import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../services/tv/tv_protocol.dart';
import '../../services/tv/tv_receiver_service.dart';

/// Pantalla receptora que corre en el TV. Es dueña del [Player] de media_kit
/// (el MISMO motor MPV que el teléfono) y ejecuta los comandos que llegan por
/// el WebSocket a través de [TvReceiverService].
///
/// Empuja estado (posición/duración/estado/pistas) al teléfono ~2 veces por
/// segundo. Cuando no hay media, muestra una pantalla de espera con el nombre
/// del dispositivo.
///
/// NOTA: los controles con control remoto (D-pad) se añaden en la Fase 3.
class TvReceiverScreen extends StatefulWidget {
  const TvReceiverScreen({super.key});

  @override
  State<TvReceiverScreen> createState() => _TvReceiverScreenState();
}

class _TvReceiverScreenState extends State<TvReceiverScreen> {
  final TvReceiverService _service = TvReceiverService();

  // ── IMPORTANTE (error crítico #1 y #3 del brief) ──────────────────────────
  // No forzamos vo=gpu ni profile=fast: media_kit crea su propio video output
  // sobre una Surface; forzar vo=gpu hace ABORTAR a libmpv en Android.
  // Buffer moderado (24-32MB) para TVs con ~1GB de RAM.
  late final Player _player = Player(
    configuration: PlayerConfiguration(
      title: 'Bump Comba TV',
      bufferSize: 32 * 1024 * 1024, // 32 MB — moderado para TVs de gama baja
      // En debug subimos a `info` para que MPV diga POR QUE se queda en
      // buffering: el spinner eterno del televisor no deja rastro en el log de
      // Flutter, solo `buffering=true @0s` y silencio. En release se queda en
      // `error` para no gastar CPU del TV escribiendo lineas.
      logLevel: kDebugMode ? MPVLogLevel.info : MPVLogLevel.error,
      // libass en FALSE a propósito: el widget Video de media_kit solo
      // renderiza subtítulos con su SubtitleView Flutter cuando libass está
      // apagado. Con libass, MPV intenta dibujarlos nativamente sobre la
      // Surface de Android y NO SE VEN (mismo motivo por el que el teléfono
      // usa un overlay Flutter propio). Además, sin libass es más liviano
      // para la GPU del TV.
      libass: false,
    ),
  );
  // hwdec va AQUÍ y no en setProperty: AndroidVideoController.create() aplica
  // su propia configuración DESPUÉS de la nuestra y con 'auto-safe' este SoC
  // (Amlogic) elige mediacodec-copy → modo ByteBuffer → una copia por CPU de
  // cada frame 1080p (los errores mali_gralloc del log) → tirones.
  // 'mediacodec' fuerza decodificación DIRECTA a la Surface (zero-copy).
  late final VideoController _videoController = VideoController(
    _player,
    configuration: const VideoControllerConfiguration(
      enableHardwareAcceleration: true,
      hwdec: 'mediacodec',
    ),
  );

  final List<StreamSubscription> _subs = [];
  StreamSubscription? _commandSub;
  Timer? _statusTimer;

  bool _hasMedia = false;
  bool _buffering = false;

  /// true cuando la capa nativa ya pintó un frame de verdad a la textura.
  ///
  /// Hace falta porque MPV emite `buffering=false` en cuanto ABRE el archivo,
  /// mucho antes de tener imagen. Con solo `_buffering` el spinner se apagaba
  /// ahí, el widget `Video` todavía no tenía nada que pintar, y el televisor se
  /// quedaba en negro sin ninguna señal de que estuviera cargando.
  bool _primerFrameListo = false;

  /// Posicion de la muestra anterior de `_pushStatus`, para detectar avance
  /// real. `null` justo despues de un LOAD: la primera muestra del contenido
  /// nuevo solo sirve de referencia, no se compara con la del anterior.
  Duration? _posAnterior;

  // ── Pregunta en pantalla (cmdAsk) ────────────────────────────────────────
  //
  // El telefono pide mostrar una decision al usuario. Se responde con el mando,
  // que es donde esta el usuario cuando transmite.
  // ── Menu de pistas (audio / subtitulos) con el mando ──────────────────────
  //
  // Hasta ahora las pistas solo se podian cambiar desde el telefono, aunque el
  // receptor ya sabia hacerlo (`cmdSetAudio` / `cmdSetSubtitle`). Quien esta
  // viendo la tele tiene el mando en la mano, no el movil.
  /// Momento del ultimo "atras". Con el se exige pulsarlo DOS veces seguidas
  /// para salir: en un mando, el boton de atras esta pegado al de navegacion y
  /// se roza sin querer — perder la pelicula por eso es de las cosas que mas
  /// molestan, y ademas en el televisor volver a entrar cuesta bastante.
  DateTime? _ultimoAtras;

  /// Se esta mostrando el aviso de "pulsa atras otra vez para salir".
  bool _avisoSalir = false;

  Timer? _avisoSalirTimer;

  bool _menuAbierto = false;
  int _menuTab = 0; // 0 = audio, 1 = subtitulos
  int _menuIdx = 0;

  Map<String, String>? _pregunta;
  bool _preguntaSiEnfocado = true;
  Timer? _preguntaTimer;
  int _preguntaSegundos = 0;

  void _onRectCambio() {
    final r = _videoController.rect.value;
    final listo = r != null && r.width > 0 && r.height > 0;
    if (listo && !_primerFrameListo && mounted) {
      // MEDICION: cuanto tardo la imagen nueva desde que llego el LOAD.
      //
      // Ojo al interpretarlo: este listener SOLO se dispara cuando cambia la
      // resolucion respecto al contenido anterior (media_kit sale antes si son
      // iguales, ver la nota larga en _pushStatus). Asi que este numero
      // aparece a veces, no siempre, y cuando aparece es el bueno: el retraso
      // real del decodificador en entregar la textura en este televisor.
      debugPrint(
        'TvReceiver: MEDIDA primer frame real a los '
        '${DateTime.now().difference(_lastLoadAt).inMilliseconds}ms '
        '(${r.width.toInt()}x${r.height.toInt()})',
      );
      setState(() => _primerFrameListo = true);
    }
  }

  String _deviceName = 'Bump Comba TV';

  // Metadatos del contenido actual (llegan en el LOAD desde el teléfono).
  String _mediaTitle = '';
  String? _mediaThumb;

  // ── Estado de los controles con control remoto (D-pad) ──
  final FocusNode _focusNode = FocusNode();
  bool _controlsVisible = false;
  Timer? _hideControlsTimer;

  // Área con foco: 0 = botón play/pausa, 1 = línea de tiempo.
  int _focusArea = 0;

  // Posición/duración para pintar el overlay (actualizadas por streams).
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// Hasta donde hay datos descargados por delante. Es la pista mas opaca de
  /// la barra, estilo YouTube: le dice al usuario hasta donde puede adelantar
  /// sin que el contenido se pare a cargar.
  Duration _buffered = Duration.zero;
  bool _playing = false;

  // Vista previa de la línea de tiempo: el seek real se aplica con debounce.
  bool _previewing = false;
  Duration _previewPos = Duration.zero;
  Timer? _seekDebounce;

  // Auto-avance: suprimir `completed` espurio de MPV justo tras un LOAD.
  // (error crítico #10 del brief)
  DateTime _lastLoadAt = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _speedPollTimer;
  double _downloadSpeedKbps = 0.0;

  @override
  void initState() {
    super.initState();
    _deviceName = _service.deviceName;
    _configureMpv();
    _startService();
    _listenPlayer();
    _startStatusPush();
    _startSpeedPolling();
    WakelockPlus.enable();
  }

  Future<void> _configureMpv() async {
    // Solo propiedades SEGURAS en Android (nunca vo=gpu / profile=fast).
    // Optimizado para FLUIDEZ máxima en TVs de gama baja (Chromecast HD,
    // TV boxes con ~1GB RAM y SoC débil).
    try {
      final mpv = _player.platform as dynamic;
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
          debugPrint('TvReceiver: MPV rechazo ${e.key}=${e.value} -> $err');
        }
      }
    } catch (e) {
      debugPrint('TvReceiver: error configurando MPV: $e');
    }
  }

  Future<void> _startService() async {
    try {
      await _service.start(name: _deviceName);
    } catch (e) {
      debugPrint('TvReceiver: no se pudo arrancar el servicio: $e');
    }
    _commandSub = _service.commands.listen(_onCommand);
    _service.hasClient.addListener(_onClientChanged);
  }

  void _onClientChanged() {
    if (!mounted) return;
    // Al (re)conectar un cliente, empuja el estado actual de inmediato para
    // que ambos lados queden en sync al instante.
    _pushStatus();
    _pushTracks();
  }

  // ─────────────────────────── Comandos entrantes ────────────────────────────

  /// Envuelve TODO comando en try/catch (error crítico #12): una excepción de
  /// media_kit/socket no debe tumbar el proceso del receptor.
  Future<void> _onCommand(Map<String, dynamic> msg) async {
    final type = msg[TvProto.kType] as String?;
    try {
      switch (type) {
        case TvProto.cmdLoad:
          await _handleLoad(msg);
          break;
        case TvProto.cmdPlay:
          await _player.play();
          _pushStatus();
          break;
        case TvProto.cmdPause:
          await _player.pause();
          _pushStatus();
          break;
        case TvProto.cmdSeek:
          final pos = _asDouble(msg['position']);
          if (pos != null) {
            await _player.seek(Duration(milliseconds: (pos * 1000).round()));
            _pushStatus();
          }
          break;
        case TvProto.cmdStop:
          await _handleStop();
          break;
        case TvProto.cmdSetAudio:
          final id = msg['trackId']?.toString();
          if (id != null) {
            await _player.setAudioTrack(AudioTrack(id, null, null));
          }
          break;
        case TvProto.cmdSetSubtitle:
          final id = msg['trackId']?.toString();
          if (id == null || id == TvProto.subtitleOff) {
            await _player.setSubtitleTrack(SubtitleTrack.no());
          } else {
            await _player.setSubtitleTrack(SubtitleTrack(id, null, null));
          }
          break;
        case TvProto.cmdPing:
          _service.sendEvent(TvProto.evtPong, {'t': msg['t']});
          break;
        case TvProto.cmdGetTracks:
          _pushTracks();
          break;
      }
    } catch (e) {
      debugPrint('TvReceiver: error ejecutando $type: $e');
    }
  }

  Future<void> _handleLoad(Map<String, dynamic> msg) async {
    // Contenido nuevo, cuenta nueva: la corrupcion del anterior no
    // puede condenar a este.
    _eventosCorrupcion.clear();
    final url = msg['url']?.toString();
    if (url == null || url.isEmpty) {
      _service.sendEvent(TvProto.evtLoadFailed, {'error': 'url vacía'});
      return;
    }
    final position = _asDouble(msg['position']) ?? 0.0;
    final headers = _asStringMap(msg['headers']);
    final subtitulosExternos = _asSubtitleList(msg['subtitles']);
    _mediaTitle = msg['title']?.toString() ?? '';
    final thumb = msg['thumbnailUrl']?.toString();
    _mediaThumb = (thumb == null || thumb.isEmpty) ? null : thumb;

    // Que URL llega EXACTAMENTE al televisor. Es el dato que separa las dos
    // hipotesis del corte prematuro: si es un .m3u8 el problema es la lista de
    // segmentos agotandose, y si es un archivo directo es el proveedor.
    debugPrint(
      'TvReceiver: LOAD url=$url pos=${position.toStringAsFixed(0)}s '
      'live=${msg['isLive'] == true}',
    );

    _lastLoadAt = DateTime.now();
    if (mounted) {
      setState(() {
        _hasMedia = true;
        _buffering = true;
        // Cada LOAD empieza sin imagen: el spinner se mantiene hasta que
        // llegue el primer frame del contenido NUEVO, no del anterior.
        _primerFrameListo = false;
        _posAnterior = null;
        _buffered = Duration.zero;
      });
    }
    try {
      final bool isFromDB = msg['isFromDB'] == true;
      final bool isLive = msg['isLive'] == true;
      try {
        final mpv = _player.platform as dynamic;
        if (mpv != null) {
          // ── DIRECTO / HLS ────────────────────────────────────────────────
          //
          // El perfil de arriba (`_configureMpv`) esta pensado para VOD: 90s de
          // lectura adelantada y 120s de cache. Contra una lista HLS eso es
          // contraproducente — solo hay unos pocos segmentos publicados, asi
          // que MPV choca contra el final de la lista una y otra vez, y de ahi
          // salian el `End of file` repetido, los cortes cada pocos segundos y
          // el `completed` prematuro que hacia recargar al telefono.
          //
          // Son los mismos valores que el reproductor del telefono usa para
          // directo, que es donde el mismo titulo se ve bien. Todos BAJAN
          // respecto al perfil VOD, asi que no tocan el techo del VPS.
          if (isLive) {
            await mpv.setProperty('cache-secs', '60');
            await mpv.setProperty('demuxer-readahead-secs', '20');
            await mpv.setProperty('hls-bitrate', 'auto');
            await mpv.setProperty('hls-forward-cache-secs', '30');
            await mpv.setProperty('hls-back-cache-secs', '10');
            // En directo no se puede acumular bufer por adelantado sin quedarse
            // atras de la emision: se arranca en cuanto hay datos.
            await mpv.setProperty('cache-pause-initial', 'no');
            await mpv.setProperty('cache-pause-wait', '2');
            await mpv.setProperty('demuxer-cache-wait', 'no');
          } else {
            // VOD: se restauran los valores del perfil de arranque, por si el
            // contenido anterior era un directo y los dejo bajados.
            await mpv.setProperty('cache-secs', '120');
            await mpv.setProperty('demuxer-readahead-secs', '90');
            await mpv.setProperty('cache-pause-initial', 'yes');
            await mpv.setProperty('cache-pause-wait', '4');
          }

          if (isFromDB) {
            // Contenido de la base de datos: máxima calidad HD, suavizado de bordes pixelados en luz lineal y deblocking por hardware
            await mpv.setProperty('hls-bitrate', 'max');
            await mpv.setProperty('scale', 'mitchell');
            await mpv.setProperty('cscale', 'mitchell');
            await mpv.setProperty('linear-upscale', 'yes');
            await mpv.setProperty('deband', 'no');
            // Forzar deblocking de hardware (elimina macrobloques pixelados 720p en el decodificador H.264 a 60 FPS)
            await mpv.setProperty('vd-lavc-skiploopfilter', 'none');
            await mpv.setProperty('sws-scaler', 'bicubic');
          } else {
            // Canales IPTV normales: optimizado para evitar cortes en TV
            await mpv.setProperty('hls-bitrate', 'min');
            await mpv.setProperty('scale', 'bilinear');
            await mpv.setProperty('deband', 'no');
          }
        }
      } catch (_) {}

      // `start:` y no abrir-en-0-y-saltar-despues.
      //
      // MPV abre DIRECTAMENTE en esa posicion, asi que la primera peticion al
      // origen (o a TurboProxy) ya lleva el Range correcto. Abriendo en 0 y
      // buscando luego, el demuxer se traga la cabecera, empieza a bajar desde
      // el principio y solo entonces salta — y con una reanudacion a los 97
      // minutos de un archivo de 2,3 GB eso es carisimo. Es lo que ya hace el
      // reproductor del telefono.
      //
      // `_seekWhenReady` se queda como red por si la posicion real acaba lejos
      // del objetivo, pero en el camino normal ya no tiene nada que corregir.
      final inicio =
          position > 0
              ? Duration(milliseconds: (position * 1000).round())
              : null;
      await _player.open(
        Media(url, httpHeaders: headers, start: inicio),
        play: true,
      );

      // ── Subtitulos EXTERNOS del contenido de la base de datos ────────────
      //
      // `_pushTracks()` publica `_player.state.tracks.subtitle`, que solo trae
      // las pistas INCRUSTADAS en el archivo. Los subtitulos de la BD son
      // ficheros VTT/SRT con URL propia, asi que el televisor no podia
      // descubrirlos: el menu de subtitulos salia vacio aunque en el telefono
      // se vieran bien.
      //
      // Registrarlos con `SubtitleTrack.uri` los mete en la lista de pistas de
      // MPV (sub-add), y a partir de ahi `_pushTracks()` los publica y
      // `cmdSetSubtitle` puede seleccionarlos por id como a cualquier otra.
      if (subtitulosExternos.isNotEmpty) {
        for (final sub in subtitulosExternos) {
          try {
            await _player.setSubtitleTrack(
              SubtitleTrack.uri(
                sub['url']!,
                title: sub['label'],
                language: sub['language'],
              ),
            );
          } catch (e) {
            debugPrint('TvReceiver: no se pudo añadir subtitulo externo: $e');
          }
        }
        // Registrar con `setSubtitleTrack` tambien SELECCIONA, asi que sin esto
        // el televisor arrancaria con el ultimo subtitulo de la lista puesto
        // sin que nadie lo pidiera. Quedan disponibles en el menu, apagados.
        try {
          await _player.setSubtitleTrack(SubtitleTrack.no());
        } catch (_) {}
        debugPrint(
          'TvReceiver: ${subtitulosExternos.length} subtitulo(s) externo(s) '
          'registrados',
        );
      }

      if (position > 0) {
        unawaited(
          _seekWhenReady(Duration(milliseconds: (position * 1000).round())),
        );
      }
      final int loadStamp = _lastLoadAt.millisecondsSinceEpoch;
      for (final d in const [
        Duration(seconds: 2),
        Duration(seconds: 5),
        Duration(seconds: 10),
      ]) {
        Future.delayed(d, () {
          if (mounted && _lastLoadAt.millisecondsSinceEpoch == loadStamp) {
            _pushTracks();
          }
        });
      }
      _pushStatus();
    } catch (e) {
      debugPrint('TvReceiver: LOAD falló: $e');
      if (mounted) {
        setState(() {
          _hasMedia = false;
          _buffering = false;
        });
      }
      _service.sendEvent(TvProto.evtLoadFailed, {'error': e.toString()});
    }
  }

  /// Aplica un seek de arranque de forma robusta: espera a que el demuxer
  /// reporte duración y reintenta el seek hasta que la posición quede cerca del
  /// objetivo (patrón que ya usa el reproductor del teléfono).
  Future<void> _seekWhenReady(Duration target) async {
    final int loadStamp = _lastLoadAt.millisecondsSinceEpoch;

    // Fase 1: esperar a que el demuxer conozca la duración (hasta ~60s).
    //
    // Si se agota, se ABANDONA. Antes se seguia a la fase 2 igualmente y se
    // gastaban los 6 intentos haciendo seek contra un archivo que MPV todavia
    // no habia abierto: en el log salian los seis "error running command
    // _command(seek, ...)" ANTES incluso de la linea de las pistas, y se comian
    // 3s de arranque para nada. Sin duracion no hay nada a lo que saltar.
    //
    // Perder el seek no es grave: desde que el LOAD abre con `start:`, MPV ya
    // arranca en la posicion pedida y esto es solo la red de seguridad.
    // 60s de presupuesto, no 15. Abrir un archivo de 2,3 GB en una posicion
    // avanzada a traves de TurboProxy tarda bastante mas que abrirlo en 0: en
    // el log del televisor las pistas aparecieron DESPUES de agotarse los 15s
    // viejos. Quien espera aqui no bloquea nada — la reproduccion ya arranco.
    bool hayDuracion = false;
    for (int i = 0; i < 240; i++) {
      if (!mounted) return;
      // Si llegó otro LOAD entretanto, abortamos este seek.
      if (_lastLoadAt.millisecondsSinceEpoch != loadStamp) return;
      if (_player.state.duration > Duration.zero) {
        hayDuracion = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (!hayDuracion) {
      debugPrint(
        'TvReceiver: sin duracion tras 60s — abandonando el seek de arranque',
      );
      return;
    }

    // Con `start:` en el open, lo normal es llegar aqui ya en la posicion
    // correcta y no tocar nada. Si es asi, fuera: cada seek de mas vacia el
    // decodificador y se ve como un tiron.
    if (_player.state.position >= target - const Duration(seconds: 5)) {
      debugPrint(
        'TvReceiver: el open con start: ya dejo la posicion en '
        '${_player.state.position.inSeconds}s — no hace falta seek',
      );
      return;
    }
    debugPrint(
      'TvReceiver: start: no cuajo (posicion '
      '${_player.state.position.inSeconds}s, objetivo ${target.inSeconds}s) — '
      'corrigiendo con seek',
    );

    // Fase 2: seek + reintentos hasta quedar a menos de 5s del objetivo.
    for (int attempt = 0; attempt < 6; attempt++) {
      if (!mounted || _lastLoadAt.millisecondsSinceEpoch != loadStamp) return;
      try {
        await _player.seek(target);
      } catch (e) {
        debugPrint('TvReceiver: seek de arranque falló: $e');
      }
      await Future.delayed(const Duration(milliseconds: 500));

      // Se sale en cuanto estamos EN el objetivo o ya lo pasamos.
      //
      // Antes se comparaba (position - target).abs() < 5s. Con .abs(), en
      // cuanto la reproduccion avanzaba mas de 5s por encima del objetivo la
      // diferencia CRECIA, la salida no se cumplia nunca, y los 6 intentos se
      // gastaban haciendo seek al mismo segundo. En el log del televisor se
      // veia clarisimo: la posicion real iba por 484, 505, 522... y volvia una
      // y otra vez a 404, con el decodificador vaciandose en cada salto.
      //
      // Solo se reintenta si nos quedamos CORTOS: ese es el unico fallo real
      // del seek de arranque.
      if (_player.state.position >= target - const Duration(seconds: 5)) break;
    }
    _pushStatus();
  }

  Future<void> _handleStop() async {
    _eventosCorrupcion.clear();
    try {
      await _player.stop();
    } catch (_) {}
    if (mounted) setState(() => _hasMedia = false);
    _pushStatus();
  }

  // ─────────────────────────── Listeners del player ──────────────────────────

  void _listenPlayer() {
    // El `rect` del VideoController queda en null hasta que la capa nativa
    // renderiza el primer frame de verdad a la textura. Es la única señal
    // fiable de "ya hay imagen" — el estado `buffering` de MPV se apaga mucho
    // antes. Mismo criterio que usa el reproductor del teléfono para detectar
    // pantalla negra.
    _videoController.rect.addListener(_onRectCambio);

    _subs.add(
      _player.stream.tracks.listen((_) {
        _pushTracks();
      }),
    );
    // Estado local para el overlay de controles (no pintamos si no hay overlay
    // visible para ahorrar rebuilds en TVs de gama baja).
    _subs.add(
      _player.stream.position.listen((p) {
        // Log de diagnóstico: confirmar que la reproducción AVANZA de verdad
        // (una vez por segundo entero). Distingue "reproduce" de "atascado".
        if (p.inSeconds != _position.inSeconds) {
          debugPrint(
            'TvReceiver: reproduciendo @${p.inSeconds}s '
            '(buffering=$_buffering)',
          );
        }
        _position = p;
        if (_controlsVisible && !_previewing && mounted) setState(() {});
      }),
    );
    _subs.add(
      _player.stream.duration.listen((d) {
        _duration = d;
      }),
    );
    _subs.add(
      _player.stream.buffer.listen((b) {
        _buffered = b;
        // Se repinta solo con los controles a la vista: sin esto, la barra se
        // quedaria congelada mientras el usuario tiene el video en pausa
        // mirando cuanto lleva cargado, que es justo cuando mas se mira.
        if (_controlsVisible && mounted) setState(() {});
      }),
    );
    _subs.add(
      _player.stream.playing.listen((pl) {
        final wasPlaying = _playing;
        _playing = pl;
        if (!mounted) return;
        // SIEMPRE rebuild al cambiar play/pausa: el botón central de play
        // depende de _playing. Antes solo se hacía setState en algunos
        // caminos (p. ej. pausar con el overlay ya visible no redibujaba)
        // y el botón aparecía de forma intermitente.
        setState(() {});
        if (_hasMedia && wasPlaying && !pl) {
          // Se pausó (desde el TV o el teléfono): mostrar overlay + botón.
          _showControls();
        } else if (_hasMedia && !wasPlaying && pl && _controlsVisible) {
          // Se reanudó: re-armar el auto-ocultado del overlay.
          _showControls();
        }
      }),
    );
    // Spinner de carga: mismo indicador que el reproductor del teléfono.
    _subs.add(
      _player.stream.buffering.listen((b) {
        debugPrint('TvReceiver: buffering=$b @${_position.inSeconds}s');
        if (_buffering != b && mounted) setState(() => _buffering = b);
      }),
    );
    _subs.add(
      _player.stream.duration.listen((d) {
        if (d > Duration.zero) {
          _service.sendEvent(TvProto.evtLoaded, {
            'duration': d.inMilliseconds / 1000.0,
          });
        }
      }),
    );
    _subs.add(
      _player.stream.completed.listen((completed) {
        if (!completed) return;
        // Suprimir `completed` espurio dentro de ~4s tras un LOAD.
        final since = DateTime.now().difference(_lastLoadAt);
        if (since < const Duration(seconds: 4)) {
          debugPrint('TvReceiver: completed espurio suprimido');
          return;
        }
        _service.sendEvent(TvProto.evtEnded);
      }),
    );
    _subs.add(
      _player.stream.error.listen((e) {
        debugPrint('TvReceiver: error del player: $e');
      }),
    );
    // Log interno de MPV (solo debug, ver `logLevel` en PlayerConfiguration).
    //
    // El spinner eterno del televisor no deja rastro por ningun otro sitio: el
    // stream de `error` calla, `buffering` se queda en true y la posicion no
    // avanza, asi que el log de Flutter no dice si el problema es la conexion,
    // el demuxer o el decodificador. Esto lo saca de MPV directamente.
    //
    // Y se escucha SIEMPRE, no solo en depuracion. Aqui dentro pasa la unica
    // prueba fiable de que al demuxer le estan llegando bytes rotos, y esa
    // prueba hacia falta en la compilacion que usa la gente, no en la mia.
    _subs.add(
      _player.stream.log.listen((l) {
        if (kDebugMode) {
          debugPrint('TvReceiver: mpv[${l.prefix}/${l.level}] ${l.text}');
        }
        _anotarSiEsCorrupcion(l.text);
      }),
    );
  }

  // ─────────────────────────── Empuje de estado ─────────────────────────────

  void _startStatusPush() {
    // ~2 veces por segundo (500ms), como pide el brief.
    _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _pushStatus();
    });
  }

  void _startSpeedPolling() {
    _speedPollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted || !_hasMedia) return;
      try {
        final mpv = _player.platform as dynamic;
        if (mpv != null) {
          final raw = await mpv.getProperty('cache-speed');
          final speedBytes = double.tryParse(raw?.toString() ?? '') ?? 0.0;
          final kbps = speedBytes / 1024;
          if (mounted && _downloadSpeedKbps != kbps) {
            // El valor se guarda SIEMPRE, para que al abrirse el overlay ya
            // muestre el dato fresco. Pero solo se repinta si se esta VIENDO.
            //
            // Desde que la velocidad solo sale al cargar o con los controles a
            // la vista, la mayor parte del tiempo esta oculta — y un setState
            // por segundo reconstruyendo el arbol del reproductor para un texto
            // invisible es de las cosas que se notan en un Chromecast HD.
            _downloadSpeedKbps = kbps;
            if (_buffering || !_primerFrameListo || _controlsVisible) {
              setState(() {});
            }
          }
        }
      } catch (_) {}
    });
  }

  /// Marcas con las que MPV avisa de que los bytes que recibe estan rotos.
  ///
  /// No son avisos cosmeticos. Cuando salen, lo que se ve en la tele es
  /// exactamente esto: la imagen se congela, el audio salta hacia delante por
  /// su cuenta —"Invalid audio PTS: 580.28 -> 584.23"— y el video corre
  /// despues para alcanzarlo.
  ///
  /// El televisor ya los tenia delante y no hacia nada con ellos: el unico
  /// juez del cambio de servidor era el del telefono, que solo sabe mirar si
  /// la POSICION avanza. Y aqui la posicion avanza divinamente; de hecho
  /// avanza de mas. Por eso un titulo se podia ver fatal media hora sin que
  /// nadie cambiara nada.
  static const List<String> _marcasCorrupcion = [
    'Invalid EBML length',
    'Corrupt file detected',
    'Invalid audio PTS',
    'Audio/Video desynchronisation',
    'Invalid video PTS',
  ];

  final List<DateTime> _eventosCorrupcion = [];
  static const Duration _ventanaCorrupcion = Duration(seconds: 60);

  void _anotarSiEsCorrupcion(String texto) {
    if (!_marcasCorrupcion.any(texto.contains)) return;
    final ahora = DateTime.now();
    _eventosCorrupcion.add(ahora);
    _eventosCorrupcion.removeWhere(
      (t) => ahora.difference(t) > _ventanaCorrupcion,
    );
  }

  /// Cuantos avisos de corrupcion lleva el ultimo minuto.
  int _corrupcionReciente() {
    final ahora = DateTime.now();
    _eventosCorrupcion.removeWhere(
      (t) => ahora.difference(t) > _ventanaCorrupcion,
    );
    return _eventosCorrupcion.length;
  }

  void _pushStatus() {
    if (!_service.hasClient.value) return;
    try {
      final playing = _player.state.playing;
      final buffering = _player.state.buffering;
      final pos = _player.state.position;
      final dur = _player.state.duration;

      // ── Red de seguridad del overlay de carga ──────────────────────────
      //
      // `_primerFrameListo` se pone a false en CADA LOAD y solo lo levanta el
      // listener de `_videoController.rect`. El problema es que ese rect es un
      // ValueNotifier y media_kit no lo toca cuando el contenido nuevo tiene la
      // MISMA resolucion que el anterior — sale antes de tiempo:
      //
      //   final isSame = width == rect.value?.width.toInt() && ...
      //   if (isZero || isSame) return;      // ni asigna ni notifica
      //
      // Y `rect` tampoco se resetea entre medias. Asi que al recargar la misma
      // pelicula —lo que pasa justo cuando Xtream se para y el telefono reenvia
      // el LOAD— el listener no se dispara nunca y la bandera se queda en false
      // PARA SIEMPRE: el titulo y el spinner se quedan clavados
      // encima mientras el video se reproduce detras.
      //
      // Aqui se cierra por otro lado: si la posicion AVANZA entre dos muestras
      // con el reproductor reproduciendo y sin buffering, hay imagen en
      // pantalla, se haya disparado el listener o no. Solo puede QUITAR el
      // overlay, nunca mantenerlo mas tiempo.
      if (_hasMedia && !_primerFrameListo && playing && !buffering) {
        final anterior = _posAnterior;
        final r = _videoController.rect.value;
        final desdeLoad = DateTime.now().difference(_lastLoadAt);

        // El minimo de 2s no es un capricho. Este VideoController se reutiliza
        // entre contenidos, asi que `rect` conserva el valor del ANTERIOR y
        // siempre parece valido: sin el minimo, el overlay se quitaba en cuanto
        // el audio empezaba a avanzar, dejando un instante de pantalla negra
        // sin imagen y sin spinner. Con 2s la caratula cubre el arranque del
        // decodificador, que es para lo que esta.
        //
        // Sigue siendo una RED: solo puede quitar el overlay, y el camino bueno
        // (el listener de rect) lo quita antes cuando puede.
        if (anterior != null &&
            pos > anterior &&
            desdeLoad >= const Duration(seconds: 2) &&
            r != null &&
            r.width > 0 &&
            r.height > 0 &&
            mounted) {
          debugPrint(
            'TvReceiver: MEDIDA overlay quitado por avance de posicion a los '
            '${desdeLoad.inMilliseconds}ms (el listener de rect no se disparo: '
            'misma resolucion que el contenido anterior)',
          );
          setState(() => _primerFrameListo = true);
        }
      }
      _posAnterior = pos;

      String state;
      if (!_hasMedia && dur == Duration.zero) {
        state = TvProto.stateIdle;
      } else if (buffering) {
        state = TvProto.stateBuffering;
      } else if (playing) {
        state = TvProto.statePlaying;
      } else {
        state = TvProto.statePaused;
      }

      // Que pista suena/se ve AHORA. Sin esto, cambiar el idioma con el mando
      // dejaba al telefono marcando la pista vieja en su propio selector: dos
      // pantallas diciendo cosas distintas sobre el mismo video.
      String? audioActivo;
      String? subActivo;
      try {
        final a = _player.state.track.audio.id;
        if (a != 'auto' && a != 'no') audioActivo = a;
        final b = _player.state.track.subtitle.id;
        subActivo = (b == 'auto' || b == 'no') ? TvProto.subtitleOff : b;
      } catch (_) {}

      _service.sendEvent(TvProto.evtStatus, {
        'state': state,
        'position': pos.inMilliseconds / 1000.0,
        'duration': dur.inMilliseconds / 1000.0,
        'playing': playing,
        'bufferPercent': _bufferPercent(),
        if (audioActivo != null) 'activeAudioId': audioActivo,
        if (subActivo != null) 'activeSubtitleId': subActivo,
        // El telefono es quien decide cambiar de servidor, asi que necesita
        // ver esto. Campo nuevo: un receptor viejo simplemente no lo manda y
        // el telefono lo lee como 0.
        'corruptionPerMinute': _corrupcionReciente(),
      });
    } catch (e) {
      debugPrint('TvReceiver: error empujando STATUS: $e');
    }
  }

  double _bufferPercent() {
    try {
      final buf = _player.state.buffer.inMilliseconds;
      final dur = _player.state.duration.inMilliseconds;
      if (dur <= 0) return 0.0;
      return (buf / dur * 100).clamp(0.0, 100.0);
    } catch (_) {
      return 0.0;
    }
  }

  void _pushTracks() {
    try {
      final tracks = _player.state.tracks;
      final audio =
          tracks.audio
              .where((t) => t.id != 'auto' && t.id != 'no')
              .map(
                (t) => {'id': t.id, 'title': t.title, 'language': t.language},
              )
              .toList();
      final subs =
          tracks.subtitle
              .where((t) => t.id != 'auto' && t.id != 'no')
              .map(
                (t) => {'id': t.id, 'title': t.title, 'language': t.language},
              )
              .toList();
      _service.sendEvent(TvProto.evtAudioTracks, {'tracks': audio});
      _service.sendEvent(TvProto.evtSubtitleTracks, {'tracks': subs});
    } catch (e) {
      debugPrint('TvReceiver: error empujando tracks: $e');
    }
  }

  // ─────────────────────────── Helpers ──────────────────────────────────────

  double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// Lista de subtitulos externos del LOAD. Descarta las entradas sin URL.
  List<Map<String, String>> _asSubtitleList(dynamic v) {
    if (v is! List) return const [];
    final out = <Map<String, String>>[];
    for (final e in v) {
      if (e is! Map) continue;
      final url = e['url']?.toString();
      if (url == null || url.isEmpty) continue;
      out.add({
        'url': url,
        'label': e['label']?.toString() ?? 'Subtítulo',
        if (e['language'] != null) 'language': e['language'].toString(),
      });
    }
    return out;
  }

  Map<String, String>? _asStringMap(dynamic v) {
    if (v is Map) {
      final out = <String, String>{};
      v.forEach((k, val) {
        if (val != null) out[k.toString()] = val.toString();
      });
      return out.isEmpty ? null : out;
    }
    return null;
  }

  // ───────────────────────── Menu de pistas ─────────────────────────────────

  // Se filtran 'auto' y 'no' igual que en `_pushTracks`: son pseudo-pistas de
  // MPV, no idiomas reales. El "desactivados" de subtitulos se pone aparte
  // como primera entrada de la lista, para que siempre exista aunque el
  // archivo no traiga ninguna pista.
  List<AudioTrack> get _pistasAudio =>
      _player.state.tracks.audio
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();

  List<SubtitleTrack> get _pistasSubs =>
      _player.state.tracks.subtitle
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();

  /// Cuantas filas tiene la pestaña actual (subtitulos suma "Desactivados").
  int get _menuLargo =>
      _menuTab == 0 ? _pistasAudio.length : _pistasSubs.length + 1;

  String _etiquetaPista(String? title, String? language, String id) {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    final l = language?.trim();
    if (l != null && l.isNotEmpty) return l;
    return 'Pista $id';
  }

  /// Fila que corresponde a lo que suena/se ve ahora mismo.
  int _indiceActual(int tab) {
    try {
      if (tab == 0) {
        final actual = _player.state.track.audio.id;
        final i = _pistasAudio.indexWhere((t) => t.id == actual);
        return i < 0 ? 0 : i;
      }
      final actual = _player.state.track.subtitle.id;
      if (actual == 'no' || actual == 'auto') return 0;
      final i = _pistasSubs.indexWhere((t) => t.id == actual);
      return i < 0 ? 0 : i + 1; // +1 por la fila "Desactivados"
    } catch (_) {
      return 0;
    }
  }

  /// Que hace el boton ATRAS, en orden de lo mas concreto a lo mas drastico.
  ///
  /// Devuelve true si se lo quedo. Solo cuando NADIE se lo queda se sale, y
  /// aun asi hace falta pulsarlo dos veces seguidas.
  bool _manejarAtras() {
    // 1. Si hay un menu de pistas abierto, se cierra. Cerrar con atras es lo
    //    que espera cualquiera; antes cerraba "arriba", que ademas servia para
    //    moverse por la lista.
    if (_menuAbierto) {
      _cerrarMenuPistas();
      return true;
    }

    // 2. Con los controles a la vista, atras los esconde.
    if (_controlsVisible && _playing) {
      _hideControlsTimer?.cancel();
      if (mounted) setState(() => _controlsVisible = false);
      return true;
    }

    // 3. Salir, pero pidiendolo dos veces.
    final ahora = DateTime.now();
    final previo = _ultimoAtras;
    if (previo != null &&
        ahora.difference(previo) < const Duration(seconds: 3)) {
      return false; // segunda pulsacion a tiempo: que salga
    }

    _ultimoAtras = ahora;
    _avisoSalirTimer?.cancel();
    if (mounted) setState(() => _avisoSalir = true);
    _avisoSalirTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _avisoSalir = false);
    });
    return true;
  }

  void _abrirMenuPistas(int pestana) {
    // El overlay se auto-oculta a los 4s; con el menu abierto eso seria una
    // trampa (desaparece mientras lees la lista). Se corta el temporizador y
    // se vuelve a armar al cerrar.
    _hideControlsTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _menuAbierto = true;
      _menuTab = pestana;
      _menuIdx = _indiceActual(pestana);
    });
  }

  void _cerrarMenuPistas() {
    if (!mounted) return;
    setState(() => _menuAbierto = false);
    _showControls(); // re-arma el auto-ocultado
  }

  Future<void> _aplicarPistaSeleccionada() async {
    try {
      if (_menuTab == 0) {
        final lista = _pistasAudio;
        if (_menuIdx < 0 || _menuIdx >= lista.length) return;
        await _player.setAudioTrack(lista[_menuIdx]);
        debugPrint('TvReceiver: audio -> ${lista[_menuIdx].id}');
      } else {
        if (_menuIdx == 0) {
          await _player.setSubtitleTrack(SubtitleTrack.no());
          debugPrint('TvReceiver: subtitulos desactivados');
        } else {
          final lista = _pistasSubs;
          final i = _menuIdx - 1;
          if (i < 0 || i >= lista.length) return;
          await _player.setSubtitleTrack(lista[i]);
          debugPrint('TvReceiver: subtitulos -> ${lista[i].id}');
        }
      }
    } catch (e) {
      debugPrint('TvReceiver: no se pudo cambiar la pista: $e');
    }
    // El telefono tiene su propio selector: si no se le avisa, se queda
    // marcando la pista vieja y las dos pantallas dicen cosas distintas.
    _pushTracks();
    _pushStatus();
    if (mounted) setState(() {});
  }

  // ─────────────────────── Controles con control remoto ─────────────────────

  void _showControls() {
    _hideControlsTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    // Auto-ocultar a los 4s (salvo si estamos ajustando la línea de tiempo).
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (_previewing) {
        _commitPreviewSeek();
      }
      // En PAUSA el overlay (y el botón de play) permanecen visibles.
      if (!_playing && _hasMedia) {
        _showControls();
        return;
      }
      // Con el foco en los iconos de subtitulos/audio tampoco se oculta: el
      // usuario esta a media navegacion y se le desharia la pantalla debajo,
      // dejandolo con el foco en algo que ya no ve. Mismo criterio que la
      // pausa: si esta haciendo algo, el overlay se queda.
      if (_focusArea >= 2 && _hasMedia) {
        _showControls();
        return;
      }
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _mostrarPregunta(Map<String, dynamic> msg) {
    _preguntaTimer?.cancel();
    _avisoSalirTimer?.cancel();
    final segundos = (msg['segundos'] as num?)?.toInt() ?? 20;
    if (!mounted) return;
    setState(() {
      _pregunta = {
        'titulo': msg['titulo']?.toString() ?? '',
        'detalle': msg['detalle']?.toString() ?? '',
        'textoSi': msg['textoSi']?.toString() ?? 'Continuar',
        'textoNo': msg['textoNo']?.toString() ?? 'Esperar',
      };
      // Arranca en "no" (la opcion conservadora): si el usuario aporrea OK sin
      // leer, no se le cambia el idioma sin querer.
      _preguntaSiEnfocado = false;
      _preguntaSegundos = segundos;
    });
    // Que la pregunta reciba las teclas aunque el overlay estuviera oculto.
    _focusNode.requestFocus();

    _preguntaTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _pregunta == null) {
        t.cancel();
        return;
      }
      setState(() => _preguntaSegundos--);
      if (_preguntaSegundos <= 0) {
        // Se acabo el tiempo: se responde igual. Quien pregunta no puede
        // quedarse esperando indefinidamente — el contenido esta parado.
        _responderPregunta(true, porTiempo: true);
      }
    });
  }

  void _responderPregunta(bool acepta, {bool porTiempo = false}) {
    _preguntaTimer?.cancel();
    _preguntaTimer = null;
    if (mounted) setState(() => _pregunta = null);
    debugPrint(
      'TvReceiver: respuesta a la pregunta: $acepta'
      '${porTiempo ? ' (por tiempo agotado)' : ''}',
    );
  }

  Future<void> _togglePlay() async {
    if (_player.state.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    _pushStatus();
  }

  Future<void> _seekRelative(int seconds) async {
    final target = _position + Duration(seconds: seconds);
    final clamped =
        target < Duration.zero
            ? Duration.zero
            : (target > _duration ? _duration : target);
    await _player.seek(clamped);
    _pushStatus();
  }

  /// Mueve la posición de VISTA PREVIA sin bombardear al player con seeks. El
  /// salto real se aplica tras ~700ms sin pulsar (o con OK).
  void _previewSeekBy(int seconds) {
    if (!_previewing) {
      _previewing = true;
      _previewPos = _position;
    }
    var target = _previewPos + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) target = _duration;
    _previewPos = target;
    if (mounted) setState(() {});

    _seekDebounce?.cancel();
    _seekDebounce = Timer(
      const Duration(milliseconds: 700),
      _commitPreviewSeek,
    );
  }

  void _commitPreviewSeek() {
    _seekDebounce?.cancel();
    if (!_previewing) return;
    final target = _previewPos;
    _previewing = false;
    _player.seek(target);
    _pushStatus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final bool held = event is KeyRepeatEvent;

    // ── La pregunta se lleva TODAS las teclas mientras esta en pantalla ─────
    //
    // Va antes que nada, incluso que el `_hasMedia`: si el usuario pudiera
    // seguir moviendo la linea de tiempo o pausando por detras, la pregunta
    // seria una molestia flotando encima en vez de una decision.
    if (_pregunta != null) {
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        setState(() => _preguntaSiEnfocado = !_preguntaSiEnfocado);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.gameButtonA) {
        _responderPregunta(_preguntaSiEnfocado);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        // Atras = la opcion conservadora, nunca el cambio de idioma.
        _responderPregunta(false);
        return KeyEventResult.handled;
      }
      // El resto se traga: nada de pausar ni buscar por detras.
      return KeyEventResult.handled;
    }

    // ── ATRAS ────────────────────────────────────────────────────────────
    //
    // Va antes que nada (salvo la pregunta, que se trata arriba): cierra menu,
    // esconde controles, y solo a la tercera —y pulsandolo dos veces— sale.
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (_manejarAtras()) return KeyEventResult.handled;
      return KeyEventResult.ignored; // que salga por el camino del sistema
    }

    if (!_hasMedia) return KeyEventResult.ignored;

    // ── El menu de pistas se lleva TODAS las teclas mientras esta abierto ───
    //
    // Va antes que las teclas multimedia a proposito: si el usuario esta
    // eligiendo idioma, un rebobinado accidental del mando seria peor que
    // ignorar la tecla.
    if (_menuAbierto) {
      final bool ok =
          key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.gameButtonA;

      // Izquierda/derecha saltan de COLUMNA (Audio <-> Subtitulos) y colocan
      // el cursor en lo que ya esta activo en la columna nueva, que es lo que
      // el usuario espera ver marcado al llegar. Con las dos listas a la vista
      // el gesto se explica solo: se ve adonde lleva antes de pulsarlo.
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        setState(() {
          _menuTab = _menuTab == 0 ? 1 : 0;
          _menuIdx = _indiceActual(_menuTab);
        });
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        // Arriba SOLO sube por la lista. Cerrar es cosa de "atras" y de nadie
        // mas: antes arriba hacia las dos cosas segun donde estuviera el
        // cursor, y eso se siente aleatorio con un mando en la mano.
        if (_menuIdx > 0) setState(() => _menuIdx = _menuIdx - 1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        final n = _menuLargo;
        if (n > 0 && _menuIdx < n - 1) setState(() => _menuIdx = _menuIdx + 1);
        return KeyEventResult.handled;
      }
      if (ok) {
        unawaited(_aplicarPistaSeleccionada());
        _cerrarMenuPistas();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Teclas multimedia: actúan directo (y muestran el overlay) ──
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      _player.play();
      _pushStatus();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      _player.pause();
      _pushStatus();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _seekRelative(10);
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _seekRelative(-10);
      _showControls();
      return KeyEventResult.handled;
    }

    // Cualquier otra tecla revela el overlay; la primera pulsación solo revela.
    final wasVisible = _controlsVisible;
    _showControls();
    if (!wasVisible) return KeyEventResult.handled;

    final bool select =
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA;

    if (_focusArea == 1) {
      // ── Línea de tiempo ──
      final step = held ? 30 : 10; // mantener presionado = saltos más grandes
      if (key == LogicalKeyboardKey.arrowLeft) {
        _previewSeekBy(-step);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _previewSeekBy(step);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _commitPreviewSeek();
        setState(() => _focusArea = 0);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        // Abajo lleva a los iconos de subtitulos y audio.
        _commitPreviewSeek();
        setState(() => _focusArea = 2);
        return KeyEventResult.handled;
      }
      if (select) {
        _commitPreviewSeek();
        setState(() => _focusArea = 0);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Fila de iconos: subtitulos (2) y audio (3) ────────────────────────
    //
    // Sustituyen al atajo de "arriba dos veces" que habia antes para abrir las
    // pistas. Un atajo invisible obliga a acordarse; un icono se ve, se enfoca
    // y se pulsa, que es como funciona todo lo demas del mando.
    if (_focusArea == 2 || _focusArea == 3) {
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        setState(() => _focusArea = _focusArea == 2 ? 3 : 2);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _focusArea = 1;
          _previewing = true;
          _previewPos = _position;
        });
        return KeyEventResult.handled;
      }
      if (select) {
        // 2 = subtitulos -> pestaña 1;  3 = audio -> pestaña 0.
        _abrirMenuPistas(_focusArea == 2 ? 1 : 0);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Botón play/pausa (único botón) ──
    // Izquierda/derecha saltan directo ±10s (sin botones dedicados).
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekRelative(-10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekRelative(10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _focusArea = 1;
        _previewing = true;
        _previewPos = _position;
      });
      return KeyEventResult.handled;
    }
    if (select) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _speedPollTimer?.cancel();
    _commandSub?.cancel();
    _hideControlsTimer?.cancel();
    _seekDebounce?.cancel();
    _focusNode.dispose();
    _preguntaTimer?.cancel();
    _videoController.rect.removeListener(_onRectCambio);
    _service.hasClient.removeListener(_onClientChanged);
    for (final s in _subs) {
      s.cancel();
    }
    WakelockPlus.disable();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // En Android TV el boton de atras del mando suele llegar como un POP del
    // sistema, no como tecla, asi que hace falta interceptarlo aqui ademas de
    // en `_onKey`. Con `canPop: false` no se sale nunca por las buenas: decide
    // `_manejarAtras`, y si dice que toca salir, se sale a mano.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        if (!_manejarAtras()) SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _hasMedia
                  ? Video(
                    controller: _videoController,
                    fit: BoxFit.contain,
                    // Sin los controles integrados de media_kit: renderizan una
                    // capa de gestos/overlay extra que no usamos (tenemos overlay
                    // propio) y cuesta frames en TVs de gama baja.
                    controls: NoVideoControls,
                    // Subtítulos renderizados por Flutter (requiere libass:false
                    // en el Player — ver arriba). Estilo legible a distancia de
                    // sofá: grande, blanco, con sombra y fondo translúcido.
                    subtitleViewConfiguration: const SubtitleViewConfiguration(
                      style: TextStyle(
                        height: 1.35,
                        fontSize: 42.0,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        backgroundColor: Color(0x99000000),
                        shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                      ),
                      textAlign: TextAlign.center,
                      padding: EdgeInsets.fromLTRB(48, 0, 48, 56),
                    ),
                  )
                  : _WaitingScreen(deviceName: _deviceName),

              // Spinner de carga idéntico al del reproductor del teléfono.
              // Se mantiene mientras haya buffering O mientras no haya llegado el
              // primer frame: sin lo segundo, el arranque de una transmisión era
              // pantalla negra sin ninguna indicación de que estuviera cargando.
              if (_hasMedia && (_buffering || !_primerFrameListo))
                const Center(
                  child: _AppLoadingAnimation(size: 54, strokeWidth: 4),
                ),
              // Velocidad de descarga: solo cuando ACOMPAÑA a algo.
              //
              // La condicion era `_downloadSpeedKbps > 0 || _buffering`, y como
              // durante la reproduccion la velocidad casi nunca es cero, el
              // numerito se quedaba clavado en la esquina toda la pelicula.
              //
              // Ahora sale en los dos momentos en que aporta:
              //  · mientras carga —acompañando al spinner, para que se vea que
              //    algo esta pasando y no es un cuelgue—;
              //  · y con el overlay de controles a la vista, junto a la barra y
              //    el titulo, que es cuando el usuario esta mirando datos.
              //
              // El resto del tiempo la pantalla se queda limpia, que es de lo
              // que se trata al ver algo en la tele.
              if (_hasMedia &&
                  (_buffering || !_primerFrameListo || _controlsVisible))
                Positioned(
                  top: 40,
                  left: 48,
                  child: Text(
                    '${_downloadSpeedKbps.toStringAsFixed(0)} KB/s',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16.6,
                      fontWeight: FontWeight.w400,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
                  ),
                ),
              // Pregunta en pantalla: por ENCIMA de todo lo demas, con su propio
              // velo, para que se lea sobre cualquier fotograma.
              if (_pregunta != null)
                Positioned.fill(
                  child: _TvPregunta(
                    titulo: _pregunta!['titulo']!,
                    detalle: _pregunta!['detalle']!,
                    textoSi: _pregunta!['textoSi']!,
                    textoNo: _pregunta!['textoNo']!,
                    siEnfocado: _preguntaSiEnfocado,
                    segundos: _preguntaSegundos,
                  ),
                ),

              // Con el menu de pistas abierto no se pinta: quedaria translucido
              // por detras de la lista, compitiendo por la atencion.
              if (_hasMedia &&
                  _controlsVisible &&
                  _pregunta == null &&
                  !_menuAbierto)
                _TvControlsOverlay(
                  position: _previewing ? _previewPos : _position,
                  duration: _duration,
                  buffered: _buffered,
                  playing: _playing,
                  focusArea: _focusArea,
                  previewing: _previewing,
                  title: _mediaTitle,
                  thumbnailUrl: _mediaThumb,
                ),
              if (_hasMedia && _menuAbierto && _pregunta == null)
                _TvTrackMenu(
                  tab: _menuTab,
                  indice: _menuIdx,
                  audio: [
                    for (final t in _pistasAudio)
                      _etiquetaPista(t.title, t.language, t.id),
                  ],
                  subtitulos: [
                    'Desactivados',
                    for (final t in _pistasSubs)
                      _etiquetaPista(t.title, t.language, t.id),
                  ],
                  audioActivo: _indiceActual(0),
                  subtituloActivo: _indiceActual(1),
                ),

              // Botón de play SIEMPRE visible mientras esté en PAUSA (no depende
              // del overlay ni de su temporizador, para que no aparezca a veces
              // sí y a veces no). Al reanudar desaparece.
              // Con el menu abierto se esconde: taparia la lista justo en medio.
              if (_hasMedia && !_playing && !_buffering && !_menuAbierto)
                Center(
                  child: _CtrlButton(
                    icon: Icons.play_arrow_rounded,
                    focused: _focusArea == 0,
                    big: true,
                  ),
                ),

              // Aviso de salida. Abajo del todo y discreto: es una confirmacion,
              // no una alarma.
              if (_avisoSalir)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 64,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 26,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Text(
                        'Pulsa atrás otra vez para salir',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pantalla de espera mostrada cuando no hay media reproduciéndose.
///
/// Estilo minimalista (Apple): fondo casi negro, tipografía fina, mucho
/// espacio en negativo y un único acento rojo. Deja claro que en el teléfono
/// este receptor se llama [deviceName], y guía en 3 pasos.
class _WaitingScreen extends StatefulWidget {
  final String deviceName;
  const _WaitingScreen({required this.deviceName});
  @override
  State<_WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<_WaitingScreen>
    with SingleTickerProviderStateMixin {
  // Un único controller para la respiración sutil del punto de estado.
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);

  // IP local en la red — ayuda a confirmar "misma Wi-Fi".
  String? _ip;

  @override
  void initState() {
    super.initState();
    _resolveIp();
  }

  Future<void> _resolveIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) {
            if (mounted) setState(() => _ip = a.address);
            return;
          }
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // Fondo plano casi negro con un degradado vertical apenas perceptible.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B0B0D), Color(0xFF060607)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Marca discreta arriba a la izquierda.
          Positioned(
            top: 40,
            left: 48,
            child: Row(
              children: [
                _brandDot(),
                const SizedBox(width: 12),
                Text(
                  'Bump Comba',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),

          // Composición central.
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Etiqueta contextual.
                Text(
                  'TRANSMITE A',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 3.0,
                  ),
                ),
                const SizedBox(height: 20),
                // El nombre que hay que buscar en el teléfono — protagonista.
                Text(
                  widget.deviceName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 43,
                    fontWeight: FontWeight.w400, // fino, tipo SF
                    letterSpacing: -0.9,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 56),
                // Hairline separador.
                Container(
                  width: 420,
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
                const SizedBox(height: 48),
                // Guía de 3 pasos, en fila.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _step(1, 'Abre Bump Comba\nen tu teléfono'),
                    _stepGap(),
                    _step(
                      2,
                      'Toca el ícono\nde transmitir',
                      icon: Icons.cast_rounded,
                    ),
                    _stepGap(),
                    _step(3, 'Elige "${widget.deviceName}"\nen la lista'),
                  ],
                ),
              ],
            ),
          ),

          // Estado inferior: punto que respira + "en espera" + IP.
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: TvReceiverService().hasClient,
                  builder: (context, connected, _) {
                    // Naranja parpadeando en espera; verde fijo al conectar.
                    final Color color =
                        connected
                            ? const Color(0xFF34C759) // verde
                            : const Color(0xFFFF9500); // naranja
                    final String label =
                        connected
                            ? 'Teléfono conectado · listo para reproducir'
                            : 'En espera de conexión';
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedBuilder(
                          animation: _t,
                          builder: (context, _) {
                            // Conectado: punto fijo. En espera: parpadeo.
                            final alpha =
                                connected ? 1.0 : (0.2 + 0.8 * _t.value);
                            return Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: color.withValues(alpha: alpha),
                                boxShadow:
                                    connected
                                        ? [
                                          BoxShadow(
                                            color: color.withValues(alpha: 0.5),
                                            blurRadius: 8,
                                            spreadRadius: 1,
                                          ),
                                        ]
                                        : null,
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 10),
                        Text(
                          label,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 15,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                if (_ip != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Misma red Wi-Fi · $_ip',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.25),
                      fontSize: 13,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Punto de marca: pequeña esfera glossy roja (identidad de la app).
  Widget _brandDot() {
    return Container(
      width: 16,
      height: 16,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: Alignment(-0.4, -0.5),
          radius: 1.2,
          colors: [Color(0xFFFF6B5E), Color(0xFFE53935), Color(0xFFB71C1C)],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
    );
  }

  Widget _stepGap() => Container(
    width: 1,
    height: 76,
    margin: const EdgeInsets.symmetric(horizontal: 40),
    color: Colors.white.withValues(alpha: 0.06),
  );

  Widget _step(int n, String text, {IconData? icon}) {
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Círculo de número, contorno fino con acento rojo.
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFFE53935).withValues(alpha: 0.55),
                width: 1.4,
              ),
            ),
            child:
                icon != null
                    ? Icon(icon, color: Colors.white, size: 20)
                    : Text(
                      '$n',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
          ),
          const SizedBox(height: 18),
          Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 18,
              height: 1.35,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// Overlay de controles para el control remoto. `focusArea`: 0 = botones,
/// 1 = línea de tiempo. Se navega con el D-pad (ver [_TvReceiverScreenState]).
class _TvControlsOverlay extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool playing;
  final int focusArea;
  final bool previewing;
  final String title;
  final String? thumbnailUrl;

  const _TvControlsOverlay({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.playing,
    required this.focusArea,
    required this.previewing,
    required this.title,
    required this.thumbnailUrl,
  });

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// Extrae solo el nombre del episodio del título completo.
  ///
  /// Los títulos de series llegan como "Serie S01E05 Nombre" o "Serie 1x05 -
  /// Nombre"; aquí nos quedamos con lo que va DESPUÉS del patrón de
  /// temporada/episodio. Si no hay patrón (películas), se muestra tal cual.
  String _displayTitle(String raw) {
    final t = raw.trim();
    final matches =
        RegExp(
          r'[Ss]\d{1,2}\s*[-.\s]?\s*[Ee]\d{1,3}|\b\d{1,2}x\d{1,3}\b',
        ).allMatches(t).toList();
    // Películas (sin patrón de episodio): quitar el año final,
    // p. ej. "Moana (2026)" / "Moana [2026]" / "Moana 2026" → "Moana".
    if (matches.isEmpty) {
      return t
          .replaceAll(RegExp(r'\s*[(\[]\s*(19|20)\d{2}\s*[)\]]\s*$'), '')
          .replaceAll(RegExp(r'\s+(19|20)\d{2}\s*$'), '')
          .trim();
    }

    final after =
        t
            .substring(matches.last.end)
            .replaceFirst(RegExp(r'^[\s\-–—:._|]+'), '')
            .trim();
    if (after.isNotEmpty) return after;

    // Sin nombre tras el patrón: mostrar al menos "S01E05".
    return t.substring(matches.last.start).trim();
  }

  @override
  Widget build(BuildContext context) {
    final double progress =
        duration.inMilliseconds > 0
            ? (position.inMilliseconds / duration.inMilliseconds).clamp(
              0.0,
              1.0,
            )
            : 0.0;

    // Fraccion cargada. `buffer` de MPV es la posicion ABSOLUTA hasta donde
    // hay datos, no una duracion, asi que se divide igual que la posicion.
    // Nunca por detras de lo ya reproducido: si el bufer se vacia, la pista
    // secundaria se esconde bajo la principal en vez de dibujarse al reves.
    final double buffered0a1 =
        duration.inMilliseconds > 0
            ? (buffered.inMilliseconds / duration.inMilliseconds).clamp(
              progress,
              1.0,
            )
            : 0.0;
    final timelineFocused = focusArea == 1;
    // Mismo lenguaje visual que el botón de play: blanco, con acento verde
    // al enfocar.
    final Color accent = Colors.white;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.75)],
          stops: const [0.5, 1.0],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // (El botón de play se dibuja en el Stack principal, no aquí, para
          // que su visibilidad dependa solo del estado de pausa.)
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 0, 48, 36),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Zona inferior estilo referencia: carátula a la izquierda,
                // línea de tiempo + título a la derecha. ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (thumbnailUrl != null) ...[
                      Image.network(
                        thumbnailUrl!,
                        width: 90,
                        height: 130,
                        fit: BoxFit.cover,
                        // Si la carátula falla, no mostramos nada (sin hueco feo).
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
                          // Mismo criterio que en el telefono: un `00:00 / 00:00` no se lee
                          // como "cargando", se lee como "esto dura cero". Y aqui pasa aunque
                          // el overlay solo salga al pulsar el mando: si pulsas mientras carga,
                          // veias esa barra a ceros.
                          //
                          // Mientras tanto ya hay un spinner con los KB/s en el centro, que es
                          // lo unico que Netflix muestra en este hueco.
                          //
                          // `maintainSize` reserva la altura para que el titulo de debajo no
                          // pegue un salto cuando aparece la barra.
                          Visibility(
                            visible: duration > Duration.zero,
                            maintainSize: true,
                            maintainAnimation: true,
                            maintainState: true,
                            child: Row(
                              children: [
                                Text(
                                  _fmt(position),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                                const SizedBox(width: 18),
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final barWidth = constraints.maxWidth;
                                      final thumbX = barWidth * progress;
                                      // Un punto mas gruesa de lo que era
                                      // (6/8 en vez de 5/7). Sube tambien la
                                      // enfocada para no perder el salto de
                                      // grosor, que es la senal de "estas
                                      // aqui" de la barra.
                                      final barHeight =
                                          timelineFocused ? 8.0 : 6.0;
                                      final thumbSize =
                                          timelineFocused ? 26.0 : 18.0;
                                      return SizedBox(
                                        height: 28,
                                        child: Stack(
                                          alignment: Alignment.centerLeft,
                                          children: [
                                            // Pista: mismo blanco translúcido
                                            // que el botón sin foco (white24).
                                            Container(
                                              height: barHeight,
                                              decoration: BoxDecoration(
                                                color: Colors.white24,
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                            ),
                                            // Pista de bufer: por DEBAJO de la
                                            // reproducida, para que esta la
                                            // tape. Mas opaca que la pista
                                            // vacia (white24) y mas tenue que
                                            // el acento, igual que YouTube.
                                            FractionallySizedBox(
                                              alignment: Alignment.centerLeft,
                                              widthFactor: buffered0a1,
                                              child: Container(
                                                height: barHeight,
                                                decoration: BoxDecoration(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.45),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                              ),
                                            ),
                                            FractionallySizedBox(
                                              alignment: Alignment.centerLeft,
                                              widthFactor: progress,
                                              child: Container(
                                                height: barHeight,
                                                decoration: BoxDecoration(
                                                  color: accent,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              left: (thumbX - thumbSize / 2)
                                                  .clamp(
                                                    0.0,
                                                    barWidth - thumbSize,
                                                  ),
                                              child: Container(
                                                width: thumbSize,
                                                height: thumbSize,
                                                // Mismo estilo glossy rojo que
                                                // el botón de play.
                                                decoration: const BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  gradient: RadialGradient(
                                                    center: Alignment(
                                                      -0.4,
                                                      -0.5,
                                                    ),
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
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(width: 18),
                                Text(
                                  _fmt(duration),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          // Título a la izquierda, pistas a la derecha, en la
                          // MISMA linea.
                          //
                          // Antes se llegaba a las pistas pulsando ARRIBA dos
                          // veces desde el botón de play: un atajo invisible,
                          // que hay que saberse y que no se parece a nada más
                          // del mando. Aquí son dos iconos que se ven, se
                          // enfocan con abajo y se abren con OK, igual que
                          // cualquier otro control.
                          //
                          // Y comparten linea con el título en vez de ir
                          // debajo por dos motivos. Uno: esta columna crece
                          // hacia ARRIBA —está anclada abajo—, asi que
                          // cualquier fila nueva empuja el título y la barra
                          // de progreso fuera de su sitio. Dos: a la
                          // izquierda y bajo el tiempo transcurrido, las dos
                          // cosas se leian como un mismo bloque; al otro
                          // extremo se ven como lo que son, ajustes.
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title.isNotEmpty ? _displayTitle(title) : '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 28),
                              _IconoPista(
                                icon: Icons.subtitles_outlined,
                                etiqueta: 'Subtítulos',
                                focused: focusArea == 2,
                              ),
                              // Separados de verdad: pegados parecian un solo
                              // control de dos partes, y ademas al crecer con
                              // el foco casi se tocaban.
                              const SizedBox(width: 26),
                              _IconoPista(
                                icon: Icons.multitrack_audio_rounded,
                                etiqueta: 'Audio',
                                focused: focusArea == 3,
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
          ),
        ],
      ),
    );
  }
}

/// Icono de la fila de pistas (subtitulos / audio), junto al titulo.
///
/// Sin caja, sin borde, sin relleno y sin subrayado: el mismo lenguaje que el
/// selector que abren.
///
/// EL FOCO, SIN PINTAR NADA NUEVO
/// Se marca con tres cosas que no anaden ni una linea a la pantalla:
///  · gris -> BLANCO PURO,
///  · la letra engorda,
///  · y el conjunto CRECE un 10%.
///
/// El color solo no basta en un televisor: los modos de imagen que aplastan el
/// contraste se comen la diferencia entre un gris claro y el blanco. El tamano
/// no se lo come ninguno, y ademas el movimiento se percibe por el rabillo del
/// ojo, que es como se navega con un mando en la mano.
///
/// Crece con `AnimatedScale`, que es una transformacion y no toca el layout:
/// asi al pasar el foco de un icono al otro no se mueve nada alrededor.
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

    return AnimatedScale(
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOut,
      scale: focused ? 1.10 : 1.0,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 7),
          // El grosor NO cambia con el foco, aunque seria lo natural.
          //
          // La negrita ensancha el texto, y aqui eso costaba dos cosas: la
          // etiqueta parecia crecer de tamano (que no es lo que se quiere
          // decir; el tamano ya lo dice la escala) y al ensancharse empujaba
          // al icono de al lado. Con el grosor fijo, el ancho es siempre el
          // mismo y lo unico que se mueve es lo que debe moverse.
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
      ),
    );
  }
}

class _CtrlButton extends StatelessWidget {
  final IconData icon;
  final bool focused;
  final bool big;

  const _CtrlButton({
    required this.icon,
    required this.focused,
    this.big = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = big ? 72.0 : 56.0;
    // Esfera roja brillante (estilo glossy): degradado radial con luz
    // arriba-izquierda y brillo especular, sin sombras.
    return AnimatedScale(
      duration: const Duration(milliseconds: 150),
      scale: 1.0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: 1.0,
        child: Container(
          width: size,
          height: size,
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
              // Brillo especular (la "chispa" blanca de la esfera).
              Positioned(
                top: size * 0.13,
                left: size * 0.22,
                child: Container(
                  width: size * 0.26,
                  height: size * 0.15,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(size),
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
              Icon(icon, color: Colors.white, size: big ? 46 : 34),
            ],
          ),
        ),
      ),
    );
  }
}

/// Spinner de carga — copia exacta del que usa el reproductor del teléfono
/// (`_AppLoadingAnimation` en video_player_screen.dart), para que la carga en
/// el TV se vea igual.
class _AppLoadingAnimation extends StatefulWidget {
  final double size;
  final double strokeWidth;

  const _AppLoadingAnimation({this.size = 60, this.strokeWidth = 4});

  @override
  State<_AppLoadingAnimation> createState() => _AppLoadingAnimationState();
}

class _AppLoadingAnimationState extends State<_AppLoadingAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.red.withValues(alpha: 0.1),
                width: widget.strokeWidth,
              ),
            ),
          ),
          SizedBox(
            width: widget.size,
            height: widget.size,
            child: CircularProgressIndicator(
              value: 0.3,
              strokeWidth: widget.strokeWidth,
              color: Colors.red,
              strokeCap: StrokeCap.round,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pregunta a pantalla completa en el televisor, contestable con el mando.
///
/// Tamanos pensados para verse desde el sofa: el titulo a 34 y los botones a
/// 22, muy por encima de lo que se usaria en un telefono. El foco se marca con
/// relleno solido y borde, no solo con color, porque a tres metros un cambio de
/// tono no se distingue.
class _TvPregunta extends StatelessWidget {
  final String titulo;
  final String detalle;
  final String textoSi;
  final String textoNo;
  final bool siEnfocado;
  final int segundos;

  const _TvPregunta({
    required this.titulo,
    required this.detalle,
    required this.textoSi,
    required this.textoNo,
    required this.siEnfocado,
    required this.segundos,
  });

  Widget _boton(String texto, bool enfocado) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 16),
      decoration: BoxDecoration(
        color: enfocado ? Colors.white : Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: enfocado ? Colors.white : Colors.white24,
          width: 2,
        ),
      ),
      child: Text(
        texto,
        style: TextStyle(
          color: enfocado ? Colors.black : Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.82),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.language, color: Colors.amber, size: 40),
            ),
            const SizedBox(height: 22),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              detalle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 19,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 34),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _boton(textoNo, !siEnfocado),
                const SizedBox(width: 20),
                _boton(textoSi, siEnfocado),
              ],
            ),
            const SizedBox(height: 26),
            Text(
              'Usa ← → para elegir y OK para confirmar  ·  '
              'continúa solo en ${segundos}s',
              style: const TextStyle(color: Colors.white38, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

/// Menú de pistas del televisor: audio y subtítulos, navegable con el D-pad.
///
/// Dos pestañas en vez de dos menús separados porque con un mando cada nivel
/// de navegación extra se paga caro: así izquierda/derecha cambia de lista y
/// arriba/abajo recorre, sin submenús ni botón de "volver".
///
/// La pista activa lleva un check aunque el cursor esté en otra fila: sin eso,
/// al entrar no hay forma de saber qué idioma está sonando ya.
class _TvTrackMenu extends StatelessWidget {
  final int tab;
  final int indice;
  final List<String> audio;
  final List<String> subtitulos;
  final int audioActivo;
  final int subtituloActivo;

  const _TvTrackMenu({
    required this.tab,
    required this.indice,
    required this.audio,
    required this.subtitulos,
    required this.audioActivo,
    required this.subtituloActivo,
  });

  @override
  Widget build(BuildContext context) {
    // LAS DOS LISTAS A LA VEZ, sin caja y sin adornos.
    //
    // Asi lo resuelve Netflix en television, y no por gusto: con una sola
    // lista y pestanas hay que ACORDARSE de que existe la otra y descubrir
    // que se llega con izquierda/derecha. Con las dos delante, el gesto es
    // evidente sin explicarlo, y de paso se ve de un vistazo que idioma y que
    // subtitulo hay puestos: son la misma decision.
    //
    // El manejo del mando no cambia ni una linea: `tab` ya era 0/1 y
    // izquierda/derecha ya alternaba. Lo que antes eran dos pestanas ahora son
    // dos columnas, que es lo que ese gesto sugeria desde el principio.
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.88),
        alignment: Alignment.center,
        child: ConstrainedBox(
          // El ancho es lo que de verdad separa las dos listas: cada columna
          // se lleva la mitad, asi que cuanto mas ancho, mas lejos cae el
          // texto de la segunda. Estrechando el conjunto se juntan sin tocar
          // el hueco entre ellas.
          constraints: const BoxConstraints(maxWidth: 580, maxHeight: 560),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _ColumnaPistas(
                  titulo: 'AUDIO',
                  filas: audio,
                  seleccionada: audioActivo,
                  enfocada: tab == 0,
                  indiceFoco: indice,
                ),
              ),
              const SizedBox(width: 36),
              Expanded(
                child: _ColumnaPistas(
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
      ),
    );
  }
}

/// Una columna del selector: cabecera y lista de texto pelado.
///
/// Sin recuadros, sin bordes, sin rojo. En una pantalla grande el texto ya es
/// suficientemente grande para leerse de lejos, y cada caja que se anade es
/// una linea mas que compite con el titulo que se estaba viendo.
class _ColumnaPistas extends StatelessWidget {
  final String titulo;
  final List<String> filas;
  final int seleccionada;
  final bool enfocada;
  final int indiceFoco;

  const _ColumnaPistas({
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
            // La columna sin foco se apaga entera. Es lo unico que dice donde
            // esta el mando, y basta: no hace falta marco.
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

                // Tres estados y ni un pixel de decoracion:
                //  · con el foco  -> blanco puro
                //  · ya elegida   -> blanco apagado, con su marca
                //  · el resto     -> gris
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
