import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/fast_image_service.dart';
import '../../services/m3u_service.dart';
import '../../utils/colors.dart';
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

  /// Margen derecho. La tarjeta NO llega al filo: es una tarjeta, y una
  /// tarjeta pegada al borde de la pantalla deja de leerse como tal. Ademas,
  /// un televisor recorta los bordes —el "overscan"— y lo pegado al filo se lo
  /// come el panel.
  static const double margenDer = 56;

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
  /// UN SOLO BOTÓN.
  ///
  /// Había otro, "Ver ficha". Con uno solo la portada dice una cosa y no dos,
  /// y el mando no tiene que elegir antes de poder empezar.
  final FocusNode _nodo = FocusNode(debugLabel: 'destacadoVer');

  bool _foco = false;
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
      if (_foco || widget.items.length < 2) return;
      widget.onSiguiente();
    });
  }

  @override
  void dispose() {
    _reloj?.cancel();
    _nodo.dispose();
    super.dispose();
  }

  /// Pone el foco en la cabecera.
  void enfocar() => _nodo.requestFocus();

  bool get tieneFoco => _foco;

  KeyEventResult _tecla(KeyEvent evento) {
    if (evento is! KeyDownEvent && evento is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = evento.logicalKey;

    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA) {
      if (evento is KeyRepeatEvent) return KeyEventResult.handled;
      widget.onReproducir();
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowRight) {
      // Derecha pasa a la siguiente portada. Con dos botones había que
      // cruzarlos primero; ahora es directo — las rayitas de abajo dicen
      // cuántas hay, y la flecha cumple lo que esas rayitas prometen.
      //
      // Con la tecla mantenida NO se encadena: pasar cinco portadas de golpe
      // por dejar el dedo puesto no lo quiere nadie.
      if (evento is! KeyRepeatEvent) widget.onSiguiente();
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      widget.onSalirIzquierda();
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

  void _cambioFoco(bool tiene) {
    if (_foco == tiene) return;
    if (mounted) setState(() => _foco = tiene);
    widget.onFoco(tiene);
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
    final hayImagen = widget.listo && imagen != null && imagen.isNotEmpty;

    return LayoutBuilder(
      builder: (context, restricciones) {
        final alto = TvDestacado.alturaPara(restricciones.maxWidth);

        return SizedBox(
          height: alto,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              TvDestacado.margenIzq,
              22,
              TvDestacado.margenDer,
              24,
            ),
            child: Stack(
              // Sin recorte: el resplandor de abajo se sale del hueco a
              // propósito, y recortarlo lo convertiría en una línea.
              clipBehavior: Clip.none,
              children: [
                // ── 1. El resplandor ──────────────────────────────────────
                //
                // Una copia desenfocada de la misma imagen, detrás de la
                // tarjeta y desbordando por abajo. Es lo que hace que en el
                // teléfono el banner parezca apoyado sobre la pantalla en vez
                // de pegado a ella, y en una tele —donde el fondo es casi
                // negro— se nota todavía más.
                //
                // A media resolución: va a 30 de desenfoque, así que el
                // detalle no se ve y en un aparato de 1 GB no hay que pagarlo.
                if (hayImagen)
                  Positioned(
                    top: 16,
                    left: 14,
                    right: 14,
                    bottom: -12,
                    child: IgnorePointer(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                        child: Opacity(
                          opacity: 0.55,
                          child: FastThumbnail(
                            url: imagen,
                            width: double.infinity,
                            height: double.infinity,
                            cacheWidth: 400,
                          ),
                        ),
                      ),
                    ),
                  ),

                // ── 2. La tarjeta ─────────────────────────────────────────
                //
                // Casi los mismos valores que en el teléfono: radio 12, borde
                // blanco de 1,5 px y un degradado diagonal muy tenue.
                // Ese borde es lo que separa la tarjeta del fondo sin dibujar
                // una caja: se ve el filo, no el marco.
                //
                // El borde NO cambia con el foco. El foco lo lleva el botón,
                // que se vuelve blanco; si además se encendiera el marco,
                // serían dos cosas diciendo lo mismo.
                // `Container` Y NO `DecoratedBox`, y es la diferencia entre
                // que el borde se vea o no.
                //
                // `DecoratedBox` pinta la decoracion DETRAS de su hijo sin
                // apartarlo: la imagen ocupaba tambien el filo y se comia el
                // borde entero. `Container` convierte el borde en relleno, asi
                // que el recorte de dentro empieza 1,5 px mas adentro y el
                // filo queda a la vista.
                //
                // Ya me paso antes en esta misma tarjeta.
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      // 0.13, mas tenue que el 0.2 del telefono. Alli la
                      // pantalla se mira de cerca y el filo se pierde si no
                      // aprieta; a tres metros el blanco sobre fondo oscuro
                      // gana presencia, y al 20% el marco se veia antes que la
                      // portada. Asi marca el limite sin dibujarlo.
                      color: Colors.white.withValues(alpha: 0.13),
                      width: 1.5,
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.15),
                        Colors.white.withValues(alpha: 0.05),
                        Colors.white.withValues(alpha: 0.10),
                      ],
                    ),
                  ),
                  child: ClipRRect(
                    // 11 y no 12: por dentro del borde de 1,5. Con el mismo
                    // radio, la imagen asomaría por las esquinas.
                    borderRadius: BorderRadius.circular(11),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Base oscura: si la imagen no llega, la tarjeta sigue
                        // siendo una tarjeta y no un agujero al fondo.
                        const ColoredBox(color: Color(0xFF15151A)),

                        if (hayImagen)
                          FastThumbnail(
                            url: imagen,
                            width: double.infinity,
                            height: double.infinity,
                            // El servicio reescribe las URLs de TMDB; sin esta
                            // marca la imagen llegaría a 185 px de ancho para
                            // una tarjeta de más de mil.
                            pantallaCompleta: true,
                          ),

                        // ── 3. Los velos ──────────────────────────────────
                        //
                        // El de abajo es el del teléfono, con el color del
                        // fondo de la app y no negro: así el pie de la tarjeta
                        // se funde con la pantalla en vez de oscurecerse.
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.transparent,
                                AppColors.fondoTv.withValues(alpha: 0.7),
                              ],
                              stops: const [0.0, 0.55, 1.0],
                            ),
                          ),
                        ),
                        // Y este por la izquierda, que en el teléfono no hace
                        // falta —allí el texto va abajo, sobre el velo de
                        // arriba— pero aquí sí: en una pantalla apaisada el
                        // texto va al lado, y sin esto una portada clara se
                        // come la letra blanca.
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                AppColors.fondoTv.withValues(alpha: 0.8),
                                AppColors.fondoTv.withValues(alpha: 0.42),
                                AppColors.fondoTv.withValues(alpha: 0),
                              ],
                              stops: const [0.0, 0.45, 0.8],
                            ),
                          ),
                        ),

                        // ── 4. El contenido ───────────────────────────────
                        Positioned(
                          left: 34,
                          right: restricciones.maxWidth * 0.42,
                          bottom: 30,
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
                                  fontSize: 22,
                                  fontWeight: FontWeight.w500,
                                  height: 1.15,
                                  letterSpacing: -0.3,
                                ),
                              ),

                              const SizedBox(height: 8),

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

                              // Una línea de sinopsis, y solo si la hay: sin
                              // ella el bloque se cierra y el botón sube.
                              if (sinopsis != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  sinopsis,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    height: 1.4,
                                  ),
                                ),
                              ],

                              const SizedBox(height: 20),

                              _Boton(
                                nodo: _nodo,
                                texto: 'Ver',
                                icono: Icons.play_arrow_rounded,
                                conFoco: _foco,
                                onTecla: _tecla,
                                onFoco: _cambioFoco,
                              ),
                            ],
                          ),
                        ),

                        // ── 5. En cuál de los cinco estás ─────────────────
                        if (widget.items.length > 1)
                          Positioned(
                            right: 28,
                            bottom: 30,
                            child: Row(
                              children: [
                                for (
                                  var i = 0;
                                  i < widget.items.length;
                                  i++
                                ) ...[
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 220),
                                    width: i == _i ? 22 : 8,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color:
                                          i == _i
                                              ? Colors.white
                                              : Colors.white.withValues(
                                                alpha: 0.35,
                                              ),
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
                  ),
                ),
              ],
            ),
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

  /// Opcional: hay botones que se explican solos con el texto.
  final IconData? icono;
  final bool conFoco;
  final KeyEventResult Function(KeyEvent) onTecla;
  final ValueChanged<bool> onFoco;

  const _Boton({
    required this.nodo,
    required this.texto,
    this.icono,
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
    final tinta = conFoco ? const Color(0xFF0D0D0D) : Colors.white;

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
            if (icono != null) ...[
              Icon(icono, color: tinta, size: 18),
              const SizedBox(width: 7),
            ],
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
