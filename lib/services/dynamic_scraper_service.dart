import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'm3u_service.dart';
import '../utils/cabeceras_stream.dart';

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
  final List<String> alternativeUrls;
  final Map<String, String> headers;

  ExtractedStreamResult({
    required this.videoUrl,
    this.subtitles = const [],
    this.alternativeUrls = const [],
    this.headers = const {},
  });
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
  /// Devuelve true si la URL pertenece a un servicio de descarga directa
  /// (file hoster) que no soporta Range requests ni streaming real.
  /// Estas URLs no deben usarse como fuente de reproducción.
  static bool _esUrlFileHoster(String url) {
    final low = url.toLowerCase();
    return low.contains('multiup.io') ||
        low.contains('1fichier.com') ||
        low.contains('rapidgator') ||
        low.contains('nitroflare') ||
        low.contains('katfile') ||
        low.contains('mega.nz') ||
        low.contains('mediafire.com') ||
        low.contains('uptobox');
  }

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

    // 9. Peelink variants
    if (lowUrl.contains('peelink') ||
        lowUrl.contains('peelink2') ||
        lowUrl.contains('peelinkp')) {
      return true;
    }

    // 10. VOE variants
    if (lowUrl.contains('voe.sx') ||
        lowUrl.contains('johnfullwonder') ||
        lowUrl.contains('voe-network') ||
        lowUrl.contains('voe.') ||
        lowUrl.contains('peliculasrey.me')) {
      return true;
    }

    // 11. Uqload variants
    if (lowUrl.contains('uqload')) {
      return true;
    }

    // 12. Gnula variants
    if (lowUrl.contains('gnulahd') ||
        lowUrl.contains('gnula.nu') ||
        lowUrl.contains('gnula.cc') ||
        lowUrl.contains('gnula.se') ||
        lowUrl.contains('gnula.life') ||
        lowUrl.contains('gnula.club') ||
        lowUrl.contains('gnula.')) {
      return true;
    }

    // 13. OK.ru variants
    if (lowUrl.contains('ok.ru') ||
        lowUrl.contains('odnoklassniki')) {
      return true;
    }

    // 15. Pelisflix variants
    if (lowUrl.contains('pelisflix1.tv') ||
        lowUrl.contains('pelisflix2.tv') ||
        lowUrl.contains('pelisflix.tv') ||
        lowUrl.contains('pelisflix.me') ||
        lowUrl.contains('pelisflix.cc') ||
        lowUrl.contains('pelisflix.lat') ||
        lowUrl.contains('pelisflix')) {
      return true;
    }

    // 14. SaveFiles variants
    if (lowUrl.contains('savefiles')) {
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
      return 1080;
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

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';

  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  /// Abre un `.m3u8` y devuelve la altura de la MEJOR variante que declara.
  /// `null` si no es una lista maestra o no se pudo leer.
  ///
  /// POR QUE NO BASTA CON MIRAR LA URL
  /// `_getQualityScore` puntua por el TEXTO de la direccion, que es una
  /// adivinanza: un `master.m3u8` no dice por fuera si lleva 1080p o 480p
  /// dentro, asi que se le daba 700 — POR DEBAJO de un `hd.m3u8` fijo, que
  /// puntua 720. Con las dos sobre la mesa se elegia la de 720 y se tiraba la
  /// maestra, que es justo donde suele estar la variante buena. De ahi el
  /// "en la base de datos solo hay hasta 720": nadie habia mirado dentro.
  ///
  /// Una lista maestra ocupa menos de 2 KB y esta al principio del archivo,
  /// asi que se corta la descarga a 32 KB en vez de tragarse la lista de
  /// segmentos de una pelicula entera.
  static Future<int?> _alturaMaximaDe(String url, String referer) async {
    final cliente = http.Client();
    try {
      final peticion =
          http.Request('GET', Uri.parse(url))
            ..headers.addAll({
              'User-Agent': _ua,
              'Referer': referer,
              'Accept': '*/*',
            });
      final respuesta = await cliente
          .send(peticion)
          .timeout(const Duration(seconds: 2));
      if (respuesta.statusCode != 200) return null;

      final buffer = StringBuffer();
      await for (final trozo in respuesta.stream.transform(
        const Utf8Decoder(allowMalformed: true),
      )) {
        buffer.write(trozo);
        if (buffer.length > 32768) break;
      }

      final cuerpo = buffer.toString();
      if (!cuerpo.contains('#EXT-X-STREAM-INF')) return null;

      var mejor = 0;
      for (final m in RegExp(
        r'RESOLUTION=\d+x(\d+)',
        caseSensitive: false,
      ).allMatches(cuerpo)) {
        final alto = int.tryParse(m.group(1) ?? '') ?? 0;
        if (alto > mejor) mejor = alto;
      }
      return mejor > 0 ? mejor : null;
    } catch (_) {
      return null;
    } finally {
      cliente.close();
    }
  }

  /// Extracts metadata from a supported URL.
  Future<ScrapedMetadata?> scrapeMetadata(String url) async {
    if (!isSupported(url)) return null;

    if (url.toLowerCase().contains('pelisflix')) {
      final fastMeta = await _scrapePelisflixMetadata(url);
      if (fastMeta != null) {
        return fastMeta;
      }
    }

    if (url.toLowerCase().contains('peelink')) {
      final fastMeta = await _scrapePeelinkMetadata(url);
      if (fastMeta != null) {
        return fastMeta;
      }
    }

    if (url.toLowerCase().contains('gnula')) {
      final fastMeta = await _scrapeGnulaMetadata(url);
      if (fastMeta != null) {
        return fastMeta;
      }
    }

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
                  const epElements = document.querySelectorAll('a[href*="/episode/"], a[href*="/capitulo"], a[href*="/episodio"], a[href*="/ep-"], .episode-item, .list-episodes a, [class*="episode"] a, [class*="capitulo"] a');
                  
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
    // El token `?s=` de nupload caduca en minutos (a los ~30 ya daba 404).
    if (url.contains('ibra.lat')) {
      return DateTime.now().add(const Duration(minutes: 3));
    }
    return DateTime.now().add(const Duration(minutes: 10));
  }

  void invalidateCache([String? pageUrl]) {
    if (pageUrl != null) {
      _resueltas.remove(pageUrl);
    } else {
      _resueltas.clear();
    }
  }

  /// Precargas HTTP en curso, por página, para que pulsar "Reproducir" a
  /// mitad de una precarga la espere en vez de repetir el trabajo.
  final Map<String, Future<ExtractedStreamResult?>> _precargasEnCurso = {};

  /// Resuelve [pageUrl] en segundo plano ANTES de que el usuario pulse
  /// reproducir (p. ej. el episodio de "Continuar" en la ficha de una serie).
  ///
  /// Deliberadamente limitado para no empeorar nada:
  ///  · solo pelisflix, cuya vía rápida es HTTP puro;
  ///  · NUNCA abre el WebView: hay uno solo global y una precarga que lo
  ///    ocupara le tiraría el trabajo al reproductor;
  ///  · si falla, no deja rastro y el reproductor sigue su camino normal.
  void precargar(String pageUrl) {
    if (!pageUrl.toLowerCase().contains('pelisflix')) return;
    final guardada = _resueltas[pageUrl];
    if (guardada != null && DateTime.now().isBefore(guardada.hasta)) return;
    if (_precargasEnCurso.containsKey(pageUrl)) return;

    final futuro = () async {
      try {
        final r = await _tryFastDirectExtraction(
          pageUrl,
        ).timeout(const Duration(seconds: 20));
        if (r != null && r.videoUrl.isNotEmpty) {
          _resueltas[pageUrl] = (hasta: _caducidadDe(r.videoUrl), resultado: r);
          debugPrint('DynamicScraperService: precargada -> ${r.videoUrl}');
        }
        return r;
      } catch (_) {
        return null;
      } finally {
        _precargasEnCurso.remove(pageUrl);
      }
    }();
    _precargasEnCurso[pageUrl] = futuro;
  }

  Future<ExtractedStreamResult?> extractStreamResult(String pageUrl) async {
    if (!isSupported(pageUrl)) return null;

    final enCurso = _precargasEnCurso[pageUrl];
    var viaRapidaYaFallo = false;
    if (enCurso != null) {
      debugPrint('DynamicScraperService: esperando la precarga en curso');
      final r = await enCurso;
      if (r != null && r.videoUrl.isNotEmpty) return r;
      // Falló justo esa vía rápida: repetirla solo sumaría espera.
      viaRapidaYaFallo = true;
    }

    final guardada = _resueltas[pageUrl];
    if (guardada != null) {
      if (DateTime.now().isBefore(guardada.hasta) &&
          !_esUrlFileHoster(guardada.resultado.videoUrl)) {
        debugPrint('DynamicScraperService: ya resuelta, sin abrir WebView');
        return guardada.resultado;
      }
      _resueltas.remove(pageUrl);
    }

    // ── VÍA RÁPIDA NATIVA (HTTP directo sin WebView) ───────────────────
    // Para Peelink y servidores directos como VOE. Resuelve en ~500ms y
    // con 0 MB de consumo de RAM (vital para TV Boxes con 1 GB de RAM).
    final fastResult =
        viaRapidaYaFallo ? null : await _tryFastDirectExtraction(pageUrl);
    if (fastResult != null && fastResult.videoUrl.isNotEmpty) {
      debugPrint(
        'DynamicScraperService: resuelto por vía rápida nativa -> ${fastResult.videoUrl}',
      );
      _resueltas[pageUrl] = (
        hasta: _caducidadDe(fastResult.videoUrl),
        resultado: fastResult,
      );
      return fastResult;
    }

    if (_isScrapingGlobal) await _disposeHeadless();
    _isScrapingGlobal = true;

    final completer = Completer<ExtractedStreamResult?>();
    final sessionId = 'extract_${DateTime.now().millisecondsSinceEpoch}';
    _currentSessionId = sessionId;

    final Map<String, int> candidateUrls = {};
    final Set<ScrapedSubtitle> detectedSubtitles = {};

    // Altura REAL leida dentro de cada lista maestra, y las que ya se miraron
    // (aunque no dieran nada, para no volver a pedirlas en bucle).
    final Map<String, int> alturaReal = {};
    final Set<String> yaSondeadas = {};
    bool sondeando = false;

    int puntosDe(String url) => alturaReal[url] ?? candidateUrls[url] ?? 0;

    void resolveBestCandidate({bool force = false}) {
      if (completer.isCompleted || candidateUrls.isEmpty) return;
      if (sondeando && !force) return;

      String? bestUrl;
      int maxScore = -1;
      for (final candidateUrl in candidateUrls.keys) {
        final score = puntosDe(candidateUrl);
        if (score > maxScore) {
          maxScore = score;
          bestUrl = candidateUrl;
        }
      }
      if (bestUrl == null) return;

      // Un `.m3u8` sin abrir puede ser una maestra con 1080p dentro. Se mira
      // ANTES de conformarse con lo que diga la URL. El `force` del tope de
      // tiempo salta este paso: ahi ya no hay margen para sondear nada.
      final sinSondear =
          candidateUrls.keys
              .where(
                (u) =>
                    u.toLowerCase().contains('.m3u8') && !yaSondeadas.contains(u),
              )
              .take(4)
              .toList();

      if (sinSondear.isNotEmpty && !force) {
        sondeando = true;
        yaSondeadas.addAll(sinSondear);
        unawaited(() async {
          try {
            await Future.wait(
              sinSondear.map((u) async {
                final alto = await _alturaMaximaDe(u, pageUrl);
                if (alto != null) {
                  alturaReal[u] = alto;
                  debugPrint(
                    'DynamicScraperService: lista maestra con ${alto}p -> $u',
                  );
                }
              }),
            ).timeout(const Duration(seconds: 3));
          } catch (_) {
            // Un sondeo que falla no bloquea nada: se sigue con la puntuacion
            // adivinada por la URL, que es lo que habia antes.
          }
          sondeando = false;
          resolveBestCandidate();
        }());
        return;
      }

      if (maxScore >= 1080 || force) {
        debugPrint(
          'DynamicScraperService: Best candidate resolved (Score: $maxScore P): $bestUrl',
        );
        completer.complete(
          ExtractedStreamResult(
            videoUrl: bestUrl,
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
          useShouldOverrideUrlLoading: true,
          mediaPlaybackRequiresUserGesture: false,
          offscreenPreRaster: false,
          transparentBackground: true,
          blockNetworkImage: true,
          loadsImagesAutomatically: false,
          hardwareAcceleration:
              false, // CRITICAL: Release Surface buffers for the Video Player
        ),
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          final navUrl = navigationAction.request.url?.toString() ?? '';
          // Cancelar el redirect anti-bot de pelisflix a su homepage.
          // shouldInterceptRequest no puede cancelar navegación principal;
          // solo shouldOverrideUrlLoading con CANCEL puede hacerlo.
          if (navigationAction.isForMainFrame == true &&
              pageUrl.contains('pelisflix1') &&
              (navUrl == 'https://pelisflix1.tv/' ||
                  navUrl == 'http://pelisflix1.tv/') &&
              pageUrl != 'https://pelisflix1.tv/' &&
              pageUrl != 'http://pelisflix1.tv/') {
            debugPrint('DynamicScraperService: CANCEL navegación anti-bot pelisflix -> $navUrl');
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
        shouldInterceptRequest: (controller, request) async {
          if (_currentSessionId != sessionId || _headlessWebView == null) {
            return null;
          }

          final urlStr = request.url.toString();

          // CLOUDFLARE BYPASS: Never block cdn-cgi or cloudflare scripts
          if (urlStr.contains('cdn-cgi') || urlStr.contains('cloudflare')) {
            return null;
          }

          // JWPLAYER PATCH: r2cr6BE6.js define window.jwplayer como un loader
          // que encola llamadas setup(). nupload.top llama getState/getDuration
          // etc. *antes* de que el player esté listo, lo que lanza TypeError y
          // mata la ejecución, impidiendo que setup() sea llamado. Descargamos
          // r2cr6BE6.js, le añadimos stubs para esos métodos y lo devolvemos
          // parcheado. Así getState() no crashea y setup() llega al loader.
          if (urlStr.contains('content.jwplatform.com/libraries/') &&
              urlStr.endsWith('.js')) {
            try {
              final jwResp = await http.get(
                Uri.parse(urlStr),
                headers: {
                  'User-Agent': _ua,
                  'Referer': 'https://nupload.top/',
                },
              ).timeout(const Duration(seconds: 6));
              if (jwResp.statusCode == 200) {
                const patch = r"""
;(function(){
  var _jw=window.jwplayer;
  if(typeof _jw!='function')return;
  window.jwplayer=function(id){
    var inst=_jw.apply(this,arguments);
    if(inst){
      function s(n,v){if(typeof inst[n]!='function')inst[n]=function(){return v;};}
      s('getState','idle');s('getDuration',0);s('getPosition',0);
      s('getVolume',100);s('getMute',false);s('getFullscreen',false);
      s('getPlaylistIndex',0);s('getPlaylist',[]);
      s('on',inst);s('off',inst);s('once',inst);
    }
    return inst;
  };
  try{for(var k in _jw){if(Object.prototype.hasOwnProperty.call(_jw,k))window.jwplayer[k]=_jw[k];}}catch(e){}
  try{Object.setPrototypeOf(window.jwplayer,Object.getPrototypeOf(_jw));}catch(e){}
})();
""";
                debugPrint('DynamicScraperService: Parcheando JWPlayer loader -> $urlStr');
                return WebResourceResponse(
                  contentType: 'application/javascript',
                  statusCode: 200,
                  data: Uint8List.fromList(
                    utf8.encode(jwResp.body + patch),
                  ),
                );
              }
            } catch (_) {}
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

          // Detectar iframes de hosts embed conocidos y extraer el stream de ellos.
          // pelisflix1.tv (y sitios similares) muestran el video en un iframe de
          // un host de tercero ANTES de que el anti-bot redirija al homepage; si
          // no pescamos esa URL aqui, el JS de onLoadStop corre en la pagina
          // equivocada y no encuentra nada.
          if (request.isForMainFrame != true) {
            final embedHosts = [
              'nupload.top', 'streamwish', 'filelions', 'wishfast',
              'streamvid', 'moviesapi', 'voe.sx', 'ibelin', 'doodstream',
              'mixdrop', 'supervideo', 'vudeo', 'waaw', 'vidmoly',
              'streamlare', 'streamtape', 'vidoza', 'uqload', 'upstream',
              'ok.ru', 'odnoklassniki',
            ];
            // Comparar solo contra el host (no los query params) para evitar
            // falsos positivos como ?domain=nupload.top en URLs de anuncios.
            final embedHost = Uri.tryParse(urlStr)?.host ?? '';
            if (embedHosts.any((h) => embedHost.contains(h)) &&
                !urlStr.contains('.js') && !urlStr.contains('.css') &&
                !urlStr.contains('.png') && !urlStr.contains('.jpg') &&
                !urlStr.contains('.gif') && !urlStr.contains('.webp')) {
              debugPrint('DynamicScraperService: Detectado iframe embed -> $urlStr');
              unawaited(() async {
                try {
                  final embedResult = await _extractDirectStreamFromEmbed(urlStr)
                      .timeout(const Duration(seconds: 10));
                  if (embedResult != null && embedResult.videoUrl.isNotEmpty &&
                      _currentSessionId == sessionId) {
                    final score = _getQualityScore(embedResult.videoUrl);
                    candidateUrls[embedResult.videoUrl] = score;
                    debugPrint('DynamicScraperService: Stream via iframe embed (Score: ${score}P): ${embedResult.videoUrl}');
                    resolveBestCandidate();
                  }
                } catch (_) {}
              }());
            }
          }

          // Interceptar sv3.ibra.lat/?s= (JWPlayer de nupload.top pide este URL
          // para obtener el m3u8; la URL redirige al .m3u8 real).
          if (urlStr.contains('sv3.ibra.lat') && urlStr.contains('?s=')) {
            debugPrint('DynamicScraperService: Interceptando sv3.ibra.lat -> $urlStr');
            unawaited(() async {
              try {
                final svRes = await http.get(
                  Uri.parse(urlStr),
                  headers: {
                    'User-Agent': _ua,
                    'Referer': 'https://nupload.top/',
                    'Accept': '*/*',
                  },
                ).timeout(const Duration(seconds: 8));
                if (svRes.statusCode == 200 && _currentSessionId == sessionId) {
                  final body = svRes.body;
                  if (body.startsWith('#EXTM3U') || body.contains('#EXT-X-')) {
                    // La URL ?s= misma sirve como stream (el player sigue el redirect)
                    candidateUrls[urlStr] = 1080;
                    debugPrint('DynamicScraperService: Stream via sv3.ibra.lat (Score: 1080P): $urlStr');
                    resolveBestCandidate();
                  }
                }
              } catch (_) {}
            }());
          }

          // Interceptar respuesta de api.kindor.io (API de JWPlayer usada por nupload.top)
          if (urlStr.contains('api.kindor.io') ||
              urlStr.contains('cdn.jwplayer.com/v2/media/')) {
            debugPrint('DynamicScraperService: Interceptando JWPlayer API -> $urlStr');
            unawaited(() async {
              try {
                final kindorRes = await http.get(
                  Uri.parse(urlStr),
                  headers: {
                    'User-Agent': _ua,
                    'Referer': 'https://nupload.top/',
                    'Accept': 'application/json,*/*',
                  },
                ).timeout(const Duration(seconds: 6));
                if (kindorRes.statusCode == 200 &&
                    _currentSessionId == sessionId) {
                  final kindorBody = kindorRes.body;
                  final m3u8Match = RegExp(
                    r'''["\']file["\']\s*:\s*["\'](https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)["\'']''',
                    caseSensitive: false,
                  ).firstMatch(kindorBody);
                  if (m3u8Match != null) {
                    final streamUrl = m3u8Match.group(1)!;
                    final score = _getQualityScore(streamUrl);
                    candidateUrls[streamUrl] = score;
                    debugPrint(
                      'DynamicScraperService: Stream via JWPlayer API (Score: ${score}P): $streamUrl',
                    );
                    resolveBestCandidate();
                  }
                }
              } catch (_) {}
            }());
          }

          // Intercept m3u8/mp4 streams and score them
          if (urlStr.contains('.m3u8') ||
              urlStr.contains('.mp4') ||
              urlStr.contains('googlevideo.com')) {
            // Saltar file-hosters: no soportan Range requests ni streaming real.
            if (_esUrlFileHoster(urlStr)) {
              debugPrint(
                'DynamicScraperService: Ignorando file-hoster en WebView: $urlStr',
              );
            } else {
              final score = _getQualityScore(urlStr);
              candidateUrls[urlStr] = score;
              debugPrint(
                'DynamicScraperService: Intercepted candidate stream (Score: $score P): $urlStr',
              );
              resolveBestCandidate();
            }
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
                      if (lowerUrl.includes('master.m3u8') || lowerUrl.includes('playlist.m3u8') || lowerUrl.includes('index.m3u8') || lowerUrl.includes('manifest.m3u8')) return 1080;
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
                      if (videoUrl && (videoUrl.includes('.m3u8') || videoUrl.includes('.mp4'))) {
                        // Exclude subtitle and image files from stream results
                        const lv = videoUrl.toLowerCase();
                        if (!lv.includes('.srt') && !lv.includes('.vtt') && !lv.includes('.ass') &&
                            !lv.includes('/subtitle') && !lv.includes('/subtitles') &&
                            !lv.includes('.jpg') && !lv.includes('.jpeg') && !lv.includes('.png') &&
                            !lv.includes('.gif') && !lv.includes('.webp') && !lv.includes('.avif') &&
                            !lv.includes('/poster') && !lv.includes('/thumb') && !lv.includes('/image')) {
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

                    // 4. Click quality button directly (e.g., 1080P, 720P) if present in DOM
                    const qualityButtons = document.querySelectorAll('button, li, a, .quality-btn, .btn-quality, .resolution-btn, [data-quality], [data-res]');
                    let highestBtn = null;
                    let highestBtnScore = 0;
                    qualityButtons.forEach(btn => {
                      const text = (btn.innerText || btn.textContent || btn.getAttribute('data-quality') || btn.getAttribute('data-res') || '').trim();
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
                        if (u != null && u.isNotEmpty && s is num &&
                            !_esUrlFileHoster(u)) {
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

      // nupload.top necesita ~20s: JWPlayer tarda ~8s en cargar librerías
      // antes de hacer el request a sv3.ibra.lat que queremos interceptar.
      final scraperTimeoutSecs = pageUrl.contains('pelisflix') ||
              pageUrl.contains('nupload') ||
              pageUrl.contains('sv3.ibra')
          ? 30
          : 15;
      final result = await completer.future.timeout(
        Duration(seconds: scraperTimeoutSecs),
        onTimeout: () {
          resolveBestCandidate(force: true);
          if (_currentSessionId == sessionId) _disposeHeadless();
          if (candidateUrls.isEmpty) return null;
          // El mejor, no el primero que entro: `candidateUrls` es un mapa sin
          // orden de calidad, asi que `.first` devolvia una variante al azar
          // —normalmente la ligera, que es la que suelen publicar antes.
          final mejor = candidateUrls.keys.reduce(
            (a, b) => puntosDe(b) > puntosDe(a) ? b : a,
          );
          return ExtractedStreamResult(
            videoUrl: mejor,
            subtitles: detectedSubtitles.toList(),
          );
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

  // ── VÍA RÁPIDA NATIVA: PEELINK & VOE ────────────────────────────────────────

  Future<ExtractedStreamResult?> _tryFastDirectExtraction(
    String pageUrl,
  ) async {
    final low = pageUrl.toLowerCase();
    if (low.contains('peelink')) {
      return await _extractPeelinkStream(pageUrl);
    }
    if (low.contains('pelisflix')) {
      return await _extractPelisflixStream(pageUrl);
    }
    if (low.contains('gnula')) {
      return await _extractGnulaStream(pageUrl);
    }
    if (low.contains('ok.ru') || low.contains('odnoklassniki')) {
      return await _extractOkRuStream(pageUrl);
    }
    if (low.contains('voe.sx') ||
        low.contains('johnfullwonder') ||
        low.contains('voe-network') ||
        low.contains('voe.') ||
        low.contains('peliculasrey.me') ||
        low.contains('auroravid')) {
      return await _extractVoeStream(pageUrl);
    }
    if (low.contains('savefiles')) {
      return await _extractSaveFilesStream(pageUrl);
    }
    if (low.contains('ibelin') ||
        low.contains('divxplayer') ||
        low.contains('metaverseid') ||
        low.contains('akpdm') ||
        low.contains('cvary')) {
      return await _extractIbelinStream(pageUrl);
    }
    return null;
  }

  Future<ExtractedStreamResult?> _extractDirectStreamFromEmbed(
    String embedUrl,
  ) async {
    final low = embedUrl.toLowerCase();
    if (low.contains('nupload.top') || low.contains('nupload.')) {
      return await _extractNuploadStream(embedUrl);
    }
    if (low.contains('ok.ru') || low.contains('odnoklassniki')) {
      return await _extractOkRuStream(embedUrl);
    }
    if (low.contains('voe.sx') ||
        low.contains('johnfullwonder') ||
        low.contains('voe-network') ||
        low.contains('voe.') ||
        low.contains('peliculasrey.me') ||
        low.contains('auroravid')) {
      return await _extractVoeStream(embedUrl);
    }
    if (low.contains('ibelin') ||
        low.contains('divxplayer') ||
        low.contains('metaverseid') ||
        low.contains('akpdm') ||
        low.contains('cvary')) {
      return await _extractIbelinStream(embedUrl);
    }

    // Intento genérico para otros servidores embebidos
    try {
      final client = http.Client();
      final res = await client.get(
        Uri.parse(embedUrl),
        headers: {
          'User-Agent': _ua,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 4));
      client.close();
      if (res.statusCode == 200) {
        final m3u8Match = RegExp(
          r'''['"](https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)['"]''',
          caseSensitive: false,
        ).firstMatch(res.body);
        if (m3u8Match != null) {
          return ExtractedStreamResult(videoUrl: m3u8Match.group(1)!);
        }
        final mp4Match = RegExp(
          r'''['"](https?://[^\s"'<>]+\.mp4[^\s"'<>]*)['"]''',
          caseSensitive: false,
        ).firstMatch(res.body);
        if (mp4Match != null) {
          return ExtractedStreamResult(videoUrl: mp4Match.group(1)!);
        }
      }
    } catch (_) {}

    return null;
  }

  Future<ExtractedStreamResult?> _extractIbelinStream(String ibelinUrl) async {
    try {
      final client = http.Client();
      final res = await client.get(
        Uri.parse(ibelinUrl),
        headers: {
          'User-Agent': _ua,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
          'Referer': 'https://www.peelink2.com/',
        },
      ).timeout(const Duration(seconds: 5));
      client.close();

      if (res.statusCode != 200) return null;
      final html = res.body;

      final m3u8Match = RegExp(
        r'''(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)''',
        caseSensitive: false,
      ).firstMatch(html);
      if (m3u8Match != null) {
        debugPrint(
          'DynamicScraperService: Ibelin stream resuelto -> ${m3u8Match.group(1)}',
        );
        return ExtractedStreamResult(videoUrl: m3u8Match.group(1)!);
      }

      final mp4Match = RegExp(
        r'''(https?://[^\s"'<>]+\.mp4[^\s"'<>]*)''',
        caseSensitive: false,
      ).firstMatch(html);
      if (mp4Match != null) {
        return ExtractedStreamResult(videoUrl: mp4Match.group(1)!);
      }
    } catch (e) {
      debugPrint('DynamicScraperService: error extractIbelinStream: $e');
    }
    return null;
  }

  Future<ExtractedStreamResult?> _extractPeelinkStream(
    String peelinkUrl,
  ) async {
    try {
      final client = http.Client();
      final res = await client.get(
        Uri.parse(peelinkUrl),
        headers: {
          'User-Agent': _ua,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        },
      ).timeout(const Duration(seconds: 7));
      client.close();

      if (res.statusCode != 200) return null;
      final html = res.body;

      // 1. Extraer opciones de px_repros: px_repros['latino_0'] = '...'
      final reproRegex = RegExp(
        r'''px_repros\['([^']+)'\]\s*=\s*'([^']+)' '''.trim(),
      );
      final matches = reproRegex.allMatches(html).toList();

      final List<String> candidateServerUrls = [];
      final latino = <String>[];
      final espanol = <String>[];
      final sub = <String>[];
      final otros = <String>[];

      for (final m in matches) {
        final key = m.group(1)?.toLowerCase() ?? '';
        final b64 = m.group(2) ?? '';
        try {
          final decodedHtml = utf8.decode(
            base64.decode(b64),
            allowMalformed: true,
          );
          final srcMatch = RegExp(
            r'''src=['"]([^'"]+)['"]''',
          ).firstMatch(decodedHtml);
          if (srcMatch != null) {
            final serverUrl = srcMatch.group(1)!;
            if (key.contains('latino')) {
              latino.add(serverUrl);
            } else if (key.contains('espanol') || key.contains('castellano')) {
              espanol.add(serverUrl);
            } else if (key.contains('sub')) {
              sub.add(serverUrl);
            } else {
              otros.add(serverUrl);
            }
          }
        } catch (_) {}
      }

      candidateServerUrls.addAll(latino);
      candidateServerUrls.addAll(espanol);
      candidateServerUrls.addAll(sub);
      candidateServerUrls.addAll(otros);

      // Si no encontramos en px_repros, buscar en video[N]
      if (candidateServerUrls.isEmpty) {
        final videoRegex = RegExp(r'''video\[\d+\]\s*=\s*['"]([^'"]+)['"]''');
        for (final vm in videoRegex.allMatches(html)) {
          final vVal = vm.group(1) ?? '';
          final srcMatch = RegExp(
            r'''src=['"]([^'"]+)['"]''',
          ).firstMatch(vVal);
          if (srcMatch != null) {
            candidateServerUrls.add(srcMatch.group(1)!);
          }
        }
      }

      // Priorizar candidatos con hosts de extracción rápida (VOE, etc.)
      bool isFastCandidate(String u) {
        final l = u.toLowerCase();
        return l.contains('voe') ||
            l.contains('ibelin') ||
            l.contains('peliculasrey.me') ||
            l.contains('/red2.php/');
      }

      candidateServerUrls.sort((a, b) {
        final aFast = isFastCandidate(a) ? 0 : 1;
        final bFast = isFastCandidate(b) ? 0 : 1;
        return aFast.compareTo(bFast);
      });

      debugPrint(
        'DynamicScraperService (Peelink): ${candidateServerUrls.length} servidores encontrados',
      );

      final List<ExtractedStreamResult> extractedResults = [];

      for (final serverUrl in candidateServerUrls) {
        var target = serverUrl;

        // Desempaquetar redirecciones base64 de peliculasrey si aplica
        if (target.contains('peliculasrey.me') || target.contains('/red2.php/')) {
          final b64Part = target.split('/red2.php/').last;
          try {
            var dec = utf8.decode(base64.decode(b64Part), allowMalformed: true);
            if (dec.startsWith('aHR0')) {
              dec = utf8.decode(base64.decode(dec), allowMalformed: true);
            }
            if (dec.startsWith('http')) {
              target = dec;
            }
          } catch (_) {}
        }

        // Si ya tenemos al menos 1 resultado rápido y este target no parece de un host rápido,
        // no esperamos por hosts lentos para evitar latencia innecesaria en TV.
        if (extractedResults.isNotEmpty) {
          final lowTarget = target.toLowerCase();
          final isLikelyFastHost = lowTarget.contains('voe') ||
              lowTarget.contains('ibelin') ||
              lowTarget.contains('streamwish') ||
              lowTarget.contains('filelions');
          if (!isLikelyFastHost) continue;
        }

        final result = await _extractDirectStreamFromEmbed(target);
        if (result != null && result.videoUrl.isNotEmpty) {
          extractedResults.add(result);
          // Si ya tenemos al menos 2 servidores alternativos listos, resolvemos inmediatamente
          if (extractedResults.length >= 2) break;
        }
      }

      if (extractedResults.isNotEmpty) {
        final primary = extractedResults.first;
        final altUrls = extractedResults
            .skip(1)
            .map((r) => r.videoUrl)
            .where((u) => u != primary.videoUrl)
            .toList();

        final Set<ScrapedSubtitle> allSubs = {};
        for (final r in extractedResults) {
          allSubs.addAll(r.subtitles);
        }

        return ExtractedStreamResult(
          videoUrl: primary.videoUrl,
          subtitles: allSubs.toList(),
          alternativeUrls: altUrls,
        );
      }
    } catch (e) {
      debugPrint('DynamicScraperService: error extractPeelinkStream: $e');
    }
    return null;
  }

  Future<ExtractedStreamResult?> _extractVoeStream(String voeUrl) async {
    try {
      var currentUrl = voeUrl;

      // Desempaquetar redirección de peliculasrey si llegó aquí directo
      if (currentUrl.contains('peliculasrey.me') ||
          currentUrl.contains('/red2.php/')) {
        final b64Part = currentUrl.split('/red2.php/').last;
        try {
          var dec = utf8.decode(base64.decode(b64Part), allowMalformed: true);
          if (dec.startsWith('aHR0')) {
            dec = utf8.decode(base64.decode(dec), allowMalformed: true);
          }
          if (dec.startsWith('http')) {
            currentUrl = dec;
          }
        } catch (_) {}
      }

      final client = http.Client();
      http.Response res = await client.get(
        Uri.parse(currentUrl),
        headers: {
          'User-Agent': _ua,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        },
      ).timeout(const Duration(seconds: 7));

      // Redirección JavaScript de VOE a dominio de entrega
      if (res.body.contains("window.location.href = '") ||
          res.body.contains('window.location.href = "')) {
        final redirectMatch = RegExp(
          r'''window\.location\.href\s*=\s*['"]([^'"]+)['"]''',
        ).firstMatch(res.body);
        if (redirectMatch != null) {
          final redirectUrl = redirectMatch.group(1)!;
          currentUrl = redirectUrl;
          res = await client.get(
            Uri.parse(currentUrl),
            headers: {
              'User-Agent': _ua,
              'Referer': voeUrl,
            },
          ).timeout(const Duration(seconds: 7));
        }
      }
      client.close();

      final html = res.body;

      // Patrón de carga útil cifrada: <script ... type="application/json" ...>["..."]</script>
      RegExpMatch? jsonTagMatch = RegExp(
        r'''<script[^>]*type=['"]application/json['"][^>]*>\s*\[\s*['"]([^'"]+)['"]\s*\]''',
        caseSensitive: false,
      ).firstMatch(html);

      jsonTagMatch ??= RegExp(
        r'''type=['"]application/json['"][^>]*>\s*\[\s*['"]([^'"]+)['"]\s*\]''',
        caseSensitive: false,
      ).firstMatch(html);

      jsonTagMatch ??= RegExp(
        r'''\[\s*['"]([A-Za-z0-9+/=~@%?*!#&@\$\^\-]{50,})['"]\s*\]''',
      ).firstMatch(html);

      if (jsonTagMatch != null) {
        final payload = jsonTagMatch.group(1)!;
        final decryptedJson = _decryptVoePayload(payload);
        if (decryptedJson != null) {
          final Map<String, dynamic> data = jsonDecode(decryptedJson);
          final rawUrl =
              data['source']?.toString() ??
              data['direct_access_url']?.toString();
          if (rawUrl != null && rawUrl.isNotEmpty) {
            String streamUrl = rawUrl;
            // Resolver master playlist HLS directamente para arranque y seeks ultra rápidos
            if (streamUrl.contains('master.m3u8')) {
              try {
                final masterClient = http.Client();
                final masterRes = await masterClient.get(
                  Uri.parse(streamUrl),
                  headers: {'User-Agent': _ua},
                ).timeout(const Duration(seconds: 2));
                masterClient.close();
                if (masterRes.statusCode == 200) {
                  final lines = masterRes.body.split('\n');
                  for (final l in lines) {
                    final trimmed = l.trim();
                    if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
                      final resolvedUri = Uri.parse(streamUrl).resolve(trimmed);
                      streamUrl = resolvedUri.toString();
                      debugPrint(
                        'DynamicScraperService: Master playlist pre-resuelta a -> $streamUrl',
                      );
                      break;
                    }
                  }
                }
              } catch (_) {}
            }

            final List<ScrapedSubtitle> subs = [];
            if (data['captions'] is List) {
              for (var c in data['captions']) {
                if (c is Map && c['file'] != null) {
                  subs.add(
                    ScrapedSubtitle(
                      url: c['file'].toString(),
                      label: c['label']?.toString() ?? 'Español',
                      language: c['language']?.toString(),
                    ),
                  );
                }
              }
            }
            return ExtractedStreamResult(videoUrl: streamUrl, subtitles: subs);
          }
        }
      }

      // Respaldo secundario: búsqueda directa de URL de streaming en JS
      final hlsMatch = RegExp(
        r'''['"](?:hls|source)['"]\s*:\s*['"]([^'"]+\.m3u8[^'"]*)['"]''',
      ).firstMatch(html);
      if (hlsMatch != null) {
        return ExtractedStreamResult(videoUrl: hlsMatch.group(1)!);
      }
      final mp4Match = RegExp(
        r'''['"](?:file|direct_access_url)['"]\s*:\s*['"]([^'"]+\.mp4[^'"]*)['"]''',
      ).firstMatch(html);
      if (mp4Match != null) {
        return ExtractedStreamResult(videoUrl: mp4Match.group(1)!);
      }
    } catch (e) {
      debugPrint('DynamicScraperService: error extractVoeStream: $e');
    }
    return null;
  }

  String? _decryptVoePayload(String raw) {
    try {
      // 1. ROT13 sobre letras mayúsculas y minúsculas
      final rot13Buffer = StringBuffer();
      for (int i = 0; i < raw.length; i++) {
        final code = raw.codeUnitAt(i);
        if (code >= 65 && code <= 90) {
          rot13Buffer.writeCharCode((code - 65 + 13) % 26 + 65);
        } else if (code >= 97 && code <= 122) {
          rot13Buffer.writeCharCode((code - 97 + 13) % 26 + 97);
        } else {
          rot13Buffer.writeCharCode(code);
        }
      }
      var stripped = rot13Buffer.toString();

      // 2. Eliminar cadenas de ruido agregadas por el servidor VOE
      const noise = ['@\$', '^^', '~@', '%?', '*~', '!!', '#&'];
      for (final p in noise) {
        stripped = stripped.replaceAll(p, '');
      }

      // 3. Primer decode Base64
      final padLen = (4 - (stripped.length % 4)) % 4;
      final padded1 = stripped + ('=' * padLen);
      final bytes1 = base64.decode(padded1);
      final decoded1 = utf8.decode(bytes1, allowMalformed: true);

      // 4. Desplazamiento de caracteres (-3)
      final shiftedBuffer = StringBuffer();
      for (int i = 0; i < decoded1.length; i++) {
        shiftedBuffer.writeCharCode(decoded1.codeUnitAt(i) - 3);
      }
      final shifted = shiftedBuffer.toString();

      // 5. Invertir la cadena
      final reversed = shifted.split('').reversed.join();

      // 6. Segundo decode Base64 para obtener el JSON final
      final padLen2 = (4 - (reversed.length % 4)) % 4;
      final padded2 = reversed + ('=' * padLen2);
      final bytes2 = base64.decode(padded2);
      final finalJson = utf8.decode(bytes2, allowMalformed: true);

      return finalJson;
    } catch (e) {
      debugPrint('DynamicScraperService: error decrypting VOE payload: $e');
      return null;
    }
  }

  // ── PELISFLIX ────────────────────────────────────────────────────────────────

  Future<ScrapedMetadata?> _scrapePelisflixMetadata(String url) async {
    try {
      final client = http.Client();
      final res = await client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _desktopUa,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
          'Referer': 'https://pelisflix1.tv/',
        },
      ).timeout(const Duration(seconds: 10));
      client.close();

      if (res.statusCode != 200) return null;
      final html = res.body;

      // Título desde og:title o <h1>
      String title = '';
      final ogTitle = RegExp(
        r'''<meta\s+property=['"]og:title['"]\s+content=['"]([^'"]+)['"]''',
      ).firstMatch(html);
      if (ogTitle != null) {
        title = ogTitle.group(1)!.trim();
      } else {
        final h1 = RegExp(r'<h1[^>]*>(.*?)</h1>', dotAll: true).firstMatch(html);
        if (h1 != null) {
          title = h1.group(1)!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        }
      }

      // Poster
      String? thumb;
      final ogImg = RegExp(
        r'''<meta\s+property=['"]og:image['"]\s+content=['"]([^'"]+)['"]''',
      ).firstMatch(html);
      if (ogImg != null) thumb = ogImg.group(1)!.trim();

      // Descripción
      String? desc;
      final ogDesc = RegExp(
        r'''<meta\s+(?:property=['"]og:description['"]|name=['"]description['"])\s+content=['"]([^'"]+)['"]''',
      ).firstMatch(html);
      if (ogDesc != null) desc = ogDesc.group(1)!.trim();

      // Episodios: busca enlaces que contengan /capitulo/, /episodio/, /ep-
      final List<M3UItem> episodes = [];
      final seenUrls = <String>{};
      final epRegex = RegExp(
        r'''<a[^>]+href=['"](https?://[^'"]*(?:/capitulo[^'"]*|/episodio[^'"]*|/ep-\d+[^'"]*|/temporada[^'"]*capitulo[^'"]*))['"]\s*[^>]*>(.*?)</a>''',
        caseSensitive: false,
        dotAll: true,
      );
      for (final m in epRegex.allMatches(html)) {
        final epUrl = m.group(1)!;
        if (!seenUrls.add(epUrl)) continue;
        final epTitle = m.group(2)!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        episodes.add(M3UItem(
          name: epTitle.isNotEmpty ? epTitle : 'Episodio ${episodes.length + 1}',
          url: epUrl,
          logo: thumb,
          category: 'Episodios',
          isLive: false,
          isDynamic: true,
        ));
      }

      if (title.isNotEmpty) {
        return ScrapedMetadata(
          title: title,
          thumbnailUrl: thumb,
          description: desc,
          episodes: episodes,
        );
      }
    } catch (e) {
      debugPrint('DynamicScraperService: error _scrapePelisflixMetadata: $e');
    }
    return null;
  }

  Future<ExtractedStreamResult?> _extractPelisflixStream(String pageUrl) async {
    try {
      final client = http.Client();
      final res = await client.get(
        Uri.parse(pageUrl),
        headers: {
          'User-Agent': _desktopUa,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
          'Referer': '${Uri.parse(pageUrl).origin}/',
        },
      ).timeout(const Duration(seconds: 10));
      client.close();

      if (res.statusCode != 200) return null;
      final html = res.body;

      // 1. Buscar iframe con src de servidor conocido
      final iframeRegex = RegExp(
        r'''<iframe[^>]+src=['"](https?://[^'"]+)['"]''',
        caseSensitive: false,
      );
      final iframes = <String>[];

      // pelisflix ya no pone <iframe> en el HTML: cada servidor va en
      // data-url="<base64>" y el JS lo monta al hacer clic. Vienen en orden
      // LATINO, CASTELLANO, SUBTITULADO, así que el orden del documento ya
      // prioriza Latino. Leerlos aquí evita el WebView (anuncios + redirect).
      for (final m in RegExp(r'data-url="([A-Za-z0-9+/=]{16,})"').allMatches(html)) {
        try {
          final u = utf8.decode(base64.decode(m.group(1)!));
          if (u.startsWith('http') && !iframes.contains(u)) iframes.add(u);
        } catch (_) {}
      }
      iframes.addAll(iframeRegex.allMatches(html).map((m) => m.group(1)!));

      // Ordenar: primero los hosts con extractor rápido
      // (List.sort no es estable: se desempata por posición para no mezclar
      // idiomas).
      final pos = {for (var i = 0; i < iframes.length; i++) iframes[i]: i};
      iframes.sort((a, b) {
        int score(String u) {
          final l = u.toLowerCase();
          if (l.contains('nupload') || l.contains('voe') ||
              l.contains('ibelin') || l.contains('savefiles')) {
            return 0;
          }
          return 1;
        }
        final c = score(a).compareTo(score(b));
        return c != 0 ? c : pos[a]!.compareTo(pos[b]!);
      });

      for (final iframeSrc in iframes) {
        final low = iframeSrc.toLowerCase();
        if (low.contains('doubleclick') || low.contains('google-analytics') ||
            low.contains('googlesyndication') || low.contains('ads')) {
          continue;
        }

        final result = await _extractDirectStreamFromEmbed(iframeSrc);
        if (result != null && result.videoUrl.isNotEmpty) {
          debugPrint('DynamicScraperService (Pelisflix): stream via iframe -> ${result.videoUrl}');
          return result;
        }
      }

      // 2. Buscar m3u8/mp4 directo en el HTML
      final m3u8Match = RegExp(
        r'''['"](https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)['"]''',
        caseSensitive: false,
      ).firstMatch(html);
      if (m3u8Match != null) {
        return ExtractedStreamResult(videoUrl: m3u8Match.group(1)!);
      }

      final mp4Match = RegExp(
        r'''['"](https?://[^\s"'<>]+\.mp4[^\s"'<>]*)['"]''',
        caseSensitive: false,
      ).firstMatch(html);
      if (mp4Match != null) {
        return ExtractedStreamResult(videoUrl: mp4Match.group(1)!);
      }
    } catch (e) {
      debugPrint('DynamicScraperService: error _extractPelisflixStream: $e');
    }
    // Si la extracción HTTP falla, el WebView lo reintentará
    return null;
  }

  Future<ScrapedMetadata?> _scrapePeelinkMetadata(String url) async {
    try {
      final client = http.Client();
      final res = await client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _ua,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        },
      ).timeout(const Duration(seconds: 8));
      client.close();

      if (res.statusCode != 200) return null;
      final html = res.body;

      // 1. Título
      String title = '';
      final h1Match = RegExp(
        r'''<h1[^>]*class=['"][^'"]*entry-title[^'"]*['"][^>]*>(.*?)</h1>''',
        dotAll: true,
      ).firstMatch(html);
      if (h1Match != null) {
        title = h1Match.group(1)!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      } else {
        final ogTitle = RegExp(
          r'''<meta\s+property=['"]og:title['"]\s+content=['"]([^'"]+)['"]''',
        ).firstMatch(html);
        if (ogTitle != null) {
          title = ogTitle.group(1)!.replaceAll(' - PEELINK', '').trim();
        }
      }

      // 2. Poster / Imagen
      String? thumb;
      final ogImg = RegExp(
        r'''<meta\s+property=['"]og:image['"]\s+content=['"]([^'"]+)['"]''',
      ).firstMatch(html);
      if (ogImg != null) {
        thumb = ogImg.group(1)!.trim();
      }

      // 3. Descripción
      String? desc;
      final ogDesc = RegExp(
        r'''<meta\s+(?:property=['"]og:description['"]|name=['"]description['"])\s+content=['"]([^'"]+)['"]''',
      ).firstMatch(html);
      if (ogDesc != null) {
        desc = ogDesc.group(1)!.trim();
      }

      // 4. Episodios si es serie
      final List<M3UItem> episodes = [];
      final epRegex = RegExp(
        r'''<a[^>]+href=['"](https?://[^'"]*peelink[^'"]*(?:cap\d+|capitulo|episodio)[^'"]*)['"][^>]*>(.*?)</a>''',
        caseSensitive: false,
      );
      final seenEpUrls = <String>{};
      for (final m in epRegex.allMatches(html)) {
        final epUrl = m.group(1)!;
        if (!seenEpUrls.add(epUrl)) continue;
        final epTitleRaw =
            m.group(2)!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        final epTitle =
            epTitleRaw.isNotEmpty
                ? epTitleRaw
                : 'Episodio ${episodes.length + 1}';
        episodes.add(
          M3UItem(
            name: epTitle,
            url: epUrl,
            logo: thumb,
            category: 'Episodios',
            isLive: false,
            isDynamic: true,
          ),
        );
      }

      if (title.isNotEmpty) {
        return ScrapedMetadata(
          title: title,
          thumbnailUrl: thumb,
          description: desc,
          episodes: episodes,
        );
      }
    } catch (e) {
      debugPrint('DynamicScraperService: error _scrapePeelinkMetadata: $e');
    }
    return null;
  }

  /// Extrae el stream de nupload.top/watch/HASH
  /// nupload usa JWPlayer; el setup está en el HTML como jwplayer().setup({...})
  /// o se obtiene de la API de JWPlayer cdn.jwplayer.com/v2/media/ID
  /// Decodifica el array base64 de nupload.top para obtener la URL base del stream.
  /// El HTML tiene: var arr = ["base64_1","base64_2",...];
  /// Cada elemento: atob(value) tiene dígitos incrustados; extraerlos, restar 1323034, convertir a char.
  String? _decodeNuploadArray(String arrayName, String body, int offset) {
    final arrRegex = RegExp(
      'var\\s+$arrayName\\s*=\\s*(\\[[^\\]]+\\])',
      caseSensitive: false,
    );
    final arrMatch = arrRegex.firstMatch(body);
    if (arrMatch == null) return null;
    final arrStr = arrMatch.group(1)!;
    final items = RegExp(r'"([^"]+)"').allMatches(arrStr).map((m) => m.group(1)!).toList();
    if (items.isEmpty) return null;
    final result = StringBuffer();
    for (final item in items) {
      try {
        final decoded = String.fromCharCodes(base64.decode(item));
        final digits = decoded.replaceAll(RegExp(r'\D'), '');
        if (digits.isEmpty) continue;
        final code = int.parse(digits) - offset;
        if (code > 0 && code < 0x10FFFF) result.writeCharCode(code);
      } catch (_) {}
    }
    final s = result.toString();
    return s.isEmpty ? null : s;
  }

  Future<ExtractedStreamResult?> _extractNuploadStream(
    String embedUrl,
  ) async {
    try {
      final res = await http.get(
        Uri.parse(embedUrl),
        headers: {
          'User-Agent': _ua,
          'Referer': 'https://pelisflix1.tv/',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        },
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) return null;
      final body = res.body;

      // Técnica principal: el HTML tiene un array de strings base64 que codifican
      // la URL base del stream, y una variable sesz con el token de sesión.
      // file = decodeArray() + "?s=" + sesz
      // Ese URL al cargarlo devuelve el .m3u8 real (sigue redirect).
      //
      // Buscar el nombre del array (puede variar): "var <nombre> = ["..." ]"
      final arrayNameMatch = RegExp(
        r'var\s+([A-Za-z_]\w*)\s*=\s*\["[A-Za-z0-9+/=]+",',
      ).firstMatch(body);

      final seszMatch = RegExp(r'''sesz\s*=\s*"([^"]{20,})"''').firstMatch(body);

      if (arrayNameMatch != null && seszMatch != null) {
        final arrName = arrayNameMatch.group(1)!;
        final sesz = seszMatch.group(1)!;

        // Buscar el offset numérico usado en la resta: "parseInt(atob(value).replace(...)) - OFFSET"
        // El replace(/\D/g,'') mete paréntesis extra, así que se toma lo que
        // haya hasta el primer "- NUM" tras parseInt(atob(.
        final offsetMatch = RegExp(r'parseInt\(atob\(.{0,80}?\)\s*-\s*(\d+)').firstMatch(body);
        final decodedOffset = offsetMatch != null ? int.tryParse(offsetMatch.group(1)!) ?? 1323034 : 1323034;

        final baseUrl = _decodeNuploadArray(arrName, body, decodedOffset);
        if (baseUrl != null && baseUrl.startsWith('http')) {
          final streamApiUrl = '$baseUrl?s=$sesz';
          debugPrint('NuploadExtractor: GET $streamApiUrl');
          try {
            final client = http.Client();
            final streamRes = await client.get(
              Uri.parse(streamApiUrl),
              headers: {
                'User-Agent': _ua,
                'Referer': 'https://nupload.top/',
                'Accept': '*/*',
              },
            ).timeout(const Duration(seconds: 6));
            client.close();
            // La respuesta es el .m3u8 directo O redirige a él
            final finalUrl = streamRes.request?.url.toString() ?? streamApiUrl;
            if (streamRes.statusCode == 200) {
              final bodyM = streamRes.body;
              // Si el servidor no se fía, redirige a una lista-cebo que sí
              // termina en .m3u8 pero dice "File deleted by DMCA request".
              // Solo vale un #EXTM3U de verdad.
              if (bodyM.contains('#EXTM3U')) {
                final m3u8url = finalUrl.contains('.m3u8') ? finalUrl : streamApiUrl;
                debugPrint('NuploadExtractor: stream -> $m3u8url');
                return ExtractedStreamResult(
                  videoUrl: m3u8url,
                  headers: cabecerasObligatorias(m3u8url),
                );
              }
              debugPrint('NuploadExtractor: el servidor devolvió una lista cebo');
              // A veces la respuesta es JSON con "file"
              final jsonFileMatch = RegExp(
                r'"file"\s*:\s*"(https?://[^"]+\.m3u8[^"]*)"',
              ).firstMatch(bodyM);
              if (jsonFileMatch != null) {
                return ExtractedStreamResult(videoUrl: jsonFileMatch.group(1)!);
              }
            }
          } catch (e) {
            debugPrint('NuploadExtractor stream fetch error: $e');
          }
        }
      }

      // Fallback: buscar file directo en jwplayer().setup({file:"..."})
      final fileMatch = RegExp(
        r'''file["\']\s*:\s*["\'](https?://[^\s"'<>]+\.m3u8[^"']*)["\'"]''',
        caseSensitive: false,
      ).firstMatch(body);
      if (fileMatch != null) {
        debugPrint('NuploadExtractor: stream directo -> ${fileMatch.group(1)}');
        return ExtractedStreamResult(videoUrl: fileMatch.group(1)!);
      }

      debugPrint('NuploadExtractor: no se encontró stream en $embedUrl');
    } catch (e) {
      debugPrint('NuploadExtractor error: $e');
    }
    return null;
  }

  Future<ExtractedStreamResult?> _extractOkRuStream(String okUrl) async {
    try {
      var embedUrl = okUrl;
      if (embedUrl.contains('/video/') && !embedUrl.contains('/videoembed/')) {
        embedUrl = embedUrl.replaceFirst('/video/', '/videoembed/');
      }

      final client = http.Client();
      final res = await client.get(
        Uri.parse(embedUrl),
        headers: {
          'User-Agent': _desktopUa,
          'Referer': 'https://ok.ru/',
        },
      ).timeout(const Duration(seconds: 8));
      client.close();

      if (res.statusCode != 200) return null;
      final html = res.body;

      String? hlsUrl;
      final List<String> altUrls = [];

      // 1. Parsear data-options
      final optMatch = RegExp(r'''data-options=(["'])(.*?)\1''', dotAll: true).firstMatch(html);
      if (optMatch != null) {
        try {
          var rawOpt = optMatch.group(2) ?? '';
          rawOpt = rawOpt.replaceAll('&quot;', '"').replaceAll('&amp;', '&');
          final optJson = json.decode(rawOpt) as Map<String, dynamic>;
          final flashvars = optJson['flashvars'] as Map<String, dynamic>? ?? {};
          dynamic metadata = flashvars['metadata'];
          if (metadata is String) {
            metadata = json.decode(metadata);
          }
          if (metadata is Map<String, dynamic>) {
            final ondHls = metadata['ondemandHls'] as String?;
            if (ondHls != null && ondHls.isNotEmpty) {
              hlsUrl = ondHls;
            }
            final hlsManifest = metadata['hlsManifestUrl'] as String?;
            if (hlsManifest != null && hlsManifest.isNotEmpty) {
              if (hlsUrl == null) {
                hlsUrl = hlsManifest;
              } else if (hlsManifest != hlsUrl && !altUrls.contains(hlsManifest)) {
                altUrls.add(hlsManifest);
              }
            }
            final videos = metadata['videos'] as List? ?? [];
            for (final v in videos) {
              if (v is Map && v['url'] != null) {
                final vUrl = v['url'].toString();
                if (!altUrls.contains(vUrl)) {
                  altUrls.add(vUrl);
                }
              }
            }
          }
        } catch (_) {}
      }

      // 2. Fallback regex directo para ondemandHls
      if (hlsUrl == null) {
        final regHls = RegExp(r'''ondemandHls[\\"\':\s]+(https:[^\\"\']+\.m3u8[^\s\\"\']*)''').firstMatch(html);
        if (regHls != null) {
          hlsUrl = regHls.group(1)!.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&');
        }
      }

      final primaryUrl = hlsUrl ?? (altUrls.isNotEmpty ? altUrls.first : null);
      if (primaryUrl == null) return null;

      final remainingAlts = altUrls.where((u) => u != primaryUrl).toList();

      return ExtractedStreamResult(
        videoUrl: primaryUrl,
        alternativeUrls: remainingAlts,
        headers: {
          'User-Agent': _desktopUa,
          'Referer': 'https://ok.ru/',
        },
      );
    } catch (e) {
      debugPrint('DynamicScraperService: error extractOkRuStream: $e');
    }
    return null;
  }

  Future<ExtractedStreamResult?> _extractSaveFilesStream(String embedUrl) async {
    try {
      final codeMatch = RegExp(r'savefiles\.com/(?:e/)?([A-Za-z0-9_-]+)', caseSensitive: false)
          .firstMatch(embedUrl);
      if (codeMatch == null) return null;
      final fileCode = codeMatch.group(1)!;

      final client = http.Client();
      final res = await client.post(
        Uri.parse('https://savefiles.com/dl'),
        headers: {
          'User-Agent': _desktopUa,
          'Referer': embedUrl,
          'Origin': 'https://savefiles.com',
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
        body: {
          'op': 'embed',
          'file_code': fileCode,
          'auto': '1',
          'referer': 'https://ww3.gnulahd.nu/',
        },
      ).timeout(const Duration(seconds: 8));
      client.close();

      if (res.statusCode != 200) return null;

      final body = res.body;

      // Buscar el archivo m3u8 en la configuración del reproductor SaveFiles
      final m3u8Match = RegExp(
        r'''sources\s*:\s*\[\s*\{\s*file\s*:\s*['"]([^'"]+\.m3u8[^'"]*)['"]''',
        caseSensitive: false,
      ).firstMatch(body) ??
      RegExp(
        r'''['"](https?://[^'"\s]+\.m3u8[^'"\s]*)['"]''',
        caseSensitive: false,
      ).firstMatch(body);

      if (m3u8Match != null) {
        final streamUrl = m3u8Match.group(1)!;

        // Subtítulos si existen
        final List<ScrapedSubtitle> subs = [];
        final captionMatches = RegExp(
          r'''\{\s*file\s*:\s*['"]([^'"]+\.vtt[^'"]*)['"]\s*,\s*label\s*:\s*['"]([^'"]*)['"]''',
          caseSensitive: false,
        ).allMatches(body);
        for (final cm in captionMatches) {
          subs.add(
            ScrapedSubtitle(
              url: cm.group(1)!,
              label: cm.group(2)!.isNotEmpty ? cm.group(2)! : 'Subtítulo',
            ),
          );
        }

        return ExtractedStreamResult(
          videoUrl: streamUrl,
          subtitles: subs,
          headers: {
            'User-Agent': _desktopUa,
            'Referer': 'https://savefiles.com/',
            'Origin': 'https://savefiles.com',
          },
        );
      }
    } catch (e) {
      debugPrint('DynamicScraperService: error extractSaveFilesStream: $e');
    }
    return null;
  }

  Future<ExtractedStreamResult?> _extractGnulaStream(String pageUrl) async {
    try {
      // Reutilizar el mismo client para página + API (mismo host) → una sola negociación TLS.
      final client = http.Client();
      final res = await client.get(
        Uri.parse(pageUrl),
        headers: {
          'User-Agent': _desktopUa,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode != 200) return null;
      final html = res.body;

      // Si la URL recibida es la ficha de una serie (/ver/) y no tiene reproductor directo,
      // resolvemos el primer episodio cronológico (S1E1) para que reproduzca desde el inicio.
      if (!html.contains('_gnrdPid') && html.contains('gnrd-eplist')) {
        final allCards = RegExp(
          r'''<a[^>]+class=['"][^'"]*gnrd-epc[^'"]*['"][^>]*>''',
          caseSensitive: false,
        ).allMatches(html);

        String? bestHref;
        int minSeason = 999999;
        int minEpisode = 999999;

        for (final m in allCards) {
          final cardTag = m.group(0)!;
          final href = RegExp(r'''href=['"]([^'"]+)['"]''', caseSensitive: false).firstMatch(cardTag)?.group(1);
          final sStr = RegExp(r'''data-s=['"](\d+)['"]''', caseSensitive: false).firstMatch(cardTag)?.group(1);
          final eStr = RegExp(r'''data-e=['"](\d+)['"]''', caseSensitive: false).firstMatch(cardTag)?.group(1);

          final s = int.tryParse(sStr ?? '') ?? 1;
          final e = int.tryParse(eStr ?? '') ?? 1;

          if (href != null && (s < minSeason || (s == minSeason && e < minEpisode))) {
            minSeason = s;
            minEpisode = e;
            bestHref = href;
          }
        }

        if (bestHref != null) {
          client.close();
          return await _extractGnulaStream(bestHref);
        }
      }

      final pidMatch = RegExp(r'_gnrdPid\s*=\s*(\d+)').firstMatch(html);
      final tokMatch = RegExp(r'''_gnrdTok\s*=\s*['"]([^'"]+)['"]''').firstMatch(html);
      final vdAuthMatch = RegExp(r'''VD_AUTH\s*=\s*['"]([^'"]+)['"]''').firstMatch(html);
      final ttAuthMatch = RegExp(r'''(?:^|[^a-zA-Z0-9_])AUTH\s*=\s*['"]([^'"]+)['"]''').firstMatch(html);

      if (pidMatch != null && tokMatch != null) {
        final pid = pidMatch.group(1)!;
        final tok = tokMatch.group(1)!;
        final vdAuth = vdAuthMatch?.group(1) ?? '&t=69d77fa4e43d2d340a4306574a3af563';
        final ttAuth = ttAuthMatch?.group(1) ?? '&t=2020e4d463d84d7745ee262348f5b65d';

        final uri = Uri.parse(pageUrl);
        final apiUrl = '${uri.scheme}://${uri.host}/wp-json/gnrd/v1/player?id=$pid&t=$tok';

        // Reutilizar el mismo client → misma conexión TCP/TLS para página + API.
        final apiRes = await client.get(
          Uri.parse(apiUrl),
          headers: {
            'User-Agent': _desktopUa,
            'Referer': pageUrl,
            'Accept': 'application/json, text/plain, */*',
          },
        ).timeout(const Duration(seconds: 12));

        if (apiRes.statusCode == 200) {
          final apiJson = json.decode(apiRes.body) as Map<String, dynamic>;
          final p = apiJson['p'] as String?;
          if (p != null && p.isNotEmpty) {
            final rawBytes = base64.decode(p);
            const key = [103, 78, 55, 100];
            final decBytes = Uint8List(rawBytes.length);
            for (var i = 0; i < rawBytes.length; i++) {
              decBytes[i] = rawBytes[i] ^ key[i & 3];
            }
            final decStr = utf8.decode(decBytes, allowMalformed: true);
            final data = json.decode(decStr) as Map<String, dynamic>;

            final langs = data['langs'] as List? ?? [];
            final List<String> candidateServers = [];
            final latino = <String>[];
            final castellano = <String>[];
            final subtitulado = <String>[];
            final otros = <String>[];

            for (final l in langs) {
              if (l is! Map) continue;
              final label = (l['label'] ?? '').toString().toLowerCase();
              final srvs = l['servers'] as List? ?? [];
              for (final s in srvs) {
                if (s is! Map) continue;
                final src = s['src'] as String?;
                if (src == null || src.isEmpty) continue;
                if (label.contains('latino')) {
                  latino.add(src);
                } else if (label.contains('castellano') || label.contains('español')) {
                  castellano.add(src);
                } else if (label.contains('sub')) {
                  subtitulado.add(src);
                } else {
                  otros.add(src);
                }
              }
            }

            candidateServers.addAll(latino);
            candidateServers.addAll(castellano);
            candidateServers.addAll(subtitulado);
            candidateServers.addAll(otros);

            // Priorizar por estabilidad, calidad y velocidad de resolución:
            //   0 = SaveFiles (Servidor 4) → ultra rápido, multi-CDN sin cortes
            //   1 = ok.ru                 → CDN de alta velocidad
            //   2 = vidara/the.tube       → resolución directa
            //   3 = voe                   → decodificación json/hls
            //   4 = resto                 → HTTP call + calidad desconocida
            int velocidad(String s) {
              final low = s.toLowerCase();
              if (low.contains('savefiles') || low.contains('savefile')) return 0;
              if (low.contains('ok.ru') || low.contains('odnoklassniki')) return 1;
              if (low.contains('vidara') || low.contains('the.tube') || low.contains('they.tube')) return 2;
              if (low.contains('voe')) return 3;
              return 4;
            }

            candidateServers.sort((a, b) => velocidad(a).compareTo(velocidad(b)));

            final List<ExtractedStreamResult> extractedResults = [];

            for (final src in candidateServers) {
              // Saltar file-hosters: no soportan Range requests ni streaming real.
              if (_esUrlFileHoster(src)) continue;

              // 1. Servidor SaveFiles (Servidor 4 en GnulaHD): ultra rápido y sin cortes
              if (src.contains('savefiles.com') || src.contains('savefile')) {
                final sfRes = await _extractSaveFilesStream(src);
                if (sfRes != null && sfRes.videoUrl.isNotEmpty) {
                  extractedResults.add(sfRes);
                  if (extractedResults.length >= 2) break;
                  continue;
                }
              }

              // 2. Servidor Vidara: resolución directa mediante vidara-resolve.php
              if (src.contains('vidara.to') || src.contains('vidaraa.cc') || src.contains('vidara')) {
                final m = RegExp(r'https?://([^/]+)/(?:e/)?([^/?#]+)').firstMatch(src);
                if (m != null) {
                  final host = m.group(1)!;
                  final code = m.group(2)!;
                  final vidaraM3u8 = '${uri.scheme}://${uri.host}/panel/vidara-resolve.php?pl=1&code=$code&host=$host$vdAuth&ext=.m3u8';
                  extractedResults.add(
                    ExtractedStreamResult(
                      videoUrl: vidaraM3u8,
                      headers: {
                        'User-Agent': _ua,
                        'Referer': pageUrl,
                      },
                    ),
                  );
                  if (extractedResults.length >= 2) break;
                  continue;
                }
              }

              // B. Servidor ok.ru
              if (src.contains('ok.ru') || src.contains('odnoklassniki')) {
                final okRes = await _extractOkRuStream(src);
                if (okRes != null && okRes.videoUrl.isNotEmpty) {
                  extractedResults.add(okRes);
                  if (extractedResults.length >= 2) break;
                  continue;
                }
              }

              // C. Servidor the.tube
              if (src.contains('the.tube') || src.contains('they.tube')) {
                final m = RegExp(r'the(?:y)?\.tube/(?:e/)?([A-Za-z0-9_-]+)').firstMatch(src);
                if (m != null) {
                  final code = m.group(1)!;
                  final tubeUrl = '${uri.scheme}://${uri.host}/panel/the-tube-resolve.php?code=$code$ttAuth';
                  extractedResults.add(
                    ExtractedStreamResult(
                      videoUrl: tubeUrl,
                      headers: {
                        'User-Agent': _ua,
                        'Referer': pageUrl,
                      },
                    ),
                  );
                  if (extractedResults.length >= 2) break;
                  continue;
                }
              }

              // D. Servidor VOE
              if (src.contains('voe.sx') || src.contains('voe.') || src.contains('voe-network')) {
                final voeRes = await _extractVoeStream(src);
                if (voeRes != null && voeRes.videoUrl.isNotEmpty) {
                  extractedResults.add(voeRes);
                  if (extractedResults.length >= 2) break;
                  continue;
                }
              }

              // E. Fallback genérico para otros servidores
              final genRes = await _extractDirectStreamFromEmbed(src);
              if (genRes != null &&
                  genRes.videoUrl.isNotEmpty &&
                  !_esUrlFileHoster(genRes.videoUrl)) {
                extractedResults.add(genRes);
                if (extractedResults.length >= 2) break;
              }
            }

            if (extractedResults.isNotEmpty) {
              final primary = extractedResults.first;
              final altUrls = <String>[];
              for (final r in extractedResults) {
                if (r.videoUrl != primary.videoUrl && !altUrls.contains(r.videoUrl)) {
                  altUrls.add(r.videoUrl);
                }
                for (final alt in r.alternativeUrls) {
                  if (alt != primary.videoUrl && !altUrls.contains(alt)) {
                    altUrls.add(alt);
                  }
                }
              }

              client.close();
              return ExtractedStreamResult(
                videoUrl: primary.videoUrl,
                subtitles: primary.subtitles,
                alternativeUrls: altUrls,
                headers: primary.headers.isNotEmpty ? primary.headers : {
                  'User-Agent': _ua,
                  'Referer': pageUrl,
                },
              );
            }
          }
        }
      }

      // Fallback si no hubo _gnrdPid: buscar iframe en el HTML
      final iframeMatch = RegExp(r'''<iframe[^>]+src=['"]([^'"]+)['"]''', caseSensitive: false).firstMatch(html);
      if (iframeMatch != null) {
        final ifrSrc = iframeMatch.group(1)!;
        if (!ifrSrc.contains('youtube') && !ifrSrc.contains('about:blank')) {
          client.close();
          return await _extractDirectStreamFromEmbed(ifrSrc);
        }
      }
      client.close();
    } catch (e) {
      debugPrint('DynamicScraperService: error extractGnulaStream: $e');
    }
    return null;
  }

  Future<ScrapedMetadata?> _scrapeGnulaMetadata(String url) async {
    try {
      final client = http.Client();
      final res = await client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _desktopUa,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        },
      ).timeout(const Duration(seconds: 10));
      client.close();

      if (res.statusCode != 200) return null;
      final html = res.body;

      // 1. Título limpio
      String title = '';
      final ogTitle = RegExp(
        r'''<meta\s+property=['"]og:title['"]\s+content=['"]([^'"]+)['"]''',
        caseSensitive: false,
      ).firstMatch(html);
      if (ogTitle != null) {
        title = ogTitle.group(1)!
            .replaceAll(RegExp(r'\s*\(?\d{4}\)?\s*(?:Película Completa|Serie Completa)?\s*(?:Español\s*Latino|Castellano|Subtitulado)?\s*(?:HD)?\s*\|\s*Gnula.*$', caseSensitive: false), '')
            .replaceAll(' - Gnula', '')
            .trim();
      }
      if (title.isEmpty) {
        final h1Match = RegExp(r'''<h1[^>]*>(.*?)</h1>''', dotAll: true, caseSensitive: false).firstMatch(html);
        if (h1Match != null) {
          title = h1Match.group(1)!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        }
      }

      // 2. Poster
      String? thumb;
      final ogImg = RegExp(
        r'''<meta\s+property=['"]og:image['"]\s+content=['"]([^'"]+)['"]''',
        caseSensitive: false,
      ).firstMatch(html);
      if (ogImg != null) {
        thumb = ogImg.group(1)!.trim();
      }

      // 3. Descripción / Sinopsis
      String? desc;
      final descMatch = RegExp(
        r'''<meta\s+(?:property=['"]og:description['"]|name=['"]description['"])\s+content=['"]([^'"]+)['"]''',
        caseSensitive: false,
      ).firstMatch(html);
      if (descMatch != null) {
        desc = descMatch.group(1)!.trim();
      }
      if (desc == null || desc.isEmpty) {
        final synMatch = RegExp(r'''class=['"][^'"]*gnrd-fi-syn[^'"]*['"][^>]*>(.*?)</div>''', dotAll: true, caseSensitive: false).firstMatch(html);
        if (synMatch != null) {
          desc = synMatch.group(1)!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        }
      }

      // 4. Episodios si es serie
      final List<M3UItem> episodes = [];
      final fullTagRegex = RegExp(
        r'''<a([^>]+class=['"][^'"]*gnrd-epc[^'"]*['"][^>]*)>(.*?)</a>''',
        dotAll: true,
        caseSensitive: false,
      );

      final seenUrls = <String>{};
      for (final m in fullTagRegex.allMatches(html)) {
        final tagAttrs = m.group(1) ?? '';
        final inner = m.group(2) ?? '';

        final hrefMatch = RegExp(r'''href=['"]([^'"]+)['"]''', caseSensitive: false).firstMatch(tagAttrs);
        if (hrefMatch == null) continue;
        final epUrl = hrefMatch.group(1)!;
        if (!seenUrls.add(epUrl)) continue;

        final seasonMatch = RegExp(r'''data-s=['"]([^'"]+)['"]''', caseSensitive: false).firstMatch(tagAttrs);
        final numMatch = RegExp(r'''class=['"][^'"]*gnrd-epc-n[^'"]*['"][^>]*>([^<]+)<''', caseSensitive: false).firstMatch(inner);
        final titleMatch = RegExp(r'''class=['"][^'"]*gnrd-epc-title[^'"]*['"][^>]*>([^<]+)<''', caseSensitive: false).firstMatch(inner);
        final durMatch = RegExp(r'''class=['"][^'"]*gnrd-epc-dur[^'"]*['"][^>]*>([^<]+)<''', caseSensitive: false).firstMatch(inner);
        final imgMatch = RegExp(r'''<img[^>]+(?:src|data-src)=['"]([^'"]+)['"]''', caseSensitive: false).firstMatch(inner);

        final codeStr = numMatch?.group(1)?.trim() ?? ''; // ej: "2x10"
        final epTitleClean = titleMatch?.group(1)?.trim() ?? ''; // ej: "Donde pertenecemos"
        final durStr = durMatch?.group(1)?.trim(); // ej: "53 min"
        final epThumb = imgMatch?.group(1)?.trim() ?? thumb;

        int? sNum;
        int? epNum;
        if (codeStr.isNotEmpty) {
          final parts = RegExp(r'(\d+)x(\d+)', caseSensitive: false).firstMatch(codeStr);
          if (parts != null) {
            sNum = int.tryParse(parts.group(1)!);
            epNum = int.tryParse(parts.group(2)!);
          }
        }
        sNum ??= int.tryParse(seasonMatch?.group(1) ?? '');

        final displayName = [
          if (codeStr.isNotEmpty) codeStr,
          if (epTitleClean.isNotEmpty) epTitleClean,
        ].join(' - ');

        final finalName = displayName.isNotEmpty ? displayName : 'Episodio ${episodes.length + 1}';

        episodes.add(
          M3UItem(
            name: finalName,
            url: epUrl,
            logo: epThumb,
            category: 'Episodios',
            duration: durStr,
            seriesName: title,
            seasonNumber: sNum,
            episodeNumber: epNum,
            isLive: false,
            isDynamic: true,
          ),
        );
      }

      // Ordenar episodios ascendentemente
      episodes.sort((a, b) {
        final sA = a.seasonNumber ?? 0;
        final sB = b.seasonNumber ?? 0;
        if (sA != sB) return sA.compareTo(sB);
        final eA = a.episodeNumber ?? 0;
        final eB = b.episodeNumber ?? 0;
        return eA.compareTo(eB);
      });

      if (title.isNotEmpty) {
        return ScrapedMetadata(
          title: title,
          thumbnailUrl: thumb,
          description: desc,
          episodes: episodes,
        );
      }
    } catch (e) {
      debugPrint('DynamicScraperService: error _scrapeGnulaMetadata: $e');
    }
    return null;
  }
}
