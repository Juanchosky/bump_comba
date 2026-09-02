import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../services/dynamic_scraper_service.dart';
import '../../services/turbo_proxy.dart';
import '../../services/tv/tv_mpv_config.dart';
import '../../utils/cabeceras_stream.dart';
import '../../utils/clasificacion_stream.dart';
import 'tv_loading_animation.dart';
import '../../services/m3u_service.dart';
import '../../services/watch_progress_service.dart';

/// Reproductor del televisor en modo autónomo (sin teléfono).
///
/// Es hermano del receptor de transmisiones, no el mismo: aquel obedece
/// órdenes que llegan por la red y este obedece al mando. Compartir uno solo
/// habría significado un archivo con dos dueños y un `if` en cada método.
///
/// Lo que sí comparten es el LENGUAJE: misma línea de tiempo, mismos iconos de
/// pistas, mismo selector a dos columnas, mismo criterio de que el foco se
/// marca con brillo y nunca con tamaño.
class TvPlayerScreen extends StatefulWidget {
  final M3UItem item;
  final String titulo;

  /// Solo lo rellena la vista previa de la ficha. Si es `null`, esto es una
  /// pantalla normal empujada al `Navigator` y todo funciona como siempre.
  ///
  /// SI NO ES NULL, este reproductor NO vive en una ruta: vive en el `Overlay`
  /// de la app, por encima del `Navigator`. Ese es el truco entero de que
  /// pasar de la ficha al reproductor grande no recargue el vídeo — al no
  /// estar dentro de una ruta, navegar no lo destruye ni lo vuelve a montar.
  ///
  /// A cambio hay dos cosas que aquí NO puede hacer, y por eso se consulta
  /// este valor en varios sitios:
  ///
  ///  · `PopScope` necesita una `ModalRoute` para engancharse, y en el
  ///    `Overlay` no hay ninguna. El "atrás" lo intercepta quien lo montó.
  ///  · No puede robar el foco: mientras está pequeño, el foco es de la ficha.
  ///
  /// El valor dice si está en grande. Los controles solo se pintan entonces:
  /// en un recuadro de 360 px son ilegibles y además tapan el vídeo.
  final ValueListenable<bool>? expandido;

  const TvPlayerScreen({
    super.key,
    required this.item,
    required this.titulo,
    this.expandido,
  });

  @override
  State<TvPlayerScreen> createState() => TvPlayerScreenState();
}

class TvPlayerScreenState extends State<TvPlayerScreen> {
  /// ¿Vive en el `Overlay` en vez de en una ruta?
  bool get _enOverlay => widget.expandido != null;

  /// ¿Se está viendo a pantalla completa?
  bool get _grande => widget.expandido?.value ?? true;

  /// Para que quien lo monta en el `Overlay` pueda pasarle las teclas del
  /// mando: allí arriba no las recibe por su cuenta.
  KeyEventResult manejarTecla(KeyEvent evento) =>
      _tecla(_playerFocusNode, evento);

  /// El "atrás", con el mismo orden de siempre: primero cierra el menú, luego
  /// los controles, y solo entonces admite que se quiere salir.
  bool manejarAtras() => _manejarAtras();
  // EXACTAMENTE la misma configuracion que el receptor de transmisiones.
  //
  // `hwdec: 'mediacodec'` va AQUI, en la creacion, y no por `setProperty`:
  // `AndroidVideoController.create()` aplica lo suyo DESPUES, y con 'auto-safe'
  // este SoC (Amlogic) elige `mediacodec-copy` — una copia por CPU de cada
  // fotograma 1080p, que son tirones.
  //
  // Creandolo tarde y sin esto, el log decia
  // "h264_mediacodec: Both surface and native_window are NULL": el decodificador
  // arrancaba sin superficie donde pintar y la pantalla se quedaba NEGRA con el
  // audio corriendo por detras.
  final Player _player = Player(
    configuration: PlayerConfiguration(
      title: 'Bump Comba TV',
      bufferSize: 32 * 1024 * 1024, // 32 MB — moderado para TVs de gama baja
      logLevel: kDebugMode ? MPVLogLevel.info : MPVLogLevel.error,
      // libass apagado: el widget Video solo pinta subtitulos con su
      // SubtitleView de Flutter cuando libass no esta. Con libass, MPV los
      // dibuja sobre la Surface de Android y no se ven.
      libass: false,
    ),
  );

  late final VideoController _controlador = VideoController(
    _player,
    configuration: const VideoControllerConfiguration(
      enableHardwareAcceleration: true,
      hwdec: 'mediacodec',
    ),
  );
  final List<StreamSubscription> _subs = [];
  final FocusNode _playerFocusNode = FocusNode(debugLabel: 'TvPlayerKeys');

  /// La pantalla ya se fue y el `Player` esta destruido.
  ///
  /// ── POR QUE HACE FALTA ADEMAS DE `mounted` ─────────────────────────────
  ///
  /// Resolver la pagina de un servidor tarda SEGUNDOS: se abre un WebView, se
  /// carga la web del proveedor entera y se espera a pillar el enlace del
  /// video. En ese rato el usuario puede salir de la ficha de sobra.
  ///
  /// Cuando la resolucion termina, el `State` ya esta destruido y el `Player`
  /// con el; tocarlo entonces revienta con `[Player] has been disposed`. Y lo
  /// peor no es el error: es que ese fallo se tomaba por un servidor caido y
  /// disparaba el failover sobre un reproductor que ya no existe, dejando en
  /// el log "el unico servidor disponible fallo" cuando el servidor no habia
  /// dicho nada.
  ///
  /// `mounted` no basta: el `Player` se destruye en `dispose`, y hay tramos
  /// `async` que siguen despues. Esto es explicito y no depende del orden.
  bool _muerto = false;

  bool _reproduciendo = false;
  bool _buffering = true;

  /// ¿Ha llegado ya el primer fotograma?
  ///
  /// Sin esto el spinner solo salia con `buffering`, y hay un hueco entre que
  /// MPV deja de bufferear y aparece la imagen: ahi la pantalla se quedaba
  /// NEGRA y sin nada, que es lo que hace pensar que se colgo.
  bool _primerFrameListo = false;

  /// Hasta donde hay datos cargados (posicion ABSOLUTA, no una duracion).
  Duration _bufer = Duration.zero;

  /// Cuando avanzo la posicion por ultima vez.
  DateTime _ultimoAvance = DateTime.now();

  /// Si toca enseñar el spinner.
  ///
  /// EL JUEZ ES EL AVANCE, NO `buffering`.
  ///
  /// El spinner se quedaba puesto con el video ya corriendo, y el motivo es
  /// que dependia de `_buffering`: MPV mantiene esa bandera levantada mientras
  /// rellena el bufer, y con una lista HLS que reconecta cada pocos segundos
  /// no la baja casi nunca. Preguntarle a MPV "¿estas cargando?" da una
  /// respuesta que no coincide con lo que se ve.
  ///
  /// Si la posicion se movio hace menos de un segundo, hay imagen: no hay nada
  /// que esperar y el spinner sobra, diga lo que diga la bandera.
  bool get _cargando {
    if (!_arranco) return true;
    return DateTime.now().difference(_ultimoAvance) >
        const Duration(milliseconds: 1000);
  }

  /// Lo ultimo que se pinto, para repintar solo cuando cambia.
  bool _spinnerVisible = true;

  // ── EL COLCHON CRECE SI LA LINEA NO DA ─────────────────────────────────
  //
  // Arrancar con el bufer vacio hace que el video empiece al instante, pero si
  // el proveedor da 1,5 Mbps para un video de 8 se queda sin datos enseguida y
  // aparecen los cortes cada pocos segundos.
  //
  // Un valor fijo no sirve para las dos cosas: alto, la primera imagen tarda
  // quince segundos; bajo, la pelicula va a tirones. Asi que se empieza bajo
  // —arranque rapido— y CADA VEZ QUE SE CORTA se pide mas colchon para
  // reanudar. El resultado es menos cortes y mas largos en vez de muchos y
  // cortos, que es lo que de verdad se nota mirando.
  //
  // Es lo mismo que hace un reproductor de streaming serio: adaptarse a la
  // linea que hay, no a la que uno querria.
  final List<DateTime> _cortes = [];
  int _esperaBufer = _esperaBuferInicial;
  static const int _esperaBuferInicial = 2;
  static const int _esperaBuferMaxima = 20;

  /// Velocidad de descarga, para la esquina superior izquierda.
  double _kbps = 0;
  Timer? _sondeoVelocidad;
  Timer? _diagnostico;
  Timer? _prepararAlternativas;
  Duration _posicion = Duration.zero;
  Duration _duracion = Duration.zero;

  bool _controlesVisibles = true;
  Timer? _ocultar;

  /// 0 = play, 1 = línea de tiempo, 2 = subtítulos, 3 = audio.
  int _foco = 0;

  // Salto en curso: se acumula mientras se pulsa y se aplica al soltar, para
  // no vaciar el decodificador en cada pulsación.
  bool _preparandoSalto = false;
  Duration _saltoPrevisto = Duration.zero;
  Timer? _confirmarSalto;

  bool _menuAbierto = false;
  int _menuTab = 0;
  int _menuIdx = 0;

  // ── Seguir viendo ────────────────────────────────────────────────────────
  final _progreso = WatchProgressService();
  Timer? _guardado;
  Duration? _reanudadoDesde;

  // ── Cambio de servidor ───────────────────────────────────────────────────
  //
  // Mismo problema que en la transmision y misma solucion: el titulo puede
  // estar en varios sitios y el primero no siempre responde.
  late final List<String> _urls;
  int _idxServidor = 0;
  VoidCallback? _m3uListener;

  Timer? _vigilante;
  Duration _posVigilada = Duration.zero;
  int _segundosSinAvance = 0;
  bool _cambiandoServidor = false;

  /// Segundos parado que bastan para probar otro servidor. El mismo numero que
  /// usa el telefono, y por el mismo motivo: por debajo se cambia por baches
  /// normales del bufer, y por encima el usuario ya se ha ido.
  static const int _umbralParado = 9;

  /// ¿Lo paró el usuario?
  ///
  /// EL VIGILANTE NO PUEDE CONTAR MIENTRAS ESTA EN PAUSA.
  ///
  /// En pausa no entran bytes y la posicion no se mueve: para el vigilante era
  /// exactamente igual que un servidor muerto, asi que a los 45 segundos de
  /// haber pausado cambiaba de servidor solo. Y al cambiar, volvia a
  /// reproducir — el usuario habia pulsado pausa y la pelicula arrancaba sola
  /// por otro sitio.
  ///
  /// El estado `playing` de MPV no basta para distinguirlo: tambien se pone en
  /// falso al bufferear o al cambiar de pista. Esta bandera dice quien lo paro,
  /// que es lo unico que importa aqui.
  bool _pausadoAdrede = false;

  // ── Vigilante de ARRANQUE ────────────────────────────────────────────────
  //
  // Es un fallo DISTINTO del de "se paro a mitad", y necesita su propio juez.
  //
  // El de mitad mira si la posicion avanza. Ese no sirve aqui: durante el
  // arranque la posicion es 0 y no se mueve porque aun no hay imagen. Aplicarle
  // el mismo criterio provocaba que cambiara de servidor cada 9s sin dejar
  // arrancar nunca; excluir el arranque del todo dejaba el caso contrario, un
  // servidor que se queda cargando para siempre y nadie lo releva.
  //
  // Lo que se mide aqui es si ENTRAN DATOS. Con `cache-speed` a cero no esta
  // cargando lento: no esta cargando.
  int _segundosDesdeAbrir = 0;

  /// Segundos que se le dan a un servidor para EMPEZAR antes de pasar al
  /// siguiente. Los mismos 9 que usa el telefono, para que la espera se sienta
  /// igual se abra desde donde se abra.
  static const int _umbralArranque = 9;

  /// La primera posicion observada tras abrir. La referencia contra la que se
  /// mide si el video avanza de verdad.
  Duration? _posReferencia;

  /// Si este servidor llego a arrancar. Se reinicia en cada apertura.
  bool _arranco = false;

  /// Avisos de MPV de que los bytes que llegan estan rotos.
  ///
  /// Un vigilante que solo mira si la posicion avanza NO ve este fallo: con
  /// datos corruptos la posicion avanza —a tirones, y con el audio por su
  /// lado— y todo parece sano. Aqui se lee lo que dice el demuxer.
  static const List<String> _marcasCorrupcion = [
    'Invalid EBML length',
    'Corrupt file detected',
    'Invalid audio PTS',
    'Audio/Video desynchronisation',
  ];
  final List<DateTime> _corrupcion = [];
  static const int _corrupcionParaCambiar = 6;

  @override
  void initState() {
    super.initState();
    // EL MISMO PERFIL DE MPV QUE EL RECEPTOR.
    //
    // Faltaba, y era la diferencia entera: el mismo video se veia fino al
    // transmitirlo desde el telefono y a tirones al abrirlo desde el catalogo,
    // porque aqui el reproductor arrancaba con los valores por defecto de MPV.
    // Ahora los dos comparten `TvMpvConfig` — framedrop=vo, cache en RAM, el
    // reparto 96/48 MB del bufer... — que son decisiones ganadas peleando con
    // este proveedor en este aparato.

    _subs.addAll([
      _player.stream.playing.listen((v) {
        if (mounted) setState(() => _reproduciendo = v);
      }),
      _player.stream.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
        if (v) _anotarCorte();
      }),
      _player.stream.position.listen((v) {
        // Cada vez que la posicion se mueve de verdad se apunta la hora: es lo
        // unico que prueba que el video esta corriendo. Se apunta SIEMPRE,
        // tambien mientras se apunta un salto: el vigilante necesita saber que
        // el video sigue vivo pase lo que pase.
        if (v != _posicion) _ultimoAvance = DateTime.now();

        // ── MIENTRAS SE APUNTA UN SALTO, MANDA EL USUARIO ────────────────
        //
        // Aqui estaba el tiron de la linea de tiempo. `_saltar` escribe en
        // `_posicion` el sitio al que vas, pero el salto no se ejecuta hasta
        // 500 ms despues de soltar. En ese medio segundo MPV sigue
        // reproduciendo y mandando su posicion REAL, que caia justo aqui y
        // pisaba la del usuario.
        //
        // Resultado: la marca saltaba adelante al pulsar y volvia atras al
        // instante siguiente, decenas de veces por segundo. Eso es el
        // "glitch" — no era el dibujo, eran dos sitios distintos escribiendo
        // la misma variable a la vez.
        if (_preparandoSalto) return;

        _posicion = v;
        if (mounted && _controlesVisibles) setState(() {});
      }),
      _player.stream.duration.listen((v) {
        if (mounted) setState(() => _duracion = v);
      }),
      // Cuanto hay cargado por delante. Lo pinta la linea de tiempo como una
      // pista mas clara, igual que el receptor: sin ella no se sabe si el
      // video esta cargando o parado.
      _player.stream.buffer.listen((v) {
        _bufer = v;
        if (mounted && (_controlesVisibles || _preparandoSalto)) {
          setState(() {});
        }
      }),
    ]);

    // El titulo primero y sus alternativas despues, sin repetidos.
    //
    // Si el item fue abierto antes de que terminara el cruce en segundo plano,
    // se consulta M3UService para obtener las alternativas ya conocidas o de la BD.
    final alts =
        widget.item.alternatives.isNotEmpty
            ? widget.item.alternatives
            : M3UService().getAlternativesFor(widget.item);

    _urls = <String>{widget.item.url, for (final alt in alts) alt.url}.toList();

    if (_urls.length <= 1) {
      debugPrint(
        'TvPlayer: "${widget.item.name}" no tiene servidor alternativo '
        '— esperando si el indexado de BD encuentra alguno',
      );
    } else {
      debugPrint('TvPlayer: ${_urls.length} servidores disponibles');
    }

    // Escuchar a M3UService por si el indexado en segundo plano termina mientras
    // se reproduce y añade alternativas desde la BD (Supabase).
    _m3uListener = () {
      if (_urls.length <= 1 && mounted) {
        final freshAlts = M3UService().getAlternativesFor(widget.item);
        if (freshAlts.isNotEmpty) {
          final nuevasUrls =
              <String>{
                widget.item.url,
                for (final alt in freshAlts) alt.url,
              }.toList();
          if (nuevasUrls.length > _urls.length) {
            setState(() {
              _urls = nuevasUrls;
            });
            debugPrint(
              'TvPlayer: ${_urls.length} servidores disponibles (actualizado tras indexado de BD)',
            );
          }
        }
      }
    };
    M3UService().addListener(_m3uListener!);

    _subs.add(
      _player.stream.log.listen((l) {
        // Fallo definitivo: no se espera a los 9 segundos, se pasa ya al
        // siguiente y este se marca para no volver a probarlo.
        // Ojo: solo si el servidor actual es ya una URL de video. Si es una
        // pagina a medio resolver, los errores son de la pagina, no del video.
        if (!_arranco &&
            !_resolviendo.contains(_idxServidor) &&
            _marcasFatales.any(l.text.contains)) {
          debugPrint(
            'TvPlayer: servidor $_idxServidor roto (${l.text.trim()})',
          );
          _rotos.add(_idxServidor);
          unawaited(_siguienteServidor('el servidor no sirve el video'));
          return;
        }
        if (_marcasCorrupcion.any(l.text.contains)) {
          final ahora = DateTime.now();
          _corrupcion.add(ahora);
          _corrupcion.removeWhere(
            (t) => ahora.difference(t) > const Duration(seconds: 60),
          );
        }
      }),
    );

    // El primer fotograma: en cuanto el video tiene tamaño real, hay imagen.
    _controlador.rect.addListener(() {
      final r = _controlador.rect.value;
      if (r != null && r.width > 0 && !_primerFrameListo && mounted) {
        setState(() => _primerFrameListo = true);
      }
    });

    _arrancarSondeoVelocidad();
    _arrancar();
    _mostrarControles();
  }

  /// Carga el titulo, reanudando donde se dejo.
  ///
  /// Se reanuda SIN PREGUNTAR, que es lo que hace Netflix. Un dialogo de
  /// "¿continuar o empezar de cero?" con un mando en la mano es una decision
  /// que nadie pidio: en el 95% de los casos se quiere continuar, y para el
  /// otro 5% ya esta la barra de tiempo.
  Future<void> _arrancar() async {
    // PRIMERO SE PINTA, DESPUES SE TRABAJA.
    //
    // Todo lo que viene detras —las ~30 propiedades de MPV, leer el historial,
    // levantar TurboProxy— corre por el canal de plataforma y en un Chromecast
    // HD tarda lo suyo. Lanzandolo aqui mismo, el hilo de interfaz se queda
    // ocupado ANTES de haber pintado un solo fotograma: se veia pantalla
    // negra, sin spinner, y parecia que no estaba cargando.
    //
    // Esperar al final del primer fotograma cuesta ~16 ms y garantiza que el
    // spinner ya este en pantalla cuando empieza lo pesado.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    // LA CONFIGURACION DE MPV SE ESPERA, no se lanza y se olvida.
    //
    // Estaba con `unawaited`, asi que el `open()` podia salir ANTES de que
    // estuvieran puestos el tamaño de cache, el reparto del bufer y el resto.
    // MPV arrancaba con sus valores por defecto y se comportaba de otra forma
    // — justo lo que este perfil existe para evitar.
    await TvMpvConfig.aplicarBase(_player);

    Duration desde = Duration.zero;
    try {
      final p = await _progreso.getProgressForItem(widget.item);
      // Los ultimos 60 s no se reanudan: quien llego al final quiere empezar
      // de nuevo, no ver los creditos otra vez.
      if (p != null &&
          !p.isCompleted &&
          p.positionSeconds > 30 &&
          p.durationSeconds - p.positionSeconds > 60) {
        desde = Duration(seconds: p.positionSeconds);
      }
    } catch (_) {}

    if (!mounted) return;
    if (desde > Duration.zero) setState(() => _reanudadoDesde = desde);

    try {
      await _abrir(desde);
    } catch (e) {
      // Si el PRIMER servidor no arranca —tipico del de la base de datos,
      // cuya pagina puede no soltar el video— se pasa al siguiente en vez de
      // quedarse en negro esperando a un vigilante que aun no existe.
      debugPrint('TvPlayer: el primer servidor fallo ($e) — cambiando');
      unawaited(_siguienteServidor('fallo al abrir'));
    }
    // ── LAS ALTERNATIVAS SE PREPARAN DESDE EL PRINCIPIO ─────────────────
    //
    // Antes esto solo arrancaba cuando el primer servidor ECHABA A ANDAR. Pero
    // el caso en que hace falta cambiar es justo el contrario: el primero no
    // arranca, a los 9 segundos toca saltar, y ahi es cuando se ponia a cargar
    // la pagina en el navegador invisible — con el usuario mirando una pantalla
    // parada. De ahi el "al cambiar de servidor se pone lentisimo".
    //
    // ── SOLO SI EL VIDEO VA BIEN DE VERDAD ────────────────────────────────
    //
    // Esto abre un WebView para resolver la pagina de OTRO servidor por
    // adelantado. Un WebView es un Chromium entero: carga la web del proveedor
    // con sus fuentes, su JavaScript y su analitica.
    //
    // Estaba lanzado a los 3 segundos de abrir, SIEMPRE. Y en el log se ve lo
    // que eso provoca en un televisor de gama baja: el bufer ya venia justo
    // —"acelerando mid-stream, 1.7 Mbps"—, arranca el navegador encima, y MPV
    // empieza con "End of file" y "Packet corrupt". El adelanto que pretendia
    // ahorrar tiempo era justo lo que tumbaba la reproduccion.
    //
    // Ahora se comprueba cada 8 segundos y solo se dispara cuando el video
    // lleva un rato largo yendo fino. Si nunca va fino, no se prepara nada:
    // ese aparato no da para las dos cosas a la vez, y el video es lo que el
    // usuario esta mirando.
    _prepararAlternativas = Timer.periodic(const Duration(seconds: 8), (t) {
      if (_muerto) {
        t.cancel();
        return;
      }
      if (!_reproduccionSana) return;
      t.cancel();
      _prepararAlternativasEnSegundoPlano();
    });

    _armarVigilante();
    _armarGuardado();
  }

  /// Apunta un corte y, si se repiten, agranda el colchon de reanudacion.
  void _anotarCorte() {
    // Los primeros segundos no cuentan: ahi "bufferear" es cargar, no cortarse.
    if (!_arranco) return;

    final ahora = DateTime.now();
    _cortes.add(ahora);
    _cortes.removeWhere(
      (t) => ahora.difference(t) > const Duration(minutes: 2),
    );

    // Tres cortes en dos minutos ya no es mala suerte: es que la linea no da.
    if (_cortes.length < 3 || _esperaBufer >= _esperaBuferMaxima) return;
    _cortes.clear();
    _esperaBufer = (_esperaBufer * 2).clamp(
      _esperaBuferInicial,
      _esperaBuferMaxima,
    );
    debugPrint(
      'TvPlayer: cortes repetidos -> colchon de reanudacion a ${_esperaBufer}s',
    );
    unawaited(_ponerEsperaBufer(_esperaBufer));
  }

  Future<void> _ponerEsperaBufer(int segundos) async {
    try {
      final mpv = _player.platform as dynamic;
      await mpv?.setProperty('cache-pause-wait', '$segundos');
    } catch (e) {
      debugPrint('TvPlayer: no se pudo ajustar cache-pause-wait: $e');
    }
  }

  /// La URL local que sirve TurboProxy para el servidor actual.
  String? _urlTurbo;

  /// Baja los topes del demuxer cuando la fuente es una lista HLS.
  ///
  /// Ver la nota de `_abrir`: el perfil VOD contra un `.m3u8` produce cortes
  /// constantes. Es el mismo fallo que ya se corrigio en el receptor cuando el
  /// telefono no mandaba `isLive`.
  Future<void> _ajustarPerfilSegunFuente(String url) async {
    final esHls = url.toLowerCase().contains('.m3u8');
    try {
      final mpv = _player.platform as dynamic;
      if (mpv == null) return;
      if (esHls) {
        await mpv.setProperty('cache-secs', '60');
        await mpv.setProperty('demuxer-readahead-secs', '20');
        await mpv.setProperty('hls-bitrate', 'max');
        await mpv.setProperty('hls-forward-cache-secs', '30');
        await mpv.setProperty('hls-back-cache-secs', '10');
        await mpv.setProperty('demuxer-cache-wait', 'no');
        debugPrint('TvPlayer: perfil HLS aplicado');
      } else {
        // Fichero entero: se restauran los valores del perfil base, por si el
        // servidor anterior era una lista HLS y los dejo bajados.
        await mpv.setProperty('cache-secs', '120');
        await mpv.setProperty('demuxer-readahead-secs', '90');
      }
    } catch (e) {
      debugPrint('TvPlayer: no se pudo ajustar el perfil: $e');
    }
  }

  /// Saca la URL del video de una pagina, con el extractor del telefono.
  ///
  /// SE HACE POR ADELANTADO, NO CUANDO YA HACE FALTA.
  ///
  /// Cargar la pagina en un navegador invisible cuesta lo suyo en un aparato
  /// de 1 GB: si se hace en el momento del fallo, se suma a una pantalla que
  /// ya lleva 9 segundos parada. Lanzandolo mientras el otro servidor va bien,
  /// el trabajo caro ocurre cuando NO molesta, y si luego hace falta cambiar,
  /// la URL ya esta lista y el cambio es inmediato.
  Future<String?> _resolverPagina(int indice) async {
    if (_resueltos.containsKey(indice)) return _resueltos[indice];
    if (_resolviendo.contains(indice)) return null;

    final pagina = _urls[indice];
    if (!DynamicScraperService().isSupported(pagina)) return pagina;

    _resolviendo.add(indice);
    debugPrint('TvPlayer: resolviendo la pagina del servidor $indice...');
    try {
      // ── DOS INTENTOS, COMO EN EL TELEFONO ──────────────────────────────
      //
      // Aqui se probaba UNA vez y, si fallaba, el servidor se daba por roto.
      // Pero la extraccion no falla solo cuando el servidor esta caido: falla
      // cuando la web tarda de mas, cuando el WebView arranca justo con poca
      // memoria, cuando un anuncio se cuela antes que el reproductor... y a la
      // segunda sale. El telefono reintenta por eso, y era la diferencia por
      // la que en el televisor habia titulos de la BD que "no funcionaban" y
      // en el movil si.
      for (var intento = 0; intento < 2; intento++) {
        if (_muerto) return null;
        if (intento > 0) {
          debugPrint('TvPlayer: reintentando la pagina del servidor $indice');
          // Un respiro antes de repetir: reintentar al instante suele repetir
          // el mismo fallo, porque lo que fallo sigue ocupado.
          await Future<void>.delayed(const Duration(seconds: 2));
          if (_muerto) return null;
        }

        final r = await DynamicScraperService()
            .extractStreamResult(pagina)
            .timeout(const Duration(seconds: 45));

        if (r != null && r.videoUrl.isNotEmpty) {
          _resueltos[indice] = r.videoUrl;
          // LOS SUBTITULOS SE GUARDAN, no se tiran.
          //
          // El extractor los devuelve junto al video —el telefono los recoge
          // en `_scrapedSubtitles`— y aqui se estaba usando solo `videoUrl`.
          // Por eso el contenido de la BD salia siempre sin subtitulos en el
          // televisor: no es que no los tuviera, es que se descartaban al
          // resolver.
          if (r.subtitles.isNotEmpty) {
            _subsWeb[indice] = r.subtitles;
            debugPrint(
              'TvPlayer: servidor $indice trae ${r.subtitles.length} '
              'pistas de subtitulos',
            );
          }
          debugPrint('TvPlayer: servidor $indice resuelto');
          return r.videoUrl;
        }
        debugPrint('TvPlayer: la pagina del servidor $indice no solto video');
      }
      _rotos.add(indice);
    } catch (e) {
      debugPrint('TvPlayer: no se pudo resolver el servidor $indice: $e');
      _rotos.add(indice);
    } finally {
      _resolviendo.remove(indice);
      await DynamicScraperService().stopCurrentScraping();
    }
    return null;
  }

  /// Los subtitulos que trajo el extractor de cada servidor.
  final Map<int, List<ScrapedSubtitle>> _subsWeb = {};

  /// Registra en MPV los subtitulos que venian con la pagina.
  ///
  /// Va DESPUES de `open`: antes no hay medio al que engancharlos.
  Future<void> _cargarSubsWeb() async {
    final subs = _subsWeb[_idxServidor];
    if (subs == null || subs.isEmpty || _muerto) return;
    for (final sub in subs) {
      if (_muerto) return;
      try {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(sub.url, title: sub.label, language: sub.language),
        );
      } catch (e) {
        // Una pista que no carga no puede tumbar la reproduccion.
        debugPrint('TvPlayer: no se pudo añadir el subtitulo ${sub.label}: $e');
      }
    }
  }

  /// Deja listos, en segundo plano, los servidores que necesitan extractor.
  /// ¿La reproduccion va lo bastante bien como para robarle recursos?
  ///
  /// Estricta a proposito: `_cortes` vacio significa que NO ha habido ni un
  /// tiron desde que se abrio este servidor. Con un solo corte ya no se
  /// adelanta nada — en un aparato justo, el que ha tenido un tiron tendra
  /// otro, y lo ultimo que necesita es un navegador arrancando al lado.
  bool get _reproduccionSana =>
      _reproduciendo &&
      _primerFrameListo &&
      !_buffering &&
      _cortes.isEmpty &&
      _segundosDesdeAbrir >= 25;

  Future<void> _prepararAlternativasEnSegundoPlano() async {
    // DE UNA EN UNA, no todas de golpe.
    //
    // Antes se lanzaban todas a la vez con `unawaited`: con tres servidores
    // eran tres Chromium simultaneos. Y entre una y otra se vuelve a mirar si
    // el video sigue fino, para parar en cuanto empiece a sufrir.
    for (var i = 0; i < _urls.length; i++) {
      if (_muerto) return;
      if (i == _idxServidor || _rotos.contains(i)) continue;
      if (!DynamicScraperService().isSupported(_urls[i])) continue;
      if (_resueltos.containsKey(i)) continue;
      if (!_reproduccionSana) return;
      await _resolverPagina(i);
    }
  }

  /// La URL de video REAL de cada servidor que guarda una pagina en vez de un
  /// fichero (el contenido propio: cuevana, flixlat...).
  ///
  /// El telefono hace justo esto antes de reproducir; el televisor no lo hacia
  /// y por eso ese servidor "no funcionaba aqui y en el movil si". No es que
  /// el TV lo hiciera distinto: es que no lo hacia.
  final Map<int, String> _resueltos = {};

  /// Resoluciones en marcha, para no lanzar dos veces la misma pagina.
  final Set<int> _resolviendo = {};

  /// Servidores que ya se sabe que NO van a funcionar en esta reproduccion.
  ///
  /// Hay fallos que no son mala suerte ni lentitud: un 403, una cabecera que
  /// no se puede leer, un fichero cortado. Reintentar eso a los 9 segundos es
  /// perder 9 segundos con total seguridad. Se apunta y no se vuelve.
  final Set<int> _rotos = {};

  /// Cuantos servidores seguidos han fallado sin que ninguno arrancara.
  ///
  /// Cuando da la vuelta entera sin exito, se para: seguir girando entre dos
  /// servidores que no funcionan no es tolerancia a fallos, es un bucle. Y
  /// ademas cada vuelta creaba otra sesion de TurboProxy.
  int _fallosSeguidos = 0;

  /// Se acabaron los servidores. Se enseña y se deja de intentar.
  bool _agotado = false;

  /// Lo que dice MPV cuando el servidor no va a dar el video, pase lo que pase.
  static const List<String> _marcasFatales = [
    'HTTP error 403',
    'HTTP error 404',
    'HTTP error 401',
    'error reading header',
    'Failed to open',
    'partial file',
  ];

  void _cerrarTurbo() {
    final anterior = _urlTurbo;
    _urlTurbo = null;
    if (anterior != null) TurboProxy().cerrarSesion(anterior);
  }

  Future<void> _abrir(Duration desde) async {
    // Servidor nuevo, cuenta nueva: lo que tardara el anterior no puede
    // condenar a este.
    _segundosDesdeAbrir = 0;
    _arranco = false;
    _posReferencia = null;
    // Servidor nuevo, colchon nuevo: lo que no daba el anterior no condena a
    // este, y arrancar rapido vuelve a ser lo primero.
    _cortes.clear();
    _esperaBufer = _esperaBuferInicial;
    unawaited(_ponerEsperaBufer(_esperaBuferInicial));

    var original = _urls[_idxServidor];

    // ── SI ESTE SERVIDOR ES UNA PAGINA, SE RESUELVE ANTES ───────────────
    //
    // Es lo que hace el telefono y lo que aqui faltaba. Si ya venia resuelto
    // de la preparacion en segundo plano, esto no cuesta nada; si no, se
    // resuelve ahora y se espera, que sigue siendo mejor que abrir HTML con
    // MPV y ver como falla.
    if (DynamicScraperService().isSupported(original)) {
      final resuelto = await _resolverPagina(_idxServidor);
      // Aqui se ha ido el tiempo largo. Si ya no hay pantalla, se abandona en
      // silencio: no es un fallo del servidor, es que nadie esta mirando.
      if (_muerto) return;
      if (resuelto == null || resuelto.isEmpty) {
        throw StateError('la pagina del servidor $_idxServidor no dio video');
      }
      original = resuelto;
    }

    String url = original;

    // ── TurboProxy, igual que en el telefono ────────────────────────────
    //
    // El proveedor corta cada respuesta HTTP en ~104 KB: una pelicula de 2,3 GB
    // son mas de 22.000 reconexiones. Servidas de una en una se ven como
    // parones, el audio adelantandose y el video corriendo despues para
    // alcanzarlo — exactamente el sintoma que llevamos todo el dia persiguiendo.
    //
    // TurboProxy las pide en paralelo por rangos y se las entrega a MPV como un
    // flujo continuo. Corre DENTRO de esta app, asi que en el televisor
    // autonomo funciona igual que en el movil: no hace falta ningun telefono
    // encendido.
    //
    // Todo el camino es opcional: si el envoltorio falla o tarda mas de 7s se
    // usa la URL original y se reproduce como antes.
    // Las MISMAS cabeceras que el telefono. Iban vacias, y esa era la
    // diferencia entre arrancar en 10s y tardar 40 o 50: sin `X-Bump-Tier` la
    // peticion cae en el carril lento del VPS, y sin `User-Agent` hay
    // proveedores que estrangulan al cliente que no reconocen.
    final cabeceras = cabecerasParaStream(original);

    // LA SESION ANTERIOR SE CIERRA ANTES DE ABRIR OTRA.
    //
    // No se cerraba nunca, y el log lo cantaba: "9 sesiones, todas en uso —
    // no se expulsa ninguna", luego 10, luego 11. Cada cambio de servidor
    // dejaba una descarga zombi viva, peleando por el ancho de banda y por el
    // puerto del VPS contra la reproduccion de verdad. Con un servidor que no
    // arranca y otro roto, el bucle de failover fabricaba una fuga cada 9
    // segundos: cuanto mas lo intentaba, peor iba.
    // ── PRIMERO SE PARA MPV, DESPUES SE CIERRA LA SESION ────────────────
    //
    // El orden importa, y al reves hace daño de verdad. Cerrando la sesion
    // antes, la URL local `127.0.0.1/t/N` deja de existir mientras MPV SIGUE
    // enganchado a ella: se pasa los siguientes segundos —el envoltorio tarda
    // hasta 7s, y resolver una pagina bastante mas— reconectando contra un
    // endpoint muerto. Eso es lo que llenaba el log de
    //
    //   http: HTTP error 404 Not Found
    //   http: Stream ends prematurely at 14211
    //
    // y lo que ponia el aparato de rodillas justo al cambiar de servidor: no
    // era el cambio, era MPV martilleando una direccion que ya no existia
    // mientras el resto de la app intentaba trabajar.
    //
    // Parando MPV primero, ademas, se suelta enseguida la conexion del
    // proveedor — que con un tope de 4 por linea no es un detalle menor.
    try {
      await _player.stop();
    } catch (_) {
      // Si no se puede parar, seguir igualmente: `open()` lo reemplaza.
    }
    _cerrarTurbo();

    if (!esEnVivoPorUrl(original)) {
      try {
        final local = await TurboProxy()
            .wrap(original, cabeceras)
            .timeout(const Duration(seconds: 7));
        if (local != null) {
          url = local;
          _urlTurbo = local;
          debugPrint('TvPlayer: enrutado por TurboProxy');
        }
      } catch (e) {
        debugPrint('TvPlayer: TurboProxy fallo ($e) — URL directa');
      }
    }

    // ── EL PERFIL SE AJUSTA AL TIPO DE FUENTE ──────────────────────────
    //
    // El perfil base es de VOD: 120s de cache y 90s de lectura adelantada,
    // pensados para un fichero entero servido por rangos. Contra una lista
    // HLS —que es lo que devuelve el extractor del contenido propio— eso es
    // contraproducente: solo hay unos pocos segmentos publicados, MPV choca
    // contra el final de la lista una y otra vez, y de ahi salen el
    // "End of file" repetido y los cortes cada pocos segundos.
    //
    // Son los mismos valores que ya usa el receptor para HLS, y todos BAJAN
    // respecto al perfil VOD, asi que no tocan el techo del VPS.
    if (_muerto) return;
    await _ajustarPerfilSegunFuente(original);

    // ── QUE EL EXTRACTOR SE HAYA IDO DEL TODO ─────────────────────────────
    //
    // Es lo que hace el telefono justo antes de abrir, y su comentario dice
    // que es el paso mas importante para que el bufer se comporte. Tiene
    // sentido: el WebView de extraccion es un Chromium entero: aunque se le
    // haya dicho que pare, tarda un momento en soltar memoria y CPU. Abrir
    // MPV en ese momento es hacerle competir con lo que se esta muriendo, y
    // en un aparato de 1 GB eso se nota en los primeros segundos de video.
    //
    // 300 ms de margen cuestan menos que un arranque a tirones.
    await DynamicScraperService().stopCurrentScraping();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    if (_muerto) return;
    await _player.open(
      Media(
        url,
        // Si TurboProxy no entro, MPV pide directo y necesita las cabeceras el
        // mismo. Con el envoltorio puesto no estorban: la URL ya es local.
        httpHeaders: cabeceras,
        start: desde > Duration.zero ? desde : null,
      ),
    );

    // Y los subtitulos que vinieran con la pagina, ya con el medio abierto.
    await _cargarSubsWeb();
  }

  // ── Guardar por donde va ─────────────────────────────────────────────────
  void _armarGuardado() {
    _guardado?.cancel();
    _guardado = Timer.periodic(const Duration(seconds: 5), (_) => _guardar());
  }

  void _guardar() {
    if (_posicion.inSeconds < 10 || _duracion <= Duration.zero) return;
    unawaited(
      _progreso.saveProgress(
        widget.item.url,
        _posicion,
        _duracion,
        alternativeUrls: [for (final a in widget.item.alternatives) a.url],
        name: widget.item.name,
        seriesName: widget.item.seriesName,
        seasonNumber: widget.item.seasonNumber,
        episodeNumber: widget.item.episodeNumber,
      ),
    );
  }

  // ── Vigilante: cambiar de servidor cuando este va mal ────────────────────
  void _armarVigilante() {
    _vigilante?.cancel();
    // Se arma SIEMPRE, aunque no haya alternativa: `_siguienteServidor` ya
    // comprueba si hay adonde ir, y el contador de arranque sirve igual para
    // dejar constancia en el log de que ese servidor no dio un byte.

    _vigilante = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _cambiandoServidor) return;

      // Repintar SOLO cuando el spinner cambia de estado. Un `setState` por
      // segundo en un televisor de gama baja se nota.
      if (_cargando != _spinnerVisible) {
        setState(() => _spinnerVisible = _cargando);
      }

      // En pausa no se vigila NADA: ni la posicion, ni los bytes, ni el
      // arranque. Se congela todo tal cual estaba para que al reanudar no
      // arrastre segundos que el servidor no debe.
      if (_pausadoAdrede) {
        _segundosSinAvance = 0;
        _segundosDesdeAbrir = 0;
        _posVigilada = _posicion;
        return;
      }

      // Corrupcion: la prueba mas directa, y la que el detector de posicion
      // no puede ver.
      final ahora = DateTime.now();
      _corrupcion.removeWhere(
        (t) => ahora.difference(t) > const Duration(seconds: 60),
      );
      if (_corrupcion.length >= _corrupcionParaCambiar) {
        _corrupcion.clear();
        unawaited(_siguienteServidor('datos corruptos'));
        return;
      }

      // ── Nada de esto cuenta mientras el video todavia ARRANCA ──────────
      //
      // Este vigilante mide "la posicion no se mueve". Pero durante la carga
      // inicial la posicion es 0 y no se mueve porque aun no hay imagen, no
      // porque el servidor falle.
      //
      // Sin esta guarda el resultado era demoledor: a los 9s saltaba, cambiaba
      // de servidor, volvia a empezar, y a los 9s otra vez. El contenido no
      // llegaba a cargar NUNCA y en pantalla se veia "Cambiando de servidor"
      // una y otra vez sobre un fondo negro. El arranque lento que se estaba
      // viendo no era lentitud: era este bucle.
      //
      // Mientras bufferea tampoco: bufferear es estar cargando, no estar
      // atascado. El caso de "no arranca" tiene su propio remedio — si el video
      // nunca empieza, no hay nada que vigilar aqui.
      // ── Todavia ARRANCANDO: el failover de 9s del telefono ─────────────
      //
      // Copiado de `video_player_screen`, donde ya esta probado. La clave es
      // COMO se decide que "arranco", porque las dos formas evidentes fallan:
      //
      //  - Mirar `posicion < 300ms` asume que se empieza en cero. Al reanudar,
      //    el video abre en el minuto 40 y la condicion no se cumple nunca.
      //  - Mirar `playing` tampoco vale: MPV se considera reproduciendo en
      //    cuanto se le dijo que reprodujera, aunque este llenando el bufer.
      //
      // Con las dos fallando, el failover no disparaba y se quedaba en Xtream
      // indefinidamente — exactamente el sintoma. Aqui la unica prueba que se
      // acepta es que la posicion AVANCE de verdad respecto a la PRIMERA
      // observada, sea cual sea. Asi reanudar a las dos horas funciona igual
      // que empezar de cero.
      if (!_arranco) {
        _segundosSinAvance = 0;
        _posVigilada = _posicion;
        _segundosDesdeAbrir++;

        _posReferencia ??= _posicion;
        if (_reproduciendo &&
            _posicion > _posReferencia! + const Duration(milliseconds: 500)) {
          _arranco = true;
          // Este servidor SI va: la cuenta de fallos seguidos vuelve a cero.
          _fallosSeguidos = 0;
          // Aqui NO se preparan alternativas. Se hacia, y era el segundo
          // camino por el que el navegador arrancaba encima del video: basta
          // con detectar medio segundo de avance, que no dice nada de si la
          // reproduccion aguanta. De eso se ocupa el temporizador de arriba,
          // que exige 25 segundos sin un solo tiron.
          return;
        }

        if (_segundosDesdeAbrir >= _umbralArranque) {
          unawaited(_siguienteServidor('no arranco en ${_umbralArranque}s'));
        }
        return;
      }

      // Bufferear con imagen ya en pantalla es cargar, no estar atascado.
      if (_buffering) {
        _segundosSinAvance = 0;
        _posVigilada = _posicion;
        return;
      }

      // En pausa no se cuenta: parado a proposito no es parado por fallo.
      if (!_reproduciendo || _preparandoSalto) {
        _segundosSinAvance = 0;
        _posVigilada = _posicion;
        return;
      }

      if (_posicion == _posVigilada) {
        _segundosSinAvance++;
        if (_segundosSinAvance >= _umbralParado) {
          _segundosSinAvance = 0;
          unawaited(_siguienteServidor('sin avance en ${_umbralParado}s'));
        }
      } else {
        _segundosSinAvance = 0;
        _posVigilada = _posicion;
      }
    });
  }

  Future<void> _siguienteServidor(String motivo) async {
    // Sin pantalla no hay nada que rescatar: cambiar de servidor aqui solo
    // abriria otro WebView para nadie.
    if (_muerto) return;
    if (_cambiandoServidor || _agotado) return;

    // Si solo hay un servidor, no hay adonde saltar
    if (_urls.length <= 1) {
      debugPrint('TvPlayer: el único servidor disponible falló ($motivo)');
      _vigilante?.cancel();
      // Parar antes de cerrar, por el mismo motivo que en `_abrir`: si no, MPV
      // se queda reconectando contra la sesion cerrada.
      unawaited(_player.stop());
      _cerrarTurbo();
      if (mounted) setState(() => _agotado = true);
      return;
    }

    // ── ¿QUEDA ALGUN SERVIDOR AL QUE IR? ────────────────────────────────
    //
    // Se buscan los otros servidores disponibles (excluyendo el actual _idxServidor)
    final candidatos = [
      for (var i = 1; i < _urls.length; i++)
        if (!_rotos.contains((_idxServidor + i) % _urls.length))
          (_idxServidor + i) % _urls.length,
    ];
    if (candidatos.isEmpty || _fallosSeguidos >= _urls.length) {
      debugPrint(
        'TvPlayer: sin servidores utiles '
        '(${_rotos.length} rotos de ${_urls.length}) — se deja de intentar',
      );
      _vigilante?.cancel();
      // Parar antes de cerrar, por el mismo motivo que en `_abrir`: si no, MPV
      // se queda reconectando contra la sesion cerrada.
      unawaited(_player.stop());
      _cerrarTurbo();
      if (mounted) setState(() => _agotado = true);
      return;
    }

    _fallosSeguidos++;
    _cambiandoServidor = true;
    // Servidor nuevo: vuelve a no haber imagen hasta que llegue la primera. Sin
    // esto, el vigilante seguiria contando desde el primer segundo del video
    // nuevo y encadenaria otro cambio.
    if (mounted) setState(() => _primerFrameListo = false);
    _segundosDesdeAbrir = 0;
    final desde = _posicion;
    _idxServidor = candidatos.first;
    debugPrint('TvPlayer: cambio de servidor ($motivo) -> $_idxServidor');

    // SIN AVISO EN PANTALLA.
    //
    // El cambio de servidor es cosa interna: al usuario le da igual de donde
    // salgan los bytes, y ver "Cambiando de servidor..." tres veces seguidas
    // solo transmite que algo va mal. Lo que si se ve es el spinner, que ya
    // dice lo unico importante — que todavia no hay imagen.
    //
    // Queda en el log, que es donde sirve.

    try {
      // Se retoma por donde iba, no desde cero: cambiar de servidor no puede
      // costarle al usuario volver a buscar su minuto.
      await _abrir(desde);
    } catch (e) {
      debugPrint('TvPlayer: el cambio de servidor fallo: $e');
    }

    _segundosSinAvance = 0;
    _posVigilada = desde;
    _cambiandoServidor = false;
  }

  @override
  void dispose() {
    // LO PRIMERO: lo que siga corriendo por detras tiene que enterarse de que
    // ya no hay a quien servir, antes de que nada mas se destruya.
    _muerto = true;

    // Una extraccion a medias deja un WebView invisible corriendo: en un
    // televisor de 1 GB eso es memoria que no vuelve.
    _cerrarTurbo();
    for (final s in _subs) {
      s.cancel();
    }
    _ocultar?.cancel();
    _diagnostico?.cancel();
    _prepararAlternativas?.cancel();
    _confirmarSalto?.cancel();
    _sondeoVelocidad?.cancel();
    _vigilante?.cancel();
    _guardado?.cancel();
    // Un ultimo guardado al salir: sin el se pierden hasta 5 s, y salir es
    // justo cuando el usuario espera que quede anotado por donde iba.
    _guardar();
    if (_m3uListener != null) {
      M3UService().removeListener(_m3uListener!);
    }
    _playerFocusNode.dispose();
    _player.dispose();
    super.dispose();
  }

  /// Los KB/s que MPV esta metiendo en su cache.
  ///
  /// Solo se repinta cuando se esta VIENDO —cargando o con los controles
  /// abiertos—: un setState por segundo para un texto invisible se nota en un
  /// Chromecast HD. Es el mismo criterio que el receptor.
  void _arrancarSondeoVelocidad() {
    _sondeoVelocidad = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      try {
        final mpv = _player.platform as dynamic;
        if (mpv == null) return;
        final raw = await mpv.getProperty('cache-speed');
        final kbps = (double.tryParse(raw?.toString() ?? '') ?? 0) / 1024;
        if (!mounted || kbps == _kbps) return;
        _kbps = kbps;
        if (_buffering || !_primerFrameListo || _controlesVisibles) {
          setState(() {});
        }
      } catch (_) {}
    });

    // ── DIAGNOSTICO: ¿falta red o no da el aparato? ──────────────────────
    //
    // Son dos averias distintas y desde fuera se ven parecidas: el video "va
    // mal". Sin estos numeros no hay forma de separarlas, y se acaba tocando
    // el bufer para arreglar un problema de decodificacion (o al reves).
    //
    // Como se leen las tres cifras, cada 5 segundos:
    //
    //  · bufer ~0s          -> FALTA RED. MPV se queda sin datos y para.
    //    Se ve como cortes: la imagen se congela y sigue.
    //
    //  · bufer alto Y drops -> NO DA EL APARATO. Hay datos de sobra pero los
    //    fotogramas se descartan sin llegar a pintarse. Se ve como tirones
    //    con el video corriendo: la imagen avanza a saltos.
    //
    //  · drops que suben sin parar con bufer sano, en un .mkv de este
    //    proveedor -> son los PTS rotos ("Input packet is missing PTS"): los
    //    paquetes llegan sin marca de tiempo y MPV no sabe cuando pintarlos.
    //    Ni es la red ni es el aparato; es el archivo.
    _diagnostico = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || !_arranco) return;
      try {
        final mpv = _player.platform as dynamic;
        if (mpv == null) return;
        final descartados = await mpv.getProperty('frame-drop-count');
        final descartadosDec = await mpv.getProperty(
          'decoder-frame-drop-count',
        );
        final segundosBufer = _bufer - _posicion;
        debugPrint(
          'TvPlayer diag: bufer=${segundosBufer.inSeconds}s '
          '${_kbps.toStringAsFixed(0)}KB/s '
          'descartados(vo)=${descartados ?? "?"} '
          'descartados(dec)=${descartadosDec ?? "?"} '
          'colchon=${_esperaBufer}s',
        );
      } catch (_) {}
    });
  }

  // ── Controles ────────────────────────────────────────────────────────────
  void _mostrarControles() {
    _ocultar?.cancel();
    if (!_controlesVisibles && mounted) {
      setState(() => _controlesVisibles = true);
    }
    _ocultar = Timer(const Duration(seconds: 5), () {
      if (mounted && !_menuAbierto) {
        setState(() => _controlesVisibles = false);
      }
    });
  }

  void _alternarReproduccion() {
    if (_reproduciendo) {
      _pausadoAdrede = true;
      _player.pause();
    } else {
      _pausadoAdrede = false;
      // Al reanudar, los contadores empiezan de cero: los segundos que estuvo
      // en pausa no son culpa del servidor.
      _segundosSinAvance = 0;
      _segundosDesdeAbrir = 0;
      _posVigilada = _posicion;
      _player.play();
    }
  }

  /// Cuantos saltos seguidos se llevan sin aplicar. Manda el tamaño del paso.
  int _saltosSeguidos = 0;

  /// El paso crece si se sigue saltando: 10 s, 30 s, 60 s y 120 s.
  ///
  /// Es lo que hace que llegar al minuto 40 sea cuestion de mantener la flecha
  /// un par de segundos en vez de dar cien toques. El primer toque sigue
  /// siendo de 10 s para que un ajuste fino —te perdiste una frase— siga
  /// siendo posible.
  int get _paso {
    if (_saltosSeguidos < 4) return 10;
    if (_saltosSeguidos < 10) return 30;
    if (_saltosSeguidos < 20) return 60;
    return 120;
  }

  /// Cuando se atendio el ultimo salto. Ver `_saltar`.
  DateTime? _ultimoSalto;

  /// Ritmo maximo al mantener la flecha.
  ///
  /// `KeyRepeatEvent` llega CADA 40-50 ms. Sin frenarlo, un segundo de flecha
  /// mantenida eran ~20 saltos, y para entonces la carrerilla ya iba por 120 s
  /// cada uno: unos QUINCE MINUTOS de pelicula en un segundo de pulsacion.
  /// Imposible de apuntar, y de ahi que recorrer la pelicula no funcionara.
  ///
  /// A 150 ms salen 6-7 pasos por segundo, que es un ritmo que la vista sigue
  /// — y ademas hace que la carrerilla se mida en tiempo real: 10 s por paso
  /// el primer medio segundo, 30 s hasta el segundo y medio, 60 s hasta los
  /// tres, y 120 s de ahi en adelante.
  static const Duration _ritmoSalto = Duration(milliseconds: 150);

  /// `direccion` es -1 o 1; el tamaño del paso lo decide la carrerilla.
  void _saltar(int direccion) {
    final ahora = DateTime.now();
    final previo = _ultimoSalto;
    if (previo != null && ahora.difference(previo) < _ritmoSalto) return;
    _ultimoSalto = ahora;

    _saltosSeguidos++;
    final segundos = direccion.sign * _paso;
    final base = _preparandoSalto ? _saltoPrevisto : _posicion;
    var destino = base + Duration(seconds: segundos);
    if (destino < Duration.zero) destino = Duration.zero;
    if (_duracion > Duration.zero && destino > _duracion) destino = _duracion;

    setState(() {
      _preparandoSalto = true;
      _saltoPrevisto = destino;
      _posicion = destino;
    });

    // Se aplica 500 ms despues de la ULTIMA pulsacion, no en cada una: saltar
    // por cada tecla vacia el bufer una vez por pulsacion y recorrer un minuto
    // a base de toques dejaba el video inservible. Con la flecha mantenida,
    // ademas, 500 da margen a soltar antes de que se ejecute.
    _confirmarSalto?.cancel();
    _confirmarSalto = Timer(const Duration(milliseconds: 500), _aplicarSalto);
  }

  void _aplicarSalto() {
    if (!_preparandoSalto) return;
    _saltosSeguidos = 0; // la carrerilla se pierde al soltar
    _ultimoSalto = null;
    _player.seek(_saltoPrevisto);
    setState(() => _preparandoSalto = false);
  }

  // ── Pistas ───────────────────────────────────────────────────────────────
  List<AudioTrack> get _pistasAudio =>
      _player.state.tracks.audio
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();

  List<SubtitleTrack> get _pistasSubs =>
      _player.state.tracks.subtitle
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();

  int get _menuLargo =>
      _menuTab == 0 ? _pistasAudio.length : _pistasSubs.length + 1;

  int _indiceActual(int pestana) {
    try {
      if (pestana == 0) {
        final id = _player.state.track.audio.id;
        final i = _pistasAudio.indexWhere((t) => t.id == id);
        return i < 0 ? 0 : i;
      }
      final id = _player.state.track.subtitle.id;
      if (id == 'no' || id == 'auto') return 0;
      final i = _pistasSubs.indexWhere((t) => t.id == id);
      return i < 0 ? 0 : i + 1;
    } catch (_) {
      return 0;
    }
  }

  void _abrirMenu(int pestana) {
    _ocultar?.cancel();
    setState(() {
      _menuAbierto = true;
      _menuTab = pestana;
      _menuIdx = _indiceActual(pestana);
    });
  }

  Future<void> _aplicarPista() async {
    try {
      if (_menuTab == 0) {
        final l = _pistasAudio;
        if (_menuIdx >= 0 && _menuIdx < l.length) {
          await _player.setAudioTrack(l[_menuIdx]);
        }
      } else {
        if (_menuIdx == 0) {
          await _player.setSubtitleTrack(SubtitleTrack.no());
        } else {
          final l = _pistasSubs;
          final i = _menuIdx - 1;
          if (i >= 0 && i < l.length) await _player.setSubtitleTrack(l[i]);
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  String _etiqueta(String? titulo, String? idioma, String id) {
    final partes = [
      if (titulo != null && titulo.trim().isNotEmpty) titulo.trim(),
      if (idioma != null && idioma.trim().isNotEmpty) idioma.trim(),
    ];
    return partes.isEmpty ? 'Pista $id' : partes.join(' · ');
  }

  // ── Mando ────────────────────────────────────────────────────────────────
  bool _manejarAtras() {
    if (_menuAbierto) {
      setState(() => _menuAbierto = false);
      _mostrarControles();
      return true;
    }
    if (_controlesVisibles) {
      setState(() => _controlesVisibles = false);
      return true;
    }
    // ATRAS SALE A LA PRIMERA.
    //
    // Antes pedia dos pulsaciones, para que un roce no te sacara de la
    // pelicula. Pero con el mando en la mano no hay roces —hay que apuntar y
    // pulsar—, asi que la proteccion no protegia de nada y si obligaba a
    // pulsar dos veces cada vez que querias salir. Y donde se vuelve es al
    // catalogo, con la posicion guardada: salir no cuesta nada.
    return false;
  }

  KeyEventResult _tecla(FocusNode node, KeyEvent evento) {
    final k = evento.logicalKey;

    // ── MANTENER LA FLECHA ADELANTA ────────────────────────────────────
    //
    // Solo se atendia `KeyDownEvent`, o sea la pulsacion suelta: cada toque
    // eran 10 segundos y adelantar veinte minutos salian 120 toques. Por eso
    // moverse por la pelicula era una tortura.
    //
    // `KeyRepeatEvent` es lo que llega al DEJAR la flecha apretada. Se atiende
    // solo para las flechas de la linea de tiempo: repetir "OK" o "atras"
    // mantenidos no significa nada bueno.
    final esFlecha =
        k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight;
    if (evento is KeyRepeatEvent && esFlecha && !_menuAbierto) {
      if (_foco == 0 || _foco == 1) {
        // Los controles siguen a la vista mientras se recorre. Sin esto, el
        // temporizador de 5s no se refrescaba y la linea de tiempo
        // desaparecia justo mientras la estabas usando.
        _mostrarControles();
        _saltar(k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
        return KeyEventResult.handled;
      }
    }
    if (evento is! KeyDownEvent) return KeyEventResult.ignored;

    final ok =
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA;

    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      if (_manejarAtras()) return KeyEventResult.handled;
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    // ── Selector de pistas ────────────────────────────────────────────────
    if (_menuAbierto) {
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight) {
        setState(() {
          _menuTab = _menuTab == 0 ? 1 : 0;
          _menuIdx = _indiceActual(_menuTab);
        });
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        if (_menuIdx > 0) setState(() => _menuIdx--);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        if (_menuIdx < _menuLargo - 1) setState(() => _menuIdx++);
        return KeyEventResult.handled;
      }
      if (ok) {
        unawaited(_aplicarPista());
        setState(() {
          _menuAbierto = false;
          _foco = 0; // elegida la pista, lo siguiente es seguir viendo
        });
        _mostrarControles();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.mediaPlayPause) {
      _alternarReproduccion();
      _mostrarControles();
      return KeyEventResult.handled;
    }

    // La primera pulsación con los controles ocultos solo los revela.
    final estaban = _controlesVisibles;
    _mostrarControles();
    if (!estaban) return KeyEventResult.handled;

    // ── Línea de tiempo ───────────────────────────────────────────────────
    if (_foco == 1) {
      if (k == LogicalKeyboardKey.arrowLeft) {
        _saltar(-1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        _saltar(1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        _aplicarSalto();
        setState(() => _foco = 0);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        _aplicarSalto();
        setState(() => _foco = 2);
        return KeyEventResult.handled;
      }
      if (ok) {
        _aplicarSalto();
        setState(() => _foco = 0);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Iconos de pistas ──────────────────────────────────────────────────
    if (_foco == 2 || _foco == 3) {
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight) {
        setState(() => _foco = _foco == 2 ? 3 : 2);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        setState(() => _foco = 1);
        return KeyEventResult.handled;
      }
      // Abajo da la vuelta al play: volver a reproducir es lo que se quiere
      // casi siempre después de pasar por aquí.
      if (k == LogicalKeyboardKey.arrowDown) {
        setState(() => _foco = 0);
        return KeyEventResult.handled;
      }
      if (ok) {
        _abrirMenu(_foco == 2 ? 1 : 0);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Botón de play ─────────────────────────────────────────────────────
    if (k == LogicalKeyboardKey.arrowLeft) {
      _saltar(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _saltar(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _foco = 1);
      return KeyEventResult.handled;
    }
    if (ok) {
      _alternarReproduccion();
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progreso =
        _duracion.inMilliseconds <= 0
            ? 0.0
            : (_posicion.inMilliseconds / _duracion.inMilliseconds).clamp(
              0.0,
              1.0,
            );

    // Asegurar que el foco esté en NUESTRO nodo, no en el del widget Video
    // de media_kit. Sin esto el Video reclama el foco, nuestro onKeyEvent
    // deja de recibir las teclas, y el framework las propaga a la ruta de
    // debajo (TvDetailScreen) — que actúa sobre ellas y navega a otro
    // contenido o hace cosas del detalle mientras se ve el reproductor.
    // En el `Overlay` NO se reclama el foco. Mientras la vista previa está
    // pequeña, el foco pertenece a la ficha —es ella quien navega— y robárselo
    // dejaría al usuario sin poder moverse por la pantalla que está viendo.
    // Estando en grande, las teclas se las pasa a mano quien lo montó.
    if (!_enOverlay &&
        !_playerFocusNode.hasFocus &&
        !_playerFocusNode.hasPrimaryFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playerFocusNode.requestFocus();
      });
    }

    // Al vivir en el `Overlay`, este widget no se reconstruye al navegar: hay
    // que escuchar el cambio de tamaño para que los controles aparezcan y
    // desaparezcan.
    if (_enOverlay) {
      return ValueListenableBuilder<bool>(
        valueListenable: widget.expandido!,
        builder: (_, _, _) => _cuerpo(progreso),
      );
    }

    final cuerpo = _cuerpo(progreso);

    // En el `Overlay` se devuelve el cuerpo pelado: ni `PopScope` (no hay
    // `ModalRoute` a la que engancharse) ni `Focus` propio (lo tiene la ficha).
    if (_enOverlay) return cuerpo;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (hecho, _) {
        if (hecho) return;
        if (!_manejarAtras()) Navigator.of(context).pop();
      },
      child: FocusScope(
        autofocus: true,
        child: Focus(
          focusNode: _playerFocusNode,
          autofocus: true,
          onKeyEvent: _tecla,
          child: cuerpo,
        ),
      ),
    );
  }

  Widget _cuerpo(double progreso) {
    return LayoutBuilder(
      builder: (context, restricciones) {
        // ── NO BASTA CON QUE ESTE "EN GRANDE" ─────────────────────────────
        //
        // Al pulsar, `expandido` se pone a `true` de inmediato pero el
        // rectangulo tarda 260 ms en llegar a la pantalla entera. En ese rato
        // los controles ya se estan pintando dentro de una caja de 360 px:
        // la barra del titulo no cabe y desborda 53 px, que es el aviso del
        // log.
        //
        // Midiendo el ancho de verdad, los controles esperan a que haya sitio.
        // Aparecen al terminar la transicion, que ademas es donde tienen
        // sentido.
        final grande = _grande && restricciones.maxWidth > 700;
        return _pantalla(progreso, grande);
      },
    );
  }

  Widget _pantalla(double progreso, bool grande) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: Video(
              controller: _controlador,
              controls: NoVideoControls,
              // EN PEQUEÑO LLENA EL RECUADRO; EN GRANDE, NO.
              //
              // Por defecto el vídeo se ajusta entero (`contain`), así que si
              // su proporción no es la del hueco deja franjas negras — el
              // recuadro de la ficha se veía a medio ocupar.
              //
              // Ahí `cover` es lo correcto: es una vista previa, se recorta un
              // poco por los lados y llena el hueco. A pantalla completa se
              // vuelve a `contain`, porque recortar una película para que
              // cuadre con el televisor sí sería quitarle imagen al usuario.
              fit: grande ? BoxFit.contain : BoxFit.cover,
            ),
          ),

          // MISMO SPINNER Y MISMA CONDICION QUE EL RECEPTOR.
          //
          // Antes era el `CircularProgressIndicator` de Material y solo
          // con `_buffering`. Entre que MPV deja de bufferear y llega la
          // imagen hay un hueco, y ahi la pantalla se quedaba negra y
          // vacia: parecia colgada. Con `!_primerFrameListo` el spinner
          // cubre tambien ese tramo.
          // El spinner, mientras haya algo que esperar. Si ya no queda
          // servidor, esperar es mentir: se dice lo que pasa.
          if (_cargando && !_agotado)
            Center(
              // Se queda también en pequeño —es lo que explica por qué el
              // recuadro está negro— pero a escala: 54 px dentro de
              // 360 x 203 lo llenan entero.
              child: TvLoadingAnimation(
                size: grande ? 54 : 30,
                strokeWidth: grande ? 4 : 2.5,
              ),
            ),

          // ── Se acabaron los servidores ────────────────────────────
          //
          // Antes esto era un bucle silencioso: "Cambiando de servidor"
          // una y otra vez sobre negro, sin final. Un mensaje claro y la
          // salida a mano valen mas que un intento numero cuarenta.
          // En pequeño solo el icono: el mensaje entero son 54 px de icono
          // más dos textos, y en un recuadro de 203 de alto no entra —
          // desbordaba 19 px. El icono ya dice que algo va mal, y quien
          // quiera el detalle lo tiene al abrirlo en grande.
          if (_agotado && !grande)
            const Center(
              child: Icon(
                Icons.cloud_off_rounded,
                color: Colors.white38,
                size: 34,
              ),
            ),

          if (_agotado && grande)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 80),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_off_rounded,
                      color: Colors.white38,
                      size: 54,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _urls.length > 1
                          ? 'Ninguno de los ${_urls.length} servidores '
                              'pudo reproducir este título'
                          : 'El servidor no pudo reproducir este título',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Pulsa atrás para volver e inténtalo más tarde.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),

          // Velocidad de descarga, arriba a la izquierda. Sale cuando
          // ACOMPAÑA a algo: mientras carga, o con los controles abiertos.
          // Se avisa de que se reanudo, pero no se pregunta. Enterarse
          // es util; tener que decidir con el mando, no.
          if (grande && _reanudadoDesde != null && _controlesVisibles)
            Positioned(
              top: 44,
              left: 56,
              child: Text(
                'Reanudado desde ${_fmt(_reanudadoDesde!)}',
                style: const TextStyle(color: Colors.white54, fontSize: 15),
              ),
            ),

          // ── Play, SOLO EN PAUSA ─────────────────────────────────
          //
          // Es lo que hace el receptor, y tenia razon de ser: no es un
          // control permanente sino un "dale para seguir". Mientras se
          // reproduce no pinta nada en mitad de la pantalla; en cuanto
          // pausas, aparece y dice que hacer.
          //
          // Yo lo habia quitado del todo al malinterpretar que no debia
          // salir "ahi" — no salia SIEMPRE, que es distinto.
          if (grande &&
              !_reproduciendo &&
              !_buffering &&
              _primerFrameListo &&
              !_menuAbierto)
            const Center(child: _BotonEsfera()),

          if (grande && _controlesVisibles && !_menuAbierto)
            _Controles(
              titulo: widget.titulo,
              caratula: widget.item.logo,
              posicion: _posicion,
              duracion: _duracion,
              bufer: _bufer,
              progreso: progreso,
              reproduciendo: _reproduciendo,
              foco: _foco,
              fmt: _fmt,
            ),

          if (grande && _menuAbierto)
            _MenuPistas(
              tab: _menuTab,
              indice: _menuIdx,
              audio: [
                for (final t in _pistasAudio)
                  _etiqueta(t.title, t.language, t.id),
              ],
              subtitulos: [
                'Desactivados',
                for (final t in _pistasSubs)
                  _etiqueta(t.title, t.language, t.id),
              ],
              audioActivo: _indiceActual(0),
              subtituloActivo: _indiceActual(1),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Controles inferiores
// ═══════════════════════════════════════════════════════════════════════════
/// El botón de play del centro: la misma esfera roja del receptor.
///
/// Estaba "parecida" y no igual: le faltaba el brillo especular —la chispa
/// blanca de arriba a la izquierda, que es lo que hace que se lea como una
/// esfera y no como un circulo plano— y el icono iba a 40 en vez de 46.
///
/// Copiado de `_CtrlButton` del receptor a proposito: transmitir desde el
/// telefono y ver desde el propio televisor tienen que verse igual, porque
/// para quien mira son la misma app.
class _BotonEsfera extends StatelessWidget {
  const _BotonEsfera();

  static const double _tamano = 72;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _tamano,
      height: _tamano,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: Alignment(-0.4, -0.5),
          radius: 1.2,
          colors: [
            Color(0xFFFF6B5E), // luz cálida arriba-izquierda
            Color(0xFFE53935), // rojo principal
            Color(0xFFB71C1C), // rojo profundo en el borde
          ],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // El brillo especular: la "chispa" blanca de la esfera.
          Positioned(
            top: _tamano * 0.13,
            left: _tamano * 0.22,
            child: Container(
              width: _tamano * 0.26,
              height: _tamano * 0.15,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_tamano),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.85),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 46),
        ],
      ),
    );
  }
}

class _Controles extends StatelessWidget {
  final String titulo;
  final String? caratula;
  final Duration posicion;
  final Duration duracion;
  final Duration bufer;
  final double progreso;
  final bool reproduciendo;
  final int foco;
  final String Function(Duration) fmt;

  const _Controles({
    required this.titulo,
    required this.caratula,
    required this.posicion,
    required this.duracion,
    required this.bufer,
    required this.progreso,
    required this.reproduciendo,
    required this.foco,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final enBarra = foco == 1;

    // Fraccion cargada. El `buffer` de MPV es la posicion ABSOLUTA hasta donde
    // hay datos, no una duracion, asi que se divide igual que la posicion.
    // Nunca por detras de lo ya reproducido: si el bufer se vacia, la pista
    // secundaria se esconde bajo la principal en vez de dibujarse al reves.
    final double cargado =
        duracion.inMilliseconds > 0
            ? (bufer.inMilliseconds / duracion.inMilliseconds).clamp(
              progreso,
              1.0,
            )
            : 0.0;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
          stops: [0.0, 0.55],
        ),
      ),
      // Mismas medidas que el receptor: 40 a la izquierda, 48 a la derecha,
      // 36 abajo. Si no coinciden, la misma pelicula se ve descolocada segun
      // como la hayas abierto.
      padding: const EdgeInsets.fromLTRB(40, 0, 48, 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // SIN BOTON DE PLAY FLOTANTE.
          //
          // El receptor no lo tiene, y con razon: al transmitir se pausa desde
          // el telefono, y aqui se pausa con OK sobre la linea de tiempo. Un
          // circulo rojo en mitad de la pantalla tapa el video y no aporta nada
          // que el mando no haga ya.
          // ── Carátula a la izquierda, línea de tiempo y título a la
          // derecha ── Es la disposición del receptor, y estaba sin replicar:
          // al transmitir salía la carátula y al abrir desde el catálogo no,
          // así que la misma película se veía de dos formas distintas.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (caratula != null && caratula!.isNotEmpty) ...[
                Image.network(
                  caratula!,
                  width: 90,
                  height: 130,
                  fit: BoxFit.cover,
                  cacheWidth: 180,
                  cacheHeight: 260,
                  // Si la carátula falla no se deja hueco: mejor sin ella que
                  // con un rectángulo vacío.
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                const SizedBox(width: 24),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // La barra NO se pinta hasta saber la duracion.
                    //
                    // Mismo criterio que el receptor y que el telefono: un
                    // "00:00 / 00:00" no se lee como "cargando", se lee como
                    // "esto dura cero". `maintainSize` reserva el alto para
                    // que el titulo de debajo no pegue un salto al aparecer.
                    // La barra se pinta SIEMPRE, tambien mientras carga.
                    //
                    // Antes se escondia hasta saber la duracion, para no
                    // enseñar un "00:00 / 00:00". Pero esconderla sale mas
                    // caro: al pulsar el mando durante la carga no habia linea
                    // de tiempo y la pantalla parecia otra. Que ponga ceros un
                    // momento se entiende; que el control desaparezca y vuelva,
                    // no.
                    Row(
                      children: [
                        Text(
                          fmt(posicion),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, c) {
                              const alto = 6.0;
                              const tirador = 20.0;
                              final x = c.maxWidth * progreso;
                              return SizedBox(
                                height: 28,
                                child: Stack(
                                  alignment: Alignment.centerLeft,
                                  children: [
                                    // Pista vacia.
                                    Container(
                                      height: alto,
                                      decoration: BoxDecoration(
                                        color: Colors.white24,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                    // Pista de BUFER: por debajo de la
                                    // reproducida, para que esta la tape. Mas
                                    // opaca que la vacia y mas tenue que el
                                    // acento, igual que el receptor. Faltaba
                                    // aqui, y es lo que dice si el video esta
                                    // cargando o parado.
                                    FractionallySizedBox(
                                      alignment: Alignment.centerLeft,
                                      widthFactor: cargado,
                                      child: Container(
                                        height: alto,
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.45,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Lo reproducido: BLANCO, no rojo.
                                    //
                                    // El receptor lo pinta en blanco y aqui
                                    // iba en rojo: la misma pelicula se veia
                                    // distinta segun la hubieras abierto desde
                                    // el catalogo o transmitido. El rojo se
                                    // queda para el tirador y el boton de
                                    // play, que son los controles.
                                    //
                                    // Sin foco se apaga un poco: es la marca
                                    // que sustituye al cambio de grosor, que
                                    // haria "saltar" la barra al entrar y
                                    // salir el foco.
                                    FractionallySizedBox(
                                      alignment: Alignment.centerLeft,
                                      widthFactor: progreso,
                                      child: Container(
                                        height: alto,
                                        decoration: BoxDecoration(
                                          color:
                                              enBarra
                                                  ? Colors.white
                                                  : Colors.white.withValues(
                                                    alpha: 0.6,
                                                  ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: (x - tirador / 2).clamp(
                                        0.0,
                                        (c.maxWidth - tirador).clamp(
                                          0.0,
                                          double.infinity,
                                        ),
                                      ),
                                      child: AnimatedOpacity(
                                        duration: const Duration(
                                          milliseconds: 150,
                                        ),
                                        opacity: enBarra ? 1.0 : 0.5,
                                        child: Container(
                                          width: tirador,
                                          height: tirador,
                                          decoration: const BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: RadialGradient(
                                              center: Alignment(-0.4, -0.5),
                                              radius: 1.2,
                                              colors: [
                                                Color(0xFFFF6B5E),
                                                Color(0xFFE53935),
                                                Color(0xFFB71C1C),
                                              ],
                                              stops: [0.0, 0.55, 1.0],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 18),
                        Text(
                          fmt(duracion),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Título a la izquierda, pistas a la derecha, en la misma línea.
                    //
                    // `Expanded` Y NO `Flexible`: el título se queda con todo
                    // el hueco sobrante y EMPUJA las pistas contra el borde
                    // derecho, que es donde van.
                    //
                    // Lo probé con `Flexible` para atajar un desbordamiento, y
                    // el efecto fue que el título encogía a su ancho natural y
                    // "Subtítulos" y "Audio" se le pegaban al lado, en medio
                    // de la barra. El desbordamiento venía de otro sitio —los
                    // controles se estaban dibujando en la vista previa de
                    // 360 px— y ya está resuelto ahí.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            titulo,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                            ),
                          ),
                        ),
                        const SizedBox(width: 28),
                        _IconoPista(
                          icon: Icons.subtitles_outlined,
                          etiqueta: 'Subtítulos',
                          focused: foco == 2,
                        ),
                        const SizedBox(width: 26),
                        _IconoPista(
                          icon: Icons.multitrack_audio_rounded,
                          etiqueta: 'Audio',
                          focused: foco == 3,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Mismo criterio que en el receptor: el foco es solo color, nunca tamaño.
class _IconoPista extends StatelessWidget {
  final IconData icon;
  final String etiqueta;
  final bool focused;

  const _IconoPista({
    required this.icon,
    required this.etiqueta,
    required this.focused,
  });

  @override
  Widget build(BuildContext context) {
    final color = focused ? Colors.white : Colors.white54;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 7),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 130),
          style: TextStyle(
            color: color,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          child: Text(etiqueta),
        ),
      ],
    );
  }
}

/// Las dos listas a la vez, sin caja. Igual que en el receptor.
class _MenuPistas extends StatelessWidget {
  final int tab;
  final int indice;
  final List<String> audio;
  final List<String> subtitulos;
  final int audioActivo;
  final int subtituloActivo;

  const _MenuPistas({
    required this.tab,
    required this.indice,
    required this.audio,
    required this.subtitulos,
    required this.audioActivo,
    required this.subtituloActivo,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 560),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Columna(
                titulo: 'AUDIO',
                filas: audio,
                seleccionada: audioActivo,
                enfocada: tab == 0,
                indiceFoco: indice,
              ),
            ),
            const SizedBox(width: 36),
            Expanded(
              child: _Columna(
                titulo: 'SUBTÍTULOS',
                filas: subtitulos,
                seleccionada: subtituloActivo,
                enfocada: tab == 1,
                indiceFoco: indice,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Columna extends StatelessWidget {
  final String titulo;
  final List<String> filas;
  final int seleccionada;
  final bool enfocada;
  final int indiceFoco;

  const _Columna({
    required this.titulo,
    required this.filas,
    required this.seleccionada,
    required this.enfocada,
    required this.indiceFoco,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          titulo,
          style: TextStyle(
            color: enfocada ? Colors.white : Colors.white24,
            fontSize: 15,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 20),
        if (filas.isEmpty)
          Text(
            'No hay',
            style: TextStyle(
              color: enfocada ? Colors.white38 : Colors.white24,
              fontSize: 18,
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: filas.length,
              itemBuilder: (context, i) {
                final foco = enfocada && i == indiceFoco;
                final puesta = i == seleccionada;
                final Color color;
                if (foco) {
                  color = Colors.white;
                } else if (!enfocada) {
                  color = Colors.white24;
                } else {
                  color = puesta ? Colors.white70 : Colors.white54;
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        child:
                            puesta
                                ? Icon(
                                  Icons.check_rounded,
                                  size: 18,
                                  color: color,
                                )
                                : null,
                      ),
                      Expanded(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 120),
                          style: TextStyle(
                            color: color,
                            fontSize: 18,
                            fontWeight:
                                foco ? FontWeight.w600 : FontWeight.w400,
                          ),
                          child: Text(
                            filas[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
