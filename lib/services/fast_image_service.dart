import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/io_client.dart';
import 'performance_service.dart';

// FIX 1: Headers completos — evita 403 en CDNs de logos IPTV
const Map<String, String> _kImageHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
  'Accept': 'image/webp,image/avif,image/*,*/*;q=0.8',
  'Accept-Language': 'es-419,es;q=0.9,en;q=0.8',
  'Referer': 'https://www.google.com/',
};

// ─────────────────────────────────────────────────────────────────────────────
// APP CACHE MANAGER
// ─────────────────────────────────────────────────────────────────────────────

class AppCacheManager {
  static const key = 'bump_comba_img_cache';
  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 7),
      maxNrOfCacheObjects: 2500,
      fileService: HttpFileService(
        httpClient: IOClient(
          HttpClient()..connectionTimeout = const Duration(seconds: 15),
        ),
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

    if (url.contains('ejemplo.com') || url.contains('placeholder.com')) return false;

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

    // Debe tener al menos un path segment no vacío
    return uri.pathSegments.any((s) => s.isNotEmpty);
  }

  // FIX 5: Limitar _queued para evitar leak de memoria en sesiones largas
  static const int _maxQueuedMemory = 3000;
  final Set<String> _queued = {};

  static const int _batchSize = 4;
  static const int _maxBackgroundPrewarm = 24;

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

      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> _precacheOne(String url, BuildContext context) async {
    try {
      await precacheImage(
        ResizeImage(
          CachedNetworkImageProvider(
            url,
            headers: _kImageHeaders, // FIX 1
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
    for (final url in urls.take(20)) {
      if (!isValidImageUrl(url) || _queued.contains(url)) continue;
      _queued.add(url);
      precacheImage(
        ResizeImage(
          CachedNetworkImageProvider(
            url,
            headers: _kImageHeaders, // FIX 1
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

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _effectiveCacheWidth = _computeCacheWidth();
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
    // FIX 3: solo resetear si la URL cambió — cacheWidth es estable en runtime
    if (oldWidget.url != widget.url) {
      _cachedProvider = null;
      _effectiveCacheWidth = _computeCacheWidth();
      _fadeController.reset();
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  ImageProvider _getProvider() {
    if (_cachedProvider != null) return _cachedProvider!;

    ImageProvider provider = CachedNetworkImageProvider(
      widget.url!,
      headers: _kImageHeaders, // FIX 1
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

    if (!FastImageService.isValidImageUrl(widget.url)) {
      content = _placeholder();
    } else {
      content = Stack(
        children: [
          _placeholder(),
          FadeTransition(
            opacity: _fadeAnimation,
            child: Image(
              image: _getProvider(),
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
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
                if (widget.onError != null) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => widget.onError!(),
                  );
                }
                return _placeholder();
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

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
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
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  ImageProvider _getProvider() {
    if (_cachedProvider != null) return _cachedProvider!;
    _cachedProvider = ResizeImage(
      CachedNetworkImageProvider(
        widget.url!,
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
            image: _getProvider(),
            width: widget.size,
            height: widget.size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
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
              if (widget.onError != null) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => widget.onError!(),
                );
              }
              return _placeholder();
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
