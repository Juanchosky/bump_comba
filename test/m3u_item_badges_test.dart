// Distintivos "BD" y "ENG" del detalle de contenido.
//
// Los dos getters que se prueban aquí deciden qué ve el usuario ANTES de darle
// al play, y los dos tienen una trampa concreta:
//
//   · esDeLaBD      → la etiqueta se renombró de 'V2' a 'BD', pero `sourceName`
//                     se guarda en la caché binaria. Los catálogos ya cacheados
//                     siguen trayendo 'V2' tras actualizar la app.
//   · esAudioIngles → "eng" aparece dentro de palabras normales ("Venganza"),
//                     así que comparar con `contains` marcaría como inglés
//                     contenido que está en español.

import 'package:bump_comba/models/m3u_item.dart';
import 'package:flutter_test/flutter_test.dart';

M3UItem _item({String? fuente, String categoria = 'Estrenos 2026'}) =>
    M3UItem(
      name: 'Peli',
      url: 'http://x/1.mkv',
      category: categoria,
      sourceName: fuente,
    );

void main() {
  group('esDeLaBD', () {
    test('reconoce la etiqueta nueva', () {
      expect(_item(fuente: 'BD (Más rápida)').esDeLaBD, isTrue);
    });

    test('reconoce la etiqueta VIEJA que quedó en cachés ya guardadas', () {
      // Sin esto, tras actualizar la app los usuarios con catálogo cacheado se
      // quedarían sin distintivo y sin alternativas hasta la próxima recarga.
      expect(_item(fuente: 'V2 (Más rápida)').esDeLaBD, isTrue);
    });

    test('reconoce el item propio recién traído de Supabase', () {
      expect(_item(fuente: 'Supabase').esDeLaBD, isTrue);
    });

    test('Xtream y sin fuente no son de la BD', () {
      expect(_item(fuente: 'Xtream').esDeLaBD, isFalse);
      expect(_item(fuente: null).esDeLaBD, isFalse);
    });
  });

  group('esAudioIngles', () {
    test('detecta el formato que se usa al subir contenido', () {
      expect(_item(categoria: 'Estrenos 2026 | Eng').esAudioIngles, isTrue);
    });

    test('acepta variantes de escritura y espaciado', () {
      for (final c in [
        'Estrenos 2026|ENG',
        'Estrenos 2026 |  eng  ',
        'Accion / English',
        'Accion - Ingles',
        'Accion | Inglés',
      ]) {
        expect(_item(categoria: c).esAudioIngles, isTrue, reason: c);
      }
    });

    test('NO marca "Venganza" ni otras palabras que contienen "eng"', () {
      // El caso que rompería un `contains('eng')`: contenido en español
      // marcado como inglés por el título de su categoría.
      for (final c in [
        'Venganza',
        'Estrenos 2026 | Venganza',
        'Thriller de venganza',
        'Engaños',
      ]) {
        expect(_item(categoria: c).esAudioIngles, isFalse, reason: c);
      }
    });

    test('una categoría normal en español no lleva distintivo', () {
      for (final c in ['Estrenos 2026', 'Acción', 'Terror | Latino', '']) {
        expect(_item(categoria: c).esAudioIngles, isFalse, reason: c);
      }
    });
  });

  group('Combinación: solo se avisa de inglés si es de la BD', () {
    test('BD + categoría Eng → las dos condiciones se cumplen', () {
      final i = _item(fuente: 'BD (Más rápida)', categoria: 'Estrenos | Eng');
      expect(i.esDeLaBD && i.esAudioIngles, isTrue);
    });

    test('Xtream con "Eng" en la categoría no dispara el aviso', () {
      // El distintivo solo tiene sentido para lo que se sube a la BD: es ahí
      // donde se marca el idioma a mano.
      final i = _item(fuente: 'Xtream', categoria: 'Estrenos | Eng');
      expect(i.esDeLaBD && i.esAudioIngles, isFalse);
    });
  });
}
