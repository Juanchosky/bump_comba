import 'package:flutter_test/flutter_test.dart';

import 'package:bump_comba/services/tv/tv_mpv_config.dart';

void main() {
  bool malo({
    int ancho = 1280,
    int alto = 720,
    required double mbps,
    double fps = 24,
  }) => TvMpvConfig.caudalInsuficiente(
    ancho: ancho,
    alto: alto,
    bitsPorSegundo: mbps * 1000000,
    fps: fps,
  );

  group('Cuando el caudal no da para evitar macrobloques', () {
    test('un 720p con caudal normal no se toca', () {
      // 4 Mbps son 0,18 bits por pixel: imagen limpia.
      expect(malo(mbps: 4.0), isFalse);
      expect(malo(mbps: 2.0), isFalse, reason: 'justo, pero no malo');
    });

    test('un 720p hambriento si dispara el cambio', () {
      expect(malo(mbps: 1.2), isTrue);
      expect(malo(mbps: 0.8), isTrue);
    });

    test('el umbral se adapta a la resolucion, no es una cifra fija', () {
      // ESTE es el punto: 1,2 Mbps es poco para 720p y de sobra para 480p.
      // Con un umbral fijo se cambiaria de servidor en contenido que esta
      // perfectamente bien.
      expect(malo(ancho: 1280, alto: 720, mbps: 1.2), isTrue);
      expect(malo(ancho: 854, alto: 480, mbps: 1.2), isFalse);
    });

    test('y a los fotogramas por segundo', () {
      // El mismo caudal rinde la mitad al doble de fotogramas.
      expect(malo(mbps: 2.0, fps: 24), isFalse);
      expect(malo(mbps: 2.0, fps: 48), isTrue);
    });

    test('sin datos NO se cambia de servidor', () {
      // Lo prudente por defecto: un dato que falta no es una fuente mala, y
      // cambiar de servidor le cuesta al usuario un corte.
      expect(
        TvMpvConfig.caudalInsuficiente(
          ancho: null,
          alto: 720,
          bitsPorSegundo: 1000000,
        ),
        isFalse,
      );
      expect(
        TvMpvConfig.caudalInsuficiente(
          ancho: 1280,
          alto: 720,
          bitsPorSegundo: null,
        ),
        isFalse,
      );
      expect(
        TvMpvConfig.caudalInsuficiente(ancho: 0, alto: 0, bitsPorSegundo: 0),
        isFalse,
      );
    });
  });
}
