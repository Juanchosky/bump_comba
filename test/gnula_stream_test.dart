import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:bump_comba/services/dynamic_scraper_service.dart';

void main() {
  test('GnulaHD XOR unpacker and Vidara resolver test', () async {
    final pageUrl = 'https://ww3.gnulahd.nu/dang-1x01/';
    const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
    
    final res = await http.get(Uri.parse(pageUrl), headers: {
      'User-Agent': ua,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    });
    
    expect(res.statusCode, 200);
    final html = res.body;
    
    final pidMatch = RegExp(r'_gnrdPid\s*=\s*(\d+)').firstMatch(html);
    final tokMatch = RegExp(r'''_gnrdTok\s*=\s*['"]([^'"]+)['"]''').firstMatch(html);
    final vdAuthMatch = RegExp(r'''VD_AUTH\s*=\s*['"]([^'"]+)['"]''').firstMatch(html);
    
    expect(pidMatch, isNotNull);
    expect(tokMatch, isNotNull);
    
    final pid = pidMatch!.group(1)!;
    final tok = tokMatch!.group(1)!;
    final vdAuth = vdAuthMatch?.group(1) ?? '';
    
    final apiUrl = 'https://ww3.gnulahd.nu/wp-json/gnrd/v1/player?id=$pid&t=$tok';
    final apiRes = await http.get(Uri.parse(apiUrl), headers: {
      'User-Agent': ua,
      'Referer': pageUrl,
    });
    expect(apiRes.statusCode, 200);
    final apiJson = jsonDecode(apiRes.body);
    final p = apiJson['p'];
    expect(p, isNotNull);
    
    final rawBytes = base64.decode(p);
    const key = [103, 78, 55, 100];
    final decryptedBytes = List<int>.generate(
      rawBytes.length,
      (i) => rawBytes[i] ^ key[i % key.length],
    );
    final decStr = utf8.decode(decryptedBytes, allowMalformed: true);
    final Map<String, dynamic> data = jsonDecode(decStr);
    
    expect(data['langs'], isNotNull);
    final langs = data['langs'] as List;
    expect(langs.isNotEmpty, isTrue);
    
    String? vidaraUrl;
    for (final l in langs) {
      for (final s in (l['servers'] as List? ?? [])) {
        final src = s['src'] as String;
        if (src.contains('vidara')) {
          final m = RegExp(r'https?://([^/]+)/e/([^/?#]+)').firstMatch(src);
          if (m != null) {
            final host = m.group(1)!;
            final code = m.group(2)!;
            vidaraUrl = 'https://ww3.gnulahd.nu/panel/vidara-resolve.php?pl=1&code=$code&host=$host$vdAuth&ext=.m3u8';
            break;
          }
        }
      }
      if (vidaraUrl != null) break;
    }
    
    expect(vidaraUrl, isNotNull);
    final checkRes = await http.get(Uri.parse(vidaraUrl!), headers: {
      'User-Agent': ua,
      'Referer': pageUrl,
    });
    expect(checkRes.statusCode, 200);
    expect(checkRes.body.startsWith('#EXTM3U'), isTrue);
  });

  test('DynamicScraperService fast extraction for GnulaHD', () async {
    final scraper = DynamicScraperService();
    expect(scraper.isSupported('https://ww3.gnulahd.nu/dang-1x01/'), isTrue);
    expect(scraper.isSupported('https://ww3.gnulahd.nu/ver/dang/'), isTrue);
    
    final result = await scraper.extractStreamResult('https://ww3.gnulahd.nu/dang-1x01/');
    expect(result, isNotNull);
    expect(result!.videoUrl, contains('vidara-resolve.php'));
    expect(result.videoUrl, contains('.m3u8'));
  });
}
