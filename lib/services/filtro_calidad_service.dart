import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'performance_service.dart';

/// Cuanto realce pide una fuente, segun lo baja que sea.
///
/// El corte esta en 720: por encima de ahi no se toca NADA. Una pelicula que
/// ya llega a 1080p no necesita ayuda y cualquier filtro que se le ponga solo
/// puede empeorarla, asi que el filtro entero se queda dormido para ella.
enum NivelRealce {
  /// Fuente de 1080p o mas: el filtro no actua.
  ninguno,

  /// 720p justo. Es lo mas comun en esta base de datos.
  suave,

  /// La franja de 540p / 960x520 — la variante `-ld` que publican estas
  /// paginas antes de la buena.
  medio,

  /// 480p o menos.
  fuerte,
}

/// Lo que se ha observado de una fuente: a cuanto llega y de que titulo era.
///
/// El nombre se guarda solo para poder ENSENAR la lista. La clave del registro
/// es la URL, que es lo unico estable, pero una pantalla llena de URLs no le
/// dice nada a nadie.
class TechoFuente {
  const TechoFuente({
    required this.altura,
    this.nombre,
    this.ultima = 0,
    this.vecesPorDebajo = 0,
  });

  /// Altura maxima en pixeles que se le ha visto decodificar. Este es el
  /// techo: lo que el proveedor da cuando todo sale bien.
  final int altura;

  /// Nombre del titulo tal y como aparecia en el catalogo.
  final String? nombre;

  /// Altura de la ULTIMA vez que se reprodujo.
  final int ultima;

  /// Cuantas veces se resolvio por debajo de su techo.
  ///
  /// PARA QUE SIRVE ESTE CONTADOR
  /// Para separar dos problemas que se ven igual — "borroso" — y no tienen
  /// nada que ver:
  ///
  ///  · `vecesPorDebajo == 0` y techo de 720: el proveedor no tiene mas. No
  ///    hay nada que rascar por el lado de la fuente.
  ///  · `vecesPorDebajo > 0`: el mismo titulo ha salido unas veces bien y
  ///    otras mal. Eso NO es un limite del proveedor, es la carrera del
  ///    scraper, y es la unica de las dos que se puede arreglar.
  ///
  /// Es tambien la forma de comprobar si la deduccion de variantes hermanas
  /// esta haciendo su trabajo: si funciona, este contador deja de subir.
  final int vecesPorDebajo;

  /// Esta fuente no da para mas: es de las que el filtro tiene que realzar.
  bool get esLimitada => altura <= 720;

  /// El mismo titulo se ha resuelto con calidades distintas segun el dia.
  bool get esInconsistente => vecesPorDebajo > 0;
}

/// Que se sabe sobre si ESTE aparato aguanta el nivel 2.
///
/// Es una propiedad del equipo, no del contenido, asi que se decide una vez y
/// se recuerda para siempre.
enum VeredictoNivel2 {
  /// Nunca se ha intentado. La proxima fuente limitada sirve de prueba.
  sinProbar,

  /// Se acaba de lanzar un intento y todavia no ha vuelto a confirmar que
  /// fuera bien.
  ///
  /// QUE SIGNIFICA ENCONTRAR ESTO AL ARRANCAR
  /// Que el intento anterior no llego a confirmarse — la app se fue por el
  /// camino malo: ANR, cierre forzoso, o el usuario harto de ver un video
  /// congelado. Esa es justo la firma del fallo que hay que evitar, y por eso
  /// encontrarlo aqui cuenta como un NO.
  probando,

  /// Probado y aguanta. Se aplica siempre que toque.
  apto,

  /// Probado y no aguanta, o no se pudo confirmar. No se vuelve a intentar.
  noApto,
}

/// FILTRO DE CALIDAD PARA FUENTES QUE NO PASAN DE 720p
///
/// EL PROBLEMA QUE RESUELVE
/// La base de datos tiene mucho titulo cuyo maximo REAL es 720p — no es que el
/// scraper elija mal, es que la fuente no da mas (comprobado abriendo las
/// listas maestras). En una pantalla de 1080p o 4K ese fotograma se estira con
/// el escalador del compositor de Android, que es un bilineal simple, y se ve
/// blando y con bandas en los degradados.
///
/// POR QUE NO VALE PONER `scale` Y `deband` Y LISTO
/// Ya se intento el 2026-09-09 y no cambio nada. Con `hwdec: mediacodec` el
/// fotograma va del decodificador a la Surface de Android sin pasar por la
/// cadena de shaders de MPV, asi que `scale`, `cscale`, `deband` y compania se
/// aceptan sin protestar y se ignoran. `setProperty` no devuelve error: es un
/// fallo silencioso.
///
/// LOS DOS NIVELES
/// De ahi que el filtro tenga dos caminos, y que el primero no dependa de MPV:
///
/// - **Nivel 1 — filtro de capa.** Un `ColorFilter` colgado del arbol de capas
///   de Flutter. Lo aplica el motor al componer la textura del video, asi que
///   le da igual por donde venga el fotograma: funciona con `mediacodec` tal
///   cual esta hoy. Sube contraste y saturacion en la medida justa para que un
///   720p comprimido deje de verse lavado. No inventa detalle — no puede —
///   pero es lo unico que actua siempre y sin riesgo.
///
/// - **Nivel 2 — cadena de shaders de MPV.** Esto si da nitidez y quita
///   bandas de verdad, pero exige `mediacodec-copy` para que el fotograma
///   pase por el renderizador. Y ahi esta el incidente del 2026-08-16: con
///   `-copy` en MediaTek/Motorola se decodificaron 6 fotogramas en 7,5 s y
///   acabo en ANR — ver el comentario largo de la eleccion de decodificador en
///   `video_player_screen.dart`.
///
///   PERO ese incidente fue copiando fotogramas de **1080p**. Un 720p son
///   921.600 pixeles contra 2.073.600: menos de la mitad del trabajo de copia
///   y de subida a la GPU. Por eso el nivel 2 solo se intenta cuando ya se
///   sabe que la fuente no pasa de 720p, y nunca en gama baja.
///
/// TODO ESTO VA SOLO, SIN NADA QUE TOCAR
/// No hay ajuste ni interruptor: el nivel 1 se aplica siempre que la fuente lo
/// pida y el nivel 2 se decide por aparato, examinandolo una vez. Lo que hace
/// posible examinarlo sin pedirle nada al usuario es el canario de
/// [VeredictoNivel2.probando]: la senal se escribe en disco ANTES de
/// arriesgarse, porque el fallo que se teme mata el proceso y no deja momento
/// posterior en el que apuntar nada. Si al arrancar la senal sigue puesta, el
/// intento no volvio y el aparato queda descartado para siempre. Coste maximo:
/// una reproduccion mala, una vez por instalacion.
///
/// COMO SE SABE LA ALTURA ANTES DE ABRIR
/// El nivel 1 reacciona en caliente a `player.state.height`, que llega cuando
/// ya hay imagen. El nivel 2 no puede esperar a eso: cambiar `hwdec` a mitad
/// de la reproduccion reinicia el decodificador y se ve el tiron. Asi que el
/// servicio APUNTA la altura real de cada titulo la primera vez que se ve
/// ([anotarAltura]) y en las siguientes ya la sabe de antemano
/// ([techoConocido]). Primera vez: nivel 1. De la segunda en adelante: el
/// nivel que toque, aplicado desde el `open()`.
///
/// Ese registro es ademas la lista de "que titulos topan de verdad en 720p",
/// que se llena sola con lo que la gente ve y sin gastar una sola peticion
/// extra ([techosObservados]).
class FiltroCalidadService {
  static final FiltroCalidadService _instancia =
      FiltroCalidadService._interno();
  factory FiltroCalidadService() => _instancia;
  FiltroCalidadService._interno();

  static const String _clave = 'filtro_calidad_techos';

  /// El sufijo de version no es decorativo: cada vez que la logica que PRODUCE
  /// el veredicto tenia un fallo, los veredictos viejos son basura y hay que
  /// tirarlos.
  ///
  ///  · `_v2` — la primera version del canario daba por fallido cualquier
  ///    intento que no se confirmara en 20 s, y un cierre normal (salir del
  ///    video, un hot restart) es indistinguible de un ANR desde el arranque
  ///    siguiente.
  ///  · `_v3` — faltaba el margen de arranque: una recarga por un STREAM roto
  ///    —un token caducado, por ejemplo— descalificaba al aparato. Medido en
  ///    un telefono el 2026-09-21: quedo en `noApto` por un stream muerto,
  ///    cuando ese mismo aparato ya habia decodificado a 24 fps con
  ///    `mediacodec-copy`.
  static const String _claveVeredicto = 'filtro_calidad_nivel2_veredicto_v3';

  /// Cuando se descarto el aparato, en milisegundos de epoca.
  static const String _claveDescartadoEn = 'filtro_calidad_nivel2_descarte';

  /// Cuanto dura un descarte antes de volver a intentarlo.
  ///
  /// POR QUE UN DESCARTE CADUCA
  /// Porque `noApto` era PERMANENTE y sin vuelta atras, y eso es demasiado
  /// frágil para una decision que se toma con UNA sola observacion: un stream
  /// roto, un bache de red o un cierre raro bastaban para dejar el realce
  /// apagado en ese aparato hasta reinstalar la app. Paso tres veces mientras
  /// se desarrollaba esto.
  ///
  /// Con una cuarentena, lo peor que puede pasar es una reproduccion mala cada
  /// siete dias — y un aparato descartado por error se cura solo. Siete y no
  /// uno para que un equipo que de verdad no puede no lo pague cada dia.
  static const Duration cuarentenaDescarte = Duration(days: 7);

  /// Cuanto tiene que aguantar un intento del nivel 2 para darlo por bueno.
  ///
  /// 20 s de reproduccion seguida sin congelarse ni reintentar. El fallo que
  /// se teme no es sutil —6 fotogramas en 7,5 s— asi que si va a aparecer,
  /// aparece dentro de esa ventana y de sobra.
  static const Duration margenDePrueba = Duration(seconds: 20);

  /// Cuantos titulos se recuerdan. Pasado el tope se tira el mas antiguo.
  ///
  /// 1500 entradas son ~30 KB de JSON en SharedPreferences. El catalogo tiene
  /// 36.000 items, pero la mayoria son episodios que nadie abre; guardar los
  /// 1500 ultimos vistos cubre de sobra el uso real.
  static const int _tope = 1500;

  SharedPreferences? _prefs;

  /// clave del item (su URL) -> lo observado de esa fuente.
  final Map<String, TechoFuente> _techos = {};

  /// Los mismos ids, del mas viejo al mas reciente, para poder desalojar.
  final List<String> _orden = [];

  VeredictoNivel2 _veredicto = VeredictoNivel2.sinProbar;

  /// Altura de la fuente que se esta viendo ahora mismo, o 0 si aun no hay
  /// imagen. El widget [RealceDeVideo] escucha esto para entrar y salir solo.
  final ValueNotifier<int> alturaActual = ValueNotifier(0);

  /// Lo que se sabe de este aparato respecto al nivel 2.
  VeredictoNivel2 get veredictoNivel2 => _veredicto;

  /// Lo que se ha ido aprendiendo, de solo lectura.
  Map<String, TechoFuente> get techosObservados => Map.unmodifiable(_techos);

  /// Las fuentes que topan en 720p o menos, de la peor a la mejor.
  ///
  /// Esta es la lista que contesta "que titulos estan limitados de verdad", y
  /// se ha llenado sola con lo que se ha visto: ni una peticion de mas al
  /// proveedor. Lo que salga aqui en 540 o 480 es lo que merece que alguien
  /// vaya a buscarle otra fuente.
  ///
  /// No se ensena en ninguna pantalla —el filtro no tiene interfaz— pero se
  /// imprime en el log al reproducir (`"titulo" topa en NNNp`) y se puede
  /// consultar desde aqui cuando haya que decidir que re-scrapear.
  List<TechoFuente> fuentesLimitadas() {
    final lista = _techos.values.where((t) => t.esLimitada).toList();
    lista.sort((a, b) => a.altura.compareTo(b.altura));
    return lista;
  }

  /// Los titulos que se han resuelto con calidades distintas segun el dia, de
  /// mas inconsistente a menos.
  ///
  /// Esta es la lista que importa de las dos: lo que sale aqui NO es un limite
  /// del proveedor —el titulo ha dado su techo alguna vez— sino la carrera del
  /// scraper. Si la deduccion de variantes hermanas hace su trabajo, esta
  /// lista deja de crecer.
  List<TechoFuente> fuentesInconsistentes() {
    final lista = _techos.values.where((t) => t.esInconsistente).toList();
    lista.sort((a, b) => b.vecesPorDebajo.compareTo(a.vecesPorDebajo));
    return lista;
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _cargarTechos();

    final guardado = _prefs?.getInt(_claveVeredicto) ?? 0;
    _veredicto =
        guardado >= 0 && guardado < VeredictoNivel2.values.length
            ? VeredictoNivel2.values[guardado]
            : VeredictoNivel2.sinProbar;

    // LA CUARENTENA DEL DESCARTE.
    //
    // Un `noApto` caduca. Se mira ANTES del canario porque un descarte viejo
    // ya no dice nada del aparato: pudo venir de un stream roto, de un bache
    // de red o de un cierre raro, y dejar el realce apagado para siempre por
    // eso es peor que arriesgar una reproduccion mala cada siete dias.
    if (_veredicto == VeredictoNivel2.noApto) {
      final cuando = _prefs?.getInt(_claveDescartadoEn);
      final caducado =
          cuando == null ||
          DateTime.now()
                  .difference(DateTime.fromMillisecondsSinceEpoch(cuando))
                  .abs() >
              cuarentenaDescarte;
      if (caducado) {
        debugPrint(
          'FiltroCalidad: el descarte de este aparato ha caducado — se '
          'vuelve a intentar',
        );
        await _guardarVeredicto(VeredictoNivel2.sinProbar);
        await _prefs?.remove(_claveDescartadoEn);
      }
    }

    // EL CANARIO.
    //
    // Si el veredicto guardado sigue siendo `probando`, el intento anterior
    // no volvio a decir que fuera bien. Y no volver es exactamente lo que
    // pasa en el caso que se teme: un ANR mata el proceso, asi que NO hay
    // ningun momento posterior en el que apuntar "esto ha ido mal". La unica
    // forma de detectarlo es marcarlo ANTES de arriesgarse y comprobar al
    // arrancar si alguien vino a borrarlo.
    //
    // De ahi que no haga falta que el usuario pruebe nada: el aparato se
    // examina solo, una vez, y como mucho paga una reproduccion mala.
    if (_veredicto == VeredictoNivel2.probando) {
      debugPrint(
        'FiltroCalidad: el intento anterior del nivel 2 no volvio -> '
        'este aparato queda descartado',
      );
      await _guardarVeredicto(VeredictoNivel2.noApto);
    }

    // El shader se saca a disco AHORA, en el arranque de la app y sin esperar
    // a que termine. Asi cuando alguien le de a reproducir ya esta ahi y no
    // hay que pararse a escribir un archivo con el usuario mirando.
    //
    // Si el aparato ya salio descartado no se molesta: no se va a usar.
    if (_veredicto != VeredictoNivel2.noApto) {
      unawaited(rutaDelShaderDesbloqueo());
    }
  }

  Future<void> _guardarVeredicto(VeredictoNivel2 v) async {
    _veredicto = v;
    await _prefs?.setInt(_claveVeredicto, v.index);
    if (v == VeredictoNivel2.noApto) {
      await _prefs?.setInt(
        _claveDescartadoEn,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  void _cargarTechos() {
    _techos.clear();
    _orden.clear();
    final crudo = _prefs?.getString(_clave);
    if (crudo == null || crudo.isEmpty) return;
    try {
      final mapa = jsonDecode(crudo) as Map<String, dynamic>;
      final techos = mapa['t'] as Map<String, dynamic>?;
      final orden = mapa['o'] as List<dynamic>?;
      if (techos == null) return;
      techos.forEach((id, valor) {
        // Se aceptan las dos formas: la de ahora, `{"h": 720, "n": "..."}`, y
        // un entero suelto, que es como se guardaba antes de que la lista
        // necesitara nombres. Asi una actualizacion de la app no tira por la
        // ventana lo que ya se habia aprendido.
        int? alto;
        String? nombre;
        int ultima = 0;
        int porDebajo = 0;
        if (valor is int) {
          alto = valor;
        } else if (valor is Map) {
          final h = valor['h'];
          alto = h is int ? h : int.tryParse('$h');
          final n = valor['n'];
          if (n is String && n.isNotEmpty) nombre = n;
          final u = valor['u'];
          ultima = u is int ? u : (int.tryParse('$u') ?? 0);
          final b = valor['b'];
          porDebajo = b is int ? b : (int.tryParse('$b') ?? 0);
        } else {
          alto = int.tryParse('$valor');
        }
        if (alto != null && alto > 0) {
          _techos[id] = TechoFuente(
            altura: alto,
            nombre: nombre,
            ultima: ultima,
            vecesPorDebajo: porDebajo,
          );
        }
      });
      // El orden manda sobre el mapa: si una entrada esta en el mapa pero no
      // en el orden no habria forma de desalojarla nunca.
      for (final id in orden ?? const []) {
        if (id is String && _techos.containsKey(id)) _orden.add(id);
      }
      for (final id in _techos.keys) {
        if (!_orden.contains(id)) _orden.add(id);
      }
    } catch (e) {
      debugPrint(
        'FiltroCalidad: registro de techos ilegible, se empieza de cero -> $e',
      );
      _techos.clear();
      _orden.clear();
    }
  }

  Future<void> _guardarTechos() async {
    try {
      await _prefs?.setString(
        _clave,
        jsonEncode({
          'v': 3,
          't': {
            for (final e in _techos.entries)
              e.key: {
                'h': e.value.altura,
                if (e.value.nombre != null) 'n': e.value.nombre,
                if (e.value.ultima > 0) 'u': e.value.ultima,
                if (e.value.vecesPorDebajo > 0) 'b': e.value.vecesPorDebajo,
              },
          },
          'o': _orden,
        }),
      );
    } catch (e) {
      debugPrint('FiltroCalidad: no se pudo guardar el registro -> $e');
    }
  }

  /// Altura real que se le vio a este titulo la ultima vez. `null` si no se ha
  /// visto nunca — primera reproduccion, el nivel 2 no se arriesga.
  int? techoConocido(String? idItem) {
    if (idItem == null || idItem.isEmpty) return null;
    return _techos[idItem]?.altura;
  }

  /// Apunta la altura que ha reportado el reproductor.
  ///
  /// Se llama con cada cambio de `state.height`, asi que tiene que ser barato
  /// y no escribir a disco si no ha cambiado nada. Se queda con la MAYOR
  /// altura vista: en HLS la primera variante que carga suele ser la ligera y
  /// sube despues, y lo que interesa guardar es el techo, no el arranque.
  Future<void> anotarAltura(
    String? idItem,
    int altura, {
    String? nombre,
  }) async {
    alturaActual.value = altura;
    if (idItem == null || idItem.isEmpty || altura <= 0) return;

    final previa = _techos[idItem];
    final techo = altura > (previa?.altura ?? 0) ? altura : previa!.altura;

    // El contador de "salio por debajo" solo se toca cuando esta reproduccion
    // se queda corta respecto a un techo que YA se conocia. Subir el techo no
    // cuenta como haberse quedado corto antes: la primera vez que se ve un
    // titulo no hay con que comparar.
    final bool seQuedoCorta = previa != null && altura < previa.altura;
    final nueva = TechoFuente(
      altura: techo,
      nombre: nombre ?? previa?.nombre,
      ultima: altura,
      vecesPorDebajo: (previa?.vecesPorDebajo ?? 0) + (seQuedoCorta ? 1 : 0),
    );

    // Nada que guardar si la altura repite y el resto ya estaba puesto. En HLS
    // el mismo valor puede llegar varias veces y no vamos a escribir a disco
    // por cada aviso.
    if (previa != null &&
        previa.altura == nueva.altura &&
        previa.ultima == nueva.ultima &&
        previa.vecesPorDebajo == nueva.vecesPorDebajo &&
        previa.nombre == nueva.nombre) {
      return;
    }

    _techos[idItem] = nueva;
    _orden.remove(idItem);
    _orden.add(idItem);

    while (_orden.length > _tope) {
      _techos.remove(_orden.removeAt(0));
    }

    if (seQuedoCorta) {
      debugPrint(
        'FiltroCalidad: "$idItem" salio a ${altura}p pero su techo es '
        '${techo}p — van ${nueva.vecesPorDebajo} veces por debajo',
      );
    } else {
      debugPrint('FiltroCalidad: "$idItem" topa en ${techo}p');
    }
    await _guardarTechos();
  }

  /// Que nivel de realce pide una altura dada.
  NivelRealce nivelPara(int altura) {
    // 0 = aun no hay imagen. No se filtra a ciegas.
    if (altura <= 0) return NivelRealce.ninguno;
    if (altura > 720) return NivelRealce.ninguno;
    if (altura > 600) return NivelRealce.suave; // 720p
    if (altura > 500) return NivelRealce.medio; // 540p y el 960x520 de `-ld`
    return NivelRealce.fuerte; // 480p y por debajo
  }

  /// El filtro de capa del nivel 1, o `null` si no toca filtrar.
  ///
  /// Solo contraste y saturacion, y con la mano muy quieta. La tentacion es
  /// subir tambien el brillo, pero estas fuentes van llenas de escenas
  /// oscuras: levantar el negro las deja lavadas y se nota mucho mas que la
  /// falta de resolucion. Y pasarse de contraste empasta las sombras, que es
  /// justo donde la compresion ya ha hecho destrozo.
  ColorFilter? filtroDeColor(int altura) {
    final (double contraste, double saturacion) = switch (nivelPara(altura)) {
      NivelRealce.ninguno => (1.0, 1.0),
      NivelRealce.suave => (1.06, 1.05),
      NivelRealce.medio => (1.10, 1.10),
      NivelRealce.fuerte => (1.14, 1.14),
    };

    if (contraste == 1.0 && saturacion == 1.0) return null;
    return ColorFilter.matrix(_matriz(contraste, saturacion));
  }

  /// Matriz 4x5 de contraste por saturacion.
  ///
  /// La saturacion es la matriz estandar que conserva luminancia (pesos de
  /// Rec.709) y el contraste es un escalado alrededor del gris medio:
  /// `salida = c * (S . rgb) + 128 * (1 - c)`. El desplazamiento va en la
  /// quinta columna, que en Flutter se expresa en el rango 0..255.
  static List<double> _matriz(double c, double s) {
    const double lr = 0.2126;
    const double lg = 0.7152;
    const double lb = 0.0722;

    final double inv = 1 - s;
    final double s00 = inv * lr + s;
    final double s01 = inv * lg;
    final double s02 = inv * lb;
    final double s10 = inv * lr;
    final double s11 = inv * lg + s;
    final double s12 = inv * lb;
    final double s20 = inv * lr;
    final double s21 = inv * lg;
    final double s22 = inv * lb + s;

    final double t = 128 * (1 - c);

    return <double>[
      c * s00, c * s01, c * s02, 0, t, //
      c * s10, c * s11, c * s12, 0, t, //
      c * s20, c * s21, c * s22, 0, t, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// El nivel 2 puede entrar para este titulo.
  ///
  /// Hacen falta las cuatro cosas, y si falta una se queda en el nivel 1:
  ///
  /// 1. Que este aparato no haya salido ya descartado.
  /// 2. Que no sea de gama baja. En gama baja la copia a RAM del fotograma es
  ///    exactamente el escenario del ANR del 2026-08-16, y ahi no se prueba
  ///    nada: se da por perdido de entrada.
  /// 3. Que YA se sepa que este titulo no pasa de 720p. En la primera
  ///    reproduccion de algo no se sabe y no se arriesga.
  /// 4. Que sea el primer intento. Si el reproductor ya esta reintentando hay
  ///    un problema de verdad y no es momento de pedirle mas trabajo; la
  ///    escalera de reintentos que ya existe se encarga.
  ///
  /// Con `sinProbar` devuelve `true`: ESE intento es la prueba. Quien lo use
  /// tiene que llamar a [marcarNivel2EnPrueba] antes de abrir y a
  /// [confirmarNivel2Estable] cuando lleve [margenDePrueba] reproduciendo
  /// bien, o el canario del arranque lo dara por fallido.
  /// DICE EN VOZ ALTA POR QUE NO.
  ///
  /// Devolver `false` por cuatro motivos distintos sin decir cual es el mismo
  /// fallo silencioso que ya nos ha costado tres rondas en esta base de
  /// codigo. En un log real el nivel 2 no entraba y no habia forma de saber si
  /// era el veredicto, la gama del aparato o el techo sin medir: ahora se lee.
  bool permiteNivel2(String? idItem, {required int intento}) {
    String? porQueNo;

    if (_veredicto == VeredictoNivel2.noApto) {
      porQueNo = 'este aparato salio descartado en una prueba anterior';
    } else if (intento != 0) {
      porQueNo = 'ya se esta reintentando (intento $intento)';
    } else if (PerformanceService().isLowPerformance) {
      porQueNo = 'aparato de gama baja';
    } else {
      final techo = techoConocido(idItem);
      if (techo == null) {
        porQueNo =
            'no se sabe todavia a cuanto llega esta fuente — se apunta al '
            'reproducirla y entrara la proxima vez';
      } else if (techo > 720) {
        porQueNo = 'la fuente llega a ${techo}p, no necesita realce';
      }
    }

    if (porQueNo != null) {
      debugPrint('FiltroCalidad: nivel 2 NO entra -> $porQueNo');
      return false;
    }
    return true;
  }

  /// Deja la senal en disco ANTES de arriesgarse.
  ///
  /// Tiene que estar escrita antes del `open()`, porque si el aparato se
  /// atraganca ya no habra ocasion de escribir nada. Si el veredicto ya es
  /// `apto` no se toca: ese aparato esta aprobado y no se vuelve a examinar.
  Future<void> marcarNivel2EnPrueba() async {
    if (_veredicto != VeredictoNivel2.sinProbar) return;
    debugPrint('FiltroCalidad: probando el nivel 2 en este aparato');
    await _guardarVeredicto(VeredictoNivel2.probando);
  }

  /// El intento ha sobrevivido: se borra la senal y el aparato queda aprobado.
  Future<void> confirmarNivel2Estable() async {
    if (_veredicto != VeredictoNivel2.probando) return;
    debugPrint('FiltroCalidad: el nivel 2 aguanta en este aparato');
    await _guardarVeredicto(VeredictoNivel2.apto);
  }

  /// La reproduccion termina sin haber podido confirmar, pero de forma LIMPIA.
  ///
  /// POR QUE ESTO ES IMPRESCINDIBLE
  /// El canario del arranque dice "si la marca sigue puesta, el intento no
  /// volvio". Pero hay un monton de formas de no volver que no son un fallo:
  /// el usuario sale del video a los 10 segundos, cierra la app, o se hace un
  /// hot restart mientras se programa. Sin esta llamada, todas ellas condenan
  /// al aparato igual que un ANR — y eso es exactamente lo que paso la primera
  /// vez que se probo esto en un telefono de verdad.
  ///
  /// Se vuelve a `sinProbar`, no a `noApto`: no se ha aprendido nada, asi que
  /// la proxima reproduccion vuelve a intentarlo.
  Future<void> cancelarPruebaNivel2() async {
    if (_veredicto != VeredictoNivel2.probando) return;
    debugPrint(
      'FiltroCalidad: la prueba del nivel 2 acabo antes de tiempo sin fallar '
      '— se reintentara',
    );
    await _guardarVeredicto(VeredictoNivel2.sinProbar);
  }

  /// El intento ha ido mal de una forma que SI se ha podido observar —se
  /// congelo, hubo que reintentar— y no hace falta esperar al canario.
  ///
  /// Descarta el aparato aunque el veredicto fuera ya `apto`: si un equipo
  /// aprobado empieza a fallar (se quedo mas justo de memoria, subio de
  /// resolucion la pantalla) lo que manda es lo que pasa ahora.
  Future<void> descartarNivel2(String motivo) async {
    if (_veredicto == VeredictoNivel2.noApto) return;
    debugPrint('FiltroCalidad: nivel 2 descartado en este aparato -> $motivo');
    await _guardarVeredicto(VeredictoNivel2.noApto);
  }

  /// Ruta en disco del shader, o `null` si no se pudo dejar ahi.
  String? _rutaShader;
  bool _shaderIntentado = false;

  /// La ruta del shader SI YA ESTA LISTA, sin esperar a nada.
  ///
  /// POR QUE ESTO EXISTE Y NO SE LLAMA AL `await` DIRECTAMENTE
  /// Porque sacar el shader del APK cuesta un `rootBundle.loadString`, un
  /// `getApplicationSupportDirectory()` —que es un canal de plataforma— y una
  /// escritura con `flush`, todo en el isolate principal. Puesto en el camino
  /// de `open()` eso es tiempo que el usuario ve como "el video tarda en
  /// arrancar". Se precalienta en [init], segundos antes de que nadie
  /// reproduzca nada, y aqui solo se recoge.
  ///
  /// `null` si todavia no esta: se reproduce sin desbloqueo esta vez (el resto
  /// del nivel 2 se aplica igual) y la siguiente ya lo tendra. Nunca se
  /// bloquea la apertura por un adorno.
  String? get rutaShaderSiYaEsta => _rutaShader;

  /// Deja el shader de desbloqueo en un archivo de verdad y devuelve su ruta.
  ///
  /// POR QUE HAY QUE COPIARLO
  /// `glsl-shaders` de MPV quiere una RUTA de sistema de archivos, y un asset
  /// de Flutter no lo es: vive comprimido dentro del APK y solo se puede leer
  /// por el canal de assets. Asi que se saca una vez al directorio de soporte
  /// de la app y a partir de ahi ya es un archivo normal que mpv puede abrir.
  ///
  /// Se reescribe en cada arranque a proposito, y no solo si no existe: asi una
  /// actualizacion de la app que traiga un shader nuevo no se queda con el
  /// viejo cacheado del APK anterior.
  Future<String?> rutaDelShaderDesbloqueo() async {
    if (_shaderIntentado) return _rutaShader;
    _shaderIntentado = true;
    try {
      final datos = await rootBundle.loadString(
        'assets/shaders/desbloqueo.glsl',
      );
      final dir = await getApplicationSupportDirectory();
      final archivo = File('${dir.path}/desbloqueo.glsl');
      await archivo.writeAsString(datos, flush: true);
      _rutaShader = archivo.path;
      debugPrint('FiltroCalidad: shader de desbloqueo en $_rutaShader');
    } catch (e) {
      // Sin shader se pierde el desbloqueo, pero el resto del nivel 2
      // —escalador sharp, deband— sigue aplicandose igual.
      debugPrint('FiltroCalidad: no se pudo preparar el shader -> $e');
      _rutaShader = null;
    }
    return _rutaShader;
  }

  /// Los ajustes de MPV del nivel 2. Van con `mediacodec-copy`, porque sin el
  /// no se aplica ninguno.
  ///
  /// `deband` es el que mas se nota en este material: las fuentes de 720p a
  /// bitrate corto tienen bandas muy visibles en cielos y paredes, y eso si se
  /// puede arreglar de verdad. El escalador sharp es lo segundo.
  /// `rutaShader` es lo que devuelva [rutaDelShaderDesbloqueo]. Si es `null`
  /// se aplica todo lo demas sin el: el desbloqueo se pierde, pero el
  /// escalador y el `deband` no.
  ///
  /// EL ORDEN DE LO QUE PASA CON EL FOTOGRAMA
  ///  1. `glsl-shaders` corre sobre `LUMA`, con la imagen todavia en su tamaño
  ///     original. Ahi es donde esta la reja de macrobloques y donde se puede
  ///     deshacer.
  ///  2. `scale` la estira a la pantalla. Se hace DESPUES, sobre una imagen ya
  ///     limpia, que es la unica forma de que un escalador sharp no se dedique
  ///     a resaltar los cuadrados.
  ///  3. `deband` remata los degradados.
  /// Imprime lo que MPV cree de verdad sobre el fotograma que esta pintando.
  ///
  /// ── POR QUE HACE FALTA MEDIR ESTO ──────────────────────────────────────
  ///
  /// El shader se bajo del 100% al 28% del filtrado y el velo siguio igual.
  /// Eso no es un ajuste corto: es la prueba de que el velo NO lo pone el
  /// shader, y que llevamos rondas tocando la palanca equivocada.
  ///
  /// El sospechoso que si encaja es el RANGO DE COLOR. Con `mediacodec` la
  /// conversion YUV->RGB la hace el compositor de Android; con
  /// `mediacodec-copy` la hace MPV, y los bufers de MediaCodec no traen de
  /// forma fiable si el video es de rango limitado (16-235) o completo
  /// (0-255). Si MPV supone completo en un video limitado, el negro 16 se
  /// pinta como gris: un velo sobre TODA la imagen, desde el primer
  /// fotograma y pase lo que pase con el shader.
  ///
  /// Esto no corrige nada a proposito. Primero hay que saber que dice MPV; si
  /// aqui sale `colorlevels: full`, el arreglo es una linea, y si sale
  /// `limited` hemos descartado la hipotesis con certeza en vez de encadenar
  /// otra suposicion.
  ///
  /// De paso confirma si el shader llego a cargarse: nunca se ha comprobado,
  /// y un `glsl-shaders` vacio significaria que todo este rato el unico que
  /// estaba suavizando era `deband`.
  Future<void> diagnosticoDeImagen(dynamic mpv) async {
    if (mpv == null) return;
    for (final propiedad in const [
      'video-params/colorlevels',
      'video-params/colormatrix',
      'video-params/pixelformat',
      'video-params/w',
      'video-params/h',
      'glsl-shaders',
      'deband',
    ]) {
      try {
        final valor = await mpv.getProperty(propiedad);
        debugPrint('DIAGNOSTICO $propiedad = $valor');
      } catch (e) {
        debugPrint('DIAGNOSTICO $propiedad -> no se pudo leer ($e)');
      }
    }
  }

  Map<String, String> ajustesMpvNivel2({String? rutaShader}) {
    return {
      if (rutaShader != null) 'glsl-shaders': rutaShader,
      'scale': 'ewa_lanczossharp',
      'cscale': 'spline36',
      'dscale': 'mitchell',
      'correct-downscaling': 'yes',

      // ── ESCALADO EN LUZ LINEAL: APAGADO ────────────────────────────────
      //
      // `linear-upscaling` convierte la imagen a luz lineal, la escala y la
      // devuelve a gamma. `sigmoid-upscaling` hace lo mismo con una curva en
      // S. Sobre el papel es mas correcto, y por eso los puse.
      //
      // El problema es que son las DOS UNICAS cosas de esta lista que tocan
      // el tono de la imagen ENTERA. Todo lo demas —el shader, deband,
      // scale— actua por zonas. Y un velo uniforme sobre toda la pantalla,
      // que no se inmuta cuando el shader baja del 100% al 28% de filtrado,
      // solo lo puede poner algo que actue sobre todo por igual.
      //
      // Descartado ya, con el diagnostico del 2026-09-21: NO es el rango de
      // color. MPV lo detecta bien (`colorlevels = limited`, `bt.709`).
      // Tampoco es que el shader no cargue: carga (`glsl-shaders` devuelve la
      // ruta). Quedan estos dos.
      //
      // Lo que se pierde apagandolos es un pelo de correccion en los bordes
      // de alto contraste al ampliar. Lo que se gana, si la hipotesis es
      // buena, es una imagen que no parece vista a traves de una gasa.
      'linear-upscaling': 'no',
      'sigmoid-upscaling': 'no',

      // ── DEBAND: UN POCO, Y A PROPOSITO ─────────────────────────────────
      //
      // Aqui hay que separar dos cosas que se apagaron juntas y NO son lo
      // mismo (2026-09-21, probado en el aparato):
      //
      //  · El escalado en luz lineal era VELO PURO: cambia el tono de toda
      //    la imagen y no esconde nada. Todo coste y ningun beneficio. Fuera
      //    para siempre.
      //
      //  · `deband` SI suaviza de verdad, y por eso tapa bandas y restos de
      //    compresion. Apagandolo desaparecio el velo pero la reproduccion
      //    "se ve muy mal": sin nada que los disimule, los artefactos de una
      //    fuente a bitrate corto quedan al aire.
      //
      // O sea que un poco de suavizado no es un defecto en este material: es
      // parte del acabado. Lo que sobraba era el velo tonal, no este.
      //
      // 1 iteracion y umbral 20: la mitad largo de lo que habia cuando se
      // quejo del velo, y con el escalado lineal ya fuera. Si se ven bandas
      // en cielos, subir el umbral a 32 antes que las iteraciones.
      'deband': 'yes',
      'deband-iterations': '1',
      'deband-threshold': '20',
      'deband-range': '16',
      'dither-depth': 'auto',
    };
  }

  /// Los mismos ajustes, puestos del reves: lo que hay que aplicar para volver
  /// al camino de hardware sin dejar restos a medias.
  Map<String, String> ajustesMpvSinRealce() {
    return const {
      // Vacio, no ausente: si se deja puesto el de antes, mpv lo sigue
      // intentando cargar en el camino de hardware y llena el log de errores.
      'glsl-shaders': '',
      'scale': 'bilinear',
      'cscale': 'bilinear',
      'linear-upscaling': 'no',
      'sigmoid-upscaling': 'no',
      'deband': 'no',
      'dither-depth': 'no',
    };
  }

  /// Techo de bitrate HLS para un titulo cuyo maximo es 720p.
  ///
  /// Devuelve `null` cuando no aplica y hay que dejar el valor de siempre.
  ///
  /// POR QUE ESTO SUBE CALIDAD SIN SUBIR RIESGO
  /// El tope de 3 Mbps del reproductor del telefono se puso, y esta escrito
  /// en el comentario, "para limitar a 720p" y que una conexion modesta no se
  /// fuera a por un 1080p que no puede sostener. Pero si la fuente NO TIENE
  /// 1080p, ese tope ya no protege de nada: lo unico que hace es elegir la
  /// version mas comprimida de las de 720p que hay. Sin 1080p al que irse,
  /// `max` coge el 720p con menos artefactos y el ancho de banda sigue siendo
  /// de 720p.
  String? hlsBitratePara(String? idItem) {
    final techo = techoConocido(idItem);
    if (techo == null || techo > 720) return null;
    return 'max';
  }
}

/// Envuelve el video en el filtro de capa del nivel 1.
///
/// Se pone POR FUERA del `Video` y no dentro: `ColorFiltered` cuelga un
/// `ColorFilterLayer` del arbol, y el motor lo aplica al componer la textura
/// externa. Es por eso que funciona donde los shaders de MPV no: no necesita
/// que el fotograma pase por Dart ni por el renderizador de MPV.
///
/// Cuando no hay nada que filtrar devuelve el hijo pelado, sin capa de mas.
class RealceDeVideo extends StatelessWidget {
  const RealceDeVideo({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final servicio = FiltroCalidadService();
    return ValueListenableBuilder<int>(
      valueListenable: servicio.alturaActual,
      builder: (context, altura, hijo) {
        final filtro = servicio.filtroDeColor(altura);
        if (filtro == null) return hijo!;
        return ColorFiltered(colorFilter: filtro, child: hijo);
      },
      child: child,
    );
  }
}
