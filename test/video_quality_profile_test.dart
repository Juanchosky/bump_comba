import 'package:flutter_test/flutter_test.dart';
import 'package:bump_comba/services/m3u_service.dart';

void main() {
  group('Perfil de Calidad de Video y Escenas Oscuras', () {
    test('esDeLaBD reconoce todos los contenidos de la BD para aplicar perfil de alta calidad', () {
      final itemSupa = M3UItem(
        name: 'Turner & Hooch E1',
        url: 'https://play.cuevana19.com/es/detail/drama/s6zRVRSlnwiYobIrIEdtO-Turner--Hooch[Audio-Latino]/1',
        category: 'Drama',
        sourceName: 'Supabase',
      );
      final itemBD = M3UItem(
        name: 'Turner & Hooch E2',
        url: 'https://play.cuevana19.com/es/detail/drama/s6zRVRSlnwiYobIrIEdtO-Turner--Hooch[Audio-Latino]/2',
        category: 'Drama',
        sourceName: 'BD (Más rápida)',
      );
      final itemV2 = M3UItem(
        name: 'Turner & Hooch E3',
        url: 'https://play.cuevana19.com/es/detail/drama/s6zRVRSlnwiYobIrIEdtO-Turner--Hooch[Audio-Latino]/3',
        category: 'Drama',
        sourceName: 'V2 (Servidor)',
      );

      expect(itemSupa.esDeLaBD, isTrue);
      expect(itemBD.esDeLaBD, isTrue);
      expect(itemV2.esDeLaBD, isTrue);
    });
  });
}
