import '../services/m3u_service.dart';
import 'content_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../services/performance_service.dart';
import '../services/fast_image_service.dart';
import '../utils/transitions.dart';
import '../utils/colors.dart';
import '../services/network_quality_service.dart';
import 'stream_browser_screen.dart';

// Since we need to play items, we need access to the player logic or open details logic.
// Simpler approach: Category screen opens ContentDetailScreen when item is tapped.
// ContentDetailScreen handles 'onPlay' and 'onFavorite'.
// But 'onPlay' needs to launch the player in StreamBrowserScreen context or we need a global player screen.
// Wait, StreamBrowserScreen has the player.
// If we navigate to CategoryScreen, and then ContentDetailScreen, and then 'Play',
// We pop Detail, then Pop Category? Or just Play?
// If we Pop all the way back to StreamBrowserScreen, it works.
// We can use Navigator.popUntil(context, ModalRoute.withName('/hidden')) if we named routes.
// Or just pop until first screen.

class CategoryScreen extends StatefulWidget {
  final String title;
  final List<M3UItem> items;

  const CategoryScreen({super.key, required this.title, required this.items});

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  final M3UService _m3uService = M3UService();
  final ScrollController _scrollController = ScrollController();
  int _displayCount = 30;
  bool _isLoadingMore = false;
  bool _isOffline = false;
  bool _bannerDismissed = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);

    _isOffline =
        NetworkQualityService().quality.value == NetworkQuality.offline;
    NetworkQualityService().quality.addListener(_onNetworkQualityChanged);

    // Aggressive pre-caching for first category items
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final currentItems = _m3uService.filterValidItems(widget.items);
        final urls =
            currentItems
                .take(15)
                .map((i) => i.logo)
                .whereType<String>()
                .toList();
        if (urls.isNotEmpty) {
          FastImageService().prewarm(urls, context);
        }
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
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

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreItems();
    }
  }

  void _loadMoreItems() async {
    final currentItems = _m3uService.filterValidItems(widget.items);
    if (_isLoadingMore || _displayCount >= currentItems.length) return;
    setState(() {
      _isLoadingMore = true;
    });

    final nextBatch = currentItems.skip(_displayCount).take(30).toList();
    final urls = nextBatch.map((i) => i.logo).whereType<String>().toList();

    await Future.wait([
      Future.delayed(const Duration(milliseconds: 600)),
      if (urls.isNotEmpty) FastImageService().prewarmAndAwait(urls, context),
    ]);

    if (!mounted) return;
    setState(() {
      _displayCount = (_displayCount + 30).clamp(0, currentItems.length);
      _isLoadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([PerformanceService(), _m3uService]),
      builder: (context, _) {
        // Re-filter if M3UService updated (e.g. from internal failures)
        final currentItems = _m3uService.filterValidItems(widget.items);
        final itemsToDisplay = currentItems.take(_displayCount).toList();

        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            title: Text(
              widget.title,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
            backgroundColor: AppColors.background,
            foregroundColor: Colors.white,
          ),
          body: SafeArea(
            child: Stack(
              children: [
                CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.all(10),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: (MediaQuery.of(context).size.width / 160)
                              .floor()
                              .clamp(3, 12),
                          childAspectRatio: 0.6,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final item = itemsToDisplay[index];
                            return GestureDetector(
                              onTap: () async {
                                // Calculate similar items
                                final similarItems =
                                    widget.items.where((i) => i.url != item.url).toList();
                                similarItems.shuffle();

                                await Navigator.push(
                                  context,
                                  ContentDetailPageRoute(
                                    page: ContentDetailScreen(
                                      item: item,
                                      similarItems: similarItems.take(10).toList(),
                                      onToggleFavorite: (favItem) async {
                                        await _m3uService.toggleFavorite(favItem);
                                        if (mounted) setState(() {});
                                      },
                                    ),
                                  ),
                                );
                              },
                              child: _buildCard(item),
                            );
                          },
                          childCount: itemsToDisplay.length,
                        ),
                      ),
                    ),
                    if (_isLoadingMore)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(
                            child: CupertinoActivityIndicator(
                              radius: 14,
                              color: Colors.white,
                            ),
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
                              key: const ValueKey('category_banner_visible'),
                              onDismiss: () {
                                setState(() => _bannerDismissed = true);
                              },
                            )
                            : const SizedBox.shrink(
                              key: ValueKey('category_banner_hidden'),
                            ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard(M3UItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: FastThumbnail(
              url: item.logo,
              title: item.name,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              cacheWidth: 300,
              onError: () {
                if (item.logo != null) {
                  _m3uService.reportFailedLogo(item.logo!);
                }
              },
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
    );
  }
}
