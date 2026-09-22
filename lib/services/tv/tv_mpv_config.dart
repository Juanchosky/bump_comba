import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import '../../utils/cabeceras_stream.dart';
import '../performance_service.dart';
import '../network_quality_service.dart';

/// Configuracion de MPV para televisores, COMPARTIDA.
///
/// POR QUE VIVE AQUI Y NO EN CADA PANTALLA
/// Estos valores no son preferencias: son el resultado de pelearse con un
/// proveedor concreto en un aparato concreto. `framedrop=vo` en vez de
/// `decoder+vo`, `cache-on-disk=no`, el reparto 96/48 MB del bufer... cada uno
/// arregla un sintoma que costo encontrar.
///
/// El receptor de transmisiones los tenia y el reproductor autonomo no, asi que
/// el mismo video se veia fluido al transmitirlo y a tirones al abrirlo desde
/// el catalogo del televisor. Duplicarlos habria garantizado que se separaran:
/// el dia que alguien afine uno, el otro se queda atras.

class TvMpvConfig {
  TvMpvConfig._();

  /// Que calidad se le pide a una lista HLS, segun el APARATO y la RED.
  ///
  /// ── POR QUE NO ES UN NUMERO FIJO ───────────────────────────────────────
  ///
  /// Estaba a `3000000` (3 Mbps) para el contenido scrapeado y a `auto` para
  /// el resto. Dos problemas:
  ///
  ///  1. `auto` NO EXISTE. MPV solo acepta `no`, `min`, `max` o un numero, y
  ///     lo dice en el log del televisor: "Invalid value for option
  ///     hls-bitrate: auto". O sea que donde ponia `auto` no se aplicaba nada.
  ///  2. El tope de 3 Mbps protegia a los aparatos flojos y las redes malas
  ///     —que era la intencion— pero se lo comia TODO el mundo: en un
  ///     televisor decente con fibra tambien se descartaba la copia 1080p de
  ///     6 Mbps y se veia peor de lo que se podia.
  ///
  /// Asi que se decide en el momento, con lo que la app ya sabe:
  ///
  ///  · GAMA BAJA (Chromecast HD, cajas de ~1 GB): nunca `max`. Pedir 8 Mbps
  ///    a un aparato que no da abasto decodificando no se ve mejor, se ve a
  ///    tirones.
  ///  · RED FLOJA O CAIDA: se baja el tope aunque el aparato sea bueno. Una
  ///    copia que la linea no sostiene es una copia que se corta cada poco.
  ///  · SCRAPEADO: un escalon por debajo. Ese proveedor trunca las respuestas
  ///    y reconecta constantemente, asi que aguanta menos caudal que un origen
  ///    normal con la misma red.
  ///  · APARATO BUENO + RED BUENA: `max`, la mejor copia de la lista.
  ///
  /// Se consulta al abrir cada video, asi que si la red cambia entre un
  /// titulo y el siguiente, el siguiente ya se pide distinto.
  /// `techoFuente` es la altura maxima REAL de la fuente, cuando se sabe (la
  /// apunta `FiltroCalidadService` al reproducir). Sirve para no aplicarle a
  /// un 720p un tope que existe para frenar un 1080p que no existe.
  static String hlsBitrate({bool esScrapeado = false, int? techoFuente}) {
    final gamaBaja = PerformanceService().isLowPerformance;
    final red = NetworkQualityService().quality.value;

    // Techo por red. En vivo o no, una linea que no da es lo que manda.
    final int porRed = switch (red) {
      NetworkQuality.offline || NetworkQuality.poor => 1200000,
      NetworkQuality.fair => 2500000,
      NetworkQuality.good => 5000000,
      NetworkQuality.excellent => 0, // 0 = sin techo por este lado
    };

    // ── TECHO POR APARATO ──────────────────────────────────────────────
    //
    // La gama baja no pasa de 3 Mbps... salvo si ya se sabe que la fuente
    // topa en 720p, y entonces sube a 6.
    //
    // POR QUE ES SEGURO SUBIRLO AHI. Este tope existe para que el aparato no
    // se ahogue decodificando, y **lo que cuesta decodificar lo marca la
    // RESOLUCION, no el bitrate**: son los pixeles por segundo que tiene que
    // sacar el decodificador. Un 720p a 6 Mbps no le da mas trabajo al
    // decodificador por hardware que un 720p a 3 Mbps; lo que sube es el
    // trafico de red y el troceo del flujo, que son baratos al lado.
    //
    // POR QUE HACE FALTA. En el televisor se ven macrobloques mucho mas que
    // en el telefono, y ahi NO se puede hacer nada por software: el shader de
    // desbloqueo necesita `mediacodec-copy` y este SoC no lo aguanta (ver
    // `_nivel2PermitidoEnTv` en la pantalla del reproductor). O sea que en el
    // televisor la UNICA palanca que queda contra el bloque es pedir una
    // copia mejor codificada — y este tope era lo que lo impedia: obligaba a
    // quedarse con el 720p MAS comprimido de los que ofrece la lista, que es
    // exactamente el que mas cuadros tiene.
    //
    // El techo por red sigue mandando por encima de esto, que es la
    // proteccion de verdad si la linea no da.
    final bool fuenteBaja = techoFuente != null && techoFuente <= 720;
    final int porAparato = gamaBaja ? (fuenteBaja ? 6000000 : 3000000) : 0;

    // Y el scrapeado, un escalon por debajo del resto.
    //
    // Salvo si ya se sabe que esa fuente no pasa de 720p: entonces el escalon
    // no frena nada —no hay 1080p al que pudiera irse— y lo unico que hace es
    // quedarse con el 720p mas comprimido de los que ofrece. El ancho de
    // banda que gasta sigue siendo de 720p, asi que los topes por red y por
    // aparato, que son los que hablan de lo que el enlace y el cacharro
    // aguantan, se quedan donde estan.
    final int porOrigen = (esScrapeado && !fuenteBaja) ? 6000000 : 0;

    final topes = [porRed, porAparato, porOrigen].where((t) => t > 0).toList();
    if (topes.isEmpty) return 'max';
    return topes.reduce((a, b) => a < b ? a : b).toString();
  }

  /// El desbloqueo que el PROPIO CODEC lleva dentro.
  ///
  /// `vd-lavc-skiploopfilter` decide si se SALTA el filtro de bucle de
  /// H.264. Y ese filtro no es un extra: es el desbloqueador que el
  /// codec lleva dentro, el que suaviza las fronteras de macrobloque
  /// dentro del propio decodificador. Saltarselo es, literalmente,
  /// apagar el antibloques del codec.
  ///
  /// Estaba en `nonref` —saltarselo en los fotogramas que no sirven de
  /// referencia— por fluidez, y en un aparato asi era una decision
  /// razonable. Pero es tambien la causa mas directa posible de los
  /// cuadros que se ven en el televisor, y en el televisor NO hay plan
  /// B: el shader de desbloqueo necesita `mediacodec-copy`, que este
  /// SoC no aguanta.
  ///
  /// OJO, Y ES IMPORTANTE PARA NO ENGAÑARSE: con `hwdec: mediacodec`
  /// quien descodifica es MediaCodec, y estas opciones son de
  /// libavcodec. Ahi no hacen NADA — ni bien ni mal. Solo cuentan
  /// cuando el camino de hardware no puede con el flujo y MPV cae a
  /// software, que es justo cuando peor se ve. O sea: gratis en el caso
  /// normal, y una mejora real en el caso malo.
  ///
  /// Con una fuente que ya se sabe que no pasa de 720p hay holgura de
  /// sobra para no saltarse nada; de 1080p para arriba se mantiene el
  /// ahorro de siempre.
  static Map<String, String> opcionesDeDecodificacion(int? techoFuente) {
    final bool fuenteBaja =
        techoFuente != null && techoFuente > 0 && techoFuente <= 720;
    return fuenteBaja
        ? const {'vd-lavc-fast': 'no', 'vd-lavc-skiploopfilter': 'none'}
        : const {'vd-lavc-fast': 'yes', 'vd-lavc-skiploopfilter': 'nonref'};
  }

  /// Aplica el perfil base. Pensado para VOD: lectura adelantada larga y cache
  /// generoso. Para directos hay que bajar ambos despues (ver el receptor).
  ///
  /// `techoFuente` es la altura maxima real de la fuente, cuando se sabe:
  /// decide si se conserva el filtro de bucle del codec (ver
  /// [opcionesDeDecodificacion]).
  static Future<void> aplicarBase(Player player, {int? techoFuente}) async {
    // Solo propiedades SEGURAS en Android (nunca vo=gpu / profile=fast).
    // Optimizado para FLUIDEZ máxima en TVs de gama baja (Chromecast HD,
    // TV boxes con ~1GB RAM y SoC débil).
    try {
      final mpv = player.platform as dynamic;
      if (mpv == null) return;

      final opciones = <String, String>{
        'vd-lavc-threads': '0',

        ...opcionesDeDecodificacion(techoFuente),
        'video-sync': 'audio',
        'framedrop': 'vo',
        'scale': 'bilinear',
        'cscale': 'bilinear',
        'linear-upscaling': 'no',
        'sigmoid-upscaling': 'no',
        'deband': 'no',
        'dither-depth': 'no',
        'cache': 'yes',
        // media_kit trae 'cache-on-disk': 'yes' por defecto (ver la tabla de
        // propiedades de NativePlayer). El telefono ya lo apaga a mano; el
        // receptor no lo hacia, asi que MPV intentaba escribir los 96 MB de
        // cache del demuxer en la flash del televisor. En un Chromecast HD sin
        // espacio libre eso falla ("Failed to create file cache") despues de
        // haber gastado el tiempo intentandolo, y el arranque se va a 8s o se
        // queda colgado. En RAM no hay nada que crear.
        'cache-on-disk': 'no',
        // ── Reparto del búfer entre "adelante" y "atrás" ───────────────────
        //
        // Estaba en 128 MB adelante / 16 MB atras, con 300s de lectura
        // adelantada. Esa proporcion 8:1 rompe el cambio de pista: al elegir
        // otro idioma o activar subtitulos, MPV tiene que volver a demuxar la
        // posicion ACTUAL para la pista nueva. Con 300s de readahead la cabeza
        // del demuxer va lejisimos por delante, asi que los bytes de donde
        // esta viendo el usuario caen en la parte de ATRAS del bufer — que solo
        // guardaba 16 MB, unos 20 segundos a 6 Mbps. Ya estaban descartados.
        //
        // Sin esos bytes, MPV no puede servir el cambio desde memoria y vuelve
        // a pedir por red: seek completo, decodificador vaciado y parón. Es lo
        // que se ve al cambiar de idioma.
        //
        // El total sigue siendo 144 MB — importante, porque estos TV box tienen
        // ~1 GB de RAM. Solo se reparte distinto: 48 MB atras son ~64s, de
        // sobra para cualquier cambio de pista, y bajar el readahead evita que
        // la cabeza se aleje tanto de la posicion de reproduccion.
        'cache-secs': '60',
        'demuxer-max-bytes': '50331648',
        'demuxer-max-back-bytes': '16777216',
        'demuxer-readahead-secs': '45',
        // ── ARRANCAR YA, NO CUANDO EL BUFER ESTE LLENO ────────────────────
        //
        // Estaba en 'yes', que le dice a MPV que NO empiece a reproducir hasta
        // tener `cache-pause-wait` segundos —4— en el bufer. Con este proveedor
        // dando 0,5-3 Mbps para un video de 8, llenar esos 4 segundos son diez
        // o quince de pantalla negra: es exactamente el "en el telefono
        // arranca al instante y en el televisor tarda muchisimo".
        //
        // En el telefono este prebufer solo se activa para premium, y con un
        // aviso en pantalla que explica la espera. Aqui estaba puesto para
        // todos y sin aviso.
        //
        // A cambio, el primer minuto puede tener algun corte mas: se arranca
        // con lo poco que haya. Es el intercambio correcto — un corte se
        // entiende, quince segundos en negro parecen una app rota. El
        // `cache-pause-wait` de 4s se queda, que ese SI vale para recuperarse
        // de un vaciado a mitad de pelicula.
        'cache-pause-initial': 'no',
        'cache-pause-wait': '4',
        'cache-pause': 'yes',
        // Sin esto MPV RECHAZA entradas de playlist que considera inseguras,
        // y este proveedor sirve los titulos como playlist — el log del
        // televisor lo dice en cada carga: "Reading plaintext playlist".
        // El resultado era que la reproduccion terminaba antes de tiempo (un
        // `completed` a los 64s de una pelicula entera), el telefono lo leia
        // como fin prematuro y recargaba con otro archivo distinto.
        //
        // El reproductor del telefono ya lo tenia puesto, y sin condiciones;
        // el receptor nunca lo recibio. Por eso el mismo titulo va bien en el
        // movil y se corta en la tele.
        'load-unsafe-playlists': 'yes',
        'user-agent': kUserAgentPorDefecto,
        'http-header-fields': 'Connection: keep-alive',
        'demuxer-cache-wait': 'no',
        'hls-bitrate': hlsBitrate(),
        'stream-buffer-size': '8388608',
        'network-timeout': '35',
        'http-reconnect': 'yes',
        'http-reconnect-sleep': '0.5',
        // stream-lavf-o es una lista clave=valor separada por comas, asi que
        // una coma DENTRO de un valor rompe el parseo: MPV leia "429" como
        // una clave suelta y tiraba "Expected '=' and a value", dejando toda
        // la opcion sin aplicar (sin reconexion de ffmpeg en la TV). El prefijo
        // %N% le dice a MPV cuantos caracteres ocupa el valor literal.
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_at_eof=1,'
            'reconnect_delay_max=2,reconnect_on_network_error=1,'
            'reconnect_on_http_error=%7%5xx,429',
        'http-pipelining': 'yes',
        'tls-verify': 'no',
        'force-seekable': 'yes',
        // ── Ajustes portados del reproductor del telefono ──────────────────
        //
        // Este proveedor TRUNCA cada respuesta HTTP en un tamano fijo (~104 KB
        // medidos), asi que un archivo de 2,3 GB son ~22.000 reconexiones, cada
        // una con su corte de paquete. El telefono ya tiene estos tres ajustes
        // para sobrevivirlo; el receptor no los tenia.
        //
        // Ninguno aumenta el ancho de banda: los tamanos de bufer siguen igual
        // porque subirlos satura el puerto del VPS y provoca que el proveedor
        // corte las conexiones lentas.
        //
        // - demuxer-seekable-cache: deja recolocarse dentro del bufer ya
        //   descargado en vez de repedir por red tras cada corte.
        // - http-reconnect-timeout: acota cuanto puede quedarse colgada UNA
        //   reconexion. Sin esto, una sola mala congela la imagen entera.
        // - vd-lavc-o err_detect=ignore_err: que el decodificador tolere los
        //   paquetes danados de cada frontera de truncado en vez de atascarse.
        'demuxer-seekable-cache': 'yes',
        'http-reconnect-timeout': '5',
        'vd-lavc-o': 'err_detect=ignore_err,flags2=+fast',
      };

      // Una a una, no con Future.wait. Antes iban todas juntas y el fallo de
      // UNA sola abortaba el await de las demas sin decir cual era: por eso el
      // "Expected '=' and a value" de stream-lavf-o aparecia como un error
      // suelto del player, sin nombre de propiedad. Asi cada opcion que este
      // MPV no reconozca (varias `http-*` son en realidad AVOptions de ffmpeg,
      // no propiedades de MPV) queda registrada por su nombre.
      for (final e in opciones.entries) {
        try {
          await mpv.setProperty(e.key, e.value);
        } catch (err) {
          debugPrint('TvMpv: rechazado ${e.key}=${e.value} -> $err');
        }
      }
    } catch (e) {
      debugPrint('TvReceiver: error configurando MPV: $e');
    }
  }
}
