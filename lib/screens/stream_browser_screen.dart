import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
import '../widgets/native_ad_widget.dart';
import 'stream_browser_config_screen.dart';
import 'settings_screen.dart';
import '../services/social_rewards_service.dart';
import '../widgets/rate_dialog.dart';

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

  // Slow loading feedback
  bool _showSlowLoadingMessage = false;
  Timer? _slowLoadingTimer;
  Timer? _stallTimer; // Timer for live stream stall detection

  // Search
  // bool _isSearching = false; // REMOVED
  // final TextEditingController _searchController = TextEditingController(); // REMOVED
  final TextEditingController _sourceUrlController = TextEditingController();

  // final FocusNode _searchFocusNode = FocusNode(); // REMOVED
  // Timer? _debounce; // REMOVED
  // List<M3UItem> _searchResults = []; // REMOVED

  // Fixed Categories
  List<String> get _fixedTabs {
    final tabs = ['Inicio', 'Películas', 'Series', 'Telenovelas', 'En Vivo'];

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
  int _bottomNavIndex = 0; // 0=Inicio, 1=Favoritos

  // State
  M3UItem? _heroItem;
  bool _isNavigating = false;
  DateTime? _lastPressedAt;

  // Live TV Sub-state
  String? _selectedLiveCategory; // Active category chip
  Player? _livePlayer;
  VideoController? _liveVideoController;
  final ValueNotifier<VideoController?> _liveVideoControllerNotifier =
      ValueNotifier<VideoController?>(null);
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
  bool _showLiveSearch = false;
  bool _showInlineControls = false;
  Timer? _inlineControlsTimer;

  // -- LIVE TV HEALTH MONITOR STATE --
  Timer? _liveHealthMonitorTimer;
  int _liveStallSeconds = 0;
  bool _isLiveChannel = true;

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
  double? _downloadProgress;
  String? _downloadDetail;

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

  void _toggleInlineControls() {
    setState(() {
      _showInlineControls = !_showInlineControls;
    });
    if (_showInlineControls) {
      _startInlineHideTimer();
    } else {
      _inlineControlsTimer?.cancel();
    }
  }

  void _startInlineHideTimer() {
    _inlineControlsTimer?.cancel();
    _inlineControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showInlineControls = false;
        });
      }
    });
  }

  Future<bool> _onWillPop() async {
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
        if (mounted) setState(() => _showInlineControls = true);
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
    _watchProgressVersion.dispose();
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
        _downloadProgress = null;
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
              if (_heroItem == null || !_m3uService.items.contains(_heroItem)) {
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
                  _downloadProgress =
                      progress.receivedBytes / progress.totalBytes!;
                  _downloadDetail =
                      '${(progress.receivedBytes / 1024 / 1024).toStringAsFixed(1)} MB / ${(progress.totalBytes! / 1024 / 1024).toStringAsFixed(1)} MB';
                } else {
                  _downloadProgress = null;
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
            _downloadProgress = null;
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
        if (_heroItem == null || !_m3uService.items.contains(_heroItem)) {
          _pickHeroItem(_m3uService.latestItems);
        }

        // ── Mover trabajo pesado fuera del UI thread ──────────────────────
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

        // Precarga de imágenes — también diferida al microtask siguiente
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

  Future<void> _onItemTap(M3UItem item) async {
    // Get similar items
    final similarItems = _m3uService.getSimilarItems(item);

    await Navigator.push(
      context,
      FadeScalePageRoute(
        page: ContentDetailScreen(
          item: item,
          similarItems: similarItems,
          onToggleFavorite: (favItem) async {
            await _m3uService.toggleFavorite(favItem);
            if (mounted) setState(() {});
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
          body: PrimaryScrollController(
            controller: _homeScrollController,
            child: SafeArea(
              child: Column(
                children: [
                  _buildAppBar(),
                  Expanded(
                    child:
                        (_isDesktopOrWeb() && !PremiumService().isPremium)
                            ? _buildDesktopPremiumGate()
                            : AnimatedSwitcher(
                              duration: const Duration(milliseconds: 400),
                              switchInCurve: Curves.easeOut,
                              switchOutCurve: Curves.easeIn,
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
                                        key: const ValueKey('content'),
                                        child: _buildStreamContent(),
                                      ),
                            ),
                  ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: _buildBottomNav(),
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
            AppColors.background.withOpacity(0.9),
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
                  color: Colors.amber.withOpacity(0.1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.amber.withOpacity(0.1),
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
                  color: Colors.white.withOpacity(0.7),
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
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.1),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
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
                        color: Colors.white.withOpacity(0.6),
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
                          color: Colors.white.withOpacity(0.3),
                          letterSpacing: 2,
                        ),
                        filled: true,
                        fillColor: Colors.black.withOpacity(0.5),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color:
                                _licenseErrorMessage != null
                                    ? Colors.red.withOpacity(0.5)
                                    : Colors.white.withOpacity(0.2),
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
          color: AppColors.background.withOpacity(0.7),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    value: _downloadProgress,
                    strokeWidth: 3,
                    color: Colors.red,
                  ),
                ),
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
                        '• Prueba conectarte a una VPN\n• Reinicia tu router de internet\n• El servidor podría estar saturado, intenta en unos minutos',
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
    
    // Only pick a new hero item if it's not already set.
    // This makes the banner persistent during the session as requested.
    if (_heroItem != null) return;

    // First try with recentItems from service (already filtered roughly)
    final recentItems = _m3uService.getRecentItems();
    final rawPool = recentItems.isNotEmpty ? recentItems : items;
    
    // STRICT FILTER: No live streams in banner, no Supabase custom content, must be movies/content
    final pool = _m3uService.filterValidItems(rawPool)
        .where((item) {
          if (item.isLive || item.sourceName == 'Supabase') return false;
          final n = item.name.toLowerCase();
          // SAFETY: Check for words that definitely indicate a live channel
          if (n.contains('canal ') || n.contains('tv ') || n.contains('en vivo')) return false;
          return true;
        })
        .toList();

    if (pool.isEmpty) return;

    // Improved year regex: catches 2024, (2024), etc.
    final regexYear = RegExp(r'\b(202[0-9]|19[0-9]{2})\b');

    // 1. Find max year in the current pool
    int maxYear = 0;
    for (var item in pool) {
      final match = regexYear.firstMatch(item.name);
      if (match != null) {
        final yearStr = match.group(1) ?? '';
        final year = int.tryParse(yearStr);
        if (year != null && year > maxYear && year < 2100) {
          maxYear = year;
        }
      }
    }

    // 2. Filter pool strictly by that max year
    List<M3UItem> filteredPool = pool;
    if (maxYear > 0) {
      filteredPool =
          pool.where((item) {
            final match = regexYear.firstMatch(item.name);
            if (match != null) {
              final yearStr = match.group(1) ?? '';
              final year = int.tryParse(yearStr);
              return year == maxYear;
            }
            return false;
          }).toList();
    }

    // Fallback if filtering removed everything (unlikely)
    if (filteredPool.isEmpty) filteredPool = pool;

    // Random selection from strictly filtered pool
    final randomIndex = DateTime.now().microsecond % filteredPool.length;

    setState(() {
      _heroItem = filteredPool[randomIndex];
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
                  color: Colors.red,
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
                      if (item.isSeries) {
                        Navigator.push(
                          context,
                          MaterialFadePageRoute(
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
                                child: LinearProgressIndicator(
                                  value: progress.progressPercentage / 100,
                                  backgroundColor: Colors.black45,
                                  color: Colors.red,
                                  minHeight: 3,
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
          // My List (Favorites) — sin cambios
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
                                  color: Colors.white.withOpacity(0.5),
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

        // ── Contenido principal (tabs Inicio, Películas, Series, etc.) ──
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
                _buildScrollableHeader(), // ← header+tabs scrolleable
                _buildM3USourceInput(),
              ],
            );
          }

          return ValueListenableBuilder<int>(
            valueListenable: _watchProgressVersion,
            builder: (context, version, _) {
              return FutureBuilder<List<WatchProgress>>(
                // El "key" fuerza al FutureBuilder a re-ejecutar el future cuando version cambia
                key: ValueKey(version),
                future: WatchProgressService().getHistory(),
                builder: (context, snapshot) {
                  final history = snapshot.data ?? [];
                  final continueWatchingItems = <Map<String, dynamic>>[];
                  final processedSeries = <String>{};

                  for (var progress in history) {
                    final item = _m3uService.resolveItemFromProgress(progress);

                    if (item == null) continue;

                    if (item.seriesName != null &&
                        item.seriesName!.isNotEmpty) {
                      if (processedSeries.contains(item.seriesName)) continue;
                      processedSeries.add(item.seriesName!);
                    }
                    if (progress.isCompleted) continue;
                    continueWatchingItems.add({
                      'item': item,
                      'progress': progress,
                    });
                  }

                  final homeSections = <Widget>[];

                  // 0. Header + Tabs
                  homeSections.add(_buildScrollableHeader());

                  // 1. Hero
                  homeSections.add(
                    _buildHeroRandomLatest(
                      recentItems.isNotEmpty
                          ? recentItems
                          : _m3uService.latestItems,
                    ),
                  );

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
                  for (int i = 0; i < displayCategories.length; i++) {
                    final cat = displayCategories[i];
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

                  return ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: homeSections.length,
                    itemBuilder: (context, index) => homeSections[index],
                  );
                },
              );
            },
          );
        } else if (_selectedTab == 'En Vivo') {
          return _buildLiveContent();
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

          return ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 20),
            itemCount:
                1 + // header+tabs
                novelaCategories.length +
                1 +
                curatedNovelaLists.length,
            itemBuilder: (context, index) {
              if (index == 0) return _buildScrollableHeader(); // ← header+tabs
              final i = index - 1;

              if (i == 0) {
                return _buildCategoryRow(
                  'Todas las Telenovelas',
                  allNovelaItems,
                );
              }
              final curatedIndex = i - 2;
              if (curatedIndex >= 0 &&
                  curatedIndex < curatedNovelaLists.length) {
                final curated = curatedNovelaLists[curatedIndex];
                return _buildCategoryRow(curated['title'], curated['items']);
              }
              final catIndex = i - 2 - curatedNovelaLists.length;
              if (catIndex < 0 || catIndex >= novelaCategories.length) {
                return const SizedBox.shrink();
              }
              final cat = novelaCategories[catIndex];
              return _buildCategoryRow(
                cat,
                _m3uService.getItemsByCategory(cat),
              );
            },
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
              _buildScrollableHeader(), // ← header+tabs
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
              if (index == 0) return _buildScrollableHeader(); // ← header+tabs
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

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 20),
      itemCount: 1 + movieCategories.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) return _buildScrollableHeader(); // ← header+tabs
        final i = index - 1;
        if (i == 0) return _buildCategoryRow('Todas las Películas', movies);
        if (i == 1 && recentMovies.isNotEmpty) {
          return _buildCategoryRow('Nuevas películas de hoy', recentMovies);
        }
        if (i == 1 && recentMovies.isEmpty) return const SizedBox.shrink();
        final cat = movieCategories[i - 2];
        final catItems =
            _m3uService
                .getItemsByCategory(cat)
                .where((i) => !i.isSeries && !i.isLive)
                .toList();
        return _buildCategoryRow(cat, catItems);
      },
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

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 20),
      itemCount: 1 + seriesCategories.length + 2 + curatedLists.length,
      itemBuilder: (context, index) {
        if (index == 0) return _buildScrollableHeader(); // ← header+tabs
        final i = index - 1;
        if (i == 0) return _buildCategoryRow('Todas las Series', series);
        if (i == 1 && recentSeries.isNotEmpty) {
          return _buildCategoryRow('Nuevas series de hoy', recentSeries);
        }
        if (i == 1 && recentSeries.isEmpty) return const SizedBox.shrink();
        final curatedIndex = i - 2;
        if (curatedIndex >= 0 && curatedIndex < curatedLists.length) {
          final curated = curatedLists[curatedIndex];
          return _buildCategoryRow(curated['title'], curated['items']);
        }
        final catIndex = i - 2 - curatedLists.length;
        if (catIndex < 0 || catIndex >= seriesCategories.length) {
          return const SizedBox.shrink();
        }
        final cat = seriesCategories[catIndex];
        final catItems =
            _m3uService
                .getItemsByCategory(cat)
                .where((i) => i.isSeries && !i.isLive)
                .toList();
        return _buildCategoryRow(cat, catItems);
      },
    );
  }

  Future<void> _disposeLivePlayer() async {
    // -- CRITICAL DISPOSAL SEQUENCE FOR MOTOROLA/ANDROID 15 --
    // Set guard FIRST so _playLiveChannel won't create a new player
    // while this one is still draining its native event queue.
    _isDisposingLivePlayer = true;

    _liveDurationTimer?.cancel();
    _liveDurationTimer = null;
    _liveSecondsWatched = 0;
    _liveAdCountdownNotifier.value = null;
    _liveMidRollNoticeShown = false;
    _hasViewedLiveMidRollAd = false;

    _liveHealthMonitorTimer?.cancel();
    _liveHealthMonitorTimer = null;
    _stallTimer?.cancel();
    _recoveryTimer?.cancel();

    // 1. Cancel Dart-side subscriptions FIRST so no new events reach Dart.
    for (final s in _liveStreamSubscriptions) {
      s.cancel();
    }
    _liveStreamSubscriptions.clear();

    final pToStop = _livePlayer;

    // 2. Silence the native MPV engine and kill video output.
    try {
      final mpv = pToStop?.platform as dynamic;
      mpv?.setProperty('msg-level', 'all=no');
      mpv?.setProperty('log-level', 'no');
      mpv?.setProperty('vid', 'no');
      mpv?.setProperty('vo', 'null');
    } catch (_) {}

    // 3. Stop decoding.
    pToStop?.stop();

    // 4. Unmount the Flutter video surface.
    _liveVideoControllerNotifier.value = null;
    _liveVideoController = null;

    // 5. Null our Dart reference immediately.
    _livePlayer = null;
    _currentLiveChannel = null;
    _isLiveLoading = false;
    _isLiveReloading = false;
    _isLiveError = false;
    _liveRetryCount = 0;
    _liveSpeedNotifier.value = '0 B/s';
    WakelockPlus.disable();

    if (pToStop != null) {
      // 6. Give the native thread 800ms to finish draining before disposal.
      // This is the extra safety window for Motorola's slow Surface release.
      await Future.delayed(const Duration(milliseconds: 800));
      pToStop.dispose();
    }

    _isDisposingLivePlayer = false;
  }

  Future<void> _playLiveChannel(M3UItem item) async {
    // Same channel already playing, do nothing
    if (_currentLiveChannel?.url == item.url && _livePlayer != null) return;

    // Guard: don't start a new player while the previous one is draining.
    // The user tapped quickly — try again after the drain window completes.
    if (_isDisposingLivePlayer) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
    }

    // Pause current channel before showing ad to prevent background audio
    if (_livePlayer != null && _livePlayer!.state.playing) {
      _livePlayer!.pause();
      _liveAdCountdownNotifier.value = null;
    }

    // Show rewarded ad with confirmation EVERY switch
    // Premium users are handled inside showRewardedAdWithConfirmation (it auto-skips)
    AdService().showRewardedAdWithConfirmation(
      context,
      onUserEarnedReward: () async {
        _startLivePlayback(item);
      },
      onAdFailed: () {
        if (!mounted) return;
        _startLivePlayback(item);
      },
      message:
          '¡Señal disponible! Mira un breve anuncio para conectar con la transmisión en vivo y disfrutar sin límites.',
    );
  }

  Future<void> _startLivePlayback(M3UItem item) async {
    if (!mounted) return;

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
      _liveStreamSubscriptions.add(
        _livePlayer!.stream.completed.listen((completed) {
          if (completed && mounted && !_isLiveError) {
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted) _reloadLiveSignal();
            });
          }
        }),
      );

      // Reload automático en error de red
      _liveStreamSubscriptions.add(
        _livePlayer!.stream.error.listen((error) {
          debugPrint('Player error: $error');
          if (mounted && !_isLiveError && !_isLiveReloading) {
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

    // Configurar MPV para máxima resiliencia
    await Future.microtask(() async {
      try {
        final platform = _livePlayer?.platform as dynamic;
        if (platform == null) return;

        final url = item.url.toLowerCase();
        _isLiveChannel =
            url.contains('/live/') ||
            url.contains('type=live') ||
            (url.endsWith('.m3u8') && !url.contains('/vod/'));

        // Buffer y caché
        await platform.setProperty('cache', 'yes');
        await platform.setProperty(
          'cache-pause',
          'no',
        ); // no pausar al rellenar buffer
        await platform.setProperty(
          'cache-pause-wait',
          '2',
        ); // tolerar 2s antes de pausar
        await platform.setProperty(
          'cache-secs',
          '45',
        ); // 45s de buffer adelante
        await platform.setProperty(
          'cache-back-buffer-size',
          '67108864',
        ); // 64 MB buffer atrás
        await platform.setProperty(
          'demuxer-max-bytes',
          '268435456',
        ); // 256 MB demuxer

        // Red y reconexión automática
        await platform.setProperty('network-timeout', '15');
        await platform.setProperty(
          'stream-lavf-o',
          'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
        );
        await platform.setProperty('http-reconnect', 'yes');
        await platform.setProperty('http-reconnect-sleep', '2');
        await platform.setProperty('http-header-fields', 'Icy-MetaData:1');

        // HLS específico (streams en vivo)
        if (_isLiveChannel) {
          await platform.setProperty('hls-bitrate', 'max');
          await platform.setProperty('hls-forward-cache-secs', '30');
          await platform.setProperty('hls-back-cache-secs', '10');
          await platform.setProperty('demuxer-lavf-hacks', 'yes');
          await platform.setProperty(
            'demuxer-cache-wait',
            'no',
          ); // no esperar llenado de caché
        } else {
          await platform.setProperty('cache-secs', '60');
        }

        // Decodificación eficiente
        await platform.setProperty(
          'hwdec',
          'auto-safe',
        ); // GPU si está disponible
        await platform.setProperty('vd-lavc-threads', '0'); // auto-threads
        await platform.setProperty(
          'framedrop',
          'vo',
        ); // descarta frames antes de cortar

        // Audio estable
        await platform.setProperty(
          'audio-buffer',
          '0.5',
        ); // 500ms buffer de audio
        await platform.setProperty(
          'audio-stream-silence',
          'yes',
        ); // silencio en gaps (no corte)

        // Sincronización suave
        await platform.setProperty('video-sync', 'audio');
        await platform.setProperty('interpolation', 'no');
      } catch (e) {
        debugPrint('Error configurando MPV: $e');
      }
    });

    // Abrir el stream con headers completos
    try {
      await _livePlayer!.open(
        Media(
          item.url,
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
        _showInlineControls = true;
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
      _startLiveHealthMonitor();
    }
  }

  void _startLiveHealthMonitor() {
    Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted || _livePlayer == null) {
        timer.cancel();
        return;
      }
      if (_liveVideoControllerNotifier.value == null) {
        timer.cancel();
        return;
      }

      final state = _livePlayer!.state;

      // ── Fix pantalla negra con audio ──────────────────────────────
      // Si hay audio pero el video reporta 0x0, forzar re-render del widget
      // sin reiniciar el stream (mucho más rápido y sin corte de audio)
      if (state.playing &&
          !state.buffering &&
          state.width != null &&
          state.height != null &&
          state.width == 0 &&
          state.height == 0 &&
          !_isLiveReloading &&
          !_isLiveLoading) {
        debugPrint(
          'Health: pantalla negra detectada (0x0). Forzando re-render...',
        );

        // Primero intentar re-render sin reiniciar el player
        if (mounted) {
          setState(() {
            _liveVideoControllerNotifier.value = null;
          });
          Future.delayed(const Duration(milliseconds: 100), () {
            if (mounted) {
              setState(() {
                _liveVideoControllerNotifier.value = _liveVideoController;
              });
            }
          });
        }

        // Si después de 5s sigue sin video, ahí sí recargamos el stream
        Future.delayed(const Duration(seconds: 5), () {
          if (!mounted || _livePlayer == null) return;
          final s = _livePlayer!.state;
          if (s.width == 0 && s.height == 0 && !_isLiveReloading) {
            debugPrint('Health: re-render no resolvió. Recargando stream...');
            timer.cancel();
            _reloadLiveSignal();
          }
        });
      }
    });
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
        _showInlineControls = false;
      });
    }
    WakelockPlus.disable();
  }

  void _startLiveStallMonitor() {
    _liveHealthMonitorTimer?.cancel();
    _liveStallSeconds = 0;

    _liveHealthMonitorTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      if (!mounted || _livePlayer == null) return;

      final playerState = _livePlayer!.state;

      // Detección de stall con umbrales más generosos
      if (playerState.buffering) {
        _liveStallSeconds++;
        // Live: 20s, VOD: 30s — más tolerante que el original (15s/20s)
        final int threshold = _isLiveChannel ? 20 : 30;

        if (_liveStallSeconds >= threshold && !_isLiveReloading) {
          debugPrint(
            'Stall persistente (${_liveStallSeconds}s). Recargando...',
          );
          _liveStallSeconds = 0;
          _reloadLiveSignal();
        }
      } else {
        if (_liveStallSeconds > 3) {
          debugPrint('Buffer recuperado tras $_liveStallSeconds s.');
        }
        _liveStallSeconds = 0;
      }

      // Velocidad de descarga
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
    });
  }

  Future<void> _reloadLiveSignal() async {
    if (!mounted ||
        _currentLiveChannel == null ||
        _isLiveReloading ||
        _isLiveError) {
      return;
    }

    // Backoff progresivo más suave: 2s, 4s, 8s, 12s, 20s, 30s
    const backoffDelays = [2, 4, 8, 12, 20, 30];
    final int attemptIndex =
        _liveRetryCount < backoffDelays.length
            ? _liveRetryCount
            : backoffDelays.length - 1;
    final delay = backoffDelays[attemptIndex];

    if (_liveRetryCount < 5) {
      // ── Recuperación rápida (intentos 0 y 1): reabrir sin destruir player ──
      if (_liveRetryCount < 2 && _livePlayer != null) {
        debugPrint(
          'Recuperación rápida #${_liveRetryCount + 1} (reopen sin reiniciar)...',
        );
        setState(() {
          _isLiveReloading = true;
          _isLiveLoading = true;
          _liveRetryCount++;
        });
        try {
          final channel = _currentLiveChannel!;
          await _livePlayer!.open(
            Media(
              channel.url,
              httpHeaders: {
                'User-Agent': _getRandomUserAgent(),
                'Accept': '*/*',
                'Connection': 'keep-alive',
                'Cache-Control': 'no-cache',
              },
            ),
            play: true,
          );
          if (mounted) {
            setState(() {
              _isLiveLoading = false;
              _isLiveReloading = false;
            });
          }
          return; // Éxito — no destruimos el player
        } catch (_) {
          // Falló la recuperación rápida, continuamos con reinicio
        }
      }

      // ── Recuperación completa (intentos 2+): reiniciar player ──
      setState(() {
        _isLiveReloading = true;
        _isLiveLoading = true;
        _liveRetryCount++;
      });

      debugPrint(
        'Recargando stream en ${delay}s (intento $_liveRetryCount)...',
      );
      await Future.delayed(Duration(seconds: delay));

      if (mounted && _currentLiveChannel != null) {
        final channel = _currentLiveChannel!;
        final savedCount = _liveRetryCount;
        _disposeLivePlayer();
        _liveRetryCount = savedCount;
        _currentLiveChannel = channel;
        _startLivePlayback(channel);
      }
    } else {
      // 5 intentos fallidos → buscar espejo
      if (!_isUsingMirror && _currentLiveChannel != null) {
        _liveRetryCount = 0;
        _startMirrorPlayback();
      } else {
        debugPrint('Sin espejo. Reintentando en ${delay}s...');
        setState(() {
          _isLiveReloading = true;
          _isLiveLoading = true;
          _liveRetryCount++;
        });

        await Future.delayed(Duration(seconds: delay));

        if (mounted && _currentLiveChannel != null) {
          final channel = _currentLiveChannel!;
          final savedCount = _liveRetryCount;
          _disposeLivePlayer();
          _liveRetryCount = savedCount;
          _currentLiveChannel = channel;
          _startLivePlayback(channel);
        }
      }
    }
  }

  Future<void> _startMirrorPlayback() async {
    if (!mounted || _currentLiveChannel == null) return;

    final mirror = M3UService().findMirrorChannel(_currentLiveChannel!);

    if (mirror != null) {
      debugPrint('Found mirror channel: ${mirror.name} (${mirror.url})');

      setState(() {
        _originalLiveChannel = _currentLiveChannel;
        _isUsingMirror = true;
        _isLiveReloading = true;
        _isLiveLoading = true;
      });

      _disposeLivePlayer();
      _startLivePlayback(mirror);

      // Start background recovery check for the original channel
      _startBackgroundRecovery();
    } else {
      debugPrint('No mirror found for ${_currentLiveChannel!.name}');
      setState(() {
        _isLiveReloading = false;
        _isLiveLoading = false;
        _isLiveError = true;
      });
      _stopLivePlayer();
      if (mounted) {
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
      debugPrint('Checking original channel: ${_originalLiveChannel!.url}');
      final response = await http
          .head(
            Uri.parse(_originalLiveChannel!.url),
            headers: {'User-Agent': _getRandomUserAgent()},
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode >= 200 && response.statusCode < 400) {
        debugPrint('Original channel is back! Swapping...');
        _recoveryTimer?.cancel();

        if (mounted) {
          setState(() {
            _isUsingMirror = false;
            _isLiveReloading = true; // Prevent other reloads during swap
            _isLiveLoading = true;
          });

          final original = _originalLiveChannel!;
          _originalLiveChannel = null;

          _disposeLivePlayer();
          _startLivePlayback(original);
        }
      } else {
        debugPrint(
          'Original channel still down (Status: ${response.statusCode})',
        );
      }
    } catch (e) {
      debugPrint('Original channel still down (Error: $e)');
    }
  }

  void _triggerLiveMidRollAd() {
    if (!mounted || _livePlayer == null) return;

    _livePlayer!.pause();
    if (mounted) setState(() => _showInlineControls = true);

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

  void _showLiveReportOptions(M3UItem item) {
    final reasons = [
      'No carga el video',
      'Se traba / Mucho buffering',
      'Audio desincronizado / Sin audio',
      'Mala calidad de imagen',
      'Canal equivocado',
      'Otro problema',
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a1a1a),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 20,
                  horizontal: 24,
                ),
                child: Text(
                  'Reportar problema: ${item.name}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: reasons.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      title: Text(
                        reasons[index],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right,
                        color: Colors.white54,
                      ),
                      onTap: () async {
                        Navigator.pop(context);
                        final success = await _m3uService.reportContent(
                          name: item.name,
                          category: item.category,
                          url: item.url,
                          reason: reasons[index],
                        );
                        if (mounted) {
                          SnackBarUtils.showAppSnackBar(
                            context,
                            success
                                ? 'Reporte enviado. ¡Gracias!'
                                : 'Error al enviar reporte',
                          );
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _enterFullscreen() async {
    if (_liveVideoController == null) return;

    final isDesktopOrWeb =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;

    if (!isDesktopOrWeb) {
      // Force Landscape
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    if (!mounted) return;

    // Reset search state when entering fullscreen
    // _showLiveSearch = false;
    // _liveSearchController.clear();

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) => _FullscreenLivePlayer(
              controllerNotifier: _liveVideoControllerNotifier,
              channelName: _currentLiveChannel?.name ?? 'Live TV',
              adCountdownNotifier: _liveAdCountdownNotifier,
              speedNotifier: _liveSpeedNotifier,
              item: _currentLiveChannel!,
              onReport: _showLiveReportOptions,
            ),
      ),
    );

    if (!isDesktopOrWeb) {
      // Restore Portrait
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  Widget _buildLiveContent() {
    final liveItems = _m3uService.items.where((i) => i.isLive).toList();
    final liveCategories =
        liveItems.map((i) => i.category).toSet().toList()..sort();

    if (liveCategories.isNotEmpty) {
      liveCategories.insert(0, 'Todos');
      liveCategories.insert(1, 'Mi Lista');
    }

    if (_selectedLiveCategory == null && liveCategories.isNotEmpty) {
      _selectedLiveCategory = 'Todos';
    }

    var filteredItems = liveItems;
    if (_selectedLiveCategory == 'Todos') {
      filteredItems = liveItems;
    } else if (_selectedLiveCategory == 'Mi Lista') {
      filteredItems = liveItems.where((i) => i.isFavorite).toList();
    } else {
      filteredItems =
          liveItems.where((i) => i.category == _selectedLiveCategory).toList();
    }

    if (_showLiveSearch && _liveSearchController.text.isNotEmpty) {
      final query = _liveSearchController.text.toLowerCase();
      filteredItems =
          filteredItems
              .where((i) => i.name.toLowerCase().contains(query))
              .toList();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate video height: 16:9 ratio, but cap at 40% of available height
        final videoWidth = constraints.maxWidth;
        final idealVideoHeight = videoWidth * 9 / 16;
        final maxVideoHeight = constraints.maxHeight * 0.40;
        final videoHeight = idealVideoHeight.clamp(0.0, maxVideoHeight);

        return Column(
          children: [
            // Fixed Search Header + Main Tabs
            _buildScrollableHeader(),

            // Fixed Inline Player
            SizedBox(
              width: double.infinity,
              height: videoHeight,
              child: Container(
                color: const Color.fromARGB(255, 3, 3, 3),
                child: ValueListenableBuilder<VideoController?>(
                  valueListenable: _liveVideoControllerNotifier,
                  builder: (context, controller, _) {
                    if (controller == null) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              CupertinoIcons.tv,
                              size: 40,
                              color: Colors.white.withOpacity(0.15),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Selecciona un canal',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.3),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return GestureDetector(
                      onTap: _toggleInlineControls,
                      behavior: HitTestBehavior.translucent,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Video(
                            key: ValueKey('live_inline_${controller.hashCode}'),
                            controller: controller,
                            fit: BoxFit.contain,
                            fill: Colors.black,
                            controls: (state) => const SizedBox.shrink(),
                          ),
                          ValueListenableBuilder<int?>(
                            valueListenable: _liveAdCountdownNotifier,
                            builder: (context, countdown, _) {
                              if (countdown == null) {
                                return const SizedBox.shrink();
                              }
                              return Positioned(
                                top: 10,
                                left: 10,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.background.withOpacity(
                                      0.7,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.white24,
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.info_outline,
                                        color: Colors.yellow,
                                        size: 17.8,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Anuncio en $countdown...',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                          Positioned(
                            top: 10,
                            left: 10,
                            child: ValueListenableBuilder<String>(
                              valueListenable: _liveSpeedNotifier,
                              builder: (context, speed, _) {
                                return ValueListenableBuilder<int?>(
                                  valueListenable: _liveAdCountdownNotifier,
                                  builder: (context, countdown, _) {
                                    return AnimatedPadding(
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                      padding: EdgeInsets.only(
                                        top: countdown != null ? 35 : 0,
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black45,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: Colors.white10,
                                            width: 0.5,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.download_rounded,
                                              color: Colors.white60,
                                              size: 10,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              speed,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                fontFamily: 'monospace',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                          if (_isLiveLoading)
                            const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          else
                            StreamBuilder<bool>(
                              stream: controller.player.stream.buffering,
                              builder: (context, snapshot) {
                                if (snapshot.data == true) {
                                  return const Center(
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  );
                                }
                                return const SizedBox.shrink();
                              },
                            ),
                          Positioned.fill(
                            child: IgnorePointer(
                              ignoring: !_showInlineControls,
                              child: AnimatedOpacity(
                                opacity: _showInlineControls ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 300),
                                child: Stack(
                                  children: [
                                    if (_currentLiveChannel != null)
                                      Positioned(
                                        top: 8,
                                        right: 8,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black54,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            _currentLiveChannel!.name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                    Positioned(
                                      bottom: 8,
                                      left: 8,
                                      child: StreamBuilder<bool>(
                                        stream:
                                            controller.player.stream.playing,
                                        initialData:
                                            controller.player.state.playing,
                                        builder: (context, snapshot) {
                                          final isPlaying =
                                              snapshot.data ?? false;
                                          return IconButton(
                                            icon: Icon(
                                              isPlaying
                                                  ? Icons.pause
                                                  : Icons.play_arrow,
                                              color: Colors.white,
                                              size: 32,
                                            ),
                                            onPressed: () {
                                              _startInlineHideTimer();
                                              controller.player.playOrPause();
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                    Positioned(
                                      bottom: 12,
                                      right: 12,
                                      child: IconButton(
                                        icon: const Icon(
                                          Icons.fullscreen,
                                          color: Colors.white,
                                          size: 28,
                                        ),
                                        onPressed: _enterFullscreen,
                                      ),
                                    ),
                                  ],
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
            ),

            // Fixed Category Chips + Search Bar
            Container(
              height: 54,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white10, width: 1),
                ),
              ),
              child:
                  _showLiveSearch
                      ? Row(
                        children: [
                          const Icon(
                            Icons.search,
                            color: Colors.white54,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _liveSearchController,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'Buscar en $_selectedLiveCategory...',
                                hintStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.5),
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              onChanged: (val) => setState(() {}),
                              autofocus: true,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            onPressed: () {
                              setState(() {
                                _showLiveSearch = false;
                                _liveSearchController.clear();
                              });
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      )
                      : Row(
                        children: [
                          Expanded(
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: liveCategories.length,
                              itemBuilder: (context, catIdx) {
                                final category = liveCategories[catIdx];
                                final isSelected =
                                    _selectedLiveCategory == category;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap:
                                          () => setState(
                                            () =>
                                                _selectedLiveCategory =
                                                    category,
                                          ),
                                      borderRadius: BorderRadius.circular(9),
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          gradient:
                                              isSelected
                                                  ? const LinearGradient(
                                                    colors: [
                                                      Color.fromARGB(
                                                        235,
                                                        229,
                                                        9,
                                                        20,
                                                      ),
                                                      Color.fromARGB(
                                                        255,
                                                        206,
                                                        31,
                                                        31,
                                                      ),
                                                    ],
                                                    begin: Alignment.topLeft,
                                                    end: Alignment.bottomRight,
                                                  )
                                                  : null,
                                          color:
                                              isSelected
                                                  ? null
                                                  : const Color.fromARGB(
                                                    0,
                                                    20,
                                                    20,
                                                    20,
                                                  ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color:
                                                isSelected
                                                    ? Colors.transparent
                                                    : const Color.fromARGB(
                                                      0,
                                                      255,
                                                      255,
                                                      255,
                                                    ),
                                            width: 1,
                                          ),
                                        ),
                                        child: Text(
                                          category,
                                          style: TextStyle(
                                            color:
                                                isSelected
                                                    ? Colors.white
                                                    : const Color.fromARGB(
                                                      144,
                                                      255,
                                                      255,
                                                      255,
                                                    ),
                                            fontSize: 13,
                                            fontWeight:
                                                isSelected
                                                    ? FontWeight.w600
                                                    : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed:
                                () => setState(() => _showLiveSearch = true),
                            icon: const Icon(
                              Icons.search,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
            ),

            // Scrollable expanded area
            Expanded(
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom + 20,
                ),
                itemCount:
                    filteredItems.isEmpty
                        ? 1
                        : (filteredItems.length +
                            (filteredItems.length / 7).floor()),
                itemBuilder: (context, index) {
                  if (filteredItems.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 100),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              CupertinoIcons.tv,
                              size: 43,
                              color: Color.fromARGB(59, 143, 143, 143),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'No hay canales en esta categoría',
                              style: TextStyle(
                                color: Color.fromARGB(153, 153, 153, 153),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  final isAd = (index + 1) % 8 == 0;
                  if (isAd) return const NativeAdWidget(height: 130);

                  final itemIndex = index - (index / 8).floor();
                  if (itemIndex >= filteredItems.length) {
                    return const SizedBox.shrink();
                  }
                  return _buildLiveChannelTile(
                    filteredItems[itemIndex],
                    itemIndex,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLiveChannelTile(M3UItem item, int index) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child:
              item.logo != null && item.logo!.isNotEmpty
                  ? FastChannelLogo(
                    url: item.logo,
                    size: 48,
                    borderRadius: BorderRadius.circular(8),
                  )
                  : const Icon(Icons.tv, color: Colors.white12),
        ),
      ),
      title: Row(
        children: [
          Text(
            (index + 1).toString().padLeft(3, '0'),
            style: const TextStyle(
              color: Colors.red,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(left: 36),
        child: Text(
          item.category,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),
      ),
      trailing: IconButton(
        icon: Icon(
          Icons.arrow_circle_right_outlined,
          color:
              _currentLiveChannel?.url == item.url
                  ? Colors.red
                  : Colors.white.withValues(alpha: 0.2),
          size: 28,
        ),
        onPressed: () => _playLiveChannel(item),
      ),
      onTap: () => _playLiveChannel(item),
      onLongPress: () async {
        // If removing favorite, always allow
        if (!item.isFavorite) {
          // Check live-specific limit for free users
          final liveFavCount =
              _m3uService.getFavorites().where((i) => i.isLive).length;
          if (!PremiumService().canAddLiveFavorite(liveFavCount)) {
            if (!context.mounted) return;
            SnackBarUtils.showAppSnackBar(
              context,
              'Máximo 4 canales en Mi Lista. ¡Hazte Premium para ilimitados!',
            );
            return;
          }
        }
        try {
          await _m3uService.toggleFavorite(item);
        } catch (e) {
          if (!mounted) return;
          SnackBarUtils.showAppSnackBar(context, e.toString());
          return;
        }
        setState(() {});
        if (!mounted) return;
        SnackBarUtils.showAppSnackBar(
          context,
          item.isFavorite ? 'Añadido a Mi lista' : 'Eliminado de Mi lista',
        );
      },
    );
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
        // Dispose live player when leaving En Vivo tab
        if (_selectedTab == 'En Vivo' && title != 'En Vivo') {
          _disposeLivePlayer();
        }
        setState(() {
          _selectedTab = title;
        });
      },
      child: Container(
        margin: const EdgeInsets.only(right: 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border:
              isSelected
                  ? const Border(
                    bottom: BorderSide(color: Colors.red, width: 2),
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
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const StreamBrowserConfigScreen(),
      ),
    );
    // Refresh when coming back in case sources changed
    setState(() => _isLoading = true);
    await _initService();
  }

  Widget _buildHeroRandomLatest(List<M3UItem> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    if (_heroItem != null) return _buildHeroBanner(_heroItem!);

    // Fallback logic if _heroItem isn't ready:
    // Filter out lives and supabase content even in this random picker
    final validVods =
        items
            .where((i) => !i.isLive && i.sourceName != 'Supabase')
            .where((i) {
              final n = i.name.toLowerCase();
              return !n.contains('canal ') &&
                  !n.contains('tv ') &&
                  !n.contains('en vivo');
            })
            .toList();

    if (validVods.isEmpty) {
      // Show shimmer instead of risking a live channel display
      return const _HiddenMoviesShimmer();
    }

    final random = validVods[DateTime.now().millisecond % validVods.length];
    return _buildHeroBanner(random);
  }

  Widget _buildM3USourceInput() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF1a1a1a),
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
                backgroundColor: Colors.red.withOpacity(0.1),
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
          border: Border.all(color: iconColor.withOpacity(0.3)),
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
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.3)),
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
                        color: const Color(0xFF2B2B2B),
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
                    color: Colors.white.withOpacity(0.5),
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
    return GestureDetector(
      onTap: () => _onItemTap(item),
      child: Container(
        height: 500,
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
                    // Background Image (Poster)
                    FastThumbnail(
                      url: item.logo,
                      title: item.name,
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                      cacheWidth: null, // resolución completa para el hero
                      isSeries: item.isSeries,
                      useTMDBFallback: !item.isLive,
                      onError: () {
                        if (item.logo != null && item.logo!.isNotEmpty) {
                          _m3uService.reportFailedLogo(item.logo!);
                        }
                      },
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
                                _playItem(item);
                              },
                              icon: const Icon(
                                Icons.play_arrow,
                                color: AppColors.background,
                              ),
                              label: const Text(
                                'Reproducir',
                                style: TextStyle(
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
                                await _m3uService.toggleFavorite(item);
                                setState(() {});
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
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: filteredItems.length,
                    cacheExtent: performance.isLowPerformance ? 0 : 500,
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: true,
                    itemBuilder: (context, index) {
                      return _buildHorizontalCard(filteredItems[index]);
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
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: topItems.length,
              cacheExtent: 500,
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
    return GestureDetector(
      onTap: () => _onItemTap(item),
      onLongPress: () async {
        await _m3uService.toggleFavorite(item);
        setState(() {});
        if (!mounted) return;
        SnackBarUtils.showAppSnackBar(
          context,
          item.isFavorite ? 'Añadido a Mi lista' : 'Eliminado de Mi lista',
        );
      },
      child: Container(
        width: rank >= 10 ? 215 : 175,
        margin: const EdgeInsets.symmetric(horizontal: 10),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // ── Large rank number (behind the poster) ──
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
            // ── Movie poster ──
            Positioned(
              left: rank < 10 ? 55 : 95,
              top: 0,
              bottom: 5,
              right: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ClipRRect(
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

  Widget _buildHorizontalCard(M3UItem item) {
    return GestureDetector(
      onTap: () => _onItemTap(item),
      onLongPress: () async {
        await _m3uService.toggleFavorite(item);
        setState(() {});
        if (!mounted) return;
        SnackBarUtils.showAppSnackBar(
          context,
          item.isFavorite ? 'Añadido a Mi lista' : 'Eliminado de Mi lista',
        );
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
                      color: const Color(0xFF1a1a1a),
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
                    child: ClipRRect(
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
    );
  }

  // _buildSearchGrid removed

  Widget _buildGridCard(M3UItem item, {bool showTitle = true}) {
    return RepaintBoundary(
      child: GestureDetector(
        onTap: () => _onItemTap(item),
        onLongPress: () async {
          await _m3uService.toggleFavorite(item);
          setState(() {});
          if (!mounted) return;
          SnackBarUtils.showAppSnackBar(
            context,
            item.isFavorite ? 'Añadido a Mi lista' : 'Eliminado de Mi lista',
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1a1a1a),
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
                    child: ClipRRect(
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
                  if (_bottomNavIndex == 1)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: GestureDetector(
                        onTap: () async {
                          await _m3uService.toggleFavorite(item);
                          setState(() {});
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
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
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
          color: const Color(0xFF1a1a1a),
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

  const _FullscreenLivePlayer({
    required this.controllerNotifier,
    required this.channelName,
    required this.adCountdownNotifier,
    required this.speedNotifier,
    required this.item,
    required this.onReport,
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

    // Optimize buffering for fluidity in fullscreen
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final player = widget.controllerNotifier.value?.player;
        final platform = player?.platform as dynamic;
        if (platform != null) {
          await platform.setProperty('cache', 'yes');
          await platform.setProperty('demuxer-max-bytes', '134217728');
          await platform.setProperty('cache-pause', 'no'); // No cuts
          await platform.setProperty('hls-bitrate', 'max');
        }
      } catch (_) {}
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
                  child: ValueListenableBuilder<VideoController?>(
                    valueListenable: widget.controllerNotifier,
                    builder: (context, controller, child) {
                      if (controller == null) {
                        return const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        );
                      }
                      return Video(
                        key: ValueKey(controller.hashCode),
                        controller: controller,
                        controls: (state) => const SizedBox.shrink(),
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
    _timer = Timer.periodic(widget.interval, (timer) {
      if (!mounted) return;
      setState(() {
        _currentIndex = (_currentIndex + 1) % widget.suggestions.length;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.suggestions.isEmpty) return const SizedBox.shrink();

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
                child.key == ValueKey<String>(widget.suggestions[_currentIndex])
                    ? inAnimation
                    : outAnimation,
            child: child,
          );
        },
        child: Container(
          key: ValueKey<String>(widget.suggestions[_currentIndex]),
          height: 20, // constrain height to text size to prevent overflow
          alignment: Alignment.centerLeft,
          child: Text(
            widget.suggestions[_currentIndex],
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
      baseColor: const Color(0xFF1a1a1a),
      highlightColor: const Color(0xFF2B2B2B),
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
                        color: const Color(0xFF2B2B2B),
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
          FadeScalePageRoute(
            page: ContentDetailScreen(
              item: item,
              similarItems: similarItems,
              onToggleFavorite: (favItem) async {
                await widget.m3uService.toggleFavorite(favItem);
                if (mounted) setState(() {});
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
          FadeScalePageRoute(
            page: ContentDetailScreen(
              item: item,
              similarItems: similarItems,
              onToggleFavorite: (favItem) async {
                await widget.m3uService.toggleFavorite(favItem);
                if (mounted) setState(() {});
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
