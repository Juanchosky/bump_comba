import 'package:flutter_test/flutter_test.dart';
import 'package:bump_comba/models/m3u_item.dart';
import 'package:bump_comba/services/m3u_service.dart';

M3UItem xtream(String nombre, {required bool serie, String cat = 'Recomendados'}) =>
    M3UItem(
      name: nombre,
      url: 'http://prov/$nombre',
      category: cat,
      isSeries: serie,
    );

M3UItem bd(String nombre, {required bool serie, String cat = 'Recomendados'}) =>
    M3UItem(
      name: nombre,
      url: 'https://bd/$nombre',
      category: cat,
      isSeries: serie,
      sourceName: 'Supabase',
    );

void main() {
  group('Reparto del contenido propio en el catalogo', () {
    // Se reproduce la forma REAL del catalogo, que es la que causaba el fallo:
    //
    //  · Todas las peliculas delante y las series detras.
    //  · La categoria del item propio ("Recomendados") existe en el catalogo
    //    del proveedor pero solo con PELICULAS; sus series estan en otra.
    //
    // Con esa forma, agrupar solo por categoria mandaba la serie propia a la
    // zona de peliculas —al principio de la lista— y al filtrar por isSeries
    // salia la primera. Sin la segunda condicion el fallo no aparece: la
    // insercion cae por casualidad entre series y la prueba pasa igual.
    List<M3UItem> catalogoDelProveedor() => [
          for (var i = 0; i < 20; i++) xtream('Pelicula $i', serie: false),
          for (var i = 0; i < 20; i++)
            xtream('Serie $i', serie: true, cat: 'Series TV'),
        ];

    test('una serie propia NO sale la primera de las series', () {
      final resultado = M3UService.repartirContenidoPropioParaPruebas(
        catalogoDelProveedor(),
        [bd('Serie de la BD', serie: true)],
      );

      // Es lo que hace la fila "Todas las Series": filtrar por isSeries
      // conservando el orden.
      final series = resultado.where((i) => i.isSeries).toList();
      expect(series.first.name, isNot('Serie de la BD'));
      expect(
        series.any((i) => i.name == 'Serie de la BD'),
        isTrue,
        reason: 'tiene que seguir estando, solo que no la primera',
      );
    });

    test('y tampoco se cuela en el bloque de peliculas', () {
      final resultado = M3UService.repartirContenidoPropioParaPruebas(
        catalogoDelProveedor(),
        [bd('Serie de la BD', serie: true)],
      );
      final idx = resultado.indexWhere((i) => i.name == 'Serie de la BD');
      final primeraSerie = resultado.indexWhere((i) => i.isSeries);
      expect(
        idx,
        greaterThan(primeraSerie),
        reason: 'una serie propia va entre series, no entre peliculas',
      );
    });

    test('lo mismo para una pelicula propia: no sale la primera', () {
      final resultado = M3UService.repartirContenidoPropioParaPruebas(
        catalogoDelProveedor(),
        [bd('Pelicula de la BD', serie: false)],
      );
      final pelis = resultado.where((i) => !i.isSeries).toList();
      expect(pelis.first.name, isNot('Pelicula de la BD'));
      expect(pelis.any((i) => i.name == 'Pelicula de la BD'), isTrue);
    });

    test('no se pierde nada por el camino', () {
      final propios = [
        bd('Serie de la BD', serie: true),
        bd('Pelicula de la BD', serie: false),
      ];
      final resultado = M3UService.repartirContenidoPropioParaPruebas(
        catalogoDelProveedor(),
        propios,
      );
      expect(resultado.length, 40 + propios.length);
    });
  });
}
