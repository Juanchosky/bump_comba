import 'dart:async';
import 'package:bonsoir/bonsoir.dart';
import 'package:cast/cast.dart';
import 'package:flutter/foundation.dart';

/// Servicio singleton para descubrir y controlar dispositivos Chromecast.
///
/// Usa bonsoir directamente para el descubrimiento (la implementación interna
/// de CastDiscoveryService tiene un bug con bonsoir 5.x que causa puertos
/// incorrectos). Después usa CastSession para la conexión Cast v2.
class CastService {
  CastService._();
  static final CastService _instance = CastService._();
  factory CastService() => _instance;

  CastSession? _session;
  CastDevice? _connectedDevice;
  final ValueNotifier<CastSessionState?> sessionState =
      ValueNotifier<CastSessionState?>(null);
  final ValueNotifier<bool> isCasting = ValueNotifier<bool>(false);

  // ─── Estado de reproducción sincronizado ───
  final ValueNotifier<Duration> castPosition = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> castDuration = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> castPlaying = ValueNotifier(false);
  final ValueNotifier<String> castPlayerState = ValueNotifier('IDLE');
  final ValueNotifier<bool> castMediaFinished = ValueNotifier(false);

  /// Última posición conocida antes de una posible desconexión o stall.
  Duration lastKnownPosition = Duration.zero;

  StreamSubscription? _stateSubscription;
  StreamSubscription? _messageSubscription;
  Timer? _statusPollTimer;

  CastDevice? get connectedDevice => _connectedDevice;

  /// Puerto estándar de Cast v2 (todos los Chromecast y dispositivos compatibles).
  static const int _kCastPort = 8009;

  /// Busca dispositivos Chromecast en la red local usando bonsoir directamente.
  ///
  /// El paquete `cast` tiene un bug en su CastDiscoveryService que extrae
  /// incorrectamente el host/port del servicio resuelto con bonsoir 5.x,
  /// causando errores "No route to host" en puertos incorrectos.
  Future<List<CastDevice>> discoverDevices({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final results = <CastDevice>[];

    try {
      final discovery = BonsoirDiscovery(type: '_googlecast._tcp');
      await discovery.ready;

      discovery.eventStream!.listen(
        (event) {
          if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
            // Solicitar resolución del servicio para obtener IP y puerto
            event.service?.resolve(discovery.serviceResolver);
          } else if (event.type ==
              BonsoirDiscoveryEventType.discoveryServiceResolved) {
            final service = event.service;
            if (service == null) return;

            // Extraer IP y puerto del servicio resuelto
            final String? host = _extractHost(service);
            final int port = service.port > 0 ? service.port : _kCastPort;

            if (host == null || host.isEmpty) {
              debugPrint(
                'CastService: Skipping device with no host: ${service.name}',
              );
              return;
            }

            // Extraer nombre amigable de los atributos TXT
            final attrs = service.attributes;
            String friendlyName = [
              attrs['md'], // Modelo del dispositivo
              attrs['fn'], // Nombre amigable
            ].whereType<String>().where((s) => s.isNotEmpty).join(' - ');

            if (friendlyName.isEmpty) {
              friendlyName = service.name;
            }

            debugPrint(
              'CastService: Found device "$friendlyName" at $host:$port '
              '(service: ${service.name})',
            );

            results.add(
              CastDevice(
                serviceName: service.name,
                name: friendlyName,
                host: host,
                port: port,
              ),
            );
          } else if (event.type ==
              BonsoirDiscoveryEventType.discoveryServiceLost) {
            debugPrint('CastService: Device lost: ${event.service?.name}');
          }
        },
        onError: (error) {
          debugPrint('CastService: Discovery error: $error');
        },
      );

      await discovery.start();
      await Future.delayed(timeout);
      await discovery.stop();

      // Deduplicar por serviceName
      final seen = <String>{};
      final unique = <CastDevice>[];
      for (final d in results) {
        if (seen.add(d.serviceName)) unique.add(d);
      }

      return unique;
    } catch (e) {
      debugPrint('CastService: Error discovering devices: $e');
      return results;
    }
  }

  /// Extrae la IP del host de un servicio bonsoir resuelto.
  ///
  /// Bonsoir 5.x cambiaron las claves JSON respecto a versiones anteriores.
  /// Probamos múltiples accesos para máxima compatibilidad.
  String? _extractHost(BonsoirService service) {
    // 1. Propiedad directa (BonsoirService resuelto en bonsoir 5.x)
    if (service is ResolvedBonsoirService) {
      final host = service.host;
      if (host != null && host.isNotEmpty) return host;
    }

    // 2. Fallback: buscar en el JSON del servicio
    try {
      final json = service.toJson();
      // Bonsoir 5.x usa 'service.host' o 'host'
      final candidates = [
        json['host'],
        json['service.host'],
        json['service.ip'],
        json['ip'],
      ];
      for (final candidate in candidates) {
        if (candidate is String && candidate.isNotEmpty) return candidate;
      }
    } catch (_) {}

    return null;
  }

  /// Conecta a un dispositivo Chromecast y lanza el receptor de medios predeterminado.
  ///
  /// Espera hasta que la sesión esté completamente conectada al transport del
  /// media receiver antes de retornar `true`. Esto evita que el LOAD se envíe
  /// a "receiver-0" en vez del transport correcto.
  Future<bool> connectToDevice(CastDevice device) async {
    try {
      await disconnect(); // Limpiar sesión previa

      // Asegurar que usamos el puerto correcto (8009 estándar para Cast v2)
      CastDevice targetDevice = device;
      if (device.port != _kCastPort && device.port != 0) {
        debugPrint(
          'CastService: Device port ${device.port} is non-standard, '
          'trying with $_kCastPort',
        );
        targetDevice = CastDevice(
          serviceName: device.serviceName,
          name: device.name,
          host: device.host,
          port: _kCastPort,
        );
      } else if (device.port == 0) {
        targetDevice = CastDevice(
          serviceName: device.serviceName,
          name: device.name,
          host: device.host,
          port: _kCastPort,
        );
      }

      debugPrint(
        'CastService: Connecting to "${targetDevice.name}" '
        'at ${targetDevice.host}:${targetDevice.port}',
      );

      _session = await CastSessionManager().startSession(
        targetDevice,
        const Duration(seconds: 10),
      );
      _connectedDevice = targetDevice;

      // Completer que se completa cuando el session state llega a connected
      final connectedCompleter = Completer<bool>();

      _stateSubscription = _session!.stateStream.listen((state) {
        sessionState.value = state;
        debugPrint('CastService: Session state → $state');
        if (state == CastSessionState.connected) {
          isCasting.value = true;
          if (!connectedCompleter.isCompleted) {
            connectedCompleter.complete(true);
          }
        } else if (state == CastSessionState.closed) {
          isCasting.value = false;
          _connectedDevice = null;
          _stopStatusPolling();
          if (!connectedCompleter.isCompleted) {
            connectedCompleter.complete(false);
          }
        }
      });

      _messageSubscription = _session!.messageStream.listen((message) {
        _handleReceiverMessage(message);
      });

      // Lanzar el Default Media Receiver (CC1AD845)
      _session!.sendMessage(CastSession.kNamespaceReceiver, {
        'type': 'LAUNCH',
        'appId': 'CC1AD845', // Default Media Receiver
        'requestId': 1,
      });

      // Esperar hasta que la sesión esté CONNECTED al transport del receiver
      // (esto garantiza que el transport ID está disponible para enviar LOAD)
      final connected = await connectedCompleter.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          debugPrint('CastService: Timeout waiting for connected state');
          return false;
        },
      );

      if (connected) {
        // Dar un momento extra para que el segundo CONNECT al transport
        // se establezca completamente (senderConnected: true)
        await Future.delayed(const Duration(milliseconds: 500));
        debugPrint('CastService: Session fully connected, ready to load media');
        _startStatusPolling();
      }

      return connected;
    } catch (e) {
      debugPrint('CastService: Error connecting to device: $e');
      isCasting.value = false;
      _connectedDevice = null;
      return false;
    }
  }

  String? _mediaSessionId;
  String? _transportId;
  int _requestId = 10; // Empezar alto para no colisionar con LAUNCH/LOAD

  // ─── Fallback automático para LOAD_FAILED ───
  String? _pendingFallbackUrl;
  String? _pendingFallbackTitle;
  String? _pendingFallbackThumb;
  double _pendingFallbackPosition = 0.0;
  bool _isFallbackAttempt = false;

  // ─── Flag para suprimir FINISHED espurio durante la carga de un nuevo medio ───
  // El Chromecast envía IDLE/FINISHED del episodio anterior justo antes de
  // procesar el nuevo LOAD. Este flag evita que esa señal llegue a la UI.
  bool _isLoadingMedia = false;
  Timer? _loadingMediaTimer;

  // ─── Polling de estado para sincronización ───

  /// Inicia polling periódico de GET_STATUS al Chromecast.
  /// - Media heartbeat: cada 1 segundo (sincronización fina de posición)
  /// - Receiver heartbeat: cada 3 segundos (mantiene el socket vivo con menos ruido)
  void _startStatusPolling() {
    _stopStatusPolling();
    int pollTick = 0;
    _statusPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      pollTick++;
      _requestMediaStatus(sendReceiverHeartbeat: pollTick % 3 == 0);
    });
  }

  void _stopStatusPolling() {
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
  }

  /// Solicita el estado actual de media y del receiver al Chromecast.
  /// [sendReceiverHeartbeat] controla si también se envía heartbeat al receptor
  /// (cada 3 segundos es suficiente para mantener el socket vivo).
  void _requestMediaStatus({bool sendReceiverHeartbeat = false}) {
    if (_session == null) return;

    // 1. Heartbeat al Media Player (sincronización de posición — cada segundo)
    if (_mediaSessionId != null) {
      _session!.sendMessage(CastSession.kNamespaceMedia, {
        'type': 'GET_STATUS',
        'requestId': _requestId++,
        'mediaSessionId': int.tryParse(_mediaSessionId!) ?? _mediaSessionId,
      });
    }

    // 2. Heartbeat al Receiver (mantiene el socket v2 vivo — cada 3 segundos)
    if (sendReceiverHeartbeat) {
      _session!.sendMessage(CastSession.kNamespaceReceiver, {
        'type': 'GET_STATUS',
        'requestId': _requestId++,
      });
    }
  }

  void _handleReceiverMessage(Map<String, dynamic> message) {
    final type = message['type'];
    if (type == 'RECEIVER_STATUS') {
      final status = message['status'];
      if (status != null && status['applications'] != null) {
        final apps = status['applications'] as List;
        if (apps.isNotEmpty) {
          _transportId = apps[0]['transportId'];
          _mediaSessionId = null;
          debugPrint('CastService: Transport ID = $_transportId');
        }
      }
    } else if (type == 'MEDIA_STATUS') {
      _handleMediaStatus(message);
    } else if (type == 'LOAD_FAILED') {
      debugPrint('CastService: ⚠️ LOAD_FAILED received');
      _handleLoadFailed();
    }
  }

  /// Procesa MEDIA_STATUS para sincronizar posición, duración y estado.
  void _handleMediaStatus(Map<String, dynamic> message) {
    final statusList = message['status'];
    if (statusList is! List || statusList.isEmpty) return;

    final status = statusList[0] as Map<String, dynamic>;

    // Media Session ID
    if (status['mediaSessionId'] != null) {
      _mediaSessionId = status['mediaSessionId'].toString();
    }

    // Posición actual (en segundos, como double)
    final currentTime = status['currentTime'];
    if (currentTime is num) {
      final pos = Duration(milliseconds: (currentTime * 1000).toInt());
      castPosition.value = pos;
      if (pos > Duration.zero) {
        lastKnownPosition = pos;
      }
    }

    // Duración del contenido
    final media = status['media'];
    if (media is Map<String, dynamic>) {
      final duration = media['duration'];
      if (duration is num && duration > 0) {
        castDuration.value = Duration(milliseconds: (duration * 1000).toInt());
      }
    }

    // Estado de reproducción
    final playerState = status['playerState']?.toString() ?? 'IDLE';
    castPlayerState.value = playerState;
    castPlaying.value = playerState == 'PLAYING';

    // Si el estado es IDLE con razón FINISHED, dejamos de pollear
    if (playerState == 'IDLE') {
      final idleReason = status['idleReason']?.toString();
      if (idleReason == 'FINISHED') {
        // Suprimir la señal si estamos en plena carga de un nuevo medio.
        // El Chromecast emite FINISHED del episodio anterior antes de procesar
        // el nuevo LOAD, lo que causaría un bucle infinito de episodios.
        if (_isLoadingMedia) {
          debugPrint(
            'CastService: FINISHED suppressed (new LOAD in progress)',
          );
          return;
        }
        debugPrint('CastService: Playback finished');
        castPlaying.value = false;
        castMediaFinished.value = true;
      }
    }
  }

  /// Maneja LOAD_FAILED: si tenemos una URL de fallback, reintenta con ella.
  void _handleLoadFailed() {
    if (_pendingFallbackUrl != null && !_isFallbackAttempt) {
      debugPrint(
        'CastService: Retrying with original URL (fallback): '
        '$_pendingFallbackUrl',
      );
      _isFallbackAttempt = true;
      _sendLoadMessage(
        url: _pendingFallbackUrl!,
        title: _pendingFallbackTitle ?? '',
        thumbnailUrl: _pendingFallbackThumb,
        startPosition: _pendingFallbackPosition,
      );
      _pendingFallbackUrl = null;
    } else {
      debugPrint('CastService: LOAD_FAILED — no fallback available');
      _pendingFallbackUrl = null;
      _isFallbackAttempt = false;
    }
  }

  /// Envía un video al Chromecast con la URL y título dados.
  ///
  /// Para URLs de Xtream IPTV, intenta primero con .m3u8 (HLS/AAC audio).
  /// Si el Chromecast responde con LOAD_FAILED, automáticamente reintenta
  /// con la URL original (.mp4).
  Future<void> loadMedia({
    required String url,
    required String title,
    String? thumbnailUrl,
    String contentType = 'video/mp4',
    double startPosition = 0.0,
  }) async {
    if (_session == null) {
      debugPrint('CastService: No active session');
      return;
    }

    // Esperar a que la sesión esté conectada (safety net)
    if (sessionState.value != CastSessionState.connected) {
      debugPrint('CastService: Waiting for connected state before LOAD...');
      for (int i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (sessionState.value == CastSessionState.connected) break;
        if (_session == null) return;
      }
      if (sessionState.value != CastSessionState.connected) {
        debugPrint('CastService: Still not connected, aborting LOAD');
        return;
      }
    }

    // Reset estado de sincronización
    castPosition.value = Duration.zero;
    castDuration.value = Duration.zero;
    castPlaying.value = false;
    castMediaFinished.value = false;

    // Suprimir FINISHED espurios del episodio anterior durante la transición.
    // El Chromecast tarda ~2-3 segundos en procesar el nuevo LOAD y puede
    // emitir IDLE/FINISHED del contenido anterior en ese intervalo.
    _isLoadingMedia = true;
    _loadingMediaTimer?.cancel();
    _loadingMediaTimer = Timer(const Duration(seconds: 4), () {
      _isLoadingMedia = false;
    });

    // ─── Xtream/IPTV Optimization: Force HLS for Audio Compatibility ───
    String castUrl = url;
    _isFallbackAttempt = false;
    _pendingFallbackUrl = null;

    // Detectar si es una URL de IPTV (por patrón o por puertos comunes de Xtream)
    final isIptv =
        url.contains('/movie/') ||
        url.contains('/series/') ||
        url.contains('/live/') ||
        url.contains('output=') ||
        RegExp(r':(80|8080|25461|2095|2082|2086)/').hasMatch(url);

    if (isIptv && !url.contains('.m3u8') && !url.contains('output=m3u8')) {
      _pendingFallbackUrl = url;
      _pendingFallbackTitle = title;
      _pendingFallbackThumb = thumbnailUrl;
      _pendingFallbackPosition = startPosition;

      // Intentamos convertir a HLS (.m3u8) que es el "estándar de oro" para Cast.
      // Los servidores IPTV suelen tener un transcodificador AAC para HLS.
      if (castUrl.contains('.')) {
        castUrl = castUrl.replaceFirst(
          RegExp(r'\.(mp4|mkv|avi|ts)$', caseSensitive: false),
          '.m3u8',
        );
      }

      if (castUrl.contains('output=ts')) {
        castUrl = castUrl.replaceFirst('output=ts', 'output=m3u8');
      } else if (!castUrl.contains('output=')) {
        castUrl += castUrl.contains('?') ? '&output=m3u8' : '?output=m3u8';
      }

      debugPrint(
        'CastService: IPTV/VOD optimization. Forcing HLS (.m3u8) for maximum audio compatibility.',
      );
    }

    _sendLoadMessage(
      url: castUrl,
      title: title,
      thumbnailUrl: thumbnailUrl,
      startPosition: startPosition,
    );
  }

  /// Envía el mensaje LOAD al Chromecast (usado por loadMedia y el fallback).
  void _sendLoadMessage({
    required String url,
    required String title,
    String? thumbnailUrl,
    double startPosition = 0.0,
  }) {
    if (_session == null) return;

    // Auto-detectar tipo de contenido
    final lowUrl = url.toLowerCase();
    String resolvedContentType = 'video/mp4';
    if (lowUrl.contains('.m3u8') || lowUrl.contains('type=m3u8')) {
      resolvedContentType = 'application/x-mpegURL';
    } else if (lowUrl.contains('.mpd')) {
      resolvedContentType = 'application/dash+xml';
    } else if (lowUrl.endsWith('.ts') || lowUrl.contains('.ts')) {
      resolvedContentType = 'video/mp2t';
    } else if (lowUrl.endsWith('.mkv') || lowUrl.contains('.mkv')) {
      resolvedContentType = 'video/x-matroska';
    } else if (lowUrl.endsWith('.avi') || lowUrl.contains('.avi')) {
      resolvedContentType = 'video/x-msvideo';
    } else if (lowUrl.endsWith('.mov') || lowUrl.contains('.mov')) {
      resolvedContentType = 'video/quicktime';
    }

    // Determinar tipo de stream
    final bool isLive =
        lowUrl.contains('/live/') || lowUrl.contains('type=live');
    final String streamType = isLive ? 'LIVE' : 'BUFFERED';

    // Pre-buffer agresivo: pedimos al Chromecast que bufferee 60s por adelantado.
    // Esto reduce las pausas en VOD serie porque el TV tiene más datos listos
    // antes de necesitarlos (especialmente útil en conexiones Wi-Fi compartidas).
    final int preloadSeconds = isLive ? 15 : 60;

    final Map<String, dynamic> mediaInfo = {
      'contentId': url,
      'contentType': resolvedContentType,
      'streamType': streamType,
      'metadata': {
        'type': 0,
        'metadataType': 0,
        'title': title,
        if (thumbnailUrl != null)
          'images': [
            {'url': thumbnailUrl},
          ],
      },
      // Pre-buffer hint: el receptor empieza a descargar $preloadSeconds segundos
      // por adelantado de la posición de reproducción actual.
      'preloadTime': preloadSeconds,
      // Configuración de reproducción para el Default Media Receiver v3
      'playbackConfig': {
        // Iniciar reproducción solo cuando haya al menos 5 segundos en buffer
        'initialBandwidth': 10000000, // 10 Mbps hint para elección de bitrate
        'protocolType': isLive ? 0 : 1, // 0=HLS, 1=DASH (hint)
      },
      // HACK para audio: Algunos receptores activan decodificadores extra con estas flags
      'customData': {
        'audioConfig': {'bitrate': 128000, 'channels': 2},
        'hlsSegmentFormat': 'FMP4',
        'hlsVideoType': 'MPEG_TS_H264_AAC',
      },
    };

    // Usar requestId único para cada LOAD — evita que el Chromecast duplique
    // mensajes o ignore el LOAD por considerarlo repetido (bug del Default Receiver)
    final int loadRequestId = _requestId++;

    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'LOAD',
      'requestId': loadRequestId,
      'media': mediaInfo,
      'autoplay': true,
      'currentTime': startPosition,
      // Reproducir inmediatamente sin esperar a que el buffer llene (el TV
      // gestiona el pre-buffer internamente con 'preloadTime').
      'activeTrackIds': [],
    });

    debugPrint(
      'CastService: 🚀 LOADING MEDIA 🚀\n'
      '   - Title: $title\n'
      '   - URL: $url\n'
      '   - MIME: $resolvedContentType\n'
      '   - Stream: $streamType\n'
      '   - Fallback Attempt: $_isFallbackAttempt',
    );
  }

  // ─── Controles de reproducción ───

  /// Pausa la reproducción en el Chromecast.
  void pause() {
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'PAUSE',
      'requestId': _requestId++,
      'mediaSessionId': int.tryParse(_mediaSessionId!) ?? _mediaSessionId,
    });
  }

  /// Reanuda la reproducción en el Chromecast.
  void play() {
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'PLAY',
      'requestId': _requestId++,
      'mediaSessionId': int.tryParse(_mediaSessionId!) ?? _mediaSessionId,
    });
  }

  /// Detiene la reproducción y cierra la app del receptor.
  void stop() {
    if (_session == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'STOP',
      'requestId': _requestId++,
      if (_mediaSessionId != null)
        'mediaSessionId': int.tryParse(_mediaSessionId!) ?? _mediaSessionId,
    });
  }

  /// Busca a una posición específica (en segundos).
  void seek(double positionSeconds) {
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'SEEK',
      'requestId': _requestId++,
      'currentTime': positionSeconds,
      'mediaSessionId': int.tryParse(_mediaSessionId!) ?? _mediaSessionId,
    });
    // Actualizar posición local inmediatamente para feedback visual rápido
    castPosition.value = Duration(
      milliseconds: (positionSeconds * 1000).toInt(),
    );
  }

  /// Avanza 10 segundos.
  void seekForward({int seconds = 10}) {
    final newPos = castPosition.value.inSeconds + seconds;
    final maxPos = castDuration.value.inSeconds;
    seek((newPos > maxPos ? maxPos : newPos).toDouble());
  }

  /// Retrocede 10 segundos.
  void seekBackward({int seconds = 10}) {
    final newPos = castPosition.value.inSeconds - seconds;
    seek((newPos < 0 ? 0 : newPos).toDouble());
  }

  /// Cambia la pista de audio activa en el Chromecast.
  ///
  /// [trackId] es el ID numérico del track dentro del media actual.
  /// Los tracks se obtienen del MEDIA_STATUS del Chromecast.
  void setActiveAudioTrack(int trackId) {
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'EDIT_TRACKS_INFO',
      'requestId': _requestId++,
      'activeTrackIds': [trackId],
      'mediaSessionId': int.tryParse(_mediaSessionId!) ?? _mediaSessionId,
    });
    debugPrint('CastService: Set active audio track → $trackId');
  }

  /// Desconecta del dispositivo Chromecast actual.
  Future<void> disconnect() async {
    try {
      _stopStatusPolling();
      _loadingMediaTimer?.cancel();
      _loadingMediaTimer = null;
      _isLoadingMedia = false;
      if (_session != null) {
        try {
          stop();
          await _session!.close();
        } catch (_) {}
      }
      _stateSubscription?.cancel();
      _messageSubscription?.cancel();
      _stateSubscription = null;
      _messageSubscription = null;
      _session = null;
      _connectedDevice = null;
      _transportId = null;
      _mediaSessionId = null;
      _pendingFallbackUrl = null;
      isCasting.value = false;
      sessionState.value = null;
      castPosition.value = Duration.zero;
      castDuration.value = Duration.zero;
      castPlaying.value = false;
      castPlayerState.value = 'IDLE';
    } catch (e) {
      debugPrint('CastService: Error disconnecting: $e');
    }
  }

  bool get isConnected =>
      _session != null && sessionState.value == CastSessionState.connected;
}
