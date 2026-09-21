import 'package:flutter_test/flutter_test.dart';

import 'package:bump_comba/services/dynamic_scraper_service.dart';

/// Lo que se comprueba aqui es la DEDUCCION, no la peticion.
///
/// Que una hermana exista de verdad depende del proveedor y no se puede
/// probar sin red — eso es lo que hace que `gnula_stream_test.dart` falle de
/// forma intermitente. Pero deducir su URL es aritmetica de cadenas, y eso si
/// se puede clavar: es donde estaria el fallo que cambiaria una variante por
/// una que no existe, o peor, por una PEOR.
void main() {
  group('Deduccion de la variante hermana', () {
    test('de la ligera -ld saca las mejores, y la mejor primero', () {
      final h = DynamicScraperService.hermanasDe(
        'https://cdn.ejemplo.com/video/peli-ld.m3u8',
      );
      expect(h, isNotEmpty);
      expect(h.first, 'https://cdn.ejemplo.com/video/peli-fhd.m3u8');
      expect(h, contains('https://cdn.ejemplo.com/video/peli-hd.m3u8'));
      expect(h, contains('https://cdn.ejemplo.com/video/peli-sd.m3u8'));
    });

    test('nunca propone una variante peor que la que ya se tiene', () {
      // De `-ld` no puede salir `-fd`, que es la mas pobre de la familia.
      final h = DynamicScraperService.hermanasDe(
        'https://cdn.ejemplo.com/peli-ld.m3u8',
      );
      expect(h.any((u) => u.contains('-fd.')), isFalse);

      // Y de `-sd` no puede salir ni `-ld` ni `-fd`.
      final h2 = DynamicScraperService.hermanasDe(
        'https://cdn.ejemplo.com/peli-sd.m3u8',
      );
      expect(h2.any((u) => u.contains('-ld.') || u.contains('-fd.')), isFalse);
    });

    test('la familia microframe, donde hd significa 1080', () {
      final h = DynamicScraperService.hermanasDe(
        'https://v.ejemplo.com/hls/microframe-ld/index.m3u8',
      );
      expect(h.first, 'https://v.ejemplo.com/hls/microframe-hd/index.m3u8');
      expect(
        h,
        contains('https://v.ejemplo.com/hls/microframe-sd/index.m3u8'),
      );
    });

    test('la familia numerica, en el nombre del archivo', () {
      final h = DynamicScraperService.hermanasDe(
        'https://cdn.ejemplo.com/v/480.m3u8',
      );
      expect(h.first, 'https://cdn.ejemplo.com/v/1080.m3u8');
      expect(h, contains('https://cdn.ejemplo.com/v/720.m3u8'));
    });

    test('la familia numerica, como carpeta', () {
      final h = DynamicScraperService.hermanasDe(
        'https://cdn.ejemplo.com/hls/720/index.m3u8',
      );
      expect(h, ['https://cdn.ejemplo.com/hls/1080/index.m3u8']);
    });

    test('la familia por palabra', () {
      final h = DynamicScraperService.hermanasDe(
        'https://cdn.ejemplo.com/v/low.m3u8',
      );
      expect(h.first, 'https://cdn.ejemplo.com/v/high.m3u8');
    });

    test('se conserva la parte de la firma, que va en el query', () {
      // Esto importa: en estos servidores el token viaja detras del `?`. Si
      // la deduccion se lo comiera, la hermana daria 403 SIEMPRE y el cambio
      // no serviria para nada sin que se notara por que.
      final h = DynamicScraperService.hermanasDe(
        'https://s3.ejemplo.com/hls2/01/peli-ld.m3u8?t=abc123&s=1789948776&e=43200',
      );
      expect(h, isNotEmpty);
      for (final u in h) {
        expect(u, contains('?t=abc123&s=1789948776&e=43200'));
      }
    });

    test('una url que ya es la buena no propone nada', () {
      expect(
        DynamicScraperService.hermanasDe(
          'https://cdn.ejemplo.com/v/master.m3u8',
        ),
        isEmpty,
      );
      expect(
        DynamicScraperService.hermanasDe('https://cdn.ejemplo.com/v/peli.mp4'),
        isEmpty,
      );
      // Y la cima de cada familia tampoco tiene a donde subir.
      expect(
        DynamicScraperService.hermanasDe(
          'https://cdn.ejemplo.com/v/1080.m3u8',
        ),
        isEmpty,
      );
    });

    test('no se propone a si misma', () {
      final url = 'https://cdn.ejemplo.com/v/peli-sd.m3u8';
      expect(DynamicScraperService.hermanasDe(url), isNot(contains(url)));
    });

    test('no repite una misma url aunque encajen dos reglas', () {
      final h = DynamicScraperService.hermanasDe(
        'https://cdn.ejemplo.com/hls/480/peli-ld.m3u8',
      );
      expect(h.length, h.toSet().length);
    });
  });
}
