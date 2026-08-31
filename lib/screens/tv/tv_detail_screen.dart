import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/m3u_item.dart';
import '../../services/m3u_service.dart';
import '../../services/tmdb_service.dart';
import 'tv_player_screen.dart';

/// Ficha de un título en el televisor.
///
/// CÓMO ESTÁ ARMADA
/// La forma es la de las fichas de las apps de IPTV al uso: el texto manda a la
/// izquierda —título, procedencia, sinopsis—, la imagen apaisada acompaña
/// arriba a la derecha, y ABAJO va lo único que se pulsa de verdad: la fila de
/// episodios (o el botón de reproducir, si es película). Quien llega con el
/// mando baja una vez y ya está encima de lo que quiere.
///
/// DE DÓNDE SALE LA INFORMACIÓN
/// El catálogo solo trae nombre, categoría y carátula. La sinopsis, el año, el
/// país y el título original vienen de TMDB, el mismo servicio que ya usa la
/// ficha del teléfono — así las dos pantallas cuentan lo mismo del mismo
/// título.
///
/// Y LLEGA TARDE, A PROPÓSITO
/// TMDB es una llamada de red: si la ficha esperase a tenerla, pulsar una
/// carátula daría pantalla en negro un segundo. Aquí se pinta al instante todo
/// lo que ya se sabe —título, imagen, episodios— y lo de TMDB aparece cuando
/// llega. Lo importante es que la fila de abajo NO se mueve al llegar los
/// datos: quien va directo a darle a OK no se encuentra el foco en otro sitio a
/// mitad de gesto.
class TvDetailScreen extends StatefulWidget {
  final M3UItem item;

  const TvDetailScreen({super.key, required this.item});

  @override
  State<TvDetailScreen> createState() => _TvDetailScreenState();
}

class _TvDetailScreenState extends State<TvDetailScreen> {
  Map<String, dynamic>? _ficha;
  bool _buscando = true;

  /// Los episodios, que casi nunca vienen con el item.
  ///
  /// De 3.301 series del catalogo, solo 55 llegan con sus episodios dentro. El
  /// resto son fichas SIN contenido: el proveedor entrega los episodios cuando
  /// se los pides, no en el listado. Por eso la ficha salia con "Reproducir" y
  /// ninguna temporada — no era que estuvieran mal agrupadas, es que aun no se
  /// habian pedido.
  ///
  /// Es lo mismo que ya hace la ficha del telefono con `fetchEpisodesForItem`.
  List<M3UItem> _episodiosCargados = const [];
  bool _cargandoEpisodios = false;

  /// Temporada elegida. `null` hasta que se sabe cual es la primera.
  int? _temporada;

  /// Episodio marcado, el que se lleva el boton de reproducir.
  ///
  /// Empieza en el primero y cambia SOLO al pulsar un numero, no al pasar el
  /// foco por encima: si cambiara al pasar, la linea naranja de arriba estaria
  /// bailando mientras uno se limita a recorrer la fila.
  int _episodioElegido = 0;

  /// Otros titulos de la misma categoria. Se calcula una vez.
  late final List<M3UItem> _sugerencias = _calcularSugerencias();

  @override
  void initState() {
    super.initState();
    _buscarFicha();
    _cargarEpisodios();
  }

  /// Pide los episodios al proveedor si el item no los trae.
  ///
  /// No bloquea la ficha: el titulo, la imagen y el boton de reproducir se
  /// pintan al instante y los episodios entran cuando llegan. Quien solo
  /// queria darle a play no espera a nada.
  Future<void> _cargarEpisodios() async {
    // Los que ya vienen puestos son los buenos: no se vuelve a pedir nada.
    if (widget.item.episodes.isNotEmpty) {
      setState(() => _episodiosCargados = widget.item.episodes);
      return;
    }
    // Una pelicula no tiene episodios que pedir.
    if (!widget.item.isSeries && widget.item.seriesName == null) return;

    setState(() => _cargandoEpisodios = true);
    try {
      final eps = await M3UService().fetchEpisodesForItem(widget.item);
      if (mounted) setState(() => _episodiosCargados = eps);
    } catch (e) {
      debugPrint('TvDetalle: no se pudieron traer los episodios: $e');
    } finally {
      if (mounted) setState(() => _cargandoEpisodios = false);
    }
  }

  Future<void> _buscarFicha() async {
    try {
      final d = await TMDBService().searchAndGetDetails(
        // De una serie se busca la serie, no el episodio: "Capítulo 4" no
        // existe en TMDB, pero el nombre de la serie sí. Y limpio, porque los
        // titulos del proveedor vienen con basura pegada.
        _paraBuscar(widget.item.seriesName ?? widget.item.name),
        isSeries: widget.item.isSeries || widget.item.seriesName != null,
      );
      if (mounted) setState(() => _ficha = d.isEmpty ? null : d);
    } catch (_) {
      if (mounted) setState(() => _ficha = null);
    } finally {
      if (mounted) setState(() => _buscando = false);
    }
  }

  /// Titulos parecidos: los de la misma categoria que ya estan en memoria.
  ///
  /// No se pide nada a la red. El catalogo ya esta cargado —es de donde se
  /// venia— y sacar de ahi cuesta cero, que es justo lo que puede permitirse
  /// una fila decorativa al final de la ficha.
  List<M3UItem> _calcularSugerencias() {
    final s = M3UService();
    final esSerie = widget.item.isSeries || widget.item.seriesName != null;
    var base = esSerie ? s.series : s.movies;
    if (base.isEmpty) base = s.itemsPreliminares;
    if (base.isEmpty) return const [];

    final propio = widget.item.seriesName ?? widget.item.name;
    final cat = widget.item.category.trim();

    final mismos = <M3UItem>[];
    final otros = <M3UItem>[];
    for (final e in base) {
      if ((e.seriesName ?? e.name) == propio) continue;
      if ((e.logo ?? '').isEmpty) continue;
      if (cat.isNotEmpty && e.category.trim() == cat) {
        mismos.add(e);
        if (mismos.length >= 14) break;
      } else if (otros.length < 14) {
        otros.add(e);
      }
    }
    return [...mismos, ...otros].take(14).toList();
  }

  List<M3UItem> get _episodios {
    if (_episodiosCargados.isEmpty) return const [];
    final lista = [..._episodiosCargados];
    lista.sort((a, b) {
      final t = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
      return t != 0
          ? t
          : (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });
    return lista;
  }

  /// Deja el titulo en algo que TMDB pueda encontrar.
  ///
  /// Los nombres del proveedor llegan asi: "Spider Man - Un Nuevo Día (HDTS)
  /// (2026)". Con la marca de calidad y el año pegados, TMDB no devuelve nada
  /// —la ficha salia siempre vacia— y no es un fallo de TMDB: le estabamos
  /// pasando un nombre que no existe.
  ///
  /// Se quitan las marcas de calidad, el año entre parentesis y los corchetes
  /// del proveedor. El año NO se pierde del todo: `searchAndGetDetails` ya lo
  /// extrae por su cuenta del texto original para afinar la busqueda.
  static final RegExp _basura = RegExp(
    r'\((?:HDTS|CAM|TS|HDRIP|BRRIP|WEBRIP|WEB-?DL|HD|SD|4K|FHD|UHD|LAT|CAST|'
    r'SUB|VOSE|DUAL|REMUX|BLURAY|DVDRIP|SCREENER|LINE)\)|\[[^\]]*\]|'
    r'(?:19|20)\d{2}|\(\s*\)',
    caseSensitive: false,
  );

  static String _paraBuscar(String bruto) {
    var t = bruto.replaceAll(_basura, ' ');
    // Los parentesis que quedan vacios tras vaciar su contenido.
    t = t.replaceAll(RegExp(r'\(\s*\)'), ' ');
    // Separadores del proveedor al final: " - ", " | ", puntos sueltos.
    t = t.replaceAll(RegExp(r'\s*[|·]\s*'), ' ');
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    // Un guion suelto al final no aporta y estorba a la busqueda.
    t = t.replaceAll(RegExp(r'\s*-\s*$'), '').trim();
    return t.isEmpty ? bruto : t;
  }

  /// Las temporadas que trae esta serie, ordenadas.
  List<int> get _temporadas {
    final t = <int>{};
    for (final e in _episodios) {
      t.add(e.seasonNumber ?? 1);
    }
    final lista = t.toList()..sort();
    return lista;
  }

  /// Episodios de la temporada elegida.
  ///
  /// Con una sola temporada no se filtra nada y tampoco se enseña el selector:
  /// un control con una unica opcion es un control que sobra.
  List<M3UItem> get _episodiosVisibles {
    final temporadas = _temporadas;
    if (temporadas.length < 2) return _episodios;
    final elegida = _temporada ?? temporadas.first;
    return [
      for (final e in _episodios)
        if ((e.seasonNumber ?? 1) == elegida) e,
    ];
  }

  void _reproducir(M3UItem queVer) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvPlayerScreen(item: queVer, titulo: queVer.name),
      ),
    );
  }

  /// Saltar de una ficha a otra desde "Quizás te guste".
  ///
  /// Se REEMPLAZA en vez de apilar: encadenando sugerencias se llegaba a tener
  /// diez fichas una encima de otra, y volver desde ahi eran diez pulsaciones
  /// de "atras" para regresar al catalogo.
  void _abrir(M3UItem otro) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => TvDetailScreen(item: otro)),
    );
  }

  // ── Datos derivados de la ficha ──────────────────────────────────────────
  String? _texto(String clave) {
    final v = _ficha?[clave];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  String? get _anio {
    final f = _texto('release_date');
    if (f != null && f.length >= 4) return f.substring(0, 4);
    return null;
  }

  String get _sinopsis => _texto('overview') ?? '';
  String? get _pais => _texto('country');
  String? get _tituloOriginal => _texto('original_title');
  String? get _fondo => _texto('backdrop_url');

  /// La imagen apaisada de arriba a la derecha.
  ///
  /// Primero el backdrop de TMDB, que es el que da el aire de ficha. Si TMDB no
  /// tiene nada, la caratula del proveedor antes que un hueco gris.
  String? get _imagen => _fondo ?? _texto('poster_url') ?? widget.item.logo;

  @override
  Widget build(BuildContext context) {
    final episodios = _episodiosVisibles;
    final esSerie = _episodios.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0D),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Fondo ────────────────────────────────────────────────────────
          //
          // El mismo fondo fijo del catalogo, para que pasar de una pantalla a
          // otra no cambie de escenario. Antes aqui iba el backdrop del titulo
          // y tenia un problema: cada ficha se veia de un color distinto, y
          // con un backdrop claro el texto blanco de encima se perdia. La
          // imagen del titulo sigue estando, pero donde se mira — en el
          // recuadro grande de la derecha.
          //
          // `cover` y no `fill`: en un televisor la proporcion puede no ser
          // 16:9 exacta y estirar la imagen se nota enseguida en las
          // diagonales. Y con `color: black` debajo, el recorte nunca deja un
          // borde vacio en pantallas mas altas o mas anchas.
          const DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black,
              image: DecorationImage(
                image: AssetImage('assets/images/detallestv.png'),
                fit: BoxFit.cover,
              ),
            ),
            child: SizedBox.expand(),
          ),

          // Un velo oscuro que se abre de izquierda a derecha. El fondo tiene
          // el dibujo justo en el centro, que es por donde pasa la sinopsis:
          // sin esto, el texto cae encima de las circunferencias claras y deja
          // de leerse desde el sofa.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0xF2000000),
                  Color(0xB3000000),
                  Color(0x59000000),
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
            child: SizedBox.expand(),
          ),

          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(48, 26, 48, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Cabecera: texto a la izquierda, imagen a la derecha ────
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _cabeceraTexto(esSerie, episodios)),
                    const SizedBox(width: 36),

                    // La imagen ES el boton de reproducir.
                    //
                    // Antes habia un "Reproducir" aparte debajo, y sobraba: en
                    // la ficha ya hay una imagen grande justo donde mira el
                    // ojo, asi que darle el foco a ella quita un control de la
                    // pantalla sin quitar nada de lo que se puede hacer. Es
                    // ademas el primer foco, asi que entrar y pulsar OK
                    // reproduce, sin mover el mando.
                    _ImagenFicha(
                      url: _imagen,
                      autofocus: true,
                      onOk:
                          () =>
                              _reproducir(_queSeReproduce(esSerie, episodios)),
                    ),
                  ],
                ),

                const SizedBox(height: 22),

                if (esSerie) _bloqueEpisodios(episodios),

                if (_sugerencias.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  const Text(
                    'Quizás te guste',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 176,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _sugerencias.length,
                      itemBuilder:
                          (context, i) => _CardSugerencia(
                            item: _sugerencias[i],
                            onOk: () => _abrir(_sugerencias[i]),
                          ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Lo que se pone al pulsar la imagen: el episodio marcado, o la pelicula.
  M3UItem _queSeReproduce(bool esSerie, List<M3UItem> episodios) {
    if (!esSerie || episodios.isEmpty) return widget.item;
    return _episodioElegido < episodios.length
        ? episodios[_episodioElegido]
        : episodios.first;
  }

  // ── Cabecera ─────────────────────────────────────────────────────────────
  Widget _cabeceraTexto(bool esSerie, List<M3UItem> episodios) {
    // País | Año | Título original. Se junta con " | " y se saltan los huecos:
    // con TMDB a medio llegar es normal tener solo uno de los tres, y una linea
    // con separadores sueltos ("| 2016 |") se lee como un error.
    final linea = [
      if (_pais != null) _pais!,
      if (_anio != null) _anio!,
      if (_tituloOriginal != null) _tituloOriginal!,
    ].join('  |  ');

    final marcado =
        (esSerie && _episodioElegido < episodios.length)
            ? episodios[_episodioElegido]
            : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.item.seriesName ?? widget.item.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26.6,
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 8),

        // El hueco de la linea se reserva aunque TMDB no haya llegado: si
        // creciera despues, empujaria hacia abajo la fila de episodios justo
        // cuando el usuario va a pulsarla.
        SizedBox(
          height: 20,
          child: Text(
            linea.isNotEmpty ? linea : (_buscando ? '' : widget.item.category),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        // ── Episodio marcado ────────────────────────────────────────────
        //
        // En naranja porque es el unico dato de la cabecera que CAMBIA con lo
        // que uno hace abajo: al pulsar un numero, esta linea es la que
        // confirma cual quedo puesto.
        if (marcado != null) ...[
          const SizedBox(height: 10),
          Text(
            _nombreEpisodio(marcado),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFF5A623),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],

        // Marca de servidor: V1+ (hay de donde tirar si falla) o BD (propio).
        Builder(
          builder: (context) {
            final hayAlternativas =
                widget.item.alternatives.isNotEmpty ||
                _episodios.any((e) => e.alternatives.isNotEmpty);
            final deLaBD =
                widget.item.esDeLaBD || _episodios.any((e) => e.esDeLaBD);
            final texto = hayAlternativas ? 'V1+' : (deLaBD ? 'BD' : null);
            if (texto == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _Distintivo(texto: texto),
            );
          },
        ),

        const SizedBox(height: 14),

        // ── Sinopsis ──────────────────────────────────────────────────────
        //
        // Cuatro líneas como techo. En una tele el texto se lee a tres metros:
        // un bloque más largo no se lee, se saltea. Y no hay "ver más" porque
        // abrirlo con el mando cuesta un foco más para algo que casi nadie
        // hace.
        RichText(
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            children: [
              const TextSpan(
                text: 'Sinopsis  ',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  height: 1.5,
                ),
              ),
              TextSpan(
                text:
                    _sinopsis.isNotEmpty
                        ? _sinopsis
                        : (_buscando ? 'Cargando…' : 'Sin datos'),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),

        // Mientras llegan los episodios se dice, en vez de dejar un hueco que
        // parece que falta algo. Ocupa poco y desaparece solo.
        if (_cargandoEpisodios) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white38,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Buscando episodios...',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String _nombreEpisodio(M3UItem ep) {
    final n = ep.episodeNumber;
    if (n == null) return ep.name;
    final t = ep.seasonNumber;
    return (t != null && _temporadas.length > 1)
        ? 'Temporada $t · Episodio $n'
        : 'Episodio $n';
  }

  // ── Bloque de episodios ─────────────────────────────────────────────────
  //
  // Una sola fila de numeros, como en las apps de IPTV: la lista vertical
  // obligaba a bajar episodio a episodio hasta el 12, y con el mando eso son
  // doce pulsaciones para algo que aqui son tres.
  Widget _bloqueEpisodios(List<M3UItem> episodios) {
    final temporadas = _temporadas;
    final primero =
        episodios.isEmpty ? null : (episodios.first.episodeNumber ?? 1);
    final ultimo =
        episodios.isEmpty
            ? null
            : (episodios.last.episodeNumber ?? episodios.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Selector de temporada, solo si hay mas de una.
        if (temporadas.length > 1) ...[
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final t in temporadas)
                  _ChipTemporada(
                    numero: t,
                    elegida: (_temporada ?? temporadas.first) == t,
                    onOk:
                        () => setState(() {
                          _temporada = t;
                          _episodioElegido = 0;
                        }),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],

        // El rango de la temporada, en naranja. Dice de un vistazo cuantos
        // episodios hay sin tener que recorrer la fila hasta el final.
        if (primero != null && ultimo != null) ...[
          Text(
            '$primero-$ultimo',
            style: const TextStyle(
              color: Color(0xFFF5A623),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
        ],

        SizedBox(
          height: 46,
          child: ListView.builder(
            // La clave incluye la temporada: sin ella, Flutter reutiliza las
            // celdas y la fila se queda con los episodios de la anterior.
            key: ValueKey(_temporada),
            scrollDirection: Axis.horizontal,
            // Una celda mas que episodios: la primera es el boton de
            // reproducir, que se lleva el episodio marcado.
            itemCount: episodios.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                final marcado =
                    _episodioElegido < episodios.length
                        ? episodios[_episodioElegido]
                        : episodios.first;
                return _CeldaEpisodio(
                  icono: Icons.play_arrow_rounded,
                  onOk: () => _reproducir(marcado),
                );
              }
              final ep = episodios[i - 1];
              return _CeldaEpisodio(
                texto: '${ep.episodeNumber ?? i}',
                marcada: _episodioElegido == i - 1,
                onOk: () {
                  setState(() => _episodioElegido = i - 1);
                  _reproducir(ep);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// La imagen apaisada de la cabecera, que es tambien el boton de reproducir.
///
/// Sin esquinas redondeadas: pegada al borde recto se lee como un fotograma
/// del propio titulo y no como una tarjeta mas de una interfaz.
class _ImagenFicha extends StatefulWidget {
  final String? url;
  final bool autofocus;
  final VoidCallback onOk;

  const _ImagenFicha({
    required this.url,
    required this.onOk,
    this.autofocus = false,
  });

  @override
  State<_ImagenFicha> createState() => _ImagenFichaState();
}

class _ImagenFichaState extends State<_ImagenFicha> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    final url = widget.url;

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (v) {
        setState(() => _foco = v);
        if (v) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 180),
          );
        }
      },
      // OK SE LEE DIRECTO DE LA TECLA, sin Actions ni Intents.
      //
      // Dos intentos fallaron antes en el aparato: un `Actions` colgado DENTRO
      // del `Focus` (los Intent se despachan hacia ARRIBA, asi que no se
      // consultaba nunca) y `onShowFocusHighlight`, que depende de
      // `FocusManager.highlightMode` y con el mando de un televisor no se pone
      // en modo teclado. Leer la tecla no depende de ninguna de las dos cosas.
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.gameButtonA) {
          widget.onOk();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 360,
        height: 203,
        decoration: const BoxDecoration(color: Color(0xFF1A1A1E)),
        // El recuadro del foco va POR ENCIMA de la imagen, no alrededor.
        //
        // Como borde normal dejaba un marco oscuro permanente aun sin foco: el
        // borde transparente sigue ocupando y deja ver el color de la caja de
        // debajo. Asi la imagen llega hasta el filo y el blanco solo aparece
        // cuando esta seleccionada.
        foregroundDecoration: BoxDecoration(
          border: Border.all(
            color: _foco ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url != null && url.isNotEmpty)
              Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder:
                    (_, _, _) => const Icon(
                      Icons.movie_outlined,
                      color: Colors.white24,
                      size: 52,
                    ),
              )
            else
              const Icon(Icons.movie_outlined, color: Colors.white24, size: 52),

            // El play solo aparece con el foco encima. Puesto siempre seria un
            // adorno; asi es la señal de que ESTO es lo que se pulsa, que es
            // justo lo que hay que decir al quitar el boton de debajo.
            if (_foco)
              const Center(
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.white,
                  size: 58,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Cada tecla de la fila de episodios: un numero, o el play de la primera.
class _CeldaEpisodio extends StatefulWidget {
  final String? texto;
  final IconData? icono;
  final bool marcada;
  final VoidCallback onOk;

  const _CeldaEpisodio({
    this.texto,
    this.icono,
    this.marcada = false,
    required this.onOk,
  });

  @override
  State<_CeldaEpisodio> createState() => _CeldaEpisodioState();
}

class _CeldaEpisodioState extends State<_CeldaEpisodio> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (v) {
        setState(() => _foco = v);
        if (v) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 180),
          );
        }
      },
      // OK SE LEE DIRECTO DE LA TECLA, sin Actions ni Intents.
      //
      // Dos intentos fallaron antes en el aparato: un `Actions` colgado DENTRO
      // del `Focus` (los Intent se despachan hacia ARRIBA, asi que no se
      // consultaba nunca) y `onShowFocusHighlight`, que depende de
      // `FocusManager.highlightMode` y con el mando de un televisor no se pone
      // en modo teclado. Leer la tecla no depende de ninguna de las dos cosas.
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.gameButtonA) {
          widget.onOk();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 64,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: _foco ? Colors.white : const Color(0xFF2A2A2E),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            // Marcada pero sin foco: un filo naranja para no perder de vista
            // cual quedo puesto mientras se recorre el resto de la fila.
            color:
                widget.marcada && !_foco
                    ? const Color(0xFFF5A623)
                    : Colors.transparent,
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child:
            widget.icono != null
                ? Icon(
                  widget.icono,
                  color: _foco ? Colors.black : Colors.white,
                  size: 22,
                )
                : Text(
                  widget.texto ?? '',
                  style: TextStyle(
                    color: _foco ? Colors.black : Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
      ),
    );
  }
}

/// Una carátula de la fila "Quizás te guste".
class _CardSugerencia extends StatefulWidget {
  final M3UItem item;
  final VoidCallback onOk;
  const _CardSugerencia({required this.item, required this.onOk});

  @override
  State<_CardSugerencia> createState() => _CardSugerenciaState();
}

class _CardSugerenciaState extends State<_CardSugerencia> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (v) {
        setState(() => _foco = v);
        if (v) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 180),
          );
        }
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.gameButtonA) {
          widget.onOk();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 117,
        margin: const EdgeInsets.only(right: 12),
        // El recuadro del foco va POR ENCIMA de la caratula, no alrededor.
        //
        // Puesto como borde normal dejaba un marco oscuro permanente incluso
        // sin foco —el borde transparente sigue ocupando y deja ver el fondo—,
        // y las caratulas parecian enmarcadas en negro. Asi la imagen llega
        // hasta el filo y el blanco solo aparece cuando toca.
        foregroundDecoration: BoxDecoration(
          border: Border.all(
            color: _foco ? Colors.white : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Image.network(
          widget.item.logo ?? '',
          fit: BoxFit.cover,
          errorBuilder:
              (_, _, _) => Container(
                color: const Color(0xFF1A1A1E),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.movie_outlined,
                  color: Colors.white24,
                  size: 30,
                ),
              ),
        ),
      ),
    );
  }
}

/// Numero de temporada en la ficha de una serie.
class _ChipTemporada extends StatefulWidget {
  final int numero;
  final bool elegida;
  final VoidCallback onOk;

  const _ChipTemporada({
    required this.numero,
    required this.elegida,
    required this.onOk,
  });

  @override
  State<_ChipTemporada> createState() => _ChipTemporadaState();
}

class _ChipTemporadaState extends State<_ChipTemporada> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    // Dos estados que se leen a la vez y significan cosas distintas: cual estas
    // MIRANDO (el foco, borde blanco) y cual esta PUESTA (el relleno). Sin
    // separarlos, mover el foco parece cambiar de temporada sin haber pulsado.
    final color = widget.elegida || _foco ? Colors.white : Colors.white54;

    return Focus(
      onFocusChange: (v) => setState(() => _foco = v),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.gameButtonA) {
          widget.onOk();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color:
              widget.elegida
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _foco ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: Text(
          'Temporada ${widget.numero}',
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontWeight: widget.elegida ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// Marca de servidor: V1+ (hay alternativas) o BD (contenido propio).
class _Distintivo extends StatelessWidget {
  final String texto;
  const _Distintivo({required this.texto});

  @override
  Widget build(BuildContext context) {
    final esV1 = texto == 'V1+';
    // Rojo para V1+ y verde para BD, igual que en el telefono: son dos cosas
    // distintas y el color es lo que las separa de un vistazo desde el sofa.
    final color = esV1 ? const Color(0xFFE50914) : const Color(0xFF34C759);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        texto,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
