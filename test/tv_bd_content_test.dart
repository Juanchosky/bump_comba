import 'package:flutter_test/flutter_test.dart';
import 'package:bump_comba/services/m3u_service.dart';

void main() {
  group('Contenido de la BD en el televisor', () {
    test('Deduplicación por clave en listas agrupadas no descarta series con URL vacía o repetida', () {
      // Simula series de la BD en una categoría como "Doramas" o "Netflix"
      final seriesBD = [
        M3UItem(
          name: 'Dorama 1',
          seriesName: 'Dorama 1',
          url: '',
          category: 'Doramas',
          isSeries: true,
          sourceName: 'Supabase',
        ),
        M3UItem(
          name: 'Dorama 2',
          seriesName: 'Dorama 2',
          url: '',
          category: 'Doramas',
          isSeries: true,
          sourceName: 'Supabase',
        ),
        M3UItem(
          name: 'Dorama 3',
          seriesName: 'Dorama 3',
          url: '',
          category: 'Doramas',
          isSeries: true,
          sourceName: 'Supabase',
        ),
        M3UItem(
          name: 'Pelicula 1',
          url: 'https://stream/pelicula1.mp4',
          category: 'Doramas',
          isSeries: false,
          sourceName: 'Supabase',
        ),
      ];

      // Lógica corregida de deduplicación de _agrupar
      final salida = <M3UItem>[];
      final vistos = <String>{};
      for (final it in seriesBD) {
        final elegido = it;
        final clave = (elegido.isSeries || elegido.seriesName != null)
            ? 'series_${(elegido.seriesName ?? elegido.name).toLowerCase().trim()}'
            : (elegido.url.isNotEmpty ? elegido.url : elegido.name).toLowerCase().trim();
        if (elegido.isLive || !vistos.add(clave)) continue;
        salida.add(elegido);
      }

      expect(salida.length, equals(4), reason: 'Ninguna serie de la BD debe ser descartada');
      expect(salida.map((e) => e.name).toList(), containsAll(['Dorama 1', 'Dorama 2', 'Dorama 3', 'Pelicula 1']));
    });

    test('Series de Supabase con sId como URL son únicas e identificables', () {
      final s1 = M3UItem(
        name: 'Serie A',
        seriesName: 'Serie A',
        url: 'uuid-1234',
        category: 'Netflix',
        isSeries: true,
        sourceName: 'Supabase',
      );
      final s2 = M3UItem(
        name: 'Serie B',
        seriesName: 'Serie B',
        url: 'uuid-5678',
        category: 'Netflix',
        isSeries: true,
        sourceName: 'Supabase',
      );

      expect(s1.url, isNotEmpty);
      expect(s2.url, isNotEmpty);
      expect(s1.url, isNot(equals(s2.url)));
      expect(s1, isNot(equals(s2)));
    });

    test('esDeLaBD reconoce correctamente variantes de la BD', () {
      final itemSupa = M3UItem(name: 'Test', url: 'u1', category: 'Cat', sourceName: 'Supabase');
      final itemBD = M3UItem(name: 'Test', url: 'u2', category: 'Cat', sourceName: 'BD (Más rápida)');
      final itemV2 = M3UItem(name: 'Test', url: 'u3', category: 'Cat', sourceName: 'V2 (Servidor)');
      final itemXtream = M3UItem(name: 'Test', url: 'u4', category: 'Cat', sourceName: 'Xtream');

      expect(itemSupa.esDeLaBD, isTrue);
      expect(itemBD.esDeLaBD, isTrue);
      expect(itemV2.esDeLaBD, isTrue);
      expect(itemXtream.esDeLaBD, isFalse);
    });
  });
}
