import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

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

  /// Aplica el perfil base. Pensado para VOD: lectura adelantada larga y cache
  /// generoso. Para directos hay que bajar ambos despues (ver el receptor).
  static Future<void> aplicarBase(Player player) async {
    // Solo propiedades SEGURAS en Android (nunca vo=gpu / profile=fast).
    // Optimizado para FLUIDEZ máxima en TVs de gama baja (Chromecast HD,
    // TV boxes con ~1GB RAM y SoC débil).
    try {
      final mpv = player.platform as dynamic;
      if (mpv == null) return;

      final opciones = <String, String>{
        'vd-lavc-threads': '0',
        'vd-lavc-fast': 'yes',
        'vd-lavc-skiploopfilter': 'all',
        'video-sync': 'audio',
        // 'vo' y no 'decoder+vo'. Con 'decoder' MPV descarta fotogramas ANTES
        // de decodificarlos cuando va tarde, que es justo lo que amplifica el
        // sintoma con este proveedor: se queda sin datos, el audio sigue con su
        // propio bufer, y al llegar la rafaga siguiente el video corre a
        // alcanzarlo tirando fotogramas -> el "aceleron" visible. El telefono
        // ya llego a 'vo' peleando contra este mismo proveedor.
        'framedrop': 'vo',
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
        'cache-secs': '120',
        'demuxer-max-bytes': '100663296',
        'demuxer-max-back-bytes': '50331648',
        'demuxer-readahead-secs': '90',
        'cache-pause-initial': 'yes',
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
        'hls-bitrate': 'min',
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
