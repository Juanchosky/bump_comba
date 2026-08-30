import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/m3u_item.dart';
import '../../services/m3u_service.dart';
import '../../services/tmdb_service.dart';
import 'tv_player_screen.dart';

/// Ficha de un título en el televisor.
///
/// DE DÓNDE SALE LA INFORMACIÓN
/// El catálogo solo trae nombre, categoría y carátula: con eso no se decide si
/// ver algo. La sinopsis, el año, la duración, la nota y el reparto vienen de
/// TMDB, el mismo servicio que ya usa la ficha del teléfono — así las dos
/// pantallas cuentan lo mismo del mismo título.
///
/// Y LLEGA TARDE, A PROPÓSITO
/// TMDB es una llamada de red: si la ficha esperase a tenerla, pulsar una
/// carátula daría pantalla en negro un segundo. Aquí se pinta al instante todo
/// lo que ya se sabe —título, carátula, botón de reproducir— y lo de TMDB
/// aparece cuando llega. Lo importante es que el botón de reproducir NO se
/// mueve al llegar los datos: quien va directo a darle a OK no se encuentra el
/// foco en otro sitio a mitad de gesto.
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

  @override
  void initState() {
    super.initState();
    _buscarFicha();
    _cargarEpisodios();
  }

  /// Pide los episodios al proveedor si el item no los trae.
  ///
  /// No bloquea la ficha: el titulo, la caratula y el boton de reproducir se
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
    r'(?:19|20)\d{2}|\(\s*\)',
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

  // ── Datos derivados de la ficha ──────────────────────────────────────────
  String? get _anio {
    final f = _ficha?['release_date'] ?? _ficha?['first_air_date'];
    if (f is String && f.length >= 4) return f.substring(0, 4);
    return null;
  }

  String? get _nota {
    final v = _ficha?['vote_average'];
    if (v is num && v > 0) return v.toStringAsFixed(1);
    return null;
  }

  String? get _duracion {
    final r = _ficha?['runtime'];
    if (r is num && r > 0) return '${r.toInt()} min';
    final e = _ficha?['episode_run_time'];
    if (e is List && e.isNotEmpty && e.first is num && e.first > 0) {
      return '${(e.first as num).toInt()} min';
    }
    return widget.item.duration;
  }

  List<String> get _generos {
    final g = _ficha?['genres'];
    if (g is! List) return const [];
    return [
      for (final x in g.take(3))
        if (x is Map && x['name'] is String) x['name'] as String,
    ];
  }

  String get _sinopsis {
    final o = _ficha?['overview'];
    return (o is String) ? o.trim() : '';
  }

  List<String> get _reparto {
    final c = _ficha?['credits'];
    if (c is! Map) return const [];
    final cast = c['cast'];
    if (cast is! List) return const [];
    return [
      for (final p in cast.take(4))
        if (p is Map && p['name'] is String) p['name'] as String,
    ];
  }

  String? get _fondo {
    final b = _ficha?['backdrop_path'];
    if (b is String && b.isNotEmpty) {
      return 'https://image.tmdb.org/t/p/w1280$b';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final episodios = _episodios;
    final esSerie = episodios.isNotEmpty;
    final fondo = _fondo;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Fondo ────────────────────────────────────────────────────────
          //
          // El backdrop es lo que convierte una lista de datos en una ficha que
          // apetece mirar. Va muy apagado y con un degradado encima: si compite
          // con el texto, la ficha deja de leerse, que es para lo que está.
          if (fondo != null)
            Opacity(
              opacity: 0.32,
              child: Image.network(
                fondo,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Colors.black, Colors.black87, Colors.transparent],
                stops: [0.0, 0.52, 1.0],
              ),
            ),
            child: SizedBox.expand(),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(56, 44, 56, 36),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Caratula(item: widget.item),
                const SizedBox(width: 40),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.seriesName ?? widget.item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // ── V1+ / BD ────────────────────────────────────────
                      //
                      // La misma marca que la ficha del telefono. No es
                      // decorativa: dice si ese titulo tiene MAS DE UN sitio de
                      // donde tirar. Con V1+ el cambio automatico de servidor
                      // puede actuar; sin ella, si el proveedor falla no hay
                      // adonde ir.
                      //
                      // Se mira el item Y sus episodios: en una serie las
                      // alternativas suelen estar en los episodios, no en la
                      // ficha.
                      Builder(
                        builder: (context) {
                          final hayAlternativas =
                              widget.item.alternatives.isNotEmpty ||
                              _episodios.any((e) => e.alternatives.isNotEmpty);
                          final deLaBD =
                              widget.item.esDeLaBD ||
                              _episodios.any((e) => e.esDeLaBD);
                          final texto =
                              hayAlternativas ? 'V1+' : (deLaBD ? 'BD' : null);
                          if (texto == null) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _Distintivo(texto: texto),
                          );
                        },
                      ),

                      _LineaDatos(
                        anio: _anio,
                        nota: _nota,
                        duracion: _duracion,
                        episodios: esSerie ? episodios.length : null,
                        categoria: widget.item.category,
                        buscando: _buscando,
                      ),

                      if (_generos.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          _generos.join('  ·  '),
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 15,
                          ),
                        ),
                      ],

                      // ── Sinopsis ──────────────────────────────────────────
                      //
                      // Cinco líneas como techo. En una tele el texto se lee a
                      // tres metros: un bloque más largo no se lee, se saltea.
                      // Y no hay "ver más" porque abrirlo con el mando cuesta
                      // un foco más para algo que casi nadie hace.
                      if (_sinopsis.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Text(
                          _sinopsis,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            height: 1.55,
                          ),
                        ),
                      ],

                      if (_reparto.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          'Con ${_reparto.join(', ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 14,
                          ),
                        ),
                      ],

                      const SizedBox(height: 24),

                      // Mientras llegan los episodios se dice, en vez de dejar
                      // un hueco que parece que falta algo. Ocupa poco y
                      // desaparece solo.
                      if (_cargandoEpisodios) ...[
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
                        const SizedBox(height: 16),
                      ],

                      _BotonPrincipal(
                        autofocus: true,
                        icono: Icons.play_arrow_rounded,
                        texto:
                            esSerie ? 'Reproducir 1º episodio' : 'Reproducir',
                        onOk:
                            () => _reproducir(
                              esSerie ? episodios.first : widget.item,
                            ),
                      ),

                      if (esSerie) ...[
                        const SizedBox(height: 24),
                        const Text(
                          'Episodios',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // Selector de temporada, solo si hay mas de una.
                        if (_temporadas.length > 1) ...[
                          SizedBox(
                            height: 40,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                for (final t in _temporadas)
                                  _ChipTemporada(
                                    numero: t,
                                    elegida:
                                        (_temporada ?? _temporadas.first) == t,
                                    onOk: () => setState(() => _temporada = t),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],

                        Expanded(
                          child: ListView.builder(
                            // La clave incluye la temporada: sin ella, Flutter
                            // reutiliza las filas y la lista se queda con los
                            // episodios de la temporada anterior.
                            key: ValueKey(_temporada),
                            itemCount: _episodiosVisibles.length,
                            itemBuilder: (context, i) {
                              final ep = _episodiosVisibles[i];
                              return _FilaEpisodio(
                                episodio: ep,
                                onOk: () => _reproducir(ep),
                              );
                            },
                          ),
                        ),
                      ] else
                        const Spacer(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Caratula extends StatelessWidget {
  final M3UItem item;
  const _Caratula({required this.item});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 210,
        height: 315,
        color: const Color(0xFF1A1A1E),
        child:
            (item.logo != null && item.logo!.isNotEmpty)
                ? Image.network(
                  item.logo!,
                  fit: BoxFit.cover,
                  errorBuilder:
                      (_, _, _) => const Icon(
                        Icons.movie_outlined,
                        color: Colors.white24,
                        size: 52,
                      ),
                )
                : const Icon(
                  Icons.movie_outlined,
                  color: Colors.white24,
                  size: 52,
                ),
      ),
    );
  }
}

/// Año · nota · duración · episodios · categoría.
///
/// El hueco se reserva aunque no haya nada que poner todavía: si la línea
/// creciera al llegar TMDB, empujaría hacia abajo el botón de reproducir justo
/// cuando el usuario va a pulsarlo.
class _LineaDatos extends StatelessWidget {
  final String? anio;
  final String? nota;
  final String? duracion;
  final int? episodios;
  final String categoria;
  final bool buscando;

  const _LineaDatos({
    required this.anio,
    required this.nota,
    required this.duracion,
    required this.episodios,
    required this.categoria,
    required this.buscando,
  });

  @override
  Widget build(BuildContext context) {
    final partes = <String>[
      if (anio != null) anio!,
      if (duracion != null) duracion!,
      if (episodios != null) '$episodios episodios',
      if (categoria.trim().isNotEmpty) categoria.trim(),
    ];

    return SizedBox(
      height: 24,
      child: Row(
        children: [
          if (nota != null) ...[
            const Icon(Icons.star_rounded, color: Color(0xFFF5C518), size: 19),
            const SizedBox(width: 5),
            Text(
              nota!,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Text(
              partes.join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

/// Botón grande de la ficha. Blanco cuando tiene el foco, contorno cuando no.
class _BotonPrincipal extends StatefulWidget {
  final IconData icono;
  final String texto;
  final VoidCallback onOk;
  final bool autofocus;

  const _BotonPrincipal({
    required this.icono,
    required this.texto,
    required this.onOk,
    this.autofocus = false,
  });

  @override
  State<_BotonPrincipal> createState() => _BotonPrincipalState();
}

class _BotonPrincipalState extends State<_BotonPrincipal> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (v) => setState(() => _foco = v),
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
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
        decoration: BoxDecoration(
          color: _foco ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white70, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.icono,
              color: _foco ? Colors.black : Colors.white,
              size: 25,
            ),
            const SizedBox(width: 10),
            Text(
              widget.texto,
              style: TextStyle(
                color: _foco ? Colors.black : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilaEpisodio extends StatefulWidget {
  final M3UItem episodio;
  final VoidCallback onOk;
  const _FilaEpisodio({required this.episodio, required this.onOk});

  @override
  State<_FilaEpisodio> createState() => _FilaEpisodioState();
}

class _FilaEpisodioState extends State<_FilaEpisodio> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    final ep = widget.episodio;
    final numero = [
      if (ep.seasonNumber != null) 'T${ep.seasonNumber}',
      if (ep.episodeNumber != null) 'E${ep.episodeNumber}',
    ].join(' ');

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
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _foco ? Colors.white10 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 60,
              child: Text(
                numero,
                style: TextStyle(
                  color: _foco ? Colors.white : Colors.white38,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: Text(
                ep.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _foco ? Colors.white : Colors.white60,
                  fontSize: 16,
                ),
              ),
            ),
          ],
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
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
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
            fontSize: 15,
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
