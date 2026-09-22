import 'package:flutter_test/flutter_test.dart';

import 'package:bump_comba/services/tv/tv_mpv_config.dart';

void main() {
  group('El filtro de bucle del codec en la TV', () {
    test('con una fuente de 720p NO se salta nada', () {
      // El filtro de bucle es el desbloqueador que H.264 lleva dentro.
      // Saltarselo es apagar el antibloques del codec, y en la TV no hay
      // plan B: el shader necesita `mediacodec-copy`, que este SoC no
      // aguanta. Con 720p hay holgura de sobra para no saltarse nada.
      final o = TvMpvConfig.opcionesDeDecodificacion(720);
      expect(o['vd-lavc-skiploopfilter'], 'none');
      expect(o['vd-lavc-fast'], 'no');
    });

    test('con 1080p se mantiene el ahorro de siempre', () {
      final o = TvMpvConfig.opcionesDeDecodificacion(1080);
      expect(o['vd-lavc-skiploopfilter'], 'nonref');
      expect(o['vd-lavc-fast'], 'yes');
    });

    test('sin saber el techo no se arriesga', () {
      // La primera reproduccion de un titulo no tiene techo apuntado. Ahi se
      // supone lo peor, que es lo que protege la fluidez.
      for (final techo in <int?>[null, 0, -1]) {
        expect(
          TvMpvConfig.opcionesDeDecodificacion(techo)['vd-lavc-skiploopfilter'],
          'nonref',
          reason: 'con techo $techo no se debe asumir holgura',
        );
      }
    });
  });
}
