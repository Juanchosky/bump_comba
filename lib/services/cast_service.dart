import 'dart:async';
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'package:cast/cast.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/tv/tv_protocol.dart';
import '../services/tv/tv_sender.dart';
import '../services/tv/tv_platform.dart';

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

  /// Pistas de audio/subtítulos reportadas por el receptor (MiApp TV).
  /// Cada elemento: {id, title, language}. La UI las consume igual que las del
  /// Chromecast.
  final ValueNotifier<List<Map<String, dynamic>>> castAudioTracks =
      ValueNotifier(const []);
  final ValueNotifier<List<Map<String, dynamic>>> castSubtitleTracks =
      ValueNotifier(const []);

  // ─── Backend dual: MiApp TV (receptor propio vía WebSocket) ───
  TvSender? _tvSender;

  /// `true` cuando la sesión activa usa el backend MiApp TV en vez de Cast v2.
  bool get isTvBackend => _tvSender != null;

  /// serviceNames de los dispositivos descubiertos que son MiApp TV (no
  /// Chromecast). Permite a [connectToDevice] elegir el backend correcto.
  final Set<String> _tvServiceNames = <String>{};

  /// `true` si el dispositivo dado es un receptor propio MiApp TV.
  bool isTvDevice(CastDevice device) =>
      _tvServiceNames.contains(device.serviceName);

  static const String _kLastTvHostKey = 'last_tv_host';
  static const String _kLastTvNameKey = 'last_tv_name';

  // ─── Estado de reconexión persistente (error crítico #5 y #6) ───
  CastDevice? _tvDevice;
  bool _tvUserDisconnected = false;
  Timer? _tvReconnectTimer;
  int _tvReconnectAttempt = 0;
  DateTime? _tvReconnectStartedAt;

  /// Última media enviada al TV: para decidir en la reconexión si nos
  /// adjuntamos sin reenviar LOAD (el TV reproduce solo aunque el teléfono se
  /// caiga).
  String? _tvLastUrl;
  String? _tvLastTitle;
  String? _tvLastThumb;
  Map<String, String>? _tvLastHeaders;
  String? _tvLastSeriesName;
  int? _tvLastSeason;
  int? _tvLastEpisode;

  /// Durante una reconexión: esperamos el primer STATUS para decidir si
  /// readjuntarnos o recargar. Guarda la posición esperada.
  bool _tvReattaching = false;
  Duration _tvExpectedPosition = Duration.zero;

  /// Máximo tiempo continuo de fallos antes de rendirse (batería).
  static const Duration _kTvReconnectGiveUp = Duration(minutes: 5);

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
    // Buscamos en PARALELO los Chromecast (_googlecast._tcp) y los receptores
    // propios MiApp TV (_bumpcombatv._tcp).
    _tvServiceNames.clear();

    final resultsFuture = Future.wait([
      _discoverType('_googlecast._tcp', timeout, isTv: false),
      _discoverType(TvProto.serviceType, timeout, isTv: true),
    ]);

    final lists = await resultsFuture;
    final chromecasts = lists[0];
    final tvs = lists[1];

    // mDNS es intermitente (error crítico #7): si no apareció ningún MiApp TV,
    // intentamos el último TV conocido por sondeo TCP directo.
    if (tvs.isEmpty) {
      final probed = await _probeLastKnownTv();
      if (probed != null) {
        _tvServiceNames.add(probed.serviceName);
        tvs.add(probed);
      }
    } else {
      // Persistir el primer TV visto para el sondeo futuro.
      await _persistLastTv(tvs.first);
    }

    // Deduplicar por serviceName, MiApp TV PRIMERO.
    final seen = <String>{};
    final ordered = <CastDevice>[];
    for (final d in [...tvs, ...chromecasts]) {
      if (seen.add(d.serviceName)) ordered.add(d);
    }
    return ordered;
  }

  /// Descubre un tipo mDNS concreto y devuelve los dispositivos resueltos.
  /// Si [isTv] es `true`, marca cada serviceName como MiApp TV.
  Future<List<CastDevice>> _discoverType(
    String type,
    Duration timeout, {
    required bool isTv,
  }) async {
    final results = <CastDevice>[];
    try {
      final discovery = BonsoirDiscovery(type: type);
      await discovery.ready;

      discovery.eventStream!.listen(
        (event) {
          if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
            event.service?.resolve(discovery.serviceResolver);
          } else if (event.type ==
              BonsoirDiscoveryEventType.discoveryServiceResolved) {
            final service = event.service;
            if (service == null) return;

            final String? host = _extractHost(service);
            final int port =
                service.port > 0 ? service.port : (isTv ? TvProto.port : _kCastPort);

            if (host == null || host.isEmpty) {
              debugPrint(
                'CastService: Skipping device with no host: ${service.name}',
              );
              return;
            }

            String friendlyName;
            if (isTv) {
              friendlyName = service.name;
            } else {
              final attrs = service.attributes;
              friendlyName = [
                attrs['md'], // Modelo del dispositivo
                attrs['fn'], // Nombre amigable
              ].whereType<String>().where((s) => s.isNotEmpty).join(' - ');
              if (friendlyName.isEmpty) friendlyName = service.name;
            }

            debugPrint(
              'CastService: Found ${isTv ? "MiApp TV" : "Chromecast"} '
              '"$friendlyName" at $host:$port (service: ${service.name})',
            );

            if (isTv) _tvServiceNames.add(service.name);
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
          debugPrint('CastService: Discovery error ($type): $error');
        },
      );

      await discovery.start();
      await Future.delayed(timeout);
      await discovery.stop();
    } catch (e) {
      debugPrint('CastService: Error discovering $type: $e');
    }
    return results;
  }

  /// Guarda el host/nombre del último MiApp TV visto (para sondeo TCP futuro).
  Future<void> _persistLastTv(CastDevice device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastTvHostKey, device.host);
      await prefs.setString(_kLastTvNameKey, device.name);
    } catch (_) {}
  }

  /// Sondea por TCP el último MiApp TV conocido. Si responde en el puerto fijo,
  /// lo devuelve como dispositivo aunque el mDNS no lo haya encontrado.
  Future<CastDevice?> _probeLastKnownTv() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final host = prefs.getString(_kLastTvHostKey);
      final name = prefs.getString(_kLastTvNameKey) ?? 'Bump Comba TV';
      if (host == null || host.isEmpty) return null;

      final socket = await Socket.connect(
        host,
        TvProto.port,
        timeout: const Duration(milliseconds: 1200),
      );
      socket.destroy();
      debugPrint('CastService: MiApp TV recuperado por sondeo TCP: $host');
      return CastDevice(
        serviceName: 'tv-$host',
        name: name,
        host: host,
        port: TvProto.port,
      );
    } catch (e) {
      debugPrint('CastService: sondeo TCP del último TV falló: $e');
      return null;
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
    // ── Backend MiApp TV (receptor propio) ──
    if (isTvDevice(device)) {
      return _connectToTv(device);
    }
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
    Map<String, String>? headers,
    String? seriesName,
    int? season,
    int? episode,
  }) async {
    // ── Backend MiApp TV: enviamos la URL ORIGINAL (media_kit reproduce
    // MKV/AC3 directamente) con sus headers, sin conversión HLS. ──
    if (isTvBackend) {
      castPosition.value = Duration.zero;
      castDuration.value = Duration.zero;
      castPlaying.value = false;
      castMediaFinished.value = false;
      // Recordar la media para poder recargar tras una reconexión si el TV ya
      // no la está reproduciendo.
      _tvLastUrl = url;
      _tvLastTitle = title;
      _tvLastThumb = thumbnailUrl;
      _tvLastHeaders = headers;
      _tvLastSeriesName = seriesName;
      _tvLastSeason = season;
      _tvLastEpisode = episode;
      _tvReattaching = false; // es una carga explícita del usuario
      _tvSender?.load(
        url: url,
        title: title,
        position: startPosition,
        headers: headers,
        thumbnailUrl: thumbnailUrl,
        seriesName: seriesName,
        season: season,
        episode: episode,
      );
      return;
    }

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
    if (isTvBackend) {
      _tvSender?.pause();
      // Intención optimista (error crítico #8): reflejamos la pausa al instante.
      castPlaying.value = false;
      castPlayerState.value = 'PAUSED';
      return;
    }
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'PAUSE',
      'requestId': _requestId++,
      'mediaSessionId': int.tryParse(_mediaSessionId!) ?? _mediaSessionId,
    });
  }

  /// Reanuda la reproducción en el Chromecast.
  void play() {
    if (isTvBackend) {
      _tvSender?.play();
      castPlaying.value = true;
      castPlayerState.value = 'PLAYING';
      return;
    }
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'PLAY',
      'requestId': _requestId++,
      'mediaSessionId': int.tryParse(_mediaSessionId!) ?? _mediaSessionId,
    });
  }

  /// Detiene la reproducción y cierra la app del receptor.
  void stop() {
    if (isTvBackend) {
      _tvSender?.stop();
      return;
    }
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
    if (isTvBackend) {
      _tvSender?.seek(positionSeconds);
      castPosition.value =
          Duration(milliseconds: (positionSeconds * 1000).toInt());
      return;
    }
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
  void setActiveAudioTrack(int trackId, {String? trackStringId}) {
    if (isTvBackend) {
      // El receptor usa el id de pista de media_kit (String, p. ej. "1").
      _tvSender?.setAudio(trackStringId ?? trackId.toString());
      return;
    }
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'EDIT_TRACKS_INFO',
      'requestId': _requestId++,
      'activeTrackIds': [trackId],
      'mediaSessionId': int.tryParse(_mediaSessionId!) ?? _mediaSessionId,
    });
    debugPrint('CastService: Set active audio track → $trackId');
  }

  // ══════════════════════════ Backend MiApp TV ══════════════════════════════

  /// Conecta al receptor propio por WebSocket y cablea sus eventos a los MISMOS
  /// ValueNotifier que usa el resto de la UI.
  Future<bool> _connectToTv(CastDevice device) async {
    await disconnect();
    _tvUserDisconnected = false;
    _tvDevice = device;

    final ok = await _openTvSocket(device);
    if (!ok) {
      isCasting.value = false;
      _tvDevice = null;
      return false;
    }

    _connectedDevice = device;
    isCasting.value = true;
    sessionState.value = CastSessionState.connected;

    // Reset de estado de sincronización.
    castPosition.value = Duration.zero;
    castDuration.value = Duration.zero;
    castPlaying.value = false;
    castPlayerState.value = 'IDLE';
    castMediaFinished.value = false;
    castAudioTracks.value = const [];
    castSubtitleTracks.value = const [];

    // Mantener CPU + Wi-Fi vivos mientras dure la transmisión.
    unawaited(TvPlatform.acquireCastLocks());

    return true;
  }

  /// Abre (o reabre) el socket al TV y arranca el keepalive. No toca el estado
  /// de la UI para poder reutilizarse en la reconexión.
  Future<bool> _openTvSocket(CastDevice device) async {
    final sender = TvSender(
      onEvent: _handleTvEvent,
      onClosed: _onTvSocketClosed,
    );
    final ok = await sender.connect(device.host, device.port);
    if (!ok) return false;

    _tvSender = sender;

    // Keepalive: PING cada 3s para mantener el socket con tráfico.
    _stopStatusPolling();
    _statusPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _tvSender?.ping();
    });
    return true;
  }

  /// El socket al TV se cayó (no por acción del usuario): inicia reconexión.
  void _onTvSocketClosed() {
    debugPrint('CastService: MiApp TV socket cerrado');
    _stopStatusPolling();
    _tvSender = null;
    if (_tvUserDisconnected || _tvDevice == null) return;
    _scheduleTvReconnect();
  }

  /// Reconexión PERSISTENTE con backoff (error crítico #5). No se rinde a los
  /// pocos intentos: reintenta indefinidamente hasta que el usuario corte o
  /// tras [_kTvReconnectGiveUp] de fallos continuos.
  void _scheduleTvReconnect() {
    if (_tvUserDisconnected || _tvDevice == null) return;
    if (_tvReconnectTimer != null) return; // ya hay uno en curso

    _tvReconnectStartedAt ??= DateTime.now();
    _tvReconnectAttempt++;

    // Backoff: 2s normal, hasta 15s si el TV se reinicia en bucle.
    final int seconds = (2 * _tvReconnectAttempt).clamp(2, 15);
    debugPrint(
      'CastService: reintentando MiApp TV en ${seconds}s '
      '(intento $_tvReconnectAttempt)',
    );

    _tvReconnectTimer = Timer(Duration(seconds: seconds), () async {
      _tvReconnectTimer = null;
      if (_tvUserDisconnected || _tvDevice == null) return;

      // Rendirse solo tras varios minutos continuos de fallo (batería).
      final started = _tvReconnectStartedAt;
      if (started != null &&
          DateTime.now().difference(started) > _kTvReconnectGiveUp) {
        debugPrint('CastService: MiApp TV no responde tras 5 min, rendición');
        await disconnect();
        return;
      }

      // Al reconectar: esperamos el primer STATUS para decidir si nos
      // adjuntamos sin reenviar LOAD (error crítico #6).
      _tvReattaching = _tvLastUrl != null;
      _tvExpectedPosition = castPosition.value;

      final ok = await _openTvSocket(_tvDevice!);
      if (!ok) {
        _tvReattaching = false;
        _scheduleTvReconnect(); // sigue intentando
        return;
      }

      // Conexión recuperada.
      _tvReconnectAttempt = 0;
      _tvReconnectStartedAt = null;
      isCasting.value = true;
      sessionState.value = CastSessionState.connected;
      unawaited(TvPlatform.acquireCastLocks());

      // Red de seguridad: si en 3s no llegó ningún STATUS que confirme que el
      // TV sigue reproduciendo, recargamos la media.
      Timer(const Duration(seconds: 3), () {
        if (_tvReattaching && _tvSender != null) {
          debugPrint('CastService: sin STATUS tras reconexión → recargando');
          _tvReattaching = false;
          _resendLastTvMedia();
        }
      });
    });
  }

  /// Reenvía la última media al TV (usado si el TV ya no la está reproduciendo).
  void _resendLastTvMedia() {
    final url = _tvLastUrl;
    if (url == null) return;
    _tvSender?.load(
      url: url,
      title: _tvLastTitle ?? '',
      position: _tvExpectedPosition.inSeconds.toDouble(),
      headers: _tvLastHeaders,
      thumbnailUrl: _tvLastThumb,
      seriesName: _tvLastSeriesName,
      season: _tvLastSeason,
      episode: _tvLastEpisode,
    );
  }

  /// Traduce un evento del TV a los ValueNotifier compartidos.
  void _handleTvEvent(Map<String, dynamic> event) {
    final type = event[TvProto.kType] as String?;
    switch (type) {
      case TvProto.evtStatus:
        final pos = _asDuration(event['position']);
        final state = event['state']?.toString() ?? 'IDLE';

        // ── Reconexión: decidir si nos adjuntamos sin reenviar LOAD ──
        if (_tvReattaching) {
          _tvReattaching = false;
          final stillPlaying = state == TvProto.statePlaying ||
              state == TvProto.statePaused ||
              state == TvProto.stateBuffering;
          final near = pos != null &&
              (pos - _tvExpectedPosition).abs() < const Duration(seconds: 30);
          if (stillPlaying && near) {
            // El TV sigue reproduciendo cerca de lo esperado: NO recargamos,
            // recargar interrumpiría el video.
            debugPrint('CastService: readjuntado al TV sin recargar');
          } else {
            debugPrint('CastService: TV no reproduce lo esperado → recargando');
            _resendLastTvMedia();
          }
        }

        if (pos != null) {
          castPosition.value = pos;
          if (pos > Duration.zero) lastKnownPosition = pos;
        }
        final dur = _asDuration(event['duration']);
        if (dur != null && dur > Duration.zero) castDuration.value = dur;

        castPlayerState.value = state;
        castPlaying.value = event['playing'] == true;
        break;
      case TvProto.evtLoaded:
        final dur = _asDuration(event['duration']);
        if (dur != null && dur > Duration.zero) castDuration.value = dur;
        break;
      case TvProto.evtAudioTracks:
        castAudioTracks.value = _asMapList(event['tracks']);
        break;
      case TvProto.evtSubtitleTracks:
        castSubtitleTracks.value = _asMapList(event['tracks']);
        break;
      case TvProto.evtEnded:
        castPlaying.value = false;
        castMediaFinished.value = true;
        break;
      case TvProto.evtLoadFailed:
        debugPrint('CastService: MiApp TV LOAD_FAILED: ${event['error']}');
        break;
      case TvProto.evtHello:
        debugPrint('CastService: MiApp TV HELLO de ${event['name']}');
        break;
    }
  }

  Duration? _asDuration(dynamic seconds) {
    if (seconds is num) {
      return Duration(milliseconds: (seconds * 1000).round());
    }
    return null;
  }

  List<Map<String, dynamic>> _asMapList(dynamic v) {
    if (v is List) {
      return v
          .whereType<Map>()
          .map((m) => m.map((k, val) => MapEntry(k.toString(), val)))
          .toList();
    }
    return const [];
  }

  /// Selecciona/desactiva subtítulos en el receptor (solo backend MiApp TV).
  void setActiveSubtitleTrack(String? trackId) {
    if (!isTvBackend) return;
    _tvSender?.setSubtitle(trackId ?? TvProto.subtitleOff);
  }

  /// Desconecta del dispositivo Chromecast actual.
  Future<void> disconnect() async {
    try {
      _stopStatusPolling();
      _loadingMediaTimer?.cancel();
      _loadingMediaTimer = null;
      _isLoadingMedia = false;
      // ── Backend MiApp TV ──
      // Marcar corte del usuario ANTES de cerrar para que onClosed no dispare
      // reconexión.
      _tvUserDisconnected = true;
      _tvReconnectTimer?.cancel();
      _tvReconnectTimer = null;
      _tvReconnectAttempt = 0;
      _tvReconnectStartedAt = null;
      _tvReattaching = false;
      if (_tvSender != null) {
        try {
          _tvSender!.stop();
          await _tvSender!.close();
        } catch (_) {}
        _tvSender = null;
        castAudioTracks.value = const [];
        castSubtitleTracks.value = const [];
        unawaited(TvPlatform.releaseCastLocks());
      }
      _tvDevice = null;
      _tvLastUrl = null;
      _tvLastTitle = null;
      _tvLastThumb = null;
      _tvLastHeaders = null;
      _tvLastSeriesName = null;
      _tvLastSeason = null;
      _tvLastEpisode = null;
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
      isTvBackend ||
      (_session != null && sessionState.value == CastSessionState.connected);
}
