import 'dart:async';
import 'dart:io';

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
    configuration: const PlayerConfiguration(
      title: 'Bump Comba TV',
      bufferSize: 32 * 1024 * 1024, // 32 MB — moderado para TVs de gama baja
      logLevel: MPVLogLevel.error,
      libass: true,
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
  bool _playing = false;

  // Vista previa de la línea de tiempo: el seek real se aplica con debounce.
  bool _previewing = false;
  Duration _previewPos = Duration.zero;
  Timer? _seekDebounce;

  // Auto-avance: suprimir `completed` espurio de MPV justo tras un LOAD.
  // (error crítico #10 del brief)
  DateTime _lastLoadAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _deviceName = _service.deviceName;
    _configureMpv();
    _startService();
    _listenPlayer();
    _startStatusPush();
    WakelockPlus.enable();
  }

  Future<void> _configureMpv() async {
    // Solo propiedades SEGURAS en Android (nunca vo=gpu / profile=fast).
    // Optimizado para FLUIDEZ máxima en TVs de gama baja (Chromecast HD,
    // TV boxes con ~1GB RAM y SoC débil).
    try {
      final mpv = _player.platform as dynamic;

      // ── Decodificación ──
      // NOTA: hwdec se configura en el VideoController (ver arriba) porque
      // media_kit lo re-aplica al crear el video output y pisaría lo que
      // pongamos aquí.
      // Decodificación por software (fallback) lo más barata posible:
      // multihilo total + fast + saltar el loop filter (imperceptible en TV).
      await mpv?.setProperty('vd-lavc-threads', '0');
      await mpv?.setProperty('vd-lavc-fast', 'yes');
      await mpv?.setProperty('vd-lavc-skiploopfilter', 'all');

      // ── Sincronización / frames ──
      // Priorizar audio continuo y soltar frames de video tardíos en vez de
      // congelar la imagen (en SoCs débiles esto es lo que evita el "tirón").
      await mpv?.setProperty('video-sync', 'audio');
      await mpv?.setProperty('framedrop', 'decoder+vo');
      // Sin postprocesado costoso.
      await mpv?.setProperty('deband', 'no');
      await mpv?.setProperty('dither-depth', 'no');

      // ── Cache / red ──
      // El Chromecast HD tiene 2 GB de RAM: podemos permitirnos un colchón
      // grande. Cuanto más readahead, menos veces se detiene la reproducción
      // cuando el servidor IPTV da tirones de velocidad.
      await mpv?.setProperty('cache', 'yes');
      await mpv?.setProperty('cache-secs', '180'); // hasta 3 min por delante
      await mpv?.setProperty('demuxer-max-bytes', '67108864'); // 64 MB
      await mpv?.setProperty('demuxer-max-back-bytes', '16777216');
      await mpv?.setProperty('demuxer-readahead-secs', '180');
      // Al arrancar o tras un rebuffering, esperar a acumular ~8s de buffer
      // antes de reanudar: MENOS pausas pero más largas es mucho más visible
      // que fluido; con 8s el player casi nunca vuelve a vaciarse.
      await mpv?.setProperty('cache-pause-initial', 'yes');
      await mpv?.setProperty('cache-pause-wait', '8');
      await mpv?.setProperty('cache-pause', 'yes');
      await mpv?.setProperty('stream-buffer-size', '8388608'); // 8 MB
      await mpv?.setProperty('network-timeout', '15');
      await mpv?.setProperty('http-reconnect', 'yes');
      await mpv?.setProperty('http-reconnect-sleep', '0.5');
      // Descargar el siguiente segmento sin esperar respuesta del anterior.
      await mpv?.setProperty('http-pipelining', 'yes');
      await mpv?.setProperty('tls-verify', 'no');
      await mpv?.setProperty('force-seekable', 'yes');
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
      }
    } catch (e) {
      debugPrint('TvReceiver: error ejecutando $type: $e');
    }
  }

  Future<void> _handleLoad(Map<String, dynamic> msg) async {
    final url = msg['url']?.toString();
    if (url == null || url.isEmpty) {
      _service.sendEvent(TvProto.evtLoadFailed, {'error': 'url vacía'});
      return;
    }
    final position = _asDouble(msg['position']) ?? 0.0;
    final headers = _asStringMap(msg['headers']);
    _mediaTitle = msg['title']?.toString() ?? '';
    final thumb = msg['thumbnailUrl']?.toString();
    _mediaThumb = (thumb == null || thumb.isEmpty) ? null : thumb;

    _lastLoadAt = DateTime.now();
    try {
      await _player.open(Media(url, httpHeaders: headers), play: true);
      if (mounted) setState(() => _hasMedia = true);
      if (position > 0) {
        // El seek NO debe hacerse justo tras open(): media_kit devuelve antes
        // de que el demuxer reporte duración, y en streams de red un seek
        // inmediato se pierde (el TV arrancaría desde 0). Esperamos a que el
        // medio sea buscable y reintentamos hasta acertar.
        unawaited(
          _seekWhenReady(Duration(milliseconds: (position * 1000).round())),
        );
      }
      _pushStatus();
    } catch (e) {
      debugPrint('TvReceiver: LOAD falló: $e');
      _service.sendEvent(TvProto.evtLoadFailed, {'error': e.toString()});
    }
  }

  /// Aplica un seek de arranque de forma robusta: espera a que el demuxer
  /// reporte duración y reintenta el seek hasta que la posición quede cerca del
  /// objetivo (patrón que ya usa el reproductor del teléfono).
  Future<void> _seekWhenReady(Duration target) async {
    final int loadStamp = _lastLoadAt.millisecondsSinceEpoch;

    // Fase 1: esperar a que el demuxer conozca la duración (hasta ~15s).
    for (int i = 0; i < 60; i++) {
      if (!mounted) return;
      // Si llegó otro LOAD entretanto, abortamos este seek.
      if (_lastLoadAt.millisecondsSinceEpoch != loadStamp) return;
      if (_player.state.duration > Duration.zero) break;
      await Future.delayed(const Duration(milliseconds: 250));
    }

    // Fase 2: seek + reintentos hasta quedar a menos de 5s del objetivo.
    for (int attempt = 0; attempt < 6; attempt++) {
      if (!mounted || _lastLoadAt.millisecondsSinceEpoch != loadStamp) return;
      try {
        await _player.seek(target);
      } catch (e) {
        debugPrint('TvReceiver: seek de arranque falló: $e');
      }
      await Future.delayed(const Duration(milliseconds: 500));
      final diff = (_player.state.position - target).abs();
      if (diff < const Duration(seconds: 5)) break;
    }
    _pushStatus();
  }

  Future<void> _handleStop() async {
    try {
      await _player.stop();
    } catch (_) {}
    if (mounted) setState(() => _hasMedia = false);
    _pushStatus();
  }

  // ─────────────────────────── Listeners del player ──────────────────────────

  void _listenPlayer() {
    _subs.add(
      _player.stream.tracks.listen((_) {
        _pushTracks();
      }),
    );
    // Estado local para el overlay de controles (no pintamos si no hay overlay
    // visible para ahorrar rebuilds en TVs de gama baja).
    _subs.add(
      _player.stream.position.listen((p) {
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
      _player.stream.playing.listen((pl) {
        final wasPlaying = _playing;
        _playing = pl;
        if (!mounted) return;
        if (_hasMedia && wasPlaying && !pl) {
          // Se pausó (desde el TV o el teléfono): mostrar el botón de play.
          _showControls();
        } else if (_hasMedia && !wasPlaying && pl && _controlsVisible) {
          // Se reanudó: re-armar el auto-ocultado del overlay.
          _showControls();
        } else if (_controlsVisible) {
          setState(() {});
        }
      }),
    );
    // Spinner de carga: mismo indicador que el reproductor del teléfono.
    _subs.add(
      _player.stream.buffering.listen((b) {
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
  }

  // ─────────────────────────── Empuje de estado ─────────────────────────────

  void _startStatusPush() {
    // ~2 veces por segundo (500ms), como pide el brief.
    _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _pushStatus();
    });
  }

  void _pushStatus() {
    if (!_service.hasClient.value) return;
    try {
      final playing = _player.state.playing;
      final buffering = _player.state.buffering;
      final pos = _player.state.position;
      final dur = _player.state.duration;

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

      _service.sendEvent(TvProto.evtStatus, {
        'state': state,
        'position': pos.inMilliseconds / 1000.0,
        'duration': dur.inMilliseconds / 1000.0,
        'playing': playing,
        'bufferPercent': _bufferPercent(),
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
      if (mounted) setState(() => _controlsVisible = false);
    });
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
    if (!_hasMedia) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final bool held = event is KeyRepeatEvent;

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
      if (select) {
        _commitPreviewSeek();
        setState(() => _focusArea = 0);
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
    _commandSub?.cancel();
    _hideControlsTimer?.cancel();
    _seekDebounce?.cancel();
    _focusNode.dispose();
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
    return Scaffold(
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
                )
                : _WaitingScreen(deviceName: _deviceName),
            // Spinner de carga idéntico al del reproductor del teléfono.
            if (_hasMedia && _buffering)
              const Center(
                child: _AppLoadingAnimation(size: 54, strokeWidth: 4),
              ),
            if (_hasMedia && _controlsVisible)
              _TvControlsOverlay(
                position: _previewing ? _previewPos : _position,
                duration: _duration,
                playing: _playing,
                focusArea: _focusArea,
                previewing: _previewing,
                title: _mediaTitle,
                thumbnailUrl: _mediaThumb,
              ),
          ],
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
  final bool playing;
  final int focusArea;
  final bool previewing;
  final String title;
  final String? thumbnailUrl;

  const _TvControlsOverlay({
    required this.position,
    required this.duration,
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
          // Botón de play en el CENTRO: solo aparece cuando el video está en
          // PAUSA; al reanudar desaparece (◀/▶ saltan ±10s directo).
          if (!playing)
            Center(
              child: _CtrlButton(
                icon: Icons.play_arrow_rounded,
                focused: focusArea == 0,
                big: true,
              ),
            ),
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
                          // Fila: tiempo actual · barra · duración total.
                          Row(
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
                                    final barHeight =
                                        timelineFocused ? 7.0 : 5.0;
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
                          const SizedBox(height: 14),
                          // Título del contenido, debajo de la barra (como la foto).
                          if (title.isNotEmpty)
                            Text(
                              _displayTitle(title),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 21,
                                fontWeight: FontWeight.w400,
                              ),
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
      duration: const Duration(seconds: 2),
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
