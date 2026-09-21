import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bump_comba/services/filtro_calidad_service.dart';
import 'package:bump_comba/services/tv/tv_mpv_config.dart';

void main() {
  final filtro = FiltroCalidadService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await filtro.init();
  });

  group('A que nivel entra el filtro', () {
    test('una fuente de 1080p o mas no se toca', () {
      expect(filtro.nivelPara(1080), NivelRealce.ninguno);
      expect(filtro.nivelPara(2160), NivelRealce.ninguno);
      // 721 ya esta por encima del corte: el filtro es para lo que NO llega.
      expect(filtro.nivelPara(721), NivelRealce.ninguno);
    });

    test('sin imagen todavia no se filtra a ciegas', () {
      expect(filtro.nivelPara(0), NivelRealce.ninguno);
      expect(filtro.nivelPara(-1), NivelRealce.ninguno);
    });

    test('720p entra en suave', () {
      expect(filtro.nivelPara(720), NivelRealce.suave);
    });

    test('la variante ligera de 960x520 y el 540p entran en medio', () {
      expect(filtro.nivelPara(540), NivelRealce.medio);
      expect(filtro.nivelPara(520), NivelRealce.medio);
    });

    test('480p y por debajo entran en fuerte', () {
      expect(filtro.nivelPara(480), NivelRealce.fuerte);
      expect(filtro.nivelPara(360), NivelRealce.fuerte);
    });
  });

  group('El filtro de capa', () {
    test('no devuelve filtro cuando no hay nada que realzar', () {
      expect(filtro.filtroDeColor(1080), isNull);
      expect(filtro.filtroDeColor(0), isNull);
    });

    test('devuelve filtro para una fuente limitada', () {
      expect(filtro.filtroDeColor(720), isA<ColorFilter>());
      expect(filtro.filtroDeColor(480), isA<ColorFilter>());
    });

    test('no hay forma de apagarlo: va solo y siempre', () {
      // No existe interruptor a proposito. Si alguien anade uno, este test
      // deja de compilar y hay que pensarlo dos veces.
      expect(filtro.filtroDeColor(480), isA<ColorFilter>());
      expect(filtro.filtroDeColor(720), isA<ColorFilter>());
    });
  });

  group('El tope de bitrate', () {
    test('sin saber el techo, no se toca nada', () {
      expect(filtro.hlsBitratePara('https://ejemplo.com/peli'), isNull);
      expect(filtro.hlsBitratePara(null), isNull);
    });

    test(
      'si la fuente llega a 1080p, el tope de siempre sigue mandando',
      () async {
        await filtro.anotarAltura('https://ejemplo.com/buena', 1080);
        expect(filtro.hlsBitratePara('https://ejemplo.com/buena'), isNull);
      },
    );

    test('si la fuente topa en 720p se levanta el tope', () async {
      await filtro.anotarAltura('https://ejemplo.com/limitada', 720);
      expect(filtro.hlsBitratePara('https://ejemplo.com/limitada'), 'max');
    });

    test('en la TV, el escalon del scrapeado se salta con fuente de 720p', () {
      // Sin saber el techo: se aplica el escalon de 6 Mbps de siempre.
      expect(TvMpvConfig.hlsBitrate(esScrapeado: true), '6000000');
      // Sabiendo que no hay 1080p al que irse, ese escalon no frena nada.
      expect(
        TvMpvConfig.hlsBitrate(esScrapeado: true, techoFuente: 720),
        isNot('6000000'),
      );
      // Y con una fuente que si da 1080p se queda como estaba.
      expect(
        TvMpvConfig.hlsBitrate(esScrapeado: true, techoFuente: 1080),
        '6000000',
      );
    });
  });

  group('El registro de techos', () {
    test('se queda con la mayor altura vista, no con la ultima', () async {
      // En HLS carga primero la variante ligera y sube despues: lo que
      // interesa guardar es el techo, no el arranque.
      await filtro.anotarAltura('u', 520);
      await filtro.anotarAltura('u', 720);
      await filtro.anotarAltura('u', 520);
      expect(filtro.techoConocido('u'), 720);
    });

    test('guarda el nombre para poder ensenar la lista', () async {
      await filtro.anotarAltura('u', 720, nombre: 'Una Pelicula');
      expect(filtro.techosObservados['u']?.nombre, 'Una Pelicula');
    });

    test('rellena el nombre que falta sin perder el techo', () async {
      await filtro.anotarAltura('u', 720);
      await filtro.anotarAltura('u', 540, nombre: 'Una Pelicula');
      expect(filtro.techoConocido('u'), 720);
      expect(filtro.techosObservados['u']?.nombre, 'Una Pelicula');
    });

    test('la lista de limitadas va de la peor a la mejor', () async {
      await filtro.anotarAltura('a', 720, nombre: 'Siete Veinte');
      await filtro.anotarAltura('b', 480, nombre: 'Cuatro Ochenta');
      await filtro.anotarAltura('c', 1080, nombre: 'Mil Ochenta');
      final lista = filtro.fuentesLimitadas();
      expect(lista.map((t) => t.altura), [480, 720]);
      expect(lista.first.nombre, 'Cuatro Ochenta');
    });

    test('un titulo estable no cuenta ninguna vez por debajo', () async {
      await filtro.anotarAltura('u', 720);
      await filtro.anotarAltura('u', 720);
      expect(filtro.techosObservados['u']?.vecesPorDebajo, 0);
      expect(filtro.techosObservados['u']?.esInconsistente, isFalse);
      expect(filtro.fuentesInconsistentes(), isEmpty);
    });

    test('subir el techo no cuenta como haberse quedado corto', () async {
      // La primera vez que se ve algo no hay con que comparar: que la altura
      // suba de 520 a 720 es el arranque normal de HLS, no una recaida.
      await filtro.anotarAltura('u', 520);
      await filtro.anotarAltura('u', 720);
      expect(filtro.techosObservados['u']?.vecesPorDebajo, 0);
    });

    test('salir por debajo de un techo ya conocido si cuenta', () async {
      await filtro.anotarAltura('u', 720, nombre: 'La Carrera');
      // Otra reproduccion, y esta vez el scraper se queda con la ligera.
      await filtro.anotarAltura('u', 520);
      final t = filtro.techosObservados['u'];
      expect(t?.altura, 720, reason: 'el techo no baja');
      expect(t?.ultima, 520, reason: 'pero la ultima si');
      expect(t?.vecesPorDebajo, 1);
      expect(t?.esInconsistente, isTrue);
      expect(filtro.fuentesInconsistentes().map((x) => x.nombre), [
        'La Carrera',
      ]);
    });

    test('la lista de inconsistentes va de peor a mejor', () async {
      await filtro.anotarAltura('a', 720, nombre: 'Una Vez');
      await filtro.anotarAltura('a', 520);
      await filtro.anotarAltura('b', 720, nombre: 'Tres Veces');
      await filtro.anotarAltura('b', 520);
      await filtro.anotarAltura('b', 480);
      await filtro.anotarAltura('b', 520);
      expect(filtro.fuentesInconsistentes().map((x) => x.nombre), [
        'Tres Veces',
        'Una Vez',
      ]);
    });

    test('el contador de recaidas sobrevive a reiniciar la app', () async {
      await filtro.anotarAltura('u', 720, nombre: 'La Carrera');
      await filtro.anotarAltura('u', 520);
      await filtro.init();
      final t = filtro.techosObservados['u'];
      expect(t?.altura, 720);
      expect(t?.ultima, 520);
      expect(t?.vecesPorDebajo, 1);
    });

    test('sobrevive a reiniciar la app', () async {
      await filtro.anotarAltura('u', 540, nombre: 'Una Pelicula');
      // Otra instancia del servicio leyendo las mismas prefs.
      await filtro.init();
      expect(filtro.techoConocido('u'), 540);
      expect(filtro.techosObservados['u']?.nombre, 'Una Pelicula');
    });

    test(
      'lee el formato viejo, en el que solo se guardaba la altura',
      () async {
        SharedPreferences.setMockInitialValues({
          'filtro_calidad_techos': '{"v":1,"t":{"u":720},"o":["u"]}',
        });
        await filtro.init();
        expect(filtro.techoConocido('u'), 720);
        expect(filtro.techosObservados['u']?.nombre, isNull);
      },
    );

    test('un registro corrupto no tumba nada', () async {
      SharedPreferences.setMockInitialValues({
        'filtro_calidad_techos': 'esto no es json',
      });
      await filtro.init();
      expect(filtro.techosObservados, isEmpty);
    });
  });

  group('El shader de desbloqueo', () {
    test('se enchufa en los ajustes cuando hay ruta', () {
      final a = filtro.ajustesMpvNivel2(rutaShader: '/datos/desbloqueo.glsl');
      expect(a['glsl-shaders'], '/datos/desbloqueo.glsl');
      // Y el escalador sigue ahi: el shader limpia y el escalador estira
      // DESPUES, sobre la imagen ya limpia.
      expect(a['scale'], 'ewa_lanczossharp');
      expect(a['deband'], 'yes');
    });

    test('sin ruta se aplica el resto y no se inventa la clave', () {
      final a = filtro.ajustesMpvNivel2();
      expect(a.containsKey('glsl-shaders'), isFalse);
      expect(a['scale'], 'ewa_lanczossharp');
    });

    test('al volver al camino de hardware se suelta el shader', () {
      // Vacio y no ausente: si se queda el de antes puesto, mpv lo sigue
      // intentando cargar donde no puede y llena el log de errores.
      expect(filtro.ajustesMpvSinRealce()['glsl-shaders'], '');
      expect(filtro.ajustesMpvSinRealce()['scale'], 'bilinear');
    });
  });

  group('Cuando se permite el nivel 2', () {
    test(
      'sin haberlo probado nunca, se intenta: ese intento es la prueba',
      () async {
        await filtro.anotarAltura('u', 720);
        expect(filtro.veredictoNivel2, VeredictoNivel2.sinProbar);
        expect(filtro.permiteNivel2('u', intento: 0), isTrue);
      },
    );

    test('en la primera reproduccion de un titulo no se arriesga', () async {
      // Nunca visto: no hay techo apuntado, asi que podria ser un 1080p.
      expect(filtro.permiteNivel2('desconocida', intento: 0), isFalse);
    });

    test('si ya se esta reintentando, no se pide mas trabajo', () async {
      await filtro.anotarAltura('u', 720);
      expect(filtro.permiteNivel2('u', intento: 1), isFalse);
      expect(filtro.permiteNivel2('u', intento: 2), isFalse);
    });

    test(
      'con una fuente de 1080p no se activa: ese es el caso del ANR',
      () async {
        await filtro.anotarAltura('u', 1080);
        expect(filtro.permiteNivel2('u', intento: 0), isFalse);
      },
    );

    test('un aparato descartado no se vuelve a examinar', () async {
      await filtro.anotarAltura('u', 720);
      await filtro.descartarNivel2('prueba');
      expect(filtro.veredictoNivel2, VeredictoNivel2.noApto);
      expect(filtro.permiteNivel2('u', intento: 0), isFalse);
      // Y sigue descartado tras reiniciar.
      await filtro.init();
      expect(filtro.veredictoNivel2, VeredictoNivel2.noApto);
      expect(filtro.permiteNivel2('u', intento: 0), isFalse);
    });
  });

  group('El canario que examina el aparato solo', () {
    test('un intento confirmado deja el aparato aprobado', () async {
      await filtro.anotarAltura('u', 720);
      await filtro.marcarNivel2EnPrueba();
      expect(filtro.veredictoNivel2, VeredictoNivel2.probando);
      await filtro.confirmarNivel2Estable();
      expect(filtro.veredictoNivel2, VeredictoNivel2.apto);
      // Aprobado sobrevive al reinicio y sigue permitiendo el nivel 2.
      await filtro.init();
      expect(filtro.veredictoNivel2, VeredictoNivel2.apto);
      expect(filtro.permiteNivel2('u', intento: 0), isTrue);
    });

    test('un intento que NO vuelve descarta el aparato al arrancar', () async {
      await filtro.anotarAltura('u', 720);
      await filtro.marcarNivel2EnPrueba();
      // Aqui es donde el ANR mataria el proceso: nadie llega a confirmar.
      // El arranque siguiente encuentra la senal sin borrar.
      await filtro.init();
      expect(filtro.veredictoNivel2, VeredictoNivel2.noApto);
      expect(filtro.permiteNivel2('u', intento: 0), isFalse);
    });

    test('un aparato ya aprobado no se vuelve a marcar en prueba', () async {
      await filtro.marcarNivel2EnPrueba();
      await filtro.confirmarNivel2Estable();
      await filtro.marcarNivel2EnPrueba();
      expect(filtro.veredictoNivel2, VeredictoNivel2.apto);
      // Y por tanto un cierre forzoso posterior no lo descalifica.
      await filtro.init();
      expect(filtro.veredictoNivel2, VeredictoNivel2.apto);
    });

    test('salir del video antes de tiempo NO condena al aparato', () async {
      // Este es el caso que se vio en un telefono de verdad: el nivel 2 entro,
      // el usuario cerro el video (o hubo un hot restart) antes de los 20 s, y
      // el arranque siguiente lo marcaba `noApto` para siempre. Una salida
      // limpia no ha demostrado nada y tiene que poder reintentarse.
      await filtro.anotarAltura('u', 720);
      await filtro.marcarNivel2EnPrueba();
      expect(filtro.veredictoNivel2, VeredictoNivel2.probando);

      await filtro.cancelarPruebaNivel2();
      expect(filtro.veredictoNivel2, VeredictoNivel2.sinProbar);

      // Y tras reiniciar sigue pudiendo intentarlo.
      await filtro.init();
      expect(filtro.veredictoNivel2, VeredictoNivel2.sinProbar);
      expect(filtro.permiteNivel2('u', intento: 0), isTrue);
    });

    test('cancelar no toca un veredicto ya decidido', () async {
      await filtro.marcarNivel2EnPrueba();
      await filtro.confirmarNivel2Estable();
      await filtro.cancelarPruebaNivel2();
      expect(filtro.veredictoNivel2, VeredictoNivel2.apto);

      await filtro.descartarNivel2('prueba');
      await filtro.cancelarPruebaNivel2();
      expect(filtro.veredictoNivel2, VeredictoNivel2.noApto);
    });

    test('confirmar sin haber marcado nada no aprueba de rebote', () async {
      await filtro.confirmarNivel2Estable();
      expect(filtro.veredictoNivel2, VeredictoNivel2.sinProbar);
    });

    test('un descarte reciente aguanta el reinicio', () async {
      await filtro.descartarNivel2('prueba');
      await filtro.init();
      expect(filtro.veredictoNivel2, VeredictoNivel2.noApto);
    });

    test('un descarte viejo CADUCA y se vuelve a intentar', () async {
      // Un `noApto` permanente es demasiado fragil para una decision tomada
      // con una sola observacion: en un telefono de verdad, un stream con el
      // token caducado dejo el realce apagado para siempre en un aparato que
      // ya habia demostrado decodificar a 24 fps.
      await filtro.descartarNivel2('prueba');
      expect(filtro.veredictoNivel2, VeredictoNivel2.noApto);

      // Se envejece el descarte mas alla de la cuarentena.
      final viejo =
          DateTime.now()
              .subtract(FiltroCalidadService.cuarentenaDescarte * 2)
              .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'filtro_calidad_nivel2_veredicto_v3': VeredictoNivel2.noApto.index,
        'filtro_calidad_nivel2_descarte': viejo,
      });

      await filtro.init();
      expect(filtro.veredictoNivel2, VeredictoNivel2.sinProbar);
    });

    test('un descarte sin fecha se da por caducado', () async {
      // Un veredicto escrito por una version anterior no trae fecha. Mejor
      // reintentarlo que arrastrar un descarte del que no se sabe nada.
      SharedPreferences.setMockInitialValues({
        'filtro_calidad_nivel2_veredicto_v3': VeredictoNivel2.noApto.index,
      });
      await filtro.init();
      expect(filtro.veredictoNivel2, VeredictoNivel2.sinProbar);
    });

    test('un aparato aprobado que empieza a fallar se descarta', () async {
      await filtro.marcarNivel2EnPrueba();
      await filtro.confirmarNivel2Estable();
      await filtro.descartarNivel2('se congelo');
      expect(filtro.veredictoNivel2, VeredictoNivel2.noApto);
    });
  });
}
