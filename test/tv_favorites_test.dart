import 'package:flutter_test/flutter_test.dart';
import 'package:bump_comba/services/m3u_service.dart';

void main() {
  group('TV Favoritos y Mi Lista', () {
    test('M3UItem conserva estado de favorito y propiedades al clonar', () {
      final item = M3UItem(
        name: 'Inception',
        url: 'https://cdn.example.com/inception.mp4',
        category: 'Ciencia Ficción',
        isFavorite: true,
        logo: 'https://cdn.example.com/poster.jpg',
      );

      expect(item.isFavorite, isTrue);
      expect(item.name, equals('Inception'));

      final itemCopia = item.copyWith(isFavorite: false);
      expect(itemCopia.isFavorite, isFalse);
      expect(itemCopia.name, equals('Inception'));
      expect(itemCopia.url, equals(item.url));
    });

    test('Identificación unívoca de favoritos para películas y series', () {
      final favList = <M3UItem>[
        M3UItem(
          name: 'Breaking Bad',
          seriesName: 'Breaking Bad',
          url: 'uuid-series-1',
          category: 'Series',
          isSeries: true,
          isFavorite: true,
        ),
        M3UItem(
          name: 'Interstellar',
          url: 'https://cdn.example.com/interstellar.mp4',
          category: 'Películas',
          isFavorite: true,
        ),
      ];

      final buscada = M3UItem(
        name: 'Breaking Bad',
        seriesName: 'Breaking Bad',
        url: 'uuid-series-1',
        category: 'Series',
        isSeries: true,
      );

      final existe = favList.any((f) {
        if (buscada.isSeries || buscada.seriesName != null) {
          final n1 = (buscada.seriesName ?? buscada.name).toLowerCase().trim();
          final n2 = (f.seriesName ?? f.name).toLowerCase().trim();
          if (n1 == n2) return true;
        }
        return (f.url.isNotEmpty && f.url == buscada.url) ||
            f.name.toLowerCase().trim() == buscada.name.toLowerCase().trim();
      });

      expect(existe, isTrue);
    });
  });
}
