import 'dart:async';
import 'package:flutter/foundation.dart';
import 'tmdb_service.dart';

/// Service to handle on-demand metadata fallback (like missing posters) from TMDB.
/// It implements in-memory caching and request de-duplication to prevent
/// excessive API calls during list scrolling.
class MetadataFallbackService {
  static final MetadataFallbackService _instance = MetadataFallbackService._internal();
  factory MetadataFallbackService() => _instance;
  MetadataFallbackService._internal();

  final TMDBService _tmdb = TMDBService();
  
  // Cache: "title_isSeries" -> "posterUrl"
  final Map<String, String?> _posterCache = {};
  
  // Track pending lookups to avoid duplicate requests for the same title
  final Map<String, Future<String?>> _pendingLookups = {};

  /// Resolves a poster URL from TMDB for the given title.
  /// Returns null if not found.
  Future<String?> getFallbackPoster(String title, {bool isSeries = false}) async {
    if (title.isEmpty) return null;

    final cacheKey = '${title.trim().toLowerCase()}_$isSeries';

    // 1. Check cache
    if (_posterCache.containsKey(cacheKey)) {
      return _posterCache[cacheKey];
    }

    // 2. Check pending
    if (_pendingLookups.containsKey(cacheKey)) {
      return _pendingLookups[cacheKey];
    }

    // 3. New lookup
    final completer = Completer<String?>();
    _pendingLookups[cacheKey] = completer.future;

    try {
      final details = await _tmdb.searchAndGetDetails(title, isSeries: isSeries);
      final String? posterUrl = details['poster_url'] as String?;
      
      _posterCache[cacheKey] = posterUrl;
      completer.complete(posterUrl);
    } catch (e) {
      debugPrint('MetadataFallbackService error for $title: $e');
      _posterCache[cacheKey] = null;
      completer.complete(null);
    } finally {
      _pendingLookups.remove(cacheKey);
    }

    return completer.future;
  }

  /// Manually pre-seed the cache if we already fetched metadata elsewhere
  void seedCache(String title, bool isSeries, String? posterUrl) {
    if (title.isEmpty) return;
    final cacheKey = '${title.trim().toLowerCase()}_$isSeries';
    _posterCache[cacheKey] = posterUrl;
  }
}
