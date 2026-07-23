import '../services/fast_image_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../services/m3u_service.dart';
import '../services/watch_progress_service.dart';
import 'content_detail_screen.dart';
import '../utils/colors.dart';
import '../utils/transitions.dart';
import '../services/network_quality_service.dart';
import 'stream_browser_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryEntry {
  final M3UItem item;
  final WatchProgress progress;
  _HistoryEntry(this.item, this.progress);
}

class _HistoryScreenState extends State<HistoryScreen> {
  final M3UService _m3uService = M3UService();
  final WatchProgressService _watchProgressService = WatchProgressService();

  List<_HistoryEntry> _historyEntries = [];
  bool _isLoading = true;
  bool _isOffline = false;
  bool _bannerDismissed = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _watchProgressService.addListener(_loadHistory);

    _isOffline =
        NetworkQualityService().quality.value == NetworkQuality.offline;
    NetworkQualityService().quality.addListener(_onNetworkQualityChanged);
  }

  @override
  void dispose() {
    _watchProgressService.removeListener(_loadHistory);
    NetworkQualityService().quality.removeListener(_onNetworkQualityChanged);
    super.dispose();
  }

  void _onNetworkQualityChanged() {
    final offline =
        NetworkQualityService().quality.value == NetworkQuality.offline;
    if (_isOffline != offline) {
      if (mounted) {
        setState(() {
          _isOffline = offline;
          if (offline) _bannerDismissed = false;
        });
      }
    }
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);

    final history = await _watchProgressService.getHistory();

    final List<_HistoryEntry> entries = [];
    final Set<String> seenContentKeys = {};

    for (final progress in history) {
      final item = _m3uService.resolveItemFromProgress(progress);

      if (item != null) {
        // Dedup by normalized content identity: prevents duplicate series
        // shells and the same movie saved under different URLs (distinct
        // sources / refreshed tokens) from appearing twice.
        if (!seenContentKeys.add(item.contentKey)) continue;
        entries.add(_HistoryEntry(item, progress));
      }
    }

    if (mounted) {
      setState(() {
        _historyEntries = entries;
        _isLoading = false;
      });
    }
  }

  Future<void> _clearHistory() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: const Text(
                  'Borrar actividad',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.07)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  '¿Estás seguro de que quieres borrar toda tu actividad? Esta acción no se puede deshacer.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 14,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => Navigator.pop(context, false),
                        child: Container(
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.1),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            'Cancelar',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => Navigator.pop(context, true),
                        child: Container(
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.red.withValues(alpha: 0.4),
                              width: 1,
                            ),
                          ),
                          child: const Text(
                            'Borrar',
                            style: TextStyle(
                              color: Colors.red,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
            ],
          ),
        );
      },
    );

    if (confirmed == true) {
      await _watchProgressService.clearAllProgress();
      _loadHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Actividad de visualización',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        actions: [
          if (_historyEntries.isNotEmpty)
            IconButton(
              icon: const Icon(CupertinoIcons.trash, color: Colors.white70),
              onPressed: _clearHistory,
              tooltip: 'Borrar actividad',
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            _isLoading
                ? const Center(
                  child: CircularProgressIndicator(color: Colors.red),
                )
                : _historyEntries.isEmpty
                ? _buildEmptyState()
                : _buildHistoryGrid(),
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
                          key: const ValueKey('history_banner_visible'),
                          onDismiss: () {
                            setState(() => _bannerDismissed = true);
                          },
                        )
                        : const SizedBox.shrink(
                          key: ValueKey('history_banner_hidden'),
                        ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.rectangle_stack_fill_badge_minus,
            size: 58.6,
            color: Colors.white.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'Ups, no hay nada aún',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 16.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryGrid() {
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = (screenWidth / 160).floor().clamp(3, 12);

    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.6,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _historyEntries.length,
      itemBuilder: (context, index) {
        final entry = _historyEntries[index];
        return _buildGridCard(entry);
      },
    );
  }

  Widget _buildGridCard(_HistoryEntry entry) {
    final item = entry.item;
    final progress = entry.progress;

    return GestureDetector(
      onTap: () async {
        var targetItem = item;

        if (item.isSeries) {
          targetItem = item; // It's already the shell
        }

        final similarItems = _m3uService.getSimilarItems(targetItem);

        await Navigator.push(
          context,
          ContentDetailPageRoute(
            page: ContentDetailScreen(
              item: targetItem,
              similarItems: similarItems,
              onToggleFavorite: (favItem) async {
                await _m3uService.toggleFavorite(favItem);
                if (mounted) setState(() {});
              },
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1a1a1a),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FastThumbnail(
                  url: item.logo,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                  cacheWidth: 200,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.name.replaceAll(RegExp(r'\s*\(\d{4}\)'), ''),
            style: TextStyle(
              color: AppColors.textMuted.withValues(alpha: 0.82),
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.progressPercentage / 100,
              backgroundColor: Colors.white10,
              color: Colors.red,
              minHeight: 2,
            ),
          ),
        ],
      ),
    );
  }
}
