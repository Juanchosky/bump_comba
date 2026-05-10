import 'dart:io';
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/io_client.dart';
import 'performance_service.dart';
import 'metadata_fallback_service.dart';

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
/// - maxConnectionsPerHost: 6 descargas paralelas al mismo servidor
/// - idleTimeout: mantiene conexiones vivas para reutilización HTTP/1.1
/// - autoUncompress: deja que el sistema descomprima automáticamente
final HttpClient _sharedHttpClient = HttpClient()
  ..connectionTimeout = const Duration(seconds: 8)
  ..idleTimeout = const Duration(seconds: 30)
  ..maxConnectionsPerHost = 6
  ..autoUncompress = true
  ..badCertificateCallback =
      ((X509Certificate cert, String host, int port) => true);

class AppCacheManager {
  static const key = 'bump_comba_img_cache';
  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 7),
      maxNrOfCacheObjects: 3000,
      fileService: HttpFileService(
        httpClient: IOClient(_sharedHttpClient),
      ),
    ),
  );
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

    if (url.contains('ejemplo.com') || url.contains('placeholder.com'))
      return false;

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

  static const int _batchSize = 8;
  static const int _maxBackgroundPrewarm = 40;

  int get _thumbWidth => PerformanceService().lowMemoryLimit ? 150 : 300;

  /// Llamar cuando se recarga la lista con forceRefresh
  void clearQueue() => _queued.clear();

  Future<void> prewarm(List<String> urls, BuildContext context) async {
    if (urls.isEmpty) return;

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
    for (int start = 0; start < urls.length; start += _batchSize) {
      final end = (start + _batchSize).clamp(0, urls.length);
      final batch = urls.sublist(start, end);

      await Future.wait(
        batch.map((url) => _precacheOne(url, context)),
        eagerError: false,
      );

      // Micro-pausa entre batches para no bloquear el UI thread
      await Future.delayed(const Duration(milliseconds: 50));
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
    for (final url in urls.take(30)) {
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

  // Silent retry state
  int _retryCount = 0;
  Timer? _retryTimer;
  int _imageKey = 0;
  bool _hasLoaded = false;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _effectiveCacheWidth = _computeCacheWidth();
    _checkAndResolveFallback();
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
    if (performance.isLowPerformance) return 150;
    if (performance.currentMode == PerformanceMode.high ||
        !performance.isLowEndHeuristic) {
      return null;
    }
    return 300;
  }

  @override
  void didUpdateWidget(FastThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _cachedProvider = null;
      _fallbackUrl = null;
      _effectiveCacheWidth = _computeCacheWidth();
      _fadeController.reset();
      _retryCount = 0;
      _retryTimer?.cancel();
      _hasLoaded = false;
      _imageKey = 0;
      _checkAndResolveFallback();
    }
  }

  /// Silently retry loading the image after a short delay.
  void _scheduleRetry() {
    if (!mounted || _hasLoaded) return;

    // Max 5 retries: 2s, 4s, 8s, 12s, 18s
    if (_retryCount >= 5) {
      widget.onError?.call();
      return;
    }

    _retryCount++;
    _retryTimer?.cancel();
    final delay = Duration(seconds: [2, 4, 8, 12, 18][_retryCount - 1]);

    _retryTimer = Timer(delay, () {
      if (!mounted || _hasLoaded) return;

      // 1. Evict from disk cache
      final url = _resolveUrl();
      if (url != null) {
        AppCacheManager.instance.removeFile(url).catchError((_) {});
      }

      // 2. Evict from memory
      _cachedProvider?.evict();
      _cachedProvider = null;

      // 3. Reset fade
      _fadeController.reset();

      // 4. Rebuild with new key
      if (mounted) {
        setState(() {
          _imageKey++;
        });
      }
    });
  }

  /// Resolve the effective image URL (primary or fallback), trimmed.
  String? _resolveUrl() {
    final String? raw =
        FastImageService.isValidImageUrl(widget.url) ? widget.url : _fallbackUrl;
    return raw?.trim();
  }

  @override
  void dispose() {
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

    Widget base = Container(
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
    );

    return base;
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
                if (wasSynchronouslyLoaded) {
                  _hasLoaded = true;
                  if (!_fadeController.isCompleted) {
                    SchedulerBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _fadeController.value = 1.0;
                    });
                  }
                  return child;
                }
                if (frame == null) return const SizedBox.shrink();
                _hasLoaded = true;
                if (!_fadeController.isCompleted) {
                  SchedulerBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _fadeController.forward();
                  });
                }
                return child;
              },
              errorBuilder: (context, error, stackTrace) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _scheduleRetry();
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

  // Silent retry state
  int _retryCount = 0;
  Timer? _retryTimer;
  int _imageKey = 0;
  bool _hasLoaded = false;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
  }

  @override
  void didUpdateWidget(FastChannelLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _cachedProvider = null;
      _fadeController.reset();
      _retryCount = 0;
      _retryTimer?.cancel();
      _hasLoaded = false;
      _imageKey = 0;
    }
  }

  void _scheduleRetry() {
    if (!mounted || _hasLoaded) return;

    if (_retryCount >= 5) {
      widget.onError?.call();
      return;
    }

    _retryCount++;
    _retryTimer?.cancel();
    final delay = Duration(seconds: [2, 4, 8, 12, 18][_retryCount - 1]);

    _retryTimer = Timer(delay, () {
      if (!mounted || _hasLoaded) return;

      final url = widget.url?.trim();
      if (url != null) {
        AppCacheManager.instance.removeFile(url).catchError((_) {});
      }

      _cachedProvider?.evict();
      _cachedProvider = null;
      _fadeController.reset();

      if (mounted) {
        setState(() {
          _imageKey++;
        });
      }
    });
  }

  @override
  void dispose() {
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
              if (wasSynchronouslyLoaded) {
                _hasLoaded = true;
                if (!_fadeController.isCompleted) {
                  SchedulerBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _fadeController.value = 1.0;
                  });
                }
                return child;
              }
              if (frame == null) return const SizedBox.shrink();
              _hasLoaded = true;
              if (!_fadeController.isCompleted) {
                SchedulerBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _fadeController.forward();
                });
              }
              return child;
            },
            errorBuilder: (context, error, stackTrace) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _scheduleRetry();
              });
              return const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }

  Widget _placeholder() {
    if (PerformanceService().isLowPerformance) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Center(
          child: Icon(Icons.tv, color: Color(0xFF2d2d2d), size: 20),
        ),
      );
    }
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: const BoxDecoration(
        color: Color(0xFF1a1a1a),
        shape: BoxShape.circle,
      ),
    );
  }
}
