// Tests del lector del catálogo pre-horneado.
//
// Se prueba `parseSnapshotEnSegundoPlano` directamente (sin `compute`) porque
// es una función top-level pura: entra el JSON que publica `vps/catalogo.sh` y
// salen los M3UItem. Es la pieza donde un fallo silencioso duele más — no
// crashea, simplemente le muestra al usuario un catálogo mal armado.
//
// El contrato que verifican estos tests es el mismo que cumple el parser del
// panel (`parseVodStreamsInBackground` / `parseSeriesInBackground`) en
// lib/services/xtream_service.dart. Si se cambia uno, el otro tiene que
// seguirlo, o el catálogo cambiará según de dónde vino.

import 'dart:convert';

import 'package:bump_comba/services/catalog_snapshot_service.dart';
import 'package:bump_comba/utils/normalization_utils.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = 'http://mi.panel.tv:8080';
const _user = 'usuario1';
const _pass = 'clave1';

Map<String, dynamic> _entrada({
  required Map<String, dynamic> vod,
  required Map<String, dynamic> series,
  int version = 1,
}) => {
  'vod': jsonEncode(vod),
  'series': jsonEncode(series),
  'host': _host,
  'user': _user,
  'pass': _pass,
  'version': version,
};

Map<String, dynamic> _vodBase({List<Map<String, dynamic>>? items}) => {
  'v': 1,
  'categorias': {'42': 'Acción', '9': 'Terror'},
  'items':
      items ??
      [
        {
          'i': '759216',
          'n': 'Una Película',
          'e': 'mkv',
          'c': '42',
          'l': 'http://img.panel.tv/759216.jpg',
          'd': '1:45:00',
        },
      ],
};

Map<String, dynamic> _seriesBase({List<Map<String, dynamic>>? items}) => {
  'v': 1,
  'categorias': {'9': 'Series HD'},
  'items':
      items ??
      [
        {
          'i': '5521',
          'n': 'Una Serie',
          'c': '9',
          'l': 'http://img.panel.tv/s5521.jpg',
        },
      ],
};

void main() {
  group('URLs y credenciales', () {
    test('la URL de película se arma con las credenciales del usuario', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(vod: _vodBase(), series: _seriesBase()),
      );
      final peli = items.firstWhere((i) => !i.isSeries);

      // Exactamente el mismo formato que produce parseVodStreamsInBackground.
      expect(peli.url, '$_host/movie/$_user/$_pass/759216.mkv');
    });

    test('el snapshot no contiene credenciales: salen del parámetro', () {
      final crudo = jsonEncode(_vodBase());
      expect(crudo.contains(_user), isFalse);
      expect(crudo.contains(_pass), isFalse);

      final items = parseSnapshotEnSegundoPlano(
        _entrada(vod: _vodBase(), series: _seriesBase()),
      );
      expect(items.first.url, contains(_user));
    });

    test('la serie guarda el series_id en url, no una URL reproducible', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(vod: _vodBase(), series: _seriesBase()),
      );
      final serie = items.firstWhere((i) => i.isSeries);

      expect(serie.url, '5521');
      expect(serie.seriesName, 'Una Serie');
      expect(serie.episodes, isEmpty);
    });

    test('sin extensión usa mp4, igual que el parser del panel', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: _vodBase(items: [
            {'i': '10', 'n': 'Sin ext', 'c': '42'},
          ]),
          series: _seriesBase(items: []),
        ),
      );
      expect(items.single.url, endsWith('/10.mp4'));
    });
  });

  group('Categorías y logos', () {
    test('resuelve el id de categoría contra el mapa', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(vod: _vodBase(), series: _seriesBase()),
      );
      // Comparado contra normalizeCategory y no contra la cadena cruda: el
      // valor que llega al catálogo es siempre el normalizado (ver el grupo
      // "Paridad con el camino del panel").
      expect(
        items.firstWhere((i) => !i.isSeries).category,
        NormalizationUtils.normalizeCategory('Acción'),
      );
      expect(
        items.firstWhere((i) => i.isSeries).category,
        NormalizationUtils.normalizeCategory('Series HD'),
      );
    });

    test('categoría desconocida cae al nombre por defecto', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: _vodBase(items: [
            {'i': '10', 'n': 'Huérfana', 'e': 'mkv', 'c': '999'},
          ]),
          series: _seriesBase(items: [
            {'i': '20', 'n': 'Serie Huérfana', 'c': '999'},
          ]),
        ),
      );
      expect(items.firstWhere((i) => !i.isSeries).category, 'Películas');
      expect(items.firstWhere((i) => i.isSeries).category, 'Series');
    });

    test('las categorías se comparten en memoria (intern)', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: _vodBase(items: [
            {'i': '1', 'n': 'A', 'e': 'mkv', 'c': '42'},
            {'i': '2', 'n': 'B', 'e': 'mkv', 'c': '42'},
          ]),
          series: _seriesBase(items: []),
        ),
      );
      // La misma instancia, no dos cadenas iguales: con ~20.000 items esto es
      // la diferencia entre una copia y veinte mil.
      expect(identical(items[0].category, items[1].category), isTrue);
    });

    test('logo relativo se completa con el host', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: _vodBase(items: [
            {'i': '1', 'n': 'A', 'e': 'mkv', 'c': '42', 'l': '/covers/1.jpg'},
          ]),
          series: _seriesBase(items: []),
        ),
      );
      expect(items.single.logo, '$_host/covers/1.jpg');
    });

    test('logo ausente o placeholder queda vacío', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: _vodBase(items: [
            {'i': '1', 'n': 'A', 'e': 'mkv', 'c': '42'},
            {
              'i': '2',
              'n': 'B',
              'e': 'mkv',
              'c': '42',
              'l': 'http://x/placeholder.png',
            },
          ]),
          series: _seriesBase(items: []),
        ),
      );
      expect(items[0].logo, '');
      expect(items[1].logo, '');
    });
  });

  // Estos dos grupos existen por una regresion real (2026-08-22): el snapshot
  // producia categorias y URLs distintas a las del panel, y el usuario vio
  // cambiar los nombres de las categorias y desaparecer contenido de sus
  // secciones. La lista de items era la misma; lo que estaba mal era como se
  // agrupaba. Cualquier diferencia entre los dos caminos se paga asi.
  group('Paridad con el camino del panel', () {
    test('las categorias se normalizan igual que en el panel', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: {
            'v': 1,
            // Tal como las manda el panel: mayusculas y etiquetas tecnicas.
            'categorias': {'42': 'CINE DE ORO MEXICANO', '7': 'ACCION [HD]'},
            'items': [
              {'i': '1', 'n': 'A', 'e': 'mkv', 'c': '42'},
              {'i': '2', 'n': 'B', 'e': 'mkv', 'c': '7'},
            ],
          },
          series: _seriesBase(items: []),
        ),
      );

      // xtream_service.dart:391 pasa cada nombre por normalizeCategory antes
      // de armar el mapa. El snapshot las guarda crudas, asi que la
      // normalizacion tiene que ocurrir aqui o los dos caminos divergen.
      expect(items[0].category, NormalizationUtils.normalizeCategory('CINE DE ORO MEXICANO'));
      expect(items[1].category, NormalizationUtils.normalizeCategory('ACCION [HD]'));
      // Y en concreto: NO la cadena cruda.
      expect(items[0].category, isNot('CINE DE ORO MEXICANO'));
    });

    test('las categorias de series tambien se normalizan', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: _vodBase(items: []),
          series: {
            'v': 1,
            'categorias': {'9': 'NETFLIX'},
            'items': [
              {'i': '5', 'n': 'S', 'c': '9'},
            ],
          },
        ),
      );
      expect(items.single.category, NormalizationUtils.normalizeCategory('NETFLIX'));
    });

    test('un host con barra final no duplica la barra en la URL', () {
      final items = parseSnapshotEnSegundoPlano({
        'vod': jsonEncode(_vodBase()),
        'series': jsonEncode(_seriesBase(items: [])),
        // El panel usa cleanHost (sin barra). La URL es la clave de favoritos e
        // historial, asi que una barra de mas los desvincula.
        'host': '$_host/',
        'user': _user,
        'pass': _pass,
        'version': 1,
      });
      expect(items.single.url, '$_host/movie/$_user/$_pass/759216.mkv');
      expect(items.single.url, isNot(contains('//movie/')));
    });
  });

  group('Rechazo del snapshot (el que llama cae al panel)', () {
    test('versión distinta a la soportada devuelve lista vacía', () {
      final vod = _vodBase()..['v'] = 2;
      final items = parseSnapshotEnSegundoPlano(
        _entrada(vod: vod, series: _seriesBase()),
      );
      // Vacío = CatalogSnapshotService devuelve null = se usa el panel. Es
      // preferible a interpretar un formato que esta versión no conoce.
      expect(items, isEmpty);
    });

    test('si UNA de las dos listas es inválida se rechaza todo', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(vod: _vodBase(), series: {'v': 1}..['v'] = 99),
      );
      // Con solo las películas el usuario creería que perdió las series.
      expect(items, isEmpty);
    });

    test('JSON que no es un objeto se rechaza', () {
      final items = parseSnapshotEnSegundoPlano({
        'vod': '[]',
        'series': jsonEncode(_seriesBase()),
        'host': _host,
        'user': _user,
        'pass': _pass,
        'version': 1,
      });
      expect(items, isEmpty);
    });
  });

  group('Datos sucios', () {
    test('items sin id o malformados se descartan sin tirar el resto', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: _vodBase(items: [
            {'i': '1', 'n': 'Buena', 'e': 'mkv', 'c': '42'},
            {'n': 'Sin id', 'e': 'mkv', 'c': '42'},
            {'i': '', 'n': 'Id vacío', 'e': 'mkv', 'c': '42'},
          ]),
          series: _seriesBase(items: []),
        ),
      );
      expect(items.length, 1);
      expect(items.single.name, 'Buena');
    });

    test('item sin nombre usa el mismo texto que el parser del panel', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: _vodBase(items: [
            {'i': '1', 'e': 'mkv', 'c': '42'},
          ]),
          series: _seriesBase(items: []),
        ),
      );
      expect(items.single.name, 'Sin nombre');
    });

    test('acentos y no-ASCII sobreviven intactos', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(
          vod: _vodBase(items: [
            {'i': '1', 'n': 'El Niño y la Garza — 君たちはどう生きるか',
             'e': 'mkv', 'c': '42'},
          ]),
          series: _seriesBase(items: []),
        ),
      );
      expect(items.single.name, 'El Niño y la Garza — 君たちはどう生きるか');
      expect(items.single.category, 'Acción');
    });

    test('catálogo vacío no crashea', () {
      final items = parseSnapshotEnSegundoPlano(
        _entrada(vod: _vodBase(items: []), series: _seriesBase(items: [])),
      );
      expect(items, isEmpty);
    });
  });
}
