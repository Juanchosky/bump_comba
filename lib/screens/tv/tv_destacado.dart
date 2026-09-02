import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/fast_image_service.dart';
import '../../services/m3u_service.dart';
import '../../utils/titulo_tmdb.dart';

/// La cabecera del catálogo: un mosaico de seis huecos.
///
/// ── LA FORMA ───────────────────────────────────────────────────────────────
///
///     +---------------+---------------+
///     |   GRANDE 0    |   GRANDE 1    |   <- dos apaisadas, media pantalla
///     |  (se pasa     |    (fija)     |
///     |    sola)      |               |
///     +---------------+---------------+
///     |  título de lo que tenga el foco   |
///     +-------+-------+-------+-------+
///     |   2   |   3   |   4   |   5   |   <- cuatro pequeñas, pegadas
///     +-------+-------+-------+-------+
///
/// El hueco de arriba a la izquierda NO es un título fijo: va pasando varios
/// solo, y las rayitas de su esquina dicen por cuál va. Los otros cinco sí lo
/// son.
///
/// ── POR QUÉ UN MOSAICO Y NO UNA PORTADA ────────────────────────────────────
///
/// Una portada única enseña un título y esconde el resto detrás de una flecha.
/// Así se ven seis a la vez y con jerarquía: los dos de arriba mandan por
/// tamaño, los cuatro de abajo acompañan. Se lee de un vistazo en lugar de
/// leerse de uno en uno.
class TvDestacado extends StatefulWidget {
  /// Los títulos de la cabecera.
  ///
  /// Hacen falta [titulosNecesarios] para llenarla; con menos, los huecos que
  /// sobran se quedan vacíos en vez de reordenar el mosaico.
  final List<M3UItem> items;

  /// Cuál está seleccionado. Sirve para volver al mismo sitio al regresar.
  final int indice;

  /// La imagen apaisada de cada título, en el mismo orden que [items].
  ///
  /// La resuelve el catálogo contra TMDB. Puede haber huecos: un título sin
  /// imagen sale como caja oscura con su nombre, que es mejor que meter la
  /// carátula vertical del proveedor recortada a la fuerza.
  final List<String?> imagenes;

  /// ¿Están ya todas las imágenes?
  ///
  /// Mientras es `false` se pintan siluetas en lugar de las portadas.
  ///
  /// Las fichas de TMDB llegan en cadena y tardan, así que hay un rato largo
  /// sin nada. Dejar el sitio en blanco parecía que la app se había colgado;
  /// las siluetas dicen "esto viene ahora" y de paso enseñan la forma del
  /// mosaico antes de que llegue.
  ///
  /// Se rellenan las seis A LA VEZ, no según van llegando: ver piezas
  /// aparecer a destiempo es justo lo que se quiere evitar.
  final bool listo;

  /// Abrir el título `i` de [items].
  final ValueChanged<int> onElegir;

  /// El foco se movió al título `i` de [items].
  final ValueChanged<int> onIndice;

  /// Bajar a la primera fila de carátulas.
  final VoidCallback onAbajo;

  /// Izquierda desde la primera columna: se vuelve al menú lateral.
  final VoidCallback onSalirIzquierda;

  /// El foco entró o salió de la cabecera.
  final ValueChanged<bool> onFoco;

  const TvDestacado({
    super.key,
    required this.items,
    required this.indice,
    required this.imagenes,
    required this.listo,
    required this.onElegir,
    required this.onIndice,
    required this.onAbajo,
    required this.onSalirIzquierda,
    required this.onFoco,
  });

  /// Huecos del mosaico: 2 grandes + 4 pequeñas.
  static const int huecos = 6;

  /// Cuántos títulos se turnan en el hueco de arriba a la izquierda.
  static const int rotantes = 3;

  /// Títulos que consume la cabecera entera.
  ///
  /// Los que se turnan ocupan UN hueco entre todos, de ahí el `- 1`.
  static const int titulosNecesarios = huecos + rotantes - 1;

  /// Cada cuánto pasa al siguiente el hueco que se turna.
  static const Duration cadaTurno = Duration(seconds: 8);

  /// Separación entre huecos: la mínima.
  ///
  /// Las seis piezas casi se tocan, que es lo que las hace leerse como UN
  /// bloque —la cabecera— en vez de como seis tarjetas puestas cerca. Con 6
  /// se veía la rendija y el conjunto no cuajaba; con 0, dos portadas de
  /// colores parecidos se fundían en una sola imagen.
  ///
  /// 3 es la raya justa para distinguir dónde acaba una y empieza otra, sin
  /// llegar a separarlas.
  static const double hueco = 3;

  /// Márgenes.
  ///
  /// El izquierdo es el mismo que el de los títulos de las filas de abajo: las
  /// dos cosas tienen que empezar en la misma vertical.
  ///
  /// EL DERECHO NO ES CERO, aunque el mosaico deba llegar al filo.
  ///
  /// Un televisor recorta los bordes de la imagen —el "overscan"—, así que lo
  /// que la app dibuja pegado al borde derecho el panel se lo come: se veía
  /// cortado por fuera de la pantalla. 40 es la reserva habitual para eso.
  ///
  /// No es aire de diseño; es el trozo que el televisor no enseña.
  static const double margenIzq = 106;
  static const double margenDer = 40;

  /// Aire por arriba del mosaico.
  ///
  /// Con 24 el bloque quedaba pegado al filo de arriba y se leía como si se
  /// hubiera desbordado por ahí. 48 le da sitio para respirar.
  static const double margenSup = 48;

  /// Aire por abajo, entre el mosaico y la primera categoría.
  ///
  /// Sobraban más de cien píxeles y ahora quedaban pegados: sin nada de aire,
  /// el título de la primera fila parece parte del mosaico en vez del
  /// principio de otra cosa. Esto es lo justo para que se separen.
  static const double margenInf = 26;

  /// Tope de alto. El mosaico no pasa de aquí ni aunque la pantalla dé para
  /// más: por encima se comería la primera fila de carátulas.
  ///
  /// FIJO Y CONOCIDO porque el desplazamiento vertical se CALCULA: la fila `i`
  /// vive en `altura + i * altoFila`. Si esto midiera lo que le apeteciera, el
  /// catálogo volvería a moverse a tientas.
  ///
  /// Y AHORA MANDA ELLA: el mosaico se ajusta para caber aquí dentro, no al
  /// revés. Antes salía de multiplicar anchuras, y como el ancho disponible
  /// cambia con el menú lateral, el bloque acababa más alto que lo reservado
  /// y empujaba las categorías de abajo fuera de la pantalla.
  static const double alturaMaxima = 470;

  /// Lo que ocupa DE VERDAD con un ancho dado.
  ///
  /// ── POR QUÉ NO ES UNA CONSTANTE ───────────────────────────────────────
  ///
  /// Lo era, y sobraba sitio. Las piezas se dimensionan por el ANCHO —media
  /// anchura útil en 16:9—, así que en un panel estrecho salen más bajas y el
  /// hueco reservado se quedaba grande: entre el mosaico y "Últimamente
  /// nuevo" aparecía una franja vacía de más de cien píxeles.
  ///
  /// Reservando lo que de verdad mide, esa franja desaparece sola en
  /// cualquier pantalla, en vez de tener que acertar un número fijo que solo
  /// vale para un televisor.
  static double alturaPara(double anchoDisponible) {
    final util = anchoDisponible - margenIzq - margenDer;
    final porAncho = (util - hueco) / 2 * 9 / 16;
    // Las pequeñas miden la mitad que las grandes, así que las dos filas
    // juntas son una vez y media la grande.
    final porAlto = (alturaMaxima - margenSup) / 1.5;
    final altoGrande = porAncho < porAlto ? porAncho : porAlto;
    return margenSup + altoGrande * 1.5 + margenInf;
  }

  @override
  State<TvDestacado> createState() => TvDestacadoState();
}

class TvDestacadoState extends State<TvDestacado> {
  /// Un nodo por HUECO, no por título: los que se turnan comparten sitio.
  final List<FocusNode> _nodos = List.generate(
    TvDestacado.huecos,
    (i) => FocusNode(debugLabel: 'destacado$i'),
  );

  int _foco = -1; // -1 = ninguno

  /// Por cuál de los que se turnan va el hueco 0.
  int _turno = 0;
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    _reloj = Timer.periodic(TvDestacado.cadaTurno, (_) {
      if (!mounted) return;
      // ── NO SE MUEVE MIENTRAS LO MIRAS ─────────────────────────────────
      //
      // Con el foco encima, cambiar el título significaría que OK abre algo
      // distinto de lo que estabas mirando. Con un mando, donde el foco es lo
      // único que orienta, eso es abrir la película equivocada.
      if (_foco == 0) return;
      setState(() => _turno = (_turno + 1) % _rotantesReales);
    });
  }

  @override
  void dispose() {
    _reloj?.cancel();
    for (final n in _nodos) {
      n.dispose();
    }
    super.dispose();
  }

  /// Cuántos se turnan de verdad: si llegaron menos títulos de los que caben,
  /// se turnan los que haya.
  int get _rotantesReales {
    final sobrantes = widget.items.length - (TvDestacado.huecos - 1);
    return sobrantes.clamp(1, TvDestacado.rotantes);
  }

  /// Qué título le toca al hueco `h`.
  ///
  /// El hueco 0 se lo reparten los que se turnan; los demás van detrás, en
  /// orden. `null` si todavía no hay título para ese hueco — con el catálogo a
  /// medio cargar es lo normal.
  int? _indiceDe(int h) {
    final i = h == 0 ? _turno : _rotantesReales + h - 1;
    return i < widget.items.length ? i : null;
  }

  /// Pone el foco en la cabecera.
  void enfocar() {
    // En el hueco donde esté lo último elegido, si sigue a la vista; si no, en
    // el primero.
    for (var h = 0; h < TvDestacado.huecos; h++) {
      if (_indiceDe(h) == widget.indice) {
        _nodos[h].requestFocus();
        return;
      }
    }
    _nodos.first.requestFocus();
  }

  bool get tieneFoco => _foco >= 0;

  /// A dónde lleva cada flecha desde cada hueco.
  ///
  /// Escrito como tabla y no como una cadena de `if`: el mosaico tiene una
  /// forma concreta —dos arriba, cuatro abajo— y los saltos se entienden mucho
  /// mejor viéndolos juntos que deduciéndolos de condiciones sueltas.
  ///
  ///  · Bajar desde una grande lleva a la pequeña que tiene DEBAJO, no siempre
  ///    a la primera: la izquierda cubre las pequeñas 2 y 3, la derecha las 4
  ///    y 5.
  ///  · Subir desde una pequeña devuelve a la grande de su mitad.
  ///  · `null` es "aquí no hay nada", y lo resuelve quien llama: saliendo al
  ///    menú lateral o bajando a las filas del catálogo.
  static const Map<int, ({int? izq, int? der, int? arr, int? aba})> _saltos = {
    0: (izq: null, der: 1, arr: null, aba: 2),
    1: (izq: 0, der: null, arr: null, aba: 4),
    2: (izq: null, der: 3, arr: 0, aba: null),
    3: (izq: 2, der: 4, arr: 0, aba: null),
    4: (izq: 3, der: 5, arr: 1, aba: null),
    5: (izq: 4, der: null, arr: 1, aba: null),
  };

  void _irA(int? h) {
    if (h == null) return;
    if (_indiceDe(h) == null) return; // hueco vacío: no se va ahí
    _nodos[h].requestFocus();
  }

  KeyEventResult _tecla(int h, KeyEvent evento) {
    if (evento is! KeyDownEvent && evento is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = evento.logicalKey;
    final salto = _saltos[h]!;

    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA) {
      // Con la tecla mantenida no se repite: abrir la ficha cinco veces por
      // dejar el dedo puesto no lo quiere nadie.
      if (evento is KeyRepeatEvent) return KeyEventResult.handled;
      final i = _indiceDe(h);
      if (i != null) widget.onElegir(i);
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowRight) {
      _irA(salto.der);
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      if (salto.izq == null) {
        widget.onSalirIzquierda();
      } else {
        _irA(salto.izq);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowDown) {
      // Si abajo no hay hueco —o el que hay está vacío— se sale a las filas
      // del catálogo, que es lo que uno espera al seguir bajando.
      final abajo = salto.aba;
      if (abajo == null || _indiceDe(abajo) == null) {
        widget.onAbajo();
      } else {
        _irA(abajo);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowUp) {
      _irA(salto.arr);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _cambioFoco(int h, bool tiene) {
    final antes = _foco >= 0;
    if (tiene) {
      _foco = h;
      final i = _indiceDe(h);
      if (i != null) widget.onIndice(i);
    } else if (_foco == h) {
      _foco = -1;
    }
    if (mounted) setState(() {});

    final ahora = _foco >= 0;
    if (antes != ahora) widget.onFoco(ahora);
  }

  /// Sin las marcas del proveedor: en pantalla se leía "Obsesión (2026)", con
  /// el año repetido. El mismo limpiado que se le manda a TMDB sirve para
  /// enseñarlo.
  String _titulo(int i) =>
      limpiarTituloParaTmdb(widget.items[i].seriesName ?? widget.items[i].name);

  String? _imagen(int i) =>
      i < widget.imagenes.length ? widget.imagenes[i] : null;

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox(height: TvDestacado.alturaMaxima);
    }

    return LayoutBuilder(
      builder: (context, restricciones) {
        // Las medidas se CALCULAN del ancho disponible en vez de fijarse a
        // mano, para que el mosaico salga igual de proporcionado en un panel
        // de 1080p que en uno de 720p.
        final util =
            restricciones.maxWidth -
            TvDestacado.margenIzq -
            TvDestacado.margenDer;
        // 16:9, la proporción de las imágenes apaisadas de TMDB. Con
        // cualquier otra saldrían franjas negras o recortes.
        //
        // SE MIRA EL ANCHO **Y** EL ALTO, y manda el que menos deje.
        //
        // Con solo el ancho, el bloque crecía hasta donde le diera la
        // anchura disponible y se comía el sitio de las filas de abajo:
        // "Últimamente nuevo" quedaba fuera de la pantalla. Ajustándolo
        // también al alto reservado, el mosaico es todo lo grande que puede
        // ser sin invadir lo que viene debajo.
        final porAncho = (util - TvDestacado.hueco) / 2 * 9 / 16;
        // Las pequeñas miden la mitad que las grandes, así que las dos filas
        // juntas son una vez y media la grande.
        final porAlto =
            (TvDestacado.alturaMaxima - TvDestacado.margenSup) / 1.5;
        final altoGrande = math.min(porAncho, porAlto);

        final anchoGrande = altoGrande * 16 / 9;
        final anchoChica = (anchoGrande * 2 - TvDestacado.hueco * 2) / 4;
        final altoChica = anchoChica * 9 / 16;

        return Padding(
          padding: const EdgeInsets.only(
            top: TvDestacado.margenSup,
            bottom: TvDestacado.margenInf,
            left: TvDestacado.margenIzq,
            right: TvDestacado.margenDer,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Las dos grandes ──────────────────────────────────────
              Row(
                children: [
                  _tarjeta(0, anchoGrande, altoGrande),
                  const SizedBox(width: TvDestacado.hueco),
                  _tarjeta(1, anchoGrande, altoGrande),
                ],
              ),

              const SizedBox(height: TvDestacado.hueco),

              // ── Las cuatro pequeñas ──────────────────────────────────
              Row(
                children: [
                  for (var h = 2; h < TvDestacado.huecos; h++) ...[
                    _tarjeta(h, anchoChica, altoChica),
                    if (h != TvDestacado.huecos - 1)
                      const SizedBox(width: TvDestacado.hueco),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tarjeta(int h, double ancho, double alto) {
    final i = _indiceDe(h);
    if (i == null) {
      // Sin título todavía: se deja el sitio marcado y vacío. Que el mosaico
      // cambie de forma según van llegando los datos se ve peor que un hueco
      // oscuro un momento.
      return SizedBox(width: ancho, height: alto);
    }

    return _Tarjeta(
      nodo: _nodos[h],
      ancho: ancho,
      alto: alto,
      imagen: _imagen(i),
      titulo: _titulo(i),
      conFoco: _foco == h,
      // LA SILUETA VA DENTRO DE LA PIEZA, no en lugar de ella.
      //
      // Estaba en su sitio, como widget aparte, y eso dejaba el mosaico SIN
      // NODOS DE FOCO mientras cargaba: el mando no encontraba dónde
      // agarrarse y la navegación se volvía impredecible justo en los
      // primeros segundos.
      //
      // Metiéndola dentro, la pieza es la misma con foco, teclas y borde;
      // solo cambia lo que se pinta.
      cargando: !widget.listo,
      // Las rayitas solo en el hueco que se turna: en los fijos no habría nada
      // que contar.
      total: h == 0 ? _rotantesReales : 0,
      posicion: _turno,
      onTecla: (e) => _tecla(h, e),
      onFoco: (v) => _cambioFoco(h, v),
    );
  }
}

/// Un hueco del mosaico.
class _Tarjeta extends StatelessWidget {
  final FocusNode nodo;
  final double ancho;
  final double alto;
  final String? imagen;
  final String titulo;
  final bool conFoco;

  /// Todavía no hay portada: se pinta la silueta.
  final bool cargando;

  /// Cuántos se turnan aquí. 0 o 1 = no se turna, así que sin rayitas.
  final int total;
  final int posicion;

  final KeyEventResult Function(KeyEvent) onTecla;
  final ValueChanged<bool> onFoco;

  const _Tarjeta({
    required this.nodo,
    required this.ancho,
    required this.alto,
    required this.imagen,
    required this.titulo,
    required this.conFoco,
    required this.cargando,
    required this.total,
    required this.posicion,
    required this.onTecla,
    required this.onFoco,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: nodo,
      onFocusChange: onFoco,
      // OK se lee directo de la tecla, como en el resto del televisor: con el
      // mando, `Actions`/`Intents` no llegan.
      onKeyEvent: (node, evento) => onTecla(evento),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: ancho,
        height: alto,
        decoration: const BoxDecoration(color: Color(0xFF15151A)),
        // EL BORDE VA POR ENCIMA, no alrededor.
        //
        // Como borde normal empujaría el contenido hacia dentro al aparecer, y
        // la imagen daría un tirón de tres píxeles cada vez que se mueve el
        // foco. En un mosaico, además, un borde que ocupa sitio descuadraría
        // la rejilla entera.
        foregroundDecoration: BoxDecoration(
          border: Border.all(
            color: conFoco ? Colors.white : Colors.transparent,
            // 2, el mismo grosor que el foco de las carátulas del catálogo.
            // El foco tiene que verse igual en toda la pantalla: si aquí es
            // más grueso, parece que la cabecera usa otro sistema.
            width: 2,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── EL HUECO MIENTRAS NO HAY PORTADA ──────────────────────────
            //
            // Una caja oscura y QUIETA. Antes latía —seis piezas subiendo y
            // bajando de brillo a la vez— y eso era lo que se veía raro al
            // arrancar: parecía que la pantalla estuviera fallando, no
            // cargando.
            //
            // Y cuando llega la portada, entra fundiéndose en vez de aparecer
            // de golpe. Seis cambios secos simultáneos dan un salto; medio
            // segundo de fundido lo convierte en algo que se posa.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              child:
                  cargando || imagen == null || imagen!.isEmpty
                      ? const ColoredBox(
                        key: ValueKey('vacio'),
                        color: Color(0xFF15151A),
                      )
                      : FastThumbnail(
                        key: const ValueKey('portada'),
                        url: imagen!,
                        width: ancho,
                        height: alto,
                        // El servicio reescribe las URLs de TMDB; sin esta
                        // marca la imagen llegaría a 185 px de ancho para un
                        // hueco de 550.
                        pantallaCompleta: true,
                      ),
            ),

            // ── EL TÍTULO, DENTRO Y SOLO EN LA SELECCIONADA ───────────────
            //
            // Dentro y no fuera: fuera ocupaba una franja entre las dos filas
            // y partía el bloque en dos. Pegado al filo, con el aire justo
            // para que la letra no toque el borde.
            //
            if (!cargando)
              // SIEMPRE, no solo con el foco. Muchas portadas del proveedor no
              // traen el nombre impreso, o lo traen en un idioma distinto al del
              // catálogo, así que sin el rótulo hay piezas que no se sabe qué
              // son hasta pasar el mando por encima.
              //
              // El velo oscuro va DEBAJO del texto: una portada clara —un cielo,
              // una nieve— se come la letra blanca. Solo el tramo de abajo, para
              // no ensuciar la imagen.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    padding: EdgeInsets.fromLTRB(10, 26, 10, 8),
                    // El velo, más suave. Estaba casi opaco y se veía como una
                    // banda negra pegada al pie de cada pieza; ahora solo
                    // oscurece lo justo para que la letra se lea.
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0x8A000000)],
                      ),
                    ),
                    child: Text(
                      titulo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // NO blanco puro. El rótulo es una ayuda, no el asunto
                        // de la pieza: a plena intensidad compite con la portada
                        // y en seis piezas a la vez cansa la vista. Bajado, se
                        // lee igual pero deja de llamar.
                        color: Colors.white.withValues(alpha: 0.72),
                        // EL MISMO CUERPO EN LAS SEIS.
                        //
                        // Las grandes lo llevaban a 19 y las pequeñas a 14, para
                        // reforzar la jerarquía. Pero el rótulo no es el título
                        // de la pieza: es una etiqueta que dice qué hay ahí, y
                        // una etiqueta que cambia de tamaño según dónde caiga se
                        // lee como un descuido. El tamaño de las imágenes ya
                        // marca la jerarquía de sobra.
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),

            // Por cuál de los que se turnan va. Visible siempre, con foco o
            // sin él: es lo que avisa de que ese hueco no es fijo.
            if (!cargando && total > 1)
              Positioned(
                right: 10,
                bottom: 34,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      for (var i = 0; i < total; i++) ...[
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          width: i == posicion ? 16 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color:
                                i == posicion
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        if (i != total - 1) const SizedBox(width: 5),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
