import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/fast_image_service.dart';
import '../../services/m3u_service.dart';
import '../../utils/titulo_tmdb.dart';

/// La cabecera del catálogo: UNA portada, grande.
///
/// ── POR QUÉ UNA Y NO SEIS ──────────────────────────────────────────────────
///
/// Antes era un mosaico de seis piezas del mismo peso, y ese era su problema:
/// seis cosas iguales no proponen nada. Es una rejilla más, solo que arriba y
/// con las piezas más grandes — y el usuario ya tiene rejillas de sobra debajo.
///
/// Una portada única hace lo que hace la primera página de un periódico: decir
/// "empieza por aquí". En un televisor eso importa más que en un móvil, porque
/// el ojo se posa en un punto y se mira desde tres metros: una imagen grande
/// con su título legible se entiende de un vistazo; seis títulos pequeños hay
/// que recorrerlos.
///
/// ── LO QUE ADEMÁS ARREGLA ──────────────────────────────────────────────────
///
///  · UNA sola imagen en pantalla en vez de seis. En un aparato de 1 GB eso es
///    memoria y decodificación que dejan de competir con el vídeo.
///  · Si TMDB no tiene la imagen de un título, no queda un hueco oscuro al
///    lado de otros cinco: se pasa al siguiente y ya está.
class TvDestacado extends StatefulWidget {
  /// Los títulos que se van turnando en la portada.
  final List<M3UItem> items;

  /// Cuál se está enseñando.
  final int indice;

  /// La imagen apaisada de cada título, en el mismo orden que [items].
  final List<String?> imagenes;

  /// La ficha de TMDB de cada título: sinopsis y año. Puede faltar.
  final List<Map<String, dynamic>?> fichas;

  /// ¿Está ya la imagen de la portada actual?
  ///
  /// Mientras es `false` se pinta el hueco oscuro en vez de la imagen. Sin
  /// esto se veía entrar una portada a medio cargar, que en algo tan grande
  /// canta mucho más que en una carátula pequeña.
  final bool listo;

  /// Reproducir el destacado actual.
  final VoidCallback onReproducir;

  /// Abrir su ficha.
  final VoidCallback onFicha;

  /// Bajar a la primera fila de carátulas.
  final VoidCallback onAbajo;

  /// Izquierda desde el primer botón: se vuelve al menú lateral.
  final VoidCallback onSalirIzquierda;

  /// Pasar al siguiente destacado.
  final VoidCallback onSiguiente;

  /// El foco entró o salió de la cabecera.
  final ValueChanged<bool> onFoco;

  const TvDestacado({
    super.key,
    required this.items,
    required this.indice,
    required this.imagenes,
    required this.fichas,
    required this.listo,
    required this.onReproducir,
    required this.onFicha,
    required this.onAbajo,
    required this.onSalirIzquierda,
    required this.onSiguiente,
    required this.onFoco,
  });

  /// Cuántos títulos se turnan en la portada.
  static const int titulosNecesarios = 5;

  /// Cada cuánto pasa al siguiente, con el foco fuera.
  static const Duration cadaTurno = Duration(seconds: 9);

  /// Margen izquierdo del texto: el mismo que el de los títulos de las filas
  /// de abajo. Las dos cosas tienen que empezar en la misma vertical.
  static const double margenIzq = 106;

  /// Tope de alto, para que la portada no se coma la primera fila.
  static const double alturaMaxima = 450;

  /// Lo que ocupa con un ancho dado.
  ///
  /// En formato 16:9, el 45% del ancho disponible equivale al ~80% de la altura de la
  /// pantalla (432 px en 540p, 864 px en 1080p).
  /// Da presencia cinematográfica al arte de TMDB y permite que la primera fila
  /// de categorías asome abajo con claridad.
  static double alturaPara(double anchoDisponible) {
    final alto = anchoDisponible * 0.45;
    return alto < 360 ? 360 : (alto > alturaMaxima ? alturaMaxima : alto);
  }

  @override
  State<TvDestacado> createState() => TvDestacadoState();
}

class TvDestacadoState extends State<TvDestacado> {
  /// Un nodo por botón: Ver y Ver ficha.
  final List<FocusNode> _nodos = [
    FocusNode(debugLabel: 'destacadoVer'),
    FocusNode(debugLabel: 'destacadoFicha'),
  ];

  int _foco = -1; // -1 = ninguno
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    _reloj = Timer.periodic(TvDestacado.cadaTurno, (_) {
      if (!mounted) return;
      // ── NO PASA MIENTRAS LO MIRAS ──────────────────────────────────────
      //
      // Con el foco aquí, cambiar de título significaría que OK abre algo
      // distinto de lo que estabas viendo. Con un mando, donde el foco es lo
      // único que orienta, eso es abrir la película equivocada.
      if (_foco >= 0 || widget.items.length < 2) return;
      widget.onSiguiente();
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

  /// Pone el foco en la cabecera, siempre en "Ver": es a lo que se viene.
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
      // Derecha recorre: botón, botón, siguiente portada. Es lo que hace que
      // los cinco sean alcanzables sin inventar un control aparte — las
      // rayitas de abajo ya dicen cuántos hay, y la flecha cumple lo que esas
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

  void _cambioFoco(int i, bool tiene) {
    final antes = _foco >= 0;
    if (tiene) {
      _foco = i;
    } else if (_foco == i) {
      _foco = -1;
    }
    if (mounted) setState(() {});

    final ahora = _foco >= 0;
    if (antes != ahora) widget.onFoco(ahora);
  }

  // ── Datos, con lo que haya ───────────────────────────────────────────────
  int get _i => widget.indice.clamp(0, widget.items.length - 1);

  Map<String, dynamic>? get _ficha =>
      _i < widget.fichas.length ? widget.fichas[_i] : null;

  String? _texto(String clave) {
    final v = _ficha?[clave];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  String? get _anio {
    final f = _texto('release_date');
    return (f != null && f.length >= 4) ? f.substring(0, 4) : null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return SizedBox(height: TvDestacado.alturaPara(400));
    }

    final item = widget.items[_i];
    // Sin las marcas del proveedor: en pantalla se leía "Obsesión (2026)", con
    // el año repetido en la línea de debajo.
    final titulo = limpiarTituloParaTmdb(item.seriesName ?? item.name);
    final imagen = _i < widget.imagenes.length ? widget.imagenes[_i] : null;
    final sinopsis = _texto('overview');

    return LayoutBuilder(
      builder: (context, restricciones) {
        final alto = TvDestacado.alturaPara(restricciones.maxWidth);

        return SizedBox(
          height: alto,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ── 1. Fondo base ─────────────────────────────────────────
              // Evita cualquier hueco o transparencia indeseada.
              const ColoredBox(color: Color(0xFF0B0B0D)),

              // ── 2. La imagen apaisada ─────────────────────────────────
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                child:
                    (!widget.listo || imagen == null || imagen.isEmpty)
                        ? const ColoredBox(
                          key: ValueKey('vacio'),
                          color: Color(0xFF0B0B0D),
                        )
                        : FastThumbnail(
                          key: ValueKey(imagen),
                          url: imagen,
                          width: restricciones.maxWidth,
                          height: alto,
                          // Encuadre superior para no cortar rostros ni cabezas
                          alignment: const Alignment(0.0, -0.3),
                          pantallaCompleta: true,
                        ),
              ),

              // ── 3. Velo superior sutil ────────────────────────────────
              // Suaviza la transición hacia la parte alta de la pantalla.
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 120,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x8C0B0B0D), Colors.transparent],
                        stops: [0.0, 1.0],
                      ),
                    ),
                  ),
                ),
              ),

              // ── 4. Velo lateral izquierdo ─────────────────────────────
              // Da legibilidad y contraste perfecto a los textos y botones.
              const Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Color(0xF50B0B0D),
                          Color(0xD90B0B0D),
                          Color(0x660B0B0D),
                          Colors.transparent,
                        ],
                        stops: [0.0, 0.32, 0.58, 0.85],
                      ),
                    ),
                  ),
                ),
              ),

              // ── 5. Velo inferior cinematográfico ──────────────────────
              // Funde la imagen gradualmente en el fondo de la pantalla (0xFF0B0B0D).
              // Comienza suave desde la mitad inferior y solo llega a opaco en la
              // base misma, eliminando cualquier franja negra o corte seco.
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 280,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Color(0x000B0B0D),
                          Color(0x330B0B0D),
                          Color(0x730B0B0D),
                          Color(0xBF0B0B0D),
                          Color(0xFF0B0B0D),
                        ],
                        stops: [0.0, 0.20, 0.45, 0.68, 0.88, 1.0],
                      ),
                    ),
                  ),
                ),
              ),

              // ── 6. El texto y los botones ─────────────────────────────
              Positioned(
                left: TvDestacado.margenIzq,
                right: restricciones.maxWidth * 0.40,
                bottom: 40,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      titulo,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                        letterSpacing: -0.4,
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Año · categoría.
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

                    // Una o dos líneas de sinopsis si la hay
                    if (sinopsis != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        sinopsis,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),

                    Row(
                      children: [
                        _Boton(
                          nodo: _nodos[0],
                          texto: 'Ver',
                          icono: Icons.play_arrow_rounded,
                          conFoco: _foco == 0,
                          onTecla: (e) => _tecla(0, e),
                          onFoco: (v) => _cambioFoco(0, v),
                        ),
                        const SizedBox(width: 12),
                        _Boton(
                          nodo: _nodos[1],
                          texto: 'Ver ficha',
                          icono: Icons.info_outline_rounded,
                          conFoco: _foco == 1,
                          onTecla: (e) => _tecla(1, e),
                          onFoco: (v) => _cambioFoco(1, v),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // ── 7. En cuál de los títulos estás ───────────────────────
              if (widget.items.length > 1)
                Positioned(
                  right: 48,
                  bottom: 42,
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.items.length; i++) ...[
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          width: i == _i ? 22 : 8,
                          height: 4,
                          decoration: BoxDecoration(
                            color:
                                i == _i
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        if (i != widget.items.length - 1)
                          const SizedBox(width: 5),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// El separador entre el año y la categoría.
class _Punto extends StatelessWidget {
  const _Punto();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 8),
    child: Text('·', style: TextStyle(color: Colors.white38, fontSize: 13)),
  );
}

/// Uno de los dos botones de la portada.
class _Boton extends StatelessWidget {
  final FocusNode nodo;
  final String texto;
  final IconData icono;
  final bool conFoco;
  final KeyEventResult Function(KeyEvent) onTecla;
  final ValueChanged<bool> onFoco;

  const _Boton({
    required this.nodo,
    required this.texto,
    required this.icono,
    required this.conFoco,
    required this.onTecla,
    required this.onFoco,
  });

  @override
  Widget build(BuildContext context) {
    // DOS ESTADOS, NO TRES. El que tiene el foco va en blanco sólido; el otro,
    // translúcido. Que el blanco signifique una sola cosa —"aquí está el
    // foco"— es lo que lo hace legible desde el sofá.
    final fondo = conFoco ? Colors.white : Colors.white.withValues(alpha: 0.16);
    final tinta = conFoco ? const Color(0xFF0B0B0D) : Colors.white;

    return Focus(
      focusNode: nodo,
      onFocusChange: onFoco,
      // OK se lee directo de la tecla: con el mando de un televisor,
      // `Actions`/`Intents` no llegan.
      onKeyEvent: (node, evento) => onTecla(evento),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 8),
        decoration: BoxDecoration(color: fondo),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, color: tinta, size: 18),
            const SizedBox(width: 7),
            Text(
              texto,
              style: TextStyle(
                color: tinta,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
