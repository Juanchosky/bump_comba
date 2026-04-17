import 'package:bump_comba/services/m3u_service.dart';
import 'package:bump_comba/screens/content_detail_screen.dart';
import 'package:flutter/material.dart';
import '../services/performance_service.dart';
import '../services/fast_image_service.dart';
import '../utils/transitions.dart';
import '../utils/colors.dart';

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
  late List<M3UItem> _displayItems;
  final M3UService _m3uService = M3UService();

  @override
  void initState() {
    super.initState();
    // Pre-filter definitely invalid items
    _displayItems = _m3uService.filterValidItems(widget.items);

    // Aggressive pre-caching for first category items
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final urls =
            _displayItems
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
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([PerformanceService(), _m3uService]),
      builder: (context, _) {
        // Re-filter if M3UService updated (e.g. from internal failures)
        final currentItems = _m3uService.filterValidItems(widget.items);

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
            child: GridView.builder(
              padding: const EdgeInsets.all(10),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: (MediaQuery.of(context).size.width / 160)
                    .floor()
                    .clamp(3, 12),
                childAspectRatio: 0.6,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: currentItems.length,
              itemBuilder: (context, index) {
                final item = currentItems[index];
                return GestureDetector(
                  onTap: () async {
                    // Calculate similar items
                    final similarItems =
                        widget.items.where((i) => i.url != item.url).toList();
                    similarItems.shuffle();

                    await Navigator.push(
                      context,
                      FadeScalePageRoute(
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
