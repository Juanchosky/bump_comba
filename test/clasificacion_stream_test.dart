import 'package:flutter_test/flutter_test.dart';
import 'package:bump_comba/utils/clasificacion_stream.dart';

void main() {
  group('esEnVivoPorUrl', () {
    // ── El fallo que motivo todo esto ─────────────────────────────────────
    //
    // Los proveedores Xtream sirven muchisimo VOD como `.m3u8`. El heuristico
    // viejo miraba la extension antes que la ruta y daba estas por directo;
    // al televisor le llegaban entonces fuera de TurboProxy y se comia las
    // reconexiones del proveedor de una en una.
    test('una pelicula servida como .m3u8 NO es directo', () {
      expect(
        esEnVivoPorUrl('http://prov.tv:8080/movie/usuario/clave/12345.m3u8'),
        isFalse,
      );
    });

    test('un episodio servido como .m3u8 NO es directo', () {
      expect(
        esEnVivoPorUrl('http://prov.tv:8080/series/usuario/clave/999.m3u8'),
        isFalse,
      );
    });

    test('la ruta de catalogo manda aunque la URL diga tambien m3u8', () {
      expect(
        esEnVivoPorUrl('http://prov.tv/movie/u/c/1.m3u8?token=abc'),
        isFalse,
      );
    });

    // ── Lo que si es directo ──────────────────────────────────────────────
    test('un canal en /live/ es directo', () {
      expect(
        esEnVivoPorUrl('http://prov.tv:8080/live/usuario/clave/55.m3u8'),
        isTrue,
      );
    });

    test('type=live es directo', () {
      expect(esEnVivoPorUrl('http://prov.tv/stream?type=live&id=7'), isTrue);
    });

    test('un .m3u8 sin ninguna pista de catalogo se asume directo', () {
      expect(esEnVivoPorUrl('http://cualquiera.tv/canal.m3u8'), isTrue);
    });

    // ── VOD normal ────────────────────────────────────────────────────────
    test('un archivo de video corriente no es directo', () {
      expect(esEnVivoPorUrl('http://prov.tv/movie/u/c/1.mkv'), isFalse);
      expect(esEnVivoPorUrl('https://cdn.ejemplo.com/peli.mp4'), isFalse);
    });

    test('/vod/ no es directo', () {
      expect(esEnVivoPorUrl('http://prov.tv/vod/u/c/1.m3u8'), isFalse);
    });

    test('no distingue mayusculas', () {
      expect(esEnVivoPorUrl('http://PROV.tv/MOVIE/u/c/1.M3U8'), isFalse);
      expect(esEnVivoPorUrl('http://PROV.tv/LIVE/u/c/1.M3U8'), isTrue);
    });
  });
}
