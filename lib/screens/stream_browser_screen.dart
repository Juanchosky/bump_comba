import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/m3u_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/search_history_service.dart';
import 'content_detail_screen.dart';
import 'category_screen.dart';
import '../utils/transitions.dart';
import '../services/performance_service.dart';
import '../services/fast_image_service.dart';
import '../utils/snack_bar_utils.dart';
import 'history_screen.dart';
import 'package:shimmer/shimmer.dart';
import '../services/watch_progress_service.dart';
import 'video_player_screen.dart';
import '../services/game_config_service.dart';
import '../services/video_prewarm_service.dart';
import '../services/premium_service.dart';
import '../services/ad_service.dart';
import '../utils/content_filters.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'subscription_screen.dart';
import '../utils/colors.dart';
import 'stream_browser_config_screen.dart';
import 'settings_screen.dart';
import '../services/social_rewards_service.dart';
import '../widgets/rate_dialog.dart';
import '../services/deep_link_service.dart';
import '../services/network_quality_service.dart';

Future<void> _safeToggleFavoriteGlobal(
  BuildContext context,
  M3UService m3uService,
  M3UItem item,
  VoidCallback onComplete,
) async {
  try {
    await m3uService.toggleFavorite(item);
    onComplete();
    if (context.mounted) {
      SnackBarUtils.showAppSnackBar(
        context,
        item.isFavorite ? 'Añadido a Mi lista' : 'Eliminado de Mi lista',
      );
    }
  } catch (e) {
    if (context.mounted) {
      SnackBarUtils.showAppSnackBar(
        context,
        e.toString().replaceAll('Exception: ', ''),
        action: SnackBarAction(
          label: 'Ver Planes',
          textColor: Colors.amberAccent,
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            );
          },
        ),
      );
    }
  }
}

class ExitFullscreenIntent extends Intent {
  const ExitFullscreenIntent();
}

class StreamBrowserScreen extends StatefulWidget {
  const StreamBrowserScreen({super.key});

  @override
  State<StreamBrowserScreen> createState() => _StreamBrowserScreenState();
}

class _StreamBrowserScreenState extends State<StreamBrowserScreen>
    with AutomaticKeepAliveClientMixin {
  final M3UService _m3uService = M3UService();
  final SearchHistoryService _searchHistoryService = SearchHistoryService();
  final GameConfigService _gameConfigService = GameConfigService();
  // Agregar junto a las otras variables de estado
  final ValueNotifier<int> _watchProgressVersion = ValueNotifier<int>(0);
  final ScrollController _homeScrollController = ScrollController();
  // Custom PC Premium Support
  final TextEditingController _pcLicenseController = TextEditingController();
  bool _isValidatingLicense = false;
  String? _licenseErrorMessage;

  bool _isLoading = true;
  // bool _isSearchingLoading = false; // REMOVED
  bool _hasError = false;
  String _errorMessage = '';
  String? _detectedCountryCode;
  bool _isOffline = false;
  bool _bannerDismissed = false;

  // Slow loading feedback
  bool _showSlowLoadingMessage = false;
  Timer? _slowLoadingTimer;
  // _stallTimer removed â€” no longer used

  // Search
  // bool _isSearching = false; // REMOVED
  // final TextEditingController _searchController = TextEditingController(); // REMOVED
  final TextEditingController _sourceUrlController = TextEditingController();

  // final FocusNode _searchFocusNode = FocusNode(); // REMOVED
  // Timer? _debounce; // REMOVED
  // List<M3UItem> _searchResults = []; // REMOVED

  // Fixed Categories
  List<String> get _fixedTabs {
    final tabs = ['Inicio', 'Películas', 'Series', 'Telenovelas', 'Animación'];

    final bool isPC =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;

    // Only show "Community" if the user has enough coins AND enough time has passed (AND NOT PC)
    if (!isPC &&
        _m3uService.isCommunityFeatureVisible(
          _gameConfigService.coins,
          _gameConfigService.firstInstallDate,
        )) {
      tabs.add('Tesoros Especiales');
    }

    return tabs;
  }

  String _selectedTab = 'Inicio';
  // Dynamic placeholder

  // Bottom nav
  int _bottomNavIndex =
      0; // 0=Inicio, 1=Buscar(acción), 2=Categorías, 3=Mi lista

  // State
  M3UItem? _heroItem;
  // Hero destacado por sección (persistencia por sesión, igual que _heroItem).
  final Map<String, M3UItem> _sectionHeroItems = {};
  bool _isNavigating = false;
  DateTime? _lastPressedAt;

  // Live TV Sub-state
  // Active category chip
  Player? _livePlayer;
  VideoController? _liveVideoController;
  final ValueNotifier<VideoController?> _liveVideoControllerNotifier =
      ValueNotifier<VideoController?>(null);
  final ValueNotifier<Uint8List?> _lastLiveFrameBytesNotifier =
      ValueNotifier<Uint8List?>(null);
  M3UItem? _currentLiveChannel;
  bool _isLiveLoading = false;
  bool _isLiveReloading = false; // Add guard for reloading
  bool _isLiveError = false; // Persistent error state
  int _liveRetryCount = 0;
  // Guard: prevents creating a new player while the previous one is draining
  bool _isDisposingLivePlayer = false;

  // Channel Mirroring & Recovery
  M3UItem? _originalLiveChannel;
  bool _isUsingMirror = false;
  Timer? _recoveryTimer;
  final TextEditingController _liveSearchController = TextEditingController();
  Timer? _inlineControlsTimer;

  // -- LIVE TV HEALTH MONITOR STATE --
  Timer? _liveHealthMonitorTimer;
  // _liveStallSeconds and _lastLivePosition removed â€” now local vars in monitor
  bool _isLiveChannel = true;

  // Calidad Adaptativa Dinámica
  bool _isQualityCapped = false;
  Timer? _qualityRestoreTimer;

  // Live Mid-roll Ads (12 min cycle)
  int _liveSecondsWatched = 0;
  bool _liveMidRollNoticeShown = false;
  bool _hasViewedLiveMidRollAd = false; // Add flag for one-time ad
  Timer? _liveDurationTimer;
  final ValueNotifier<int?> _liveAdCountdownNotifier = ValueNotifier<int?>(
    null,
  );
  final ValueNotifier<String> _liveSpeedNotifier = ValueNotifier<String>(
    '0 B/s',
  );

  // Recommendations cache (stable during session)
  List<M3UItem>? _recommendedItems;
  final List<StreamSubscription> _liveStreamSubscriptions = [];

  // Download progress
  String? _downloadDetail;

  // Progressive loading for categories rows
  int _loadedHomeCategories = 3;
  int _loadedMovieCategories = 3;
  int _loadedSeriesCategories = 3;
  int _loadedNovelaCategories = 3;
  int _loadedAnimationCategories = 3;

  bool _isHomeLoadingMore = false;
  bool _isMoviesLoadingMore = false;
  bool _isSeriesLoadingMore = false;
  bool _isNovelasLoadingMore = false;
  bool _isAnimationLoadingMore = false;

  String _getRandomUserAgent() {
    const agents = [
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/119.0',
      'VLC/3.0.18 LibVLC/3.0.18',
      'Dalvik/2.1.0 (Linux; U; Android 13; Pixel 7 Build/TQ3A)',
    ];
    return agents[DateTime.now().microsecond % agents.length];
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _launchURL(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        SnackBarUtils.showAppSnackBar(context, 'No se pudo abrir el enlace');
      }
    }
  }

  void _startInlineHideTimer() {
    _inlineControlsTimer?.cancel();
    _inlineControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<bool> _onWillPop() async {
    // If not on the home tab, go back to Inicio instead of exiting
    if (_bottomNavIndex != 0) {
      setState(() {
        _bottomNavIndex = 0;
        _selectedTab = 'Inicio';
      });
      return false;
    }

    // 1. Handle Exit Confirmation
    final now = DateTime.now();
    if (_lastPressedAt == null ||
        now.difference(_lastPressedAt!) > const Duration(seconds: 2)) {
      _lastPressedAt = now;
      SnackBarUtils.showAppSnackBar(context, 'Presiona otra vez para salir');
      return false;
    }

    return true;
  }

  @override
  void initState() {
    super.initState();
    _initService();
    _initSearchHistory();
    _detectCountry();
    // Listen to global ad state to pause live player
    AdService.isAdInProgress.addListener(_handleAdStateChange);
    // FIX: Escuchar al M3UService para cuando el cómputo async de items
    // recientes termine y así actualizar las secciones del home.
    _m3uService.addListener(_onM3UServiceUpdated);
    WatchProgressService().addListener(_onWatchProgressUpdated);
    _checkRateDialog();
    // Initialize Deep Link Listener
    DeepLinkService().init(context);

    // Initialize global NetworkQualityService and listen
    NetworkQualityService().startGlobal();
    _isOffline =
        NetworkQualityService().quality.value == NetworkQuality.offline;
    NetworkQualityService().quality.addListener(_onNetworkQualityChanged);
  }

  void _onNetworkQualityChanged() {
    final offline =
        NetworkQualityService().quality.value == NetworkQuality.offline;
    if (_isOffline != offline) {
      if (mounted) {
        setState(() {
          _isOffline = offline;
          // Si el usuario cerró el banner con la X, no volver a mostrarlo
          // aunque se pierda la conexión de nuevo (permanece oculto).
        });
      }
    }
  }

  void _checkRateDialog() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (SocialRewardsService().shouldShowRateDialog()) {
        showDialog(context: context, builder: (context) => const RateDialog());
      }
    });
  }

  bool _wasPlayingBeforeAd = false;

  void _handleAdStateChange() {
    if (AdService.isAdInProgress.value) {
      if (_livePlayer != null && _livePlayer!.state.playing) {
        _wasPlayingBeforeAd = true;
        _livePlayer!.pause();
        if (mounted) {}
      }
    } else {
      if (_wasPlayingBeforeAd && _livePlayer != null) {
        _wasPlayingBeforeAd = false;
        _livePlayer!.play();
      }
    }
  }

  @override
  void dispose() {
    NetworkQualityService().quality.removeListener(_onNetworkQualityChanged);
    _watchProgressVersion.dispose();
    _liveVideoControllerNotifier.dispose();
    _lastLiveFrameBytesNotifier.dispose();
    _m3uService.removeListener(_onM3UServiceUpdated);
    WatchProgressService().removeListener(_onWatchProgressUpdated);
    _disposeLivePlayer();
    _slowLoadingTimer?.cancel();
    _liveSearchController.dispose();
    _inlineControlsTimer?.cancel();
    _pcLicenseController.dispose();
    _sourceUrlController.dispose();

    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    DeepLinkService().dispose();
    super.dispose();
  }

  /// FIX: Llamado por M3UService.notifyListeners() cuando el cómputo async
  /// de items recientes termina (sea porque se cargó desde caché o fresco).
  /// Recarga _recommendedItems si aún están vacíos y dispara un rebuild.
  void _onWatchProgressUpdated() {
    if (mounted) {
      _watchProgressVersion.value++;
    }
  }

  void _onM3UServiceUpdated() {
    if (!mounted || _isLoading) return;

    // â”€â”€ TMDB TRENDING HERO: Si el hero no se ha establecido aún,
    // intentar usar trending TMDB cuando los datos llegan async â”€â”€
    if (_heroItem == null) {
      final trendingItems = _m3uService.getTrendingBannerItems();
      if (trendingItems.isNotEmpty) {
        _setHeroRandomly(trendingItems);
      }
    }

    final recentItems = _m3uService.getRecentItems();
    if (recentItems.isNotEmpty &&
        (_recommendedItems == null || _recommendedItems!.isEmpty)) {
      // Limpiar caché de sesión del servicio para forzar recompute con la
      // lógica corregida (que ahora prioriza categorías con contenido no-live)
      _m3uService.clearSessionRecommendations();
      WatchProgressService().getHistory().then((history) {
        if (!mounted) return;
        final recommended = _m3uService.getRecommendedItems(history);
        if (mounted) {
          setState(() {
            _recommendedItems = recommended;
          });
        }
      });
    } else if (mounted) {
      // Rebuild para que la UI recoja los nuevos recentItems
      setState(() {});
    }
  }

  Future<void> _initService() async {
    try {
      // Reset slow loading state and download indicators
      setState(() {
        _showSlowLoadingMessage = false;
        _downloadDetail = null;
        // FIX: Resetear para que se recalcule con los datos del caché al reiniciar
        _recommendedItems = null;
      });
      _slowLoadingTimer?.cancel();

      // Start timer to show message if loading takes too long
      _slowLoadingTimer = Timer(const Duration(seconds: 7), () {
        if (mounted && _isLoading) {
          setState(() => _showSlowLoadingMessage = true);
        }
      });

      // Crucial: Initialize Premium Service immediately so the PC License is loaded
      // BEFORE we drop the `_isLoading` flag and evaluate the Desktop Premium Gate
      await PremiumService().initialize();
      await _m3uService.init();

      bool success = false;

      // FastBoot: Intentar cargar del caché instantáneamente para restaurar la UI
      final cachedOk = await _m3uService.loadFromCache();
      if (cachedOk && mounted) {
        success = true;
        setState(() => _isLoading = false);
        // Si cargamos de caché, refrescamos en background silenciosamente
        unawaited(
          _m3uService.loadM3UContent(useRetry: false).then((refreshSuccess) {
            if (refreshSuccess && mounted) {
              // Re-pick hero si cambió algo importante
              // Solo elegir el héroe una vez por sesión al entrar en la pestaña "Inicio"
              if (_heroItem == null) {
                _pickHeroItem(_m3uService.latestItems);
              }
              setState(() {});
            }
          }),
        );
      }

      if (_isLoading) {
        // Solo si NO pudimos cargar del caché, procedemos con la carga normal bloqueante
        success = await _m3uService.loadM3UContent(
          useRetry: true,
          retryAttempts: 3,
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                if (progress.totalBytes != null && progress.totalBytes! > 0) {
                  _downloadDetail =
                      '${(progress.receivedBytes / 1024 / 1024).toStringAsFixed(1)} MB / ${(progress.totalBytes! / 1024 / 1024).toStringAsFixed(1)} MB';
                } else {
                  _downloadDetail =
                      '${(progress.receivedBytes / 1024 / 1024).toStringAsFixed(1)} MB descargados...';
                }
              });
            }
          },
        );

        _slowLoadingTimer?.cancel();
        if (mounted) {
          setState(() {
            _downloadDetail = null;
            if (success) _isLoading = false;
          });
        }
      } else {
        // Si ya no estamos cargando (FastBoot), solo cancelamos el timer
        _slowLoadingTimer?.cancel();
      }

      if (success) {
        // Pick Hero Item once on load, only if it hasn't been picked yet (e.g. app start)
        if (_heroItem == null) {
          _pickHeroItem(_m3uService.latestItems);
        }

        // â”€â”€ Mover trabajo pesado fuera del UI thread â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        // getRecommendedItems() y la construcción de priorityUrls iteran
        // sobre toda la lista y bloquean el main thread, congelando el shimmer.
        // Future.microtask() cede el control al event loop (y al animationFrame)
        // antes de ejecutar el bloque, eliminando el freeze visible.
        if (_recommendedItems == null || _recommendedItems!.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 50), () async {
            final history = await WatchProgressService().getHistory();
            _recommendedItems = _m3uService.getRecommendedItems(history);
          });
        }

        // Precarga de imágenes â€” también diferida al microtask siguiente
        // para que el setState de `_isLoading = false` llegue primero al árbol
        // y el usuario vea el contenido antes de que empiece la precarga.
        if (mounted) {
          final priorityUrls = [
            if (_heroItem?.logo != null) _heroItem!.logo!,
            ..._m3uService
                .getRecentItems()
                .where((i) => i.logo != null)
                .take(19)
                .map((i) => i.logo!),
          ];

          // prewarmPriority y prewarm son síncronos internamente pero rápidos;
          // envolverlos en un delay evita que bloqueen el frame de transición.
          Future.delayed(const Duration(milliseconds: 50), () {
            if (!mounted) return;
            FastImageService().prewarmPriority(priorityUrls, context);

            final allUrls =
                _m3uService.items
                    .where((i) => i.logo != null && i.logo!.isNotEmpty)
                    .map((i) => i.logo!)
                    .toList();
            FastImageService().prewarm(allUrls, context);
          });
        }
      }

      if (!mounted) return;

      final m3uUrl = await _m3uService.getM3UUrl();
      final isSourceMissing = m3uUrl == null || m3uUrl.isEmpty;

      setState(() {
        _isLoading = false;
        // Trigger pre-warming for 'Seguir Viendo' items with a 5s delay to avoid initial contention
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted) _triggerPrewarming();
        });

        if (isSourceMissing) {
          // If source is missing, we don't treat it as a hard error page,
          // instead we show the StreamContent which will show the input field
          // in the Películas tab (or we can just show the input field directly here).
          _hasError = false;
          _selectedTab =
              'Inicio'; // Suggest navigating to Inicio where input is
        } else {
          _hasError = !success;
          if (!success) {
            _errorMessage =
                _m3uService.lastError ??
                'No se pudo cargar el contenido. Verifica tu enlace M3U.';
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = true;
        _errorMessage = 'Error: $e';
      });
    }
  }

  Future<void> _initSearchHistory() async {
    await _searchHistoryService.init();
    if (mounted) setState(() {});
  }

  Future<void> _playItem(M3UItem item, {List<M3UItem>? playlist}) async {
    if (!mounted) return;

    // CRITICAL: Ensure the Live Player (TV) is COMPLETELY disposed
    // before we even think about opening a movie (VOD).
    await _disposeLivePlayer();

    final prewarmedPlayer = VideoPrewarmService().getPlayer(item);

    await Navigator.push(
      context,
      FadeScalePageRoute(
        page: VideoPlayerScreen(
          item: item,
          playlist: playlist ?? [],
          prewarmedPlayer: prewarmedPlayer,
        ),
      ),
    );
    // Refresh history version to trigger SegmentedHistoryRow update
    _watchProgressVersion.value++;

    // Refresh recommendations since history has changed (NO LONGER NEEDED SUDDEN CHANGES)
    // We keep recommendations stable during session as per user request.
  }

  void _triggerPrewarming() async {
    final history = await WatchProgressService().getHistory();
    if (history.isEmpty) return;

    // Take the first 2 most recent items
    final toPrewarm = history.take(2).toList();
    final userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.1 Safari/537.36';

    for (final progress in toPrewarm) {
      // Find the actual M3UItem from service to get full details (URL, etc.)
      try {
        final fullItem = _m3uService.items.firstWhere(
          (i) => i.url == progress.url,
        );
        VideoPrewarmService().prewarm(fullItem, userAgent);
      } catch (_) {
        // Item not found in current M3U, skip pre-warming it
      }
    }
  }

  // Removed internal player methods

  Future<void> _onItemTap(M3UItem item, {String? heroTag}) async {
    HapticFeedback.selectionClick();
    // Get similar items
    final similarItems = _m3uService.getSimilarItems(item);

    await Navigator.push(
      context,
      ContentDetailPageRoute(
        page: ContentDetailScreen(
          item: item,
          similarItems: similarItems,
          heroTag: heroTag,
          onToggleFavorite: (favItem) async {
            await _safeToggleFavoriteGlobal(context, _m3uService, favItem, () {
              if (mounted) setState(() {});
            });
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  // Removed internal player methods

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          // If there's no previous route (direct access mode), exit the app
          if (!Navigator.of(context).canPop()) {
            SystemNavigator.pop();
          } else {
            Navigator.pop(context);
          }
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          systemNavigationBarColor: AppColors.background,
          systemNavigationBarIconBrightness: Brightness.light,
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: SafeArea(
            child: Stack(
              children: [
                Column(
                  children: [
                    _buildAppBar(),
                    Expanded(
                      child:
                          (_isDesktopOrWeb() && !PremiumService().isPremium)
                              ? _buildDesktopPremiumGate()
                              : AnimatedSwitcher(
                                duration: const Duration(milliseconds: 340),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                // Transición premium al cambiar de pestaña
                                // (Inicio → Películas → Series, etc.): fade
                                // suave + un ligero escalado para que el
                                // contenido "asiente" con fluidez.
                                transitionBuilder: (child, animation) {
                                  final key = child.key;
                                  final keyValue =
                                      key is ValueKey ? '${key.value}' : '';
                                  // "Mi Lista" (barra inferior, índice 1):
                                  // entra con fade + sutil deslizamiento
                                  // desde abajo, natural para navegación
                                  // inferior.
                                  if (keyValue.startsWith('content_1_')) {
                                    return FadeTransition(
                                      opacity: animation,
                                      child: SlideTransition(
                                        position: Tween<Offset>(
                                          begin: const Offset(0.0, 0.04),
                                          end: Offset.zero,
                                        ).animate(
                                          CurvedAnimation(
                                            parent: animation,
                                            curve: Curves.easeOutCubic,
                                          ),
                                        ),
                                        child: child,
                                      ),
                                    );
                                  }
                                  // Resto (pestañas y estados): fade suave con
                                  // un ligero escalado.
                                  return FadeTransition(
                                    opacity: animation,
                                    child: ScaleTransition(
                                      scale: Tween<double>(
                                        begin: 0.985,
                                        end: 1.0,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  );
                                },
                                child:
                                    _isLoading
                                        ? KeyedSubtree(
                                          key: const ValueKey('loading'),
                                          child: _buildLoading(),
                                        )
                                        : _hasError
                                        ? KeyedSubtree(
                                          key: const ValueKey('error'),
                                          child: _buildError(),
                                        )
                                        : KeyedSubtree(
                                          // La key incluye la pestaña activa
                                          // para que el switcher anime cada
                                          // cambio de tab (y de barra inferior).
                                          key: ValueKey(
                                            'content_${_bottomNavIndex}_$_selectedTab',
                                          ),
                                          child: _buildStreamContent(),
                                        ),
                              ),
                    ),
                  ],
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    transitionBuilder: (child, animation) {
                      final slide = Tween<Offset>(
                        begin: const Offset(0, -1.0),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                        ),
                      );
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(position: slide, child: child),
                      );
                    },
                    child:
                        (_isOffline && !_bannerDismissed)
                            ? NetflixOfflineBanner(
                              key: const ValueKey('global_banner_visible'),
                              onDismiss: () {
                                setState(() => _bannerDismissed = true);
                              },
                            )
                            : const SizedBox.shrink(
                              key: ValueKey('global_banner_hidden'),
                            ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: _isLoading ? null : _buildBottomNav(),
        ),
      ),
    );
  }

  bool _isDesktopOrWeb() {
    return kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Widget _buildAppBar() {
    return Container(); // No app bar needed here as we have custom headers inside content
  }

  Widget _buildDesktopPremiumGate() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.background,
        image: DecorationImage(
          image: const AssetImage('assets/images/background.jpg'),
          fit: BoxFit.cover,
          colorFilter: ColorFilter.mode(
            AppColors.background.withValues(alpha: 0.9),
            BlendMode.darken,
          ),
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon with glow
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.amber.withValues(alpha: 0.1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.amber.withValues(alpha: 0.1),
                      blurRadius: 40,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.workspace_premium_rounded,
                  size: 80,
                  color: Colors.amber,
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'Versión de Escritorio',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Esta versión es exclusiva para nuestros suscriptores Premium. Disfruta de una experiencia sin límites, sin anuncios y con la mejor calidad en tu PC.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 16,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),

              // PC License Key Redemption UI
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxWidth: 400),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Activa tu Premium PC',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Si compraste la versión PC por \$3.99, ingresa tu código de licencia aquí:',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Input Field
                    TextField(
                      controller: _pcLicenseController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2,
                      ),
                      decoration: InputDecoration(
                        hintText: 'XXXX-XXXX',
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.3),
                          letterSpacing: 2,
                        ),
                        filled: true,
                        fillColor: Colors.black.withValues(alpha: 0.5),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color:
                                _licenseErrorMessage != null
                                    ? Colors.red.withValues(alpha: 0.5)
                                    : Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.amber),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 18,
                        ),
                      ),
                      onChanged: (_) {
                        if (_licenseErrorMessage != null) {
                          setState(() => _licenseErrorMessage = null);
                        }
                      },
                      onSubmitted: (_) => _validatePCLicense(),
                    ),

                    if (_licenseErrorMessage != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _licenseErrorMessage!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // Action Button
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed:
                            _isValidatingLicense ? null : _validatePCLicense,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber,
                          foregroundColor: Colors.black,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child:
                            _isValidatingLicense
                                ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    color: Colors.black,
                                    strokeWidth: 2.5,
                                  ),
                                )
                                : const Text(
                                  'Verificar Código',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              TextButton(
                onPressed: () async {
                  const url = 'https://bump-comba-landing.vercel.app/';
                  if (await canLaunchUrl(Uri.parse(url))) {
                    await launchUrl(Uri.parse(url));
                  }
                },
                child: const Text(
                  '¿No tienes código? Obtenlo aquí por \$3.99/mes',
                  style: TextStyle(
                    color: Colors.amber,
                    decoration: TextDecoration.underline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _validatePCLicense() async {
    final code = _pcLicenseController.text.trim();
    if (code.isEmpty) {
      setState(() => _licenseErrorMessage = 'Por favor ingresa un código.');
      return;
    }

    setState(() {
      _isValidatingLicense = true;
      _licenseErrorMessage = null;
    });

    try {
      final result = await PremiumService().validateAndActivateLicenseCode(
        code,
      );

      if (!mounted) return;

      if (result['success'] == true) {
        SnackBarUtils.showAppSnackBar(context, result['message']);
        // Force full re-initialization of services to acknowledge premium
        await _initService();
        setState(() {}); // Remove the block immediately
      } else {
        setState(() => _licenseErrorMessage = result['message']);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _licenseErrorMessage = 'Error: $e');
    } finally {
      if (mounted) {
        setState(() => _isValidatingLicense = false);
      }
    }
  }

  Widget _buildLoading() {
    Widget loadingContent = const _HiddenMoviesShimmer();

    if (!_showSlowLoadingMessage && _downloadDetail == null) {
      return SizedBox.expand(
        child: Align(alignment: Alignment.topCenter, child: loadingContent),
      );
    }

    return Stack(
      children: [
        loadingContent,
        Container(
          color: AppColors.background.withValues(alpha: 0.7),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CupertinoActivityIndicator(radius: 17),
                if (_downloadDetail != null) ...[
                  const SizedBox(height: 24),
                  const _AnimatedLoadingMessages(),
                ],
              ],
            ),
          ),
        ),
        if (_downloadDetail != null)
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                _downloadDetail!,
                style: TextStyle(
                  color: const Color.fromARGB(255, 245, 245, 245),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildError() {
    final bool isConnectionRefused =
        _errorMessage.contains('rechazada') ||
        _errorMessage.contains('refused') ||
        _errorMessage.contains('saturado');

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Premium glowing icon container
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.05),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withValues(alpha: 0.15),
                      blurRadius: 40,
                      spreadRadius: -10,
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    CupertinoIcons.wifi_slash,
                    color: Colors.redAccent,
                    size: 44,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              // Main Error Text
              Text(
                _errorMessage,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
              if (isConnectionRefused) ...[
                const SizedBox(height: 24),
                // Glassmorphic tips box
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.05),
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            CupertinoIcons.lightbulb_fill,
                            color: Colors.yellow.shade700,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Sugerencias',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'â€¢ Prueba conectarte a una VPN\nâ€¢ Reinicia tu router de internet\nâ€¢ El servidor podría estar saturado, intenta en unos minutos',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 13,
                          height: 1.6,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 48),
              // Primary Retry Button
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                      _hasError = false;
                    });
                    _initService();
                  },
                  icon: const Icon(CupertinoIcons.refresh_circled, size: 22),
                  label: const Text(
                    'Reintentar Conexión',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Secondary Settings Button
              SizedBox(
                width: double.infinity,
                height: 54,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _hasError = false;
                      // Defaulting to 'Inicio' where the config field actually is typically shown.
                      _selectedTab = 'Inicio';
                    });
                  },
                  icon: Icon(
                    CupertinoIcons.settings,
                    size: 20,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                  label: Text(
                    'Configurar fuente manual',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.05),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
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

  void _pickHeroItem(List<M3UItem> items) {
    if (items.isEmpty) return;

    // Solo elegir un nuevo ítem si no está establecido (persistencia por sesión).
    if (_heroItem != null) return;

    // â”€â”€ PRIORIDAD TMDB: Intentar usar contenido trending de TMDB â”€â”€
    final trendingItems = _m3uService.getTrendingBannerItems();
    if (trendingItems.isNotEmpty) {
      _setHeroRandomly(trendingItems);
      if (_heroItem != null) return; // Si se estableció, no continuar
    }

    // 1. Obtener un pool base de películas y series recientes.
    final List<M3UItem> moviePool = _m3uService.movies.take(100).toList();
    final List<M3UItem> seriesPool = _m3uService.series.take(100).toList();
    final List<M3UItem> combinedPool = [...moviePool, ...seriesPool];

    // Si los pools están vacíos, usamos el fallback de items.
    final rawPool =
        combinedPool.isNotEmpty
            ? combinedPool
            : items.where((i) => !i.isLive).toList();

    // 2. Filtrado inicial de validez.
    final validPool =
        _m3uService.filterValidItems(rawPool).where((item) {
          if (item.isLive || item.sourceName == 'Supabase') return false;
          final n = item.name.toLowerCase();
          if (n.contains('canal ') ||
              n.contains('tv ') ||
              n.contains('en vivo')) {
            return false;
          }
          return true;
        }).toList();

    if (validPool.isEmpty) return;

    // 3. Agrupar películas por año detectado.
    final Map<int, List<M3UItem>> moviesByYear = {};
    // Regex más flexible para capturar años incluso pegados a paréntesis o corchetes.
    final yearRegex = RegExp(r'(\d{4})');

    for (var item in validPool) {
      final matches = yearRegex.allMatches(item.name);
      if (matches.isNotEmpty) {
        // Tomamos el último año mencionado en el nombre para evitar falsos positivos
        // (ej: "48 Horas (1982) [Resampled 2024]") -> Selecciona 2024.
        final yearStr = matches.last.group(1) ?? '';
        final year = int.tryParse(yearStr);
        if (year != null && year >= 1950 && year <= 2100) {
          moviesByYear.putIfAbsent(year, () => []).add(item);
        }
      }
    }

    if (moviesByYear.isEmpty) {
      // Fallback si no detectamos años: usar pool válido tal cual.
      _setHeroRandomly(validPool);
      return;
    }

    // 4. ALGORITMO ADAPTATIVO CON PESOS: Priorizar año más reciente (3x de probabilidad).
    final sortedYears =
        moviesByYear.keys.toList()..sort((a, b) => b.compareTo(a));
    final List<M3UItem> finalPool = [];
    int uniqueCount = 0;

    for (int i = 0; i < sortedYears.length; i++) {
      final year = sortedYears[i];
      final itemsForYear = moviesByYear[year]!;
      uniqueCount += itemsForYear.length;

      if (i == 0) {
        // CAPA 1 (ESTRENOS): Les damos peso triple (3x) para que dominen el banner.
        for (var item in itemsForYear) {
          finalPool.add(item);
          finalPool.add(item);
          finalPool.add(item);
        }
      } else {
        // CAPAS DE VARIEDAD: Probabilidad normal (1x).
        finalPool.addAll(itemsForYear);
      }

      // Si ya tenemos al menos 10 títulos únicos, paramos para mantener la relevancia.
      if (uniqueCount >= 10) break;
    }

    // 5. Selección final.
    _setHeroRandomly(finalPool.isNotEmpty ? finalPool : validPool);
  }

  void _setHeroRandomly(List<M3UItem> pool) {
    if (pool.isEmpty) return;
    final randomIndex = DateTime.now().microsecond % pool.length;
    setState(() {
      _heroItem = pool[randomIndex];
    });
  }

  List<String> _getDynamicSearchSuggestions() {
    final pool = [..._m3uService.getRecentItems(), ..._m3uService.latestItems];

    if (pool.isEmpty) {
      return ['Películas y series...'];
    }

    // 1. Find max year
    int maxYear = 0;
    final regexYear = RegExp(r'\((\d{4})\)');

    for (var item in pool) {
      final match = regexYear.firstMatch(item.name);
      if (match != null) {
        final year = int.tryParse(match.group(1) ?? '');
        if (year != null && year > maxYear && year < 2100) {
          maxYear = year;
        }
      }
    }

    // 2. Filter by last 2 years (maxYear and maxYear - 1)
    var candidates = pool;
    if (maxYear > 0) {
      candidates =
          pool.where((item) {
            final match = regexYear.firstMatch(item.name);
            if (match != null) {
              final year = int.tryParse(match.group(1) ?? '');
              return year != null && year >= (maxYear - 1);
            }
            return false;
          }).toList();
    }

    // Fallback if filtering removed everything (unlikely if maxYear was found)
    if (candidates.isEmpty) candidates = pool;

    candidates.shuffle();
    // 3. Return TITLE ONLY (no "Buscar" prefix)
    return candidates
        .where((i) => i.logo != null && i.logo!.isNotEmpty)
        .take(5)
        .map((item) => item.name)
        .toList();
  }

  Widget _buildContinueWatchingSection(
    List<Map<String, dynamic>> continueWatchingItems,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Seguir viendo',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 205, // Standard category row height
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: continueWatchingItems.length,
            itemBuilder: (context, ci) {
              final data = continueWatchingItems[ci];
              final item = data['item'] as M3UItem;
              final progress = data['progress'] as WatchProgress;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 120,
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      if (item.isSeries) {
                        Navigator.push(
                          context,
                          ContentDetailPageRoute(
                            page: ContentDetailScreen(
                              item: item,
                              onToggleFavorite:
                                  (it) => _m3uService.toggleFavorite(it),
                            ),
                          ),
                        ).then((_) {
                          if (mounted) _watchProgressVersion.value++;
                        });
                      } else {
                        _playItem(item);
                      }
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 170, // Standard thumbnail height
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: FastThumbnail(
                                  url: item.logo,
                                  title: item.name,
                                  width: double.infinity,
                                  height: double.infinity,
                                  fit: BoxFit.cover,
                                  cacheWidth: 300,
                                ),
                              ),
                              Center(
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: AppColors.background.withValues(
                                      alpha: 0.5,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.play_arrow,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.vertical(
                                    bottom: Radius.circular(8),
                                  ),
                                  child: LinearProgressIndicator(
                                    value: progress.progressPercentage / 100,
                                    backgroundColor: Colors.black.withValues(
                                      alpha: 0.45,
                                    ),
                                    color: Colors.red.withValues(alpha: 0.85),
                                    minHeight: 4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.name.replaceAll(RegExp(r'\s*\(\d{4}\)'), ''),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildStreamContent() {
    return ListenableBuilder(
      listenable: Listenable.merge([PerformanceService(), _m3uService]),
      builder: (context, _) {
        if (_bottomNavIndex == 1) {
          // My List (Favorites)
          final favorites =
              _m3uService.getFavorites().where((i) => !i.isLive).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const Text(
                      'Mi Lista',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(
                        CupertinoIcons.rectangle_stack_fill_badge_minus,
                        color: Colors.white,
                      ),
                      tooltip: 'Historial',
                      onPressed: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const HistoryScreen(),
                          ),
                        );

                        if (result != null && mounted) {
                          if (result is M3UItem) {
                            _playItem(result);
                          } else if (result is Map &&
                              result['item'] is M3UItem) {
                            _playItem(
                              result['item'] as M3UItem,
                              playlist: result['playlist'] as List<M3UItem>?,
                            );
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child:
                    favorites.isEmpty
                        ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                CupertinoIcons.check_mark_circled,
                                size: 59,
                                color: Colors.grey[800],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Tu lista está vacía',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: 16.4,
                                ),
                              ),
                            ],
                          ),
                        )
                        : Builder(
                          builder: (context) {
                            final screenWidth =
                                MediaQuery.of(context).size.width;
                            final crossAxisCount = (screenWidth / 160)
                                .floor()
                                .clamp(3, 12);
                            return GridView.builder(
                              padding: const EdgeInsets.all(16),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: crossAxisCount,
                                    childAspectRatio: 0.6,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 12,
                                  ),
                              itemCount: favorites.length,
                              itemBuilder:
                                  (context, index) =>
                                      _buildGridCard(favorites[index]),
                            );
                          },
                        ),
              ),
            ],
          );
        }

        // â”€â”€ Contenido principal (tabs Inicio, Películas, Series, etc.) â”€â”€
        // Ya no hay Column con header/tabs fijos encima.
        // Cada tab devuelve un ListView donde el ítem 0 es el header+tabs.

        final displayCategories =
            _m3uService.categories.where((cat) {
              if (cat == 'Inicio' || cat == 'Sin categoría') return false;
              final catLower = cat.toLowerCase();
              if (catLower.contains('apostarias')) return false;
              final excludedCountries = [
                'arabia',
                'argentina',
                'australia',
                'austria',
                'alemania',
                'brasil',
                'belgium',
                'bolivia',
                'bulgaria',
                'canada',
                'chile',
                'china',
                'colombia',
                'costa rica',
                'cuba',
                'croacia',
                'dinamarca',
                'dominicana',
                'ecuador',
                'egipto',
                'españa',
                'estados unidos',
                'filipinas',
                'finlandia',
                'francia',
                'grecia',
                'guatemala',
                'holanda',
                'honduras',
                'hungria',
                'india',
                'indonesia',
                'iran',
                'iraq',
                'irlanda',
                'israel',
                'italia',
                'japon',
                'jordania',
                'korea',
                'kuwait',
                'libano',
                'libia',
                'marruecos',
                'mexico',
                'myanmar',
                'nicaragua',
                'nigeria',
                'noruega',
                'pakistan',
                'panama',
                'paraguay',
                'peru',
                'polonia',
                'portugal',
                'puerto rico',
                'qatar',
                'republica',
                'romania',
                'rusia',
                'salvador',
                'serbia',
                'singapur',
                'siria',
                'suecia',
                'suiza',
                'tailandia',
                'taiwan',
                'tunisia',
                'turquia',
                'ucrania',
                'uk',
                'uruguay',
                'usa',
                'venezuela',
                'vietnam',
                'yemen',
              ];
              for (var country in excludedCountries) {
                if (catLower.contains(country)) return false;
              }
              final excludedKeywords = [
                'adulto',
                'adultos',
                'xxx',
                '+18',
                '18+',
                '24/7',
                '24 7',
                '24-7',
                'canales exclusivos',
                'exclusivo',
                'en vivo',
                'live',
                'tv en vivo',
                'canales',
                'channel',
                'deportes',
                'sport',
                'futbol',
                'football',
                'eventos deportivos',
                'evento',
                'liga',
                'streaming',
                'gratis',
                'free tv',
                'test',
                'ppv',
                'lucha libre',
                'religion',
                'noticias',
                'news',
                'radio',
                'broadcast',
                'directo',
              ];
              for (var keyword in excludedKeywords) {
                if (catLower.contains(keyword)) return false;
              }
              final items = _m3uService.getItemsByCategory(cat);
              final filtered = _m3uService.filterValidItems(items);
              return filtered.length > 2;
            }).toList();

        if (_selectedTab == 'Inicio') {
          final recentItems = _m3uService.getRecentItems();
          final hasRecent = recentItems.isNotEmpty;

          if (_m3uService.items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                _buildScrollableHeader(), // â† header+tabs scrolleable
                _buildM3USourceInput(),
              ],
            );
          }

          return ValueListenableBuilder<int>(
            valueListenable: _watchProgressVersion,
            builder: (context, version, _) {
              return FutureBuilder<List<WatchProgress>>(
                // NOTE: No key here on purpose. FutureBuilder re-executes whenever
                // the `future` object changes identity â€” and each call to getHistory()
                // returns a new Future â€” so the key is redundant. Using key: ValueKey(version)
                // caused the FutureBuilder's element tree to be replaced on every version
                // bump, which unmounted and remounted the inner ListView, briefly attaching
                // _homeScrollController to two scroll positions â†’ assertion crash.
                future: WatchProgressService().getHistory(),
                builder: (context, snapshot) {
                  final history = snapshot.data ?? [];
                  final continueWatchingItems = <Map<String, dynamic>>[];
                  final seenContentKeys = <String>{};

                  for (var progress in history) {
                    final item = _m3uService.resolveItemFromProgress(progress);

                    if (item == null) continue;
                    if (progress.isCompleted) continue;

                    // Dedup by normalized content identity so the same title
                    // saved under different URLs (distinct sources / refreshed
                    // tokens) doesn't appear twice. History is sorted newest
                    // first, so we keep the most recent occurrence.
                    if (!seenContentKeys.add(item.contentKey)) continue;

                    continueWatchingItems.add({
                      'item': item,
                      'progress': progress,
                    });
                  }

                  final homeSections = <Widget>[];

                  // 0. Header + Tabs
                  homeSections.add(_buildScrollableHeader());

                  // 1. Hero
                  final List<M3UItem> heroPool = [];
                  if (_m3uService.movies.isNotEmpty ||
                      _m3uService.series.isNotEmpty) {
                    heroPool.addAll(_m3uService.movies.take(100));
                    heroPool.addAll(_m3uService.series.take(100));
                  } else {
                    final fallback =
                        (recentItems.isNotEmpty
                            ? recentItems
                            : _m3uService.latestItems);
                    heroPool.addAll(fallback.where((i) => !i.isLive));
                  }

                  homeSections.add(_buildHeroRandomLatest(heroPool));

                  // 2. Últimamente nuevo
                  if (hasRecent) {
                    homeSections.add(
                      _buildCategoryRow('Últimamente nuevo', recentItems),
                    );
                  }

                  // 3. Recomendados para ti
                  if (_recommendedItems != null &&
                      _recommendedItems!.isNotEmpty) {
                    homeSections.add(
                      _buildCategoryRow(
                        'Recomendados para ti',
                        _recommendedItems!,
                      ),
                    );
                  }

                  // 4. Seguir viendo
                  if (continueWatchingItems.isNotEmpty) {
                    homeSections.add(
                      _buildContinueWatchingSection(continueWatchingItems),
                    );
                  }

                  // 5. Build dynamic categories with Top 10 injected after the first one
                  final categoriesToLoad =
                      displayCategories.take(_loadedHomeCategories).toList();
                  for (int i = 0; i < categoriesToLoad.length; i++) {
                    final cat = categoriesToLoad[i];
                    homeSections.add(
                      _buildCategoryRow(
                        cat,
                        _m3uService.getItemsByCategory(cat),
                      ),
                    );

                    // Inject Top 10 after the first category
                    if (i == 0) {
                      homeSections.add(_buildTop10Section());
                    }
                  }

                  // If no categories, still add Top 10 at the end if it wasn't added
                  if (displayCategories.isEmpty) {
                    homeSections.add(_buildTop10Section());
                  }

                  if (_isHomeLoadingMore) {
                    homeSections.add(
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: CupertinoActivityIndicator(
                            radius: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    );
                  }

                  return NotificationListener<ScrollNotification>(
                    onNotification: (scrollInfo) {
                      if (scrollInfo.metrics.pixels >=
                          scrollInfo.metrics.maxScrollExtent - 200) {
                        _loadMoreHomeCategories(displayCategories);
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _homeScrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 20),
                      itemCount: homeSections.length,
                      itemBuilder:
                          (context, index) => _RevealOnMount(
                            // Header (0) appears instantly; rows below cascade in.
                            child: homeSections[index],
                          ),
                    ),
                  );
                },
              );
            },
          );
        } else if (_selectedTab == 'Animación') {
          return _buildAnimationContentScrollable();
        } else if (_selectedTab == 'Películas') {
          return _buildMoviesContentScrollable();
        } else if (_selectedTab == 'Series') {
          return _buildSeriesContentScrollable();
        } else if (_selectedTab == 'Telenovelas') {
          final novelaCategories =
              _m3uService.categories.where((cat) {
                if (cat == 'Inicio') return false;
                final c = cat.toLowerCase();
                final isNovela =
                    c.contains('novela') ||
                    c.contains('soap') ||
                    c.contains('item') ||
                    c.contains('turca') ||
                    c.contains('turco') ||
                    c.contains('dorama') ||
                    c.contains('telemundo') ||
                    c.contains('televisa') ||
                    c.contains('biblica') ||
                    c.contains('pasion');
                if (!isNovela) return false;
                final items = _m3uService.getItemsByCategory(cat);
                final filtered = _m3uService.filterValidItems(items);
                return filtered.length > 2;
              }).toList();

          final allNovelaItems = <M3UItem>[];
          for (var cat in novelaCategories) {
            allNovelaItems.addAll(_m3uService.getItemsByCategory(cat));
          }

          final curatedNovelaSections = ContentFilters.curatedNovelaSections;
          final curatedNovelaLists = <Map<String, dynamic>>[];
          for (var section in curatedNovelaSections) {
            final keywords = section['keywords'] as List<String>;
            final items =
                allNovelaItems
                    .where((item) {
                      final nameLower = item.name.toLowerCase();
                      final catLower = item.category.toLowerCase();
                      for (var keyword in keywords) {
                        if (nameLower.contains(keyword) ||
                            catLower.contains(keyword)) {
                          return true;
                        }
                      }
                      return false;
                    })
                    .take(30)
                    .toList();
            final filteredItems = _m3uService.filterValidItems(items);
            if (filteredItems.length > 3) {
              curatedNovelaLists.add({
                'title': section['title'],
                'items': filteredItems,
              });
            }
          }

          final novelaSections = <Widget>[];
          novelaSections.add(_buildScrollableHeader());
          novelaSections.add(
            _buildSectionHeroBanner('novelas', allNovelaItems),
          );
          final novelaUrls = allNovelaItems.map((e) => e.url).toSet();
          final recentNovelas =
              _m3uService
                  .getRecentItems()
                  .where((i) => !i.isLive && novelaUrls.contains(i.url))
                  .take(50)
                  .toList();
          if (recentNovelas.length > 5) {
            novelaSections.add(
              _buildCategoryRow('Últimamente nuevo', recentNovelas),
            );
          }
          novelaSections.add(
            _buildCategoryRow('Todas las Telenovelas', allNovelaItems),
          );

          for (final curated in curatedNovelaLists) {
            novelaSections.add(
              _buildCategoryRow(curated['title'], curated['items']),
            );
          }

          final categoriesToLoad =
              novelaCategories.take(_loadedNovelaCategories).toList();
          for (final cat in categoriesToLoad) {
            novelaSections.add(
              _buildCategoryRow(cat, _m3uService.getItemsByCategory(cat)),
            );
          }

          if (_isNovelasLoadingMore) {
            novelaSections.add(
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: CupertinoActivityIndicator(
                    radius: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            );
          }

          return NotificationListener<ScrollNotification>(
            onNotification: (scrollInfo) {
              if (scrollInfo.metrics.pixels >=
                  scrollInfo.metrics.maxScrollExtent - 200) {
                _loadMoreNovelaCategories(novelaCategories);
              }
              return false;
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 20),
              itemCount: novelaSections.length,
              itemBuilder: (context, index) => novelaSections[index],
            ),
          );
        } else if (_selectedTab == 'Tesoros Especiales') {
          final otherCategories =
              _m3uService.categories.where((cat) {
                final c = cat.toLowerCase();
                final isFixed =
                    c.contains('pelicula') ||
                    c.contains('cine') ||
                    c.contains('movie') ||
                    c.contains('serie') ||
                    c.contains('novela') ||
                    cat == 'Inicio' ||
                    cat == 'Sin categoría';
                final items = _m3uService.getItemsByCategory(cat);
                final filtered = _m3uService.filterValidItems(items);
                return !isFixed && filtered.length > 2;
              }).toList();

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 20),
            children: [
              _buildScrollableHeader(), // â† header+tabs
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Builder(
                  builder: (context) {
                    final screenWidth = MediaQuery.of(context).size.width;
                    final crossAxisCount = (screenWidth / 180).floor().clamp(
                      2,
                      6,
                    );
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: 1.5,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: otherCategories.length,
                      itemBuilder: (context, index) {
                        final cat = otherCategories[index];
                        return _buildCategoryCard(cat);
                      },
                    );
                  },
                ),
              ),
            ],
          );
        } else {
          // Dynamic Tab
          final rawItems = _m3uService.getItemsByCategory(_selectedTab);
          final tabItems = _m3uService.filterValidItems(rawItems);
          return ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: 1 + 1, // header+tabs + contenido
            itemBuilder: (context, index) {
              if (index == 0) {
                return _buildScrollableHeader(); // â† header+tabs
              }
              if (tabItems.isNotEmpty) {
                return _buildCategoryRow(_selectedTab, tabItems);
              } else {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: Text(
                      'Ups, No hay contenido disponible',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                );
              }
            },
          );
        }
      },
    );
  }

  Widget _buildMoviesContentScrollable() {
    final movies = _m3uService.movies.where((i) => !i.isLive).toList();

    if (movies.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [_buildScrollableHeader()],
      );
    }

    final movieCategories =
        _m3uService.categories.where((cat) {
          if (cat == 'Inicio' || cat == 'Sin categoría') return false;
          final c = cat.toLowerCase();
          final excludedCountries = ContentFilters.excludedCountries;
          for (var country in excludedCountries) {
            if (c.contains(country)) return false;
          }
          final excludedKeywords = ContentFilters.excludedKeywords;
          for (var keyword in excludedKeywords) {
            if (c.contains(keyword)) return false;
          }
          final items = _m3uService.getItemsByCategory(cat);
          if (items.isEmpty) return false;
          final filtered =
              items.where((i) => !i.isSeries && !i.isLive).toList();
          final validItems = _m3uService.filterValidItems(filtered);
          return validItems.length > 2;
        }).toList();

    final recentMovies =
        _m3uService
            .getRecentItems()
            .where((i) => !i.isSeries && !i.isLive)
            .take(50)
            .toList();

    final movieSections = <Widget>[];
    movieSections.add(_buildScrollableHeader());
    movieSections.add(_buildSectionHeroBanner('movies', movies));
    if (recentMovies.length > 5) {
      movieSections.add(_buildCategoryRow('Últimamente nuevo', recentMovies));
    }
    movieSections.add(_buildCategoryRow('Todas las Películas', movies));

    final categoriesToLoad =
        movieCategories.take(_loadedMovieCategories).toList();
    for (final cat in categoriesToLoad) {
      final catItems =
          _m3uService
              .getItemsByCategory(cat)
              .where((i) => !i.isSeries && !i.isLive)
              .toList();
      movieSections.add(_buildCategoryRow(cat, catItems));
    }

    if (_isMoviesLoadingMore) {
      movieSections.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: CupertinoActivityIndicator(radius: 14, color: Colors.white),
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        if (scrollInfo.metrics.pixels >=
            scrollInfo.metrics.maxScrollExtent - 200) {
          _loadMoreMovieCategories(movieCategories);
        }
        return false;
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 20),
        itemCount: movieSections.length,
        itemBuilder: (context, index) => movieSections[index],
      ),
    );
  }

  Widget _buildSeriesContentScrollable() {
    final series = _m3uService.series;

    final recentSeries =
        _m3uService
            .getRecentItems()
            .where((i) => i.isSeries && !i.isLive)
            .take(50)
            .toList();

    final seriesCategories =
        _m3uService.categories.where((cat) {
          if (cat == 'Inicio') return false;
          final c = cat.toLowerCase();
          final excluded = ContentFilters.seriesExclusions;
          for (var keyword in excluded) {
            if (c.contains(keyword)) return false;
          }
          if (c.contains('serie') ||
              c.contains('season') ||
              c.contains('temporada')) {
            final items = _m3uService.getItemsByCategory(cat);
            final filtered = _m3uService.filterValidItems(items);
            return filtered.length > 2;
          }
          final items = _m3uService.getItemsByCategory(cat);
          if (items.isEmpty) return false;
          final filtered = items.where((i) => i.isSeries && !i.isLive).toList();
          final validItems = _m3uService.filterValidItems(filtered);
          return validItems.length > 2;
        }).toList();

    final curatedSections = ContentFilters.curatedSeriesSections;
    final curatedLists = <Map<String, dynamic>>[];
    for (var section in curatedSections) {
      final keywords = section['keywords'] as List<String>;
      final items =
          series
              .where((item) {
                final nameLower = item.name.toLowerCase();
                final catLower = item.category.toLowerCase();
                for (var keyword in keywords) {
                  if (nameLower.contains(keyword) ||
                      catLower.contains(keyword)) {
                    return true;
                  }
                }
                return false;
              })
              .take(30)
              .toList();
      final filteredItems = _m3uService.filterValidItems(items);
      if (filteredItems.length > 3) {
        curatedLists.add({'title': section['title'], 'items': filteredItems});
      }
    }

    final seriesSections = <Widget>[];
    seriesSections.add(_buildScrollableHeader());
    seriesSections.add(_buildSectionHeroBanner('series', series));
    if (recentSeries.length > 5) {
      seriesSections.add(_buildCategoryRow('Últimamente nuevo', recentSeries));
    }
    seriesSections.add(_buildCategoryRow('Todas las Series', series));

    for (final curated in curatedLists) {
      seriesSections.add(_buildCategoryRow(curated['title'], curated['items']));
    }

    final categoriesToLoad =
        seriesCategories.take(_loadedSeriesCategories).toList();
    for (final cat in categoriesToLoad) {
      final catItems =
          _m3uService
              .getItemsByCategory(cat)
              .where((i) => i.isSeries && !i.isLive)
              .toList();
      seriesSections.add(_buildCategoryRow(cat, catItems));
    }

    if (_isSeriesLoadingMore) {
      seriesSections.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: CupertinoActivityIndicator(radius: 14, color: Colors.white),
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        if (scrollInfo.metrics.pixels >=
            scrollInfo.metrics.maxScrollExtent - 200) {
          _loadMoreSeriesCategories(seriesCategories);
        }
        return false;
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 20),
        itemCount: seriesSections.length,
        itemBuilder: (context, index) => seriesSections[index],
      ),
    );
  }

  Widget _buildAnimationContentScrollable() {
    // Gather all animation-related categories
    final animationCategories =
        _m3uService.categories.where((cat) {
          if (cat == 'Inicio') return false;
          final c = cat.toLowerCase();
          final isAnimation =
              c.contains('anim') ||
              c.contains('anime') ||
              c.contains('cartoon') ||
              c.contains('caricatura') ||
              c.contains('dibujo') ||
              c.contains('disney') ||
              c.contains('pixar') ||
              c.contains('manga') ||
              c.contains('kids') ||
              c.contains('infantil') ||
              c.contains('nickelodeon') ||
              c.contains('nick') ||
              c.contains('toonami') ||
              c.contains('crunchyroll') ||
              c.contains('funimation');
          if (!isAnimation) return false;
          final items = _m3uService.getItemsByCategory(cat);
          final filtered = _m3uService.filterValidItems(items);
          return filtered.length > 2;
        }).toList();

    // Gather ALL items from the entire catalog and filter by animation keywords
    final allItems = _m3uService.items;
    final allAnimationItems =
        allItems
            .where((item) {
              final nameLower = item.name.toLowerCase();
              final catLower = item.category.toLowerCase();
              return nameLower.contains('anim') ||
                  nameLower.contains('anime') ||
                  nameLower.contains('cartoon') ||
                  nameLower.contains('caricatura') ||
                  nameLower.contains('dibujo') ||
                  nameLower.contains('disney') ||
                  nameLower.contains('pixar') ||
                  nameLower.contains('manga') ||
                  nameLower.contains('kids') ||
                  nameLower.contains('infantil') ||
                  catLower.contains('anim') ||
                  catLower.contains('anime') ||
                  catLower.contains('cartoon') ||
                  catLower.contains('caricatura') ||
                  catLower.contains('dibujo') ||
                  catLower.contains('disney') ||
                  catLower.contains('pixar') ||
                  catLower.contains('manga') ||
                  catLower.contains('kids') ||
                  catLower.contains('infantil') ||
                  catLower.contains('nickelodeon') ||
                  catLower.contains('nick') ||
                  catLower.contains('toonami') ||
                  catLower.contains('crunchyroll') ||
                  catLower.contains('funimation');
            })
            .where((i) => !i.isLive)
            .toList();

    // Also collect items from animation categories
    for (var cat in animationCategories) {
      final catItems = _m3uService.getItemsByCategory(cat);
      for (var item in catItems) {
        if (!allAnimationItems.contains(item) && !item.isLive) {
          allAnimationItems.add(item);
        }
      }
    }

    final curatedAnimationSections = ContentFilters.curatedAnimationSections;
    final curatedAnimationLists = <Map<String, dynamic>>[];
    for (var section in curatedAnimationSections) {
      final keywords = section['keywords'] as List<String>;
      final items =
          allAnimationItems
              .where((item) {
                final nameLower = item.name.toLowerCase();
                final catLower = item.category.toLowerCase();
                for (var keyword in keywords) {
                  if (nameLower.contains(keyword) ||
                      catLower.contains(keyword)) {
                    return true;
                  }
                }
                return false;
              })
              .take(30)
              .toList();
      final filteredItems = _m3uService.filterValidItems(items);
      if (filteredItems.length > 3) {
        curatedAnimationLists.add({
          'title': section['title'],
          'items': filteredItems,
        });
      }
    }

    final animationSections = <Widget>[];
    animationSections.add(_buildScrollableHeader());

    if (allAnimationItems.isNotEmpty) {
      animationSections.add(
        _buildSectionHeroBanner('animation', allAnimationItems),
      );
      final animationUrls = allAnimationItems.map((e) => e.url).toSet();
      final recentAnimation =
          _m3uService
              .getRecentItems()
              .where((i) => !i.isLive && animationUrls.contains(i.url))
              .take(50)
              .toList();
      if (recentAnimation.length > 5) {
        animationSections.add(
          _buildCategoryRow('Últimamente nuevo', recentAnimation),
        );
      }
      animationSections.add(
        _buildCategoryRow('Todo el Contenido Animado', allAnimationItems),
      );
    }

    for (final curated in curatedAnimationLists) {
      animationSections.add(
        _buildCategoryRow(curated['title'], curated['items']),
      );
    }

    final categoriesToLoad =
        animationCategories.take(_loadedAnimationCategories).toList();
    for (final cat in categoriesToLoad) {
      animationSections.add(
        _buildCategoryRow(cat, _m3uService.getItemsByCategory(cat)),
      );
    }

    if (_isAnimationLoadingMore) {
      animationSections.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: CupertinoActivityIndicator(radius: 14, color: Colors.white),
          ),
        ),
      );
    }

    if (allAnimationItems.isEmpty && animationCategories.isEmpty) {
      animationSections.add(
        const Center(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: Text(
              'No se encontró contenido de animación.',
              style: TextStyle(color: Colors.white60, fontSize: 15),
            ),
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        if (scrollInfo.metrics.pixels >=
            scrollInfo.metrics.maxScrollExtent - 200) {
          _loadMoreAnimationCategories(animationCategories);
        }
        return false;
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 20),
        itemCount: animationSections.length,
        itemBuilder: (context, index) => animationSections[index],
      ),
    );
  }

  /// Static helper: silences mpv, stops playback, waits for the native thread
  /// to drain, then disposes. Because it is static and receives only the raw
  /// [Player] value it does NOT hold a reference to the widget State, so it
  /// can safely outlive `dispose()` without causing a use-after-free in the
  /// Dart â†’ native FFI callback bridge.
  static Future<void> _drainAndDisposePlayer(Player player) async {
    // Step A: Tell mpv to suppress all further log/event output.
    try {
      final mpv = player.platform as dynamic;
      mpv?.setProperty('msg-level', 'all=no');
      mpv?.setProperty('log-level', 'no');
      mpv?.setProperty('vid', 'no');
      mpv?.setProperty('vo', 'null');
    } catch (_) {}

    // Step B: Stop decoding synchronously (best-effort).
    try {
      await player.stop();
    } catch (_) {}

    // Step C: Extra window for Motorola/Android 15 slow Surface release.
    await Future.delayed(const Duration(milliseconds: 900));

    // Step D: Dispose the player now that the native queue has drained.
    try {
      player.dispose();
    } catch (_) {}
  }

  Future<void> _disposeLivePlayer() async {
    // -- CRITICAL DISPOSAL SEQUENCE FOR MOTOROLA/ANDROID 15 --
    // Set guard FIRST so _playLiveChannel won't create a new player
    // while this one is still draining its native event queue.
    _isDisposingLivePlayer = true;

    _lastLiveFrameBytesNotifier.value = null;

    _liveDurationTimer?.cancel();
    _liveDurationTimer = null;
    _liveSecondsWatched = 0;
    _liveAdCountdownNotifier.value = null;
    _liveMidRollNoticeShown = false;
    _hasViewedLiveMidRollAd = false;

    _liveHealthMonitorTimer?.cancel();
    _liveHealthMonitorTimer = null;
    _recoveryTimer?.cancel();
    _qualityRestoreTimer?.cancel();
    _qualityRestoreTimer = null;
    _isQualityCapped = false;

    // 1. Cancel Dart-side subscriptions FIRST so no new events reach Dart.
    for (final s in _liveStreamSubscriptions) {
      s.cancel();
    }
    _liveStreamSubscriptions.clear();

    // 2. Capture the player reference before nulling our field.
    final pToStop = _livePlayer;

    // 3. Unmount the Flutter video surface.
    _liveVideoControllerNotifier.value = null;
    _liveVideoController = null;

    // 4. Null our Dart reference immediately so the GC won't keep a second
    //    path alive while the static helper drains the native queue.
    _livePlayer = null;
    _currentLiveChannel = null;
    _isLiveLoading = false;
    _isLiveReloading = false;
    _isLiveError = false;
    _liveRetryCount = 0;
    _liveSpeedNotifier.value = '0 B/s';
    WakelockPlus.disable();

    // 5. Hand off to the static helper â€” this runs detached from the widget
    //    so it is safe even when called from dispose() (which is void/sync).
    if (pToStop != null) {
      unawaited(_drainAndDisposePlayer(pToStop));
    }

    _isDisposingLivePlayer = false;
  }

  // PRE-RESOLVER DNS del servidor de video via Cloudflare
  // Esto elimina los ~200-400ms de latencia DNS desde Colombia
  Future<void> _prewarmDns(String url) async {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      // Cloudflare DNS-over-HTTPS
      await http
          .get(
            Uri.parse('https://cloudflare-dns.com/dns-query?name=$host&type=A'),
            headers: {'Accept': 'application/dns-json'},
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Para señales EN VIVO, NO debemos rutear el streaming por el Worker de Cloudflare,
  /// ya que los cortafuegos de los servidores de IPTV (XUI.one, Cloudflare, etc.) detectan
  /// y bloquean las peticiones provenientes de IPs de centros de datos de Cloudflare (403/503).
  /// Además, las playlists en vivo (.m3u8) son dinámicas y cambian constantemente.
  /// Mantenemos la función para conservar compatibilidad con el resto del código, pero
  /// retornamos la URL original directa. La aceleración se logra gracias al DNS Prewarming paralelo.
  String _resolveStreamUrl(String url) {
    return url;
  }

  Future<void> _startLivePlayback(M3UItem item) async {
    if (!mounted) return;

    _lastLiveFrameBytesNotifier.value = null;
    setState(() => _isLiveLoading = true);

    if (_livePlayer == null) {
      _livePlayer = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 256 * 1024 * 1024, // 256 MB
          title: 'Bump Comba Live',
          logLevel: MPVLogLevel.error, // minimum available level
        ),
      );

      // -- CRITICAL SILENCING --
      // Mute native engine IMMEDIATELY to prevent orphan threads
      // from firing callbacks during/after a Hot Restart.
      try {
        final mpv = _livePlayer!.platform as dynamic;
        mpv?.setProperty('terminal', 'no');
        mpv?.setProperty('msg-level', 'all=no');
      } catch (_) {}

      _liveVideoController = VideoController(
        _livePlayer!,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration:
              true, // HW decoding = menos CPU, más fluidez
        ),
      );
      _liveVideoControllerNotifier.value = _liveVideoController;

      // Reload automático en fin de stream
      // Watchdog reactivo: cuando buffering se activa, iniciar conteo
      _liveStreamSubscriptions.add(
        _livePlayer!.stream.buffering.listen((isBuffering) {
          if (!mounted) return;
          if (isBuffering) {
            // Solo mostrar spinner â€” el timer periódico maneja el reload
            setState(() => _isLiveLoading = true);
          } else {
            setState(() => _isLiveLoading = false);
          }
        }),
      );

      // Reload automático en error de red
      _liveStreamSubscriptions.add(
        _livePlayer!.stream.error.listen((error) {
          debugPrint('Player error: $error');
          if (mounted && !_isLiveError) {
            setState(() {
              _isLiveReloading = false;
            });
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted) _reloadLiveSignal();
            });
          }
        }),
      );

      _liveDurationTimer?.cancel();
      _liveDurationTimer = Timer.periodic(
        const Duration(seconds: 1),
        _onLiveDurationTick,
      );
    }

    final platform = _livePlayer?.platform as dynamic;
    await _applySeamlessConfig(platform, item);

    final resolvedUrl = _resolveStreamUrl(item.url);
    unawaited(_prewarmDns(item.url));

    // Abrir el stream con headers completos
    try {
      await _livePlayer!.open(
        Media(
          resolvedUrl,
          httpHeaders: {
            'User-Agent': _getRandomUserAgent(),
            'Accept': '*/*',
            'Accept-Encoding': 'gzip, deflate, br',
            'Connection': 'keep-alive',
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
          },
        ),
        play: true,
      );
    } catch (e) {
      debugPrint('Error abriendo stream: $e');
      if (mounted && !_isLiveError) {
        setState(() {
          _isLiveReloading = false;
        });
        _reloadLiveSignal();
        return;
      }
    }

    if (mounted) {
      if (!_isLiveReloading && !_isUsingMirror) {
        _originalLiveChannel = item;
      }

      setState(() {
        _currentLiveChannel = item;
        _isLiveLoading = false;
        _isLiveReloading = false;
        _liveRetryCount = 0;
        // Notificar el nuevo controller para forzar reconstrucción
        // del Video widget y evitar pantalla negra con audio
        _liveVideoControllerNotifier.value = null;
      });

      // Microtask para que Flutter destruya y reconstruya el Video widget
      await Future.microtask(() {});

      if (mounted) {
        setState(() {
          _liveVideoControllerNotifier.value = _liveVideoController;
        });
      }
      _startInlineHideTimer();
      WakelockPlus.enable();
      _startLiveStallMonitor();
    }
  }

  void _onLiveDurationTick(Timer timer) {
    if (_livePlayer == null ||
        !_livePlayer!.state.playing ||
        PremiumService().isPremium ||
        _hasViewedLiveMidRollAd) {
      if (_liveAdCountdownNotifier.value != null) {
        _liveAdCountdownNotifier.value = null;
      }

      // If we already viewed it, cancel the timer
      if (_hasViewedLiveMidRollAd) {
        timer.cancel();
      }
      return;
    }

    _liveSecondsWatched++;

    // 5 minutes (300s): "Anuncio en 2 min..."
    if (_liveSecondsWatched == 300 && !_liveMidRollNoticeShown) {
      _liveMidRollNoticeShown = true;
      if (mounted) {
        SnackBarUtils.showAppSnackBar(context, 'Anuncio en 2 minutos...');
      }
    }

    // 6 min 30 sec (390s): 30s Countdown
    if (_liveSecondsWatched >= 390 && _liveSecondsWatched < 420) {
      final remaining = 420 - _liveSecondsWatched;
      if (_liveAdCountdownNotifier.value != remaining) {
        _liveAdCountdownNotifier.value = remaining;
      }
    } else if (_liveAdCountdownNotifier.value != null) {
      _liveAdCountdownNotifier.value = null;
    }

    // 7 minutes (420s): Trigger Ad
    if (_liveSecondsWatched >= 420) {
      _triggerLiveMidRollAd();
      // Reset for next cycle
      _liveSecondsWatched = 0;
      _liveMidRollNoticeShown = false;
      _hasViewedLiveMidRollAd = true; // Mark ad as viewed for this session
    }
  }

  void _stopLivePlayer() {
    _disposeLivePlayer();
    if (mounted) {
      setState(() {
        _currentLiveChannel = null;
        _liveVideoController = null;
        _liveVideoControllerNotifier.value = null;
      });
    }
    WakelockPlus.disable();
  }

  Future<void> _applySeamlessConfig(dynamic platform, M3UItem item) async {
    if (platform == null) return;
    final url = item.url.toLowerCase();
    _isLiveChannel =
        url.contains('/live/') ||
        url.contains('type=live') ||
        (url.endsWith('.m3u8') && !url.contains('/vod/'));

    Future<void> s(String k, String v) async {
      try {
        await platform.setProperty(k, v);
      } catch (_) {}
    }

    // â”€â”€ CACHÉ: buffer grande + NUNCA pausar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // 60 s de readahead absorbe cualquier micro-corte de red sin que el usuario
    // lo note. cache-pause=no es CRÍTICO: con 'yes' el reproductor para el video
    // al bajar el buffer y el usuario ve pantalla negra.
    await s('cache', 'yes');
    await s('cache-pause', 'no'); // NUNCA pausar por buffer bajo
    await s('cache-pause-initial', 'no');
    await s('cache-pause-wait', '0');
    // Para HLS en vivo, un buffer de readahead de 60s es irreal y puede confundir al reproductor.
    // Usamos 15s para en vivo y 60s para VOD/series/películas.
    await s('cache-secs', _isLiveChannel ? '15' : '60');
    await s('cache-back-buffer-size', '33554432'); // 32 MB atrás
    await s('demuxer-max-bytes', _isLiveChannel ? '20000000' : '150000000');
    await s('demuxer-max-back-bytes', '33554432');
    await s('demuxer-readahead-secs', _isLiveChannel ? '15' : '60');

    // â”€â”€ VIDEO: sin drops, superficie estable â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    await s('framedrop', 'no'); // Sin framedrop = imagen más estable
    await s('video-sync', 'audio');
    await s('vd-lavc-dr', 'no'); // Evita BLASTBufferQueue overflow
    await s('video-latency-hacks', 'yes');
    await s('vo-queue-size', '4');
    await s('opengl-early-flush', 'no');

    // â”€â”€ RED: reconexión instantánea, sin timeouts agresivos â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    await s('network-timeout', '5'); // 5 s antes de declarar error
    await s('http-reconnect', 'yes');
    await s('http-reconnect-max', '999');
    await s('http-reconnect-delay', '0.1');
    await s(
      'stream-lavf-o',
      'reconnect=1,'
          'reconnect_streamed=1,'
          'reconnect_at_eof=1,'
          'reconnect_delay_max=1,'
          'reconnect_on_network_error=1,'
          'reconnect_on_http_error=4xx,5xx,'
          'timeout=3000000,'
          'rw_timeout=3000000,'
          'tcp_nodelay=1,'
          'fflags=nobuffer',
    ); // Reduce latencia de ffmpeg
    await s('tls-verify', 'no');

    // â”€â”€ HEADERS: simular un cliente legítimo â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    await s(
      'http-header-fields',
      'Icy-MetaData:1\r\n'
          'Accept:*/*\r\n'
          'Accept-Language:es-419,es;q=0.9,en;q=0.5\r\n'
          'Accept-Encoding:identity\r\n'
          'Connection:keep-alive\r\n'
          'Cache-Control:no-cache\r\n'
          'Pragma:no-cache',
    );

    // â”€â”€ HLS LIVE â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (_isLiveChannel) {
      await s('hls-bitrate', _isQualityCapped ? '1200000' : 'max');
      await s('hls-forward-for-live', 'yes');
      await s(
        'stream-lavf-o',
        'reconnect=1,'
            'reconnect_streamed=1,'
            'reconnect_at_eof=1,'
            'reconnect_delay_max=1,'
            'reconnect_on_network_error=1,'
            'reconnect_on_http_error=4xx,5xx,'
            'timeout=3000000,'
            'rw_timeout=3000000,'
            'live_start_index=-3,' // 3 segmentos atrás = ~18-30 s de colchón
            'tcp_nodelay=1,'
            'fflags=nobuffer',
      );
      await s('demuxer-lavf-hacks', 'yes');
      await s('demuxer-lavf-o', 'allowed_extensions=ALL,strict=-2');
    }

    // â”€â”€ DECODIFICACIÓN: hardware, relajada para live â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    await s('hwdec', 'auto-safe');
    await s('vd-lavc-threads', '0');
    await s('deinterlace', 'no');
    await s('vd-lavc-skiploopfilter', 'nonref'); // menos agresivo que 'all'
    await s('vd-lavc-skipframe', 'default'); // menos agresivo para live

    // â”€â”€ AUDIO: prioridad máxima â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    await s('audio-buffer', '2.0'); // 2 s de buffer de audio
    await s('audio-stream-silence', 'yes');
    await s('audio-fallback-to-null', 'yes');
    await s('gapless-audio', 'weak');

    // â”€â”€ SINCRONIZACIÓN â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    await s('interpolation', 'no');
    await s('video-timing-offset', '0');
    await s('audio-wait-open', '0');

    // â”€â”€ ROBUSTEZ â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    await s('demuxer-lavf-probescore', '25');
    await s('hr-seek', 'no');
    await s('keep-open', 'yes');
    await s('keep-open-pause', 'no');
    await s('idle', 'yes');
    await s('force-window', 'yes');
    await s('load-unsafe-playlists', 'yes');
    await s('force-seekable', 'yes');
  }

  void _startLiveStallMonitor() {
    _liveHealthMonitorTimer?.cancel();

    // Usamos tiempo de pared para detectar stall real.
    // En live, la posición MPV puede ser inestable (vuelve a 0 al reconectar),
    // así que solo nos fiamos de ella para detectar MOVIMIENTO, no para medir
    // el tiempo exacto de stall.
    int consecutiveStillSeconds = 0;
    Duration prevPosition = Duration.zero;
    bool firstTick = true;

    _liveHealthMonitorTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      if (!mounted || _livePlayer == null) {
        timer.cancel();
        return;
      }
      if (_liveVideoControllerNotifier.value == null) {
        timer.cancel();
        return;
      }
      // Si estamos en medio de un reload, resetear el watchdog y esperar
      if (_isLiveReloading || _isDisposingLivePlayer) {
        consecutiveStillSeconds = 0;
        prevPosition = Duration.zero;
        firstTick = true;
        return;
      }

      final state = _livePlayer!.state;
      final Duration currentPos = state.position;

      if (state.buffering) {
        // Buffering explícito: acumular pero esperar más tiempo
        // antes de hacer algo (la red puede recuperarse sola)
        consecutiveStillSeconds++;

        // Mostrar spinner solo después de 2 s en buffering
        if (consecutiveStillSeconds == 2 && mounted) {
          setState(() => _isLiveLoading = true);
        }

        // Recargar solo si el buffering dura más de 5 s consecutivos
        if (consecutiveStillSeconds >= 5) {
          debugPrint(
            'ðŸ”´ Buffering ${consecutiveStillSeconds}s â†’ seamless reload',
          );
          consecutiveStillSeconds = 0;
          timer.cancel();
          _seamlessReload();
        }
        prevPosition = currentPos;
        return;
      }

      if (!state.playing) {
        // Pausado por el usuario â€” no hacer nada
        consecutiveStillSeconds = 0;
        prevPosition = currentPos;
        firstTick = true;
        if (mounted && _isLiveLoading) setState(() => _isLiveLoading = false);
        return;
      }

      // Player dice que está reproduciendo y no hay buffering:
      // verificar si la posición realmente avanza.
      if (firstTick) {
        prevPosition = currentPos;
        firstTick = false;
        return;
      }

      final bool positionMoved = currentPos != prevPosition;

      if (positionMoved) {
        // Hay movimiento â†’ todo bien, reset watchdog
        consecutiveStillSeconds = 0;
        if (mounted && _isLiveLoading) {
          setState(() => _isLiveLoading = false);
        }
      } else {
        // Posición quieta mientras el player dice que reproduce
        consecutiveStillSeconds++;

        // Mostrar spinner a los 2 s quieto (el usuario empieza a notar)
        if (consecutiveStillSeconds == 2 && mounted) {
          setState(() => _isLiveLoading = true);
        }

        // Recarga seamless a los 3 s quieto
        if (consecutiveStillSeconds >= 3) {
          debugPrint(
            'ðŸ”´ Stream congelado ${consecutiveStillSeconds}s â†’ seamless reload',
          );
          consecutiveStillSeconds = 0;
          timer.cancel();
          _seamlessReload();
        }
      }

      prevPosition = currentPos;
      _updateSpeedIndicator();
    });
  }

  Future<void> _seamlessReload() async {
    if (_isLiveReloading || _isDisposingLivePlayer) return;
    if (_livePlayer == null || _currentLiveChannel == null) return;

    // Capturar screenshot antes del reload para evitar pantalla negra
    try {
      final bytes = await _livePlayer?.screenshot();
      if (bytes != null && mounted) {
        _lastLiveFrameBytesNotifier.value = bytes;
      }
    } catch (_) {}

    _liveRetryCount++;
    _isLiveReloading = true;

    // NO hacer setState aquí â†’ el último frame queda visible, sin pantalla negra.
    // El spinner aparece solo si el _startLiveStallMonitor detecta que seguimos
    // atascados después de la recarga (indicando un problema más profundo).

    try {
      // player.open() en el mismo player = seamless switch:
      // MPV cierra el demuxer viejo y abre uno nuevo SIN destruir el VO (surface).
      // El usuario ve el último frame hasta que llega el primer frame nuevo.
      await _livePlayer!
          .open(
            Media(
              _currentLiveChannel!.url,
              httpHeaders: {
                'User-Agent': _getRandomUserAgent(),
                'Accept': '*/*',
                'Connection': 'keep-alive',
                'Cache-Control': 'no-cache',
                'Pragma': 'no-cache',
                'Accept-Encoding': 'identity',
              },
            ),
            play: true,
          )
          .timeout(const Duration(seconds: 5));

      _liveRetryCount = 0;
      _isLiveReloading = false;
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _lastLiveFrameBytesNotifier.value = null;
          setState(() => _isLiveLoading = false);
        }
      });

      // Si la calidad estaba limitada y llevamos varios reintentos exitosos,
      // restaurar la calidad máxima silenciosamente
      if (_isQualityCapped && _liveRetryCount == 0) {
        _qualityRestoreTimer?.cancel();
        _qualityRestoreTimer = Timer(const Duration(minutes: 2), () async {
          if (!mounted || !_isQualityCapped) return;
          _isQualityCapped = false;
          try {
            await (_livePlayer?.platform as dynamic)?.setProperty(
              'hls-bitrate',
              'max',
            );
            debugPrint('âœ… Calidad restaurada a máxima');
          } catch (_) {}
        });
      }
    } catch (e) {
      debugPrint('Seamless reload falló ($e) â†’ intento $_liveRetryCount');
      _isLiveReloading = false;

      if (_liveRetryCount <= 4) {
        // Backoff exponencial suave: 500 ms, 1 s, 2 s, 4 s
        final delay = Duration(
          milliseconds: 500 * (1 << (_liveRetryCount - 1).clamp(0, 3)),
        );
        await Future.delayed(delay);
        if (mounted) _seamlessReload();
      } else if (_liveRetryCount <= 7) {
        // Reinicio completo del player (más invasivo, último recurso antes del mirror)
        final channel = _currentLiveChannel!;
        final count = _liveRetryCount;
        await _disposeLivePlayer();
        if (!mounted) return;
        _liveRetryCount = count;
        _currentLiveChannel = channel;
        await _startLivePlayback(channel);
      } else {
        // Mirror o error final
        _liveRetryCount = 0;
        if (!_isUsingMirror) {
          _startMirrorPlayback();
        } else {
          if (mounted) {
            setState(() {
              _isLiveError = true;
              _isLiveLoading = false;
              _isLiveReloading = false;
            });
            _lastLiveFrameBytesNotifier.value = null;
          }
        }
      }
      return;
    }

    // Reiniciar el monitor después de 2 s para que el codec se estabilice
    await Future.delayed(const Duration(seconds: 2));
    if (mounted && _livePlayer != null && _currentLiveChannel != null) {
      _startLiveStallMonitor();
    }
  }

  // _doImmediateReload y _quickReopenStream eliminados â€” todo pasa por _seamlessReload()

  void _updateSpeedIndicator() {
    try {
      final platform = _livePlayer!.platform as dynamic;
      double? bitrate;
      try {
        final br = platform.getProperty('bitrate');
        if (br != null) bitrate = double.tryParse(br.toString());
      } catch (_) {}
      if (bitrate != null && bitrate > 0) {
        final kbps = bitrate / 1024;
        _liveSpeedNotifier.value =
            kbps > 1024
                ? '${(kbps / 1024).toStringAsFixed(1)} MB/s'
                : '${kbps.toStringAsFixed(0)} KB/s';
      } else {
        _liveSpeedNotifier.value = '-- KB/s';
      }
    } catch (_) {
      _liveSpeedNotifier.value = '...';
    }
  }

  Future<void> _reloadLiveSignal() async {
    if (!mounted ||
        _currentLiveChannel == null ||
        _isLiveReloading ||
        _isLiveError) {
      return;
    }

    if (_liveRetryCount >= 2 && !_isQualityCapped) {
      _isQualityCapped = true;
      try {
        await (_livePlayer!.platform as dynamic)?.setProperty(
          'hls-bitrate',
          '1200000',
        );
      } catch (_) {}
    }

    // Usar el reload seamless unificado â€” sin pantalla negra
    await _seamlessReload();
  }

  Future<void> _startMirrorPlayback() async {
    if (!mounted || _currentLiveChannel == null) return;

    final mirror = M3UService().findMirrorChannel(_currentLiveChannel!);

    if (mirror != null) {
      debugPrint('Mirror encontrado: ${mirror.name} (${mirror.url})');

      // Guardar referencia al canal original ANTES de cambiar estado
      _originalLiveChannel = _currentLiveChannel;
      _isUsingMirror = true;

      if (mounted) {
        setState(() {
          _isLiveLoading = true;
          _isLiveReloading = true;
        });
      }

      // Capturar screenshot antes del mirror para evitar pantalla negra
      try {
        final bytes = await _livePlayer?.screenshot();
        if (bytes != null && mounted) {
          _lastLiveFrameBytesNotifier.value = bytes;
        }
      } catch (_) {}

      // Seamless: abrir el mirror en el MISMO player sin destruir el surface.
      // El usuario ve el último frame del canal original mientras conecta el mirror.
      try {
        await _livePlayer!
            .open(
              Media(
                mirror.url,
                httpHeaders: {
                  'User-Agent': _getRandomUserAgent(),
                  'Accept': '*/*',
                  'Connection': 'keep-alive',
                  'Cache-Control': 'no-cache',
                  'Pragma': 'no-cache',
                  'Accept-Encoding': 'identity',
                  'icy-metadata': '1',
                },
              ),
              play: true,
            )
            .timeout(const Duration(seconds: 6));

        if (mounted) {
          setState(() {
            _currentLiveChannel = mirror;
            _isLiveReloading = false;
            _liveRetryCount = 0;
          });
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              _lastLiveFrameBytesNotifier.value = null;
              setState(() => _isLiveLoading = false);
            }
          });
          _startLiveStallMonitor();
          _startBackgroundRecovery();
        }
      } catch (e) {
        debugPrint('Mirror falló: $e â†’ error final');
        _isUsingMirror = false;
        _originalLiveChannel = null;
        if (mounted) {
          setState(() {
            _isLiveReloading = false;
            _isLiveLoading = false;
            _isLiveError = true;
          });
          SnackBarUtils.showAppSnackBar(
            context,
            'No se pudo restablecer la señal. Intenta con otro canal.',
          );
        }
      }
    } else {
      debugPrint('Sin mirror para ${_currentLiveChannel!.name}');
      if (mounted) {
        setState(() {
          _isLiveReloading = false;
          _isLiveLoading = false;
          _isLiveError = true;
        });
        SnackBarUtils.showAppSnackBar(
          context,
          'No se pudo restablecer la señal. Intenta con otro canal.',
        );
      }
    }
  }

  void _startBackgroundRecovery() {
    _recoveryTimer?.cancel();
    // Check every 60 seconds if the original channel is back online
    _recoveryTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      _checkOriginalChannel();
    });
  }

  Future<void> _checkOriginalChannel() async {
    if (!mounted || _originalLiveChannel == null || !_isUsingMirror) {
      _recoveryTimer?.cancel();
      return;
    }

    try {
      final response = await http
          .head(
            Uri.parse(_originalLiveChannel!.url),
            headers: {'User-Agent': _getRandomUserAgent()},
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode >= 200 && response.statusCode < 400) {
        debugPrint('Canal original recuperado â†’ volviendo seamless');
        _recoveryTimer?.cancel();

        if (!mounted) return;

        final original = _originalLiveChannel!;
        _originalLiveChannel = null;
        _isUsingMirror = false;

        // Capturar screenshot antes de volver al original para evitar pantalla negra
        try {
          final bytes = await _livePlayer?.screenshot();
          if (bytes != null && mounted) {
            _lastLiveFrameBytesNotifier.value = bytes;
          }
        } catch (_) {}

        // Seamless: abrir original en el mismo player sin destruir surface
        try {
          await _livePlayer!
              .open(
                Media(
                  original.url,
                  httpHeaders: {
                    'User-Agent': _getRandomUserAgent(),
                    'Accept': '*/*',
                    'Connection': 'keep-alive',
                    'Cache-Control': 'no-cache',
                    'Pragma': 'no-cache',
                    'Accept-Encoding': 'identity',
                  },
                ),
                play: true,
              )
              .timeout(const Duration(seconds: 6));

          if (mounted) {
            setState(() {
              _currentLiveChannel = original;
              _isLiveReloading = false;
            });
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted) {
                _lastLiveFrameBytesNotifier.value = null;
                setState(() => _isLiveLoading = false);
              }
            });
            _startLiveStallMonitor();
            SnackBarUtils.showAppSnackBar(
              context,
              'âœ“ Señal principal restaurada',
            );
          }
        } catch (_) {
          // Si el original falla al volver, quedarse en el mirror
          _isUsingMirror = true;
          _originalLiveChannel = original;
          _lastLiveFrameBytesNotifier.value = null;
          _startBackgroundRecovery(); // reintentar en 60s
        }
      } else {
        debugPrint('Canal original aún caído (${response.statusCode})');
      }
    } catch (e) {
      debugPrint('Canal original aún caído: $e');
    }
  }

  void _triggerLiveMidRollAd() {
    if (!mounted || _livePlayer == null) return;

    _livePlayer!.pause();
    if (mounted) {
      AdService().showRewardedAdWithConfirmation(
        context,
        onUserEarnedReward: () {
          if (mounted && _livePlayer != null) {
            _livePlayer!.play();
          }
        },
        onAdFailed: () {
          if (mounted && _livePlayer != null) {
            _livePlayer!.play();
          }
        },
        onCancel: () {
          // User dismissed the ad, stop everything and go back to placeholder
          if (mounted) {
            _stopLivePlayer();
            setState(() {
              _currentLiveChannel = null;
              _liveVideoController = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orangeAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Debes ver el anuncio para continuar viendo.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                backgroundColor: AppColors.background,
                behavior: SnackBarBehavior.floating,
                margin: const EdgeInsets.all(16),
                duration: const Duration(seconds: 4),
                shape: RoundedRectangleBorder(
                  side: const BorderSide(color: Colors.white12, width: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            );
          }
        },
        message: 'Para seguir disfrutando de la TV en vivo, mira un anuncio.',
      );
    }
  }

  // _performSearch removed

  Widget _buildScrollableHeader() {
    return Column(
      children: [
        _buildHeaderSearch(),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: _fixedTabs.map((tab) => _buildTab(tab)).toList(),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildTab(String title) {
    bool isSelected = _selectedTab == title;
    return GestureDetector(
      onTap: () {
        if (_selectedTab == title) return;
        HapticFeedback.selectionClick();
        setState(() {
          _selectedTab = title;
        });
      },
      child: Container(
        margin: const EdgeInsets.only(right: 9),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border:
              isSelected
                  ? Border(
                    bottom: BorderSide(
                      color: Colors.red.withValues(alpha: 0.8),
                      width: 2,
                    ),
                  )
                  : null,
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white60,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  void _showStreamBrowserConfig() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => const StreamBrowserConfigScreen(),
      ),
    );

    if (result == true) {
      // Refresh when coming back if significant sources/mode changed
      setState(() => _isLoading = true);
      await _initService();
    } else {
      // Just rebuild UI to pick up any non-data settings changes
      setState(() {});
    }
  }

  /// Selecciona un ítem destacado desde [rawPool] aplicando el mismo algoritmo
  /// adaptativo por año que usa el hero del Inicio (estrenos con peso 3x).
  M3UItem? _selectHeroFromPool(List<M3UItem> rawPool) {
    final validPool =
        _m3uService.filterValidItems(rawPool).where((item) {
          if (item.isLive || item.sourceName == 'Supabase') return false;
          final n = item.name.toLowerCase();
          if (n.contains('canal ') ||
              n.contains('tv ') ||
              n.contains('en vivo')) {
            return false;
          }
          return true;
        }).toList();

    if (validPool.isEmpty) return null;

    // Agrupar por año detectado en el nombre.
    final Map<int, List<M3UItem>> byYear = {};
    final yearRegex = RegExp(r'(\d{4})');
    for (var item in validPool) {
      final matches = yearRegex.allMatches(item.name);
      if (matches.isNotEmpty) {
        final year = int.tryParse(matches.last.group(1) ?? '');
        if (year != null && year >= 1950 && year <= 2100) {
          byYear.putIfAbsent(year, () => []).add(item);
        }
      }
    }

    if (byYear.isEmpty) {
      return validPool[DateTime.now().microsecond % validPool.length];
    }

    // Algoritmo adaptativo con pesos: estrenos (año más reciente) 3x.
    final sortedYears = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
    final List<M3UItem> finalPool = [];
    int uniqueCount = 0;
    for (int i = 0; i < sortedYears.length; i++) {
      final itemsForYear = byYear[sortedYears[i]]!;
      uniqueCount += itemsForYear.length;
      if (i == 0) {
        for (var item in itemsForYear) {
          finalPool.add(item);
          finalPool.add(item);
          finalPool.add(item);
        }
      } else {
        finalPool.addAll(itemsForYear);
      }
      if (uniqueCount >= 10) break;
    }

    final pool = finalPool.isNotEmpty ? finalPool : validPool;
    return pool[DateTime.now().microsecond % pool.length];
  }

  /// Hero banner por sección (Películas, Series, etc.). Reutiliza la misma UI y
  /// lógica del hero del Inicio, pero con contenido propio de cada sección y
  /// cacheado por sesión para que no cambie en cada rebuild.
  Widget _buildSectionHeroBanner(String section, List<M3UItem> pool) {
    var hero = _sectionHeroItems[section];
    if (hero == null) {
      final selected = _selectHeroFromPool(pool);
      if (selected == null) return const SizedBox.shrink();
      _sectionHeroItems[section] = selected;
      hero = selected;
    }
    return _buildHeroBanner(hero);
  }

  Widget _buildHeroRandomLatest(List<M3UItem> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    if (_heroItem != null) return _buildHeroBanner(_heroItem!);

    // â”€â”€ PRIORIDAD TMDB: Intentar usar contenido trending de TMDB â”€â”€
    final trendingItems = _m3uService.getTrendingBannerItems();
    if (trendingItems.isNotEmpty) {
      final random =
          trendingItems[DateTime.now().microsecond % trendingItems.length];
      return _buildHeroBanner(random);
    }

    // Fallback logic filtrando películas y series
    final validContent =
        items.where((i) => !i.isLive && i.sourceName != 'Supabase').where((i) {
          final n = i.name.toLowerCase();
          return !n.contains('canal ') &&
              !n.contains('tv ') &&
              !n.contains('en vivo');
        }).toList();

    if (validContent.isEmpty) {
      return const _HiddenMoviesShimmer();
    }

    // Algoritmo adaptativo también en el fallback
    final Map<int, List<M3UItem>> itemsByYear = {};
    final yearRegex = RegExp(r'(\d{4})');

    for (var item in validContent) {
      final matches = yearRegex.allMatches(item.name);
      if (matches.isNotEmpty) {
        final yearStr = matches.last.group(1) ?? '';
        final year = int.tryParse(yearStr);
        if (year != null && year >= 1950 && year <= 2100) {
          itemsByYear.putIfAbsent(year, () => []).add(item);
        }
      }
    }

    List<M3UItem> pool = validContent;
    if (itemsByYear.isNotEmpty) {
      final sortedYears =
          itemsByYear.keys.toList()..sort((a, b) => b.compareTo(a));
      final List<M3UItem> adaptivePool = [];
      int uniqueCount = 0;

      for (int i = 0; i < sortedYears.length; i++) {
        final year = sortedYears[i];
        final itemsForYear = itemsByYear[year]!;
        uniqueCount += itemsForYear.length;

        if (i == 0) {
          // Peso 3x para el año más reciente incluso en el fallback
          for (var item in itemsForYear) {
            adaptivePool.add(item);
            adaptivePool.add(item);
            adaptivePool.add(item);
          }
        } else {
          adaptivePool.addAll(itemsForYear);
        }
        if (uniqueCount >= 10) break;
      }
      pool = adaptivePool.isNotEmpty ? adaptivePool : validContent;
    }

    final random = pool[DateTime.now().microsecond % pool.length];
    return _buildHeroBanner(random);
  }

  Widget _buildM3USourceInput() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white10),
          boxShadow:
              PerformanceService().shouldShowComplexShadows
                  ? [
                    BoxShadow(
                      color: const Color(0xFF0a0a0a).withValues(alpha: 0.5),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ]
                  : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(CupertinoIcons.link, color: Colors.red, size: 32),
            const SizedBox(height: 16),
            const Text(
              'Configura tu fuente',
              style: TextStyle(
                color: Colors.white,
                fontSize: 21.1,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pega tu enlace M3u para empezar a ver películas y series.',
              style: TextStyle(color: Colors.white60, fontSize: 14),
            ),
            const SizedBox(height: 24),

            // Host / URL TextField
            TextField(
              controller: _sourceUrlController,
              style: const TextStyle(color: Colors.white, fontSize: 16.1),
              decoration: InputDecoration(
                hintText: 'Configura tu fuente',
                hintStyle: const TextStyle(
                  color: Colors.white24,
                  fontSize: 16.1,
                ),
                filled: true,
                fillColor: Colors.black26,
                prefixIcon: const Icon(
                  CupertinoIcons.link,
                  color: Colors.white38,
                  size: 20,
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.explore, color: Colors.red),
                  tooltip: 'Ver recompensas especiales',
                  onPressed: _showConfigHelpBottomSheet,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final inputSource = _sourceUrlController.text.trim();
                  if (inputSource.isNotEmpty) {
                    setState(() => _isLoading = true);

                    final result = await _m3uService.resolveM3UInput(
                      inputSource,
                    );

                    if (result.url != null) {
                      await _m3uService.setLocalM3UUrl(
                        result.url!,
                        isCode: result.isCode,
                        originalInput: inputSource,
                        username: result.username,
                        password: result.password,
                        type: result.type,
                      );
                      await _initService();
                    } else {
                      setState(() => _isLoading = false);
                      if (mounted) {
                        SnackBarUtils.showAppSnackBar(
                          context,
                          'Por favor, ingresa un enlace M3U válido',
                        );
                      }
                    }
                  } else {
                    SnackBarUtils.showAppSnackBar(
                      context,
                      'Por favor, ingresa un enlace M3U válido',
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  'Guardar Fuente',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showConfigHelpBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          decoration: const BoxDecoration(
            color: Color(0xFF1a1a1a),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              const SizedBox(height: 24),
              Row(
                children: [
                  const Icon(Icons.help_outline, color: Colors.red, size: 28),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '¿Cómo configurar tu fuente?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Este lector permite organizar y visualizar contenido a través de listas M3U estándar. Para su funcionamiento, se requiere configurar una URL compatible.',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              _buildHelpOption(
                icon: Icons.telegram,
                iconColor: Colors.red,
                title: 'Unirse al Telegram',
                subtitle: 'Obtén instrucciones y soporte técnico',
                onTap: () {
                  Navigator.pop(context);
                  _launchURL('https://t.me/+0og3wmaKjkIwMzlh');
                },
                backgroundColor: Colors.red.withValues(alpha: 0.1),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHelpOption({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required Color backgroundColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: iconColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: Colors.white.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () {
                  if (_isNavigating) return;
                  setState(() => _isNavigating = true);
                  Navigator.of(context)
                      .push(
                        PageRouteBuilder(
                          pageBuilder: (
                            context,
                            animation,
                            secondaryAnimation,
                          ) {
                            return FadeTransition(
                              opacity: animation,
                              child: _SearchPage(
                                m3uService: _m3uService,
                                itemBuilder:
                                    (ctx, item) => _buildGridCard(item),
                              ),
                            );
                          },
                          transitionDuration: const Duration(milliseconds: 300),
                        ),
                      )
                      .then((_) {
                        if (mounted) setState(() => _isNavigating = false);
                      });
                },
                child: Hero(
                  tag: 'search_bar',
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      height: 43,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.search,
                            color: Colors.white54,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _AnimatedSearchPlaceholder(
                              suggestions: _getDynamicSearchSuggestions(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          if (PremiumService().isPremium)
            GestureDetector(
              onTap: _showPremiumDetailsBottomSheet,
              child: const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  CupertinoIcons.checkmark_seal,
                  color: Colors.amber,
                  size: 23.7,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(CupertinoIcons.settings, color: Colors.white70),
            onPressed: _showStreamBrowserConfig,
          ),
          if (kIsWeb ||
              defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.linux)
            IconButton(
              icon: const Icon(CupertinoIcons.bolt, color: Colors.white70),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const SettingsScreen(),
                  ),
                ).then((_) {
                  // Refresh in case premium status or active sources changed
                  if (mounted) setState(() {});
                });
              },
            ),
          IconButton(
            icon: const Icon(CupertinoIcons.refresh, color: Colors.white70),
            onPressed: () {
              setState(() => _isLoading = true);
              _m3uService.loadM3UContent(forceRefresh: true).then((_) {
                if (mounted) setState(() => _isLoading = false);
              });
            },
          ),
        ],
      ),
    );
  }

  void _showPremiumDetailsBottomSheet() {
    final expirationDateStr = PremiumService().expirationDate;
    final managementUrl = PremiumService().managementUrl;

    String dateDisplay = "Suscripción activa sin fecha de vencimiento";
    if (expirationDateStr != null) {
      try {
        final date = DateTime.parse(expirationDateStr);
        dateDisplay =
            "Estatus válido hasta: ${date.day}/${date.month}/${date.year}";
      } catch (e) {
        debugPrint("Error parsing date: $e");
      }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder:
          (context) => Container(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            decoration: const BoxDecoration(
              color: Color.fromARGB(255, 20, 20, 20),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(top: BorderSide(color: Colors.amber, width: 1.5)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 24),
                const Icon(
                  CupertinoIcons.checkmark_seal_fill,
                  color: Colors.amber,
                  size: 50,
                ),
                const SizedBox(height: 16),
                const Text(
                  "ESTATUS PREMIUM",
                  style: TextStyle(
                    color: Colors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "¡Ahora eres Premium!",
                  style: TextStyle(
                    color: Color.fromARGB(234, 255, 255, 255),
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  dateDisplay,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 13),
                TextButton(
                  onPressed: () {
                    final url =
                        managementUrl ??
                        (Theme.of(context).platform == TargetPlatform.android
                            ? 'https://play.google.com/store/account/subscriptions'
                            : 'https://apps.apple.com/account/subscriptions');
                    launchUrl(
                      Uri.parse(url),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color.fromARGB(255, 110, 110, 110),
                    minimumSize: const Size(double.infinity, 50),
                  ),
                  child: const Text(
                    "Gestionar Suscripción",
                    style: TextStyle(fontWeight: FontWeight.w400, fontSize: 14),
                  ),
                ),

                Text(
                  "Puedes cancelar o administrar tu suscripción en cualquier momento desde la tienda oficial u opciones en ajustes.",
                  style: TextStyle(
                    color: const Color.fromARGB(255, 110, 110, 110),
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 30),
              ],
            ),
          ),
    );
  }

  Widget _buildCategoryCard(String category) {
    // Generate a semi-random color based on name
    final hue = (category.hashCode.abs() % 360).toDouble();
    final color = HSLColor.fromAHSL(1.0, hue, 0.4, 0.3).toColor();
    final items = _m3uService.getItemsByCategory(category);

    return GestureDetector(
      onTap: () async {
        final result = await Navigator.push(
          context,
          FadeScalePageRoute(
            page: CategoryScreen(title: category, items: items),
          ),
        );
        if (!mounted) return;
        if (result != null) {
          if (result is Map && result['item'] is M3UItem) {
            _playItem(
              result['item'] as M3UItem,
              playlist: result['playlist'] as List<M3UItem>?,
            );
          } else if (result is M3UItem) {
            _playItem(result);
          }
        }
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color, color.withValues(alpha: 0.7)],
          ),
          boxShadow:
              PerformanceService().shouldShowComplexShadows
                  ? [
                    BoxShadow(
                      color: AppColors.background.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ]
                  : null,
        ),
        child: Stack(
          children: [
            Positioned(
              right: -10,
              bottom: -10,
              child: Icon(
                _getCategoryIcon(category),
                size: 60,
                color: Colors.white10,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    category,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      shadows: [
                        Shadow(
                          color: AppColors.background,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${items.length} contenidos',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getCategoryIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('deporte') || lower.contains('sport')) {
      return Icons.sports_soccer;
    }
    if (lower.contains('musica') || lower.contains('music')) {
      return Icons.music_note;
    }
    if (lower.contains('noticia') || lower.contains('news')) {
      return Icons.newspaper;
    }
    if (lower.contains('infantil') || lower.contains('kid')) {
      return Icons.child_care;
    }
    if (lower.contains('documental')) return Icons.language;
    if (lower.contains('cine') || lower.contains('estreno')) return Icons.movie;
    if (lower.contains('serie') || lower.contains('novela')) {
      return Icons.live_tv;
    }
    return Icons.grid_view_rounded;
  }

  Widget _buildHeroBanner(M3UItem item) {
    final heroTag = 'hero_${item.url}';
    // Responsive height: scales with the screen instead of a fixed 500 so it
    // never dominates small phones nor looks lost on tablets.
    final heroHeight = (MediaQuery.of(context).size.height * 0.6).clamp(
      380.0,
      560.0,
    );
    return GestureDetector(
      onTap: () => _onItemTap(item, heroTag: heroTag),
      child: Container(
        height: heroHeight,
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 1. Dynamic Shadow (Blurred background image)
            if (item.logo != null &&
                item.logo!.isNotEmpty &&
                PerformanceService().shouldShowComplexShadows)
              Positioned(
                top: 12,
                left: 10,
                right: 10,
                bottom: -10,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: Opacity(
                    opacity: 0.6,
                    child: FastThumbnail(
                      url: item.logo,
                      title: item.name,
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                      cacheWidth: 400, // menor resolución para el blur
                    ),
                  ),
                ),
              ),

            // 2. Main Container with Border
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.2),
                  width: 1.5,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.15),
                    Colors.white.withValues(alpha: 0.05),
                    Colors.white.withValues(alpha: 0.1),
                  ],
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Background Image (Poster) â€” parallax + shared-element Hero.
                    AnimatedBuilder(
                      animation: _homeScrollController,
                      builder: (context, child) {
                        final offset =
                            _homeScrollController.hasClients
                                ? _homeScrollController.offset
                                : 0.0;
                        final dy = (offset * 0.12).clamp(-26.0, 26.0);
                        return Transform(
                          alignment: Alignment.center,
                          // Slight overscale prevents edge gaps as the image
                          // shifts during the parallax translation.
                          transform:
                              Matrix4.identity()
                                ..translate(0.0, dy)
                                ..scale(1.1, 1.1),
                          child: child,
                        );
                      },
                      child: _heroPoster(
                        heroTag,
                        FastThumbnail(
                          url: item.logo,
                          title: item.name,
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          cacheWidth: null, // resolución completa para el hero
                          isHD: true,
                          isSeries: item.isSeries,
                          useTMDBFallback: !item.isLive,
                          onError: () {
                            if (item.logo != null && item.logo!.isNotEmpty) {
                              _m3uService.reportFailedLogo(item.logo!);
                            }
                          },
                        ),
                      ),
                    ),

                    // Gradient Overlay (Bottom only for text legibility)
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.transparent,
                            AppColors.background.withValues(alpha: 0.8),
                          ],
                          stops: const [0.0, 0.6, 1.0],
                        ),
                      ),
                    ),

                    // Content (Buttons at the bottom)
                    Positioned(
                      bottom: 30,
                      left: 16,
                      right: 16,
                      child: Row(
                        children: [
                          // Play Button
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                // FIX: Si es una serie, abrir la pantalla de detalle
                                // (donde se cargan los episodios) en lugar de intentar
                                // reproducirla directamente como película.
                                if (item.isSeries) {
                                  _onItemTap(item);
                                } else {
                                  _playItem(item);
                                }
                              },
                              icon: Icon(
                                item.isSeries
                                    ? Icons.play_arrow
                                    : Icons.play_arrow,
                                color: AppColors.background,
                              ),
                              label: Text(
                                item.isSeries ? 'Reproducir' : 'Reproducir',
                                style: const TextStyle(
                                  color: AppColors.background,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: AppColors.background,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                elevation: 0,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // "My List" / Favorite Button
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                await _safeToggleFavoriteGlobal(
                                  context,
                                  _m3uService,
                                  item,
                                  () {
                                    setState(() {});
                                  },
                                );
                              },
                              icon: Icon(
                                item.isFavorite ? Icons.check : Icons.add,
                                color: Colors.white,
                              ),
                              label: Text(
                                item.isFavorite ? 'En lista' : 'Mi lista',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color.fromARGB(
                                  255,
                                  255,
                                  255,
                                  255,
                                ).withValues(alpha: 0.14),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                elevation: 0,
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
          ],
        ),
      ),
    );
  }

  void _loadMoreHomeCategories(List<String> categories) async {
    if (_isHomeLoadingMore || _loadedHomeCategories >= categories.length) {
      return;
    }
    setState(() {
      _isHomeLoadingMore = true;
    });

    final nextCats = categories.skip(_loadedHomeCategories).take(3).toList();
    final urls = <String>[];
    for (final cat in nextCats) {
      final items = _m3uService.getItemsByCategory(cat);
      final filtered = _m3uService.filterValidItems(items);
      urls.addAll(filtered.take(6).map((i) => i.logo).whereType<String>());
    }

    await Future.wait([
      Future.delayed(const Duration(milliseconds: 600)),
      if (urls.isNotEmpty) FastImageService().prewarmAndAwait(urls, context),
    ]);

    if (!mounted) return;
    setState(() {
      _loadedHomeCategories = (_loadedHomeCategories + 3).clamp(
        0,
        categories.length,
      );
      _isHomeLoadingMore = false;
    });
  }

  void _loadMoreMovieCategories(List<String> categories) async {
    if (_isMoviesLoadingMore || _loadedMovieCategories >= categories.length) {
      return;
    }
    setState(() {
      _isMoviesLoadingMore = true;
    });

    final nextCats = categories.skip(_loadedMovieCategories).take(3).toList();
    final urls = <String>[];
    for (final cat in nextCats) {
      final items =
          _m3uService
              .getItemsByCategory(cat)
              .where((i) => !i.isSeries && !i.isLive)
              .toList();
      final filtered = _m3uService.filterValidItems(items);
      urls.addAll(filtered.take(6).map((i) => i.logo).whereType<String>());
    }

    await Future.wait([
      Future.delayed(const Duration(milliseconds: 600)),
      if (urls.isNotEmpty) FastImageService().prewarmAndAwait(urls, context),
    ]);

    if (!mounted) return;
    setState(() {
      _loadedMovieCategories = (_loadedMovieCategories + 3).clamp(
        0,
        categories.length,
      );
      _isMoviesLoadingMore = false;
    });
  }

  void _loadMoreSeriesCategories(List<String> categories) async {
    if (_isSeriesLoadingMore || _loadedSeriesCategories >= categories.length) {
      return;
    }
    setState(() {
      _isSeriesLoadingMore = true;
    });

    final nextCats = categories.skip(_loadedSeriesCategories).take(3).toList();
    final urls = <String>[];
    for (final cat in nextCats) {
      final items =
          _m3uService
              .getItemsByCategory(cat)
              .where((i) => i.isSeries && !i.isLive)
              .toList();
      final filtered = _m3uService.filterValidItems(items);
      urls.addAll(filtered.take(6).map((i) => i.logo).whereType<String>());
    }

    await Future.wait([
      Future.delayed(const Duration(milliseconds: 600)),
      if (urls.isNotEmpty) FastImageService().prewarmAndAwait(urls, context),
    ]);

    if (!mounted) return;
    setState(() {
      _loadedSeriesCategories = (_loadedSeriesCategories + 3).clamp(
        0,
        categories.length,
      );
      _isSeriesLoadingMore = false;
    });
  }

  void _loadMoreNovelaCategories(List<String> categories) async {
    if (_isNovelasLoadingMore || _loadedNovelaCategories >= categories.length) {
      return;
    }
    setState(() {
      _isNovelasLoadingMore = true;
    });

    final nextCats = categories.skip(_loadedNovelaCategories).take(3).toList();
    final urls = <String>[];
    for (final cat in nextCats) {
      final items = _m3uService.getItemsByCategory(cat);
      final filtered = _m3uService.filterValidItems(items);
      urls.addAll(filtered.take(6).map((i) => i.logo).whereType<String>());
    }

    await Future.wait([
      Future.delayed(const Duration(milliseconds: 600)),
      if (urls.isNotEmpty) FastImageService().prewarmAndAwait(urls, context),
    ]);

    if (!mounted) return;
    setState(() {
      _loadedNovelaCategories = (_loadedNovelaCategories + 3).clamp(
        0,
        categories.length,
      );
      _isNovelasLoadingMore = false;
    });
  }

  void _loadMoreAnimationCategories(List<String> categories) async {
    if (_isAnimationLoadingMore ||
        _loadedAnimationCategories >= categories.length) {
      return;
    }
    setState(() {
      _isAnimationLoadingMore = true;
    });

    final nextCats =
        categories.skip(_loadedAnimationCategories).take(3).toList();
    final urls = <String>[];
    for (final cat in nextCats) {
      final items = _m3uService.getItemsByCategory(cat);
      final filtered = _m3uService.filterValidItems(items);
      urls.addAll(filtered.take(6).map((i) => i.logo).whereType<String>());
    }

    await Future.wait([
      Future.delayed(const Duration(milliseconds: 600)),
      if (urls.isNotEmpty) FastImageService().prewarmAndAwait(urls, context),
    ]);

    if (!mounted) return;
    setState(() {
      _loadedAnimationCategories = (_loadedAnimationCategories + 3).clamp(
        0,
        categories.length,
      );
      _isAnimationLoadingMore = false;
    });
  }

  Widget _buildCategoryRow(String title, List<M3UItem> items) {
    final filteredItems = _m3uService.filterValidItems(items);

    if (filteredItems.isEmpty) return const SizedBox.shrink();

    final performance = PerformanceService();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: 12,
            ),
            child: GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (context) => CategoryScreen(title: title, items: items),
                  ),
                );
              },
              child: Row(
                mainAxisSize:
                    MainAxisSize
                        .min, // Keep tight to prevent full width click area if unnecessary, but wrap in GestureDetector already makes the tight area clickable
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    color: Colors.white70,
                    size: 24,
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 205,
            child: ListenableBuilder(
              listenable: Listenable.merge([performance, _m3uService]),
              builder:
                  (context, _) => ListView.builder(
                    scrollCacheExtent: ScrollCacheExtent.pixels(
                      performance.isLowPerformance ? 0 : 500,
                    ),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: filteredItems.length,
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: true,
                    itemBuilder: (context, index) {
                      return _buildHorizontalCard(
                        filteredItems[index],
                        heroPrefix: title,
                      );
                    },
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTop10Section() {
    // 1. Get a larger pool to find recent years (first 500 items)
    final initialPool = _m3uService.movies.take(500).toList();
    if (initialPool.isEmpty) return const SizedBox.shrink();

    // 2. Extract years and find the maximum year present
    final itemsWithYear =
        initialPool
            .map((item) => {'item': item, 'year': _extractYear(item.name)})
            .where((e) => e['year'] != null)
            .toList();

    int maxYear = 0;
    if (itemsWithYear.isNotEmpty) {
      maxYear = itemsWithYear
          .map((e) => e['year'] as int)
          .reduce((curr, next) => curr > next ? curr : next);
    }

    // 3. Filter by max year (and maxYear-1 if pool is small)
    var filteredPool =
        itemsWithYear
            .where((e) => e['year'] == maxYear)
            .map((e) => e['item'] as M3UItem)
            .toList();

    if (filteredPool.length < 15 && maxYear > 1900) {
      final prevYearItems =
          itemsWithYear
              .where((e) => e['year'] == maxYear - 1)
              .map((e) => e['item'] as M3UItem)
              .toList();
      filteredPool.addAll(prevYearItems);
    }

    // Fallback if year detection didn't yield enough results
    if (filteredPool.isEmpty) {
      filteredPool = initialPool.take(100).toList();
    }

    // 4. Deterministic random based on current date
    final now = DateTime.now();
    final seed = now.year * 10000 + now.month * 100 + now.day;
    final random = Random(seed);

    final shuffledPool = List<M3UItem>.from(filteredPool)..shuffle(random);
    final topItems = shuffledPool.take(10).toList();
    if (topItems.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: 12,
            ),
            child: Text(
              _getTop10Title(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          SizedBox(
            height: 200,
            child: ListView.builder(
              scrollCacheExtent: ScrollCacheExtent.pixels(500),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: topItems.length,
              itemBuilder: (context, index) {
                final item = topItems[index];
                final rank = index + 1;
                return _buildTop10Card(item, rank);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTop10Card(M3UItem item, int rank) {
    final heroTag = 'top10_${item.url}';
    return GestureDetector(
      onTap: () => _onItemTap(item, heroTag: heroTag),
      onLongPress: () async {
        HapticFeedback.mediumImpact();
        await _safeToggleFavoriteGlobal(context, _m3uService, item, () {
          setState(() {});
        });
      },
      child: Container(
        width: rank >= 10 ? 215 : 175,
        margin: const EdgeInsets.symmetric(horizontal: 10),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // â”€â”€ Large rank number (behind the poster) â”€â”€
            Positioned(
              left: -5,
              bottom: 12,
              child: Text(
                '$rank',
                style: TextStyle(
                  fontSize: 115,
                  fontWeight: FontWeight.w900,
                  height: 0.85,
                  letterSpacing: rank >= 10 ? -22 : 0,
                  foreground:
                      Paint()
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = 3
                        ..color = const Color(0xFF4A4A4A),
                ),
              ),
            ),
            // â”€â”€ Movie poster â”€â”€
            Positioned(
              left: rank < 10 ? 55 : 95,
              top: 0,
              right: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 170,
                    width: 120,
                    child: _heroPoster(
                      heroTag,
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            FastThumbnail(
                              url: item.logo,
                              title: item.name,
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.cover,
                              cacheWidth: 300,
                              isSeries: item.isSeries,
                              useTMDBFallback: !item.isLive,
                              onError: () {
                                if (item.logo != null) {
                                  _m3uService.reportFailedLogo(item.logo!);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.name.replaceAll(RegExp(r'\s*\(\d{4}\)'), ''),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Wraps a poster in a Hero. The tag embeds the section prefix so the same
  /// title appearing in several rows never produces a duplicate tag on screen.
  Widget _heroPoster(String tag, Widget child) {
    return Hero(tag: tag, child: child);
  }

  Widget _buildHorizontalCard(M3UItem item, {String heroPrefix = 'row'}) {
    final heroTag = '${heroPrefix}_${item.url}';
    return GestureDetector(
      onTap: () => _onItemTap(item, heroTag: heroTag),
      onLongPress: () async {
        HapticFeedback.mediumImpact();
        await _safeToggleFavoriteGlobal(context, _m3uService, item, () {
          setState(() {});
        });
      },
      child: Container(
        width: 120,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail
            SizedBox(
              height: 170,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow:
                          PerformanceService().shouldShowComplexShadows
                              ? [
                                BoxShadow(
                                  color: AppColors.background.withValues(
                                    alpha: 0.5,
                                  ),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                ),
                              ]
                              : null,
                    ),
                    child: _heroPoster(
                      heroTag,
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: FastThumbnail(
                          url: item.logo,
                          title: item.name,
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          borderRadius: BorderRadius.circular(8),
                          isSeries: item.isSeries,
                          useTMDBFallback: !item.isLive,
                          cacheWidth:
                              PerformanceService().lowMemoryLimit ? 150 : 300,
                          onError: () {
                            if (item.logo != null && item.logo!.isNotEmpty) {
                              _m3uService.reportFailedLogo(item.logo!);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.name.replaceAll(RegExp(r'\s*\(\d{4}\)'), ''),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // _buildSearchGrid removed

  Widget _buildGridCard(M3UItem item, {bool showTitle = true}) {
    final heroTag = 'grid_${item.url}';
    return RepaintBoundary(
      child: GestureDetector(
        onTap: () => _onItemTap(item, heroTag: heroTag),
        onLongPress: () async {
          HapticFeedback.mediumImpact();
          await _safeToggleFavoriteGlobal(context, _m3uService, item, () {
            setState(() {});
          });
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow:
                          PerformanceService().shouldShowComplexShadows
                              ? [
                                BoxShadow(
                                  color: AppColors.background.withValues(
                                    alpha: 0.5,
                                  ),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                ),
                              ]
                              : null,
                    ),
                    child: _heroPoster(
                      heroTag,
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: FastThumbnail(
                          url: item.logo,
                          title: item.name,
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          borderRadius: BorderRadius.circular(10),
                          isSeries: item.isSeries,
                          useTMDBFallback: !item.isLive,
                          cacheWidth:
                              PerformanceService().lowMemoryLimit ? 150 : 300,
                          onError: () {
                            if (item.logo != null) {
                              _m3uService.reportFailedLogo(item.logo!);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  if (_bottomNavIndex == 1)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: GestureDetector(
                        onTap: () async {
                          await _safeToggleFavoriteGlobal(
                            context,
                            _m3uService,
                            item,
                            () {
                              setState(() {});
                            },
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: AppColors.background.withValues(alpha: 0.7),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            item.isFavorite ? Icons.check : Icons.add,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (showTitle) ...[
              const SizedBox(height: 6),
              Text(
                item.name.replaceAll(RegExp(r'\s*\(\d{4}\)'), ''),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            AppColors.background,
            AppColors.background.withValues(alpha: 0.95),
          ],
        ),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: _bottomNavIndex,
        onTap: (index) {
          if (_bottomNavIndex == 0 && index == 0) {
            if (_homeScrollController.hasClients) {
              final offset = _homeScrollController.offset;
              final ms = (offset / 3).clamp(350.0, 1000.0).toInt();
              _homeScrollController.animateTo(
                0.0,
                duration: Duration(milliseconds: ms),
                curve: Curves.easeInOutCubic,
              );
            }
          }
          setState(() {
            _bottomNavIndex = index;
          });
        },
        backgroundColor: Colors.transparent,
        selectedItemColor: Colors.red,
        unselectedItemColor: Colors.white54,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_filled),
            label: 'Inicio',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.check), label: 'Mi lista'),
        ],
      ),
    );
  }

  Future<void> _detectCountry() async {
    try {
      final response = await http
          .get(Uri.parse('http://ip-api.com/json'))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && data['countryCode'] != null) {
          if (mounted) {
            setState(() {
              _detectedCountryCode =
                  data['countryCode'].toString().toUpperCase();
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error detecting country: $e');
    }
  }

  String _getTop10Title() {
    final countryCode =
        _detectedCountryCode ??
        View.of(context).platformDispatcher.locale.countryCode;
    if (countryCode == null || countryCode.isEmpty) {
      return 'Top 10 películas hoy';
    }

    final countryName = _getCountryName(countryCode);
    if (countryName.isEmpty) {
      return 'Top 10 películas hoy';
    }

    return 'Top 10 películas en $countryName hoy';
  }

  int? _extractYear(String name) {
    // Matches (2024), [2024], or just 2024 at the end or in middle
    final match = RegExp(r'(?:[\[\(]?)(\d{4})(?:[\]\)]?)').allMatches(name);
    if (match.isNotEmpty) {
      // Take the last 4-digit match which is usually the year
      final yearStr = match.last.group(1);
      if (yearStr != null) {
        final year = int.tryParse(yearStr);
        if (year != null && year >= 1900 && year <= 2100) {
          return year;
        }
      }
    }
    return null;
  }

  String _getCountryName(String code) {
    final Map<String, String> countries = {
      'AR': 'Argentina',
      'BO': 'Bolivia',
      'BR': 'Brasil',
      'CL': 'Chile',
      'CO': 'Colombia',
      'CR': 'Costa Rica',
      'CU': 'Cuba',
      'EC': 'Ecuador',
      'ES': 'España',
      'GT': 'Guatemala',
      'HN': 'Honduras',
      'MX': 'México',
      'NI': 'Nicaragua',
      'PA': 'Panamá',
      'PY': 'Paraguay',
      'PE': 'Perú',
      'PR': 'Puerto Rico',
      'DO': 'República Dominicana',
      'SV': 'El Salvador',
      'UY': 'Uruguay',
      'VE': 'Venezuela',
      'US': 'Estados Unidos',
    };
    return countries[code.toUpperCase()] ?? '';
  }
}

/// One-shot fade + slide used to cascade home rows into view. Because it only
/// animates when its element is first created, rows reveal as they scroll in
/// and never re-animate on rebuilds (e.g. setState / watch-progress refresh).
class _RevealOnMount extends StatelessWidget {
  final Widget child;
  const _RevealOnMount({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 8),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _HiddenMoviesShimmer extends StatelessWidget {
  const _HiddenMoviesShimmer();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics:
          const NeverScrollableScrollPhysics(), // Prevent scrolling while loading
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Shimmer Hero
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 37, 16, 20),
            child: _ShimmerBox(
              height: 480, // Match Hero height
              width: double.infinity,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const SizedBox(height: 16),
          // Shimmer Category Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _ShimmerBox(
                  width: 150,
                  height: 20,
                  borderRadius: BorderRadius.circular(4),
                ),
                const Spacer(),
                _ShimmerBox(
                  width: 60,
                  height: 16,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ),
          ),
          // Shimmer Category Row
          SizedBox(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: 5,
              itemBuilder: (context, index) {
                return const _ShimmerItem();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ShimmerItem extends StatelessWidget {
  const _ShimmerItem();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _ShimmerBox(
              width: double.infinity,
              height: double.infinity,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 8),
          _ShimmerBox(
            width: 80,
            height: 12,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
      ),
    );
  }
}

class _ShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius borderRadius;

  const _ShimmerBox({
    required this.width,
    required this.height,
    required this.borderRadius,
  });

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _animation = Tween<double>(begin: -2.0, end: 2.0).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!PerformanceService().shouldAnimateDecorations) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: widget.borderRadius,
        ),
      );
    }

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: const [
                Color(0xFF1a1a1a),
                Color(0xFF2d3436),
                Color(0xFF1a1a1a),
              ],
              stops: [
                (0.3 + (_animation.value / 4)).clamp(0.0, 1.0),
                (0.5 + (_animation.value / 4)).clamp(0.0, 1.0),
                (0.7 + (_animation.value / 4)).clamp(0.0, 1.0),
              ],
            ),
          ),
        );
      },
    );
  }
}

// _SearchShimmer class removed

// _SearchShimmerItem class removed

/// Animated loading messages that cycle through different texts with fade transitions
class _AnimatedLoadingMessages extends StatefulWidget {
  const _AnimatedLoadingMessages();

  @override
  State<_AnimatedLoadingMessages> createState() =>
      _AnimatedLoadingMessagesState();
}

class _AnimatedLoadingMessagesState extends State<_AnimatedLoadingMessages>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  late AnimationController _controller;

  final List<Map<String, String>> _messages = const [
    {
      'title': 'Cargando contenido...',
      'subtitle': 'Preparando tu lista para la mejor experiencia',
    },
    {'title': 'Estamos preparando todo...', 'subtitle': 'Solo un momento más'},
    {
      'title': 'Ya casi estamos listos...',
      'subtitle': 'Gracias por tu paciencia',
    },
    {
      'title': 'No salgas de la app...',
      'subtitle': 'Estamos terminando de preparar todo',
    },
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    // Start the cycling timer
    _startCycling();
  }

  void _startCycling() {
    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      _cycleToNext();
    });
  }

  void _cycleToNext() async {
    // Fade out
    await _controller.forward();

    if (!mounted) return;

    // Change the message
    setState(() {
      _currentIndex = (_currentIndex + 1) % _messages.length;
    });

    // Fade in
    await _controller.reverse();

    // Schedule next cycle
    if (mounted) {
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) _cycleToNext();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_controller),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _messages[_currentIndex]['title']!,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            _messages[_currentIndex]['subtitle']!,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _FullscreenLivePlayer extends StatefulWidget {
  final ValueNotifier<VideoController?> controllerNotifier;
  final String channelName;
  final ValueNotifier<int?> adCountdownNotifier;
  final ValueNotifier<String> speedNotifier;
  final M3UItem item;
  final Function(M3UItem) onReport;
  final ValueNotifier<Uint8List?> lastFrameBytesNotifier;

  const _FullscreenLivePlayer({
    required this.controllerNotifier,
    required this.channelName,
    required this.adCountdownNotifier,
    required this.speedNotifier,
    required this.item,
    required this.onReport,
    required this.lastFrameBytesNotifier,
  });

  @override
  State<_FullscreenLivePlayer> createState() => _FullscreenLivePlayerState();
}

class _FullscreenLivePlayerState extends State<_FullscreenLivePlayer> {
  bool _showControls = true;
  bool _isPCFullscreen = false;
  Timer? _hideTimer;
  static const platform = MethodChannel('com.juanchosky.bumpcomba/pip');
  bool get _isPiPSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _startHideTimer();

    // NO tocar ninguna propiedad de MPV aquí.
    // _applySeamlessConfig ya configuró todo correctamente antes de entrar
    // a pantalla completa. Sobrescribir cache-secs=12 aquí deshacía el
    // buffer de 60s y causaba micro-cortes en fullscreen.
    //
    // El único ajuste válido en fullscreen es asegurarse de que
    // cache-pause siga en 'no', porque algunos dispositivos lo resetean
    // al cambiar de surface. Lo hacemos en un microtask para no bloquear.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final player = widget.controllerNotifier.value?.player;
      final mpv = player?.platform as dynamic;
      if (mpv == null) return;

      // Solo los ajustes que pueden resetearse al cambiar de surface.
      // NO tocar cache-secs, demuxer-max-bytes, ni ningún otro valor grande.
      Future<void> safeSet(String key, String value) async {
        try {
          await mpv.setProperty(key, value);
        } catch (_) {}
      }

      await safeSet('cache-pause', 'no'); // Crítico: nunca pausar
      await safeSet('cache-pause-initial', 'no');
      await safeSet('framedrop', 'no'); // Consistente con inline
      await safeSet('audio-stream-silence', 'yes');
      await safeSet('keep-open-pause', 'no');
    });
  }

  @override
  void dispose() {
    if (_isPCFullscreen) {
      defaultExitNativeFullscreen();
    }
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    _hideTimer?.cancel();
    super.dispose();
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _startHideTimer();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _togglePCFullscreen() {
    if (_isPCFullscreen) {
      defaultExitNativeFullscreen();
      setState(() => _isPCFullscreen = false);
    } else {
      defaultEnterNativeFullscreen();
      setState(() => _isPCFullscreen = true);
    }
  }

  void _handleEsc() {
    if (_isPCFullscreen) {
      _togglePCFullscreen();
    } else {
      Navigator.pop(context);
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
    // Force dismiss after 3 seconds (Material 3 ignores duration with actions)
    Timer(const Duration(seconds: 3), () {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
    });
  }

  Future<void> _togglePiP() async {
    if (!PremiumService().isPremium) {
      _showPremiumRequirement('Modo ventana (PiP) disponible con Premium');
      return;
    }

    try {
      final player = widget.controllerNotifier.value?.player;
      if (player == null) return;

      final width = player.state.width ?? 1920;
      final height = player.state.height ?? 1080;

      // Enter PiP Mode natively
      if (_isPiPSupported) {
        await platform.invokeMethod('enterPiP', {
          'width': width,
          'height': height,
          'playing': player.state.playing,
        });
      }

      // Hide controls immediately
      if (mounted) {
        setState(() => _showControls = false);
      }
    } catch (e) {
      debugPrint('Error triggering PiP: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No compatible con este dispositivo'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape):
            const ExitFullscreenIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ExitFullscreenIntent: CallbackAction<ExitFullscreenIntent>(
            onInvoke: (intent) => _handleEsc(),
          ),
        },
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: GestureDetector(
            onTap: _toggleControls,
            behavior: HitTestBehavior.translucent,
            child: Stack(
              children: [
                Center(
                  child: ValueListenableBuilder<Uint8List?>(
                    valueListenable: widget.lastFrameBytesNotifier,
                    builder: (context, lastFrameBytes, _) {
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          ValueListenableBuilder<VideoController?>(
                            valueListenable: widget.controllerNotifier,
                            builder: (context, controller, child) {
                              if (controller == null) {
                                return const Center(
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                  ),
                                );
                              }
                              return Video(
                                key: ValueKey(controller.hashCode),
                                controller: controller,
                                controls: (state) => const SizedBox.shrink(),
                              );
                            },
                          ),
                          if (lastFrameBytes != null)
                            Image.memory(lastFrameBytes, fit: BoxFit.contain),
                        ],
                      );
                    },
                  ),
                ),

                // Ad Countdown Overlay (Fullscreen)
                ValueListenableBuilder<int?>(
                  valueListenable: widget.adCountdownNotifier,
                  builder: (context, countdown, _) {
                    if (countdown == null) return const SizedBox.shrink();
                    return Positioned(
                      top: 40,
                      right: 20,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.background.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white10, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.info_outline,
                              color: Colors.yellow,
                              size: 19.7,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Anuncio en $countdown...',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14.8,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                // Controls Overlay
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: AnimatedOpacity(
                      opacity: _showControls ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: Container(
                        color: AppColors.background.withValues(alpha: 0.4),
                        padding: const EdgeInsets.all(20),
                        child: Stack(
                          children: [
                            // Back Button + Speed Group
                            Positioned(
                              top: 20,
                              left: 10,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: () {
                                      if (!mounted) return;
                                      Navigator.pop(context);
                                    },
                                    icon: const Icon(
                                      Icons.arrow_back_ios_new,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ValueListenableBuilder<String>(
                                    valueListenable: widget.speedNotifier,
                                    builder: (context, speed, _) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black45,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: Colors.white12,
                                            width: 0.5,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.download_rounded,
                                              color: Colors.white60,
                                              size: 14,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              speed,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                fontFamily: 'monospace',
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),

                            // Top-Right Controls (PiP & Report Buttons)
                            Positioned(
                              top: 20,
                              right: 20,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: _togglePiP,
                                    icon: const Icon(
                                      Icons.picture_in_picture_alt,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    onPressed: () {
                                      _startHideTimer();
                                      widget.onReport(widget.item);
                                    },
                                    icon: const Icon(
                                      Icons.flag_outlined,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Bottom Controls
                            Positioned(
                              bottom: 40,
                              left: 20,
                              right: 20,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          widget.channelName,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 22,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: () async {
                                          if (kIsWeb ||
                                              defaultTargetPlatform ==
                                                  TargetPlatform.windows ||
                                              defaultTargetPlatform ==
                                                  TargetPlatform.macOS ||
                                              defaultTargetPlatform ==
                                                  TargetPlatform.linux) {
                                            _togglePCFullscreen();
                                            return;
                                          }
                                          // Force portrait orientation and exit fullscreen
                                          await SystemChrome.setPreferredOrientations(
                                            [DeviceOrientation.portraitUp],
                                          );

                                          if (!mounted) return;
                                          Navigator.pop(context);

                                          // Reset to allow all orientations after a short delay
                                          Future.delayed(
                                            const Duration(milliseconds: 500),
                                            () {
                                              SystemChrome.setPreferredOrientations(
                                                [
                                                  DeviceOrientation.portraitUp,
                                                  DeviceOrientation
                                                      .portraitDown,
                                                  DeviceOrientation
                                                      .landscapeLeft,
                                                  DeviceOrientation
                                                      .landscapeRight,
                                                ],
                                              );
                                            },
                                          );
                                        },
                                        icon: const Icon(
                                          Icons.fullscreen,
                                          color: Colors.white,
                                          size: 28,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: const BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      const Text(
                                        'EN VIVO',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedSearchPlaceholder extends StatefulWidget {
  final List<String> suggestions;
  final Duration interval = const Duration(seconds: 4);

  const _AnimatedSearchPlaceholder({required this.suggestions});

  @override
  State<_AnimatedSearchPlaceholder> createState() =>
      _AnimatedSearchPlaceholderState();
}

class _AnimatedSearchPlaceholderState
    extends State<_AnimatedSearchPlaceholder> {
  Timer? _timer;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    if (widget.suggestions.isNotEmpty) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (widget.suggestions.length <= 1) return;

    _timer = Timer.periodic(widget.interval, (timer) {
      if (!mounted) return;
      if (widget.suggestions.isEmpty) {
        _timer?.cancel();
        return;
      }
      setState(() {
        _currentIndex = (_currentIndex + 1) % widget.suggestions.length;
      });
    });
  }

  @override
  void didUpdateWidget(_AnimatedSearchPlaceholder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.suggestions != oldWidget.suggestions) {
      if (widget.suggestions.isEmpty) {
        _timer?.cancel();
        _currentIndex = 0;
      } else {
        if (_currentIndex >= widget.suggestions.length) {
          _currentIndex = 0;
        }
        _startTimer();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.suggestions.isEmpty) return const SizedBox.shrink();

    // Final safety bounds check before build
    final int safeIndex =
        _currentIndex < widget.suggestions.length ? _currentIndex : 0;
    final String currentSuggestion = widget.suggestions[safeIndex];

    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        transitionBuilder: (Widget child, Animation<double> animation) {
          final inAnimation = Tween<Offset>(
            begin: const Offset(0.0, 1.0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          );

          final outAnimation = Tween<Offset>(
            begin: const Offset(0.0, -1.0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          );

          return SlideTransition(
            position:
                child.key == ValueKey<String>(currentSuggestion)
                    ? inAnimation
                    : outAnimation,
            child: child,
          );
        },
        child: Container(
          key: ValueKey<String>(currentSuggestion),
          height: 20, // constrain height to text size to prevent overflow
          alignment: Alignment.centerLeft,
          child: Text(
            currentSuggestion,
            style: const TextStyle(color: Colors.white54, fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _SearchPage extends StatefulWidget {
  final M3UService m3uService;
  final Widget Function(BuildContext, M3UItem) itemBuilder;

  const _SearchPage({required this.m3uService, required this.itemBuilder});

  @override
  State<_SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<_SearchPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<dynamic> _combinedResults = [];
  List<M3UItem> _popularItems = [];
  bool _isLoading = false;
  Timer? _debounceTimer;
  String? _activeSearchQuery;

  @override
  void initState() {
    super.initState();
    // Fetch popular items
    _popularItems = widget.m3uService.getPopularSearchItems();
    widget.m3uService.addListener(_onServiceUpdate);

    // Explicit focus request after transition to fix Android responsiveness
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted && !_searchFocusNode.hasFocus) {
          _searchFocusNode.requestFocus();
        }
      });
    });
  }

  void _onServiceUpdate() {
    if (mounted) {
      final newPopular = widget.m3uService.getPopularSearchItems();
      // Solo actualizar si hay mejora real (evita rebuild innecesario)
      if (newPopular.isNotEmpty || _popularItems.isEmpty) {
        setState(() {
          _popularItems = newPopular;
        });
      }
    }
  }

  @override
  void dispose() {
    widget.m3uService.removeListener(_onServiceUpdate);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _activeSearchQuery = query;
    if (_debounceTimer?.isActive ?? false) _debounceTimer?.cancel();

    // Snappier debounce time (from 250ms to 150ms)
    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      _performSearch(query);
    });
  }

  void _performSearch(String query) {
    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          _combinedResults = [];
          _isLoading = false;
        });
      }
      return;
    }

    final results = widget.m3uService.search(query);
    final categories = widget.m3uService.searchCategories(query);

    if (mounted && _activeSearchQuery == query) {
      final List<dynamic> combined = [];
      if (categories.isEmpty) {
        combined.addAll(results);
      } else {
        // Interleave categories among results
        final interval =
            results.length > categories.length
                ? (results.length / (categories.length + 1)).ceil()
                : 1;
        int catIdx = 0;
        for (int i = 0; i < results.length; i++) {
          combined.add(results[i]);
          if (catIdx < categories.length && (i + 1) % interval == 0) {
            combined.add(categories[catIdx++]);
          }
        }
        // Add remaining categories at the end
        while (catIdx < categories.length) {
          combined.add(categories[catIdx++]);
        }
      }

      setState(() {
        _combinedResults = combined;
        _isLoading = false;
      });

      // Aggressive pre-caching for search results (first 10)
      if (results.isNotEmpty) {
        final urls =
            results.take(10).map((i) => i.logo).whereType<String>().toList();
        if (urls.isNotEmpty) {
          FastImageService().prewarm(urls, context);
        }
      }
    }
  }

  Widget _buildSearchShimmer() {
    return Shimmer.fromColors(
      baseColor: AppColors.surface,
      highlightColor: AppColors.surfaceVariant,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: 15,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.search, color: AppColors.background, size: 20),
                const SizedBox(width: 16),
                Expanded(
                  child: Container(
                    height: 16,
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                const Icon(
                  Icons.north_east,
                  color: AppColors.background,
                  size: 18,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background, // Match app background
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Hero(
                tag: 'search_bar',
                child: Material(
                  color: Colors.transparent,
                  child: GestureDetector(
                    onTap: () {
                      if (!_searchFocusNode.hasFocus) {
                        _searchFocusNode.requestFocus();
                      }
                    },
                    child: Container(
                      height: 43,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.search,
                            color: Colors.white54,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocusNode,
                              autofocus: true,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                hintText: 'Buscar...',
                                hintStyle: TextStyle(color: Colors.white54),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              onChanged: _onSearchChanged,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white54,
                            ),
                            onPressed: () {
                              if (_searchController.text.isNotEmpty) {
                                _searchController.clear();
                                _onSearchChanged('');
                              } else {
                                Navigator.pop(context);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child:
                  _searchController.text.isEmpty
                      ? _buildPopularGrid()
                      : _isLoading
                      ? _buildSearchShimmer()
                      : (_combinedResults.isEmpty && !_isLoading)
                      ? const Center(
                        child: Text(
                          'No se encontraron resultados',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                      : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _combinedResults.length,
                        separatorBuilder: (context, index) {
                          return const Divider(
                            color: Colors.white10,
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                          );
                        },
                        itemBuilder: (context, index) {
                          final item = _combinedResults[index];
                          if (item is String) {
                            return _buildSearchCategoryItem(item);
                          }
                          return _buildSearchResultItem(item as M3UItem);
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchCategoryItem(String category) {
    final String query = _searchController.text.toLowerCase();
    final bool isCollection = category.startsWith('Colección:');

    return InkWell(
      onTap: () async {
        final items = widget.m3uService.getItemsByCategory(category);
        await Navigator.push(
          context,
          FadeScalePageRoute(
            page: CategoryScreen(title: category, items: items),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              isCollection ? CupertinoIcons.collections : Icons.folder,
              color: isCollection ? Colors.red : Colors.white54,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHighlightedText(category, query),
                  Text(
                    isCollection ? 'Colección de películas' : 'Categoría',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              color: Colors.white24,
              size: 14,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultItem(M3UItem item) {
    final String query = _searchController.text.toLowerCase();
    final String name = item.name;

    return InkWell(
      onTap: () async {
        final similarItems = widget.m3uService.getSimilarItems(item);
        await Navigator.push(
          context,
          ContentDetailPageRoute(
            page: ContentDetailScreen(
              item: item,
              similarItems: similarItems,
              onToggleFavorite: (favItem) async {
                await _safeToggleFavoriteGlobal(
                  context,
                  widget.m3uService,
                  favItem,
                  () {
                    if (mounted) setState(() {});
                  },
                );
              },
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.search, color: Colors.white54, size: 20),
            const SizedBox(width: 12),
            Expanded(child: _buildHighlightedText(name, query)),
            const SizedBox(width: 10),
            // Poster Image
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 36,
                height: 50,
                child: FastThumbnail(
                  url: item.logo,
                  title: item.name,
                  width: 36,
                  height: 50,
                  fit: BoxFit.cover,
                  onError: () {
                    // Fail silently or show icon via FastThumbnail's inherent state if needed
                  },
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Icon(
              Icons.north_east_rounded,
              color: Colors.white54,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightedText(String text, String query) {
    if (query.isEmpty || !text.toLowerCase().contains(query)) {
      return Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final List<TextSpan> spans = [];
    final String lowerText = text.toLowerCase();
    int start = 0;
    int indexOfQuery;

    while ((indexOfQuery = lowerText.indexOf(query, start)) != -1) {
      if (indexOfQuery > start) {
        spans.add(
          TextSpan(
            text: text.substring(start, indexOfQuery),
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: text.substring(indexOfQuery, indexOfQuery + query.length),
          style: const TextStyle(
            color: Colors.redAccent,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      start = indexOfQuery + query.length;
    }

    if (start < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(start),
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      );
    }

    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: spans),
    );
  }

  Widget _buildPopularGrid() {
    // If empty but fetching, show shimmer to avoid blank space and flickering
    if (_popularItems.isEmpty && widget.m3uService.isFetchingPopularTMDB) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              children: [
                const Icon(Icons.trending_up, color: Colors.red, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Búsqueda popular',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: 5,
            itemBuilder: (context, index) {
              return Shimmer.fromColors(
                baseColor: const Color(0xFF0F0F0F),
                highlightColor: const Color(
                  0xFF1E1E1E,
                ), // Subtle dark grey highlight
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 45,
                        height: 65,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: double.infinity,
                              height: 14,
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: 100,
                              height: 10,
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      );
    }

    if (_popularItems.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              const Icon(Icons.trending_up, color: Colors.red, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Búsqueda popular',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                'Recientes',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(left: 16, right: 16, top: 12),
            itemCount: _popularItems.length,
            itemBuilder: (context, index) {
              return _buildSearchListItem(_popularItems[index]);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSearchListItem(M3UItem item) {
    final bool isHot = item.name.hashCode % 2 == 0;

    return InkWell(
      onTap: () async {
        final similarItems = widget.m3uService.getSimilarItems(item);
        await Navigator.push(
          context,
          ContentDetailPageRoute(
            page: ContentDetailScreen(
              item: item,
              similarItems: similarItems,
              onToggleFavorite: (favItem) async {
                await _safeToggleFavoriteGlobal(
                  context,
                  widget.m3uService,
                  favItem,
                  () {
                    if (mounted) setState(() {});
                  },
                );
              },
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            // Poster Image
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 45,
                height: 65,
                child: FastThumbnail(
                  url: item.logo,
                  title: item.name,
                  width: 45,
                  height: 65,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 16),
            // Middle section: Title + Badge and Subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15.1,
                            fontWeight: FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildBadge(
                        isHot ? 'HOT' : 'TOP',
                        isHot
                            ? const Color(0xFFFF4D4D)
                            : const Color(0xFFFFD700),
                      ),
                    ],
                  ),
                  if (item.category.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      item.category,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            // Play Button Icon (Styled like image)
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white54,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    bool isHot = text == 'HOT';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color:
            isHot ? color.withValues(alpha: 0.9) : color.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isHot ? Colors.white : Colors.black87,
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class NetflixOfflineBanner extends StatefulWidget {
  final VoidCallback onDismiss;

  const NetflixOfflineBanner({required this.onDismiss, super.key});

  @override
  State<NetflixOfflineBanner> createState() => NetflixOfflineBannerState();
}

class NetflixOfflineBannerState extends State<NetflixOfflineBanner>
    with SingleTickerProviderStateMixin {
  bool _isChecking = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _handleRetry() async {
    if (_isChecking) return;
    setState(() {
      _isChecking = true;
    });

    await NetworkQualityService().measureManual();
    await Future.delayed(const Duration(milliseconds: 800));

    if (mounted) {
      setState(() {
        _isChecking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final showShadow = PerformanceService().shouldShowComplexShadows;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        boxShadow:
            showShadow
                ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 16,
                    spreadRadius: 2,
                    offset: const Offset(0, 8),
                  ),
                ]
                : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1F1F1F).withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFE50914).withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Contenido principal
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            // Icono Wi-Fi con pulso
                            AnimatedBuilder(
                              animation: _pulseController,
                              builder: (context, child) {
                                return Opacity(
                                  opacity:
                                      0.55 + (_pulseController.value * 0.45),
                                  child: child,
                                );
                              },
                              child: const Icon(
                                Icons.wifi_off_rounded,
                                color: Color(0xFFE50914),
                                size: 26,
                              ),
                            ),
                            const SizedBox(width: 12),

                            // Textos
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: const [
                                  Text(
                                    'Sin conexión a Internet',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    'Revisa tu Wi-Fi o datos móviles.',
                                    style: TextStyle(
                                      color: Colors.white60,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),

                            // Botón Reintentar
                            TextButton(
                              onPressed: _handleRetry,
                              style: TextButton.styleFrom(
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.08,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child:
                                  _isChecking
                                      ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                Colors.white,
                                              ),
                                        ),
                                      )
                                      : const Text(
                                        'Reintentar',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                            ),
                            const SizedBox(width: 4),

                            // Botón X para cerrar
                            GestureDetector(
                              onTap: widget.onDismiss,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(
                                  Icons.close_rounded,
                                  color: Colors.white54,
                                  size: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
