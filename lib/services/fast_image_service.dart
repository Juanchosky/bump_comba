import 'dart:io';
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'performance_service.dart';
import 'metadata_fallback_service.dart';
import 'network_quality_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FAILED IMAGE TRACKER — Retries on app resume
// ─────────────────────────────────────────────────────────────────────────────

/// Global tracker that watches for app lifecycle changes and triggers
/// silent retries on all registered widgets when the app comes back
/// to the foreground. This handles the common case where images fail
/// due to a momentary network issue and the user backgrounds the app.
class _FailedImageTracker with WidgetsBindingObserver {
  static final _FailedImageTracker instance = _FailedImageTracker._();
  _FailedImageTracker._();

  bool _initialized = false;
  final Set<VoidCallback> _retryCallbacks = {};
  NetworkQuality _lastQuality = NetworkQuality.excellent;

  void init() {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);

    // Dynamically adjust global image cache based on device hardware performance limits
    final performance = PerformanceService();
    if (performance.lowMemoryLimit) {
      PaintingBinding.instance.imageCache.maximumSize = 500;
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          50 * 1024 * 1024; // 50MB
    } else if (performance.isLowPerformance) {
      PaintingBinding.instance.imageCache.maximumSize = 1000;
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          100 * 1024 * 1024; // 100MB
    } else {
      PaintingBinding.instance.imageCache.maximumSize = 3000;
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          250 * 1024 * 1024; // 250MB
    }

    // Silence Flutter's internal "image resource service" error logs for
    // TimeoutExceptions and network errors. We already handle these gracefully
    // in each widget's errorBuilder, so the default console spam is unnecessary.
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      final isImageService = details.library == 'image resource service';
      if (isImageService) {
        // Silently swallow image loading errors — our widgets handle them
        return;
      }
      // Forward all other errors to the original handler
      originalOnError?.call(details);
    };

    // Listen to network quality changes — auto-retry all failed images
    // when network recovers from offline/poor to fair/good/excellent
    _lastQuality = NetworkQualityService().quality.value;
    _adaptConnectionLimits(_lastQuality);
    NetworkQualityService().quality.addListener(_onNetworkQualityChanged);
  }

  void _onNetworkQualityChanged() {
    final newQuality = NetworkQualityService().quality.value;

    final wasOffline = _lastQuality == NetworkQuality.offline;
    final wasPoor = _lastQuality == NetworkQuality.poor;
    final isNowConnected = newQuality != NetworkQuality.offline;
    final isNowBetterThanPoor =
        newQuality == NetworkQuality.fair ||
        newQuality == NetworkQuality.good ||
        newQuality == NetworkQuality.excellent;

    final recoveredFromOffline = wasOffline && isNowConnected;
    final recoveredFromPoor = wasPoor && isNowBetterThanPoor;

    if ((recoveredFromOffline || recoveredFromPoor) &&
        _retryCallbacks.isNotEmpty) {
      // Network recovered! Retry ALL failed images after a short settle delay
      final callbacks = Set<VoidCallback>.from(_retryCallbacks);
      Future.delayed(const Duration(milliseconds: 800), () {
        for (final cb in callbacks) {
          cb();
        }
      });
    }

    // Also adapt HttpClient connection limits dynamically
    _adaptConnectionLimits(newQuality);

    _lastQuality = newQuality;
  }

  /// Dynamically adjust HttpClient parallelism based on network quality.
  /// Fewer parallel connections on slow networks = each image gets more
  /// bandwidth and completes faster instead of all stalling together.
  void _adaptConnectionLimits(NetworkQuality quality) {
    switch (quality) {
      case NetworkQuality.excellent:
        _sharedHttpClient.maxConnectionsPerHost = 16;
      case NetworkQuality.good:
        _sharedHttpClient.maxConnectionsPerHost = 10;
      case NetworkQuality.fair:
        _sharedHttpClient.maxConnectionsPerHost = 6;
      case NetworkQuality.poor:
        _sharedHttpClient.maxConnectionsPerHost = 3;
      case NetworkQuality.offline:
        _sharedHttpClient.maxConnectionsPerHost = 2;
    }
  }

  void register(VoidCallback callback) {
    init();
    _retryCallbacks.add(callback);
  }

  void unregister(VoidCallback callback) {
    _retryCallbacks.remove(callback);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _retryCallbacks.isNotEmpty) {
      // Copy the set because callbacks may unregister themselves
      final callbacks = Set<VoidCallback>.from(_retryCallbacks);
      // Small delay to let the system settle after resume
      Future.delayed(const Duration(milliseconds: 500), () {
        for (final cb in callbacks) {
          cb();
        }
      });
    }
  }

  @override
  void didHaveMemoryPressure() {
    // Release all in-memory decoded image resources immediately under OS memory pressure.
    // This prevents background process termination and improves OS-level scheduling.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

// Track successfully loaded URLs during this session to allow 0ms instant loading.
final Set<String> _loadedUrls = {};

// Headers mínimos — solo lo imprescindible para evitar 403.
// Menos headers = handshake más rápido con el CDN.
const Map<String, String> _kImageHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  'Accept': 'image/*,*/*;q=0.8',
};

// ─────────────────────────────────────────────────────────────────────────────
// APP CACHE MANAGER — Optimizado para velocidad
// ─────────────────────────────────────────────────────────────────────────────

/// HttpClient compartido con pool de conexiones agresivo.
/// maxConnectionsPerHost se ajusta dinámicamente por _FailedImageTracker
/// según la calidad de red detectada.
final HttpClient _sharedHttpClient =
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 16
      ..autoUncompress = true
      ..findProxy =
          null // Bypass proxy search to shave off ~50ms off initial handshakes
      ..badCertificateCallback =
          ((X509Certificate cert, String host, int port) => true);

/// Returns adaptive timeout based on current network quality.
/// WiFi/Excellent: 5s, Good: 8s, Fair: 12s, Poor: 18s, Offline: 5s (fail-fast)
Duration _adaptiveTimeout() {
  final quality = NetworkQualityService().quality.value;
  switch (quality) {
    case NetworkQuality.excellent:
      return const Duration(seconds: 15);
    case NetworkQuality.good:
      return const Duration(seconds: 18);
    case NetworkQuality.fair:
      return const Duration(seconds: 22);
    case NetworkQuality.poor:
      return const Duration(seconds: 28);
    case NetworkQuality.offline:
      return const Duration(seconds: 5);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// VALIDATING IMAGE FILE SERVICE
// Intercepts HTTP responses to reject non-image content (HTML error pages, etc.)
// BEFORE they get cached. This prevents the root cause of images never loading:
// the Xtream server sometimes returns HTML ("XUI.one - Debug Mode") which
// flutter_cache_manager would cache as a valid file, causing permanent
// ImageDecoder failures on Android.
// ─────────────────────────────────────────────────────────────────────────────

class _ValidatingImageFileService extends FileService {
  _ValidatingImageFileService();

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    HttpClientRequest? req;
    try {
      final uri = Uri.parse(url);
      req = await _sharedHttpClient.getUrl(uri).timeout(_adaptiveTimeout());

      if (headers != null) {
        headers.forEach((key, value) {
          req!.headers.set(key, value);
        });
      }

      final ioResponse = await req.close().timeout(_adaptiveTimeout());

      // Check content-type BEFORE creating the cache response
      final contentType =
          ioResponse.headers.value('content-type')?.toLowerCase() ?? '';
      if (contentType.contains('text/html') ||
          contentType.contains('text/plain')) {
        // Detach and destroy to immediately free the connection
        ioResponse.detachSocket().then((s) => s.destroy()).catchError((_) {});
        throw HttpExceptionWithStatus(
          ioResponse.statusCode,
          'Server returned non-image content-type: $contentType',
          uri: uri,
        );
      }

      final responseHeaders = <String, String>{};
      ioResponse.headers.forEach((key, values) {
        responseHeaders[key] = values.join(',');
      });

      final streamedResponse = http.StreamedResponse(
        ioResponse,
        ioResponse.statusCode,
        contentLength:
            ioResponse.contentLength == -1 ? null : ioResponse.contentLength,
        request: http.Request('GET', uri),
        headers: responseHeaders,
        isRedirect: ioResponse.isRedirect,
        persistentConnection: ioResponse.persistentConnection,
        reasonPhrase: ioResponse.reasonPhrase,
      );

      // Wrap the stream to also peek at the first bytes
      // (some IPTV servers don't set content-type correctly)
      return _ValidatingHttpGetResponse(streamedResponse, ioResponse);
    } on TimeoutException {
      req?.abort(); // CRITICAL: Free connection on timeout!
      rethrow;
    } catch (e) {
      req?.abort();
      rethrow;
    }
  }
}

/// Extends HttpGetResponse with first-bytes HTML validation.
class _ValidatingHttpGetResponse extends HttpGetResponse {
  final http.StreamedResponse _rawResponse;
  final HttpClientResponse _ioResponse;
  Stream<List<int>>? _validatedStream;

  _ValidatingHttpGetResponse(this._rawResponse, this._ioResponse)
    : super(_rawResponse);

  @override
  Stream<List<int>> get content {
    if (_validatedStream != null) return _validatedStream!;

    final controller = StreamController<List<int>>();
    bool firstChunk = true;

    // Timeout adaptativo para chunks — redes lentas necesitan más tiempo
    _rawResponse.stream
        .timeout(_adaptiveTimeout())
        .listen(
          (data) {
            if (firstChunk && data.length >= 5) {
              firstChunk = false;
              // Check for HTML signature: <!DOC, <html, <HTML
              final header = String.fromCharCodes(data.take(15).toList());
              if (header.trimLeft().startsWith('<') &&
                  (header.contains('html') ||
                      header.contains('HTML') ||
                      header.contains('!DOC'))) {
                controller.addError(
                  Exception('Response body is HTML, not an image'),
                );
                _ioResponse
                    .detachSocket()
                    .then((s) => s.destroy())
                    .catchError((_) {});
                controller.close();
                return;
              }
            }
            firstChunk = false;
            controller.add(data);
          },
          onError: (Object error) {
            controller.addError(error);
            _ioResponse
                .detachSocket()
                .then((s) => s.destroy())
                .catchError((_) {});
          },
          onDone: controller.close,
        );

    _validatedStream = controller.stream;
    return _validatedStream!;
  }
}

class AppCacheManager {
  static const key = 'bump_comba_img_cache';
  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 7),
      maxNrOfCacheObjects: 3000,
      fileService: _ValidatingImageFileService(),
    ),
  );
}

// Helper to determine if an error is permanently non-retryable.
// Timeouts ARE now retryable — on slow networks, timeouts are the #1 cause
// of image failures, and the adaptive timeout + backoff system prevents
// starvation loops that the old code was guarding against.
bool _isRetryableError(Object error) {
  final errStr = error.toString().toLowerCase();

  // Timeouts are now RETRYABLE — the adaptive timeout system ensures
  // each retry uses a longer timeout appropriate to the current network.
  // The exponential backoff in _scheduleRetry prevents starvation.

  // Check for HTTP status exceptions — these are permanent
  if (error is HttpExceptionWithStatus) {
    final code = error.statusCode;
    if (code == 404 || code == 403 || code == 401 || code == 400) {
      return false;
    }
  }

  // HTML debug pages or non-image content responses — permanent server issue
  if (errStr.contains('html') || errStr.contains('non-image')) {
    return false;
  }

  // Common HTTP error tags in strings — permanent
  if (errStr.contains('404') ||
      errStr.contains('403') ||
      errStr.contains('401')) {
    return false;
  }

  return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// FAST IMAGE SERVICE
// ─────────────────────────────────────────────────────────────────────────────

class FastImageService {
  static final FastImageService _instance = FastImageService._internal();
  factory FastImageService() => _instance;
  FastImageService._internal();

  // FIX 2: isValidImageUrl acepta URLs sin extensión (logos IPTV frecuentes)
  static bool isValidImageUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    if (!url.startsWith('http')) return false;

    if (url.contains('ejemplo.com') || url.contains('placeholder.com')) {
      return false;
    }

    // Rutas base de TMDB sin filename — no son imágenes válidas
    const tmdbIncompleteSuffixes = [
      '/w600_and_h900_bestv2',
      '/original',
      '/w500',
      '/w300',
      '/w185',
      '/w92',
    ];
    for (final suffix in tmdbIncompleteSuffixes) {
      if (url.endsWith(suffix)) return false;
    }

    // Validar que sea parseable con host real
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;

    return true;
  }

  // FIX 5: Limitar _queued para evitar leak de memoria en sesiones largas
  static const int _maxQueuedMemory = 3000;
  final Set<String> _queued = {};

  /// Adaptive batch size based on network quality.
  /// Fewer parallel downloads on slow networks = each one completes faster.
  int get _batchSize {
    final quality = NetworkQualityService().quality.value;
    switch (quality) {
      case NetworkQuality.excellent:
      case NetworkQuality.good:
        return 8;
      case NetworkQuality.fair:
        return 4;
      case NetworkQuality.poor:
        return 2;
      case NetworkQuality.offline:
        return 0;
    }
  }

  /// Adaptive max prewarm count — don't saturate a slow network.
  int get _maxBackgroundPrewarm {
    final quality = NetworkQualityService().quality.value;
    switch (quality) {
      case NetworkQuality.excellent:
      case NetworkQuality.good:
        return 40;
      case NetworkQuality.fair:
        return 20;
      case NetworkQuality.poor:
        return 10;
      case NetworkQuality.offline:
        return 0; // Don't even try when offline
    }
  }

  /// Adaptive thumbnail width — smaller images on slow networks load
  /// 3-4x faster while still looking acceptable on phone screens.
  int get _thumbWidth {
    if (PerformanceService().lowMemoryLimit) return 120;
    final quality = NetworkQualityService().quality.value;
    switch (quality) {
      case NetworkQuality.excellent:
        return 300;
      case NetworkQuality.good:
        return 300;
      case NetworkQuality.fair:
        return 200;
      case NetworkQuality.poor:
        return 120;
      case NetworkQuality.offline:
        return 120;
    }
  }

  /// Llamar cuando se recarga la lista con forceRefresh
  void clearQueue() => _queued.clear();

  Future<void> prewarm(List<String> urls, BuildContext context) async {
    if (urls.isEmpty) return;

    // Don't prewarm when offline — waste of resources
    if (NetworkQualityService().quality.value == NetworkQuality.offline) return;

    // FIX 5: limpiar si el set creció demasiado
    if (_queued.length > _maxQueuedMemory) _queued.clear();

    final fresh =
        urls
            .where((u) => isValidImageUrl(u) && !_queued.contains(u))
            .take(_maxBackgroundPrewarm)
            .toSet()
            .toList();
    if (fresh.isEmpty) return;

    _queued.addAll(fresh);

    SchedulerBinding.instance.addPostFrameCallback((_) {
      _warmBatch(fresh, context);
    });
  }

  Future<void> _warmBatch(List<String> urls, BuildContext context) async {
    final batchSz = _batchSize; // Capture once per warm cycle
    for (int start = 0; start < urls.length; start += batchSz) {
      final end = (start + batchSz).clamp(0, urls.length);
      final batch = urls.sublist(start, end);

      await Future.wait(
        batch.map((url) => _precacheOne(url, context)),
        eagerError: false,
      );

      // Longer pause between batches on slow networks to avoid congestion
      final pauseMs =
          NetworkQualityService().quality.value.index >=
                  NetworkQuality.fair.index
              ? 200
              : 50;
      await Future.delayed(Duration(milliseconds: pauseMs));
    }
  }

  Future<void> _precacheOne(String url, BuildContext context) async {
    try {
      await precacheImage(
        ResizeImage(
          CachedNetworkImageProvider(
            url,
            headers: _kImageHeaders,
            cacheManager: AppCacheManager.instance,
          ),
          width: _thumbWidth,
        ),
        context,
        onError: (_, _) {},
      );
    } catch (_) {}
  }

  void prewarmPriority(List<String> urls, BuildContext context) {
    // Skip if offline
    if (NetworkQualityService().quality.value == NetworkQuality.offline) return;

    final maxPriority =
        NetworkQualityService().quality.value.index >= NetworkQuality.fair.index
            ? 10
            : 30;
    for (final url in urls.take(maxPriority)) {
      if (!isValidImageUrl(url) || _queued.contains(url)) continue;
      _queued.add(url);
      precacheImage(
        ResizeImage(
          CachedNetworkImageProvider(
            url,
            headers: _kImageHeaders,
            cacheManager: AppCacheManager.instance,
          ),
          width: _thumbWidth,
        ),
        context,
        onError: (_, _) {},
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAST THUMBNAIL WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class FastThumbnail extends StatefulWidget {
  final String? url;
  final double width;
  final double height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final int? cacheWidth;
  final String? title;
  final bool isSeries;
  final bool useTMDBFallback;
  final VoidCallback? onError;

  const FastThumbnail({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.title,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.cacheWidth,
    this.isSeries = false,
    this.useTMDBFallback = false,
    this.onError,
  });

  @override
  State<FastThumbnail> createState() => _FastThumbnailState();
}

class _FastThumbnailState extends State<FastThumbnail>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  ImageProvider? _cachedProvider;
  int? _effectiveCacheWidth;
  String? _fallbackUrl;
  bool _isResolvingFallback = false;

  // Silent retry state — NEVER gives up permanently.
  // Uses exponential backoff with cap at 30s.
  int _retryCount = 0;
  Timer? _retryTimer;
  int _imageKey = 0;
  bool _hasLoaded = false;

  // Retry intervals with exponential backoff, capped at 30s.
  // After index 7, all retries use 30s.
  static const List<int> _retryDelays = [1, 2, 4, 8, 15, 20, 25, 30];

  @override
  void initState() {
    super.initState();
    final url = _resolveUrl();
    final wasAlreadyLoaded = url != null && _loadedUrls.contains(url);

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: wasAlreadyLoaded ? 1.0 : 0.0,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _effectiveCacheWidth = _computeCacheWidth();
    _checkAndResolveFallback();
    // Register for app resume retries
    _FailedImageTracker.instance.register(_onAppResumeRetry);
  }

  void _checkAndResolveFallback() async {
    if (!widget.useTMDBFallback || widget.title == null) return;
    if (FastImageService.isValidImageUrl(widget.url)) return;
    if (_fallbackUrl != null || _isResolvingFallback) return;

    setState(() => _isResolvingFallback = true);
    final url = await MetadataFallbackService().getFallbackPoster(
      widget.title!,
      isSeries: widget.isSeries,
    );
    if (mounted) {
      setState(() {
        _fallbackUrl = url;
        _isResolvingFallback = false;
      });
    }
  }

  int? _computeCacheWidth() {
    if (widget.cacheWidth != null) return widget.cacheWidth;
    final performance = PerformanceService();
    if (performance.isLowPerformance) return 120;
    // Adapt resolution to network quality — smaller images on slow
    // networks load significantly faster and still look good on phones.
    final quality = NetworkQualityService().quality.value;
    switch (quality) {
      case NetworkQuality.excellent:
      case NetworkQuality.good:
        return 300;
      case NetworkQuality.fair:
        return 200;
      case NetworkQuality.poor:
      case NetworkQuality.offline:
        return 120;
    }
  }

  @override
  void didUpdateWidget(FastThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _cachedProvider = null;
      _fallbackUrl = null;
      _effectiveCacheWidth = _computeCacheWidth();

      final url = _resolveUrl();
      final wasAlreadyLoaded = url != null && _loadedUrls.contains(url);
      if (wasAlreadyLoaded) {
        _fadeController.value = 1.0;
      } else {
        _fadeController.reset();
      }

      _retryCount = 0;
      _retryTimer?.cancel();
      _hasLoaded = false;
      _imageKey = 0;
      _checkAndResolveFallback();
    }
  }

  /// Called when the app resumes from background — retry if image hasn't loaded.
  void _onAppResumeRetry() {
    if (!mounted || _hasLoaded) return;
    // Reset retry count so the user gets fresh attempts after resume
    _retryCount = 0;
    _performRetry();
  }

  /// Silently retry loading the image after an adaptive delay.
  /// NEVER gives up — uses exponential backoff with 30s cap.
  /// Non-retryable errors (404, 403, HTML responses) stop immediately.
  void _scheduleRetry(Object error) {
    if (!mounted || _hasLoaded) return;

    // Truly permanent errors — server says the image doesn't exist
    if (!_isRetryableError(error)) {
      return; // Stop retrying but don't mark as permanently failed
      // — network recovery or app resume can still trigger a retry
    }

    // Don't schedule if offline — _FailedImageTracker will auto-retry
    // when network recovers
    if (NetworkQualityService().quality.value == NetworkQuality.offline) {
      return;
    }

    // Exponential backoff with cap at 30s
    final delayIndex = _retryCount.clamp(0, _retryDelays.length - 1);
    final delay = Duration(seconds: _retryDelays[delayIndex]);
    _retryCount++;
    _retryTimer?.cancel();

    _retryTimer = Timer(delay, () {
      if (!mounted || _hasLoaded) return;
      _performRetry();
    });
  }

  /// Core retry logic shared by timer-based and app-resume retries.
  /// Awaits cache eviction before triggering a rebuild to guarantee
  /// the corrupted file is gone before a fresh download starts.
  Future<void> _performRetry() async {
    if (!mounted || _hasLoaded) return;

    final url = _resolveUrl();
    if (url != null) {
      // 1. Evict from disk cache FIRST and wait for completion
      try {
        await AppCacheManager.instance.removeFile(url);
      } catch (_) {}

      // 2. Evict every form of this image from Flutter's in-memory cache
      //    (including ResizeImage wrappers)
      final provider = CachedNetworkImageProvider(
        url,
        headers: _kImageHeaders,
        cacheManager: AppCacheManager.instance,
      );
      try {
        await provider.evict();
      } catch (_) {}
      if (_effectiveCacheWidth != null) {
        try {
          await ResizeImage(provider, width: _effectiveCacheWidth!).evict();
        } catch (_) {}
      }

      // 3. Also clear from Flutter's global image cache by key
      PaintingBinding.instance.imageCache.evict(url);
    }

    if (!mounted || _hasLoaded) return;

    // 4. Drop our own cached reference
    _cachedProvider = null;

    // 5. Reset fade — image will appear seamlessly via gaplessPlayback
    _fadeController.reset();

    // 6. Rebuild with new key
    setState(() {
      _imageKey++;
    });
  }

  /// Resolve the effective image URL (primary or fallback), trimmed.
  String? _resolveUrl() {
    final String? raw =
        FastImageService.isValidImageUrl(widget.url)
            ? widget.url
            : _fallbackUrl;
    return raw?.trim();
  }

  @override
  void dispose() {
    _FailedImageTracker.instance.unregister(_onAppResumeRetry);
    _fadeController.dispose();
    _retryTimer?.cancel();
    super.dispose();
  }

  ImageProvider _getProvider() {
    if (_cachedProvider != null) return _cachedProvider!;

    final String? imageTarget = _resolveUrl();

    if (imageTarget == null || imageTarget.isEmpty) {
      return const AssetImage('assets/placeholder.png');
    }

    ImageProvider provider = CachedNetworkImageProvider(
      imageTarget,
      headers: _kImageHeaders,
      cacheManager: AppCacheManager.instance,
    );

    if (_effectiveCacheWidth != null) {
      provider = ResizeImage(provider, width: _effectiveCacheWidth!);
    }
    _cachedProvider = provider;
    return provider;
  }

  Widget _placeholder() {
    final bool isLow = PerformanceService().isLowPerformance;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_hasLoaded) {
          _performRetry();
        }
      },
      child: Container(
        width: widget.width,
        height: widget.height,
        color: const Color(0xFF1a1a1a),
        child:
            (widget.title != null && !isLow)
                ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      widget.title!,
                      textAlign: TextAlign.center,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                )
                : Center(
                  child: Icon(
                    Icons.movie_creation_outlined,
                    color: Colors.white.withValues(alpha: 0.1),
                    size: 30,
                  ),
                ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    final bool hasValidPrimary = FastImageService.isValidImageUrl(widget.url);
    final bool hasValidFallback = FastImageService.isValidImageUrl(
      _fallbackUrl,
    );

    if (!hasValidPrimary && !hasValidFallback) {
      content = _placeholder();
    } else {
      content = Stack(
        children: [
          _placeholder(),
          FadeTransition(
            opacity: _fadeAnimation,
            child: Image(
              key: ValueKey('thumb_$_imageKey'),
              image: _getProvider(),
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                _hasLoaded = true;
                final url = _resolveUrl();
                if (url != null) {
                  _loadedUrls.add(url);
                }
                _FailedImageTracker.instance.unregister(_onAppResumeRetry);

                if (wasSynchronouslyLoaded) {
                  if (!_fadeController.isCompleted) {
                    SchedulerBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _fadeController.value = 1.0;
                    });
                  }
                  return child;
                }
                if (frame == null) return const SizedBox.shrink();
                if (!_fadeController.isCompleted) {
                  SchedulerBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _fadeController.forward();
                  });
                }
                return child;
              },
              errorBuilder: (context, error, stackTrace) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _scheduleRetry(error);
                });
                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      );
    }

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: content);
    }
    return content;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAST CHANNEL LOGO WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class FastChannelLogo extends StatefulWidget {
  final String? url;
  final double size;
  final BorderRadius? borderRadius;
  final VoidCallback? onError;

  const FastChannelLogo({
    super.key,
    required this.url,
    this.size = 48,
    this.borderRadius,
    this.onError,
  });

  @override
  State<FastChannelLogo> createState() => _FastChannelLogoState();
}

class _FastChannelLogoState extends State<FastChannelLogo>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  ImageProvider? _cachedProvider;

  // Silent retry state — NEVER gives up permanently.
  int _retryCount = 0;
  Timer? _retryTimer;
  int _imageKey = 0;
  bool _hasLoaded = false;

  // Retry intervals with exponential backoff, capped at 30s.
  static const List<int> _retryDelays = [1, 2, 4, 8, 15, 20, 25, 30];

  @override
  void initState() {
    super.initState();
    final url = widget.url?.trim();
    final wasAlreadyLoaded = url != null && _loadedUrls.contains(url);

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: wasAlreadyLoaded ? 1.0 : 0.0,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    // Register for app resume retries
    _FailedImageTracker.instance.register(_onAppResumeRetry);
  }

  @override
  void didUpdateWidget(FastChannelLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _cachedProvider = null;

      final url = widget.url?.trim();
      final wasAlreadyLoaded = url != null && _loadedUrls.contains(url);
      if (wasAlreadyLoaded) {
        _fadeController.value = 1.0;
      } else {
        _fadeController.reset();
      }

      _retryCount = 0;
      _retryTimer?.cancel();
      _hasLoaded = false;
      _imageKey = 0;
    }
  }

  /// Called when the app resumes from background — retry if image hasn't loaded.
  void _onAppResumeRetry() {
    if (!mounted || _hasLoaded) return;
    _retryCount = 0;
    _performRetry();
  }

  void _scheduleRetry(Object error) {
    if (!mounted || _hasLoaded) return;

    // Truly permanent errors — stop but allow network-recovery retries
    if (!_isRetryableError(error)) {
      return;
    }

    // Don't schedule if offline — _FailedImageTracker auto-retries on recovery
    if (NetworkQualityService().quality.value == NetworkQuality.offline) {
      return;
    }

    final delayIndex = _retryCount.clamp(0, _retryDelays.length - 1);
    final delay = Duration(seconds: _retryDelays[delayIndex]);
    _retryCount++;
    _retryTimer?.cancel();

    _retryTimer = Timer(delay, () {
      if (!mounted || _hasLoaded) return;
      _performRetry();
    });
  }

  /// Core retry logic shared by timer-based and app-resume retries.
  Future<void> _performRetry() async {
    if (!mounted || _hasLoaded) return;

    final url = widget.url?.trim();
    if (url != null) {
      // Evict from disk cache FIRST and wait for completion
      try {
        await AppCacheManager.instance.removeFile(url);
      } catch (_) {}

      // Evict every form from Flutter's in-memory cache
      final provider = CachedNetworkImageProvider(
        url,
        headers: _kImageHeaders,
        cacheManager: AppCacheManager.instance,
      );
      try {
        await provider.evict();
      } catch (_) {}
      try {
        await ResizeImage(provider, width: widget.size.toInt() * 2).evict();
      } catch (_) {}

      // Also clear from Flutter's global image cache
      PaintingBinding.instance.imageCache.evict(url);
    }

    if (!mounted || _hasLoaded) return;

    _cachedProvider = null;
    _fadeController.reset();

    setState(() {
      _imageKey++;
    });
  }

  @override
  void dispose() {
    _FailedImageTracker.instance.unregister(_onAppResumeRetry);
    _fadeController.dispose();
    _retryTimer?.cancel();
    super.dispose();
  }

  ImageProvider _getProvider() {
    if (_cachedProvider != null) return _cachedProvider!;
    _cachedProvider = ResizeImage(
      CachedNetworkImageProvider(
        widget.url!.trim(),
        headers: _kImageHeaders,
        cacheManager: AppCacheManager.instance,
      ),
      width: widget.size.toInt() * 2,
    );
    return _cachedProvider!;
  }

  @override
  Widget build(BuildContext context) {
    final child = _buildImage();
    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: child);
    }
    return child;
  }

  Widget _buildImage() {
    if (!FastImageService.isValidImageUrl(widget.url)) return _placeholder();

    return Stack(
      children: [
        _placeholder(),
        FadeTransition(
          opacity: _fadeAnimation,
          child: Image(
            key: ValueKey('logo_$_imageKey'),
            image: _getProvider(),
            width: widget.size,
            height: widget.size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              _hasLoaded = true;
              final url = widget.url?.trim();
              if (url != null) {
                _loadedUrls.add(url);
              }
              _FailedImageTracker.instance.unregister(_onAppResumeRetry);

              if (wasSynchronouslyLoaded) {
                if (!_fadeController.isCompleted) {
                  SchedulerBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _fadeController.value = 1.0;
                  });
                }
                return child;
              }
              if (frame == null) return const SizedBox.shrink();
              if (!_fadeController.isCompleted) {
                SchedulerBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _fadeController.forward();
                });
              }
              return child;
            },
            errorBuilder: (context, error, stackTrace) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _scheduleRetry(error);
              });
              return const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }

  Widget _placeholder() {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_hasLoaded) {
          _performRetry();
        }
      },
      child:
          PerformanceService().isLowPerformance
              ? SizedBox(
                width: widget.size,
                height: widget.size,
                child: const Center(
                  child: Icon(Icons.tv, color: Color(0xFF2d2d2d), size: 20),
                ),
              )
              : Container(
                width: widget.size,
                height: widget.size,
                decoration: const BoxDecoration(
                  color: Color(0xFF1a1a1a),
                  shape: BoxShape.circle,
                ),
              ),
    );
  }
}
