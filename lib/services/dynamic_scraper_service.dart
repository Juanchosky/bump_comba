import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'm3u_service.dart';

class ScrapedSubtitle {
  final String url;
  final String label;
  final String? language;

  ScrapedSubtitle({required this.url, required String label, this.language})
    : label = cleanLanguageLabel(label, language, url);

  static String cleanLanguageLabel(
    String rawLabel, [
    String? rawLang,
    String? url,
  ]) {
    final text = '${rawLabel.toLowerCase()} ${rawLang?.toLowerCase() ?? ''}';
    final u = (url ?? '').toLowerCase();

    // 1. Spanish
    if (text.contains('latino') ||
        text.contains('es-la') ||
        text.contains('es_la') ||
        u.contains('es-la') ||
        u.contains('es_la') ||
        u.contains('_lat.')) {
      return 'Español (Latino)';
    }
    if (text.contains('castellano') ||
        text.contains('es-es') ||
        text.contains('es_es') ||
        u.contains('es-es') ||
        u.contains('es_es')) {
      return 'Español (España)';
    }
    if (text.contains('spa') ||
        text.contains('spanish') ||
        text.contains('espanol') ||
        text.contains('español') ||
        text.contains('es') ||
        u.contains('_es.') ||
        u.contains('_es_') ||
        u.contains('/es/') ||
        u.contains('-es.') ||
        u.contains('lang=es')) {
      return 'Español';
    }

    // 2. English
    if (text.contains('eng') ||
        text.contains('english') ||
        text.contains('inglés') ||
        text.contains('ingles') ||
        text.contains('en') ||
        u.contains('_en.') ||
        u.contains('_en_') ||
        u.contains('/en/') ||
        u.contains('-en.') ||
        u.contains('lang=en')) {
      return 'Inglés';
    }

    // 3. Arabic
    if (text.contains('ara') ||
        text.contains('arabic') ||
        text.contains('عربي') ||
        text.contains('ar') ||
        u.contains('_ar.') ||
        u.contains('_ar_') ||
        u.contains('/ar/') ||
        u.contains('-ar.') ||
        u.contains('lang=ar')) {
      return 'Árabe';
    }

    // 4. French
    if (text.contains('fra') ||
        text.contains('french') ||
        text.contains('francés') ||
        text.contains('frances') ||
        text.contains('français') ||
        text.contains('fr') ||
        u.contains('_fr.') ||
        u.contains('_fr_') ||
        u.contains('/fr/') ||
        u.contains('-fr.') ||
        u.contains('lang=fr')) {
      return 'Francés';
    }

    // 5. Portuguese
    if (text.contains('por') ||
        text.contains('portuguese') ||
        text.contains('portugués') ||
        text.contains('portugues') ||
        text.contains('pt') ||
        u.contains('_pt.') ||
        u.contains('_pt_') ||
        u.contains('/pt/') ||
        u.contains('-pt.') ||
        u.contains('lang=pt')) {
      return 'Portugués';
    }

    // 6. German
    if (text.contains('ger') ||
        text.contains('german') ||
        text.contains('alemán') ||
        text.contains('aleman') ||
        text.contains('de') ||
        u.contains('_de.') ||
        u.contains('_de_') ||
        u.contains('/de/') ||
        u.contains('-de.') ||
        u.contains('lang=de')) {
      return 'Alemán';
    }

    // 7. Italian
    if (text.contains('ita') ||
        text.contains('italian') ||
        text.contains('italiano') ||
        text.contains('it') ||
        u.contains('_it.') ||
        u.contains('_it_') ||
        u.contains('/it/') ||
        u.contains('-it.') ||
        u.contains('lang=it')) {
      return 'Italiano';
    }

    // 8. Japanese
    if (text.contains('jpn') ||
        text.contains('japanese') ||
        text.contains('japonés') ||
        text.contains('japones') ||
        text.contains('ja') ||
        u.contains('_ja.') ||
        u.contains('_ja_') ||
        u.contains('/ja/') ||
        u.contains('-ja.') ||
        u.contains('lang=ja')) {
      return 'Japonés';
    }

    // 9. Korean
    if (text.contains('kor') ||
        text.contains('korean') ||
        text.contains('coreano') ||
        text.contains('ko') ||
        u.contains('_ko.') ||
        u.contains('_ko_') ||
        u.contains('/ko/') ||
        u.contains('-ko.') ||
        u.contains('lang=ko')) {
      return 'Coreano';
    }

    // 10. Russian
    if (text.contains('rus') ||
        text.contains('russian') ||
        text.contains('ruso') ||
        text.contains('ru') ||
        u.contains('_ru.') ||
        u.contains('_ru_') ||
        u.contains('/ru/') ||
        u.contains('-ru.') ||
        u.contains('lang=ru')) {
      return 'Ruso';
    }

    // 11. Turkish
    if (text.contains('tur') ||
        text.contains('turkish') ||
        text.contains('turco') ||
        text.contains('türkçe') ||
        text.contains('tr') ||
        u.contains('_tr.') ||
        u.contains('_tr_') ||
        u.contains('/tr/') ||
        u.contains('-tr.') ||
        u.contains('lang=tr')) {
      return 'Turco';
    }

    // 12. Chinese
    if (text.contains('chi') ||
        text.contains('chinese') ||
        text.contains('chino') ||
        text.contains('zho') ||
        text.contains('zh') ||
        u.contains('_zh.') ||
        u.contains('_zh_') ||
        u.contains('/zh/') ||
        u.contains('-zh.') ||
        u.contains('lang=zh')) {
      return 'Chino';
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

    // 1. Archivos directos de vídeo NUNCA deben tratarse como páginas dinámicas
    if (lowUrl.endsWith('.m3u8') ||
        lowUrl.endsWith('.mp4') ||
        lowUrl.endsWith('.mkv') ||
        lowUrl.endsWith('.ts') ||
        lowUrl.endsWith('.avi') ||
        lowUrl.endsWith('.mov') ||
        lowUrl.endsWith('.flv') ||
        lowUrl.endsWith('.webm') ||
        lowUrl.contains('.m3u8?') ||
        lowUrl.contains('.mp4?') ||
        lowUrl.contains('.mkv?') ||
        lowUrl.contains('.ts?') ||
        lowUrl.contains('.avi?')) {
      return false;
    }

    // 2. Streams de Xtream Codes o IPTV por puerto/ruta directa NUNCA son páginas
    //    dinámicas.
    //
    //    EL PATRON TIENE QUE SER EL DE XTREAM ENTERO, NO UN PEDAZO.
    //
    //    Antes se comprobaba `/movie/` + el regex `/[^/]+/[^/]+/\d+`, y ese
    //    `\d+` NO exige que el segmento sea numerico: le basta una barra
    //    seguida de UN digito. En
    //
    //      flixlat.com/es/detail/movie/9YyHEfKN2wTk9jnrAH5fa-The-Last-House
    //
    //    encontraba `/detail` + `/movie` + `/9` y daba la pagina por "video
    //    directo": no pasaba por el extractor, se le entregaba el HTML a MPV y
    //    salia un 403. Y como dependia de si el id de la pagina empezaba por
    //    numero o por letra, unos titulos de la BD funcionaban y otros no —
    //    sin patron aparente.
    //
    //    Una URL de Xtream es `/movie|series|live/USUARIO/CLAVE/12345.ext`:
    //    dos segmentos y luego uno TODO numerico, al final. Eso es lo que se
    //    exige ahora, anclado, para que ninguna ruta de pagina la imite por
    //    casualidad.
    if (RegExp(r':\d+/(?:movie|series|live)/').hasMatch(lowUrl) ||
        RegExp(
          r'/(?:movie|series|live)/[^/]+/[^/]+/\d+(?:\.[a-z0-9]+)?(?:\?|$)',
        ).hasMatch(lowUrl)) {
      return false;
    }

    // 2.bis LA FORMA DE LA PAGINA, NO EL DOMINIO
    //
    // Todo lo que sigue es una lista de dominios escrita a mano, y el
    // proveedor los CAMBIA: cuevana.life, dramasfree.com, 123pelicula.com...
    // Cada dominio nuevo entra sin estar en la lista, `isSupported` dice que
    // no, y la pagina HTML se le entrega tal cual a MPV — que responde con un
    // 403 y parece que el servidor esta caido. Eso fue lo que paso con
    // `ver.123pelicula.com`.
    //
    // Todas esas paginas tienen la MISMA forma: `/detail/<tipo>/<id>-<slug>`.
    // Reconocerla cubre tambien el proximo dominio, sin tener que enterarse
    // del cambio a base de fallos.
    //
    // Va DESPUES de las dos exclusiones de arriba a proposito: los archivos
    // directos y las rutas de Xtream ya se han descartado, asi que aqui solo
    // llega algo que se parece a una pagina.
    if (RegExp(r'^https?://').hasMatch(lowUrl) && lowUrl.contains('/detail/')) {
      return true;
    }

    // 3. 123flms / 123movies / flmsfree / 123flmsfree / subtitles
    if (lowUrl.contains('123flms') ||
        lowUrl.contains('123movies') ||
        lowUrl.contains('123pelicula') ||
        lowUrl.contains('flmsfree') ||
        lowUrl.contains('subtitles.')) {
      return true;
    }

    // 4. Playspelis variants
    if (lowUrl.contains('playspelis.com') ||
        lowUrl.contains('playspelis.org') ||
        lowUrl.contains('playspelis.net') ||
        lowUrl.contains('playspelis.tv') ||
        lowUrl.contains('playspelis')) {
      return true;
    }

    // 5. Cuevana variants
    if (lowUrl.contains('cuevana4br.com') ||
        lowUrl.contains('cuevana') ||
        lowUrl.contains('cuevana3') ||
        lowUrl.contains('cuevana4') ||
        lowUrl.contains('cuevana8')) {
      return true;
    }

    // 6. FlixLat variants
    if (lowUrl.contains('flixlat.com') ||
        lowUrl.contains('flixlat.org') ||
        lowUrl.contains('flixlat.am') ||
        lowUrl.contains('flixlat.lat') ||
        lowUrl.contains('flixlat.cc') ||
        lowUrl.contains('flixlat.to') ||
        lowUrl.contains('flixlatam.com')) {
      return true;
    }

    // 7. DramasFree variants
    if (lowUrl.contains('dramasfree.com') ||
        lowUrl.contains('dramasfree.cc') ||
        lowUrl.contains('dramasfree.org') ||
        lowUrl.contains('dramasfree.io')) {
      return true;
    }

    // 8. PeliculaPlay / VidSrc / Embed / SuperEmbed
    if (lowUrl.contains('peliculaplay') ||
        lowUrl.contains('vidsrc') ||
        lowUrl.contains('superembed') ||
        lowUrl.contains('2embed') ||
        lowUrl.contains('/embed/') ||
        lowUrl.contains('embed.')) {
      return true;
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
  /// Lo ya resuelto, por pagina, con su fecha de caducidad.
  ///
  /// ── POR QUE HACE FALTA ────────────────────────────────────────────────
  ///
  /// Resolver una pagina cuesta ~10 segundos: se abre un WebView —un Chromium
  /// entero— y se carga el sitio del proveedor con sus fuentes, su JavaScript
  /// y su analitica, solo para pescar la URL del video.
  ///
  /// Y se estaba pagando VARIAS VECES por el mismo titulo: una en la vista
  /// previa de la ficha y otra al abrir el reproductor, con diez segundos de
  /// diferencia y para obtener exactamente lo mismo. De ahi que en el
  /// televisor "tarde tanto" algo que en el telefono va suelto.
  final Map<String, ({DateTime hasta, ExtractedStreamResult resultado})>
  _resueltas = {};

  /// Hasta cuando vale lo resuelto.
  ///
  /// Estas URLs vienen firmadas y traen su propia caducidad en `exp=<unix>`.
  /// Se respeta esa, con un minuto de margen, porque servir una URL caducada
  /// es peor que no tener cache: falla al abrir y encima parece un fallo del
  /// servidor.
  ///
  /// Si no trae `exp`, diez minutos: suficiente para el caso que importa —el
  /// mismo titulo dos veces seguidas— y corto para que nada se quede rancio.
  DateTime _caducidadDe(String url) {
    final m = RegExp(r'exp=(\d{10})').firstMatch(url);
    if (m != null) {
      final seg = int.tryParse(m.group(1)!);
      if (seg != null) {
        return DateTime.fromMillisecondsSinceEpoch(
          seg * 1000,
        ).subtract(const Duration(minutes: 1));
      }
    }
    return DateTime.now().add(const Duration(minutes: 10));
  }

  Future<ExtractedStreamResult?> extractStreamResult(String pageUrl) async {
    if (!isSupported(pageUrl)) return null;

    final guardada = _resueltas[pageUrl];
    if (guardada != null) {
      if (DateTime.now().isBefore(guardada.hasta)) {
        debugPrint('DynamicScraperService: ya resuelta, sin abrir WebView');
        return guardada.resultado;
      }
      _resueltas.remove(pageUrl);
    }
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

      if (bestUrl != null &&
          (maxScore >= 480 || force || candidateUrls.isNotEmpty)) {
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
          blockNetworkImage: true,
          loadsImagesAutomatically: false,
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

          // Block heavy media/images/fonts that waste memory in headless mode
          final lower = urlStr.toLowerCase();
          if (lower.endsWith('.png') ||
              lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.webp') ||
              lower.endsWith('.gif') ||
              lower.endsWith('.svg') ||
              lower.endsWith('.woff') ||
              lower.endsWith('.woff2') ||
              lower.endsWith('.ttf') ||
              lower.contains('/fonts/')) {
            return WebResourceResponse(
              contentType: 'text/plain',
              data: Uint8List(0),
            );
          }

          // Intercept subtitle tracks (.vtt, .srt, .ass, /subtitle, /subtitles, /caption, /captions)
          if ((urlStr.contains('.vtt') ||
                  urlStr.contains('.srt') ||
                  urlStr.contains('.ass') ||
                  urlStr.contains('/subtitle') ||
                  urlStr.contains('/subtitles') ||
                  urlStr.contains('/caption') ||
                  urlStr.contains('/captions')) &&
              !urlStr.contains('.m3u8') &&
              !urlStr.contains('.mp4') &&
              !urlStr.contains('.html') &&
              !urlStr.contains('.js') &&
              !urlStr.contains('.css')) {
            detectedSubtitles.add(
              ScrapedSubtitle(url: urlStr, label: '', language: null),
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
            // ── PASADAS PARA CAZAR AL REPRODUCTOR MIENTRAS SE MONTA ─────
            //
            // Eran 3 pasadas (600 + 800 + 800 ms) y despues se aceptaba el
            // mejor candidato que hubiera, FUERA CUAL FUERA su calidad. Ahi
            // estaba el "la maxima es 720p y no veo que lo sea": estas paginas
            // publican primero la variante ligera (`-ld`, 960x520, puntua 540)
            // y la buena llega un pelo mas tarde. Con la ventana justa, unas
            // veces se pillaba la buena y otras se cerraba con la mala — de
            // ahi que fuera aleatorio.
            //
            // Ahora hay hasta 6 pasadas, pero NO alargan la espera cuando no
            // hace falta: `resolveBestCandidate()` cierra en cuanto aparece
            // una de 720 o mas, y el bucle sale al ver el completer cerrado.
            // Solo se sigue mirando cuando lo unico que hay es una variante
            // pobre, que es justo el caso que queremos mejorar.
            //
            // El tope de 15s de la extraccion sigue mandando por encima.
            for (int pass = 1; pass <= 6; pass++) {
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
                source: r"""
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
                        // Exclude subtitle files from stream results
                        if (!videoUrl.includes('.srt') && !videoUrl.includes('.vtt') && !videoUrl.includes('.ass') && !videoUrl.includes('/subtitle') && !videoUrl.includes('/subtitles')) {
                          const score = getQualityScore(text, videoUrl);
                          results.push({ url: videoUrl, score: score });
                        }
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

                    // 5. Universal subtitle harvester (<track>, buttons with data-url/data-language/data-text, links, and script regex)
                    try {
                      // a) HTML <track> elements
                      const tracks = document.querySelectorAll('track');
                      tracks.forEach(tr => {
                        const src = tr.getAttribute('src') || tr.src || '';
                        const label = tr.getAttribute('label') || tr.label || tr.getAttribute('srclang') || '';
                        const lang = tr.getAttribute('srclang') || tr.srclang || '';
                        if (src && (src.includes('.vtt') || src.includes('.srt') || src.includes('.ass') || src.includes('subtitle') || src.startsWith('http'))) {
                          subtitles.push({ url: src, label: label, lang: lang });
                        }
                      });

                      // b) Subtitle buttons, options, and data-url attributes (e.g. 123flmsfree, cuevana, flixlat, etc.)
                      const subSelectors = 'button[data-url], [data-url*="subtitle"], [data-url*="subtitles"], [data-url*=".srt"], [data-url*=".vtt"], ' +
                                           'a[href*=".vtt"], a[href*=".srt"], a[href*=".ass"], a[href*="subtitle"], ' +
                                           'button[data-sub], [data-subtitle], [data-caption], [data-vtt], [data-srt], [data-language], ' +
                                           'option[value*=".vtt"], option[value*=".srt"], option[data-url]';
                      const subElements = document.querySelectorAll(subSelectors);
                      subElements.forEach(el => {
                        const subUrl = el.getAttribute('data-url') || el.getAttribute('href') || el.getAttribute('data-sub') || el.getAttribute('data-subtitle') || el.getAttribute('data-src') || el.getAttribute('value') || el.getAttribute('data-caption') || el.getAttribute('data-vtt') || el.getAttribute('data-srt') || '';
                        const lang = el.getAttribute('data-language') || el.getAttribute('data-lang') || el.getAttribute('lang') || '';
                        const textLabel = el.getAttribute('data-text') || el.getAttribute('data-label') || el.innerText || el.textContent || '';
                        
                        if (subUrl && (subUrl.includes('.vtt') || subUrl.includes('.srt') || subUrl.includes('.ass') || subUrl.includes('subtitle') || subUrl.includes('subtitles') || subUrl.startsWith('http'))) {
                          if (!subUrl.includes('.m3u8') && !subUrl.includes('.mp4')) {
                            subtitles.push({ url: subUrl, label: textLabel.trim(), lang: lang.trim() });
                          }
                        }
                      });

                      // c) Embedded script tags scanning for .srt and .vtt subtitle URLs
                      const scripts = document.querySelectorAll('script');
                      scripts.forEach(s => {
                        const code = s.innerText || s.textContent || '';
                        if (code.includes('.srt') || code.includes('.vtt') || code.includes('subtitles') || code.includes('captions')) {
                          const srtRegex = /(https?:\/\/[^\s"'<>]+\.(?:srt|vtt|ass)(?:\?[^\s"'<>]*)?)/gi;
                          let match;
                          while ((match = srtRegex.exec(code)) !== null) {
                            const subUrl = match[1];
                            if (subUrl && !subUrl.includes('.m3u8') && !subUrl.includes('.mp4')) {
                              subtitles.push({ url: subUrl, label: '', lang: '' });
                            }
                          }
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
      // A la cache, para que el siguiente que pida esta misma pagina no
      // vuelva a abrir un WebView. Solo si trajo video: guardar un fallo
      // seria condenar el titulo durante todo el plazo.
      if (result != null && result.videoUrl.isNotEmpty) {
        _resueltas[pageUrl] = (
          hasta: _caducidadDe(result.videoUrl),
          resultado: result,
        );
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
