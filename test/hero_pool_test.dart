import 'package:bump_comba/models/m3u_item.dart';
import 'package:bump_comba/utils/hero_pool.dart';
import 'package:flutter_test/flutter_test.dart';

M3UItem it(String n) =>
    M3UItem(name: n, url: 'u/$n', logo: 'l', category: 'c', isLive: false);

void main() {
  test('determinista dentro de la sesion', () {
    final pool = List.generate(15, (i) => it('Titulo $i (2026)'));
    final a = destacadoDeTendencia(pool);
    for (var k = 0; k < 50; k++) {
      expect(destacadoDeTendencia(pool)!.name, a!.name);
    }
    expect(pool.take(6).map((e) => e.name), contains(a!.name));
  });

  test('sin repetidos aunque el pool pese 3x', () {
    final base = [it('A (2026)'), it('B (2026)'), it('C (2025)')];
    final pesado = [
      base[0], base[0], base[0], base[1], base[1], base[1], base[2],
    ];
    final tres = destacadosDeTendencia(pesado, 3);
    expect(tres.length, 3);
    expect(tres.map((e) => e.name).toSet().length, 3);
  });

  test('descarta lo que no tiene caratula ni lo live', () {
    final pool = [
      M3UItem(name: 'Sin logo', url: 'a', category: 'c', isLive: false),
      M3UItem(name: 'Canal', url: 'b', logo: 'l', category: 'c', isLive: true),
      it('Bueno (2026)'),
    ];
    expect(destacadoDeTendencia(pool)!.name, 'Bueno (2026)');
  });
}
