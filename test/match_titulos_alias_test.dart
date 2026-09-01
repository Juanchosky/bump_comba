import 'package:flutter_test/flutter_test.dart';

import 'package:bump_comba/services/m3u_service.dart';

/// Fila de la BD (custom_content) con sus alias declarados.
M3UItem bd(String titulo, {List<String> alias = const []}) => M3UItem(
      name: titulo,
      url: 'https://bd.example/x.mp4',
      category: 'Recomendados',
      sourceName: 'Supabase',
      titleAliases: alias,
    );

/// Item tal y como llega del proveedor Xtream.
M3UItem xtream(String titulo) => M3UItem(
      name: titulo,
      url: 'http://prov.example/movie/u/p/1.mp4',
      category: 'Peliculas',
    );

void main() {
  group('Match entre la BD y Xtream con titulos alternativos', () {
    test('sin alias, una traduccion NO coincide (es el limite conocido)', () {
      // No es un fallo: "The First Avenger" y "El primer vengador" no comparten
      // ni una palabra. Esta prueba fija el motivo por el que existen los alias.
      expect(
        coincideAlgunTituloParaPruebas(
          bd('Capitán América: El primer vengador'),
          xtream('Captain America: The First Avenger'),
        ),
        isFalse,
      );
    });

    test('con el alias en ingles, engancha la copia en ingles', () {
      final fila = bd(
        'Capitán América: El primer vengador',
        alias: ['Captain America: The First Avenger'],
      );
      expect(
        coincideAlgunTituloParaPruebas(
          fila,
          xtream('Captain America: The First Avenger'),
        ),
        isTrue,
      );
    });

    test('y la copia en espanol sigue enganchando con el mismo alias', () {
      // Este es el caso que se perdia al sustituir el titulo por el ingles:
      // arreglabas una copia y rompias la otra. Con alias enganchan las dos.
      final fila = bd(
        'Capitán América: El primer vengador',
        alias: ['Captain America: The First Avenger'],
      );
      expect(
        coincideAlgunTituloParaPruebas(
          fila,
          xtream('Capitan America El Primer Vengador'),
        ),
        isTrue,
      );
    });

    test('los alias no aflojan el match: otra pelicula sigue sin coincidir', () {
      final fila = bd(
        'Capitán América: El primer vengador',
        alias: ['Captain America: The First Avenger'],
      );
      expect(
        coincideAlgunTituloParaPruebas(
          fila,
          xtream('Captain America: Civil War'),
        ),
        isFalse,
      );
    });

    test('ni unen secuelas distintas', () {
      final fila = bd('Avengers', alias: ['Los Vengadores']);
      expect(
        coincideAlgunTituloParaPruebas(fila, xtream('Avengers 2')),
        isFalse,
      );
    });

    // ── Alias REALES devueltos por TMDB ──────────────────────────────────
    //
    // No son inventados: son la salida literal de `alias-tmdb.sh` para esta
    // pelicula. La automatizacion mete varios alias por titulo, algunos cortos
    // y genericos ("Captain America"), asi que hay que demostrar que eso no
    // genera falsos positivos con el resto de la saga.
    final capiTmdb = bd(
      'Capitán América: The First Avenger (2011)',
      alias: const [
        'Capitán América: El primer vengador',
        'Captain America: The First Avenger',
        "Marvel's Captain America - The First Avenger",
        "Marvel Studios' Captain America: The First Avenger",
        'Captain America',
      ],
    );

    test('con los alias de TMDB engancha la copia en espanol', () {
      expect(
        coincideAlgunTituloParaPruebas(
          capiTmdb,
          xtream('Capitan America El Primer Vengador'),
        ),
        isTrue,
      );
    });

    test('y tambien la inglesa', () {
      expect(
        coincideAlgunTituloParaPruebas(
          capiTmdb,
          xtream('Captain America: The First Avenger'),
        ),
        isTrue,
      );
    });

    test('el alias generico "Captain America" NO arrastra Civil War', () {
      expect(
        coincideAlgunTituloParaPruebas(
          capiTmdb,
          xtream('Captain America: Civil War'),
        ),
        isFalse,
      );
    });

    test('ni El Soldado de Invierno, en ninguno de los dos idiomas', () {
      expect(
        coincideAlgunTituloParaPruebas(
          capiTmdb,
          xtream('Captain America: The Winter Soldier'),
        ),
        isFalse,
      );
      expect(
        coincideAlgunTituloParaPruebas(
          capiTmdb,
          xtream('Capitán América y el Soldado del Invierno'),
        ),
        isFalse,
      );
    });

    test('sin alias el comportamiento es identico al de antes', () {
      expect(
        coincideAlgunTituloParaPruebas(
          bd('Capitán América: El primer vengador'),
          xtream('Capitan America - El Primer Vengador (2011) 1080p'),
        ),
        isTrue,
      );
    });

    test('getAlternativesFor resuelve alternativas directamente si el item las trae o por match', () {
      final itemConAlts = xtream('Spider-Man').copyWith(
        alternatives: [bd('Spider-Man')],
      );
      final alts = M3UService().getAlternativesFor(itemConAlts);
      expect(alts.isNotEmpty, isTrue);
      expect(alts.first.url, 'https://bd.example/x.mp4');
    });
  });
}
