import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:bump_comba/services/dynamic_scraper_service.dart';
import 'package:bump_comba/utils/clasificacion_stream.dart';

void main() {
  test('GnulaHD XOR unpacker deterministic algorithm test', () {
    const key = [103, 78, 55, 100];
    final original = {
      't': 'Monarch 2x10',
      'langs': [
        {
          'label': 'Latino',
          'servers': [
            {'src': 'https://ok.ru/videoembed/13947470547571'},
          ],
        },
      ],
    };
    final jsonStr = jsonEncode(original);
    final utf8Bytes = utf8.encode(jsonStr);

    // Cifrar con XOR
    final encrypted = Uint8List(utf8Bytes.length);
    for (var i = 0; i < utf8Bytes.length; i++) {
      encrypted[i] = utf8Bytes[i] ^ key[i & 3];
    }
    final b64Payload = base64.encode(encrypted);

    // Descifrar con XOR (mismo algoritmo que gnrdUnpack)
    final rawBytes = base64.decode(b64Payload);
    final decrypted = Uint8List(rawBytes.length);
    for (var i = 0; i < rawBytes.length; i++) {
      decrypted[i] = rawBytes[i] ^ key[i & 3];
    }
    final recoveredStr = utf8.decode(decrypted);
    final recoveredJson = jsonDecode(recoveredStr) as Map<String, dynamic>;

    expect(recoveredJson['t'], 'Monarch 2x10');
    expect(recoveredJson['langs'], isNotEmpty);
    expect(
      recoveredJson['langs'][0]['servers'][0]['src'],
      'https://ok.ru/videoembed/13947470547571',
    );
  });

  test(
      'DynamicScraperService fast extraction for Monarch 2x10 (ok.ru stream)',
      () async {
    final scraper = DynamicScraperService();
    const epUrl =
        'https://ww3.gnulahd.nu/monarch-legado-de-monstruos-2x10/';
    expect(scraper.isSupported(epUrl), isTrue);

    final sw = Stopwatch()..start();
    final result = await scraper.extractStreamResult(epUrl);
    sw.stop();

    expect(result, isNotNull);
    expect(result!.videoUrl.isNotEmpty, isTrue);
    expect(
      result.videoUrl.contains('.m3u8') || result.videoUrl.contains('okcdn.ru'),
      isTrue,
    );
    expect(sw.elapsedMilliseconds, lessThan(10000));

    // Verificar que el stream obtenido de okcdn responda HTTP 200 y sea una lista HLS válida
    final ioClient = IOClient(
      HttpClient()..badCertificateCallback = (cert, host, port) => true,
    );
    final streamRes = await ioClient.get(
      Uri.parse(result.videoUrl),
      headers: result.headers,
    );
    ioClient.close();

    expect(streamRes.statusCode, 200);
    expect(streamRes.body.startsWith('#EXTM3U'), isTrue);
  });

  test('DynamicScraperService series metadata and episodes for Monarch',
      () async {
    final scraper = DynamicScraperService();
    const seriesUrl =
        'https://ww3.gnulahd.nu/ver/monarch-legado-de-monstruos/';
    expect(scraper.isSupported(seriesUrl), isTrue);

    final meta = await scraper.scrapeMetadata(seriesUrl);
    expect(meta, isNotNull);
    expect(meta!.title, contains('Monarch'));
    expect(meta.thumbnailUrl, isNotNull);
    expect(meta.description, isNotNull);
    expect(meta.episodes.isNotEmpty, isTrue);
    expect(meta.episodes.length, greaterThanOrEqualTo(15));

    // Validar estructura de un episodio
    final firstEp = meta.episodes.first;
    expect(firstEp.url, contains('monarch-legado-de-monstruos'));
    expect(firstEp.isDynamic, isTrue);
    expect(firstEp.category, 'Episodios');
    expect(firstEp.seasonNumber, isNotNull);
    expect(firstEp.episodeNumber, isNotNull);

    // Validar que el episodio 2x10 está en la lista de episodios
    final ep2x10 = meta.episodes.firstWhere(
      (e) => e.url.contains('2x10'),
      orElse: () => meta.episodes.first,
    );
    expect(ep2x10.url, 'https://ww3.gnulahd.nu/monarch-legado-de-monstruos-2x10/');
    expect(ep2x10.seasonNumber, 2);
    expect(ep2x10.episodeNumber, 10);
  });

  test('DynamicScraperService fast extraction for GnulaHD Dang 1x01', () async {
    final scraper = DynamicScraperService();
    expect(scraper.isSupported('https://ww3.gnulahd.nu/dang-1x01/'), isTrue);
    expect(scraper.isSupported('https://ww3.gnulahd.nu/ver/dang/'), isTrue);

    final result =
        await scraper.extractStreamResult('https://ww3.gnulahd.nu/dang-1x01/');
    expect(result, isNotNull);
    expect(result!.videoUrl, contains('vidara-resolve.php'));
    expect(result.videoUrl, contains('.m3u8'));

    // Verificar que el stream obtenido responda HTTP 200 y sea una lista HLS válida
    final ioClient = IOClient(
      HttpClient()..badCertificateCallback = (cert, host, port) => true,
    );
    final streamRes = await ioClient.get(
      Uri.parse(result.videoUrl),
      headers: result.headers,
    );
    ioClient.close();

    expect(streamRes.statusCode, 200);
    expect(streamRes.body.startsWith('#EXTM3U'), isTrue);
  });

  test('clasificacion_stream classifies GnulaHD and OK CDN as VOD', () {
    expect(esEnVivoPorUrl('https://ww3.gnulahd.nu/dang-1x01/'), isFalse);
    expect(
        esEnVivoPorUrl(
            'https://vd721.okcdn.ru/expires/12345/ondemand/hls4.m3u8'),
        isFalse);
    expect(
        esEnVivoPorUrl(
            'https://ww3.gnulahd.nu/panel/vidara-resolve.php?pl=1&code=abc&ext=.m3u8'),
        isFalse);
  });
}
