import 'package:bump_comba/services/m3u_service.dart';
import 'package:bump_comba/services/watch_progress_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui';
import 'package:media_kit/media_kit.dart';
import '../services/cast_service.dart';
import 'package:cast/device.dart';
import '../utils/transitions.dart';
import '../utils/snack_bar_utils.dart';

import '../services/ad_service.dart';
import '../services/tmdb_service.dart';
import '../services/performance_service.dart';
import '../services/fast_image_service.dart';
import 'video_player_screen.dart';
import 'subscription_screen.dart';
import '../utils/colors.dart';
import '../services/dynamic_scraper_service.dart';

class ContentDetailScreen extends StatefulWidget {
  final M3UItem item;
  final List<M3UItem> similarItems;
  final Function(M3UItem) onToggleFavorite;

  const ContentDetailScreen({
    super.key,
    required this.item,
    this.similarItems = const [],
    required this.onToggleFavorite,
  });

  @override
  State<ContentDetailScreen> createState() => _ContentDetailScreenState();
}

class _ContentDetailScreenState extends State<ContentDetailScreen>
    with TickerProviderStateMixin {
  bool _isFavorite = false;
  bool _isReporting = false;
  bool _isLiked = false;
  bool _isLiking = false;
  bool _isDisliked = false;
  bool _isDisliking = false;
  final M3UService _m3uService = M3UService();

  // Series/Version grouping
  final Map<int, List<M3UItem>> _seasonMap = {};
  List<int> _seasons = [];
  int _selectedSeason = 1;
  List<M3UItem> _otherVersions = [];
  bool _isLoadingEpisodes = false;
  List<M3UItem> _dynamicEpisodes = [];

  // TMDB Metadata
  final TMDBService _tmdbService = TMDBService();
  Map<String, dynamic>? _metadata;

  // Pre-warming
  Player? _prewarmPlayer;

  late AnimationController _shineController;
  late AnimationController _pulseController;
  List<M3UItem> get _allEpisodes =>
      _dynamicEpisodes.isNotEmpty ? _dynamicEpisodes : widget.item.episodes;

  @override
  void initState() {
    super.initState();
    _isFavorite = widget.item.isFavorite;

    if (widget.item.isSeries) {
      if (widget.item.episodes.isEmpty) {
        _loadEpisodes();
      } else {
        _groupEpisodes();
      }
    }
    _findOtherVersions();

    // Shine effect animation
    _shineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(period: const Duration(seconds: 3));

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    CastService().addListener(_onCastChanged);
    AdService().recordDetailsVisit();
    _fetchMetadata();
    _initPrewarm();

    // Aggressive pre-caching for similar items and episodes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final List<String> urls = [];
        // First few similar items
        if (widget.similarItems.isNotEmpty) {
          urls.addAll(
            widget.similarItems.take(8).map((i) => i.logo).whereType<String>(),
          );
        }
        // First few episodes if series
        if (widget.item.isSeries && widget.item.episodes.isNotEmpty) {
          urls.addAll(
            widget.item.episodes.take(8).map((i) => i.logo).whereType<String>(),
          );
        }
        if (urls.isNotEmpty) {
          FastImageService().prewarm(urls.toSet().toList(), context);
        }
      }
    });
  }

  Future<void> _fetchMetadata() async {
    final data = await _tmdbService.searchAndGetDetails(
      widget.item.name,
      isSeries: widget.item.isSeries,
    );
    if (mounted) {
      setState(() {
        _metadata = data;
      });
    }
  }

  void _initPrewarm() {
    // CRITICAL: Disable video pre-warming on Android to prevent
    // BLASTBufferQueue surface exhaustion and fatal callbacks.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return;

    if (!PerformanceService().allowVideoPrewarm) return;

    // Solo pre-calentar si no es Live (los live gastan mucho ancho de banda)
    final url = widget.item.url.toLowerCase();
    final isLive =
        url.contains('/live/') ||
        url.contains('type=live') ||
        (url.endsWith('.m3u8') && !url.contains('/vod/'));

    if (isLive) return;

    // NO pre-calentar si requiere scraping (son URLs de páginas web, no videos directos)
    if (DynamicScraperService().isSupported(url)) return;

    Future.microtask(() async {
      try {
        _prewarmPlayer = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 128 * 1024 * 1024, // 128 MB para pre-warm
            title: 'Prewarm Player',
            logLevel: MPVLogLevel.error, // Low noise
            libass: false, // Menos pesado
          ),
        );

        // -- CRITICAL SILENCING --
        // Mute native engine IMMEDIATELY to prevent callbacks
        // that could survive a Hot Restart.
        try {
          final mpvPlatform = _prewarmPlayer!.platform as dynamic;
          mpvPlatform?.setProperty('terminal', 'no');
          mpvPlatform?.setProperty('msg-level', 'all=no');
        } catch (_) {}

        // Configurar UA para el prewarm
        final mpv = _prewarmPlayer!.platform as dynamic;
        if (mpv != null) {
          await mpv.setProperty('user-agent', 'VLC/3.0.20 LibVLC/3.0.20');
        }

        await _prewarmPlayer!.open(
          Media(
            widget.item.url,
            httpHeaders: _buildPrewarmHeaders(widget.item.url),
          ),
          play: false,
        );
      } catch (e) {
        debugPrint('Error en pre-warming: $e');
      }
    });
  }

  Map<String, String> _buildPrewarmHeaders(String url) {
    String referer = '';
    try {
      final uri = Uri.parse(url);
      referer = '${uri.scheme}://${uri.host}/';
    } catch (_) {}

    return {
      'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
      'Accept': '*/*',
      'Accept-Encoding': 'gzip, deflate',
      'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
      'Connection': 'keep-alive',
      if (referer.isNotEmpty) 'Referer': referer,
      'Origin': referer.isEmpty ? '' : referer.replaceAll(RegExp(r'/$'), ''),
    }..removeWhere((k, v) => v.isEmpty);
  }

  void _onCastChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _shineController.dispose();
    _pulseController.dispose();
    CastService().removeListener(_onCastChanged);

    // -- CRITICAL DISPOSAL SEQUENCE FOR MOTOROLA/ANDROID 15 --
    final p = _prewarmPlayer;
    _prewarmPlayer = null;

    if (p != null) {
      // 1. Silence and detach video immediately before stopping.
      try {
        final mpv = p.platform as dynamic;
        mpv?.setProperty('msg-level', 'all=no');
        mpv?.setProperty('log-level', 'no');
        mpv?.setProperty('vid', 'no');
        mpv?.setProperty('vo', 'null');
      } catch (_) {}

      // 2. Stop demuxer.
      p.stop();

      // 3. Drain event queue (500ms instead of 100ms for extra safety).
      Future.delayed(const Duration(milliseconds: 500), () => p.dispose());
    }

    super.dispose();
  }

  void _showFullDescriptionBottomSheet(String overview) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1a1a1a),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.70,
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
              const SizedBox(height: 20),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Descripción',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    overview,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showOverlaySeasonSelector() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: AppColors.background.withOpacity(0.85),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return Stack(
          children: [
            // Dark Opaque Background
            Positioned.fill(
              child: Container(color: const Color.fromARGB(125, 0, 0, 0)),
            ),

            // Seasons List (Centered)
            Center(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.7,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    itemCount: _seasons.length,
                    itemBuilder: (context, index) {
                      final season = _seasons[index];
                      final isSelected = season == _selectedSeason;

                      return InkWell(
                        onTap: () {
                          setState(() {
                            _selectedSeason = season;
                          });
                          Navigator.pop(context);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Text(
                            'Temporada $season',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.white60,
                              fontSize: isSelected ? 19 : 16,
                              fontWeight:
                                  isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                              letterSpacing: isSelected ? 0.3 : 0,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),

            // Floating Close Button
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 40,
              left: 0,
              right: 0,
              child: Center(
                child: FloatingActionButton(
                  onPressed: () => Navigator.pop(context),
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.background,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.close, size: 30),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showReportOptions() {
    final reasons = [
      'No carga el video',
      'Se traba / Mucho buffering',
      'Audio desincronizado / Sin audio',
      'Subtítulos faltantes o mal sincronizados',
      'El contenido no corresponde al título',
      'Mala calidad de imagen',
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
                  '¿Qué problema encontraste?',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
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
                      onTap: () {
                        Navigator.pop(context);
                        _reportProblem(reasons[index]);
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

  Future<void> _toggleLike() async {
    if (_isLiked || _isLiking) return;

    setState(() => _isLiking = true);

    final success = await _m3uService.likeContent(widget.item);

    if (mounted) {
      if (success) {
        setState(() {
          _isLiked = true;
          _isLiking = false;
          // Un-dislike if liked
          _isDisliked = false;
        });
        SnackBarUtils.showAppSnackBar(context, '¡Te gusta este contenido!');
      } else {
        setState(() => _isLiking = false);
      }
    }
  }

  Future<void> _toggleDislike() async {
    if (_isDisliked || _isDisliking) return;

    setState(() => _isDisliking = true);

    // Simulated dislike action - for now just local state toggle
    await Future.delayed(const Duration(milliseconds: 300));

    if (mounted) {
      setState(() {
        _isDisliked = true;
        _isDisliking = false;
        // Un-like if disliked
        _isLiked = false;
      });
      SnackBarUtils.showAppSnackBar(context, 'No te gusta este contenido');
    }
  }

  Future<void> _reportProblem(String reason) async {
    setState(() => _isReporting = true);

    try {
      final success = await _m3uService.reportContent(
        name: widget.item.name,
        category: widget.item.category,
        url: widget.item.url,
        reason: reason,
      );

      if (mounted) {
        if (success) {
          SnackBarUtils.showAppSnackBar(
            context,
            'Reporte enviado con éxito. ¡Gracias!',
          );
        } else {
          SnackBarUtils.showAppSnackBar(
            context,
            'Error al enviar el reporte. Inténtalo de nuevo.',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        SnackBarUtils.showAppSnackBar(
          context,
          'Error de conexión. Inténtalo de nuevo.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isReporting = false);
      }
    }
  }

  /// Returns the capitalization signature of a name
  /// (replica de la lógica en m3u_service.dart para filtrar episodios mezclados)
  String _capSignature(String name) {
    final cleaned =
        name
            .replaceAll(RegExp(r'S\d+E\d+.*', caseSensitive: false), '')
            .replaceAll(RegExp(r'\d+x\d+.*', caseSensitive: false), '')
            .trim();
    if (cleaned.isEmpty) return 'mixed';
    final lettersOnly = cleaned.replaceAll(
      RegExp(r'[^a-zA-ZáéíóúÁÉÍÓÚñÑ]'),
      '',
    );
    if (lettersOnly.isEmpty) return 'mixed';
    int upperCount = 0, lowerCount = 0;
    for (final r in lettersOnly.runes) {
      final ch = String.fromCharCode(r);
      if (ch == ch.toUpperCase() && ch != ch.toLowerCase()) upperCount++;
      if (ch == ch.toLowerCase() && ch != ch.toUpperCase()) lowerCount++;
    }
    final total = upperCount + lowerCount;
    if (total == 0) return 'mixed';
    final upperRatio = upperCount / total;
    if (upperRatio >= 0.85) return 'upper';
    if (upperRatio <= 0.15) return 'lower';
    final words = cleaned.trim().split(RegExp(r'\s+'));
    if (words.isEmpty) return 'mixed';
    final titleWords =
        words.where((w) {
          if (w.isEmpty) return false;
          return w[0] == w[0].toUpperCase() && w[0] != w[0].toLowerCase();
        }).length;
    if (titleWords / words.length >= 0.7) return 'title';
    return 'mixed';
  }

  Future<void> _loadEpisodes() async {
    if (!mounted) return;
    setState(() => _isLoadingEpisodes = true);

    try {
      final episodes = await _m3uService.fetchEpisodesForItem(widget.item);
      if (mounted) {
        setState(() {
          _dynamicEpisodes = episodes;
          _isLoadingEpisodes = false;
          _groupEpisodes();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingEpisodes = false);
        debugPrint('Error loading episodes: $e');
      }
    }
  }

  void _groupEpisodes() {
    // Determinar la firma de capitalización del nombre de la serie padre,
    // para excluir episodios que pertenecen a OTRA versión con distinto estilo.
    // Ej: "ONE PIECE" (upper) ≠ "One Piece" (title)
    final parentCapSig = _capSignature(widget.item.name);

    final episodesToGroup =
        _dynamicEpisodes.isNotEmpty ? _dynamicEpisodes : widget.item.episodes;

    final filteredEpisodes = _m3uService.filterValidItems(episodesToGroup);
    for (var ep in filteredEpisodes) {
      // Filtrar episodios cuya serie tenga diferente estilo de capitalización
      if (ep.seriesName != null && ep.seriesName!.isNotEmpty) {
        final epCapSig = _capSignature(ep.seriesName!);
        // 'mixed' se deja pasar para no sobre-filtrar casos edge
        if (epCapSig != 'mixed' && epCapSig != parentCapSig) continue;
      }

      final season = ep.seasonNumber ?? 1;
      if (!_seasonMap.containsKey(season)) {
        _seasonMap[season] = [];
      }
      _seasonMap[season]!.add(ep);
    }

    // Ordenar temporadas
    _seasons = _seasonMap.keys.toList()..sort();

    // Ordenar episodios dentro de cada temporada por número de episodio
    for (var season in _seasons) {
      _seasonMap[season]!.sort((a, b) {
        if (a.episodeNumber != null && b.episodeNumber != null) {
          return a.episodeNumber!.compareTo(b.episodeNumber!);
        }
        return a.name.compareTo(b.name);
      });
    }

    if (_seasons.isNotEmpty) {
      _selectedSeason = _seasons.first;
    }
  }

  void _findOtherVersions() {
    // Look for items in the same category with similar names
    // e.g., "Content Name (Sub)" and "Content Name (Latino)"
    final baseName = widget.item.name.split('(').first.trim().toLowerCase();

    final candidates =
        widget.similarItems.where((item) {
          final otherBase = item.name.split('(').first.trim().toLowerCase();
          return otherBase == baseName && item.url != widget.item.url;
        }).toList();
    _otherVersions = _m3uService.filterValidItems(candidates);
  }

  Future<void> _handleSeriesPlay() async {
    final episodes = _allEpisodes;
    final urls = episodes.map((e) => e.url).toList();

    // Check for watch history
    final lastWatched = await WatchProgressService().getLastWatchedFromList(
      urls,
    );

    if (!mounted) return;

    if (lastWatched != null) {
      // Find the episode object
      final episodeIndex = _allEpisodes.indexWhere(
        (e) => e.url == lastWatched.url,
      );
      if (episodeIndex != -1) {
        M3UItem targetEpisode = _allEpisodes[episodeIndex];
        String dialogTitle = "Continuar viendo";
        String dialogBody = "Te quedaste en: ${targetEpisode.name}";
        // If completed, propose next episode
        if (lastWatched.isCompleted && episodeIndex < _allEpisodes.length - 1) {
          targetEpisode = _allEpisodes[episodeIndex + 1];
          dialogTitle = "Siguiente episodio";
          dialogBody = "Continuar con: ${targetEpisode.name}";
        } else if (lastWatched.isCompleted) {
          _playContent(_allEpisodes.first, playlist: _allEpisodes);
          return;
        }

        // Show custom premium dialog
        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: '',
          barrierColor: AppColors.background.withOpacity(0.4),
          transitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (context, anim1, anim2) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child:
                      PerformanceService().shouldShowExpensiveEffects
                          ? BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                            child: Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: AppColors.background.withOpacity(0.7),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.1),
                                  width: 1,
                                ),
                              ),
                              child: _buildContinueDialogContent(
                                dialogTitle,
                                dialogBody,
                                episodes,
                                targetEpisode,
                              ),
                            ),
                          )
                          : Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1a1a1a),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.1),
                                width: 1,
                              ),
                            ),
                            child: _buildContinueDialogContent(
                              dialogTitle,
                              dialogBody,
                              episodes,
                              targetEpisode,
                            ),
                          ),
                ),
              ),
            );
          },
          transitionBuilder: (context, anim1, anim2, child) {
            return FadeTransition(
              opacity: anim1,
              child: ScaleTransition(
                scale: CurvedAnimation(
                  parent: anim1,
                  curve: Curves.easeOutBack,
                ),
                child: child,
              ),
            );
          },
        );
        return;
      }
    }

    // Default: Play first episode
    _playContent(_allEpisodes.first, playlist: _allEpisodes);
  }

  Widget _buildContinueDialogContent(
    String title,
    String body,
    List<M3UItem> episodes,
    M3UItem targetEpisode,
  ) {
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18.5,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _playContent(episodes.first, playlist: episodes);
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    "Empezar de cero",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _playContent(targetEpisode, playlist: episodes);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    "Continuar",
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
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
    );
  }

  void _playContent(M3UItem item, {List<M3UItem>? playlist}) async {
    _navigateToPlayer(item, playlist: playlist);
  }

  void _navigateToPlayer(
    M3UItem item, {
    List<M3UItem>? playlist,
    bool skipPrewarm = false,
  }) {
    final playerToPass = skipPrewarm ? null : _prewarmPlayer;

    // ── 1. GESTIÓN ESTRICTA DE RECURSOS (Motorola Fix) ──────────────
    // Si no vamos a usar el prewarm (porque skipPrewarm es true o falló),
    // debemos destruirlo YA MISMO. No puede quedar "vivo" en el fondo
    // mientras abrimos la pantalla del reproductor real.
    if (playerToPass == null) {
      final p = _prewarmPlayer;
      _prewarmPlayer = null;
      p?.dispose();
    } else {
      // Si lo pasamos, quitamos la referencia para que VideoPlayerScreen sea el dueño
      _prewarmPlayer = null;
    }

    Navigator.push(
      context,
      FadeScalePageRoute(
        page: VideoPlayerScreen(
          item: item,
          playlist: playlist ?? [],
          prewarmedPlayer: playerToPass,
        ),
      ),
    ).then((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _handleCast(M3UItem item) async {
    final castService = CastService();
    String urlToLoad = item.url;
    String titleToLoad = item.name;

    if (item.isSeries && item.episodes.isNotEmpty) {
      final firstEp = item.episodes.first;
      urlToLoad = firstEp.url;
      titleToLoad = "${item.name} - ${firstEp.name}";
    }

    final isDynamic = DynamicScraperService().isSupported(urlToLoad);

    if (isDynamic) {
      try {
        final scraper = DynamicScraperService();
        final videoUrl = await scraper.extractVideoSource(urlToLoad);

        if (!mounted) return;

        if (videoUrl != null) {
          urlToLoad = videoUrl;
        } else {
          SnackBarUtils.showAppSnackBar(
            context,
            'No se pudo obtener el enlace para TV. Inténtalo de nuevo.',
          );
          return;
        }
      } catch (e) {
        if (mounted) {
          SnackBarUtils.showAppSnackBar(context, 'Error de conexión: $e');
        }
        return;
      }
    }

    if (!mounted) return;

    AdService().showRewardedAdWithConfirmation(
      context,
      message:
          '¡La pantalla grande te espera! Mira un breve anuncio para proyectar en tu TV y disfrutar al máximo.',
      onUserEarnedReward: () {
        castService.loadMedia(
          urlToLoad,
          title: titleToLoad,
          subtitle: item.category,
        );
        SnackBarUtils.showAppSnackBar(context, 'Reproduciendo en TV...');
      },
      onAdFailed: () {
        if (mounted) {
          SnackBarUtils.showAppSnackBar(
            context,
            'Lo sentimos, no pudimos completar la conexión. (Código: 1007)',
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([PerformanceService(), _m3uService]),
      builder: (context, _) {
        return Scaffold(
          backgroundColor: AppColors.background,
          body: CustomScrollView(
            slivers: [
              _buildSliverAppBar(),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTitleSection(),
                      const SizedBox(height: 20),
                      _buildPlayButton(),
                      const SizedBox(height: 20),
                      _buildDescription(),
                      const SizedBox(height: 12),
                      _buildSocialButtons(),
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white12, height: 1),
                      if (widget.item.isSeries) ...[
                        const SizedBox(height: 24),
                        _buildEpisodesList(),
                      ],
                      if (_otherVersions.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        _buildVersionSelector(),
                      ],
                      if (widget.similarItems.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        _buildSimilarTitles(),
                      ],
                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSliverAppBar() {
    return SliverAppBar(
      expandedHeight: 250,
      pinned: true,
      backgroundColor: AppColors.background,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: () => Navigator.pop(context),
      ),
      actions: [
        const SizedBox(width: 48), // Placeholder for balance
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            // Background Image
            FastThumbnail(
              url: widget.item.logo,
              title: widget.item.name,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              cacheWidth: null, // resolución completa para el hero
              onError: () {
                if (widget.item.logo != null && widget.item.logo!.isNotEmpty) {
                  _m3uService.reportFailedLogo(widget.item.logo!);
                }
              },
            ),

            // Gradient Overlay
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF0a0a0a).withValues(alpha: 0.7),
                    Colors.transparent,
                    Colors.transparent, // Removed heavy bottom shadow
                  ],
                  stops: const [0.0, 0.2, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleSection() {
    final name = widget.item.name;
    final yearMatch = RegExp(r'\s*\((\d{4})\)\s*$').firstMatch(name);
    final displayTitle =
        yearMatch != null ? name.substring(0, yearMatch.start).trim() : name;
    final year = yearMatch?.group(1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          displayTitle,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                widget.item.isSeries ? 'Serie' : 'Película',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (year != null) ...[
              Text(
                year,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 12),
            ],
            if (_metadata != null &&
                _metadata!['rating'] != null &&
                _metadata!['rating'].toString().isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white38, width: 0.8),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  _metadata!['rating'].toString(),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            if (_m3uService.isUnifiedMode &&
                widget.item.sourceName != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white10, width: 0.5),
                ),
                child: Text(
                  widget.item.sourceName!,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Flexible(
              child: Text(
                widget.item.category,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.item.isSeries) ...[
              const SizedBox(width: 12),
              Text(
                _isLoadingEpisodes && _allEpisodes.isEmpty
                    ? ''
                    : '${_allEpisodes.length} Episodios',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Future<WatchProgress?> _getButtonProgress() async {
    if (widget.item.isSeries) {
      final episodes = _allEpisodes;
      final urls = episodes.map((e) => e.url).toList();
      return await WatchProgressService().getLastWatchedFromList(urls);
    } else {
      return await WatchProgressService().getProgress(widget.item.url);
    }
  }

  Widget _buildPlayButton() {
    final castService = CastService();
    // Watch the connectedDevice property to rebuild when it changes
    final isCasting = castService.connectedDevice != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isCasting)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                const Icon(Icons.cast_connected, color: Colors.red, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Reproduciendo en ${castService.connectedDevice!.name}',
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        SizedBox(
          width: double.infinity,
          height: 50, // Fixed height for proper shine alignment
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              children: [
                // Main Button
                Positioned.fill(
                  child: ElevatedButton.icon(
                    onPressed:
                        (_isLoadingEpisodes)
                            ? null
                            : () async {
                              if (isCasting) {
                                _handleCast(widget.item);
                                return;
                              }

                              if (widget.item.isSeries &&
                                  _allEpisodes.isNotEmpty) {
                                _handleSeriesPlay();
                              } else {
                                _playContent(widget.item);
                              }
                            },
                    icon: Icon(
                      isCasting ? Icons.cast : Icons.play_arrow,
                      color: const Color(0xFF0a0a0a),
                      size: 22,
                    ),
                    label: Text(
                      isCasting
                          ? 'Reproducir en TV'
                          : (_isLoadingEpisodes ? 'Ver' : 'Ver'),
                      style: const TextStyle(
                        color: Color(0xFF0a0a0a),
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color.fromARGB(255, 230, 230, 230),
                      foregroundColor: AppColors.background,
                      disabledBackgroundColor: const Color.fromARGB(
                        255,
                        230,
                        230,
                        230,
                      ),
                      shape:
                          const RoundedRectangleBorder(), // Revert to square inside ClipRRect
                      elevation: 0,
                    ),
                  ),
                ),

                // Shine Effect Overlay
                if (PerformanceService().shouldAnimateDecorations)
                  AnimatedBuilder(
                    animation: _shineController,
                    builder: (context, child) {
                      return Positioned(
                        left:
                            -200 +
                            (600 * _shineController.value), // Slide across
                        top: 0,
                        bottom: 0,
                        width: 80,
                        child: Transform(
                          transform: Matrix4.skewX(-0.5),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.white.withOpacity(0.0),
                                  Colors.white.withOpacity(
                                    0.4,
                                  ), // Stronger shine
                                  Colors.white.withOpacity(0.0),
                                ],
                                stops: const [0.0, 0.5, 1.0],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                // Progress Indicator (Timeline)
                FutureBuilder<WatchProgress?>(
                  future: _getButtonProgress(),
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data != null) {
                      final progress = snapshot.data!.progressPercentage;
                      if (progress > 5 && progress < 95) {
                        return Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            height: 4,
                            color: Colors.black26,
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: progress / 100,
                              child: Container(color: Colors.red),
                            ),
                          ),
                        );
                      }
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () async {
              try {
                await widget.onToggleFavorite(widget.item);
                if (mounted) {
                  setState(() {
                    _isFavorite = widget.item.isFavorite;
                  });
                }
              } catch (e) {
                if (mounted) {
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
            },
            icon: Icon(
              _isFavorite ? Icons.check : Icons.add,
              color: Colors.white,
              size: 22,
            ),
            label: Text(
              _isFavorite ? 'En lista' : 'Mi lista',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
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
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              elevation: 0,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSocialButtons() {
    final isCasting = CastService().connectedDevice != null;
    return Row(
      children: [
        // 1. Like
        Container(
          height: 44,
          width: 44,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            shape: BoxShape.rectangle,
          ),
          child: IconButton(
            iconSize: 22,
            padding: EdgeInsets.zero,
            icon:
                _isLiking
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                    : Icon(
                      _isLiked ? Icons.thumb_up : Icons.thumb_up_outlined,
                      color: Colors.white,
                    ),
            onPressed: _isLiking ? null : _toggleLike,
            tooltip: 'Me gusta',
          ),
        ),
        const SizedBox(width: 14),
        // 2. Dislike
        Container(
          height: 44,
          width: 44,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            shape: BoxShape.rectangle,
          ),
          child: IconButton(
            iconSize: 22,
            padding: EdgeInsets.zero,
            icon:
                _isDisliking
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                    : Icon(
                      _isDisliked
                          ? Icons.thumb_down
                          : Icons.thumb_down_outlined,
                      color: Colors.white,
                    ),
            onPressed: _isDisliking ? null : _toggleDislike,
            tooltip: 'No me gusta',
          ),
        ),
        const SizedBox(width: 14),
        // 3. Cast
        Container(
          height: 44,
          width: 44,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            shape: BoxShape.rectangle,
          ),
          child: IconButton(
            iconSize: 21.5,
            padding: EdgeInsets.zero,
            icon: Icon(
              isCasting ? Icons.cast_connected : Icons.cast,
              color: isCasting ? Colors.red : Colors.white,
            ),
            onPressed: () {
              _showCastDialog();
            },
            tooltip: 'Transmitir a TV',
          ),
        ),
        const SizedBox(width: 14),
        // 4. Report
        Container(
          height: 44,
          width: 44,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            shape: BoxShape.rectangle,
          ),
          child: IconButton(
            iconSize: 23.5,
            padding: EdgeInsets.zero,
            icon:
                _isReporting
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                    : const Icon(Icons.flag_outlined, color: Colors.white),
            onPressed: _isReporting ? null : _showReportOptions,
            tooltip: 'Reportar problema',
          ),
        ),
      ],
    );
  }

  Widget _buildDescription() {
    final overview = _metadata?['overview'] ?? '';
    final hasMetadata = overview.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () {
            if (hasMetadata && overview.length > 100) {
              _showFullDescriptionBottomSheet(overview);
            }
          },
          child: Text(
            hasMetadata
                ? overview
                : 'Disfruta de este contenido en alta calidad. Selecciona reproducir para comenzar.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ),
        if (hasMetadata && overview.length > 100)
          GestureDetector(
            onTap: () => _showFullDescriptionBottomSheet(overview),
            child: const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Leer más',
                style: TextStyle(
                  color: Colors.red,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        if (hasMetadata) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.white38, size: 14),
              const SizedBox(width: 6),
              Text(
                'Datos proporcionados por TMDB',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.3),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildEpisodePulse() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Opacity(
          opacity:
              0.4 + (_pulseController.value * 0.4), // Pulse between 0.4 and 0.8
          child: Column(
            children: List.generate(
              3,
              (index) => Container(
                margin: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Container(
                      width: 120,
                      height: 70,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
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
                            height: 12,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: 100,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEpisodesList() {
    final episodes = _seasonMap[_selectedSeason] ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Episodios',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),

            // Premium Season Selector Trigger
            if (_seasons.length > 1)
              Flexible(
                child: InkWell(
                  onTap: _showOverlaySeasonSelector,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            'Temporada $_selectedSeason',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.arrow_drop_down,
                          color: Colors.white,
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 33),
        if (_isLoadingEpisodes)
          _buildEpisodePulse()
        else
          ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final episode = episodes[index];
              return InkWell(
                onTap: () {
                  final castService = CastService();
                  if (castService.connectedDevice != null) {
                    AdService().showRewardedAdWithConfirmation(
                      context,
                      message:
                          '¡Casi listo! Mira un breve anuncio para proyectar este episodio en tu TV.',
                      onUserEarnedReward: () async {
                        String urlToLoad = episode.url;

                        if (episode.isDynamic) {
                          try {
                            final videoUrl = await DynamicScraperService()
                                .extractVideoSource(episode.url);
                            if (!mounted) return;
                            if (videoUrl != null) {
                              urlToLoad = videoUrl;
                            } else {
                              SnackBarUtils.showAppSnackBar(
                                context,
                                'No se pudo obtener el enlace para TV. Inténtalo de nuevo.',
                              );
                              return;
                            }
                          } catch (e) {
                            if (mounted) {
                              SnackBarUtils.showAppSnackBar(
                                context,
                                'Error de conexión: $e',
                              );
                            }
                            return;
                          }
                        }

                        castService.loadMedia(
                          urlToLoad,
                          title: "${widget.item.name} - ${episode.name}",
                          subtitle: widget.item.category,
                        );
                        SnackBarUtils.showAppSnackBar(
                          context,
                          'Reproduciendo ${episode.name} en TV...',
                        );
                      },
                      onAdFailed: () {
                        if (mounted) {
                          SnackBarUtils.showAppSnackBar(
                            context,
                            'Hubo un error de comunicación al cargar el medio. Inténtalo más tarde. (Código de error: 1008)',
                          );
                        }
                      },
                    );
                  } else {
                    _playContent(episode, playlist: episodes);
                  }
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      // Episode Thumbnail
                      SizedBox(
                        width: 120,
                        height: 70,
                        child: Stack(
                          children: [
                            FastThumbnail(
                              url:
                                  (episode.logo != null &&
                                          episode.logo!.isNotEmpty)
                                      ? episode.logo!
                                      : (widget.item.logo ?? ''),
                              title: episode.name,
                              width: 120,
                              height: 70,
                              fit: BoxFit.cover,
                              borderRadius: BorderRadius.circular(8),
                              cacheWidth:
                                  PerformanceService().lowMemoryLimit
                                      ? 150
                                      : 300,
                              onError: () {
                                final logo =
                                    (episode.logo != null &&
                                            episode.logo!.isNotEmpty)
                                        ? episode.logo
                                        : widget.item.logo;
                                if (logo != null) {
                                  _m3uService.reportFailedLogo(logo);
                                }
                              },
                            ),
                            Center(
                              child: Icon(
                                Icons.play_circle_outline,
                                color: Colors.white.withValues(alpha: 0.8),
                                size: 32,
                              ),
                            ),
                            // Progress Indicator (Timeline)
                            FutureBuilder<WatchProgress?>(
                              future: WatchProgressService().getProgress(
                                episode.url,
                              ),
                              builder: (context, snapshot) {
                                if (snapshot.hasData && snapshot.data != null) {
                                  final progress =
                                      snapshot.data!.progressPercentage;
                                  if (progress > 5) {
                                    return Positioned(
                                      bottom: 0,
                                      left: 0,
                                      right: 0,
                                      child: Container(
                                        height: 3,
                                        color: Colors.white24,
                                        child: FractionallySizedBox(
                                          alignment: Alignment.centerLeft,
                                          widthFactor: progress / 100,
                                          child: Container(color: Colors.red),
                                        ),
                                      ),
                                    );
                                  }
                                }
                                return const SizedBox.shrink();
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              episode.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Episodio ${episode.episodeNumber ?? (index + 1)}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(
                              Icons.cast,
                              color: Colors.white54,
                              size: 20,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () async {
                              final castService = CastService();
                              if (castService.connectedDevice != null) {
                                String urlToLoad = episode.url;

                                if (episode.isDynamic) {
                                  try {
                                    final videoUrl =
                                        await DynamicScraperService()
                                            .extractVideoSource(episode.url);
                                    if (!mounted) return;
                                    if (videoUrl != null) {
                                      urlToLoad = videoUrl;
                                    } else {
                                      SnackBarUtils.showAppSnackBar(
                                        context,
                                        'No se pudo obtener el enlace para TV. Inténtalo de nuevo.',
                                      );
                                      return;
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      SnackBarUtils.showAppSnackBar(
                                        context,
                                        'Error de conexión: $e',
                                      );
                                    }
                                    return;
                                  }
                                }

                                castService.loadMedia(
                                  urlToLoad,
                                  title:
                                      "${widget.item.name} - ${episode.name}",
                                  subtitle: widget.item.category,
                                );
                                SnackBarUtils.showAppSnackBar(
                                  context,
                                  'Reproduciendo ${episode.name} en TV...',
                                );
                                // Show interstitial ad when casting
                                AdService().showInterstitialAd();
                              } else {
                                _showCastDialog();
                              }
                            },
                          ),
                        ],
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

  Widget _buildVersionSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Opciones de Idioma / Versiones',
          style: TextStyle(
            color: Colors.white,
            fontSize: 19.7,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            // Current version (disabled-look but indicated)
            _buildVersionChip(widget.item, isCurrent: true),
            // Other versions
            ..._otherVersions.map((v) => _buildVersionChip(v)),
          ],
        ),
      ],
    );
  }

  Widget _buildVersionChip(M3UItem item, {bool isCurrent = false}) {
    // Try to extract language info from parentheses, e.g. "Name (Sub)" -> "Sub"
    String label = 'Estándar';
    if (item.name.contains('(') && item.name.contains(')')) {
      final matches = RegExp(r'\(([^)]+)\)').allMatches(item.name);
      if (matches.isNotEmpty) {
        label = matches.last.group(1)!;
      }
    } else if (item.name.toLowerCase().contains('latino')) {
      label = 'Latino';
    } else if (item.name.toLowerCase().contains('sub')) {
      label = 'Sub';
    } else if (item.name.toLowerCase().contains('castellano')) {
      label = 'Castellano';
    }

    return ActionChip(
      label: Text(
        label,
        style: TextStyle(
          color: isCurrent ? const Color(0xFF0a0a0a) : Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
      backgroundColor: isCurrent ? Colors.white : Colors.white10,
      side: BorderSide(color: isCurrent ? Colors.transparent : Colors.white24),
      onPressed:
          isCurrent
              ? null
              : () {
                Navigator.pushReplacement(
                  context,
                  FadeScalePageRoute(
                    page: ContentDetailScreen(
                      item: item,
                      similarItems: widget.similarItems,
                      onToggleFavorite: widget.onToggleFavorite,
                    ),
                  ),
                );
              },
    );
  }

  Widget _buildSimilarTitles() {
    final filteredSimilar = _m3uService.filterValidItems(widget.similarItems);
    if (filteredSimilar.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Esto te puede gustar',
          style: TextStyle(
            color: Colors.white,
            fontSize: 19.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 215, // High density poster height + title
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount:
                (filteredSimilar.length > 12) ? 12 : filteredSimilar.length,
            itemBuilder: (context, index) {
              final item = filteredSimilar[index];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () {
                    // Calculate similar items for the next screen (excluding the new item)
                    final nextSimilarItems =
                        filteredSimilar
                            .where((i) => i.url != item.url)
                            .toList();

                    final navigator = Navigator.of(context);
                    navigator
                        .push(
                          FadeScalePageRoute(
                            page: ContentDetailScreen(
                              item: item,
                              similarItems: nextSimilarItems,
                              onToggleFavorite: widget.onToggleFavorite,
                            ),
                          ),
                        )
                        .then((result) {
                          // Bubble up the result if an item was selected for play
                          if (result != null && mounted) {
                            navigator.pop(result);
                          }
                        });
                  },
                  child: SizedBox(
                    width: 115, // Standard horizontal row width
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.white10,
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: FastThumbnail(
                                url: item.logo,
                                title: item.name,
                                width: double.infinity,
                                height: double.infinity,
                                fit: BoxFit.cover,
                                cacheWidth:
                                    PerformanceService().lowMemoryLimit
                                        ? 150
                                        : 300,
                                onError: () {
                                  if (item.logo != null) {
                                    _m3uService.reportFailedLogo(item.logo!);
                                  }
                                },
                              ),
                            ),
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
      ],
    );
  }

  void _showCastDialog() {
    final castService = CastService();
    castService.startDiscovery();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1a1a1a),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          titlePadding: const EdgeInsets.only(top: 28, left: 22, right: 16),
          title: const Text(
            'Dispositivos disponibles',
            style: TextStyle(
              color: Colors.white,
              fontSize: 19.6,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Es posible que en algunos dispositivos, el audio del contenido tenga problemas.',
                  textAlign: TextAlign.left,
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
              SizedBox(
                width: double.maxFinite,
                height: 200,
                child: StreamBuilder<List<CastDevice>>(
                  stream: castService.deviceStream,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Error: ${snapshot.error}',
                          style: const TextStyle(color: Colors.red),
                        ),
                      );
                    }

                    if (!snapshot.hasData || snapshot.data!.isEmpty) {
                      // If scanning is active but list empty
                      return const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(color: Colors.white),
                            SizedBox(height: 16),
                            Text(
                              'Buscando dispositivos...',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      );
                    }

                    final devices = snapshot.data!;
                    return ListView.builder(
                      itemCount: devices.length,
                      itemBuilder: (context, index) {
                        final device = devices[index];
                        final isConnected =
                            castService.connectedDevice?.host == device.host;

                        return ListTile(
                          leading: Icon(
                            isConnected ? Icons.tv_off : Icons.tv,
                            color: isConnected ? Colors.red : Colors.white,
                          ),
                          title: Text(
                            device.name,
                            style: TextStyle(
                              color: isConnected ? Colors.red : Colors.white,
                              fontWeight:
                                  isConnected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            isConnected ? 'Conectado' : device.host,
                            style: TextStyle(
                              color:
                                  isConnected
                                      ? Colors.red.withValues(alpha: 0.7)
                                      : Colors.white54,
                            ),
                          ),
                          trailing:
                              isConnected
                                  ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.red,
                                  )
                                  : null,
                          onTap: () async {
                            final navigator = Navigator.of(context);

                            try {
                              if (isConnected) {
                                await castService.disconnect();
                                if (context.mounted) {
                                  SnackBarUtils.showAppSnackBar(
                                    context,
                                    'Desconectado de ${device.name}',
                                  );
                                }
                              } else {
                                // SHOW REWARDED AD WITH CONFIRMATION BEFORE CASTING
                                AdService().showRewardedAdWithConfirmation(
                                  context,
                                  message:
                                      '¡Excelente elección! Mira un anuncio corto para disfrutar esta película en tu TV.',
                                  onUserEarnedReward: () async {
                                    if (castService.connectedDevice != null) {
                                      await castService.disconnect();
                                    }

                                    await castService.connect(device);
                                    if (context.mounted) {
                                      SnackBarUtils.showAppSnackBar(
                                        context,
                                        'Conectado a ${device.name}',
                                      );
                                    }

                                    await Future.delayed(
                                      const Duration(seconds: 1),
                                    );

                                    String urlToLoad = widget.item.url;
                                    String titleToLoad = widget.item.name;

                                    if (widget.item.isSeries &&
                                        widget.item.episodes.isNotEmpty) {
                                      // For series, load the first episode
                                      urlToLoad =
                                          widget.item.episodes.first.url;
                                      titleToLoad =
                                          "${widget.item.name} - ${widget.item.episodes.first.name}";
                                    }

                                    await castService.loadMedia(
                                      urlToLoad,
                                      title: titleToLoad,
                                      subtitle: widget.item.category,
                                    );
                                    // Show interstitial ad when casting
                                    AdService().showInterstitialAd();
                                  },
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                SnackBarUtils.showAppSnackBar(
                                  context,
                                  'Error: $e',
                                );
                              }
                            } finally {
                              if (mounted && navigator.canPop()) {
                                navigator.pop();
                              }
                            }
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                castService.stopDiscovery();
                Navigator.pop(context);
              },
              child: const Text(
                'Cerrar',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        );
      },
    ).then((_) => castService.stopDiscovery());
  }
}
