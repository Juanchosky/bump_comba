import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'm3u_service.dart';
import '../screens/content_detail_screen.dart';
import '../utils/transitions.dart';

class DeepLinkService {
  static final DeepLinkService _instance = DeepLinkService._internal();
  factory DeepLinkService() => _instance;
  DeepLinkService._internal();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  /// Global key for navigation if needed, or we use the current context
  void init(BuildContext context) {
    // 1. Handle app started from a terminated state
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) {
        _handleUri(context, uri);
      }
    });

    // 2. Handle app started from background / foreground
    _linkSubscription?.cancel();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleUri(context, uri);
    });
  }

  void dispose() {
    _linkSubscription?.cancel();
  }

  void _handleUri(BuildContext context, Uri uri) {
    debugPrint('Incoming deep link: $uri');

    // Support formats:
    // https://bump-comba.vercel.app/details?n=Inception&s=0
    // comba://details?n=Inception&s=1

    if (uri.path.contains('/details') || uri.host == 'details') {
      final String? name = uri.queryParameters['n'];
      final bool isSeries = uri.queryParameters['s'] == '1';

      if (name != null && name.isNotEmpty) {
        _findAndNavigate(context, name, isSeries);
      }
    }
  }

  Future<void> _findAndNavigate(
    BuildContext context,
    String name,
    bool isSeries,
  ) async {
    final m3uService = M3UService();

    // If items are not loaded yet, wait until they are (up to 15 seconds)
    if (m3uService.items.isEmpty) {
      debugPrint('DeepLink: Items empty, checking cache or loading...');

      // Ensure service is initialized
      await m3uService.init();

      // Try to load from cache first for speed
      if (m3uService.items.isEmpty) {
        await m3uService.loadFromCache();
      }

      // If still empty, wait a bit for any background loading to finish
      int attempts = 0;
      while (m3uService.items.isEmpty && attempts < 10) {
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;
      }

      // Final fallback: if STILL empty, force a remote load
      if (m3uService.items.isEmpty) {
        debugPrint('DeepLink: Forcing remote load...');
        await m3uService.loadM3UContent(useRetry: false);
      }

      if (m3uService.items.isEmpty) {
        debugPrint('DeepLink: Failed to load items for deep link');
        return;
      }
    }

    final String query = name.toLowerCase();

    // Try to find an exact or close match
    final results = m3uService.search(query);

    if (results.isNotEmpty) {
      // Prioritize by isSeries flag
      M3UItem? target;
      try {
        target = results.firstWhere((item) => item.isSeries == isSeries);
      } catch (_) {
        target = results.first;
      }

      if (context.mounted) {
        // Navigate to details
        Navigator.push(
          context,
          ContentDetailPageRoute(
            page: ContentDetailScreen(
              item: target,
              similarItems: m3uService.getSimilarItems(target),
              onToggleFavorite: (favItem) async {
                await m3uService.toggleFavorite(favItem);
              },
            ),
          ),
        );
      }
    } else {
      debugPrint('DeepLink: No content found for "$name"');
    }
  }
}
