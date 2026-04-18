import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/m3u_item.dart';
import '../utils/normalization_utils.dart';
import '../services/m3u_service.dart';
import '../services/watch_progress_service.dart';
import '../services/ad_service.dart';
import 'package:flutter/foundation.dart';
import '../services/premium_service.dart';
import '../services/game_config_service.dart';
import '../services/fast_image_service.dart';
import '../services/dynamic_scraper_service.dart';
import '../services/performance_service.dart';

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
  bool _showControls = true;
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
  double _dragValue = 0.0;
  Timer? _hideControlsTimer;

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

  // Like/Dislike prompt state
  bool _showLikePrompt = false;
  bool _likePromptDismissed = false;
  bool? _isLikedLocal; // null = no voted, true = liked, false = disliked

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentItem = widget.item;
    _playlist = widget.playlist;

    _swipeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );

    _controlsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 1.0,
    );
    _controlsAnim = CurvedAnimation(
      parent: _controlsAnimController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
    _startPlaybackFlow();
  }

  bool _wasPlayingBeforeAd = false;

  void _handleAdStateChange() {
    if (AdService.isAdInProgress.value) {
      if (_player != null && _player!.state.playing) {
        _wasPlayingBeforeAd = true;
        _player!.pause();
        if (mounted) setState(() => _showControls = true);
      }
    } else {
      if (_wasPlayingBeforeAd && _player != null) {
        _wasPlayingBeforeAd = false;
        _player!.play();
      }
    }
  }

  @override
  void dispose() {
    // -- CRITICAL DISPOSAL SEQUENCE FOR MOTOROLA/ANDROID 15 --
    // Order matters: cancel Dart-side listeners FIRST so no new events are
    // processed after we start tearing down the native engine.

    // 1. Cancel all timers and Dart stream subscriptions immediately.
    _hideControlsTimer?.cancel();
    _stallTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _countdownTimer?.cancel();
    _progressSaveTimer?.cancel();
    for (final s in _streamSubscriptions) {
      s.cancel();
    }
    _streamSubscriptions.clear();

    AdService.isAdInProgress.removeListener(_handleAdStateChange);

    final pToStop = _player;

    // 2. Silence the native MPV engine and KILL video output IMMEDIATELY.
    // Setting 'vid' to 'no' and 'vo' to 'null' forces mpv to release the
    // Android Surface/BufferQueue BEFORE we call stop or dispose.
    try {
      final mpv = pToStop?.platform as dynamic;
      mpv?.setProperty('msg-level', 'all=no');
      mpv?.setProperty('log-level', 'no');
      mpv?.setProperty('vid', 'no');
      mpv?.setProperty('vo', 'null');
    } catch (_) {}

    // 3. Stop the demuxer.
    pToStop?.stop();

    // 4. Unmount the Video widget from the Flutter tree.
    _videoControllerNotifier.value = null;

    // 5. Null our reference immediately so any in-flight microtasks that check
    //    _player find it gone.
    _player = null;

    // 6. Give the native thread time to drain its event queue before the FFI
    //    trampoline is destroyed. 800ms is the safety threshold for Moto/A15.
    Future.delayed(const Duration(milliseconds: 800), () {
      pToStop?.dispose();
    });

    // 7. Dispose animation/value notifiers.
    _swipeAnimController.dispose();
    _controlsAnimController.dispose();
    _videoFitNotifier.dispose();
    _videoControllerNotifier.dispose();
    _bufferedDuration.dispose();

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WakelockPlus.disable();

    if (_isPiPSupported) {
      platform.setMethodCallHandler(null);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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

  Future<void> _startPlaybackFlow() async {
    AdService().showRewardedAdWithConfirmation(
      context,
      onUserEarnedReward: () async {
        if (!mounted) return;
        _retryCount = 0;
        _hasError = false;

        final progress = await _watchProgressService.getProgress(
          _currentItem.url,
        );
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
      },
      onAdFailed: () {
        if (mounted) {
          SnackBarUtils.showAppSnackBar(
            context,
            'Lo sentimos, no pudimos cargar este título. (Código: 5003)',
          );
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted) Navigator.pop(context);
          });
        }
      },
      onCancel: () {
        if (mounted) Navigator.pop(context);
      },
      message: 'Para iniciar la reproducción, mira un anuncio.',
    );
  }

  Future<void> _cleanupPlayer() async {
    // 1. Cancel Dart-side subscriptions and timers first.
    for (final s in _streamSubscriptions) {
      s.cancel();
    }
    _streamSubscriptions.clear();
    _progressSaveTimer?.cancel();
    _hideControlsTimer?.cancel();
    _stallTimer?.cancel();

    final p = _player;

    // 2. Silence MPV and detach video output immediately.
    try {
      final mpv = p?.platform as dynamic;
      mpv?.setProperty('msg-level', 'all=no');
      mpv?.setProperty('log-level', 'no');
      mpv?.setProperty('vid', 'no');
      mpv?.setProperty('vo', 'null');
    } catch (_) {}

    // 3. Unmount the Video widget from Flutter tree.
    _videoControllerNotifier.value = null;

    // 4. Null our reference so microtasks see it as gone.
    _player = null;

    // 5. Drain native event queue before creating the next player.
    await Future.delayed(const Duration(milliseconds: 500));

    // 6. Dispose the old player.
    if (p != null) {
      try {
        await p.dispose();
      } catch (e) {
        debugPrint('Error disposing player in _cleanupPlayer: $e');
      }
    }
  }

  String _videoKey = '';
  Future<void> _initializePlayer(M3UItem item, {Duration? startFrom}) async {
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
      final isPrewarmed =
          widget.prewarmedPlayer != null &&
          widget.prewarmedPlayer!.platform != null &&
          _retryCount == 0;

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
        _showLikePrompt = false;
        _likePromptDismissed = false;
        _isLikedLocal = null;

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
            libass: false,
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

      final currentController = VideoController(
        currentPlayer,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: true,
        ),
      );

      _player = currentPlayer;
      _videoControllerNotifier.value = null;
      Future.microtask(() {
        if (mounted) _videoControllerNotifier.value = currentController;
      });

      _setupStreamMonitor();
      _startStallMonitor();

      Future.microtask(() async {
        try {
          final activePlayer = _player;
          if (activePlayer == null) return;
          final mpv = activePlayer.platform as dynamic;
          if (mpv == null) return;

          await mpv.setProperty('cache', 'yes');
          await mpv.setProperty('cache-pause', 'no');
          await mpv.setProperty('cache-on-disk', 'no');

          if (_isLiveContent) {
            await mpv.setProperty('cache-secs', '120');
            await mpv.setProperty('demuxer-max-bytes', '536870912');
            await mpv.setProperty('cache-back-buffer-size', '134217728');
            await mpv.setProperty('hls-bitrate', 'max');
            await mpv.setProperty('hls-forward-cache-secs', '60');
            await mpv.setProperty('hls-back-cache-secs', '30');
            await mpv.setProperty('demuxer-lavf-hacks', 'yes');
            await mpv.setProperty('demuxer-cache-wait', 'no');
            await mpv.setProperty(
              'demuxer-lavf-o',
              'protocol_whitelist=file,http,https,tcp,tls,crypto,hls,data',
            );
          } else {
            await mpv.setProperty('cache-secs', '240');
            await mpv.setProperty('demuxer-max-bytes', '536870912');
            await mpv.setProperty('demuxer-max-back-bytes', '134217728');
            await mpv.setProperty('demuxer-readahead-secs', '120');
            await mpv.setProperty('cache-pause-initial', 'yes');
            await mpv.setProperty('cache-pause-wait', '5');
            await mpv.setProperty('stream-buffer-size', '16777216');
            await mpv.setProperty('network-timeout', '40');
          }

          await mpv.setProperty('http-reconnect', 'yes');
          await mpv.setProperty('http-reconnect-sleep', '1');
          await mpv.setProperty('user-agent', 'VLC/3.0.20 LibVLC/3.0.20');

          // Force mediacodec-copy for Android to ensure stability on Motorola/Android 15
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
            await mpv.setProperty('hwdec', 'mediacodec-copy');
          } else {
            await mpv.setProperty('hwdec', 'auto-safe');
          }

          await mpv.setProperty('vd-lavc-threads', '0');
          await mpv.setProperty('vd-lavc-skiploopfilter', 'nonref');
          await mpv.setProperty('framedrop', 'decoder+vo');
          await mpv.setProperty('vd-lavc-o', 'err_detect=ignore_err');
          await mpv.setProperty('audio-buffer', '0.5');
          await mpv.setProperty('audio-stream-silence', 'yes');
          await mpv.setProperty('audio-fallback-to-null', 'yes');

          // Motorola specifics
          if (PerformanceService().isLowPerformance ||
              PerformanceService().allowVideoPrewarm == false) {
            // Force surface release and avoid tunneled playback
            await mpv.setProperty('vd-lavc-dr', 'no');
            await mpv.setProperty('hwdec', 'mediacodec-copy');
          }

          if (GameConfigService().volumeNormalize) {
            await mpv.setProperty('af', 'dynaudnorm');
          }
        } catch (e) {
          debugPrint('Error configurando MPV: $e');
        }
      });

      final currentUrl = _serverUrls[_currentServerIndex % _serverUrls.length];
      if (!isPrewarmed) {
        await _player!.open(
          Media(currentUrl, httpHeaders: _buildHeaders(currentUrl)),
          play: true,
        );
      } else {
        _player!.play();
      }

      if (startFrom != null && startFrom.inSeconds > 0) {
        int attempts = 0;
        while (attempts < 60 && mounted && _player != null) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (_player!.state.duration.inSeconds > 0) break;
          attempts++;
        }

        if (mounted && _player != null) {
          await _player!.seek(startFrom);
          for (int i = 0; i < 5; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (!mounted || _player == null) break;
            final diff =
                (_player!.state.position.inSeconds - startFrom.inSeconds).abs();
            if (diff < 10) break;
            await _player!.seek(startFrom);
          }
        }
      }

      int frameWait = 0;
      while (frameWait < 200 && mounted && _player != null) {
        final state = _player!.state;
        final hasVideo = (state.width ?? 0) > 0 && (state.height ?? 0) > 0;
        final isPlayingAndAdvanced =
            state.playing && state.position.inMilliseconds > 200;
        final hasBuffer = _isLiveContent || state.buffer.inSeconds >= 2;

        if (hasVideo && isPlayingAndAdvanced && hasBuffer) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
        frameWait++;
      }

      if (mounted) {
        setState(() => _isVideoLoading = false);
        _startHideControlsTimer();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isVideoLoading = false);
        SnackBarUtils.showAppSnackBar(context, 'Error al reproducir: $e');
      }
    }
  }

  void _setupStreamMonitor() {
    for (final s in _streamSubscriptions) {
      s.cancel();
    }
    _streamSubscriptions.clear();
    // Buffering stream to show/hide loading spinner
    _streamSubscriptions.add(
      _player!.stream.buffering.listen((buffering) {
        if (mounted && _isBuffering != buffering) {
          setState(() => _isBuffering = buffering);
        }
      }),
    );

    // Guardar progreso cada 5 segundos
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_player != null && mounted) {
        final position = _player!.state.position;
        final duration = _player!.state.duration;
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
      }
    });

    // Reload en error de red
    _streamSubscriptions.add(
      _player!.stream.error.listen((error) {
        if (mounted && !_isVideoLoading) {
          debugPrint('Error de stream: $error. Recargando en 1s...');
          Future.delayed(const Duration(seconds: 1), () {
            if (mounted) _reloadVideo();
          });
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
          if (_currentItem.isLive) {
            Future.delayed(const Duration(seconds: 1), () {
              if (mounted) _reloadVideo();
            });
          } else {
            _handleVideoCompletion();
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
          // Aumentamos el umbral para que aparezca mucho antes (7.5 minutos para películas largas, 2 minutos para cortas)
          final threshold = duration.inSeconds > 600 ? 450 : 120;

          if (duration.inSeconds > threshold + 30) {
            final remaining = duration - position;
            if (remaining.inSeconds <= threshold && remaining.inSeconds > 0) {
              if (_playlist.isNotEmpty && _currentItem.isSeries) {
                // Para series mantenemos el comportamiento original si es necesario,
                // pero si el usuario quiere "mucho antes" para todo, podemos usar el mismo threshold.
                _handleVideoCompletion();
              } else if (!_currentItem.isLive &&
                  !_showLikePrompt &&
                  !_likePromptDismissed) {
                setState(() => _showLikePrompt = true);
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

          if (!PremiumService().isPremium &&
              position.inSeconds >= midRollPosition - 40 &&
              position.inSeconds < midRollPosition &&
              !_midRollAdShown) {
            final remaining = midRollPosition - position.inSeconds;
            if (_adCountdown != remaining) {
              setState(() => _adCountdown = remaining);
            }
          } else if (_adCountdown != null) {
            setState(() => _adCountdown = null);
          }

          if (position.inSeconds >= midRollPosition &&
              !_midRollAdShown &&
              !PremiumService().isPremium) {
            if (position.inSeconds <= midRollPosition + 30) {
              _midRollAdShown = true;
              setState(() => _adCountdown = null);
              _triggerMidRollAd();
            } else {
              _midRollAdShown = true;
              setState(() => _adCountdown = null);
            }
          }
        }
      }),
    );
  }

  void _handleVideoCompletion() async {
    if (_player != null) {
      final duration = _player!.state.duration;
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
    }

    if (_playlist.isEmpty) return;

    final currentIndex = _playlist.indexWhere((i) => i.url == _currentItem.url);
    if (currentIndex == -1 || currentIndex >= _playlist.length - 1) return;

    setState(() => _nextEpisodeCountdown = 5);

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        if (_nextEpisodeCountdown! > 1) {
          _nextEpisodeCountdown = _nextEpisodeCountdown! - 1;
        } else {
          timer.cancel();
          _nextEpisodeCountdown = null;
          _playNextEpisode();
        }
      });
    });
  }

  void _playNextEpisode() {
    _countdownTimer?.cancel();
    if (_playlist.isEmpty) return;

    final currentIndex = _playlist.indexWhere((i) => i.url == _currentItem.url);
    if (currentIndex != -1 && currentIndex < _playlist.length - 1) {
      final nextItem = _playlist[currentIndex + 1];
      setState(() {
        _currentItem = nextItem;
        _midRollAdShown = false;
        _midRollNoticeShown = false;
        _nextEpisodeCountdown = null;
        _serverUrls = []; // Reset for next item
        _currentServerIndex = 0;
      });
      _initializePlayer(nextItem);
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
      SnackBarUtils.showAppSnackBar(context, 'Anuncio en 2 minutos...');
    }
  }

  void _startStallMonitor() {
    _stallTimer?.cancel();
    _stallSeconds = 0;

    _stallTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _player == null) return;

      final playerState = _player!.state;

      _bufferedDuration.value = playerState.buffer;

      // ── Detección de stall con umbrales generosos ─────────────
      if (playerState.buffering) {
        _stallSeconds++;

        // VOD: 15s (antes 45s, demasiado lento)
        // Live: 10s (streams en vivo deben recargar rápido)
        final int threshold = _isLiveContent ? 10 : 15;

        if (_stallSeconds >= threshold && !_isVideoLoading) {
          debugPrint('Stall persistente (${_stallSeconds}s). Recargando...');
          _stallSeconds = 0;
          _reloadVideo();
        }
      } else {
        if (_stallSeconds > 5) {
          debugPrint('Buffer recuperado tras $_stallSeconds s.');
        }
        _stallSeconds = 0;
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
    if (!mounted || _isVideoLoading || _player == null) return;

    // Rotar User-Agent en cada intento
    _userAgentIndex++;

    if (!_isLiveContent) {
      if (_retryCount < 2) {
        _retryCount++;
        debugPrint('VOD retry #$_retryCount UA: $_currentUserAgent');
        final pos = _player!.state.position;
        try {
          final currentUrl =
              _serverUrls[_currentServerIndex % _serverUrls.length];
          await _player!.open(
            Media(currentUrl, httpHeaders: _buildHeaders(currentUrl)),
            play: true,
          );
          if (pos.inSeconds > 5) {
            await Future.delayed(const Duration(milliseconds: 800));
            if (mounted && _player != null) await _player!.seek(pos);
          }
        } catch (_) {
          _retryCount = 2;
          _reloadVideo();
        }
      } else if (_currentServerIndex < _serverUrls.length - 1) {
        // Option exhausted for this server, try next alternative
        _retryCount = 0;
        _currentServerIndex++;
        debugPrint(
          'Primary server failed. Trying alternative server #$_currentServerIndex',
        );
        final pos = _player!.state.position;
        if (mounted) {
          SnackBarUtils.showAppSnackBar(
            context,
            'Intentando con servidor alternativo...',
          );
        }
        await _initializePlayer(
          _currentItem,
          startFrom: pos.inSeconds > 5 ? pos : null,
        );
      } else {
        setState(() => _hasError = true);
      }
    } else {
      const backoffDelays = [2, 4, 8, 12, 20, 30];
      final delay = backoffDelays[_retryCount < 6 ? _retryCount : 5];
      _retryCount++;
      setState(() => _isVideoLoading = true);
      await Future.delayed(Duration(seconds: delay));
      if (mounted) _initializePlayer(_currentItem);
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
                color: Colors.red.withOpacity(0.8),
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
                    'Es posible que el servidor esté caído. Inténtalo más tarde.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 16,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
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
      onUserEarnedReward: () {
        if (mounted && _player != null) _player!.play();
      },
      onAdFailed: () {
        if (mounted) {
          SnackBarUtils.showAppSnackBar(
            context,
            'Error al cargar el anuncio. (Código: 1004)',
          );
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted) Navigator.pop(context);
          });
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
                                    color: Colors.red.withOpacity(0.2),
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
                                color: Colors.white.withOpacity(0.7),
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
                                color: Colors.white.withOpacity(0.1),
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

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
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
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux) {
      if (_isLandscape) {
        await defaultExitNativeFullscreen();
        setState(() => _isLandscape = false);
      } else {
        await defaultEnterNativeFullscreen();
        setState(() => _isLandscape = true);
      }
      return;
    }

    setState(() => _isLandscape = !_isLandscape);
    if (_isLandscape) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  void _handleMainTap() {
    _toggleControls();
  }

  void _togglePlayback() {
    final activePlayer = _player;
    if (activePlayer == null) return;
    if (activePlayer.state.playing) {
      activePlayer.pause();
      setState(() => _showControls = true);
      _hideControlsTimer?.cancel();
      if (_isPiPSupported) {
        platform.invokeMethod('updatePiPState', {'playing': false});
      }
    } else {
      activePlayer.play();
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

  void _showSubtitleSelection() {
    if (_player == null) return;
    final tracks = _player!.state.tracks.subtitle;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (context) => Container(
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 27, 27, 27),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Subtítulos',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(color: Colors.white24, height: 1),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ...tracks.map((track) {
                        final isSelected =
                            _player!.state.track.subtitle == track;
                        return ListTile(
                          leading: Icon(
                            Icons.subtitles,
                            color: isSelected ? Colors.red : Colors.white70,
                          ),
                          title: Text(
                            track.title ??
                                track.language ??
                                'Pista ${tracks.indexOf(track)}',
                            style: TextStyle(
                              color: isSelected ? Colors.red : Colors.white,
                            ),
                          ),
                          trailing:
                              isSelected
                                  ? const Icon(Icons.check, color: Colors.red)
                                  : null,
                          onTap: () {
                            _player!.setSubtitleTrack(track);
                            Navigator.pop(context);
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

  void _showAudioSelection() {
    if (_player == null) return;
    final tracks = _player!.state.tracks.audio;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (context) => Container(
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 27, 27, 27),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Audio / Idioma',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(color: Colors.white24, height: 1),
                Flexible(
                  child: ListView.builder(
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

  void _showEpisodeSelection() {
    if (_playlist.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder:
          (context) => Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 27, 27, 27),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Capítulos',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(color: Colors.white24, height: 1),
                Flexible(
                  child: ListView.builder(
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
                        title: Text(
                          episode.name,
                          style: TextStyle(
                            color: isCurrentEpisode ? Colors.red : Colors.white,
                            fontWeight:
                                isCurrentEpisode
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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

  void _changeToEpisode(M3UItem newEpisode) {
    AdService().showRewardedAd(
      onUserEarnedReward: () {
        if (!mounted) return;
        setState(() {
          _currentItem = newEpisode;
          _midRollAdShown = false;
          _midRollNoticeShown = false;
          _autoPlayCancelled = false;
        });
        _initializePlayer(newEpisode);
      },
      onAdFailed: () {
        if (mounted) {
          SnackBarUtils.showAppSnackBar(
            context,
            'Error al cargar el anuncio. Inténtalo de nuevo.',
          );
        }
      },
    );
  }

  void _showSpeedSelection() {
    if (_player == null) return;

    final speeds = [1.0, 1.25, 1.5, 2.0];
    final isPremium = PremiumService().isPremium;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder:
          (context) => Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 27, 27, 27),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              border: const Border(
                top: BorderSide(color: Colors.white10, width: 1),
              ),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Velocidad de reproducción',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
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
        SnackBarUtils.showAppSnackBar(
          context,
          'No compatible con este título o dispositivo',
        );
      }
    }
  }

  void _showPremiumRequirement(String message) {
    if (!mounted) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.hideCurrentSnackBar();
    scaffoldMessenger.showSnackBar(
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
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            if (_player != null) {
              final position = _player!.state.position;
              final duration = _player!.state.duration;
              if (duration.inSeconds > 0) {
                await _watchProgressService.saveProgress(
                  _currentItem.url,
                  position,
                  duration,
                );
              }
            }
            if (mounted) Navigator.pop(context);
          },
          child: Scaffold(
            backgroundColor: Colors.black,
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
                  final screenWidth = MediaQuery.of(context).size.width;
                  if (details.localPosition.dx < screenWidth / 3) {
                    setState(() {
                      _seekFeedbackForward = false;
                      _seekFeedbackSeconds = 10;
                    });
                    _seekBackward();
                  } else if (details.localPosition.dx > screenWidth * 2 / 3) {
                    setState(() {
                      _seekFeedbackForward = true;
                      _seekFeedbackSeconds = 10;
                    });
                    _seekForward();
                  } else {
                    _videoFitNotifier.value =
                        _videoFitNotifier.value == BoxFit.cover
                            ? BoxFit.contain
                            : BoxFit.cover;
                    SnackBarUtils.showAppSnackBar(
                      context,
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
                    SnackBarUtils.showAppSnackBar(
                      context,
                      'Se ajustó el contenido a la pantalla',
                    );
                  } else if (details.scale < 0.9 &&
                      _videoFitNotifier.value != BoxFit.contain) {
                    _videoFitNotifier.value = BoxFit.contain;
                    SnackBarUtils.showAppSnackBar(context, 'Original');
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
                    final progress = (offset.abs() / 160.0).clamp(0.0, 1.0);
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
                              ValueListenableBuilder<VideoController?>(
                                valueListenable: _videoControllerNotifier,
                                builder: (context, controller, _) {
                                  if (controller == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return ValueListenableBuilder<BoxFit>(
                                    valueListenable: _videoFitNotifier,
                                    builder: (context, fit, child) {
                                      if (fit == BoxFit.cover) {
                                        return LayoutBuilder(
                                          builder: (context, constraints) {
                                            final videoController = controller;
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
                                            if (aspectRatio > screenAspect) {
                                              scale =
                                                  constraints.maxHeight *
                                                  aspectRatio /
                                                  constraints.maxWidth;
                                            } else {
                                              scale =
                                                  constraints.maxWidth /
                                                  (constraints.maxHeight *
                                                      aspectRatio);
                                            }
                                            return Transform.scale(
                                              scale: scale.clamp(1.0, 3.0),
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
                              ),
                              if (_isVideoLoading || _isBuffering)
                                _buildVideoLoading(
                                  showBackground: _isVideoLoading,
                                )
                              else
                                ValueListenableBuilder<VideoController?>(
                                  valueListenable: _videoControllerNotifier,
                                  builder: (context, controller, _) {
                                    if (controller == null) {
                                      return const SizedBox.shrink();
                                    }
                                    return StreamBuilder<bool>(
                                      stream:
                                          controller.player.stream.buffering,
                                      builder: (context, snapshot) {
                                        final isExhausted =
                                            _bufferedDuration
                                                .value
                                                .inMilliseconds <
                                            500;
                                        final isBuffering =
                                            snapshot.data == true;
                                        if (((isBuffering &&
                                                    (isExhausted ||
                                                        _isDragging)) ||
                                                _isSeeking) &&
                                            _seekFeedbackSeconds == null) {
                                          return _buildVideoLoading(
                                            showBackground: false,
                                          );
                                        }
                                        return const SizedBox.shrink();
                                      },
                                    );
                                  },
                                ),
                            ],
                          ),
                        ),

                        if (_nextEpisodeCountdown != null)
                          Positioned.fill(child: _buildAutoPlayOverlay()),

                        if (_showLikePrompt)
                          Positioned.fill(child: _buildLikePromptOverlay()),

                        if (_adCountdown != null)
                          Positioned(
                            top: 60,
                            right: 24,
                            child: _buildAdCountdownOverlay(),
                          ),

                        if (isPiP) _buildPiPUI(),

                        if (_seekFeedbackSeconds != null && !_showControls)
                          _buildSeekFeedback(),

                        if (_showControls &&
                            !_isVideoLoading &&
                            !(MediaQuery.of(context).size.height < 300))
                          _buildControls(),

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
        const Center(child: _AppLoadingAnimation()),
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
              "Obteniendo enlace real...",
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

  Widget _buildControls() {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _controlsAnim,
        builder:
            (context, child) =>
                Opacity(opacity: _controlsAnim.value, child: child),
        child: Container(
          color: Colors.black.withOpacity(0.3),
          child: SafeArea(
            child: Stack(
              children: [
                Align(
                  alignment: const Alignment(0, -0.05),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!_currentItem.isLive) ...[
                        IconButton(
                          iconSize: 42,
                          icon: const Icon(
                            Icons.replay_10,
                            color: Colors.white,
                          ),
                          onPressed: _seekBackward,
                        ),
                        const SizedBox(width: 40),
                      ],
                      StreamBuilder<bool>(
                        stream: _player?.stream.playing,
                        initialData: _player?.state.playing,
                        builder: (context, snapshot) {
                          final isPlaying = snapshot.data ?? false;
                          return IconButton(
                            iconSize: 64,
                            icon: Icon(
                              isPlaying
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_fill,
                              color: Colors.white,
                            ),
                            onPressed: _togglePlayback,
                          );
                        },
                      ),
                      if (!_currentItem.isLive) ...[
                        const SizedBox(width: 40),
                        IconButton(
                          iconSize: 42,
                          icon: const Icon(
                            Icons.forward_10,
                            color: Colors.white,
                          ),
                          onPressed: _seekForward,
                        ),
                      ],
                    ],
                  ),
                ),

                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.arrow_back_ios_new,
                                color: Colors.white,
                              ),
                              onPressed: () async {
                                if (_player != null && !_isVideoLoading) {
                                  final position = _player!.state.position;
                                  final duration = _player!.state.duration;
                                  if (duration.inSeconds > 0) {
                                    await _watchProgressService.saveProgress(
                                      _currentItem.url,
                                      position,
                                      duration,
                                      name: _currentItem.name,
                                      seriesName: _currentItem.seriesName,
                                      seasonNumber: _currentItem.seasonNumber,
                                      episodeNumber: _currentItem.episodeNumber,
                                    );
                                  }
                                }
                                if (mounted) Navigator.maybePop(context);
                              },
                            ),
                            Expanded(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Flexible(
                                    child: Text(
                                      _currentItem.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!_currentItem.isLive)
                              IconButton(
                                icon: const Icon(
                                  Icons.speed_rounded,
                                  color: Colors.white,
                                ),
                                onPressed: _showSpeedSelection,
                              ),
                            IconButton(
                              icon: const Icon(
                                Icons.picture_in_picture_alt_rounded,
                                color: Colors.white,
                              ),
                              onPressed: _togglePiP,
                            ),
                            IconButton(
                              iconSize: 24,
                              icon: Icon(
                                _isLandscape
                                    ? Icons.fullscreen_exit_rounded
                                    : Icons.fullscreen_rounded,
                                color: Colors.white,
                              ),
                              onPressed: _toggleOrientation,
                            ),
                          ],
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

                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child:
                        _currentItem.isLive
                            ? (_isLandscape
                                ? Container(
                                  padding: const EdgeInsets.only(
                                    bottom: 20,
                                    left: 8,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.start,
                                    children: [_buildLiveBadge()],
                                  ),
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
                              builder: (context, positionSnapshot) {
                                return StreamBuilder<Duration>(
                                  stream: _player?.stream.duration,
                                  initialData: _player?.state.duration,
                                  builder: (context, durationSnapshot) {
                                    final position =
                                        positionSnapshot.data ?? Duration.zero;
                                    final duration =
                                        durationSnapshot.data ?? Duration.zero;
                                    final max =
                                        duration.inMilliseconds.toDouble();
                                    final value =
                                        _isDragging
                                            ? _dragValue
                                            : position.inMilliseconds
                                                .toDouble()
                                                .clamp(
                                                  0.0,
                                                  max > 0 ? max : 0.0,
                                                );

                                    return Column(
                                      children: [
                                        SliderTheme(
                                          data: SliderThemeData(
                                            trackHeight: 2,
                                            activeTrackColor: Colors.white,
                                            inactiveTrackColor: Colors.white24,
                                            thumbColor: Colors.white,
                                            thumbShape:
                                                const RoundSliderThumbShape(
                                                  enabledThumbRadius: 6,
                                                ),
                                            overlayShape:
                                                const RoundSliderOverlayShape(
                                                  overlayRadius: 14,
                                                ),
                                          ),
                                          child: Slider(
                                            min: 0,
                                            max: max > 0 ? max : 1,
                                            value: value,
                                            onChangeStart: (newValue) {
                                              setState(() {
                                                _isDragging = true;
                                                _dragValue = newValue;
                                              });
                                            },
                                            onChanged: (newValue) {
                                              setState(
                                                () => _dragValue = newValue,
                                              );
                                            },
                                            onChangeEnd: (newValue) {
                                              _player?.seek(
                                                Duration(
                                                  milliseconds:
                                                      newValue.toInt(),
                                                ),
                                              );
                                              setState(() {
                                                _isDragging = false;
                                                _isSeeking = true;
                                              });
                                              Future.delayed(
                                                const Duration(
                                                  milliseconds: 1000,
                                                ),
                                                () {
                                                  if (mounted && _isSeeking) {
                                                    setState(
                                                      () => _isSeeking = false,
                                                    );
                                                  }
                                                },
                                              );
                                            },
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          child: Row(
                                            children: [
                                              Text(
                                                WatchProgressService.formatDuration(
                                                  Duration(
                                                    milliseconds: value.toInt(),
                                                  ),
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              const Spacer(),
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.audiotrack,
                                                  color: Colors.white,
                                                  size: 20,
                                                ),
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                                onPressed: _showAudioSelection,
                                              ),
                                              const SizedBox(width: 12),
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.closed_caption,
                                                  color: Colors.white,
                                                  size: 20,
                                                ),
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                                onPressed:
                                                    _showSubtitleSelection,
                                              ),
                                              if (_playlist.length > 1) ...[
                                                const SizedBox(width: 12),
                                                IconButton(
                                                  icon: const Icon(
                                                    Icons.list_alt,
                                                    color: Colors.white,
                                                    size: 20,
                                                  ),
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(),
                                                  onPressed:
                                                      _showEpisodeSelection,
                                                ),
                                              ],
                                              const SizedBox(width: 12),
                                              Text(
                                                WatchProgressService.formatDuration(
                                                  duration,
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
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
        ),
      ),
    );
  }

  void _seekBackward() {
    if (_player == null) return;
    setState(() {
      _isSeeking = true;
      _seekFeedbackForward = false;
      _seekFeedbackSeconds = 10;
    });
    final pos = _player!.state.position - const Duration(seconds: 10);
    _player!.seek(pos < Duration.zero ? Duration.zero : pos);
    _startHideControlsTimer();
    _resetSeekFeedback();
  }

  void _seekForward() {
    if (_player == null) return;
    setState(() {
      _isSeeking = true;
      _seekFeedbackForward = true;
      _seekFeedbackSeconds = 10;
    });
    final pos = _player!.state.position + const Duration(seconds: 10);
    final dur = _player!.state.duration;
    _player!.seek(pos > dur ? dur : pos);
    _startHideControlsTimer();
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

  Widget _buildLikePromptOverlay() {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Container(
      color: Colors.black.withOpacity(0.85),
      padding: EdgeInsets.symmetric(
        horizontal: isLandscape ? 60 : 40,
        vertical: isLandscape ? 20 : 40,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isLandscape ? 700 : 400),
          child:
              isLandscape
                  ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (_currentItem.logo != null) ...[
                        _buildPromptPoster(isLandscape: true),
                        const SizedBox(width: 48),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildPromptText(),
                            const SizedBox(height: 8),
                            if (_isLikedLocal == null) _buildPromptSubtext(),
                            const SizedBox(height: 24),
                            if (_isLikedLocal == null)
                              Row(
                                mainAxisAlignment: MainAxisAlignment.start,
                                children: [
                                  _buildLikeActionButton(
                                    icon: Icons.thumb_down_alt_rounded,
                                    label: 'No me gustó',
                                    color: Colors.white12,
                                    onTap: _handleDislike,
                                  ),
                                  const SizedBox(width: 24),
                                  _buildLikeActionButton(
                                    icon: Icons.thumb_up_alt_rounded,
                                    label: 'Me gustó',
                                    color: Colors.red,
                                    onTap: _handleLike,
                                  ),
                                ],
                              )
                            else
                              _buildPromptSuccess(),
                            const SizedBox(height: 24),
                            _buildPromptCloseButton(
                              alignment: CrossAxisAlignment.start,
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                  : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_currentItem.logo != null)
                        _buildPromptPoster(isLandscape: false),
                      _buildPromptText(),
                      const SizedBox(height: 12),
                      if (_isLikedLocal == null) _buildPromptSubtext(),
                      const SizedBox(height: 32),
                      if (_isLikedLocal == null)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildLikeActionButton(
                              icon: Icons.thumb_down_alt_rounded,
                              label: 'No me gustó',
                              color: Colors.white12,
                              onTap: _handleDislike,
                            ),
                            const SizedBox(width: 24),
                            _buildLikeActionButton(
                              icon: Icons.thumb_up_alt_rounded,
                              label: 'Me gustó',
                              color: Colors.red,
                              onTap: _handleLike,
                            ),
                          ],
                        )
                      else
                        _buildPromptSuccess(),
                      const SizedBox(height: 40),
                      _buildPromptCloseButton(),
                    ],
                  ),
        ),
      ),
    );
  }

  void _handleLike() {
    setState(() {
      _isLikedLocal = true;
    });
    M3UService().likeContent(_currentItem);
    _dismissPromptDelayed();
  }

  void _handleDislike() {
    setState(() {
      _isLikedLocal = false;
    });
    _dismissPromptDelayed();
  }

  void _dismissPromptDelayed() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _showLikePrompt = false;
          _likePromptDismissed = true;
        });
      }
    });
  }

  Widget _buildPromptPoster({required bool isLandscape}) {
    return Container(
      width: isLandscape ? 100 : 120,
      height: isLandscape ? 150 : 180,
      margin: EdgeInsets.only(bottom: isLandscape ? 0 : 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.red.withOpacity(0.3),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FastThumbnail(
          url: _currentItem.logo!,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  Widget _buildPromptText() {
    return Text(
      _isLikedLocal == null
          ? '¿Te gustó la película?'
          : (_isLikedLocal!
              ? '¡Gracias! Nos alegra que te haya gustado.'
              : 'Gracias por tu opinión. Seguiremos mejorando.'),
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 22,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _buildPromptSubtext() {
    return const Text(
      'Tu opinión nos ayuda a recomendarte mejor contenido.',
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.white70, fontSize: 14),
    );
  }

  Widget _buildPromptSuccess() {
    return const SizedBox(
      height: 80,
      child: Center(
        child: Icon(Icons.check_circle_rounded, color: Colors.green, size: 48),
      ),
    );
  }

  Widget _buildPromptCloseButton({
    CrossAxisAlignment alignment = CrossAxisAlignment.center,
  }) {
    return TextButton(
      onPressed: () {
        setState(() {
          _showLikePrompt = false;
          _likePromptDismissed = true;
        });
      },
      child: const Text(
        'Cerrar',
        style: TextStyle(color: Colors.white38, fontSize: 14),
      ),
    );
  }

  Widget _buildAutoPlayOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.8),
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

  Widget _buildLikeActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(30),
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildAdCountdownOverlay() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0a0a0a).withOpacity(0.7),
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
    // Medidas exactas que usa IconButton internamente:
    // iconSize + padding (8px * 2 cada lado) = tamaño visual del botón
    const double seekBtnWidth = 42 + 16; // replay_10 / forward_10
    const double playBtnWidth = 60.0; // Espacio central estilo Netflix
    const double gap = 32.0; // Separación balanceada

    return Align(
      alignment: const Alignment(
        0,
        0.05,
      ), // Ligeramente más abajo tras quitar el texto
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Slot izquierdo — replay
          SizedBox(
            width: seekBtnWidth,
            child:
                !_seekFeedbackForward
                    ? Center(child: _buildSeekFeedbackBubble())
                    : null,
          ),
          const SizedBox(width: gap),
          // Slot central — play (vacío, solo ocupa espacio)
          const SizedBox(width: playBtnWidth),
          const SizedBox(width: gap),
          // Slot derecho — forward
          SizedBox(
            width: seekBtnWidth,
            child:
                _seekFeedbackForward
                    ? Center(child: _buildSeekFeedbackBubble())
                    : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSeekFeedbackBubble() {
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
              child: Icon(
                _seekFeedbackForward
                    ? Icons.forward_10_outlined
                    : Icons.replay_10_outlined,
                color: const Color.fromARGB(255, 247, 247, 247),
                size: 42,
                shadows: const [Shadow(color: Colors.black45, blurRadius: 8)],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AppLoadingAnimation extends StatefulWidget {
  const _AppLoadingAnimation();

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
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.red.withOpacity(0.1), width: 4),
            ),
          ),
          const SizedBox(
            width: 60,
            height: 60,
            child: CircularProgressIndicator(
              value: 0.3,
              strokeWidth: 4,
              color: Colors.red,
              strokeCap: StrokeCap.round,
            ),
          ),
        ],
      ),
    );
  }
}
