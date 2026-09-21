import 'package:flutter_test/flutter_test.dart';

import 'package:bump_comba/services/fast_image_service.dart';

void main() {
  group('Que tamaño se le pide a TMDB', () {
    test('nunca se pide menos de lo que se va a pintar', () {
      // ESTE es el fallo que se arreglo: la TV decodifica las tarjetas a 252
      // px (126 de ancho x2, por el zoom al enfocar) y se pedia `w185`. O sea
      // 185 pixeles estirados hasta 252 — una imagen ampliada, no una imagen
      // blanda.
      expect(FastImageService.tamanoTmdbPara(252), 'w342');

      // La regla general, que es lo que de verdad hay que proteger.
      for (final ancho in const [120, 185, 200, 252, 342, 400, 500, 640]) {
        final elegido = FastImageService.tamanoTmdbPara(ancho);
        final pixeles = int.parse(elegido.substring(1));
        expect(
          pixeles,
          greaterThanOrEqualTo(ancho),
          reason: 'para pintar $ancho px se pidio $elegido: se amplia',
        );
      }
    });

    test('tampoco se pide de mas', () {
      // Lo contrario tambien importa: gastar red y disco en pixeles que se
      // van a tirar al descodificar.
      expect(FastImageService.tamanoTmdbPara(100), 'w185');
      expect(FastImageService.tamanoTmdbPara(300), 'w342');
      expect(FastImageService.tamanoTmdbPara(480), 'w500');
    });

    test('en el televisor el tope baja a w500', () {
      // Un JPEG de 780 px se descodifica aunque luego se reduzca, y en un
      // aparato de 1 GB ese trabajo extra en cada miniatura de una rejilla se
      // nota al desplazarse. Las tarjetas piden 252, asi que el tope no
      // recorta nada de lo que se ve.
      FastImageService.modoTelevisor = true;
      addTearDown(() => FastImageService.modoTelevisor = false);
      expect(FastImageService.tamanoTmdbPara(252), 'w342');
      expect(FastImageService.tamanoTmdbPara(1000), 'w500');
    });

    test('se corta en w780 y no salta a original', () {
      // `original` puede venir en 2000 px para una tarjeta. En un aparato de
      // 1 GB eso es exactamente por donde se va la memoria.
      expect(FastImageService.tamanoTmdbPara(1000), 'w780');
      expect(FastImageService.tamanoTmdbPara(4000), 'w780');
    });
  });
}
