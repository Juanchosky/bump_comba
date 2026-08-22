import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('el cliente http de la app, pide gzip?', () async {
    for (final headers in [
      <String, String>{'Accept': 'application/json'},            // como esta hoy
      <String, String>{'Accept': 'application/json',
                       'Accept-Encoding': 'gzip'},               // explicito
    ]) {
      final sw = Stopwatch()..start();
      final r = await http.get(
        Uri.parse('http://217.216.80.212/catalogo/vod.json'),
        headers: headers,
      );
      sw.stop();
      print('  headers enviados : $headers');
      print('    HTTP ${r.statusCode}'
            ' | content-encoding: ${r.headers['content-encoding']}'
            ' | content-length: ${r.headers['content-length']}');
      print('    bodyBytes (descomprimido): ${r.bodyBytes.length}');
      print('    etag: ${r.headers['etag']}  | ${sw.elapsedMilliseconds} ms');
      print('');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
