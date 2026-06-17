import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cast/cast.dart';
import '../services/m3u_service.dart';
import '../services/watch_progress_service.dart';
import '../services/cast_audio_handler.dart';
import '../services/ad_service.dart';
import 'package:flutter/foundation.dart';
import '../services/premium_service.dart';
import '../services/game_config_service.dart';
import '../services/fast_image_service.dart';
import '../services/dynamic_scraper_service.dart';
import '../services/performance_service.dart';
import '../services/cast_service.dart';
import '../services/network_quality_service.dart';
import '../services/adaptive_buffer_service.dart';
import 'package:http/http.dart' as http;

import '../utils/snack_bar_utils.dart';
import 'subscription_screen.dart';

class ExitFullscreenIntent extends Intent {
  const ExitFullscreenIntent();
}

class VideoPlayerScreen extends StatefulWidget {
  final M3UItem item;
  final List<M3UItem> playlist;
  final Player? prewarmedPlayer;

  const VideoPlayerScreen({
    super.key,
    required this.item,
    this.playlist = const [],
    this.prewarmedPlayer,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with
        WidgetsBindingObserver,
        AutomaticKeepAliveClientMixin,
        TickerProviderStateMixin {
  final WatchProgressService _watchProgressService = WatchProgressService();
  final GlobalKey<ScaffoldMessengerState> _innerMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  // Adaptive quality
  final NetworkQualityService _networkQuality = NetworkQualityService();
  NetworkQuality? _lastAppliedQuality;
  DateTime? _lastSeekTime;

  static const List<String> _userAgents = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'VLC/3.0.20 LibVLC/3.0.20',
    'Kodi/20.0 (Linux; Android 11)',
    'Mozilla/5.0 (Smart-TV; Linux; Tizen 7.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/7.0 TV Safari/538.1',
    'ExoPlayerLib/2.19.1',
    'okhttp/4.11.0',
  ];

  int _userAgentIndex = 0;

  bool _isScraping = false;
  String? _scrapingError;

  String get _currentUserAgent =>
      _userAgents[_userAgentIndex % _userAgents.length];

  Player? _player;
  // Notifier para forzar reconstrucción del Video widget sin pantalla negra
  final ValueNotifier<VideoController?> _videoControllerNotifier =
      ValueNotifier<VideoController?>(null);

  bool _isVideoLoading = true;
  bool _isBuffering = false;
  bool _midRollAdShown = false;
  bool _midRollNoticeShown = false;
  late M3UItem _currentItem;
  late List<M3UItem> _playlist;
  bool _showControls = false;
  bool _isLandscape = true;
  final ValueNotifier<BoxFit> _videoFitNotifier = ValueNotifier(BoxFit.contain);
  bool _isScaling = false;

  // Stream health monitor
  Timer? _stallTimer;
  final ValueNotifier<Duration> _bufferedDuration = ValueNotifier<Duration>(
    Duration.zero,
  );
  int _stallSeconds = 0;
  bool _isLiveContent = false;
  int _retryCount = 0;

  // Slider dragging state
  bool _isDragging = false;
  bool _hasError = false;
  bool _isSeeking = false;
  bool _isReloading = false; // Re-entrancy guard for _reloadVideo
  Duration _lastPosition = Duration.zero;
  int _noMovementSeconds = 0;
  // Detección de "audio sin video" (pantalla negra con audio) en VOD.
  int _noVideoSeconds = 0;
  bool _blackScreenReloadDone = false;
  double _dragValue = 0.0;
  Timer? _hideControlsTimer;

  // ── Panel de diagnóstico en pantalla (toque largo en el título) ──────────
  bool _showDiagPanel = false;
  String _activeDecoder = '-';
  Timer? _diagTimer;
  // Propiedades consultadas a MPV en vivo para el panel de diagnóstico.
  String _diagCodec = '?';
  String _diagHwdecActivo = '?';
  int _diagVideoTracks = -1;
  String _diagTrackCodecs = '?';
  String _diagVidSel = '?';

  static const platform = MethodChannel('com.juanchosky.bumpcomba/pip');
  bool get _isPiPSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  final List<StreamSubscription> _streamSubscriptions = [];
  Timer? _progressSaveTimer;

  // Auto-play state
  int? _nextEpisodeCountdown;
  Timer? _countdownTimer;
  bool _autoPlayCancelled = false;
  bool _isFastForwarding = false;
  int? _adCountdown;

  int _currentServerIndex = 0;
  List<String> _serverUrls = [];

  // Swipe orientation animation
  double _swipeDragOffset = 0.0;
  late AnimationController _swipeAnimController;
  Animation<double>? _swipeSnapAnim;
  bool _swipeStartedVertically = false;
  int _activePointers = 0;
  // Controls animation
  late AnimationController _controlsAnimController;
  late Animation<double> _controlsAnim;

  // Seek feedback state
  int? _seekFeedbackSeconds;
  bool _seekFeedbackForward = true;
  Timer? _seekFeedbackTimer;

  // Subtitles state
  bool _subtitlesEnabled = false;
  List<String> _currentSubtitleText = [];
  final Set<String> _damagedSubtitleTracks =
      {}; // Pistas detectadas como dañadas
  SubtitleTrack? _lastSelectedTrack;
  DateTime? _lastTrackChangeTime;

  // Cast local audio
  bool _localAudioDuringCast = false;
  double _syncOffsetMs = 0.0;

  // Visual Notice system
  String? _noticeMessage;
  Timer? _noticeTimer;
  late AnimationController _noticeAnimController;
  late Animation<double> _noticeAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CastService().castMediaFinished.addListener(_onCastMediaFinished);
    CastService().castPosition.addListener(_syncFromCast);
    CastService().castPlaying.addListener(_syncFromCast);
    _currentItem = widget.item;
    _playlist = widget.playlist;

    _swipeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );

    _controlsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _controlsAnim = CurvedAnimation(
      parent: _controlsAnimController,
      curve: Curves.easeInOut,
    );
    // Comienza oculto, se mostrará cuando inicie el video o el usuario interactúe
    // _controlsAnimController.forward();

    _noticeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _noticeAnim = CurvedAnimation(
      parent: _noticeAnimController,
      curve: Curves.easeOut,
    );

    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _isLandscape =
        MediaQueryData.fromView(
          WidgetsBinding.instance.platformDispatcher.views.first,
        ).orientation ==
        Orientation.landscape;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();

    if (_isPiPSupported) {
      platform.setMethodCallHandler(_handleMethodCall);
    }

    AdService.isAdInProgress.addListener(_handleAdStateChange);
    CastService().isCasting.addListener(_handleCastStateChange);
    _startPlaybackFlow();

    // Iniciar monitor de red ANTES de iniciar el player
    _networkQuality.start();
    _networkQuality.quality.addListener(_onQualityChanged);
  }

  void _handleCastStateChange() {
    if (!mounted) return;
    final isCasting = CastService().isCasting.value;

    if (isCasting) {
      // Si empezamos a transmitir, destruimos el controlador de video local
      // para liberar los buffers de hardware (evita BLASTBufferQueue).
      if (_videoControllerNotifier.value != null) {
        debugPrint('CastService: Disposing VideoController due to active Cast');
        _videoControllerNotifier.value = null;
      }
    } else {
      // Si dejamos de transmitir, recuperamos el controlador de video si hay un player activo.
      if (_videoControllerNotifier.value == null && _player != null) {
        debugPrint('CastService: Restoring VideoController after Cast');
        final currentController = VideoController(
          _player!,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
          ),
        );
        _videoControllerNotifier.value = currentController;
      }
    }
  }

  bool _wasPlayingBeforeAd = false;

  void _handleAdStateChange() {
    if (AdService.isAdInProgress.value) {
      if (_player != null) {
        _wasPlayingBeforeAd = _player!.state.playing;
        _player!.pause();
      }
      // Liberar buffers de video durante el anuncio para evitar BLASTBufferQueue
      if (_videoControllerNotifier.value != null) {
        debugPrint('AdService: Disposing VideoController during Ad');
        _videoControllerNotifier.value = null;
      }
      if (mounted) setState(() => _showControls = true);
    } else {
      // Restaurar el controlador si no estamos en Cast
      if (!CastService().isCasting.value &&
          _videoControllerNotifier.value == null &&
          _player != null) {
        debugPrint('AdService: Restoring VideoController after Ad');
        final currentController = VideoController(
          _player!,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
          ),
        );
        _videoControllerNotifier.value = currentController;
      }

      if (_wasPlayingBeforeAd && _player != null) {
        _wasPlayingBeforeAd = false;
        _player!.play();
      }
    }
  }

  void _syncFromCast() {
    if (!mounted || !CastService().isConnected || _isDragging || _isSeeking) {
      return;
    }
    if (!_localAudioDuringCast) return;

    final isCastPlaying = CastService().castPlaying.value;
    final localPlaying = _player?.state.playing ?? false;

    // Sincronizar estado de reproducción
    if (isCastPlaying && !localPlaying) {
      _player?.play();
    } else if (!isCastPlaying && localPlaying) {
      _player?.pause();
    }

    // Sincronizar posición con tolerancia y offset personalizado
    final castPos = CastService().castPosition.value;
    final localPos = _player?.state.position ?? Duration.zero;

    final targetPos = castPos + Duration(milliseconds: _syncOffsetMs.toInt());

    if (castPos > Duration.zero &&
        (targetPos - localPos).abs().inMilliseconds > 1500) {
      _player?.seek(targetPos);
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // ← Liberar bloqueo de pantalla
    CastService().castMediaFinished.removeListener(_onCastMediaFinished);
    CastService().castPosition.removeListener(_syncFromCast);
    CastService().castPlaying.removeListener(_syncFromCast);
    CastService().isCasting.removeListener(_handleCastStateChange);
    _networkQuality.setActiveStreamUrl(null);
    // 1. Synchronous Dart-side cleanup (cancel all listeners FIRST).
    _networkQuality.quality.removeListener(_onQualityChanged);
    _networkQuality.stop();
    _hideControlsTimer?.cancel();
    _stallTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _countdownTimer?.cancel();
    _progressSaveTimer?.cancel();
    _noticeTimer?.cancel();
    _diagTimer?.cancel();

    for (final s in _streamSubscriptions) {
      s.cancel();
    }
    _streamSubscriptions.clear();

    AdService.isAdInProgress.removeListener(_handleAdStateChange);

    final pToStop = _player;
    _player = null; // Detach immediately so no more Dart code touches it

    // 2. Unmount video widget BEFORE touching native player.
    _videoControllerNotifier.value = null;

    // 3. Aggressive native silencing sequence to prevent FFI callbacks
    //    from firing after the Dart isolate is destroyed.
    if (pToStop != null) {
      try {
        // Pause first — stops the decoder from producing new frames
        pToStop.pause();
      } catch (_) {}
      try {
        final mpv = pToStop.platform as dynamic;
        // Disable ALL outputs so MPV stops calling back into Flutter
        mpv?.setProperty('msg-level', 'all=no');
        mpv?.setProperty('log-level', 'no');
        mpv?.setProperty('aid', 'no'); // disable audio track
        mpv?.setProperty('vid', 'no'); // disable video track
        mpv?.setProperty('sid', 'no'); // disable subtitle track
        mpv?.setProperty('ao', 'null'); // null audio output
        mpv?.setProperty('vo', 'null'); // null video output
      } catch (_) {}
      try {
        pToStop.stop();
      } catch (_) {}
    }

    // 4. Flutter-side animation controllers
    _swipeAnimController.dispose();
    _controlsAnimController.dispose();
    _videoFitNotifier.dispose();
    _videoControllerNotifier.dispose();
    _bufferedDuration.dispose();
    _noticeAnimController.dispose();

    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WakelockPlus.disable();

    if (_isPiPSupported) {
      platform.setMethodCallHandler(null);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();

    // 5. Deferred total disposal — give MPV's native event queue time to drain
    //    AFTER the Dart widget is fully gone. 1500ms is safe for Motorola.
    if (pToStop != null) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        try {
          pToStop.dispose();
        } catch (_) {}
      });
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_player == null) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      bool isPiP = false;
      try {
        if (_isPiPSupported) {
          final result = await platform.invokeMethod<bool>('isPiP');
          isPiP = result ?? false;
        }
      } catch (e) {
        debugPrint('Error checking PiP: $e');
      }
      if (!isPiP) {
        _player?.pause();
      }
    }
  }

  Future<void> _playVideo() async {
    if (!mounted) return;
    _retryCount = 0;
    _hasError = false;
    _noVideoSeconds = 0;
    _blackScreenReloadDone = false;
    _diagTrackCodecs = '?';

    final progress = await _watchProgressService.getProgress(_currentItem.url);
    Duration? startFrom;

    if (progress != null && mounted) {
      final shouldResume = await _showResumeDialog(
        Duration(seconds: progress.positionSeconds),
      );

      if (shouldResume == null) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) Navigator.pop(context);
        });
        return;
      }

      if (shouldResume == true) {
        startFrom = Duration(seconds: progress.positionSeconds);
      } else if (shouldResume == false) {
        await _watchProgressService.clearProgress(_currentItem.url);
      }
    }

    await _initializePlayer(_currentItem, startFrom: startFrom);
  }

  Future<void> _startPlaybackFlow() async {
    AdService().showRewardedAdWithConfirmation(
      context,
      quarterTurns: _isLandscape ? 1 : 0,
      onUserEarnedReward: _playVideo,
      onAdFailed: () {
        if (mounted) {
          if (AdService().adBlockerDetected) {
            _showAppSnackBar(
              'Bloqueador de anuncios detectado. Para continuar, desactívalo o suscríbete a Premium.',
            );
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            ).then((_) {
              if (mounted) {
                if (!PremiumService().isPremium) {
                  Navigator.pop(context);
                } else {
                  _playVideo();
                }
              }
            });
          } else if (AdService().hasReachedUnverifiedLimit) {
            _showAppSnackBar(
              'Límite de vistas sin anuncios alcanzado. Suscríbete a Premium.',
            );
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            ).then((_) {
              if (mounted) {
                if (!PremiumService().isPremium) {
                  Navigator.pop(context);
                } else {
                  _playVideo();
                }
              }
            });
          } else {
            AdService().incrementUnverifiedViews();
            _showAppSnackBar(
              'Error técnico al cargar anuncio. Disfruta del contenido (${AdService().unverifiedViewsThisSession}/3 vistas de cortesía usadas).',
            );
            _playVideo();
          }
        }
      },
      onCancel: () {
        if (mounted) Navigator.pop(context);
      },
      message: 'Para iniciar la reproducción, mira un anuncio.',
    );
  }

  Future<void> _cleanupPlayer() async {
    _networkQuality.setActiveStreamUrl(null);
    for (final s in _streamSubscriptions) {
      s.cancel();
    }
    _streamSubscriptions.clear();
    _progressSaveTimer?.cancel();
    _hideControlsTimer?.cancel();
    _stallTimer?.cancel();

    final p = _player;
    _player = null;

    try {
      p?.pause();
    } catch (_) {}

    // CRÍTICO: Liberar el VideoController PRIMERO y esperar a que el
    // BLASTBufferQueue drene sus 8 buffers antes de tocar MPV.
    // Sin esto, el nuevo VideoController encuentra buffers retenidos.
    _videoControllerNotifier.value = null;
    await Future.delayed(const Duration(milliseconds: 600));

    try {
      final mpv = p?.platform as dynamic;
      mpv?.setProperty('msg-level', 'all=no');
      mpv?.setProperty('log-level', 'no');
      mpv?.setProperty('aid', 'no');
      mpv?.setProperty('vid', 'no');
      mpv?.setProperty('sid', 'no');
      mpv?.setProperty('ao', 'null');
      mpv?.setProperty('vo', 'null');
    } catch (_) {}

    try {
      p?.stop();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 600));

    if (p != null) {
      try {
        await p.dispose();
      } catch (e) {
        debugPrint('Error disposing player in _cleanupPlayer: $e');
      }
    }
  }

  // PRE-RESOLVER DNS del servidor de video via Cloudflare
  // Esto elimina los ~200-400ms de latencia DNS desde Colombia
  Future<void> _prewarmDns(String url) async {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      // Cloudflare DNS-over-HTTPS — mucho más rápido que el DNS del ISP colombiano
      await http
          .get(
            Uri.parse('https://cloudflare-dns.com/dns-query?name=$host&type=A'),
            headers: {'Accept': 'application/dns-json'},
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Si la URL es un M3U8, la ruteamos por el Worker para acelerar
  /// la descarga de la playlist inicial (la más lenta desde Colombia).
  /// Los segmentos de video NO se proxean — son demasiado grandes.
  String _resolveStreamUrl(String url) {
    final lower = url.toLowerCase();

    // Solo proxear playlists M3U8, no segmentos .ts ni .mp4
    final isPlaylist =
        lower.contains('.m3u8') ||
        lower.contains('/playlist') ||
        lower.contains('/index.m3u8');

    if (!isPlaylist) return url; // URLs directas .mp4 etc no necesitan proxy

    // Dominios que sabemos son lentos desde Colombia
    final needsProxy =
        url.contains('ultratvsv.site') ||
        url.contains('red4tv.lat') ||
        url.contains('iptv') ||
        url.contains('/live/') ||
        url.contains('/hls/');

    if (!needsProxy) return url;

    const workerUrl =
        'https://morning-night-2d8a.juandanielarrieta23.workers.dev';
    return '$workerUrl/?url=${Uri.encodeComponent(url)}';
  }

  String _videoKey = '';
  Future<void> _initializePlayer(
    M3UItem item, {
    Duration? startFrom,
    bool isLocalReload = false,
  }) async {
    WakelockPlus.enable(); // ← Evitar que el sistema duerma el CPU/Red durante el Cast
    // Limpieza de URL para evitar fragmentos de tiempo (#t=...)
    final cleanedUrl = NormalizationUtils.cleanUrl(item.url);
    item = item.copyWith(url: cleanedUrl);

    // 1. Manejo de Scraping (enlaces dinámicos)
    if (DynamicScraperService().isSupported(item.url)) {
      setState(() {
        _isScraping = true;
        _isVideoLoading = true;
        _scrapingError = null;
        _hasError = false;
      });

      try {
        String? scrapedUrl;
        int scraperRetriesCount = 2;

        while (scraperRetriesCount > 0) {
          scrapedUrl = await DynamicScraperService().extractVideoSource(
            item.url,
          );
          if (scrapedUrl != null) break;

          scraperRetriesCount--;
          if (scraperRetriesCount > 0 && mounted) {
            await Future.delayed(const Duration(seconds: 2));
            debugPrint(
              'VideoPlayerScreen: Retrying scraper... ($scraperRetriesCount left)',
            );
          }
        }

        if (!mounted) return;

        if (scrapedUrl != null) {
          item = item.copyWith(url: scrapedUrl);
        } else {
          setState(() {
            _isScraping = false;
            _hasError = true;
            _scrapingError = "No se pudo obtener el enlace de video del sitio.";
          });
          return;
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isScraping = false;
          _hasError = true;
          _scrapingError = "Error al extraer video: $e";
        });
        return;
      }

      if (!mounted) return;
      setState(() => _isScraping = false);

      // SYNC: Ensure Scraper WebView is COMPLETELY GONE before player starts
      // This is the most important step for Motorola buffer stability.
      await DynamicScraperService().stopCurrentScraping();
      await Future.delayed(const Duration(milliseconds: 300));
    }

    try {
      // iOS NUNCA reutiliza un player precalentado: media_kit necesita el
      // VideoController adjunto al abrir el media para inicializar la salida de
      // video (de lo contrario: audio OK, video negro). En iOS siempre abrimos
      // un player fresco con la textura ya montada.
      final bool isIOSPlatform = defaultTargetPlatform == TargetPlatform.iOS;
      final isPrewarmed =
          !isIOSPlatform &&
          widget.prewarmedPlayer != null &&
          widget.prewarmedPlayer!.platform != null &&
          _retryCount == 0 &&
          !isLocalReload;

      // Si llegó un player precalentado en iOS (no debería, pero por seguridad),
      // lo liberamos para que no quede consumiendo recursos en segundo plano.
      if (isIOSPlatform &&
          widget.prewarmedPlayer != null &&
          _retryCount == 0 &&
          !isLocalReload) {
        try {
          final pw = widget.prewarmedPlayer!;
          final mpv = pw.platform as dynamic;
          mpv?.setProperty('vid', 'no');
          mpv?.setProperty('vo', 'null');
          await pw.stop();
          await pw.dispose();
        } catch (_) {}
      }

      if (!isPrewarmed) {
        await _cleanupPlayer();
      }

      AdService().recordVideoStart();

      setState(() {
        _isVideoLoading = true;
        _autoPlayCancelled = false;
        _midRollAdShown = false;
        _midRollNoticeShown = false;
        _adCountdown = null;

        final url = item.url.toLowerCase();
        _isLiveContent =
            url.contains('/live/') ||
            url.contains('type=live') ||
            (url.endsWith('.m3u8') && !url.contains('/vod/'));
        _hasError = false;
        _videoKey = '${item.url}_${DateTime.now().millisecondsSinceEpoch}';

        if (_serverUrls.isEmpty || _serverUrls[0] != item.url) {
          _serverUrls = [item.url, ...item.alternatives.map((a) => a.url)];
          _currentServerIndex = 0;
        }

        // VALIDATION: If URL looks like a web page and scraper didn't catch it,
        // we should NOT try to play it directly (avoids buffer errors)
        if (!DynamicScraperService().isSupported(item.url) &&
            _isProbablyWebPage(item.url)) {
          setState(() {
            _isVideoLoading = false;
            _hasError = true;
            _scrapingError =
                "Este enlace parece ser una página web y no un stream directo. Intenta con otro servidor.";
          });
          return;
        }
      });

      Player currentPlayer;
      if (isPrewarmed) {
        currentPlayer = widget.prewarmedPlayer!;
      } else {
        currentPlayer = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 256 * 1024 * 1024,
            title: 'Bump Comba Player',
            logLevel: MPVLogLevel.error,
            libass: true, // ← Renderizador nativo, mucho más eficiente
          ),
        );
        // -- CRITICAL SILENCING --
        // Mute native engine IMMEDIATELY after creation to prevent callbacks
        // that could survive a Hot Restart.
        try {
          final mpv = currentPlayer.platform as dynamic;
          mpv?.setProperty('terminal', 'no');
          mpv?.setProperty('msg-level', 'all=no');
        } catch (_) {}
      }

      _player = currentPlayer;

      // OPTIMIZACIÓN CRÍTICA: No crear VideoController si estamos transmitiendo.
      // El VideoController activa la aceleración por hardware y reserva buffers
      // de video (SurfaceView) que causan el error BLASTBufferQueue en dispositivos Motorola.
      if (!CastService().isCasting.value) {
        final currentController = VideoController(
          currentPlayer,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
          ),
        );
        _videoControllerNotifier.value = null;
        // Esperar a que el BLASTBufferQueue libere los 8 buffers anteriores.
        // El cleanup mejorado de _cleanupPlayer ya drena buffers nativos, por lo que 200ms es suficiente.
        await Future.delayed(const Duration(milliseconds: 200));
        if (mounted && !CastService().isCasting.value) {
          _videoControllerNotifier.value = currentController;

          // iOS FIX: AVFoundation registra la textura de video en el SIGUIENTE
          // frame tras montar el widget Video. Si player.open() se llama antes
          // de ese frame, el stream arranca sin superficie → audio OK, video negro.
          // Esperamos exactamente un frame para que Flutter renderice el Video
          // widget con el controller antes de abrir el media.
          if (defaultTargetPlatform == TargetPlatform.iOS && mounted) {
            final frameReady = Completer<void>();
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => frameReady.complete(),
            );
            await frameReady.future;
          }
        }
      } else {
        // Durante Cast, nos aseguramos que no haya controlador de video activo en el móvil.
        _videoControllerNotifier.value = null;
        debugPrint(
          'CastService: Skipping VideoController creation during active Cast session',
        );
      }

      _setupStreamMonitor();
      _startStallMonitor();

      Future.microtask(() async {
        final activePlayer = _player;
        if (activePlayer == null) return;

        try {
          final mpv = activePlayer.platform as dynamic;
          if (mpv == null) return;

          // -- BUFFER & CACHE STRATEGY (Optimization for Stuttering) --
          await mpv.setProperty('cache', 'yes');
          await mpv.setProperty('cache-pause', 'yes');
          await mpv.setProperty('cache-on-disk', 'no');
          await mpv.setProperty('cache-pause-wait', _isLiveContent ? '1' : '2');
          await mpv.setProperty('cache-pause-initial', 'yes');
          await mpv.setProperty(
            'stream-buffer-size',
            '4194304',
          ); // 4MB buffer for network
          // Timeout más agresivo — si el servidor no responde en 10s, es que está caído
          // El reload automático probará el siguiente servidor rápidamente
          await mpv.setProperty('network-timeout', '10');
          await mpv.setProperty('http-header-fields', 'Connection: keep-alive');

          // Permitir buscar dentro de datos ya descargados (evita re-fetch al hacer seek)
          await mpv.setProperty('demuxer-seekable-cache', 'yes');

          if (_isLiveContent) {
            await mpv.setProperty('cache-secs', '60');
            await mpv.setProperty(
              'demuxer-max-bytes',
              '67108864',
            ); // 64MB for Live
            await mpv.setProperty('demuxer-max-back-bytes', '33554432');
            await mpv.setProperty('demuxer-readahead-secs', '20');

            // Calidad adaptativa HLS automática
            await mpv.setProperty('hls-bitrate', 'auto');

            await mpv.setProperty('hls-forward-cache-secs', '30');
            await mpv.setProperty('hls-back-cache-secs', '10');
            await mpv.setProperty('demuxer-lavf-hacks', 'yes');
            await mpv.setProperty('demuxer-cache-wait', 'no');
            await mpv.setProperty(
              'deinterlace',
              'auto',
            ); // Critical for Live TV
            // protocol_whitelist is enabled by default by FFmpeg
          } else {
            // VOD Content (Movies/Series)
            await mpv.setProperty(
              'cache-secs',
              '300',
            ); // 5 minutos de buffer máximo
            await mpv.setProperty(
              'demuxer-max-bytes',
              '268435456',
            ); // 256MB (Safe limit for VOD)
            await mpv.setProperty('demuxer-max-back-bytes', '67108864');
            await mpv.setProperty('demuxer-readahead-secs', '180');
            await mpv.setProperty('cache-pause-initial', 'yes');
            // Reanuda reproducción tras solo 2s de re-buffering (antes: 5s)
            await mpv.setProperty('cache-pause-wait', '2');
            await mpv.setProperty('stream-buffer-size', '16777216');
            await mpv.setProperty('network-timeout', '10');

            // Calidad adaptativa HLS automática
            await mpv.setProperty('hls-bitrate', 'auto');

            // Forzar seekable para streams IPTV que no reportan duración correctamente.
            // Sin esto, MPV desactiva el seek-cache y cada búsqueda re-descarga.
            await mpv.setProperty('force-seekable', 'yes');
          }

          // -- NETWORK & COMPATIBILITY --
          await mpv.setProperty('http-reconnect', 'yes');
          // Reconexión más rápida tras caída de red (antes: 1s → ahora: 0.5s)
          await mpv.setProperty('http-reconnect-sleep', '0.5');
          await mpv.setProperty('http-reconnect-timeout', '5');
          await mpv.setProperty('tls-verify', 'no');
          await mpv.setProperty('load-unsafe-playlists', 'yes');
          // Usar HTTP pipelining para descargar segmentos HLS más rápido
          // (envía la siguiente petición sin esperar respuesta de la anterior)
          await mpv.setProperty('http-pipelining', 'yes');

          // User-Agent Rotation: Use a modern browser UA for VOD to avoid throttling
          final selectedUA =
              _isLiveContent
                  ? 'VLC/3.0.20 LibVLC/3.0.20'
                  : _userAgents[_userAgentIndex % _userAgents.length];
          await mpv.setProperty('user-agent', selectedUA);

          // -- SUBTÍTULOS --
          // Desactivados por defecto. Se renderizan como Flutter widgets,
          // no dependemos del rendering nativo de MPV (no funciona con
          // SurfaceView en Android).
          await mpv.setProperty('sub-forced-only', 'no');

          // -- HARDWARE ACCELERATION OPTIMIZATION --
          // 'mediacodec' is zero-copy (fastest). 'mediacodec-copy' is a safe fallback.
          bool useDirectHwdec = true;
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
            // Avoid tunnel/direct on Motorola or known low-end
            if (PerformanceService().isLowPerformance ||
                PerformanceService().allowVideoPrewarm == false) {
              useDirectHwdec = false;
            }
          }

          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
            // Si es un reintento (_retryCount > 0), forzamos 'mediacodec-copy' para mayor estabilidad
            // ya que el error 'Can't acquire next buffer' suele ocurrir en modo directo (mediacodec).
            final decoder =
                (_retryCount > 0 || !useDirectHwdec)
                    ? 'mediacodec-copy'
                    : 'mediacodec';
            await mpv.setProperty('hwdec', decoder);
            _activeDecoder = decoder;
            debugPrint('Decoder seleccionado: $decoder (Retry: $_retryCount)');
          } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
            // iOS: SIEMPRE hardware (VideoToolbox). El diagnóstico mostró que
            // con software ('no') MPV reporta 0×0 — el ffmpeg de libmpv en iOS
            // NO puede decodificar HEVC/H.265 por software. Solo VideoToolbox
            // (hardware) decodifica HEVC en iOS. La variante '-copy' copia los
            // frames a memoria estándar y los sube como textura normal,
            // evitando el fallo de wrapping directo de CVPixelBuffer 10-bit.
            // NO caemos a software: daría 0×0 (sin video).
            const decoder = 'videotoolbox-copy';
            await mpv.setProperty('hwdec', decoder);
            _activeDecoder = decoder;
            debugPrint(
              'Decoder iOS seleccionado: $decoder (Retry: $_retryCount)',
            );
          } else {
            await mpv.setProperty('hwdec', 'auto-safe');
            _activeDecoder = 'auto-safe';
          }

          // Threading and error detection
          await mpv.setProperty('vd-lavc-threads', '0');
          // 'nonref' solo funciona con decoders de software (lavf/ffmpeg).
          // Con mediacodec-copy (hardware Android) es un argumento inválido
          // que genera un error de stream y causa un reload innecesario.
          // En hardware Android el filtrado de loop lo hace el propio codec.
          await mpv.setProperty('vd-lavc-skiploopfilter', 'none');
          await mpv.setProperty('framedrop', 'vo');
          await mpv.setProperty('vd-lavc-fast-decoding', 'yes');
          await mpv.setProperty(
            'vd-lavc-o',
            'err_detect=ignore_err,flags2=+fast',
          );

          // Audio Sync
          await mpv.setProperty('video-sync', 'audio');
          // Buffer de audio más bajo → menor latencia al reanudar tras pausa/seek
          await mpv.setProperty('audio-buffer', '0.2');
          await mpv.setProperty('audio-stream-silence', 'yes');
          await mpv.setProperty('audio-fallback-to-null', 'yes');

          if (PerformanceService().isLowPerformance) {
            await mpv.setProperty('vd-lavc-dr', 'no');
          }

          // Subtítulos: desactivados por defecto, el usuario los activa desde el ícono.
          // Forzamos visibilidad 'no' para usar nuestro overlay Flutter.
          await mpv.setProperty('sid', 'no');
          await mpv.setProperty('sub-visibility', 'no');
          _subtitlesEnabled = false;

          if (GameConfigService().volumeNormalize) {
            await mpv.setProperty('af', 'dynaudnorm');
          }

          // ── CAUSA RAÍZ del "audio sí, video negro/0×0" en iOS ───────────
          // media_kit crea el Player con 'vid=no' por defecto y delega en el
          // VideoController poner 'vid=auto' al adjuntarse. En iOS ese paso a
          // veces NO surte efecto → el video queda desactivado: MPV ve las
          // pistas (p.ej. 4) pero no activa ninguna, video-codec=null, 0×0, y
          // solo se oye el audio. Forzamos 'vid=auto' explícitamente para
          // garantizar que se seleccione y decodifique una pista de video.
          if (CastService().isCasting.value) {
            // Si estamos transmitiendo, desactivamos el track de video local
            // para ahorrar recursos (CPU/GPU) y evitar errores de buffer.
            await mpv.setProperty('vid', 'no');
          } else {
            await mpv.setProperty('vid', 'auto');
          }
        } catch (e) {
          debugPrint('Error configurando MPV: $e');
        }
      });

      // ── ADAPTIVE QUALITY: Aplicar perfil inicial basado en estado de red ──
      // Se hace DESPUÉS del microtask original para no bloquear el arranque.
      Future.delayed(const Duration(milliseconds: 800), () async {
        if (!mounted || _player == null) return;
        final mpv2 = _player?.platform as dynamic;
        if (mpv2 == null) return;

        // Forzar una medición actualizada ANTES de aplicar perfil.
        // La primera medición suele ser incorrecta porque el stream
        // aún no está activo cuando el servicio arranca.
        await _networkQuality.measureManual();

        final currentQuality = _networkQuality.quality.value;
        _lastAppliedQuality = currentQuality;

        // GUARD: Si el ancho de banda real es >=2.0Mbps, no aplicar perfil degradado
        // aunque la heurística de latencia diga "poor" o "fair" — puede ser una medición
        // transitoria incorrecta al inicio.
        final realBandwidth = _networkQuality.estimatedBandwidthMbps.value;
        final shouldDegrade =
            (currentQuality == NetworkQuality.fair ||
                currentQuality == NetworkQuality.poor) &&
            realBandwidth <
                2.0; // Solo degradar si el ancho de banda real es bajo

        if (shouldDegrade) {
          await AdaptiveBufferService().applyConfig(
            mpv2,
            currentQuality,
            isLive: _isLiveContent,
          );
          debugPrint(
            'AdaptiveQuality: Initial profile applied: ${currentQuality.name}',
          );
        } else if (currentQuality == NetworkQuality.poor ||
            currentQuality == NetworkQuality.fair) {
          debugPrint(
            'AdaptiveQuality: Skipping degraded profile — real bandwidth is ${realBandwidth.toStringAsFixed(1)} Mbps (quality: ${currentQuality.name})',
          );
        }
      });

      final currentUrl = _serverUrls[_currentServerIndex % _serverUrls.length];
      final resolvedUrl = _resolveStreamUrl(currentUrl);

      // Calentar DNS en paralelo mientras se configura MPV
      unawaited(_prewarmDns(currentUrl));

      // Informar al monitor de red qué servidor estamos usando
      // para que mida la velocidad contra ESE servidor, no contra Google
      _networkQuality.setActiveStreamUrl(currentUrl);
      final castService = CastService();
      final shouldPlayLocally =
          !castService.isCasting.value ||
          (_localAudioDuringCast && castService.isCasting.value);

      // iOS FIX (prewarmed): mismo principio — aseguramos que el Video widget
      // ya tiene la textura lista antes de iniciar la reproducción.
      if (defaultTargetPlatform == TargetPlatform.iOS &&
          mounted &&
          !CastService().isCasting.value) {
        final frameReady = Completer<void>();
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => frameReady.complete(),
        );
        await frameReady.future;
      }

      if (!isPrewarmed) {
        await _player!.open(
          Media(resolvedUrl, httpHeaders: _buildHeaders(currentUrl)),
          play: shouldPlayLocally,
        );
        // REFUERZO del fix vid=auto: tras open(), volvemos a forzar la
        // selección de pista de video (salvo en Cast). Cubre el caso en que
        // el VideoController de media_kit no logró poner vid=auto al adjuntarse
        // en iOS, dejando el video desactivado (audio sí, video 0×0).
        if (!castService.isCasting.value) {
          try {
            final mpvActive = _player?.platform as dynamic;
            await mpvActive?.setProperty('vid', 'auto');
          } catch (_) {}
        }
        // Durante Cast sin audio local, cerramos la descarga del player local
        // completamente para liberar el ancho de banda al Chromecast.
        // Un player pausado-pero-abierto sigue consumiendo red en background.
        if (castService.isCasting.value && !_localAudioDuringCast) {
          await Future.delayed(const Duration(milliseconds: 300));
          try {
            _player?.stop();
          } catch (_) {}
        }
      } else {
        if (shouldPlayLocally) {
          _player!.play();
        } else {
          _player!.pause();
        }
      }

      // Sincronizar con Chromecast si estamos transmitiendo
      if (castService.isCasting.value) {
        castAudioHandler.setMediaItem(
          id: currentUrl,
          title: _currentItem.name,
          artist: 'Bump Comba',
          album: castService.connectedDevice?.name ?? 'TV',
          artUri: _currentItem.logo,
        );

        // Cargamos en Chromecast si es una nueva sesión o si es un reload.
        // IMPORTANTE: Solo usamos lastKnownPosition si es un reload del mismo
        // episodio (isLocalReload=true). Al pasar al siguiente episodio,
        // startFrom==null y isLocalReload==false, por lo que siempre empezamos
        // desde el inicio (0) para evitar que el episodio nuevo empiece desde
        // la posición final del episodio anterior.
        final double finalStartPosition =
            (startFrom != null)
                ? startFrom.inSeconds.toDouble()
                : (isLocalReload
                    ? castService.lastKnownPosition.inSeconds.toDouble()
                    : 0.0);

        castService.loadMedia(
          url: currentUrl,
          title: _currentItem.name,
          thumbnailUrl: _currentItem.logo,
          startPosition: finalStartPosition,
        );
      }

      if (startFrom != null && startFrom.inSeconds > 0) {
        // FASE 1: Esperar a que el demuxer reporte duración
        int attempts = 0;
        while (attempts < 60 && mounted && _player != null) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (_player!.state.duration.inSeconds > 0) break;
          attempts++;
        }

        // FASE 2: Esperar al primer frame decodificado antes de hacer seek.
        // El decoder MTK c2.mtk.avc.decoder lanza releaseAsync si recibe
        // un seek antes de haber procesado el primer output frame.
        // Esperamos hasta 3s a que width/height > 0 (primer frame listo).
        int frameWait = 0;
        while (frameWait < 30 && mounted && _player != null) {
          await Future.delayed(const Duration(milliseconds: 100));
          final w = _player!.state.width ?? 0;
          final h = _player!.state.height ?? 0;
          if (w > 0 && h > 0) break;
          frameWait++;
        }
        // El CCodecBufferChannel MTK necesita ~300-500ms entre el primer
        // output frame dequeued y el primer seek para evitar releaseAsync.
        await Future.delayed(const Duration(milliseconds: 500));

        if (mounted && _player != null) {
          _lastSeekTime = DateTime.now();
          await _player!.seek(startFrom);
          for (int i = 0; i < 5; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (!mounted || _player == null) break;
            final diff =
                (_player!.state.position.inSeconds - startFrom.inSeconds).abs();
            if (diff < 10) break;
            _lastSeekTime = DateTime.now();
            await _player!.seek(startFrom);
          }
        }
      }

      if (!castService.isCasting.value) {
        final bool isIOS = defaultTargetPlatform == TargetPlatform.iOS;
        int frameWait = 0;
        // Cuántas iteraciones llevamos con audio reproduciéndose pero SIN video.
        int audioOnlyWaits = 0;
        while (frameWait < 200 && mounted && _player != null) {
          final state = _player!.state;
          // En iOS, "tener video" significa que la TEXTURA está renderizando
          // (rect del controller), no solo que MPV conozca las dimensiones.
          final bool hasVideo;
          if (isIOS) {
            final r = _videoControllerNotifier.value?.rect.value;
            hasVideo = r != null && r.width > 0 && r.height > 0;
          } else {
            hasVideo = (state.width ?? 0) > 0 && (state.height ?? 0) > 0;
          }
          final isPlayingAndAdvanced =
              state.playing && state.position.inMilliseconds > 200;
          final hasBuffer = _isLiveContent || state.buffer.inSeconds >= 2;

          if (hasVideo && isPlayingAndAdvanced && hasBuffer) {
            break;
          }

          // Si el audio ya está reproduciéndose con buffer pero el video sigue
          // en 0x0, es el caso de "pantalla negra con audio". No esperamos los
          // 20s completos: salimos a los ~5s para que el watchdog recargue
          // rápido (en iOS, con decodificación por software).
          if (isPlayingAndAdvanced && hasBuffer && !hasVideo) {
            audioOnlyWaits++;
            if (audioOnlyWaits >= 50) {
              debugPrint(
                'Arranque con audio pero sin video tras 5s — saliendo del wait para recuperación.',
              );
              break;
            }
          } else {
            audioOnlyWaits = 0;
          }

          await Future.delayed(const Duration(milliseconds: 100));
          frameWait++;
        }
      }

      if (mounted) {
        setState(() => _isVideoLoading = false);
        _startHideControlsTimer();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isVideoLoading = false);
        _showAppSnackBar('Error al reproducir: $e');
      }
    }
  }

  void _setupStreamMonitor() {
    for (final s in _streamSubscriptions) {
      s.cancel();
    }
    _streamSubscriptions.clear();
    _progressSaveTimer?.cancel();

    // Buffering stream to show/hide loading spinner
    // + Auto-recuperación: si el player sale de buffering exitosamente
    //   mientras _hasError está activo, significa que el stream se recuperó
    //   en segundo plano → limpiar la pantalla de error automáticamente.
    _streamSubscriptions.add(
      _player!.stream.buffering.listen((buffering) {
        if (mounted) {
          setState(() => _isBuffering = buffering);
          if (!buffering && _hasError && _player != null) {
            final state = _player!.state;
            if (state.playing || state.position.inMilliseconds > 0) {
              debugPrint(
                'Auto-recovery: stream recovered while error UI was shown. Clearing error.',
              );
              setState(() {
                _hasError = false;
                _scrapingError = null;
              });
            }
          }
        }
      }),
    );

    // Subtitle text stream — renderizado Flutter, no MPV nativo
    _streamSubscriptions.add(
      _player!.stream.subtitle.listen((subtitleLines) {
        if (mounted) {
          setState(() => _currentSubtitleText = subtitleLines);
        }
      }),
    );

    // Guardar progreso cada 5 segundos
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final castService = CastService();
      Duration position = Duration.zero;
      Duration duration = Duration.zero;

      if (castService.isCasting.value) {
        position = castService.castPosition.value;
        duration = castService.castDuration.value;
      } else if (_player != null) {
        position = _player!.state.position;
        duration = _player!.state.duration;
      }

      if (duration.inSeconds > 0) {
        _watchProgressService.saveProgress(
          _currentItem.url,
          position,
          duration,
          name: _currentItem.name,
          seriesName: _currentItem.seriesName,
          seasonNumber: _currentItem.seasonNumber,
          episodeNumber: _currentItem.episodeNumber,
        );
      }
    });

    // Reload en error de stream con detección de errores en subtítulos
    _streamSubscriptions.add(
      _player!.stream.error.listen((error) {
        if (mounted) {
          final errStr = error.toString().toLowerCase();
          // Detectar si el error es específico de subtítulos (ej: [sub/ass] error)
          if (errStr.contains('sub') ||
              errStr.contains('ass') ||
              errStr.contains('subtitle')) {
            if (_lastSelectedTrack != null && _lastSelectedTrack!.id != 'no') {
              _damagedSubtitleTracks.add(_lastSelectedTrack!.id);
              _showVisualNotice(
                'Pista de subtítulos corrupta. Desactivando...',
              );
              _player?.setSubtitleTrack(SubtitleTrack.no());
              setState(() {
                _subtitlesEnabled = false;
                _currentSubtitleText = [];
              });
              return; // Evitamos recargar el video completo si solo falló el subtítulo
            }
          }

          if (!_isVideoLoading && !_isReloading) {
            debugPrint('Error de stream: $error. Recargando en 1s...');
            Future.delayed(const Duration(seconds: 1), () {
              if (mounted && !_isReloading) _reloadVideo();
            });
          }
        }
      }),
    );

    // Manejo de fin de stream
    _streamSubscriptions.add(
      _player!.stream.completed.listen((completed) {
        if (completed &&
            mounted &&
            _nextEpisodeCountdown == null &&
            !_isVideoLoading &&
            !_autoPlayCancelled) {
          final pos = _player!.state.position;
          final dur = _player!.state.duration;

          if (CastService().isCasting.value && !_localAudioDuringCast) {
            // Si estamos transmitiendo y NO estamos escuchando localmente,
            // ignoramos el fin del stream local (probablemente se cerró por timeout al estar pausado).
            debugPrint('Local stream completed while casting. Ignored.');
            return;
          }

          if (_currentItem.isLive) {
            Future.delayed(const Duration(seconds: 1), () {
              if (mounted) _reloadVideo();
            });
          } else {
            if (dur.inSeconds > 0 && pos.inSeconds < (dur.inSeconds - 60)) {
              debugPrint('Stream finalizado prematuramente. Reconectando...');
              if (pos.inSeconds > 120) {
                _retryCount = 0; // Resetear retries si reprodujo un buen tiempo
              }
              _reloadVideo();
            } else {
              _handleVideoCompletion();
            }
          }
        }
      }),
    );

    // Manejo unificado de posición (Autoplay + Midroll ads)
    _streamSubscriptions.add(
      _player!.stream.position.listen((position) {
        if (!mounted || _player == null) return;
        final duration = _player!.state.duration;
        if (duration.inSeconds == 0) return;

        // 1. Detección de fin de episodio (antes de los créditos)
        if (_nextEpisodeCountdown == null && !_autoPlayCancelled) {
          // Cálculo inteligente del umbral basado en el 4% de la duración total (ej. 55s para 22min)
          // Mínimo 45 segundos, Máximo 5 minutos (300 segundos)
          final threshold =
              (duration.inSeconds * 0.04).clamp(45.0, 300.0).toInt();

          if (duration.inSeconds > threshold + 30) {
            final remaining = duration - position;
            // Aseguramos que estamos en el último 20% del video para evitar triggers accidentales al inicio
            final isNearEnd = position.inSeconds > duration.inSeconds * 0.8;

            if (remaining.inSeconds <= threshold &&
                remaining.inSeconds > 0 &&
                isNearEnd) {
              final isProbablySeries =
                  _currentItem.isSeries ||
                  _currentItem.episodeNumber != null ||
                  _currentItem.seriesName != null ||
                  (_playlist.length > 1 &&
                      _currentItem.category.toLowerCase().contains('series'));

              if (_playlist.isNotEmpty && isProbablySeries) {
                _handleVideoCompletion();
              }
            }
          }
        }

        // 2. Monitor de mid-roll ads
        final midRollPosition = AdService().getMidRollPosition(
          duration.inSeconds,
        );
        if (midRollPosition >= 0) {
          final noticePoint = midRollPosition - 120;

          if (position.inSeconds >= noticePoint &&
              !_midRollNoticeShown &&
              position.inSeconds < midRollPosition &&
              !PremiumService().isPremium) {
            _midRollNoticeShown = true;
            _showMidRollNotice();
          }

          if (!PremiumService().isPremium && !_midRollAdShown) {
            if (position.inSeconds >= midRollPosition) {
              // Si llega al anuncio o adelanta la barra para saltarlo
              _midRollAdShown = true;
              setState(() => _adCountdown = null);
              _triggerMidRollAd();
            } else if (position.inSeconds >= midRollPosition - 15) {
              // Zona de cuenta regresiva (15 segundos)
              final remaining = midRollPosition - position.inSeconds;

              if (_adCountdown == null) {
                setState(() => _adCountdown = remaining);
              } else if (remaining < _adCountdown!) {
                // Avance natural del tiempo
                setState(() => _adCountdown = remaining);
              } else if (remaining > _adCountdown! + 2) {
                // Si el usuario retrocede el video durante la cuenta regresiva,
                // disparamos el anuncio directamente para evitar que el contador retroceda.
                _midRollAdShown = true;
                setState(() => _adCountdown = null);
                _triggerMidRollAd();
              }
            } else if (_adCountdown != null) {
              setState(() => _adCountdown = null);
            }
          }
        }
      }),
    );
  }

  void _onCastMediaFinished() {
    if (CastService().castMediaFinished.value && mounted) {
      // Si ya hay un countdown activo o ya se canceló, ignorar la señal.
      // Esto previene doble-disparo durante la transición entre episodios.
      if (_nextEpisodeCountdown != null || _autoPlayCancelled) {
        debugPrint(
          '_onCastMediaFinished: Ignored — countdown active or autoplay cancelled.',
        );
        return;
      }

      final castService = CastService();
      // Usar la última posición válida conocida para evitar regresar a 0
      final Duration pos =
          castService.castPosition.value.inSeconds > 0
              ? castService.castPosition.value
              : castService.lastKnownPosition;
      final dur = castService.castDuration.value;

      // Si terminó faltando más de 1 minuto, fue un error del stream
      if (dur.inSeconds > 0 && pos.inSeconds < (dur.inSeconds - 60)) {
        debugPrint(
          'Transmisión Cast finalizada prematuramente a los ${pos.inSeconds}s. Reconectando...',
        );
        if (mounted) _showAppSnackBar('Reconectando transmisión...');
        final currentUrl =
            _serverUrls.isNotEmpty
                ? _serverUrls[_currentServerIndex % _serverUrls.length]
                : _currentItem.url;

        castService.loadMedia(
          url: currentUrl,
          title: _currentItem.name,
          thumbnailUrl: _currentItem.logo,
          startPosition: pos.inSeconds.toDouble(),
        );
      } else {
        _handleVideoCompletion();
      }
    }
  }

  void _handleVideoCompletion() async {
    final castService = CastService();
    Duration duration = Duration.zero;

    if (castService.isCasting.value) {
      duration = castService.castDuration.value;
    } else if (_player != null) {
      duration = _player!.state.duration;
    }

    if (duration.inSeconds > 0) {
      await _watchProgressService.saveProgress(
        _currentItem.url,
        duration,
        duration,
        name: _currentItem.name,
        seriesName: _currentItem.seriesName,
        seasonNumber: _currentItem.seasonNumber,
        episodeNumber: _currentItem.episodeNumber,
      );
    }

    if (_playlist.isEmpty) return;

    final currentIndex = _playlist.indexWhere((i) => i.url == _currentItem.url);
    if (currentIndex == -1 || currentIndex >= _playlist.length - 1) return;

    setState(() => _nextEpisodeCountdown = 5);

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        final currentCount = _nextEpisodeCountdown;
        if (currentCount == null) {
          timer.cancel();
          return;
        }
        if (currentCount > 1) {
          _nextEpisodeCountdown = currentCount - 1;
        } else {
          timer.cancel();
          _nextEpisodeCountdown = null;
          _playNextEpisode();
        }
      });
    });
  }

  void _playNextEpisode() {
    if (_playlist.isEmpty) return;

    final currentIndex = _playlist.indexWhere((i) => i.url == _currentItem.url);
    if (currentIndex != -1 && currentIndex < _playlist.length - 1) {
      final nextItem = _playlist[currentIndex + 1];
      _changeToEpisode(nextItem);
    }
  }

  void _cancelAutoPlay() {
    _countdownTimer?.cancel();
    setState(() {
      _nextEpisodeCountdown = null;
      _autoPlayCancelled = true;
    });
  }

  void _showMidRollNotice() {
    if (mounted) {
      _showAppSnackBar('Anuncio en 2 minutos...');
    }
  }

  void _startStallMonitor() {
    _stallTimer?.cancel();
    _stallSeconds = 0;

    _stallTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _player == null || _isReloading) return;

      final playerState = _player!.state;
      final currentPos = playerState.position;

      _bufferedDuration.value = playerState.buffer;

      // ── Detección de stall y congelamiento silencioso ─────────────
      bool showingSpinner = _isBuffering;

      if (playerState.buffering) {
        _stallSeconds++;
        showingSpinner = true;

        // Threshold dinámico según calidad de red:
        // - Buena red: recargar rápido (5–10s)
        // - Mala red: darle más tiempo para que el buffer se llene (15–25s)
        final networkQ = _networkQuality.quality.value;
        final int threshold;
        if (networkQ == NetworkQuality.poor) {
          threshold = _isLiveContent ? 20 : 35; // Más paciencia en red mala
        } else if (networkQ == NetworkQuality.fair) {
          threshold = _isLiveContent ? 10 : 20;
        } else {
          threshold = _isLiveContent ? 5 : 10; // Comportamiento original
        }

        if (_stallSeconds >= threshold && !_isVideoLoading) {
          // NUEVO: No recargar si acabamos de hacer un seek (los primeros 8s
          // post-seek son normalmente buffering, no un stall real).
          final secondsSinceSeek =
              _lastSeekTime != null
                  ? DateTime.now().difference(_lastSeekTime!).inSeconds
                  : 999;
          if (secondsSinceSeek < 8) {
            debugPrint(
              'Stall ignorado: seek reciente hace ${secondsSinceSeek}s',
            );
            _stallSeconds = 0; // Reset para no acumular
            return;
          }
          // Si el stall ocurre justo después de cambiar de subtítulo, probablemente sea esa pista
          if (_lastSelectedTrack != null &&
              _lastTrackChangeTime != null &&
              DateTime.now().difference(_lastTrackChangeTime!).inSeconds < 20) {
            final trackId = _lastSelectedTrack!.id;
            if (trackId != 'no') {
              _damagedSubtitleTracks.add(trackId);
              _showVisualNotice(
                'Pista de subtítulos dañada. Cambiando a "Desactivado"...',
              );
              _player?.setSubtitleTrack(SubtitleTrack.no());
              setState(() {
                _subtitlesEnabled = false;
                _currentSubtitleText = [];
              });
            }
          }

          debugPrint('Stall persistente (${_stallSeconds}s). Recargando...');
          _stallSeconds = 0;
          _reloadVideo();
        }
      } else {
        // Detector de "congelamiento" (playing pero no avanza)
        if (playerState.playing && !_isSeeking && !_isDragging) {
          if (currentPos == _lastPosition && currentPos != Duration.zero) {
            _noMovementSeconds++;
            if (_noMovementSeconds >= 3) {
              showingSpinner = true;
            }
            // Para canales en vivo, si el video se congela silenciosamente por 5 segundos, forzar recarga rápida
            if (_isLiveContent && _noMovementSeconds >= 5 && !_isVideoLoading) {
              debugPrint(
                'Congelamiento en canal en vivo (${_noMovementSeconds}s). Recargando...',
              );
              _noMovementSeconds = 0;
              _reloadVideo();
            }
          } else {
            _noMovementSeconds = 0;
          }
        } else {
          _noMovementSeconds = 0;
        }

        if (_stallSeconds > 5) {
          debugPrint('Buffer recuperado tras $_stallSeconds s.');
        }
        _stallSeconds = 0;
      }

      // ── Detección de "audio sin video" (pantalla negra con audio) ─────
      // CLAVE iOS: MPV reporta width/height desde los metadatos del stream
      // aunque VideoToolbox NO produzca frames a la textura. Por eso el chequeo
      // de width/height==0 NO sirve aquí. La señal real es el `rect` del
      // VideoController: queda en null hasta que la capa nativa renderiza el
      // primer frame de verdad a la textura. Si el audio avanza pero el rect
      // nunca se asigna → pantalla negra. Recargamos (iOS usa software decode).
      final controller = _videoControllerNotifier.value;
      final rect = controller?.rect.value;
      final firstFrameRendered =
          rect != null && rect.width > 0 && rect.height > 0;

      // NOTA iOS: el reload a software se DESACTIVÓ. El diagnóstico mostró que
      // en iOS el software ('no') da MPV 0×0 (libmpv no decodifica HEVC por
      // software). Recargar a software empeoraba las cosas. En iOS solo sirve
      // VideoToolbox por hardware, que ya es el decodificador fijo. Por eso
      // este watchdog de "pantalla negra" solo aplica fuera de iOS.
      final bool isIOSPlat = defaultTargetPlatform == TargetPlatform.iOS;
      if (!isIOSPlat &&
          !_isLiveContent &&
          !_isVideoLoading &&
          !_isSeeking &&
          !_isDragging &&
          !_blackScreenReloadDone &&
          !CastService().isCasting.value &&
          controller != null &&
          playerState.playing &&
          currentPos != _lastPosition && // el audio SÍ avanza
          !firstFrameRendered) {
        _noVideoSeconds++;
        if (_noVideoSeconds >= 4) {
          debugPrint(
            'Pantalla negra detectada (audio sin textura de video ${_noVideoSeconds}s). Recargando...',
          );
          _noVideoSeconds = 0;
          _blackScreenReloadDone = true;
          if (_retryCount == 0) _retryCount = 1;
          _reloadVideo();
        }
      } else {
        _noVideoSeconds = 0;
      }

      _lastPosition = currentPos;

      // Actualizar UI solo si cambió el estado del spinner
      if (mounted && _isBuffering != showingSpinner) {
        setState(() => _isBuffering = showingSpinner);
      }
    });

    // Health monitor para live: detectar stream sin video (pantalla negra)
    if (_isLiveContent) {
      Timer.periodic(const Duration(seconds: 5), (timer) {
        if (!mounted || _player == null || !_isLiveContent) {
          timer.cancel();
          return;
        }
        if (_stallTimer == null || !_stallTimer!.isActive) {
          timer.cancel();
          return;
        }
        final state = _player!.state;
        if (state.playing &&
            state.width != null &&
            state.height != null &&
            state.width == 0 &&
            state.height == 0) {
          debugPrint('Health: stream sin video (0x0 px). Recargando...');
          _reloadVideo();
        }
      });
    }
  }

  Future<void> _reloadVideo() async {
    // ── RE-ENTRANCY GUARD ─────────────────────────────────────────────────
    // Without this, two concurrent reload cycles (from stall monitor +
    // stream.error listener) would both call _initializePlayer, creating
    // two VideoControllers fighting for the same GPU buffers, causing
    // BpSurfaceComposerClient::Failed to transact → native crash.
    if (!mounted || _isVideoLoading || _isReloading || _player == null) return;
    _isReloading = true;

    // ── STOP ALL CALLBACKS IMMEDIATELY ─────────────────────────────────────
    // Cancel stall timer and stream subscriptions BEFORE any async work.
    // Otherwise, the old player's error/stall events can re-trigger
    // _reloadVideo while _cleanupPlayer is still draining buffers.
    _stallTimer?.cancel();
    for (final s in _streamSubscriptions) {
      s.cancel();
    }
    _streamSubscriptions.clear();

    // Rotar User-Agent en cada intento
    _userAgentIndex++;

    // Capturar la posición actual de forma inteligente
    Duration currentPos = Duration.zero;
    if (CastService().isCasting.value) {
      currentPos = CastService().castPosition.value;
      if (currentPos == Duration.zero) {
        currentPos = CastService().lastKnownPosition;
      }
    } else {
      currentPos = _player?.state.position ?? Duration.zero;
    }

    try {
      if (!_isLiveContent) {
        if (_retryCount < 2) {
          _retryCount++;
          debugPrint(
            'VOD reload #$_retryCount at ${currentPos.inSeconds}s. UA: $_currentUserAgent',
          );
          await _initializePlayer(
            _currentItem,
            startFrom: currentPos.inSeconds > 5 ? currentPos : null,
            isLocalReload: true,
          );
        } else if (_currentServerIndex < _serverUrls.length - 1) {
          // Option exhausted for this server, try next alternative
          _retryCount = 0;
          _currentServerIndex++;
          debugPrint(
            'Primary server failed. Trying alternative server #$_currentServerIndex at ${currentPos.inSeconds}s',
          );
          if (mounted) {
            _showAppSnackBar('Intentando con servidor alternativo...');
          }
          await _initializePlayer(
            _currentItem,
            startFrom: currentPos.inSeconds > 5 ? currentPos : null,
            isLocalReload: true,
          );
        } else {
          if (mounted) setState(() => _hasError = true);
        }
      } else {
        const backoffDelays = [1, 2, 4, 8, 12, 20];
        final delay = backoffDelays[_retryCount < 6 ? _retryCount : 5];
        _retryCount++;
        if (mounted) setState(() => _isVideoLoading = true);
        await Future.delayed(Duration(seconds: delay));
        if (mounted) await _initializePlayer(_currentItem, isLocalReload: true);
      }
    } finally {
      _isReloading = false;
    }
  }

  Map<String, String> _buildHeaders(String currentUrl) {
    // Extraer dominio base para el Referer
    String referer = '';
    try {
      final uri = Uri.parse(currentUrl);
      referer = '${uri.scheme}://${uri.host}/';
    } catch (_) {}

    return {
      'User-Agent': _currentUserAgent,
      'Accept': '*/*',
      'Accept-Encoding':
          'gzip, deflate', // sin 'br' — algunos proxies M3U fallan con brotli
      'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
      'Connection': 'keep-alive',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
      if (referer.isNotEmpty) 'Referer': referer,
      'Origin': referer.isEmpty ? '' : referer.replaceAll(RegExp(r'/$'), ''),
      'Icy-MetaData': '1',
    }..removeWhere((k, v) => v.isEmpty);
  }

  bool _isProbablyWebPage(String url) {
    final lowUrl = url.toLowerCase();
    if (lowUrl.endsWith('.m3u8') ||
        lowUrl.endsWith('.mp4') ||
        lowUrl.endsWith('.mkv') ||
        lowUrl.contains('type=live') ||
        lowUrl.contains('.m3u8?') ||
        lowUrl.contains('.mp4?')) {
      return false;
    }
    // Any URL with many slashes or /detail/ /movie/ is likely a page
    if (lowUrl.contains('/detail/') ||
        lowUrl.contains('/movie/') ||
        lowUrl.contains('/serie/') ||
        lowUrl.contains('/watch/') ||
        lowUrl.contains('/ver/')) {
      return true;
    }
    return false;
  }

  Widget _buildErrorUI() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(32),
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                color: Colors.red.withValues(alpha: 0.8),
                size: 77,
              ),
              const SizedBox(height: 24),
              const Text(
                'Servidor fuera de línea',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                _scrapingError ??
                    'Es posible que el servidor esté caído o tu conexión de red sea débil.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 16,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: () {
                    // Resetear todo el estado de reintentos y volver a intentar
                    setState(() {
                      _hasError = false;
                      _scrapingError = null;
                      _retryCount = 0;
                      _currentServerIndex = 0;
                      _userAgentIndex++;
                      _serverUrls = [];
                    });
                    _initializePlayer(_currentItem);
                  },
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  label: const Text(
                    'Reintentar',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color.fromARGB(230, 244, 67, 54),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Volver atrás',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _triggerMidRollAd() {
    if (!mounted || _player == null) return;
    _player!.pause();
    AdService().showRewardedAdWithConfirmation(
      context,
      quarterTurns: _isLandscape ? 1 : 0,
      onUserEarnedReward: () {
        if (mounted && _player != null) _player!.play();
      },
      onAdFailed: () {
        if (mounted) {
          if (AdService().adBlockerDetected) {
            _showAppSnackBar(
              'Bloqueador de anuncios detectado. Para continuar, desactívalo o suscríbete a Premium.',
            );
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            ).then((_) {
              if (mounted) {
                if (!PremiumService().isPremium) {
                  Navigator.pop(context);
                } else {
                  if (_player != null) _player!.play();
                }
              }
            });
          } else if (AdService().hasReachedUnverifiedLimit) {
            _showAppSnackBar(
              'Límite de vistas sin anuncios alcanzado. Suscríbete a Premium.',
            );
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            ).then((_) {
              if (mounted) {
                if (!PremiumService().isPremium) {
                  Navigator.pop(context);
                } else {
                  if (_player != null) _player!.play();
                }
              }
            });
          } else {
            AdService().incrementUnverifiedViews();
            _showAppSnackBar(
              'Error técnico al cargar anuncio. Disfruta del contenido (${AdService().unverifiedViewsThisSession}/3 vistas de cortesía usadas).',
            );
            if (_player != null) _player!.play();
          }
        }
      },
      onCancel: () {
        if (mounted) Navigator.pop(context);
      },
      message: 'Para retomar la reproducción, mira un anuncio.',
    );
  }

  Future<bool?> _showResumeDialog(Duration savedPosition) async {
    return showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: const Color.fromARGB(104, 0, 0, 0),
      pageBuilder: (context, anim1, anim2) => const SizedBox.shrink(),
      transitionBuilder: (context, anim1, anim2, child) {
        return Transform.scale(
          scale: anim1.value,
          child: Opacity(
            opacity: anim1.value,
            child: Dialog(
              backgroundColor: Colors.transparent,
              elevation: 0,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.85,
                constraints: const BoxConstraints(maxWidth: 400),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),

                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                    width: 1.0,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(19),
                  child: Stack(
                    children: [
                      if (_currentItem.logo != null)
                        Positioned.fill(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Transform.scale(
                                scale: 1.1,
                                child: ImageFiltered(
                                  imageFilter: ImageFilter.blur(
                                    sigmaX: 20,
                                    sigmaY: 20,
                                    tileMode: TileMode.decal,
                                  ),
                                  child: FastThumbnail(
                                    url: _currentItem.logo!,
                                    width: double.infinity,
                                    height: double.infinity,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                              Container(
                                color: Colors.black.withValues(alpha: 0.6),
                              ),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(28.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    CupertinoIcons.play_arrow_solid,
                                    color: Colors.red,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                const Text(
                                  'Continuar viendo',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 19.7,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Text(
                              '¿Quieres retomar desde donde lo dejaste?',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 15,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.white10,
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.access_time,
                                    color: Colors.red,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    WatchProgressService.formatDuration(
                                      savedPosition,
                                    ),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15.7,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 32),
                            Row(
                              children: [
                                Expanded(
                                  child: TextButton(
                                    onPressed:
                                        () => Navigator.pop(context, false),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.white70,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 12,
                                      ),
                                    ),
                                    child: const Text(
                                      'Empezar de cero',
                                      style: TextStyle(fontSize: 14),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed:
                                        () => Navigator.pop(context, true),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      elevation: 0,
                                    ),
                                    child: const Text(
                                      'Continuar',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _toggleControls() {
    if (_showControls) {
      _controlsAnimController.reverse().then((_) {
        if (mounted) setState(() => _showControls = false);
      });
    } else {
      setState(() => _showControls = true);
      _controlsAnimController.forward();
    }
    if (_showControls) _startHideControlsTimer();
  }

  void _startHideControlsTimer({bool showIfHidden = true}) {
    _hideControlsTimer?.cancel();

    // Asegurarse de que los controles sean visibles al iniciar el timer sí se solicita
    if (showIfHidden && !_showControls && mounted) {
      setState(() {
        _showControls = true;
        _controlsAnimController.forward();
      });
    }

    _hideControlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted &&
          _showControls &&
          !_isDragging &&
          (_player?.state.playing ?? false)) {
        _controlsAnimController.reverse().then((_) {
          if (mounted) setState(() => _showControls = false);
        });
      }
    });
  }

  void _onSwipeDragStart(DragStartDetails details) {
    if (_activePointers > 1) return;
    _swipeAnimController.stop();
    _swipeStartedVertically = false;
    setState(() => _swipeDragOffset = 0.0);
  }

  void _onSwipeDragUpdate(DragUpdateDetails details) {
    if (_activePointers > 1) return;
    final dy = details.delta.dy;

    // Restricción de dirección SIEMPRE, incluso durante el guard inicial
    if (!_isLandscape && dy > 0 && _swipeDragOffset >= 0) return;
    if (_isLandscape && dy < 0 && _swipeDragOffset <= 0) return;

    if (!_swipeStartedVertically) {
      if (_swipeDragOffset.abs() < 8.0) {
        setState(() => _swipeDragOffset += dy);
        return;
      }
      _swipeStartedVertically = true;
    }

    setState(() {
      _swipeDragOffset += dy;
      _swipeDragOffset = _swipeDragOffset.clamp(-160.0, 160.0);
    });
  }

  void _onSwipeDragEnd(DragEndDetails details) {
    if (_activePointers > 1) return;
    final velocity = details.primaryVelocity ?? 0;

    final shouldSwitch =
        (velocity < -1800 && !_isLandscape) ||
        (velocity > 1800 && _isLandscape) ||
        (_swipeDragOffset.abs() > 140 && _swipeStartedVertically);

    if (shouldSwitch) {
      final target = _isLandscape ? 160.0 : -160.0;
      _swipeAnimController.reset();
      _swipeSnapAnim = Tween<double>(
        begin: _swipeDragOffset,
        end: target,
      ).animate(
        CurvedAnimation(
          parent: _swipeAnimController,
          curve: Curves.easeOutCubic,
        ),
      );
      _swipeAnimController.forward().then((_) {
        if (mounted) {
          _toggleOrientation();
          setState(() => _swipeDragOffset = 0.0);
        }
      });
    } else {
      if (_swipeDragOffset.abs() < 5.0) {
        setState(() => _swipeDragOffset = 0.0);
        return;
      }

      _swipeAnimController.reset();
      _swipeSnapAnim = Tween<double>(begin: _swipeDragOffset, end: 0.0).animate(
        CurvedAnimation(
          parent: _swipeAnimController,
          curve: const ElasticOutCurve(0.3),
        ),
      );
      _swipeAnimController.forward().then((_) {
        if (mounted) setState(() => _swipeDragOffset = 0.0);
      });
    }
  }

  Future<void> _toggleOrientation() async {
    setState(() {
      _isLandscape = !_isLandscape;
    });

    if (_isLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _handleMainTap() {
    _toggleControls();
  }

  void _pauseNetworkMonitoring() => _networkQuality.stop();
  void _resumeNetworkMonitoring() => _networkQuality.start();

  void _togglePlayback() {
    final activePlayer = _player;
    if (activePlayer == null) return;

    final castService = CastService();

    if (castService.isCasting.value) {
      if (castService.castPlaying.value) {
        castService.pause();
        setState(() => _showControls = true);
        _hideControlsTimer?.cancel();
      } else {
        castService.play();
        _startHideControlsTimer();
      }
      if (activePlayer.state.playing) activePlayer.pause();
      return;
    }

    if (activePlayer.state.playing) {
      activePlayer.pause();
      _pauseNetworkMonitoring();
      setState(() => _showControls = true);
      _hideControlsTimer?.cancel();
      if (_isPiPSupported) {
        platform.invokeMethod('updatePiPState', {'playing': false});
      }
    } else {
      activePlayer.play();
      _resumeNetworkMonitoring();
      _startHideControlsTimer();
      if (_isPiPSupported) {
        platform.invokeMethod('updatePiPState', {'playing': true});
      }
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'pipPlay':
        if (_player != null && !_player!.state.playing) {
          _player!.play();
        }
        break;
      case 'pipPause':
        if (_player != null && _player!.state.playing) {
          _player!.pause();
        }
        break;
    }
  }

  void _showAudioSelection() {
    if (_player == null) return;
    final tracks = _player!.state.tracks.audio;
    _showVisualBottomSheet(
      builder:
          (context) => Container(
            width: _isLandscape ? 400 : double.infinity,
            margin: _isLandscape ? const EdgeInsets.all(24) : EdgeInsets.zero,
            constraints: BoxConstraints(
              maxHeight:
                  _isLandscape
                      ? MediaQuery.of(context).size.width * 0.9
                      : MediaQuery.of(context).size.height * 0.9,
            ),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 27, 27, 27),
              borderRadius:
                  _isLandscape
                      ? BorderRadius.circular(24)
                      : const BorderRadius.vertical(top: Radius.circular(20)),
              border:
                  _isLandscape
                      ? Border.all(color: Colors.white12, width: 1)
                      : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Audio / Idioma',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white10, height: 1),
                Flexible(
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final track = tracks[index];
                      final isSelected = _player!.state.track.audio == track;
                      return ListTile(
                        leading: Icon(
                          Icons.audiotrack,
                          color: isSelected ? Colors.red : Colors.white70,
                        ),
                        title: Text(
                          track.title ?? track.language ?? 'Pista $index',
                          style: TextStyle(
                            color: isSelected ? Colors.red : Colors.white,
                          ),
                        ),
                        trailing:
                            isSelected
                                ? const Icon(Icons.check, color: Colors.red)
                                : null,
                        onTap: () {
                          _player!.setAudioTrack(track);
                          final castService = CastService();
                          if (castService.isCasting.value) {
                            final trackId =
                                int.tryParse(track.id) ?? (index + 1);
                            castService.setActiveAudioTrack(trackId);
                          }
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
    );
  }

  void _showSubtitleSelection() {
    if (_player == null) return;
    final tracks = _player!.state.tracks.subtitle;

    _showVisualBottomSheet(
      builder:
          (context) => Container(
            width: _isLandscape ? 400 : double.infinity,
            margin: _isLandscape ? const EdgeInsets.all(24) : EdgeInsets.zero,
            constraints: BoxConstraints(
              maxHeight:
                  _isLandscape
                      ? MediaQuery.of(context).size.width * 0.9
                      : MediaQuery.of(context).size.height * 0.9,
            ),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 27, 27, 27),
              borderRadius:
                  _isLandscape
                      ? BorderRadius.circular(24)
                      : const BorderRadius.vertical(top: Radius.circular(20)),
              border:
                  _isLandscape
                      ? Border.all(color: Colors.white12, width: 1)
                      : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Subtítulos',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white10, height: 1),
                Flexible(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    children: [
                      // Opción: Desactivar subtítulos
                      ListTile(
                        leading: Icon(
                          Icons.subtitles_off,
                          color:
                              !_subtitlesEnabled ? Colors.red : Colors.white70,
                        ),
                        title: Text(
                          'Desactivado',
                          style: TextStyle(
                            color:
                                !_subtitlesEnabled ? Colors.red : Colors.white,
                          ),
                        ),
                        trailing:
                            !_subtitlesEnabled
                                ? const Icon(Icons.check, color: Colors.red)
                                : null,
                        onTap: () async {
                          Navigator.pop(context);
                          if (_player == null) return;
                          try {
                            _player!.setSubtitleTrack(SubtitleTrack.no());
                            final mpv = _player!.platform as dynamic;
                            await mpv?.setProperty('sid', 'no');
                            await mpv?.setProperty('sub-visibility', 'no');
                          } catch (_) {}
                          if (mounted) {
                            setState(() {
                              _subtitlesEnabled = false;
                              _currentSubtitleText = [];
                            });
                          }
                        },
                      ),
                      if (tracks.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          child: Text(
                            'No hay pistas de subtítulos disponibles en este contenido.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                        )
                      else
                        ..._player!.state.tracks.subtitle
                            .where((t) {
                              // Filtrar la pista 'no' (ya tenemos opción manual)
                              // y pistas genéricas (ID 0 o 1 sin título/lenguaje) que suelen ser basura
                              if (t.id == 'no' || t.id == 'auto') return false;
                              if ((t.id == '0' || t.id == '1') &&
                                  t.title == null &&
                                  t.language == null) {
                                return false;
                              }
                              return true;
                            })
                            .map((track) {
                              final isDamaged = _damagedSubtitleTracks.contains(
                                track.id,
                              );
                              final isSelected =
                                  _subtitlesEnabled &&
                                  _player!.state.track.subtitle == track;
                              final label =
                                  track.title ??
                                  track.language ??
                                  'Pista ${track.id}';
                              return ListTile(
                                enabled: !isDamaged,
                                leading: Icon(
                                  isDamaged
                                      ? Icons.subtitles_off
                                      : Icons.subtitles,
                                  color:
                                      isDamaged
                                          ? Colors.white70
                                          : (isSelected
                                              ? Colors.red
                                              : Colors.white70),
                                ),
                                title: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        label,
                                        style: TextStyle(
                                          color:
                                              isDamaged
                                                  ? Colors.white24
                                                  : (isSelected
                                                      ? Colors.red
                                                      : Colors.white),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (isDamaged) ...[
                                      const SizedBox(width: 8),
                                      Text(
                                        '(Not available)',
                                        style: TextStyle(
                                          color: const Color.fromARGB(
                                            157,
                                            114,
                                            114,
                                            114,
                                          ),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                trailing:
                                    isSelected
                                        ? const Icon(
                                          Icons.check,
                                          color: Colors.red,
                                        )
                                        : null,
                                onTap: () async {
                                  Navigator.pop(context);
                                  if (_player == null) return;
                                  try {
                                    _lastSelectedTrack = track;
                                    _lastTrackChangeTime = DateTime.now();
                                    _player!.setSubtitleTrack(track);
                                    // Siempre desactivar el renderizado nativo de MPV
                                    // después de seleccionar la pista: el overlay Flutter
                                    // es el único que debe mostrar los subtítulos.
                                    final mpv = _player!.platform as dynamic;
                                    await mpv?.setProperty(
                                      'sub-visibility',
                                      'no',
                                    );
                                  } catch (_) {}
                                  if (mounted) {
                                    setState(() => _subtitlesEnabled = true);
                                  }
                                },
                              );
                            }),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
    );
  }

  void _showEpisodeSelection() {
    if (_playlist.isEmpty) return;

    _showVisualBottomSheet(
      builder:
          (context) => Container(
            width: _isLandscape ? 500 : double.infinity,
            margin: _isLandscape ? const EdgeInsets.all(24) : EdgeInsets.zero,
            constraints: BoxConstraints(
              maxHeight:
                  _isLandscape
                      ? MediaQuery.of(context).size.width * 0.85
                      : MediaQuery.of(context).size.height * 0.6,
            ),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 27, 27, 27),
              borderRadius:
                  _isLandscape
                      ? BorderRadius.circular(24)
                      : const BorderRadius.vertical(top: Radius.circular(20)),
              border:
                  _isLandscape
                      ? Border.all(color: Colors.white12, width: 1)
                      : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Capítulos',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white10, height: 1),
                Flexible(
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: _playlist.length,
                    itemBuilder: (context, index) {
                      final episode = _playlist[index];
                      final isCurrentEpisode = episode.url == _currentItem.url;
                      return ListTile(
                        leading: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color:
                                isCurrentEpisode ? Colors.red : Colors.white12,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              color:
                                  isCurrentEpisode
                                      ? Colors.white
                                      : Colors.white70,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Builder(
                          builder: (context) {
                            final cleanTitle =
                                NormalizationUtils.extractEpisodeTitle(
                                  episode.name,
                                );
                            if (cleanTitle.isEmpty) {
                              return Text(
                                episode.name,
                                style: TextStyle(
                                  color:
                                      isCurrentEpisode
                                          ? Colors.red
                                          : Colors.white,
                                  fontWeight:
                                      isCurrentEpisode
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              );
                            }

                            final epNum =
                                episode.episodeNumber ??
                                NormalizationUtils.parseEpisodeNumber(
                                  episode.name,
                                ) ??
                                (index + 1);

                            return Text(
                              '$epNum. $cleanTitle',
                              style: TextStyle(
                                color:
                                    isCurrentEpisode
                                        ? Colors.red
                                        : Colors.white,
                                fontWeight:
                                    isCurrentEpisode
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        ),
                        trailing:
                            isCurrentEpisode
                                ? const Icon(
                                  Icons.play_arrow,
                                  color: Colors.red,
                                )
                                : const Icon(
                                  Icons.chevron_right,
                                  color: Colors.white38,
                                ),
                        onTap:
                            isCurrentEpisode
                                ? null
                                : () {
                                  Navigator.pop(context);
                                  _changeToEpisode(episode);
                                },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
    );
  }

  void _applyNewEpisode(M3UItem newEpisode) {
    if (!mounted) return;
    setState(() {
      _currentItem = newEpisode;
      _midRollAdShown = false;
      _midRollNoticeShown = false;
      _autoPlayCancelled = false;
      _nextEpisodeCountdown = null;
      _serverUrls = [];
      _currentServerIndex = 0;
    });
    _initializePlayer(newEpisode);
  }

  void _changeToEpisode(M3UItem newEpisode) {
    _countdownTimer?.cancel();
    _player?.pause();

    final castService = CastService();
    castService.lastKnownPosition = Duration.zero;
    castService.castMediaFinished.value = false;

    AdService().showRewardedAd(
      onUserEarnedReward: () {
        _applyNewEpisode(newEpisode);
      },
      onAdFailed: () {
        if (mounted) {
          if (AdService().adBlockerDetected) {
            _showAppSnackBar(
              'Bloqueador de anuncios detectado. Para continuar, desactívalo o suscríbete a Premium.',
            );
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            ).then((_) {
              if (mounted) {
                if (!PremiumService().isPremium) {
                  Navigator.pop(context);
                } else {
                  _applyNewEpisode(newEpisode);
                }
              }
            });
          } else if (AdService().hasReachedUnverifiedLimit) {
            _showAppSnackBar(
              'Límite de vistas sin anuncios alcanzado. Suscríbete a Premium.',
            );
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            ).then((_) {
              if (mounted) {
                if (!PremiumService().isPremium) {
                  Navigator.pop(context);
                } else {
                  _applyNewEpisode(newEpisode);
                }
              }
            });
          } else {
            AdService().incrementUnverifiedViews();
            _showAppSnackBar(
              'Error técnico al cargar anuncio. Disfruta del contenido (${AdService().unverifiedViewsThisSession}/3 vistas de cortesía usadas).',
            );
            _applyNewEpisode(newEpisode);
          }
        }
      },
    );
  }

  void _showSettingsMenu() {
    _showVisualBottomSheet(
      builder:
          (context) => Container(
            width: _isLandscape ? 380 : double.infinity,
            margin: _isLandscape ? const EdgeInsets.all(24) : EdgeInsets.zero,
            constraints: BoxConstraints(
              maxHeight:
                  _isLandscape
                      ? MediaQuery.of(context).size.width * 0.9
                      : MediaQuery.of(context).size.height * 0.9,
            ),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 27, 27, 27),
              borderRadius:
                  _isLandscape
                      ? BorderRadius.circular(24)
                      : const BorderRadius.vertical(top: Radius.circular(20)),
              border:
                  _isLandscape
                      ? Border.all(color: Colors.white12, width: 1)
                      : null,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Audio y subtítulos',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 1),
                  ListTile(
                    leading: const Icon(Icons.subtitles, color: Colors.white),
                    title: const Text(
                      'Subtítulos',
                      style: TextStyle(color: Colors.white),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Colors.white54,
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _showSubtitleSelection();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.audiotrack, color: Colors.white),
                    title: const Text(
                      'Audio',
                      style: TextStyle(color: Colors.white),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Colors.white54,
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _showAudioSelection();
                    },
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
    );
  }

  void _showSpeedSelection() {
    if (_player == null) return;

    final speeds = [1.0, 1.25, 1.5, 2.0];
    final isPremium = PremiumService().isPremium;

    _showVisualBottomSheet(
      builder:
          (context) => Container(
            width: _isLandscape ? 380 : double.infinity,
            margin: _isLandscape ? const EdgeInsets.all(24) : EdgeInsets.zero,
            constraints: BoxConstraints(
              maxHeight:
                  _isLandscape
                      ? MediaQuery.of(context).size.width * 0.8
                      : MediaQuery.of(context).size.height * 0.8,
            ),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 27, 27, 27),
              borderRadius:
                  _isLandscape
                      ? BorderRadius.circular(24)
                      : const BorderRadius.vertical(top: Radius.circular(20)),
              border:
                  _isLandscape
                      ? Border.all(color: Colors.white12, width: 1)
                      : const Border(
                        top: BorderSide(color: Colors.white10, width: 1),
                      ),
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Velocidad',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Colors.white10, height: 1),
                  ...speeds.map((speed) {
                    final isSelected = _player!.state.rate == speed;
                    final isLocked = !isPremium && speed != 1.0;

                    return ListTile(
                      leading: Icon(
                        Icons.speed,
                        color: isSelected ? Colors.white : Colors.white70,
                      ),
                      title: Text(
                        '${speed}x',
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white70,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      trailing:
                          isLocked
                              ? const Icon(
                                CupertinoIcons.lock_fill,
                                color: Color(0xFFFACC15),
                                size: 18,
                              )
                              : (isSelected
                                  ? const Icon(Icons.check, color: Colors.white)
                                  : null),
                      onTap: () {
                        if (isLocked) {
                          Navigator.pop(context);
                          _showPremiumRequirement(
                            'Velocidades de reproducción solo en Premium',
                          );
                          return;
                        }
                        _player!.setRate(speed);
                        Navigator.pop(context);
                      },
                    );
                  }),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
    );
  }

  void _showCastSelection() {
    final castService = CastService();

    // Si ya está transmitiendo, mostrar opción de desconectar
    if (castService.isConnected) {
      _showVisualBottomSheet(
        builder:
            (context) => Container(
              width: _isLandscape ? 400 : double.infinity,
              margin: _isLandscape ? const EdgeInsets.all(24) : EdgeInsets.zero,
              decoration: BoxDecoration(
                color: const Color.fromARGB(255, 27, 27, 27),
                borderRadius:
                    _isLandscape
                        ? BorderRadius.circular(24)
                        : const BorderRadius.vertical(top: Radius.circular(20)),
                border:
                    _isLandscape
                        ? Border.all(color: Colors.white12, width: 1)
                        : null,
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Transmitiendo',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(color: Colors.white10, height: 1),
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            // Toggle de audio local
                            StatefulBuilder(
                              builder: (context, setInnerState) {
                                return Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Column(
                                    children: [
                                      SwitchListTile(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 2,
                                            ),
                                        title: const Text(
                                          'Escuchar audio en el teléfono',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                          ),
                                        ),
                                        subtitle: Text(
                                          _localAudioDuringCast
                                              ? 'Activo. Ajusta el retraso si hay eco.'
                                              : 'Solo se reproduce en el TV',
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.5,
                                            ),
                                            fontSize: 11,
                                          ),
                                        ),
                                        secondary: Icon(
                                          _localAudioDuringCast
                                              ? Icons.volume_up_rounded
                                              : Icons.volume_off_rounded,
                                          color:
                                              _localAudioDuringCast
                                                  ? Colors.redAccent
                                                  : Colors.white38,
                                        ),
                                        value: _localAudioDuringCast,
                                        activeThumbColor: Colors.redAccent,
                                        onChanged: (value) {
                                          setInnerState(() {});
                                          setState(() {
                                            _localAudioDuringCast = value;
                                            if (!value) {
                                              _syncOffsetMs = 0; // Reset
                                            }
                                          });
                                          if (value) {
                                            final castPos =
                                                CastService()
                                                    .castPosition
                                                    .value;
                                            _player?.seek(castPos);
                                            _player?.play();
                                          } else {
                                            _player?.pause();
                                          }
                                        },
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          0,
                                          16,
                                          12,
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                'Recomendado para cuando no se escucha el audio en el TV, se puede reproducir con un parlante bluetooth o audífonos.',
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.6),
                                                  fontSize: 11,
                                                  height: 1.2,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            if (_localAudioDuringCast) ...[
                              const SizedBox(height: 20),
                              StatefulBuilder(
                                builder: (context, setInnerState) {
                                  return Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Sincronización de audio',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                            ),
                                          ),
                                          Text(
                                            '${_syncOffsetMs >= 0 ? '+' : ''}${_syncOffsetMs.toInt()} ms',
                                            style: const TextStyle(
                                              color: Colors.redAccent,
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SliderTheme(
                                        data: SliderThemeData(
                                          trackHeight: 2.0,
                                          activeTrackColor: Colors.redAccent,
                                          inactiveTrackColor: Colors.white24,
                                          thumbColor: Colors.redAccent,
                                          overlayColor: Colors.redAccent
                                              .withValues(alpha: 0.2),
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                enabledThumbRadius: 6,
                                              ),
                                        ),
                                        child: Slider(
                                          min: -3000,
                                          max: 3000,
                                          divisions: 60,
                                          value: _syncOffsetMs,
                                          onChanged: (val) {
                                            setInnerState(
                                              () => _syncOffsetMs = val,
                                            );
                                            setState(() => _syncOffsetMs = val);
                                          },
                                          onChangeEnd: (val) {
                                            final targetPos =
                                                CastService()
                                                    .castPosition
                                                    .value +
                                                Duration(
                                                  milliseconds: val.toInt(),
                                                );
                                            _player?.seek(targetPos);
                                          },
                                        ),
                                      ),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            'Atrasar',
                                            style: TextStyle(
                                              color: Colors.white.withValues(
                                                alpha: 0.5,
                                              ),
                                              fontSize: 10,
                                            ),
                                          ),
                                          Text(
                                            'Adelantar',
                                            style: TextStyle(
                                              color: Colors.white.withValues(
                                                alpha: 0.5,
                                              ),
                                              fontSize: 10,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ],
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.cast_rounded, size: 20),
                                label: const Text('Dejar de transmitir'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red.withValues(
                                    alpha: 0.2,
                                  ),
                                  foregroundColor: Colors.red,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  elevation: 0,
                                ),
                                onPressed: () {
                                  castService.disconnect();
                                  setState(() => _localAudioDuringCast = false);
                                  // Re-activar track de video y reanudar
                                  try {
                                    final mpv = _player?.platform as dynamic;
                                    mpv?.setProperty('vid', 'auto');
                                  } catch (_) {}
                                  _player?.play();
                                  Navigator.pop(context);
                                  _showVisualNotice('Transmisión finalizada');
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
      );
      return;
    }

    // Si no está conectado, buscar dispositivos
    _showVisualBottomSheet(
      builder:
          (context) => _CastDeviceSelector(
            isLandscape: _isLandscape,
            onDeviceSelected: (device) async {
              Navigator.pop(context);
              _showVisualNotice('Conectando a ${device.name}...');

              final connected = await castService.connectToDevice(device);
              if (!mounted) return;

              if (connected) {
                // Pausar la reproducción local ANTES de cargar en Chromecast
                if (_player?.state.playing ?? false) {
                  _player?.pause();
                }
                // Desactivar track de video local para ahorrar recursos
                try {
                  final mpv = _player?.platform as dynamic;
                  mpv?.setProperty('vid', 'no');
                } catch (_) {}

                final currentUrl =
                    _serverUrls[_currentServerIndex % _serverUrls.length];

                castAudioHandler.setMediaItem(
                  id: currentUrl,
                  title: _currentItem.name,
                  artist: 'Bump Comba',
                  album: device.name,
                  artUri: _currentItem.logo,
                );
                await castService.loadMedia(
                  url: currentUrl,
                  title: _currentItem.name,
                  thumbnailUrl: _currentItem.logo,
                  startPosition:
                      (_player?.state.position.inSeconds ?? 0).toDouble(),
                );

                _showVisualNotice('Transmitiendo a ${device.name}');
                // Advertencia sobre compatibilidad de audio
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted) {
                    _showAppSnackBar(
                      'Algunos contenidos pueden presentar problemas de audio al reproducirse en el TV',
                    );
                  }
                });
              } else {
                _showAppSnackBar('No se pudo conectar a ${device.name}');
              }
            },
          ),
    );
  }

  Future<void> _togglePiP() async {
    if (!PremiumService().isPremium) {
      _showPremiumRequirement('Modo ventana (PiP) disponible con Premium');
      return;
    }

    try {
      final width = _player?.state.width ?? 1920;
      final height = _player?.state.height ?? 1080;

      if (_isPiPSupported) {
        await platform.invokeMethod('enterPiP', {
          'width': width,
          'height': height,
          'playing': _player?.state.playing ?? false,
        });
      }

      if (mounted) {
        setState(() => _showControls = false);
      }
    } catch (e) {
      debugPrint('Error PiP: $e');
      if (mounted) {
        _showAppSnackBar('No compatible con este título o dispositivo');
      }
    }
  }

  void _showAppSnackBar(String message) {
    if (!mounted) return;
    _innerMessengerKey.currentState?.hideCurrentSnackBar();
    _innerMessengerKey.currentState?.showSnackBar(
      SnackBarUtils.getAppSnackBar(message),
    );
  }

  void _showPremiumRequirement(String message) {
    if (!mounted) return;
    _innerMessengerKey.currentState?.hideCurrentSnackBar();
    _innerMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        backgroundColor: const Color.fromARGB(255, 22, 22, 22),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
        shape: RoundedRectangleBorder(
          side: const BorderSide(
            color: Color.fromARGB(59, 192, 192, 192),
            width: 0.5,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        action: SnackBarAction(
          label: 'Ver Planes',
          textColor: Colors.amberAccent,
          onPressed: () {
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            );
          },
        ),
      ),
    );
    // Force dismiss after 4 seconds (Material 3 ignores duration with actions)
    Timer(const Duration(seconds: 3), () {
      if (mounted) {
        _innerMessengerKey.currentState?.hideCurrentSnackBar();
      }
    });
  }

  void _exitFullscreenIfActive() {
    if (_isLandscape &&
        (kIsWeb ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      _toggleOrientation();
    }
  }

  Widget _buildSeekButton({
    required String assetPath,
    required VoidCallback onTap,
    required double iconSize,
  }) {
    return IconButton(
      icon: Image.asset(
        assetPath,
        width: iconSize,
        height: iconSize,
        color: Colors.white,
      ),
      iconSize: iconSize,
      onPressed: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final size = MediaQuery.of(context).size;
    final isPiP = size.height < 300 || size.width < 300;

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape):
            const ExitFullscreenIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ExitFullscreenIntent: CallbackAction<ExitFullscreenIntent>(
            onInvoke: (intent) => _exitFullscreenIfActive(),
          ),
        },
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            final castService = CastService();
            Duration position = Duration.zero;
            Duration duration = Duration.zero;

            if (castService.isCasting.value) {
              position = castService.castPosition.value;
              duration = castService.castDuration.value;
            } else if (_player != null) {
              position = _player!.state.position;
              duration = _player!.state.duration;
            }

            if (duration.inSeconds > 0) {
              // Fire and forget to avoid blocking navigation (ANR prevention)
              _watchProgressService.saveProgress(
                _currentItem.url,
                position,
                duration,
                name: _currentItem.name,
                seriesName: _currentItem.seriesName,
                seasonNumber: _currentItem.seasonNumber,
                episodeNumber: _currentItem.episodeNumber,
              );
            }
            Navigator.pop(context);
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            body: RotatedBox(
              quarterTurns: (_isLandscape && !isPiP) ? 1 : 0,
              child: ScaffoldMessenger(
                key: _innerMessengerKey,
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: Listener(
                    onPointerDown: (_) => _activePointers++,
                    onPointerUp: (_) => _activePointers--,
                    onPointerCancel: (_) => _activePointers--,
                    child: GestureDetector(
                      onTap: _handleMainTap,
                      onLongPressStart: (_) {
                        if (_player != null && !_isVideoLoading) {
                          HapticFeedback.vibrate();
                          _player!.setRate(2.0);
                          setState(() => _isFastForwarding = true);
                        }
                      },
                      onLongPressEnd: (_) {
                        if (_player != null) {
                          _player!.setRate(1.0);
                          setState(() => _isFastForwarding = false);
                        }
                      },
                      onDoubleTapDown: (details) {
                        if (_isScaling) return; // mutex
                        final size = MediaQuery.of(context).size;
                        final visualWidth =
                            _isLandscape ? size.height : size.width;
                        if (details.localPosition.dx < visualWidth / 3) {
                          setState(() {
                            _seekFeedbackForward = false;
                            _seekFeedbackSeconds = 10;
                          });
                          _seekBackward(showControls: false);
                        } else if (details.localPosition.dx >
                            visualWidth * 2 / 3) {
                          setState(() {
                            _seekFeedbackForward = true;
                            _seekFeedbackSeconds = 10;
                          });
                          _seekForward(showControls: false);
                        } else {
                          _videoFitNotifier.value =
                              _videoFitNotifier.value == BoxFit.cover
                                  ? BoxFit.contain
                                  : BoxFit.cover;
                          _showVisualNotice(
                            _videoFitNotifier.value == BoxFit.cover
                                ? 'Se ajustó el contenido a la pantalla'
                                : 'Original',
                          );
                        }
                      },
                      onVerticalDragStart: _onSwipeDragStart,
                      onVerticalDragUpdate: _onSwipeDragUpdate,
                      onVerticalDragEnd: _onSwipeDragEnd,
                      onScaleStart: (details) {
                        if (details.pointerCount >= 2) _isScaling = true;
                      },
                      onScaleEnd: (details) {
                        _isScaling = false;
                      },
                      onScaleUpdate: (details) {
                        if (details.pointerCount < 2) return;
                        if (details.scale > 1.1 &&
                            _videoFitNotifier.value != BoxFit.cover) {
                          _videoFitNotifier.value = BoxFit.cover;
                          _showVisualNotice(
                            'Se ajustó el contenido a la pantalla',
                          );
                        } else if (details.scale < 0.9 &&
                            _videoFitNotifier.value != BoxFit.contain) {
                          _videoFitNotifier.value = BoxFit.contain;
                          _showVisualNotice('Original');
                        }
                      },
                      child: AnimatedBuilder(
                        animation: _swipeAnimController,
                        builder: (context, child) {
                          final offset =
                              (_swipeAnimController.isAnimating &&
                                      _swipeSnapAnim != null)
                                  ? _swipeSnapAnim!.value
                                  : _swipeDragOffset;
                          final progress = (offset.abs() / 160.0).clamp(
                            0.0,
                            1.0,
                          );
                          final scale = 1.0 - (progress * 0.05);
                          final radius = progress * 16.0;

                          return Transform(
                            alignment: Alignment.center,
                            transform:
                                Matrix4.identity()
                                  ..translate(0.0, offset * 0.15)
                                  ..scale(scale),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(radius),
                              child: child!,
                            ),
                          );
                        },
                        child: Stack(
                          children: [
                            if (_hasError)
                              _buildErrorUI()
                            else ...[
                              Center(
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    ValueListenableBuilder<bool>(
                                      valueListenable: CastService().isCasting,
                                      builder: (context, isCasting, _) {
                                        // Si estamos transmitiendo, SIEMPRE mostramos el placeholder.
                                        // Esto libera los recursos del SurfaceView (video) incluso si
                                        // el usuario decide escuchar solo el audio en el teléfono.
                                        if (isCasting) {
                                          return _buildCastingPlaceholder();
                                        }

                                        return ValueListenableBuilder<
                                          VideoController?
                                        >(
                                          valueListenable:
                                              _videoControllerNotifier,
                                          builder: (context, controller, _) {
                                            if (controller == null) {
                                              return const SizedBox.shrink();
                                            }
                                            return ValueListenableBuilder<
                                              BoxFit
                                            >(
                                              valueListenable:
                                                  _videoFitNotifier,
                                              builder: (context, fit, child) {
                                                if (fit == BoxFit.cover) {
                                                  return LayoutBuilder(
                                                    builder: (
                                                      context,
                                                      constraints,
                                                    ) {
                                                      final videoController =
                                                          controller;
                                                      final aspectRatio =
                                                          (videoController
                                                                  .player
                                                                  .state
                                                                  .width ??
                                                              16) /
                                                          (videoController
                                                                  .player
                                                                  .state
                                                                  .height ??
                                                              9);
                                                      final screenAspect =
                                                          constraints.maxWidth /
                                                          constraints.maxHeight;
                                                      double scale = 1.0;
                                                      if (aspectRatio >
                                                          screenAspect) {
                                                        scale =
                                                            constraints
                                                                .maxHeight *
                                                            aspectRatio /
                                                            constraints
                                                                .maxWidth;
                                                      } else {
                                                        scale =
                                                            constraints
                                                                .maxWidth /
                                                            (constraints
                                                                    .maxHeight *
                                                                aspectRatio);
                                                      }
                                                      return Transform.scale(
                                                        scale: scale.clamp(
                                                          1.0,
                                                          3.0,
                                                        ),
                                                        child: child!,
                                                      );
                                                    },
                                                  );
                                                }
                                                return child!;
                                              },
                                              child: Video(
                                                key: ValueKey(_videoKey),
                                                controller: controller,
                                                fill: Colors.black,
                                                fit: BoxFit.contain,
                                                controls: NoVideoControls,
                                              ),
                                            );
                                          },
                                        );
                                      },
                                    ),
                                    if (_isVideoLoading ||
                                        _isBuffering ||
                                        _isSeeking)
                                      _buildVideoLoading(
                                        showBackground: _isVideoLoading,
                                      )
                                    else
                                      const SizedBox.shrink(),
                                  ],
                                ),
                              ),

                              if (_nextEpisodeCountdown != null)
                                Positioned.fill(child: _buildAutoPlayOverlay()),

                              if (_adCountdown != null)
                                Positioned(
                                  top: 60,
                                  right: 24,
                                  child: _buildAdCountdownOverlay(),
                                ),

                              if (isPiP) _buildPiPUI(),

                              if (_seekFeedbackSeconds != null &&
                                  !_showControls)
                                _buildSeekFeedback(),

                              defaultTargetPlatform == TargetPlatform.iOS
                                  ? _buildControlsIOS()
                                  : _buildControls(),
                              if (_subtitlesEnabled &&
                                  _currentSubtitleText.isNotEmpty)
                                _buildSubtitleOverlay(),
                              _buildVisualNotice(),

                              if (_showDiagPanel) _buildDiagPanel(),

                              if (_isFastForwarding)
                                Positioned(
                                  top: 40,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '2 Veces más rápido',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          SizedBox(width: 8),
                                          Icon(
                                            Icons.fast_forward_rounded,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoLoading({bool showBackground = false}) {
    return Stack(
      children: [
        if (showBackground)
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child:
                  _currentItem.logo != null
                      ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Opacity(
                            opacity: 0.7,
                            child: FastThumbnail(
                              url: _currentItem.logo!,
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.cover,
                            ),
                          ),
                          BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                            child: Container(color: Colors.transparent),
                          ),
                        ],
                      )
                      : null,
            ),
          ),
        Align(
          alignment: Alignment.center,
          child:
              defaultTargetPlatform == TargetPlatform.iOS
                  ? CupertinoActivityIndicator(
                    radius:
                        16.0 *
                        ((MediaQuery.of(context).size.shortestSide / 414.0)
                                .clamp(0.8, 1.25) *
                            1.02),
                    color: Colors.white,
                  )
                  : _AppLoadingAnimation(
                    size:
                        56.0 *
                        ((MediaQuery.of(context).size.shortestSide / 414.0)
                                .clamp(0.8, 1.25) *
                            1.02),
                    strokeWidth:
                        3.5 *
                        ((MediaQuery.of(context).size.shortestSide / 414.0)
                                .clamp(0.8, 1.25) *
                            1.02),
                  ),
        ),
        if (showBackground &&
            (context
                    .findAncestorStateOfType<_VideoPlayerScreenState>()
                    ?._isScraping ??
                false))
          const Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Text(
              'Procesando enlaces...',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCastingPlaceholder() {
    final castService = CastService();
    final deviceName = castService.connectedDevice?.name ?? 'TV';
    final size = MediaQuery.of(context).size;
    final double scale = (size.shortestSide / 414.0).clamp(0.8, 1.25);

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Fondo con Poster Desenfocado y Gradiente
          if (_currentItem.logo != null) ...[
            Opacity(
              opacity: 0.35,
              child: FastThumbnail(
                url: _currentItem.logo!,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.8),
                      Colors.black,
                    ],
                  ),
                ),
              ),
            ),
          ],

          // Contenido Central
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icono con Efecto de Resplandor (Aura)
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(seconds: 2),
                  builder: (context, value, child) {
                    return Container(
                      padding: EdgeInsets.all(24 * scale),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.redAccent.withValues(
                              alpha: 0.15 + (0.05 * math.sin(value * math.pi)),
                            ),
                            blurRadius: 40 + (10 * math.sin(value * math.pi)),
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                    );
                  },
                ),
                SizedBox(height: 1 * scale),

                // Título de Dispositivo
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    'Estás viendo en $deviceName',
                    style: TextStyle(
                      color: const Color.fromARGB(237, 255, 255, 255),
                      fontSize: (_isLandscape ? 20 : 19) * scale,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(height: 12 * scale),

                // Nombre del Contenido
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Builder(
                    builder: (context) {
                      final clean = NormalizationUtils.extractEpisodeTitle(
                        _currentItem.name,
                      );
                      final epNum =
                          _currentItem.episodeNumber ??
                          NormalizationUtils.parseEpisodeNumber(
                            _currentItem.name,
                          );
                      final episodeLabel =
                          clean.isEmpty
                              ? _currentItem.name
                              : (epNum != null ? '$epNum. $clean' : clean);
                      final seriesName = _currentItem.seriesName;

                      if (seriesName != null &&
                          seriesName.isNotEmpty &&
                          seriesName != episodeLabel) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              seriesName,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: (_isLandscape ? 15 : 14) * scale,
                                fontWeight: FontWeight.w400,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              episodeLabel,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: (_isLandscape ? 17 : 16) * scale,
                                fontWeight: FontWeight.w500,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        );
                      }

                      return Text(
                        episodeLabel,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: (_isLandscape ? 15 : 14) * scale,
                          fontWeight: FontWeight.w400,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ),
                SizedBox(height: 48 * scale),

                // Badge de Optimización
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _localAudioDuringCast
                            ? Icons.volume_up_rounded
                            : Icons.bolt_rounded,
                        color:
                            _localAudioDuringCast
                                ? Colors.redAccent
                                : Colors.amber,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _localAudioDuringCast
                            ? 'Escuchando desde el teléfono'
                            : 'Audio reproduciéndose en el televisor',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12 * scale,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Botón de la barra inferior — ícono a la izquierda, texto a la derecha
  Widget _buildNetflixBarButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required double scale,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 6 * scale,
          vertical: 8 * scale,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 22 * scale),
            SizedBox(width: 5 * scale),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color.fromARGB(255, 236, 236, 236),
                  fontSize: 13 * scale,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    final size = MediaQuery.of(context).size;
    final isPiP = size.height < 300 || size.width < 300;
    if (isPiP) return const SizedBox.shrink();

    // 1. Lógica de escalado responsivo
    final double shortestSide = size.shortestSide;
    final double scale = (shortestSide / 414.0).clamp(0.8, 1.25) * 1.02;
    final double centralIconSize = 64.0 * scale;
    final double seekIconSize = centralIconSize * 0.85;
    final double seekGap = (size.width * (_isLandscape ? 0.10 : 0.05)).clamp(
      16.0,
      60.0,
    );

    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _controlsAnim,
        builder: (context, child) {
          final isVisible = _controlsAnim.value > 0;
          return IgnorePointer(
            ignoring: !isVisible,
            child: Opacity(opacity: _controlsAnim.value, child: child),
          );
        },
        child: Container(
          color: Colors.black.withValues(alpha: 0.3),
          child: Stack(
            children: [
              // Centro Absoluto (Fuera del SafeArea para coincidir con el Spinner)
              Align(
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!_currentItem.isLive) ...[
                      _buildSeekButton(
                        assetPath: 'assets/images/Retroceder.png',
                        onTap: _seekBackward,
                        iconSize: seekIconSize,
                      ),
                      SizedBox(width: seekGap),
                    ],
                    ValueListenableBuilder<bool>(
                      valueListenable: CastService().isCasting,
                      builder: (context, isCasting, _) {
                        return isCasting
                            ? ValueListenableBuilder<bool>(
                              valueListenable: CastService().castPlaying,
                              builder: (context, isPlaying, _) {
                                return IconButton(
                                  onPressed: _togglePlayback,
                                  icon: _PremiumPlayPauseIcon(
                                    isPlaying: isPlaying,
                                    size: centralIconSize,
                                  ),
                                );
                              },
                            )
                            : StreamBuilder<bool>(
                              stream: _player?.stream.playing,
                              initialData: _player?.state.playing,
                              builder: (context, snapshot) {
                                final isPlaying = snapshot.data ?? false;
                                return IconButton(
                                  onPressed: _togglePlayback,
                                  icon: _PremiumPlayPauseIcon(
                                    isPlaying: isPlaying,
                                    size: centralIconSize,
                                  ),
                                );
                              },
                            );
                      },
                    ),
                    if (!_currentItem.isLive) ...[
                      SizedBox(width: seekGap),
                      _buildSeekButton(
                        assetPath: 'assets/images/Avanzar.png',
                        onTap: _seekForward,
                        iconSize: seekIconSize,
                      ),
                    ],
                  ],
                ),
              ),

              // Barras Superior e Inferior (Dentro de SafeArea)
              SafeArea(
                child: Stack(
                  children: [
                    // Barra Superior
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: _isLandscape ? 0 : 8,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  padding:
                                      _isLandscape
                                          ? EdgeInsets.zero
                                          : const EdgeInsets.all(8),
                                  constraints:
                                      _isLandscape
                                          ? const BoxConstraints()
                                          : null,
                                  icon: const Icon(
                                    Icons.arrow_back_ios_new,
                                    color: Colors.white,
                                  ),
                                  onPressed: () async {
                                    if (_player != null && !_isVideoLoading) {
                                      final castService = CastService();
                                      Duration position = Duration.zero;
                                      Duration duration = Duration.zero;

                                      if (castService.isCasting.value) {
                                        position =
                                            castService.castPosition.value;
                                        duration =
                                            castService.castDuration.value;
                                      } else if (_player != null) {
                                        position = _player!.state.position;
                                        duration = _player!.state.duration;
                                      }

                                      if (duration.inSeconds > 0) {
                                        await _watchProgressService
                                            .saveProgress(
                                              _currentItem.url,
                                              position,
                                              duration,
                                              name: _currentItem.name,
                                              seriesName:
                                                  _currentItem.seriesName,
                                              seasonNumber:
                                                  _currentItem.seasonNumber,
                                              episodeNumber:
                                                  _currentItem.episodeNumber,
                                            );
                                      }
                                    }
                                    if (mounted) Navigator.maybePop(context);
                                  },
                                ),
                                Expanded(
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.start,
                                    children: [
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onLongPress: _toggleDiagPanel,
                                          child: Builder(
                                            builder: (context) {
                                              final clean =
                                                  NormalizationUtils.extractEpisodeTitle(
                                                    _currentItem.name,
                                                  );
                                              final epNum =
                                                  _currentItem.episodeNumber ??
                                                  NormalizationUtils.parseEpisodeNumber(
                                                    _currentItem.name,
                                                  );

                                              final episodeLabel =
                                                  clean.isEmpty
                                                      ? _currentItem.name
                                                      : (epNum != null
                                                          ? '$epNum. $clean'
                                                          : clean);
                                              final seriesName =
                                                  _currentItem.seriesName;

                                              if (seriesName != null &&
                                                  seriesName.isNotEmpty &&
                                                  seriesName != episodeLabel) {
                                                return Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      seriesName,
                                                      style: TextStyle(
                                                        color: Colors.white
                                                            .withValues(
                                                              alpha: 0.55,
                                                            ),
                                                        fontSize: 14 * scale,
                                                        fontWeight:
                                                            FontWeight.w400,
                                                        letterSpacing: 0.2,
                                                      ),
                                                      textAlign:
                                                          TextAlign.start,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      episodeLabel,
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 16 * scale,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        letterSpacing: -0.2,
                                                      ),
                                                      textAlign:
                                                          TextAlign.start,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                );
                                              }

                                              return Text(
                                                episodeLabel,
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 16 * scale,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                textAlign: TextAlign.start,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Botón de Cast / Transmitir a TV
                                ValueListenableBuilder<bool>(
                                  valueListenable: CastService().isCasting,
                                  builder: (context, casting, _) {
                                    return IconButton(
                                      padding:
                                          _isLandscape
                                              ? EdgeInsets.zero
                                              : const EdgeInsets.all(8),
                                      constraints:
                                          _isLandscape
                                              ? const BoxConstraints()
                                              : null,
                                      icon: Icon(
                                        casting
                                            ? Icons.cast_connected_rounded
                                            : Icons.cast_rounded,
                                        color:
                                            casting
                                                ? Colors.redAccent
                                                : Colors.white,
                                        size: 24 * scale,
                                      ),
                                      onPressed: _showCastSelection,
                                    );
                                  },
                                ),
                                IconButton(
                                  padding:
                                      _isLandscape
                                          ? EdgeInsets.zero
                                          : const EdgeInsets.all(8),
                                  constraints:
                                      _isLandscape
                                          ? const BoxConstraints()
                                          : null,
                                  icon: Icon(
                                    Icons.picture_in_picture_alt_rounded,
                                    color: Colors.white,
                                    size: 24 * scale,
                                  ),
                                  onPressed: _togglePiP,
                                ),
                                IconButton(
                                  padding:
                                      _isLandscape
                                          ? EdgeInsets.zero
                                          : const EdgeInsets.all(8),
                                  constraints:
                                      _isLandscape
                                          ? const BoxConstraints()
                                          : null,
                                  icon: Icon(
                                    _isLandscape
                                        ? Icons.fullscreen_exit_rounded
                                        : Icons.fullscreen_rounded,
                                    color: Colors.white,
                                    size: 24 * scale,
                                  ),
                                  onPressed: _toggleOrientation,
                                ),
                              ],
                            ),
                            // Indicador de calidad de red (solo en datos móviles y red débil)
                            ValueListenableBuilder<NetworkQuality>(
                              valueListenable: _networkQuality.quality,
                              builder: (context, q, _) {
                                if (!_networkQuality.isMobileData.value ||
                                    q.index < NetworkQuality.fair.index) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        q == NetworkQuality.poor
                                            ? Icons.signal_cellular_0_bar
                                            : Icons.signal_cellular_alt_1_bar,
                                        size: 11 * scale,
                                        color:
                                            q == NetworkQuality.poor
                                                ? Colors.red
                                                : Colors.amber,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        q == NetworkQuality.poor
                                            ? 'Señal muy débil — modo de emergencia activo'
                                            : 'Señal débil — modo ahorro activo',
                                        style: TextStyle(
                                          color:
                                              q == NetworkQuality.poor
                                                  ? Colors.red.shade300
                                                  : Colors.amber.shade300,
                                          fontSize: 10 * scale,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            if (_currentItem.isLive && !_isLandscape)
                              Padding(
                                padding: const EdgeInsets.only(left: 8, top: 8),
                                child: _buildLiveBadge(),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // Barra Inferior
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Padding(
                        padding: EdgeInsets.all(20 * scale),
                        child:
                            _currentItem.isLive
                                ? (_isLandscape
                                    ? Container(
                                      padding: const EdgeInsets.only(
                                        bottom: 20,
                                        left: 8,
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.start,
                                        children: [_buildLiveBadge()],
                                      ),
                                    )
                                    : const SizedBox.shrink())
                                : StreamBuilder<Duration>(
                                  stream:
                                      _player?.stream.position
                                          .where((_) => !_isDragging)
                                          .map(
                                            (d) =>
                                                Duration(seconds: d.inSeconds),
                                          )
                                          .distinct(),
                                  initialData: _player?.state.position,
                                  builder: (context, positionSnapshot) {
                                    return StreamBuilder<Duration>(
                                      stream: _player?.stream.duration,
                                      initialData: _player?.state.duration,
                                      builder: (context, durationSnapshot) {
                                        return ValueListenableBuilder<bool>(
                                          valueListenable:
                                              CastService().isCasting,
                                          builder: (context, isCasting, _) {
                                            return ValueListenableBuilder<
                                              Duration
                                            >(
                                              valueListenable:
                                                  CastService().castPosition,
                                              builder: (context, castPos, _) {
                                                return ValueListenableBuilder<
                                                  Duration
                                                >(
                                                  valueListenable:
                                                      CastService()
                                                          .castDuration,
                                                  builder: (
                                                    context,
                                                    castDur,
                                                    _,
                                                  ) {
                                                    final position =
                                                        isCasting
                                                            ? castPos
                                                            : (positionSnapshot
                                                                    .data ??
                                                                Duration.zero);
                                                    final duration =
                                                        isCasting
                                                            ? castDur
                                                            : (durationSnapshot
                                                                    .data ??
                                                                Duration.zero);
                                                    final max =
                                                        duration.inMilliseconds
                                                            .toDouble();
                                                    final value =
                                                        _isDragging
                                                            ? _dragValue
                                                            : position
                                                                .inMilliseconds
                                                                .toDouble()
                                                                .clamp(
                                                                  0.0,
                                                                  max > 0
                                                                      ? max
                                                                      : 0.0,
                                                                );

                                                    return GestureDetector(
                                                      behavior:
                                                          HitTestBehavior
                                                              .opaque,
                                                      onHorizontalDragUpdate:
                                                          (_) {},
                                                      child: Column(
                                                        children: [
                                                          SliderTheme(
                                                            data: SliderThemeData(
                                                              trackHeight:
                                                                  1.5 * scale,
                                                              activeTrackColor:
                                                                  const Color.fromARGB(
                                                                    255,
                                                                    190,
                                                                    19,
                                                                    19,
                                                                  ),
                                                              inactiveTrackColor:
                                                                  Colors.white
                                                                      .withValues(
                                                                        alpha:
                                                                            0.24,
                                                                      ),
                                                              thumbColor:
                                                                  const Color(
                                                                    0xFFC41212,
                                                                  ),
                                                              thumbShape:
                                                                  RoundSliderThumbShape(
                                                                    enabledThumbRadius:
                                                                        7.5 *
                                                                        scale,
                                                                  ),
                                                              overlayShape:
                                                                  RoundSliderOverlayShape(
                                                                    overlayRadius:
                                                                        14 *
                                                                        scale,
                                                                  ),
                                                            ),
                                                            child: Slider(
                                                              min: 0,
                                                              max:
                                                                  max > 0
                                                                      ? max
                                                                      : 1,
                                                              value: value,
                                                              onChangeStart: (
                                                                newValue,
                                                              ) {
                                                                setState(() {
                                                                  _isDragging =
                                                                      true;
                                                                  _dragValue =
                                                                      newValue;
                                                                });
                                                              },
                                                              onChanged: (
                                                                newValue,
                                                              ) {
                                                                setState(
                                                                  () =>
                                                                      _dragValue =
                                                                          newValue,
                                                                );
                                                              },
                                                              onChangeEnd: (
                                                                newValue,
                                                              ) {
                                                                final castService =
                                                                    CastService();
                                                                if (castService
                                                                    .isCasting
                                                                    .value) {
                                                                  castService.seek(
                                                                    newValue /
                                                                        1000.0,
                                                                  );
                                                                } else {
                                                                  _player?.seek(
                                                                    Duration(
                                                                      milliseconds:
                                                                          newValue
                                                                              .toInt(),
                                                                    ),
                                                                  );
                                                                }
                                                                setState(() {
                                                                  _isDragging =
                                                                      false;
                                                                  _isSeeking =
                                                                      true;
                                                                });
                                                                Future.delayed(
                                                                  const Duration(
                                                                    milliseconds:
                                                                        1000,
                                                                  ),
                                                                  () {
                                                                    if (mounted &&
                                                                        _isSeeking) {
                                                                      setState(
                                                                        () =>
                                                                            _isSeeking =
                                                                                false,
                                                                      );
                                                                    }
                                                                  },
                                                                );
                                                              },
                                                            ),
                                                          ),
                                                          // ── Fila de tiempos ──────────────
                                                          Padding(
                                                            padding:
                                                                EdgeInsets.symmetric(
                                                                  horizontal:
                                                                      8 * scale,
                                                                ),
                                                            child: Row(
                                                              children: [
                                                                Text(
                                                                  WatchProgressService.formatDuration(
                                                                    Duration(
                                                                      milliseconds:
                                                                          value
                                                                              .toInt(),
                                                                    ),
                                                                  ),
                                                                  style: TextStyle(
                                                                    color:
                                                                        Colors
                                                                            .white70,
                                                                    fontSize:
                                                                        11 *
                                                                        scale,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w500,
                                                                  ),
                                                                ),
                                                                const Spacer(),
                                                                Text(
                                                                  WatchProgressService.formatDuration(
                                                                    duration,
                                                                  ),
                                                                  style: TextStyle(
                                                                    color:
                                                                        Colors
                                                                            .white70,
                                                                    fontSize:
                                                                        11 *
                                                                        scale,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w500,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                          // ── Barra Netflix ─────────────────
                                                          Padding(
                                                            padding:
                                                                EdgeInsets.only(
                                                                  top:
                                                                      6 * scale,
                                                                  left:
                                                                      2 * scale,
                                                                  right:
                                                                      2 * scale,
                                                                ),
                                                            child: Row(
                                                              children: [
                                                                // Velocidad
                                                                Expanded(
                                                                  child: Center(
                                                                    child: StreamBuilder<
                                                                      double
                                                                    >(
                                                                      stream:
                                                                          _player
                                                                              ?.stream
                                                                              .rate,
                                                                      initialData:
                                                                          _player
                                                                              ?.state
                                                                              .rate ??
                                                                          1.0,
                                                                      builder: (
                                                                        context,
                                                                        rateSnap,
                                                                      ) {
                                                                        final rate =
                                                                            rateSnap.data ??
                                                                            1.0;
                                                                        final label =
                                                                            rate ==
                                                                                    rate.roundToDouble()
                                                                                ? '${rate.toInt()}x'
                                                                                : '${rate}x';
                                                                        return _buildNetflixBarButton(
                                                                          icon:
                                                                              Icons.speed_rounded,
                                                                          label:
                                                                              'Velocidad ($label)',
                                                                          onTap:
                                                                              _showSpeedSelection,
                                                                          scale:
                                                                              scale,
                                                                        );
                                                                      },
                                                                    ),
                                                                  ),
                                                                ),
                                                                // Episodios
                                                                if (_playlist
                                                                        .length >
                                                                    1)
                                                                  Expanded(
                                                                    child: Center(
                                                                      child: _buildNetflixBarButton(
                                                                        icon:
                                                                            Icons.video_library_outlined,
                                                                        label:
                                                                            'Episodios',
                                                                        onTap:
                                                                            _showEpisodeSelection,
                                                                        scale:
                                                                            scale,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                // Audio y subtítulos
                                                                Expanded(
                                                                  child: Center(
                                                                    child: _buildNetflixBarButton(
                                                                      icon:
                                                                          Icons
                                                                              .subtitles_outlined,
                                                                      label:
                                                                          'Audio y subtítulos',
                                                                      onTap:
                                                                          _showSettingsMenu,
                                                                      scale:
                                                                          scale,
                                                                    ),
                                                                  ),
                                                                ),
                                                                // Siguiente episodio
                                                                if (_playlist
                                                                        .isNotEmpty &&
                                                                    _playlist.indexWhere(
                                                                          (i) =>
                                                                              i.url ==
                                                                              _currentItem.url,
                                                                        ) <
                                                                        _playlist.length -
                                                                            1)
                                                                  Expanded(
                                                                    child: Center(
                                                                      child: _buildNetflixBarButton(
                                                                        icon:
                                                                            Icons.skip_next_rounded,
                                                                        label:
                                                                            'Siguiente ep.',
                                                                        onTap:
                                                                            _playNextEpisode,
                                                                        scale:
                                                                            scale,
                                                                      ),
                                                                    ),
                                                                  ),
                                                              ],
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                  },
                                                );
                                              },
                                            );
                                          },
                                        );
                                      },
                                    );
                                  },
                                ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PANEL DE DIAGNÓSTICO (toque largo en el título del reproductor)
  // ─────────────────────────────────────────────────────────────────────────
  void _toggleDiagPanel() {
    setState(() => _showDiagPanel = !_showDiagPanel);
    _diagTimer?.cancel();
    if (_showDiagPanel) {
      // Refresca el panel cada 500ms para que los valores sean en vivo.
      _diagTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        if (!mounted || !_showDiagPanel) return;
        // Consultar a MPV el códec real y si el hardware está activo.
        final mpv = _player?.platform as dynamic;
        if (mpv != null) {
          try {
            final c = await mpv.getProperty('video-codec');
            _diagCodec =
                (c == null || c.toString().isEmpty)
                    ? 'null (sin video)'
                    : c.toString();
          } catch (_) {
            _diagCodec = 'err';
          }
          try {
            final hw = await mpv.getProperty('hwdec-current');
            _diagHwdecActivo =
                (hw == null || hw.toString().isEmpty) ? 'null' : hw.toString();
          } catch (_) {
            _diagHwdecActivo = 'err';
          }
          // Volcado detallado de pistas de video: id, códec, dimensiones,
          // si es carátula (albumart) y si está seleccionada. Decisivo para
          // saber por qué no se activa ninguna pista.
          try {
            final selVid = await mpv.getProperty('vid');
            _diagVidSel = selVid?.toString() ?? '?';
          } catch (_) {
            _diagVidSel = 'err';
          }
          if (_diagTrackCodecs == '?' ||
              _diagTrackCodecs == 'err' ||
              _diagTrackCodecs.isEmpty) {
            try {
              final cntStr = await mpv.getProperty('track-list/count');
              final cnt = int.tryParse(cntStr?.toString() ?? '0') ?? 0;
              final parts = <String>[];
              for (var i = 0; i < cnt; i++) {
                final type = await mpv.getProperty('track-list/$i/type');
                if (type?.toString() == 'video') {
                  final id = await mpv.getProperty('track-list/$i/id');
                  final codec = await mpv.getProperty('track-list/$i/codec');
                  final dw = await mpv.getProperty('track-list/$i/demux-w');
                  final dh = await mpv.getProperty('track-list/$i/demux-h');
                  final art = await mpv.getProperty('track-list/$i/albumart');
                  final sel = await mpv.getProperty('track-list/$i/selected');
                  final isArt = art?.toString() == 'yes';
                  final isSel = sel?.toString() == 'yes';
                  parts.add(
                    '${id ?? '?'}:${codec ?? '?'} '
                    '${dw ?? '?'}x${dh ?? '?'}'
                    '${isArt ? ' art' : ''}${isSel ? ' SEL' : ''}',
                  );
                }
              }
              _diagTrackCodecs =
                  parts.isEmpty ? 'sin pistas' : parts.join(' | ');
            } catch (_) {
              _diagTrackCodecs = 'err';
            }
          }
        }
        _diagVideoTracks = _player?.state.tracks.video.length ?? -1;
        if (mounted && _showDiagPanel) setState(() {});
      });
    }
  }

  Widget _buildDiagPanel() {
    final st = _player?.state;
    final controller = _videoControllerNotifier.value;
    final rect = controller?.rect.value;
    final textureOk = rect != null && rect.width > 0 && rect.height > 0;
    final w = st?.width ?? 0;
    final h = st?.height ?? 0;

    String line(String k, String v) => '$k: $v';

    final lines = <String>[
      line('Plataforma', defaultTargetPlatform.name),
      line('Decoder', _activeDecoder),
      line('Retry', '$_retryCount'),
      line('Reproduciendo', (st?.playing ?? false) ? 'sí' : 'no'),
      line('Buffering', (st?.buffering ?? false) ? 'sí' : 'no'),
      line('Posición', '${st?.position.inSeconds ?? 0}s'),
      line('MPV w×h', '$w×$h'),
      line('Códec activo', _diagCodec),
      line('vid sel', _diagVidSel),
      line('Pistas', _diagTrackCodecs),
      line('HW activo', _diagHwdecActivo),
      line('Pistas video', _diagVideoTracks < 0 ? '?' : '$_diagVideoTracks'),
      line(
        'Textura (rect)',
        textureOk
            ? 'OK ${rect.width.toInt()}×${rect.height.toInt()}'
            : 'NO renderiza',
      ),
      line('Controller', controller == null ? 'null' : 'activo'),
      line('Recarga negra', _blackScreenReloadDone ? 'hecha' : 'no'),
    ];

    return Positioned(
      top: 60,
      left: 12,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: textureOk ? Colors.greenAccent : Colors.redAccent,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '🩺 DIAGNÓSTICO',
                    style: TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _toggleDiagPanel,
                    child: const Icon(
                      Icons.close,
                      color: Colors.white70,
                      size: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ...lines.map(
                (t) => Text(
                  t,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11.5,
                    height: 1.35,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CONTROLES iOS — estilo Apple / nativo
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildControlsIOS() {
    final size = MediaQuery.of(context).size;
    final isPiP = size.height < 300 || size.width < 300;
    if (isPiP) return const SizedBox.shrink();

    final double scale = (size.shortestSide / 414.0).clamp(0.8, 1.25) * 1.02;
    final double sideIconSize = 32.0 * scale;
    final double playCircle = 64.0 * scale;
    final double playIconSize = 32.0 * scale;

    // ── helper: botón play/pause circular estilo iOS ──────────────────────
    Widget playPauseButton(bool isPlaying) {
      return GestureDetector(
        onTap: _togglePlayback,
        child: Container(
          width: playCircle,
          height: playCircle,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.18),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1.2,
            ),
          ),
          child: Center(
            child: _PremiumPlayPauseIcon(
              isPlaying: isPlaying,
              size: playIconSize,
            ),
          ),
        ),
      );
    }

    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _controlsAnim,
        builder: (context, child) {
          final visible = _controlsAnim.value > 0;
          return IgnorePointer(
            ignoring: !visible,
            child: Opacity(opacity: _controlsAnim.value, child: child),
          );
        },
        child: Stack(
          children: [
            // ── Gradiente superior ────────────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 180,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xD9000000), Colors.transparent],
                    stops: [0.0, 1.0],
                  ),
                ),
              ),
            ),
            // ── Gradiente inferior ────────────────────────────────────────
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 220,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xD9000000), Colors.transparent],
                    stops: [0.0, 1.0],
                  ),
                ),
              ),
            ),

            // ── Centro: seek ← | play/pause | seek → ─────────────────────
            Align(
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_currentItem.isLive) ...[
                    _buildSeekButton(
                      assetPath: 'assets/images/Retroceder.png',
                      onTap: _seekBackward,
                      iconSize: sideIconSize,
                    ),
                    SizedBox(width: 20 * scale),
                  ],
                  ValueListenableBuilder<bool>(
                    valueListenable: CastService().isCasting,
                    builder: (context, isCasting, _) {
                      if (isCasting) {
                        return ValueListenableBuilder<bool>(
                          valueListenable: CastService().castPlaying,
                          builder:
                              (context, isPlaying, _) =>
                                  playPauseButton(isPlaying),
                        );
                      }
                      return StreamBuilder<bool>(
                        stream: _player?.stream.playing,
                        initialData: _player?.state.playing,
                        builder:
                            (context, snap) =>
                                playPauseButton(snap.data ?? false),
                      );
                    },
                  ),
                  if (!_currentItem.isLive) ...[
                    SizedBox(width: 20 * scale),
                    _buildSeekButton(
                      assetPath: 'assets/images/Avanzar.png',
                      onTap: _seekForward,
                      iconSize: sideIconSize,
                    ),
                  ],
                ],
              ),
            ),

            // ── SafeArea: barra superior + inferior ───────────────────────
            SafeArea(
              child: Stack(
                children: [
                  // Barra superior
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: _isLandscape ? 2 : 8,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              // Botón atrás
                              CupertinoButton(
                                padding: const EdgeInsets.all(8),
                                minSize: 0,
                                onPressed: () async {
                                  if (_player != null && !_isVideoLoading) {
                                    final cs = CastService();
                                    Duration pos = Duration.zero;
                                    Duration dur = Duration.zero;
                                    if (cs.isCasting.value) {
                                      pos = cs.castPosition.value;
                                      dur = cs.castDuration.value;
                                    } else if (_player != null) {
                                      pos = _player!.state.position;
                                      dur = _player!.state.duration;
                                    }
                                    if (dur.inSeconds > 0) {
                                      await _watchProgressService.saveProgress(
                                        _currentItem.url,
                                        pos,
                                        dur,
                                        name: _currentItem.name,
                                        seriesName: _currentItem.seriesName,
                                        seasonNumber: _currentItem.seasonNumber,
                                        episodeNumber:
                                            _currentItem.episodeNumber,
                                      );
                                    }
                                  }
                                  if (mounted) Navigator.maybePop(context);
                                },
                                child: const Icon(
                                  CupertinoIcons.chevron_left,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Título (toque largo = panel de diagnóstico)
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onLongPress: _toggleDiagPanel,
                                  child: Builder(
                                    builder: (context) {
                                      final seriesName =
                                          _currentItem.seriesName;
                                      final clean =
                                          NormalizationUtils.extractEpisodeTitle(
                                            _currentItem.name,
                                          );
                                      final epNum =
                                          _currentItem.episodeNumber ??
                                          NormalizationUtils.parseEpisodeNumber(
                                            _currentItem.name,
                                          );
                                      final episodeLabel =
                                          clean.isEmpty
                                              ? _currentItem.name
                                              : (epNum != null
                                                  ? '$epNum. $clean'
                                                  : clean);
                                      if (seriesName != null &&
                                          seriesName.isNotEmpty &&
                                          seriesName != episodeLabel) {
                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              seriesName,
                                              style: TextStyle(
                                                color: Colors.white.withValues(
                                                  alpha: 0.55,
                                                ),
                                                fontSize: 14 * scale,
                                                fontWeight: FontWeight.w400,
                                                letterSpacing: 0.2,
                                              ),
                                              textAlign: TextAlign.start,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              episodeLabel,
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 16 * scale,
                                                fontWeight: FontWeight.w600,
                                                letterSpacing: -0.2,
                                              ),
                                              textAlign: TextAlign.start,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        );
                                      }
                                      return Text(
                                        episodeLabel,
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16 * scale,
                                          fontWeight: FontWeight.w700,
                                        ),
                                        textAlign: TextAlign.start,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      );
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Cast
                              ValueListenableBuilder<bool>(
                                valueListenable: CastService().isCasting,
                                builder:
                                    (context, casting, _) => CupertinoButton(
                                      padding: const EdgeInsets.all(8),
                                      minSize: 0,
                                      onPressed: _showCastSelection,
                                      child: Icon(
                                        casting
                                            ? CupertinoIcons.tv_fill
                                            : CupertinoIcons.tv,
                                        color:
                                            casting
                                                ? Colors.redAccent
                                                : Colors.white,
                                        size: 22 * scale,
                                      ),
                                    ),
                              ),
                              // PiP
                              CupertinoButton(
                                padding: const EdgeInsets.all(8),
                                minSize: 0,
                                onPressed: _togglePiP,
                                child: Icon(
                                  Icons.picture_in_picture_alt_rounded,
                                  color: Colors.white,
                                  size: 21 * scale,
                                ),
                              ),
                              // Pantalla completa
                              CupertinoButton(
                                padding: const EdgeInsets.all(8),
                                minSize: 0,
                                onPressed: _toggleOrientation,
                                child: Icon(
                                  _isLandscape
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                  color: Colors.white,
                                  size: 24 * scale,
                                ),
                              ),
                            ],
                          ),
                          // Indicador de calidad de red
                          ValueListenableBuilder<NetworkQuality>(
                            valueListenable: _networkQuality.quality,
                            builder: (context, q, _) {
                              if (!_networkQuality.isMobileData.value ||
                                  q.index < NetworkQuality.fair.index) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      q == NetworkQuality.poor
                                          ? Icons.signal_cellular_0_bar
                                          : Icons.signal_cellular_alt_1_bar,
                                      size: 11 * scale,
                                      color:
                                          q == NetworkQuality.poor
                                              ? Colors.red
                                              : Colors.amber,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      q == NetworkQuality.poor
                                          ? 'Señal muy débil — modo de emergencia activo'
                                          : 'Señal débil — modo ahorro activo',
                                      style: TextStyle(
                                        color:
                                            q == NetworkQuality.poor
                                                ? Colors.red.shade300
                                                : Colors.amber.shade300,
                                        fontSize: 10 * scale,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                          if (_currentItem.isLive && !_isLandscape)
                            Padding(
                              padding: const EdgeInsets.only(left: 8, top: 6),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: _buildLiveBadge(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                  // Barra inferior
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        14 * scale,
                        0,
                        14 * scale,
                        18 * scale,
                      ),
                      child:
                          _currentItem.isLive
                              ? (_isLandscape
                                  ? Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(children: [_buildLiveBadge()]),
                                  )
                                  : const SizedBox.shrink())
                              : StreamBuilder<Duration>(
                                stream:
                                    _player?.stream.position
                                        .where((_) => !_isDragging)
                                        .map(
                                          (d) => Duration(seconds: d.inSeconds),
                                        )
                                        .distinct(),
                                initialData: _player?.state.position,
                                builder: (context, posSnap) {
                                  return StreamBuilder<Duration>(
                                    stream: _player?.stream.duration,
                                    initialData: _player?.state.duration,
                                    builder: (context, durSnap) {
                                      return ValueListenableBuilder<bool>(
                                        valueListenable:
                                            CastService().isCasting,
                                        builder: (context, isCasting, _) {
                                          return ValueListenableBuilder<
                                            Duration
                                          >(
                                            valueListenable:
                                                CastService().castPosition,
                                            builder: (context, castPos, _) {
                                              return ValueListenableBuilder<
                                                Duration
                                              >(
                                                valueListenable:
                                                    CastService().castDuration,
                                                builder: (context, castDur, _) {
                                                  final position =
                                                      isCasting
                                                          ? castPos
                                                          : (posSnap.data ??
                                                              Duration.zero);
                                                  final duration =
                                                      isCasting
                                                          ? castDur
                                                          : (durSnap.data ??
                                                              Duration.zero);
                                                  final maxMs =
                                                      duration.inMilliseconds
                                                          .toDouble();
                                                  final curMs =
                                                      _isDragging
                                                          ? _dragValue
                                                          : position
                                                              .inMilliseconds
                                                              .toDouble()
                                                              .clamp(
                                                                0.0,
                                                                maxMs > 0
                                                                    ? maxMs
                                                                    : 0.0,
                                                              );

                                                  return GestureDetector(
                                                    behavior:
                                                        HitTestBehavior.opaque,
                                                    onHorizontalDragUpdate:
                                                        (_) {},
                                                    child: Column(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        // Slider iOS
                                                        SliderTheme(
                                                          data: SliderThemeData(
                                                            trackHeight:
                                                                1.5 * scale,
                                                            activeTrackColor:
                                                                const Color(
                                                                  0xFFE50914,
                                                                ),
                                                            inactiveTrackColor:
                                                                Colors.white
                                                                    .withValues(
                                                                      alpha:
                                                                          0.28,
                                                                    ),
                                                            thumbColor:
                                                                const Color(
                                                                  0xFFE50914,
                                                                ),
                                                            thumbShape:
                                                                RoundSliderThumbShape(
                                                                  enabledThumbRadius:
                                                                      6 * scale,
                                                                ),
                                                            overlayShape:
                                                                RoundSliderOverlayShape(
                                                                  overlayRadius:
                                                                      16 *
                                                                      scale,
                                                                ),
                                                          ),
                                                          child: Slider(
                                                            min: 0,
                                                            max:
                                                                maxMs > 0
                                                                    ? maxMs
                                                                    : 1,
                                                            value: curMs,
                                                            onChangeStart:
                                                                (v) => setState(
                                                                  () {
                                                                    _isDragging =
                                                                        true;
                                                                    _dragValue =
                                                                        v;
                                                                  },
                                                                ),
                                                            onChanged:
                                                                (v) => setState(
                                                                  () =>
                                                                      _dragValue =
                                                                          v,
                                                                ),
                                                            onChangeEnd: (v) {
                                                              final cs =
                                                                  CastService();
                                                              if (cs
                                                                  .isCasting
                                                                  .value) {
                                                                cs.seek(
                                                                  v / 1000.0,
                                                                );
                                                              } else {
                                                                _player?.seek(
                                                                  Duration(
                                                                    milliseconds:
                                                                        v.toInt(),
                                                                  ),
                                                                );
                                                              }
                                                              setState(() {
                                                                _isDragging =
                                                                    false;
                                                                _isSeeking =
                                                                    true;
                                                              });
                                                              Future.delayed(
                                                                const Duration(
                                                                  milliseconds:
                                                                      1000,
                                                                ),
                                                                () {
                                                                  if (mounted &&
                                                                      _isSeeking) {
                                                                    setState(
                                                                      () =>
                                                                          _isSeeking =
                                                                              false,
                                                                    );
                                                                  }
                                                                },
                                                              );
                                                            },
                                                          ),
                                                        ),
                                                        // Tiempo + botones
                                                        Padding(
                                                          padding:
                                                              EdgeInsets.symmetric(
                                                                horizontal:
                                                                    6 * scale,
                                                              ),
                                                          child: Row(
                                                            children: [
                                                              Text(
                                                                WatchProgressService.formatDuration(
                                                                  Duration(
                                                                    milliseconds:
                                                                        curMs
                                                                            .toInt(),
                                                                  ),
                                                                ),
                                                                style: TextStyle(
                                                                  color:
                                                                      Colors
                                                                          .white,
                                                                  fontSize:
                                                                      13 *
                                                                      scale,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w400,
                                                                  letterSpacing:
                                                                      0.1,
                                                                ),
                                                              ),
                                                              const Spacer(),
                                                              if (_playlist
                                                                      .length >
                                                                  1) ...[
                                                                CupertinoButton(
                                                                  padding:
                                                                      EdgeInsets.all(
                                                                        6 * scale,
                                                                      ),
                                                                  minSize: 0,
                                                                  onPressed:
                                                                      _showEpisodeSelection,
                                                                  child: Icon(
                                                                    CupertinoIcons
                                                                        .list_bullet,
                                                                    color:
                                                                        Colors
                                                                            .white,
                                                                    size:
                                                                        20 *
                                                                        scale,
                                                                  ),
                                                                ),
                                                                SizedBox(
                                                                  width:
                                                                      4 * scale,
                                                                ),
                                                              ],
                                                              CupertinoButton(
                                                                padding:
                                                                    EdgeInsets.all(
                                                                      6 * scale,
                                                                    ),
                                                                minSize: 0,
                                                                onPressed:
                                                                    _showSettingsMenu,
                                                                child: Icon(
                                                                  CupertinoIcons
                                                                      .gear,
                                                                  color:
                                                                      Colors
                                                                          .white,
                                                                  size:
                                                                      20 *
                                                                      scale,
                                                                ),
                                                              ),
                                                              SizedBox(
                                                                width:
                                                                    6 * scale,
                                                              ),
                                                              Text(
                                                                WatchProgressService.formatDuration(
                                                                  duration,
                                                                ),
                                                                style: TextStyle(
                                                                  color:
                                                                      Colors
                                                                          .white70,
                                                                  fontSize:
                                                                      13 *
                                                                      scale,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w400,
                                                                  letterSpacing:
                                                                      0.1,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              );
                                            },
                                          );
                                        },
                                      );
                                    },
                                  );
                                },
                              ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _seekBackward({bool showControls = true}) {
    if (_player == null) return;
    _lastSeekTime = DateTime.now();
    final castService = CastService();
    setState(() {
      _isSeeking = true;
      _seekFeedbackForward = false;
      _seekFeedbackSeconds = 10;
    });
    if (castService.isCasting.value) {
      castService.seekBackward(seconds: 10);
    } else {
      final pos = _player!.state.position - const Duration(seconds: 10);
      _player!.seek(pos < Duration.zero ? Duration.zero : pos);
    }
    _startHideControlsTimer(showIfHidden: showControls);
    _resetSeekFeedback();
  }

  void _seekForward({bool showControls = true}) {
    if (_player == null) return;
    _lastSeekTime = DateTime.now();
    final castService = CastService();
    setState(() {
      _isSeeking = true;
      _seekFeedbackForward = true;
      _seekFeedbackSeconds = 10;
    });
    if (castService.isCasting.value) {
      castService.seekForward(seconds: 10);
    } else {
      final pos = _player!.state.position + const Duration(seconds: 10);
      final dur = _player!.state.duration;
      _player!.seek(pos > dur ? dur : pos);
    }
    _startHideControlsTimer(showIfHidden: showControls);
    _resetSeekFeedback();
  }

  void _resetSeekFeedback() {
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _seekFeedbackSeconds = null);
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted && _isSeeking) setState(() => _isSeeking = false);
    });
  }

  Widget _buildLiveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: Colors.white, size: 10),
          SizedBox(width: 6),
          Text(
            'EN VIVO',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoPlayOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Siguiente episodio en',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 10),
          Text(
            '$_nextEpisodeCountdown',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 48,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: _cancelAutoPlay,
                child: const Text(
                  'Cancelar',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              const SizedBox(width: 20),
              ElevatedButton(
                onPressed: _playNextEpisode,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
                child: const Text(
                  'Ver ahora',
                  style: TextStyle(color: Color(0xFF0a0a0a)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAdCountdownOverlay() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0a0a0a).withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline, color: Colors.yellow, size: 18),
          const SizedBox(width: 8),
          Text(
            'Anuncio en $_adCountdown...',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPiPUI() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: StreamBuilder<Duration>(
        stream: _player?.stream.position,
        builder: (context, snapshot) {
          final position = snapshot.data ?? Duration.zero;
          final duration = _player?.state.duration ?? Duration.zero;
          final max = duration.inMilliseconds.toDouble();
          final value = position.inMilliseconds.toDouble().clamp(0.0, max);

          if (max <= 0) return const SizedBox.shrink();

          return LinearProgressIndicator(
            value: value / max,
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.red),
            backgroundColor: Colors.white24,
            minHeight: 4,
          );
        },
      ),
    );
  }

  Widget _buildSeekFeedback() {
    final size = MediaQuery.of(context).size;
    final double shortestSide = size.shortestSide;
    final double scale = (shortestSide / 414.0).clamp(0.8, 1.25) * 1.02;

    final double centralIconSize = 64.0 * scale; // Simulando play para el hueco
    final double sideIconSize = centralIconSize * 0.85;
    final double horizontalGap = (_isLandscape ? 20.0 : 36.0) * scale;

    final double seekBtnWidth = sideIconSize + 16.0;
    final double playBtnWidth = centralIconSize + 16.0;

    return Align(
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Slot izquierdo — replay
          SizedBox(
            width: seekBtnWidth,
            child:
                !_seekFeedbackForward
                    ? Center(
                      child: _buildSeekFeedbackBubble(iconSize: sideIconSize),
                    )
                    : null,
          ),
          SizedBox(width: horizontalGap),
          // Slot central — play (vacío, solo ocupa espacio)
          SizedBox(width: playBtnWidth),
          SizedBox(width: horizontalGap),
          // Slot derecho — forward
          SizedBox(
            width: seekBtnWidth,
            child:
                _seekFeedbackForward
                    ? Center(
                      child: _buildSeekFeedbackBubble(iconSize: sideIconSize),
                    )
                    : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSeekFeedbackBubble({required double iconSize}) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('${_seekFeedbackForward}_$_seekFeedbackSeconds'),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutQuad,
      builder: (context, value, child) {
        // Rotación de ida y vuelta usando seno: 0 -> max -> 0
        final double maxRotation = 0.45; // ~25 grados
        final double rotation =
            math.sin(value * math.pi) *
            maxRotation *
            (_seekFeedbackForward ? 1 : -1);

        final double scale = 0.8 + (0.4 * math.sin(value * math.pi));
        final double opacity = (1.0 - value).clamp(0.0, 1.0);

        return Opacity(
          opacity: opacity,
          child: Transform.rotate(
            angle: rotation,
            child: Transform.scale(
              scale: scale,
              child: Image.asset(
                _seekFeedbackForward
                    ? 'assets/images/Avanzar.png'
                    : 'assets/images/Retroceder.png',
                color: const Color.fromARGB(255, 247, 247, 247),
                width: iconSize,
                height: iconSize,
              ),
            ),
          ),
        );
      },
    );
  }

  void _showVisualNotice(String message) {
    _noticeTimer?.cancel();
    setState(() {
      _noticeMessage = message;
    });
    _noticeAnimController.forward(from: 0.0);
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _noticeAnimController.reverse();
    });
  }

  void _onQualityChanged() {
    _onNetworkQualityChanged(_networkQuality.quality.value);
  }

  void _onNetworkQualityChanged(NetworkQuality newQuality) async {
    if (!mounted || _player == null || _isVideoLoading) return;
    if (_lastAppliedQuality == newQuality) return;

    final previous = _lastAppliedQuality;
    _lastAppliedQuality = newQuality;

    final mpv = _player?.platform as dynamic;
    if (mpv == null) return;

    // Solo ajustar parámetros MPV. NUNCA recargar el player desde aquí.
    await AdaptiveBufferService().applyConfig(
      mpv,
      newQuality,
      isLive: _isLiveContent,
    );

    // Notificar al usuario solo en cambios significativos
    if (_networkQuality.isMobileData.value && previous != null) {
      final wasGood = previous.index <= NetworkQuality.good.index;
      final isNowBad = newQuality.index >= NetworkQuality.fair.index;
      final isNowGood = newQuality.index <= NetworkQuality.good.index;

      if (wasGood && isNowBad) {
        _showAdaptiveQualityNotice(degraded: true, quality: newQuality);
      } else if (!wasGood && isNowGood) {
        _showAdaptiveQualityNotice(degraded: false, quality: newQuality);
      }
    }
  }

  void _showAdaptiveQualityNotice({
    required bool degraded,
    required NetworkQuality quality,
  }) {
    if (!mounted) return;
    final mbps = _networkQuality.estimatedBandwidthMbps.value;
    final label =
        mbps < 1.0
            ? '${(mbps * 1000).toInt()} Kbps'
            : '${mbps.toStringAsFixed(1)} Mbps';

    if (degraded) {
      _showVisualNotice(
        'Red débil ($label) — reduciendo calidad para evitar cortes',
      );
    } else {
      _showVisualNotice('Conexión mejorada ($label) — restaurando calidad');
    }
  }

  void _showVisualBottomSheet({
    required Widget Function(BuildContext) builder,
  }) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'VisualBottomSheet',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return Align(
          alignment: _isLandscape ? Alignment.center : Alignment.bottomCenter,
          child: RotatedBox(
            quarterTurns: _isLandscape ? 1 : 0,
            child: Material(color: Colors.transparent, child: builder(context)),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        if (_isLandscape) {
          return FadeTransition(
            opacity: anim1,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic),
              ),
              child: child,
            ),
          );
        }

        final begin = const Offset(0.0, 1.0);
        return SlideTransition(
          position: Tween<Offset>(
            begin: begin,
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
    );
  }

  Widget _buildSubtitleOverlay() {
    final activeLines =
        _currentSubtitleText.where((l) => l.trim().isNotEmpty).toList();

    if (activeLines.isEmpty) return const SizedBox.shrink();

    final size = MediaQuery.of(context).size;
    final double shortestSide = size.shortestSide;
    final double scale = (shortestSide / 414.0).clamp(0.75, 1.15);

    return Positioned(
      bottom: (_showControls ? 100 : 35) * scale,
      left: 40 * scale,
      right: 40 * scale,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children:
              activeLines.map((line) {
                return Container(
                  margin: EdgeInsets.only(bottom: 4 * scale),
                  padding: EdgeInsets.symmetric(
                    horizontal: 12 * scale,
                    vertical: 6 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: const Color.fromARGB(139, 0, 0, 0),
                  ),
                  child: Text(
                    line.trim(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: const Color.fromARGB(255, 211, 211, 211),
                      fontSize: 15.1 * scale,
                      height: 1.1,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.1,

                      shadows: const [], // Eliminada la sombra según petición
                    ),
                  ),
                );
              }).toList(),
        ),
      ),
    );
  }

  Widget _buildVisualNotice() {
    final size = MediaQuery.of(context).size;
    final double scale = (size.shortestSide / 414.0).clamp(0.8, 1.25) * 1.02;

    return Positioned(
      bottom: 70 * scale,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _noticeAnim,
          child: Center(
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 24 * scale,
                vertical: 10 * scale,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF262626).withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(25 * scale),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 10 * scale,
                    offset: Offset(0, 4 * scale),
                  ),
                ],
              ),
              child: Text(
                _noticeMessage ?? '',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13 * scale,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Widget StatefulWidget para buscar y listar dispositivos Chromecast.
class _CastDeviceSelector extends StatefulWidget {
  final bool isLandscape;
  final void Function(CastDevice device) onDeviceSelected;

  const _CastDeviceSelector({
    required this.isLandscape,
    required this.onDeviceSelected,
  });

  @override
  State<_CastDeviceSelector> createState() => _CastDeviceSelectorState();
}

class _CastDeviceSelectorState extends State<_CastDeviceSelector> {
  List<CastDevice>? _devices;
  bool _isSearching = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchDevices();
  }

  Future<void> _searchDevices() async {
    setState(() {
      _isSearching = true;
      _error = null;
      _devices = null;
    });

    try {
      final devices = await CastService().discoverDevices(
        timeout: const Duration(seconds: 6),
      );
      if (mounted) {
        setState(() {
          _devices = devices;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error al buscar dispositivos';
          _isSearching = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.isLandscape ? 420 : double.infinity,
      margin: widget.isLandscape ? const EdgeInsets.all(24) : EdgeInsets.zero,
      constraints: BoxConstraints(
        maxHeight:
            widget.isLandscape
                ? MediaQuery.of(context).size.width * 0.85
                : MediaQuery.of(context).size.height * 0.55,
      ),
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 27, 27, 27),
        borderRadius:
            widget.isLandscape
                ? BorderRadius.circular(24)
                : const BorderRadius.vertical(top: Radius.circular(20)),
        border:
            widget.isLandscape
                ? Border.all(color: Colors.white12, width: 1)
                : null,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cast_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Transmitir a TV',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_isSearching)
                        IconButton(
                          onPressed: _searchDevices,
                          icon: const Icon(
                            Icons.refresh_rounded,
                            color: Colors.white70,
                          ),
                          tooltip: 'Buscar de nuevo',
                        ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white10, height: 1),
            if (_isSearching)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.redAccent.withValues(alpha: 0.8),
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Buscando dispositivos...',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Asegúrate de estar en la misma red Wi-Fi',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 40,
                  horizontal: 24,
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.wifi_off_rounded,
                      color: Colors.red.withValues(alpha: 0.6),
                      size: 40,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Reintentar'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                      onPressed: _searchDevices,
                    ),
                  ],
                ),
              )
            else if (_devices != null && _devices!.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 40,
                  horizontal: 24,
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.tv_off_rounded,
                      color: Colors.white.withValues(alpha: 0.4),
                      size: 40,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'No se encontraron dispositivos',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Verifica que tu TV/Chromecast esté encendido\ny conectado a la misma red Wi-Fi.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Buscar de nuevo'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                      onPressed: _searchDevices,
                    ),
                  ],
                ),
              )
            else if (_devices != null)
              Flexible(
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: _devices!.length,
                  itemBuilder: (context, index) {
                    final device = _devices![index];
                    return ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.tv_rounded,
                          color: Colors.redAccent,
                          size: 22,
                        ),
                      ),
                      title: Text(
                        device.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        device.host,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 12,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right,
                        color: Colors.white38,
                      ),
                      onTap: () => widget.onDeviceSelected(device),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

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

class _PremiumPlayPauseIcon extends StatefulWidget {
  final bool isPlaying;
  final double size;

  const _PremiumPlayPauseIcon({required this.isPlaying, required this.size});

  @override
  _PremiumPlayPauseIconState createState() => _PremiumPlayPauseIconState();
}

class _PremiumPlayPauseIconState extends State<_PremiumPlayPauseIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: widget.isPlaying ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(_PremiumPlayPauseIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedIcon(
      icon: AnimatedIcons.play_pause,
      progress: CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOutCubic,
      ),
      color: Colors.white,
      size: widget.size,
    );
  }
}
