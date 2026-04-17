import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'm3u_service.dart';

class ScrapedMetadata {
  final String title;
  final String? thumbnailUrl;
  final String? description;
  final List<M3UItem> episodes;

  ScrapedMetadata({
    required this.title,
    this.thumbnailUrl,
    this.description,
    this.episodes = const [],
  });
}

class DynamicScraperService {
  static final DynamicScraperService _instance =
      DynamicScraperService._internal();
  factory DynamicScraperService() => _instance;
  DynamicScraperService._internal();

  static bool _isScrapingGlobal = false;
  HeadlessInAppWebView? _headlessWebView;
  String? _currentSessionId;

  /// Detects if a URL is from a supported dynamic site.
  bool isSupported(String url) {
    if (url.isEmpty) return false;
    final lowUrl = url.toLowerCase();

    // FlixLat variants
    if (lowUrl.contains('flixlat.com') ||
        lowUrl.contains('flixlat.org') ||
        lowUrl.contains('flixlat.am') ||
        lowUrl.contains('flixlat.lat') ||
        lowUrl.contains('flixlat.cc') ||
        lowUrl.contains('flixlat.to') ||
        lowUrl.contains('flixlatam.com')) {
      return true;
    }

    // DramasFree variants
    if (lowUrl.contains('dramasfree.com') ||
        lowUrl.contains('dramasfree.cc') ||
        lowUrl.contains('dramasfree.org') ||
        lowUrl.contains('dramasfree.io')) {
      return true;
    }

    // PeliculaPlay variants
    if (lowUrl.contains('peliculaplay.com') ||
        lowUrl.contains('peliculaplay.org')) {
      return true;
    }

    // Universal Fallback: If URL contains common movie detail patterns
    // and is NOT a direct video filename, treat as dynamic.
    if (!lowUrl.endsWith('.m3u8') &&
        !lowUrl.endsWith('.mp4') &&
        !lowUrl.endsWith('.mkv') &&
        !lowUrl.contains('.m3u8?') &&
        !lowUrl.contains('.mp4?')) {
      if (lowUrl.contains('/detail/') ||
          lowUrl.contains('/movie/') ||
          lowUrl.contains('/serie/') ||
          lowUrl.contains('/watch/') ||
          lowUrl.contains('/ver/')) {
        return true;
      }
    }

    return false;
  }

  /// Extracts metadata from a supported URL.
  Future<ScrapedMetadata?> scrapeMetadata(String url) async {
    if (!isSupported(url)) return null;
    if (_isScrapingGlobal) await _disposeHeadless();
    _isScrapingGlobal = true;

    final completer = Completer<ScrapedMetadata?>();
    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _currentSessionId = sessionId;

    // Cleanup previous if any
    await _disposeHeadless();

    try {
      _headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          userAgent:
              'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
          javaScriptEnabled: true,
          useShouldInterceptRequest: true,
          allowsInlineMediaPlayback: false,
          offscreenPreRaster: false,
          transparentBackground: true,
          hardwareAcceleration:
              false, // CRITICAL: Release Surface buffers for the Video Player
        ),
        shouldInterceptRequest: (controller, request) async {
          if (_currentSessionId != sessionId || _headlessWebView == null) {
            return null;
          }

          final urlStr = request.url.toString();

          // CLOUDFLARE BYPASS: Never block cdn-cgi or cloudflare scripts
          if (urlStr.contains('cdn-cgi') || urlStr.contains('cloudflare')) {
            return null;
          }

          // ANR PREVENTION: Block known heavy/ad domains immediately
          final blockList = [
            'doubleclick.net',
            'google-analytics',
            'googlesyndication',
            'googletagmanager',
            'googleadservices',
            'ads.google',
            'facebook.net',
            'pixel.facebook',
            'analytics',
            'tracker',
            'clarity.ms',
            'adnxs.com',
            'amazon-adsystem',
            'popad',
            'popmoney',
            'histats',
            'yandex.ru',
            'taboola.com',
            'outbrain.com',
            'mgid.com',
            'pubmatic.com',
            'rubiconproject',
            'openx.net',
            'coinhive',
            'miner',
          ];

          if (blockList.any((domain) => urlStr.contains(domain))) {
            return WebResourceResponse(
              contentType: 'text/plain',
              data: Uint8List(0),
            );
          }

          // Performance: Block images during metadata extraction
          if (urlStr.endsWith('.jpg') ||
              urlStr.endsWith('.png') ||
              urlStr.endsWith('.gif') ||
              urlStr.endsWith('.webp')) {
            return WebResourceResponse(
              contentType: 'image/gif',
              data: Uint8List(0),
            );
          }

          return null;
        },
        onLoadStop: (controller, url) async {
          // SAFE CHECK: Check session and if webview still exists
          if (_currentSessionId != sessionId || _headlessWebView == null) {
            return;
          }

          try {
            // Wait for hydration/rendering (Reduced time to avoid ANR)
            await Future.delayed(const Duration(milliseconds: 800));

            if (_currentSessionId != sessionId || _headlessWebView == null) {
              return;
            }

            final dynamic resultObj = await controller.evaluateJavascript(
              source: """
              (function() {
                try {
                  const title = document.querySelector('h1, .detail-title')?.innerText || document.title;
                  const thumb = document.querySelector('img[src*="img."], img[src*="poster"], .detail-poster img')?.src || '';
                  const desc = document.querySelector('.description, .synopsis, .detail-overview')?.innerText || '';
                  
                  const episodes = [];
                  const epElements = document.querySelectorAll('a[href*="/episode/"], .episode-item, .list-episodes a, [class*="episode"] a');
                  
                  epElements.forEach((el, index) => {
                    const epTitle = el.innerText.trim() || ("Episodio " + (index + 1));
                    const epUrl = el.href;
                    if (epUrl && !episodes.find(e => e.url === epUrl)) {
                      episodes.push({ title: epTitle, url: epUrl });
                    }
                  });

                  return { title, thumbnailUrl: thumb, description: desc, episodes };
                } catch (e) { return null; }
              })()
            """,
            );

            if (_currentSessionId != sessionId) return;

            if (resultObj != null && resultObj is Map) {
              final result = Map<String, dynamic>.from(resultObj);
              final List<M3UItem> m3uEpisodes = [];
              final List<dynamic> eps = result['episodes'] ?? [];

              for (var epRaw in eps) {
                if (epRaw is! Map) continue;
                final ep = Map<String, dynamic>.from(epRaw);
                m3uEpisodes.add(
                  M3UItem(
                    name: ep['title']?.toString() ?? 'Episodio',
                    url: ep['url']?.toString() ?? '',
                    logo: result['thumbnailUrl']?.toString(),
                    category: 'Episodios',
                    isLive: false,
                    isDynamic: true,
                  ),
                );
              }

              if (!completer.isCompleted) {
                completer.complete(
                  ScrapedMetadata(
                    title: result['title']?.toString() ?? 'Sin título',
                    thumbnailUrl: result['thumbnailUrl']?.toString(),
                    description: result['description']?.toString(),
                    episodes: m3uEpisodes,
                  ),
                );
              }
            } else {
              // Wait a bit more if we see "Attention Required" or "Cloudflare"
              final pageTitle = await controller.getTitle() ?? "";
              if (pageTitle.contains("Attention Required") ||
                  pageTitle.contains("Cloudflare")) {
                await Future.delayed(const Duration(seconds: 4));
                // Try one more time script injection after delay
                // ... handled by the next call if it didn't complete
              }
              if (!completer.isCompleted) completer.complete(null);
            }
          } catch (e) {
            debugPrint('Scraper inner error: $e');
            if (!completer.isCompleted) completer.complete(null);
          } finally {
            if (_currentSessionId == sessionId) {
              _disposeHeadless();
              _isScrapingGlobal = false;
            }
          }
        },
      );

      await _headlessWebView?.run();

      return await completer.future.timeout(
        const Duration(seconds: 35),
        onTimeout: () {
          if (_currentSessionId == sessionId) _disposeHeadless();
          return null;
        },
      );
    } catch (e) {
      debugPrint('Scraper execution error: $e');
      return null;
    }
  }

  /// Attempts to extract a direct video source (m3u8/mp4) from an episode page.
  Future<String?> extractVideoSource(String pageUrl) async {
    if (!isSupported(pageUrl)) return null;
    if (_isScrapingGlobal) await _disposeHeadless();
    _isScrapingGlobal = true;

    final completer = Completer<String?>();
    final sessionId = 'extract_${DateTime.now().millisecondsSinceEpoch}';
    _currentSessionId = sessionId;

    await _disposeHeadless();

    try {
      _headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(pageUrl)),
        initialSettings: InAppWebViewSettings(
          userAgent:
              'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
          javaScriptEnabled: true,
          useShouldInterceptRequest: true,
          mediaPlaybackRequiresUserGesture: false,
          offscreenPreRaster: false,
          transparentBackground: true,
          hardwareAcceleration:
              false, // CRITICAL: Release Surface buffers for the Video Player
        ),
        shouldInterceptRequest: (controller, request) async {
          if (_currentSessionId != sessionId || _headlessWebView == null) {
            return null;
          }

          final urlStr = request.url.toString();

          // CLOUDFLARE BYPASS: Never block cdn-cgi or cloudflare scripts
          if (urlStr.contains('cdn-cgi') || urlStr.contains('cloudflare')) {
            return null;
          }

          // Block ads also during video extraction (essential for performance)
          final adList = [
            'ads',
            'tracker',
            'clarity.ms',
            'popad',
            'popmoney',
            'doubleclick',
            'google-analytics',
            'googletagmanager',
            'pixel.facebook',
            'adnxs',
            'taboola',
            'outbrain',
            'mgid',
          ];
          if (adList.any((domain) => urlStr.contains(domain))) {
            return WebResourceResponse(
              contentType: 'text/plain',
              data: Uint8List(0),
            );
          }

          // Network sniffing is MUCH faster than waiting for onLoadStop
          if (urlStr.contains('.m3u8') ||
              urlStr.contains('.mp4') ||
              urlStr.contains('googlevideo.com')) {
            if (!completer.isCompleted) {
              final result = urlStr;
              completer.complete(result);
              // FOUND: Dispose as soon as possible
              _disposeHeadless();
            }
          }
          return null;
        },
        onLoadStop: (controller, url) async {
          if (_currentSessionId != sessionId || _headlessWebView == null) {
            return;
          }

          try {
            await Future.delayed(const Duration(milliseconds: 1500));

            if (_currentSessionId != sessionId || _headlessWebView == null) {
              return;
            }

            final source = await controller.evaluateJavascript(
              source: """
              (function() {
                try {
                  // 1. Direct video tag
                  const video = document.querySelector('video');
                  if (video && video.src && video.src.startsWith('http')) return video.src;
                  if (video && video.querySelector('source')) {
                    const src = video.querySelector('source').src;
                    if (src && src.startsWith('http')) return src;
                  }
                  
                  // 2. Common iframes
                  const selectors = [
                    'iframe[src*="embed"]', 
                    'iframe[src*="player"]', 
                    'iframe[src*="vidsrc"]', 
                    'iframe[src*="superembed"]',
                    'iframe[src*="vid"]',
                    'iframe[src*="peliculaplay"]',
                    '.video-container iframe',
                    '#player-iframe'
                  ];
                  
                  for (const sel of selectors) {
                    const iframe = document.querySelector(sel);
                    if (iframe && iframe.src && iframe.src.startsWith('http')) return iframe.src;
                  }
                  
                  // 3. Fallback for mobile specific - click play if found
                  const playBtn = document.querySelector('.play-btn, .btn-play, .vjs-big-play-button');
                  if (playBtn) playBtn.click();

                  return null;
                } catch (e) { return null; }
              })()
            """,
            );

            if (_currentSessionId == sessionId &&
                source != null &&
                !completer.isCompleted) {
              completer.complete(source.toString());
            } else {
              // Cloudflare catch
              final pageTitle = await controller.getTitle() ?? "";
              if (pageTitle.contains("Attention Required") ||
                  pageTitle.contains("Cloudflare")) {
                await Future.delayed(const Duration(seconds: 4));
              }
            }
          } catch (e) {
            debugPrint('Source extraction error: $e');
          }
        },
      );

      await _headlessWebView?.run();

      final result = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          if (_currentSessionId == sessionId) _disposeHeadless();
          return null;
        },
      );

      if (_currentSessionId == sessionId) {
        _disposeHeadless();
        _isScrapingGlobal = false;
      }
      return result;
    } catch (e) {
      debugPrint('Fatal extraction error: $e');
      if (_currentSessionId == sessionId) {
        _disposeHeadless();
        _isScrapingGlobal = false;
      }
      return null;
    }
  }

  /// Ensures all ongoing scraping tasks are stopped and resources released.
  Future<void> stopCurrentScraping() async {
    _currentSessionId = 'stop_${DateTime.now().millisecondsSinceEpoch}';
    await _disposeHeadless();
    _isScrapingGlobal = false;
  }

  Future<void> _disposeHeadless() async {
    try {
      if (_headlessWebView != null) {
        final webViewToDispose = _headlessWebView;
        _headlessWebView = null; // Mark as null immediately
        await webViewToDispose?.dispose();
        // Give the OS a moment to reclaim the surface
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } catch (e) {
      debugPrint('Error disposing headless: $e');
    }
  }
}
