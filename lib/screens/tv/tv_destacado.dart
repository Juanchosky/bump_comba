import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/fast_image_service.dart';
import '../../services/m3u_service.dart';
import '../../utils/titulo_tmdb.dart';

/// El destacado que abre el catálogo: imagen grande, título y dos botones.
///
/// POR QUÉ ARRIBA Y A PANTALLA COMPLETA
/// Una rejilla de carátulas no propone nada: enseña sesenta cosas iguales y
/// deja la decisión entera al usuario. El destacado hace lo que hace la
/// portada de un periódico — decir "empieza por aquí" — y de paso le da a la
/// pantalla un punto de entrada obvio para el foco.
///
/// LO QUE NO HACE
/// No rota mientras estás mirando las filas. Una imagen que cambia sola
/// mientras miras otra cosa es una distracción, no una función: solo pasa al
/// siguiente cuando el foco está aquí arriba.
class TvDestacado extends StatefulWidget {
  /// Los títulos que se van turnando. Salen de la primera fila de la sección.
  final List<M3UItem> items;

  /// Índice del que se está enseñando ahora.
  final int indice;

  /// Datos de TMDB del título actual: sinopsis, año, clasificación, imagen
  /// apaisada. Llega tarde y puede no llegar: la cabecera se pinta igual.
  final Map<String, dynamic>? ficha;

  /// TMDB todavia no ha contestado para este titulo.
  ///
  /// Mientras es cierto NO se enseña la caratula del proveedor. Esa caratula
  /// es VERTICAL y el hueco del banner es apaisado, asi que entraba recortada
  /// —"cortada", como se veia— y un segundo despues la sustituia la imagen
  /// buena. Dos imagenes distintas seguidas se ven como un fallo. Mejor el
  /// hueco oscuro un momento y luego la imagen definitiva, ya bien.
  final bool esperandoFicha;

  final VoidCallback onReproducir;
  final VoidCallback onFicha;

  /// Bajar a la primera fila de carátulas.
  final VoidCallback onAbajo;

  /// Pasar al siguiente destacado. Se llama al pulsar derecha desde el último
  /// botón: es la forma de recorrer los cinco sin un control aparte.
  final VoidCallback onSiguiente;

  /// Izquierda desde el primer botón: se vuelve al menú lateral.
  final VoidCallback onSalirIzquierda;

  /// El foco acaba de entrar o salir del destacado. El padre lo usa para
  /// arrancar y parar el turno de títulos.
  final ValueChanged<bool> onFoco;

  const TvDestacado({
    super.key,
    required this.items,
    required this.indice,
    required this.ficha,
    this.esperandoFicha = false,
    required this.onReproducir,
    required this.onFicha,
    required this.onAbajo,
    required this.onSiguiente,
    required this.onSalirIzquierda,
    required this.onFoco,
  });

  /// Alto reservado en la lista del catálogo.
  ///
  /// Fijo y conocido porque el desplazamiento vertical se CALCULA: la fila `i`
  /// vive en `altura + i * altoFila`. Si esto midiera lo que le apetezca, el
  /// catálogo volvería a moverse a tientas.
  ///
  /// 430 medidos en el aparato, no a ojo. Con 356 la captura mostraba el
  /// contenido acabando sobre el corte de la imagen y el título de la primera
  /// fila justo debajo: sin aire entre las dos cosas.
  ///
  /// De los 430, el contenido ocupa unos 250. Los 180 restantes NO están
  /// vacíos por descuido: son el tramo por el que la imagen se apaga. Ese
  /// espacio es el que hace que el destacado y las filas se lean como una
  /// sola superficie en vez de como dos bloques pegados.
  ///
  /// Sigue asomando el borde superior de la primera fila en un televisor de
  /// 1080p. Ese asomo no es un descuido: es lo que dice que hay más abajo.
  static const double altura = 390;

  @override
  State<TvDestacado> createState() => TvDestacadoState();
}

class TvDestacadoState extends State<TvDestacado> {
  /// Un nodo por botón: Reproducir y Ver ficha.
  final List<FocusNode> _nodos = [
    FocusNode(debugLabel: 'destacadoReproducir'),
    FocusNode(debugLabel: 'destacadoFicha'),
  ];

  int _foco = -1; // -1 = ninguno

  @override
  void dispose() {
    for (final n in _nodos) {
      n.dispose();
    }
    super.dispose();
  }

  /// Pone el foco en el destacado. Siempre en "Reproducir": es lo que se viene
  /// a hacer, y volver del catálogo a un "Ver ficha" enfocado sería raro.
  void enfocar() => _nodos.first.requestFocus();

  bool get tieneFoco => _foco >= 0;

  KeyEventResult _tecla(int i, KeyEvent evento) {
    if (evento is! KeyDownEvent && evento is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = evento.logicalKey;

    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA) {
      if (evento is KeyRepeatEvent) return KeyEventResult.handled;
      i == 0 ? widget.onReproducir() : widget.onFicha();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      // ── DERECHA RECORRE: botón, botón, siguiente destacado ────────────
      //
      // Desde el último botón, derecha pasa al siguiente título en vez de no
      // hacer nada. Es lo que hace que los cinco destacados sean alcanzables
      // con el mando sin inventar un control nuevo: las rayitas de abajo ya
      // dicen cuántos hay y en cuál estás, y la flecha hace lo que esas
      // rayitas prometen.
      //
      // Con la tecla mantenida NO se encadena: pasar cinco portadas de golpe
      // por dejar el dedo puesto no lo quiere nadie.
      if (i == 0) {
        _nodos[1].requestFocus();
      } else if (evento is! KeyRepeatEvent) {
        widget.onSiguiente();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (i == 1) {
        _nodos[0].requestFocus();
      } else {
        widget.onSalirIzquierda();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      widget.onAbajo();
      return KeyEventResult.handled;
    }
    // Arriba no lleva a ningún sitio: esto ya es lo más alto de la pantalla.
    if (k == LogicalKeyboardKey.arrowUp) return KeyEventResult.handled;

    return KeyEventResult.ignored;
  }

  // ── Datos, con lo que haya ───────────────────────────────────────────────
  String? _texto(String clave) {
    final v = widget.ficha?[clave];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  M3UItem? get _item =>
      widget.items.isEmpty
          ? null
          : widget.items[widget.indice.clamp(0, widget.items.length - 1)];

  /// La imagen apaisada, pedida en grande.
  ///
  /// TMDB devuelve `backdrop_url` en `w500` — poco más de un cuarto del ancho
  /// de una pantalla de televisor. Estirado a 1920 se ve exactamente como se
  /// veía: pixelado.
  ///
  /// `original` y no `w1280`: el destacado ocupa la pantalla ENTERA, y a 1280
  /// todavía hay que estirar un 50%. Es una imagen por título y solo en el
  /// televisor, que va por wifi, no por datos.
  ///
  /// El teléfono no se toca: allí `w500` va sobrado para su banner y bajar el
  /// original solo gastaría datos del usuario.
  String? _grande(String? url) {
    if (url == null) return null;
    return url.replaceFirst('/w500/', '/original/');
  }

  String? get _anio {
    final f = _texto('release_date');
    return (f != null && f.length >= 4) ? f.substring(0, 4) : null;
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    if (item == null) return const SizedBox(height: TvDestacado.altura);

    // Sin las marcas del proveedor: en pantalla se leia "Obsesión (2026)",
    // con el año repetido en la línea de debajo. El mismo limpiado que se le
    // manda a TMDB sirve para enseñarlo.
    final titulo = limpiarTituloParaTmdb(item.seriesName ?? item.name);
    final sinopsis = _texto('overview');
    final clasificacion = _texto('rating');
    // Apaisada si la hay; si no, el poster, que es vertical pero al menos es
    // del titulo. Y si TMDB no encontro nada, la caratula del proveedor.
    // Cualquier cosa antes que dejar ver el fondo de la app estirado.
    final fondo =
        _grande(_texto('backdrop_url')) ??
        _grande(_texto('poster_url')) ??
        // Solo cuando ya sabemos que TMDB no tiene nada que darnos: si sigue
        // en camino, la caratula vertical seria un parpadeo, no un respaldo.
        (widget.esperandoFicha ? null : item.logo);
    final esApaisada = _texto('backdrop_url') != null;

    return SizedBox(
      height: TvDestacado.altura,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── La imagen ────────────────────────────────────────────────
          //
          // Apaisada de TMDB. Mientras no llega no se pone la carátula
          // estirada en su sitio: un póster vertical deformado a 16:9 se ve
          // peor que no poner nada, y ademas cambiaria de forma al llegar la
          // buena.
          if (fondo != null && fondo.isNotEmpty)
            Positioned.fill(
              // El poster de respaldo se ancla a la DERECHA: es vertical, y
              // recortado a lo ancho del destacado se pierde la mitad. A la
              // derecha, lo que se pierde cae bajo el velo del texto en vez de
              // comerse la cara del cartel.
              // ── LA IMAGEN SE DISUELVE, NO SE TAPA ───────────────────
              //
              // Antes el pie llevaba un velo que iba a `#0B0B0D` OPACO. Y ahí
              // estaba el fallo que se veía en pantalla: debajo del destacado
              // no hay negro liso, está el fondo del catálogo con su textura.
              // El velo terminaba en un color que no era el de su alrededor,
              // así que en vez de un fundido salía una COSTURA — dos
              // superficies distintas pegadas, con el título de la primera
              // fila justo debajo.
              //
              // `ShaderMask` con `dstIn` no pinta nada encima: recorta el alfa
              // de la propia imagen. La imagen se desvanece de verdad y por
              // debajo asoma lo que haya, sea el fondo del catálogo o lo que
              // se ponga mañana. Nada que cuadrar a mano.
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback:
                    (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xFFFFFFFF),
                        Color(0xFFFFFFFF),
                        Color(0x00FFFFFF),
                      ],
                      stops: [0.0, 0.52, 1.0],
                    ).createShader(rect),
                child: FractionallySizedBox(
                  alignment: Alignment.centerRight,
                  widthFactor: esApaisada ? 1.0 : 0.62,
                  child: FastThumbnail(
                    url: fondo,
                    width: double.infinity,
                    height: TvDestacado.altura,
                    // Sin esto la imagen llega en 185 px de ancho: el servicio
                    // reescribe las URLs de TMDB y da igual lo que se pida
                    // desde aqui.
                    pantallaCompleta: true,
                  ),
                ),
              ),
            ),

          // Velo lateral: el texto va sobre negro casi puro y la imagen queda
          // libre a la derecha. Sin esto, un fotograma claro se come el
          // título.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xF7000000),
                    Color(0xE0000000),
                    Color(0x59000000),
                    Color(0x00000000),
                  ],
                  stops: [0.0, 0.30, 0.62, 0.90],
                ),
              ),
            ),
          ),

          // Velo al pie: funde la imagen con las filas de abajo para que no
          // haya un corte recto entre las dos zonas.
          // ── El contenido ─────────────────────────────────────────────
          Padding(
            // 80 arriba: el texto tiene que respirar. Pegado al borde se lee
            // como si se hubiera desbordado, no como una portada.
            //
            // Baja el bloque entero —título, datos, sinopsis y botones— porque
            // es un único Padding: mover esto los mueve todos a la vez y
            // conserva la separación que ya tienen entre sí.
            padding: const EdgeInsets.fromLTRB(106, 80, 0, 0),
            // ── O ENTERO, O NADA ──────────────────────────────────────────
            //
            // Antes salía el título al instante y un segundo después caían la
            // clasificación y la sinopsis, con un hueco vacío mientras tanto.
            // Eso es enseñar el banner a medio montar, y se nota.
            //
            // Netflix no llega antes a sus datos: los espera y pinta la
            // portada ya completa. Aquí igual — el bloque entero aparece de
            // una vez, cuando ya está todo, subiendo un poco al entrar.
            //
            // Si TMDB falla, `esperandoFicha` se apaga igual y sale lo que
            // haya (título y categoría): completo dentro de lo que existe,
            // que es distinto de estar a medias.
            child: AnimatedSlide(
              offset:
                  widget.esperandoFicha ? const Offset(0, 0.06) : Offset.zero,
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: widget.esperandoFicha ? 0 : 1,
                duration: const Duration(milliseconds: 380),
                curve: Curves.easeOut,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 520,
                      child: Text(
                        titulo,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          height: 1.05,
                          letterSpacing: -0.5,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 16),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 9),

                    // Año · clasificación · categoría. Alto reservado: TMDB llega
                    // tarde y sin reservarlo, los botones darían un salto hacia
                    // abajo justo cuando el usuario va a pulsarlos.
                    SizedBox(
                      height: 20,
                      child: Row(
                        children: [
                          if (_anio != null) ...[
                            Text(
                              _anio!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const _Punto(),
                          ],
                          if (clasificacion != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.38),
                                ),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                clasificacion,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const _Punto(),
                          ],
                          Flexible(
                            child: Text(
                              item.category,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 11),

                    // Dos líneas de sinopsis. Con hueco reservado, por lo mismo
                    // que la línea de arriba.
                    SizedBox(
                      width: 440,
                      height: 38,
                      child:
                          sinopsis == null
                              ? null
                              : Text(
                                sinopsis,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  height: 1.45,
                                ),
                              ),
                    ),

                    // Algo más de aire antes de los botones que entre las líneas
                    // de texto: separa lo que se lee de lo que se pulsa.
                    //
                    // Basta con este hueco: los botones y las rayitas van seguidos
                    // en la misma columna, así que bajan juntos y conservan su
                    // separación.
                    const SizedBox(height: 36),

                    Row(
                      children: [
                        _Boton(
                          nodo: _nodos[0],
                          texto: 'Reproducir',
                          icono: Icons.play_arrow_rounded,
                          principal: true,
                          onTecla: (e) => _tecla(0, e),
                          onFoco: (v) => _cambioFoco(0, v),
                          onOk: widget.onReproducir,
                        ),
                        const SizedBox(width: 12),
                        _Boton(
                          nodo: _nodos[1],
                          texto: 'Ver ficha',
                          icono: Icons.info_outline_rounded,
                          principal: false,
                          onTecla: (e) => _tecla(1, e),
                          onFoco: (v) => _cambioFoco(1, v),
                          onOk: widget.onFicha,
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // Cuál de los destacados se está viendo. Rayas y no puntos:
                    // desde el sofá, un punto de 6 píxeles no se ve.
                    Row(
                      children: [
                        for (var i = 0; i < widget.items.length; i++) ...[
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: i == widget.indice ? 24 : 15,
                            height: 3,
                            color:
                                i == widget.indice
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.28),
                          ),
                          const SizedBox(width: 5),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _cambioFoco(int i, bool tiene) {
    setState(() => _foco = tiene ? i : (_foco == i ? -1 : _foco));
    widget.onFoco(tieneFoco);
  }
}

class _Punto extends StatelessWidget {
  const _Punto();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 8),
    child: Text('·', style: TextStyle(color: Colors.white38, fontSize: 14)),
  );
}

/// Botón del destacado. Blanco relleno el principal, translúcido el otro.
class _Boton extends StatefulWidget {
  final FocusNode nodo;
  final String texto;
  final IconData icono;
  final bool principal;
  final KeyEventResult Function(KeyEvent) onTecla;
  final ValueChanged<bool> onFoco;
  final VoidCallback onOk;

  const _Boton({
    required this.nodo,
    required this.texto,
    required this.icono,
    required this.principal,
    required this.onTecla,
    required this.onFoco,
    required this.onOk,
  });

  @override
  State<_Boton> createState() => _BotonState();
}

class _BotonState extends State<_Boton> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    // Con el foco, blanco sólido y texto negro. Sin él, el principal se queda
    // en blanco apagado y el secundario casi transparente: así se sabe cuál es
    // el camino corto aunque el foco esté en otro sitio.
    final Color fondo;
    final Color tinta;
    if (_foco) {
      fondo = Colors.white;
      tinta = const Color(0xFF0B0B0D);
    } else if (widget.principal) {
      fondo = Colors.white.withValues(alpha: 0.88);
      tinta = const Color(0xFF0B0B0D);
    } else {
      fondo = Colors.white.withValues(alpha: 0.16);
      tinta = Colors.white;
    }

    return Focus(
      focusNode: widget.nodo,
      onFocusChange: (v) {
        setState(() => _foco = v);
        widget.onFoco(v);
      },
      // OK se lee directo de la tecla, como en el resto del televisor: con el
      // mando, `Actions`/`Intents` no llegan.
      onKeyEvent: (node, event) => widget.onTecla(event),
      child: AnimatedScale(
        scale: _foco ? 1.05 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        alignment: Alignment.centerLeft,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 8),
          // El mismo radio que en el teléfono: sus dos botones del banner
          // usan `BorderRadius.circular(4)`. Es un redondeo corto a
          // propósito — marca la esquina sin convertir el botón en una
          // pastilla, que es lo que pasaría con un radio grande.
          decoration: BoxDecoration(
            color: fondo,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icono, color: tinta, size: 18),
              const SizedBox(width: 7),
              Text(
                widget.texto,
                style: TextStyle(
                  color: tinta,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
