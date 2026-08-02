import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'm3u_service.dart';

class ScrapedSubtitle {
  final String url;
  final String label;
  final String? language;

  ScrapedSubtitle({
    required this.url,
    required String label,
    this.language,
  }) : label = cleanLanguageLabel(label, language, url);

  static String cleanLanguageLabel(String rawLabel, [String? rawLang, String? url]) {
    final combined = '${rawLabel.toLowerCase()} ${rawLang?.toLowerCase() ?? ''} ${url?.toLowerCase() ?? ''}';

    if (combined.contains('latino') || combined.contains('lat') || combined.contains('es-la') || combined.contains('es_la')) {
      return 'Español (Latino)';
    }
    if (combined.contains('castellano') || combined.contains('es-es') || combined.contains('es_es')) {
      return 'Español (España)';
    }
    if (combined.contains('es') ||
        combined.contains('spa') ||
        combined.contains('spanish') ||
        combined.contains('espanol') ||
        combined.contains('español')) {
      return 'Español';
    }
    if (combined.contains('en') ||
        combined.contains('eng') ||
        combined.contains('english') ||
        combined.contains('inglés') ||
        combined.contains('ingles')) {
      return 'Inglés';
    }
    if (combined.contains('pt') ||
        combined.contains('por') ||
        combined.contains('portuguese') ||
        combined.contains('portugués') ||
        combined.contains('portugues')) {
      return 'Portugués';
    }
    if (combined.contains('fr') ||
        combined.contains('fra') ||
        combined.contains('french') ||
        combined.contains('francés') ||
        combined.contains('frances')) {
      return 'Francés';
    }
    if (combined.contains('de') ||
        combined.contains('ger') ||
        combined.contains('german') ||
        combined.contains('alemán') ||
        combined.contains('aleman')) {
      return 'Alemán';
    }
    if (combined.contains('it') ||
        combined.contains('ita') ||
        combined.contains('italian') ||
        combined.contains('italiano')) {
      return 'Italiano';
    }
    if (combined.contains('ja') ||
        combined.contains('jpn') ||
        combined.contains('japanese') ||
        combined.contains('japonés') ||
        combined.contains('japones')) {
      return 'Japonés';
    }

    final cleanLabel = rawLabel.trim();
    if (cleanLabel.isNotEmpty &&
        !cleanLabel.startsWith('http') &&
        !cleanLabel.contains('.vtt') &&
        !cleanLabel.contains('.srt') &&
        !cleanLabel.contains('/')) {
      return cleanLabel[0].toUpperCase() + cleanLabel.substring(1);
    }

    return 'Español';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScrapedSubtitle &&
          runtimeType == other.runtimeType &&
          url == other.url;

  @override
  int get hashCode => url.hashCode;
}

class ExtractedStreamResult {
  final String videoUrl;
  final List<ScrapedSubtitle> subtitles;

  ExtractedStreamResult({required this.videoUrl, this.subtitles = const []});
}

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

    // Playspelis variants
    if (lowUrl.contains('playspelis.com') ||
        lowUrl.contains('playspelis.org') ||
        lowUrl.contains('playspelis.net') ||
        lowUrl.contains('playspelis.tv') ||
        lowUrl.contains('playspelis')) {
      return true;
    }

    // Cuevana variants
    if (lowUrl.contains('cuevana4br.com') ||
        lowUrl.contains('cuevana') ||
        lowUrl.contains('cuevana3') ||
        lowUrl.contains('cuevana4') ||
        lowUrl.contains('cuevana8')) {
      return true;
    }

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

  /// Evaluates resolution/quality score for stream candidate URLs and labels.
  static int _getQualityScore(String url, [String text = '']) {
    final lowerText = text.toLowerCase();
    final lowerUrl = url.toLowerCase();
    final combined = '$lowerText $lowerUrl';

    // 1. 4K / 2160P (Ultra HD)
    if (combined.contains('2160p') ||
        combined.contains('2160') ||
        combined.contains('4k') ||
        combined.contains('uhd') ||
        combined.contains('ultrahd')) {
      return 2160;
    }

    // 2. 1080P (Full HD)
    if (combined.contains('1080p') ||
        combined.contains('1080') ||
        combined.contains('fhd') ||
        combined.contains('fullhd') ||
        combined.contains('full-hd') ||
        combined.contains('microframe-hd') ||
        lowerUrl.contains('1080.m3u8') ||
        lowerUrl.contains('1080/') ||
        lowerUrl.contains('1080_') ||
        lowerUrl.contains('1080-')) {
      return 1080;
    }

    // 3. 720P (HD)
    if (combined.contains('720p') ||
        combined.contains('720') ||
        combined.contains('microframe-sd') ||
        lowerUrl.contains('-sd.m3u8') ||
        lowerUrl.contains('_sd.m3u8') ||
        lowerUrl.contains('hd.m3u8') ||
        lowerUrl.contains('-hd.m3u8') ||
        lowerUrl.contains('_hd.m3u8') ||
        lowerUrl.contains('720.m3u8') ||
        lowerUrl.contains('720/') ||
        lowerUrl.contains('720_') ||
        lowerUrl.contains('720-') ||
        lowerUrl.contains('high.m3u8') ||
        lowerText == 'hd' ||
        lowerText.contains('720')) {
      return 720;
    }

    // 4. HLS Master Playlists (auto-selects highest resolution inside MPV engine)
    if (lowerUrl.contains('master.m3u8') ||
        lowerUrl.contains('playlist.m3u8') ||
        lowerUrl.contains('index.m3u8') ||
        lowerUrl.contains('manifest.m3u8')) {
      return 700;
    }

    // 5. 540P
    if (combined.contains('540p') ||
        combined.contains('540') ||
        combined.contains('microframe-ld') ||
        lowerUrl.contains('-ld.m3u8') ||
        lowerUrl.contains('540.m3u8')) {
      return 540;
    }

    // 6. 480P (SD)
    if (combined.contains('480p') ||
        combined.contains('480') ||
        lowerUrl.contains('480.m3u8') ||
        lowerUrl.contains('medium.m3u8')) {
      return 480;
    }

    // 7. 360P / 240P
    if (combined.contains('360p') ||
        combined.contains('360') ||
        combined.contains('240p') ||
        combined.contains('240') ||
        combined.contains('microframe-fd') ||
        lowerUrl.contains('-fd.m3u8') ||
        lowerUrl.contains('360.m3u8') ||
        lowerUrl.contains('low.m3u8')) {
      return 360;
    }

    return 300;
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

  /// Attempts to extract a direct video source (m3u8/mp4) and subtitle tracks from an episode page.
  Future<ExtractedStreamResult?> extractStreamResult(String pageUrl) async {
    if (!isSupported(pageUrl)) return null;
    if (_isScrapingGlobal) await _disposeHeadless();
    _isScrapingGlobal = true;

    final completer = Completer<ExtractedStreamResult?>();
    final sessionId = 'extract_${DateTime.now().millisecondsSinceEpoch}';
    _currentSessionId = sessionId;

    final Map<String, int> candidateUrls = {};
    final Set<ScrapedSubtitle> detectedSubtitles = {};

    void resolveBestCandidate({bool force = false}) {
      if (completer.isCompleted || candidateUrls.isEmpty) return;

      String? bestUrl;
      int maxScore = -1;
      candidateUrls.forEach((candidateUrl, score) {
        if (score > maxScore) {
          maxScore = score;
          bestUrl = candidateUrl;
        }
      });

      if (bestUrl != null && (maxScore >= 720 || force)) {
        debugPrint(
          'DynamicScraperService: Best candidate resolved (Score: $maxScore P): $bestUrl',
        );
        completer.complete(
          ExtractedStreamResult(
            videoUrl: bestUrl!,
            subtitles: detectedSubtitles.toList(),
          ),
        );
        _disposeHeadless();
      }
    }

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

          // Intercept subtitle tracks (.vtt, .srt, .ass)
          if ((urlStr.contains('.vtt') ||
                  urlStr.contains('.srt') ||
                  urlStr.contains('.ass') ||
                  urlStr.contains('/subtitle') ||
                  urlStr.contains('/subtitles')) &&
              !urlStr.contains('.m3u8') &&
              !urlStr.contains('.mp4')) {
            final label =
                (urlStr.contains('spa') ||
                        urlStr.contains('es') ||
                        urlStr.contains('lat'))
                    ? 'Español'
                    : 'Subtítulo Web';
            detectedSubtitles.add(
              ScrapedSubtitle(url: urlStr, label: label, language: 'es'),
            );
            debugPrint(
              'DynamicScraperService: Intercepted subtitle track: $urlStr',
            );
          }

          // Intercept m3u8/mp4 streams and score them
          if (urlStr.contains('.m3u8') ||
              urlStr.contains('.mp4') ||
              urlStr.contains('googlevideo.com')) {
            final score = _getQualityScore(urlStr);
            candidateUrls[urlStr] = score;
            debugPrint(
              'DynamicScraperService: Intercepted candidate stream (Score: $score P): $urlStr',
            );
            resolveBestCandidate();
          }
          return null;
        },
        onLoadStop: (controller, url) async {
          if (_currentSessionId != sessionId || _headlessWebView == null) {
            return;
          }

          try {
            // Multi-pass evaluation to catch async player hydration (600ms, 1400ms, 2200ms)
            for (int pass = 1; pass <= 3; pass++) {
              if (completer.isCompleted ||
                  _currentSessionId != sessionId ||
                  _headlessWebView == null) {
                break;
              }

              await Future.delayed(
                Duration(milliseconds: pass == 1 ? 600 : 800),
              );

              if (completer.isCompleted ||
                  _currentSessionId != sessionId ||
                  _headlessWebView == null) {
                break;
              }

              final dynamic evalResult = await controller.evaluateJavascript(
                source: """
                (function() {
                  try {
                    function getQualityScore(text, url) {
                      const lowerText = (text || '').toLowerCase();
                      const lowerUrl = (url || '').toLowerCase();
                      const combined = lowerText + ' ' + lowerUrl;

                      if (combined.includes('2160p') || combined.includes('2160') || combined.includes('4k') || combined.includes('uhd') || combined.includes('ultrahd')) return 2160;
                      if (combined.includes('1080p') || combined.includes('1080') || combined.includes('fhd') || combined.includes('fullhd') || combined.includes('full-hd') || combined.includes('microframe-hd') || lowerUrl.includes('1080.m3u8') || lowerUrl.includes('1080/') || lowerUrl.includes('1080_') || lowerUrl.includes('1080-')) return 1080;
                      if (combined.includes('720p') || combined.includes('720') || combined.includes('microframe-sd') || lowerUrl.includes('-sd.m3u8') || lowerUrl.includes('_sd.m3u8') || lowerUrl.includes('hd.m3u8') || lowerUrl.includes('-hd.m3u8') || lowerUrl.includes('_hd.m3u8') || lowerUrl.includes('720.m3u8') || lowerUrl.includes('720/') || lowerUrl.includes('720_') || lowerUrl.includes('720-') || lowerUrl.includes('high.m3u8') || lowerText === 'hd' || lowerText.includes('720')) return 720;
                      if (lowerUrl.includes('master.m3u8') || lowerUrl.includes('playlist.m3u8') || lowerUrl.includes('index.m3u8') || lowerUrl.includes('manifest.m3u8')) return 700;
                      if (combined.includes('540p') || combined.includes('540') || combined.includes('microframe-ld') || lowerUrl.includes('-ld.m3u8') || lowerUrl.includes('540.m3u8')) return 540;
                      if (combined.includes('480p') || combined.includes('480') || lowerUrl.includes('480.m3u8') || lowerUrl.includes('medium.m3u8')) return 480;
                      if (combined.includes('360p') || combined.includes('360') || combined.includes('240p') || combined.includes('240') || combined.includes('microframe-fd') || lowerUrl.includes('-fd.m3u8') || lowerUrl.includes('360.m3u8') || lowerUrl.includes('low.m3u8')) return 360;
                      return 300;
                    }

                    const results = [];
                    const subtitles = [];

                    // 0. Attempt to reveal settings/quality menu or click play/server buttons
                    try {
                      const gearBtns = document.querySelectorAll('button[class*="setting"], button[aria-label*="calidad"], button[aria-label*="setting"], .settings-btn, .vjs-menu-button, svg[class*="gear"], button:has(svg), .play-btn, .btn-play, .vjs-big-play-button');
                      gearBtns.forEach(b => { try { b.click(); } catch(e){} });
                    } catch(e) {}

                    // 1. Inspect quality buttons / links (e.g. data-url, data-src, href)
                    const elements = document.querySelectorAll('button[data-url], [data-url], [data-src], a[href*=".m3u8"], a[href*=".mp4"], button, li, div');
                    elements.forEach(el => {
                      const videoUrl = el.getAttribute('data-url') || el.getAttribute('data-src') || el.getAttribute('href') || el.dataset?.url || '';
                      const text = el.innerText || el.textContent || '';
                      if (videoUrl && (videoUrl.includes('.m3u8') || videoUrl.includes('.mp4') || videoUrl.startsWith('http'))) {
                        const score = getQualityScore(text, videoUrl);
                        results.push({ url: videoUrl, score: score });
                      }
                    });

                    // 2. Direct video tag
                    const video = document.querySelector('video');
                    if (video) {
                      if (video.src && video.src.startsWith('http')) {
                        results.push({ url: video.src, score: getQualityScore('', video.src) });
                      }
                      const source = video.querySelector('source');
                      if (source && source.src && source.src.startsWith('http')) {
                        results.push({ url: source.src, score: getQualityScore('', source.src) });
                      }
                    }

                    // 3. Common iframes
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
                      if (iframe && iframe.src && iframe.src.startsWith('http')) {
                        results.push({ url: iframe.src, score: getQualityScore('', iframe.src) });
                      }
                    }

                    // 4. Click quality button directly (e.g., 720P) if present in DOM
                    const qualityButtons = document.querySelectorAll('button, li, .quality-btn, .btn-quality, .resolution-btn');
                    let highestBtn = null;
                    let highestBtnScore = 0;
                    qualityButtons.forEach(btn => {
                      const text = btn.innerText || btn.textContent || '';
                      const score = getQualityScore(text, '');
                      if (score > highestBtnScore && score >= 720) {
                        highestBtnScore = score;
                        highestBtn = btn;
                      }
                    });
                    if (highestBtn) {
                      try { highestBtn.click(); } catch(e) {}
                    }

                    // 5. Harvest <track> and subtitle elements
                    try {
                      const tracks = document.querySelectorAll('track');
                      tracks.forEach(tr => {
                        const src = tr.getAttribute('src') || tr.src || '';
                        const label = tr.getAttribute('label') || tr.label || tr.getAttribute('srclang') || 'Español';
                        const lang = tr.getAttribute('srclang') || tr.srclang || 'es';
                        if (src && (src.includes('.vtt') || src.includes('.srt') || src.includes('.ass') || src.startsWith('http'))) {
                          subtitles.push({ url: src, label: label, lang: lang });
                        }
                      });

                      const subElements = document.querySelectorAll('a[href*=".vtt"], a[href*=".srt"], a[href*=".ass"], button[data-sub], [data-subtitle], [data-caption], [data-vtt], [data-srt]');
                      subElements.forEach(el => {
                        const subUrl = el.getAttribute('href') || el.getAttribute('data-sub') || el.getAttribute('data-subtitle') || el.getAttribute('data-caption') || el.getAttribute('data-vtt') || el.getAttribute('data-srt') || '';
                        const text = el.innerText || el.textContent || 'Subtítulo';
                        if (subUrl && (subUrl.includes('.vtt') || subUrl.includes('.srt') || subUrl.includes('.ass'))) {
                          subtitles.push({ url: subUrl, label: text.trim(), lang: 'es' });
                        }
                      });
                    } catch(e) {}

                    return { streams: results, subtitles: subtitles };
                  } catch (e) { return { streams: [], subtitles: [] }; }
                })()
              """,
              );

              if (_currentSessionId == sessionId && evalResult != null) {
                if (evalResult is Map) {
                  final streams = evalResult['streams'];
                  if (streams is List) {
                    for (var item in streams) {
                      if (item is Map) {
                        final itemMap = Map<String, dynamic>.from(item);
                        final u = itemMap['url']?.toString();
                        final s = itemMap['score'];
                        if (u != null && u.isNotEmpty && s is num) {
                          candidateUrls[u] = s.toInt();
                        }
                      }
                    }
                  }

                  final subs = evalResult['subtitles'];
                  if (subs is List) {
                    for (var item in subs) {
                      if (item is Map) {
                        final itemMap = Map<String, dynamic>.from(item);
                        final u = itemMap['url']?.toString();
                        final l = itemMap['label']?.toString() ?? 'Español';
                        final lang = itemMap['lang']?.toString() ?? 'es';
                        if (u != null && u.isNotEmpty) {
                          detectedSubtitles.add(
                            ScrapedSubtitle(url: u, label: l, language: lang),
                          );
                        }
                      }
                    }
                  }
                }
              }

              resolveBestCandidate();
            }

            resolveBestCandidate(force: true);

            if (!completer.isCompleted) {
              final pageTitle = await controller.getTitle() ?? "";
              if (pageTitle.contains("Attention Required") ||
                  pageTitle.contains("Cloudflare")) {
                await Future.delayed(const Duration(seconds: 4));
                resolveBestCandidate(force: true);
              }
            }
          } catch (e) {
            debugPrint('Source extraction error: $e');
            resolveBestCandidate(force: true);
          }
        },
      );

      await _headlessWebView?.run();

      final result = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          resolveBestCandidate(force: true);
          if (_currentSessionId == sessionId) _disposeHeadless();
          if (candidateUrls.isNotEmpty) {
            return ExtractedStreamResult(
              videoUrl: candidateUrls.keys.first,
              subtitles: detectedSubtitles.toList(),
            );
          }
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

  /// Backward-compatible method to extract direct video URL.
  Future<String?> extractVideoSource(String pageUrl) async {
    final result = await extractStreamResult(pageUrl);
    return result?.videoUrl;
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
