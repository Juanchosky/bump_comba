import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/fast_image_service.dart';
import '../../services/m3u_service.dart';
import '../../services/tmdb_service.dart';
import '../../services/tv/tv_vista_previa.dart';
import '../../utils/titulo_tmdb.dart';
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

  /// Si la ficha ya se puede enseñar.
  ///
  /// LA FICHA NO SE PINTA A CACHOS.
  ///
  /// Antes cada dato entraba por su cuenta: primero el titulo, luego la
  /// sinopsis, luego los episodios, y las caratulas de abajo aparecian en un
  /// hueco que hasta entonces estaba vacio. Cada aparicion movia lo de debajo,
  /// y una pantalla que se recoloca sola tres veces se siente rota aunque
  /// funcione.
  ///
  /// Ahora se espera a tenerlo TODO —TMDB, episodios y las caratulas ya
  /// descargadas— y entra de una vez con un fundido corto. Mientras tanto solo
  /// hay fondo: nada que se mueva, nada a medias.
  bool _listo = false;

  /// Marca el recuadro de la cabecera. La vista previa vive en el `Overlay`,
  /// fuera de esta pantalla, así que hay que medirle el hueco y decírselo.
  final GlobalKey _huecoVistaPrevia = GlobalKey();

  @override
  void initState() {
    super.initState();
    _prepararFicha();
  }

  /// Junta las tres esperas y enseña la ficha cuando estan las tres.
  ///
  /// Con un PLAZO MAXIMO de dos segundos y medio. Es la parte que no puede
  /// faltar: el proveedor a veces tarda una eternidad en dar los episodios y
  /// alguna caratula no llega nunca. Sin el plazo, esos casos dejarian la
  /// pantalla en el fondo vacio para siempre — cambiar un parpadeo feo por un
  /// cuelgue no es un arreglo. Cumplido el plazo se enseña lo que haya.
  Future<void> _prepararFicha() async {
    final todo = Future.wait([
      // La imagen grande se baja detras de TMDB, que es quien dice cual es.
      // Sin esto la ficha aparecia entera menos el recuadro de la derecha, que
      // es justo el que tiene el foco: entrar y ver el hueco gris del sitio
      // que vas a pulsar es peor que esperar un instante mas.
      _buscarFicha().then((_) => _precargarImagen()),
      _cargarEpisodios(),
      _precargarSugerencias(),
    ]);
    await Future.any([todo, Future<void>.delayed(_plazoMaximo)]);
    if (mounted) setState(() => _listo = true);
    // Después del `setState`: hasta que la ficha no se pinta, el recuadro no
    // existe y no hay nada que medir.
    _arrancarVistaPrevia();
  }

  /// Pone a reproducir en el recuadro de la cabecera.
  ///
  /// Se espera al siguiente fotograma porque `_listo` acaba de cambiar y el
  /// recuadro todavía no está en pantalla: medirlo ahora daría `null`.
  bool _vistaPreviaPedida = false;

  void _arrancarVistaPrevia() {
    // Una sola vez por ficha: montarla de nuevo destruiria el reproductor que
    // ya esta resolviendo.
    if (_vistaPreviaPedida) return;
    _vistaPreviaPedida = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final hueco = _rectanguloVistaPrevia();
      if (hueco == null) return;

      final esSerie = widget.item.isSeries || widget.item.seriesName != null;
      TvVistaPrevia.instancia.mostrar(
        context,
        _queSeReproduce(esSerie, _episodios),
        hueco,
      );
    });
  }

  /// Le pasa el hueco nuevo a la vista previa. Solo mueve; no reinicia nada.
  void _reubicarVistaPrevia() {
    final hueco = _rectanguloVistaPrevia();
    if (hueco != null) TvVistaPrevia.instancia.reubicar(hueco);
  }

  /// El hueco de la cabecera en coordenadas de pantalla.
  Rect? _rectanguloVistaPrevia() {
    final caja = _huecoVistaPrevia.currentContext?.findRenderObject();
    if (caja is! RenderBox || !caja.hasSize) return null;
    return caja.localToGlobal(Offset.zero) & caja.size;
  }

  @override
  void dispose() {
    // AQUÍ SE PARA EL VÍDEO, y solo aquí.
    //
    // Volver del reproductor grande a la ficha no pasa por este `dispose` —la
    // ficha nunca se fue— así que la reproducción sigue. Salir de la ficha sí,
    // y entonces se para. Que es lo que se pidió.
    final esSerie = widget.item.isSeries || widget.item.seriesName != null;
    TvVistaPrevia.instancia.cerrarSi(_queSeReproduce(esSerie, _episodios).url);
    super.dispose();
  }

  static const Duration _plazoMaximo = Duration(milliseconds: 2500);

  /// Baja la imagen apaisada de la cabecera.
  Future<void> _precargarImagen() async {
    final url = _imagen;
    if (url == null || url.isEmpty || !mounted) return;
    await precacheImage(_proveedor(url), context, onError: (_, _) {});
  }

  /// El mismo proveedor que usa `FastThumbnail` al pintar.
  ///
  /// Con `NetworkImage` a secas la precarga no servia de nada: calentaba una
  /// entrada de cache con OTRA clave, asi que al pintar se volvia a bajar la
  /// imagen entera. Se ve como que la ficha espera y aun asi aparece vacia.
  ImageProvider _proveedor(String url) =>
      CachedNetworkImageProvider(url, cacheManager: AppCacheManager.instance);

  /// Baja las caratulas de "Quizás te guste" ANTES de enseñar la fila.
  ///
  /// Es lo que quita el efecto de fila vacia que se va rellenando sola. Los
  /// fallos se tragan a proposito: una caratula que no baja no puede retener
  /// la ficha entera.
  ///
  /// Se espera al primer fotograma antes de tocar el `context`: `precacheImage`
  /// lo consulta hacia arriba y hacerlo desde `initState` es justo lo que
  /// Flutter no deja.
  Future<void> _precargarSugerencias() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await Future.wait([
      for (final e in _sugerencias.take(8))
        if ((e.logo ?? '').isNotEmpty)
          precacheImage(_proveedor(e.logo!), context, onError: (_, _) {}),
    ]);
  }

  /// Pide los episodios al proveedor si el item no los trae.
  Future<void> _cargarEpisodios() async {
    // Los que ya vienen puestos son los buenos: no se vuelve a pedir nada.
    if (widget.item.episodes.isNotEmpty) {
      setState(() => _episodiosCargados = widget.item.episodes);
      return;
    }
    // Una pelicula no tiene episodios que pedir.
    if (!widget.item.isSeries && widget.item.seriesName == null) return;

    try {
      final eps = await M3UService().fetchEpisodesForItem(widget.item);
      if (mounted) setState(() => _episodiosCargados = eps);
    } catch (e) {
      debugPrint('TvDetalle: no se pudieron traer los episodios: $e');
    }
  }

  Future<void> _buscarFicha() async {
    try {
      final d = await TMDBService().searchAndGetDetails(
        // De una serie se busca la serie, no el episodio: "Capítulo 4" no
        // existe en TMDB, pero el nombre de la serie sí. Y limpio, porque los
        // titulos del proveedor vienen con basura pegada.
        limpiarTituloParaTmdb(widget.item.seriesName ?? widget.item.name),
        isSeries: widget.item.isSeries || widget.item.seriesName != null,
      );
      if (mounted) setState(() => _ficha = d.isEmpty ? null : d);
    } catch (_) {
      if (mounted) setState(() => _ficha = null);
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
    final alts =
        queVer.alternatives.isNotEmpty
            ? queVer.alternatives
            : M3UService().getAlternativesFor(queVer);
    final itemConAlts =
        alts.isNotEmpty && queVer.alternatives.isEmpty
            ? queVer.copyWith(alternatives: alts)
            : queVer;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => TvPlayerScreen(item: itemConAlts, titulo: itemConAlts.name),
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

  /// La clasificacion por edades: "TV-MA", "16", "PG-13"... TMDB la da por
  /// pais y `_getDetails` ya se queda con la de España, o la de EEUU si no la
  /// hay. No siempre existe, y cuando no existe no se enseña nada.
  String? get _clasificacion => _texto('rating');
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

          // ── Señal de que se esta cargando ────────────────────────────
          //
          // La espera puede llegar a dos segundos y medio, y dos segundos de
          // fondo quieto no se leen como "cargando", se leen como "se colgo".
          // El spinner es lo unico que separa una cosa de la otra.
          //
          // Se va con su propio fundido, mas rapido que el de la ficha, para
          // que los dos no se crucen a media opacidad.
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _listo ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              child: const Center(
                child: CupertinoActivityIndicator(
                  // 22 y no 16: a distancia de sofá, las aspas de este spinner
                  // son finas y a 16 apenas se distinguen del fondo.
                  radius: 22,
                  color: Colors.white,
                ),
              ),
            ),
          ),

          // ── Todo de golpe ────────────────────────────────────────────
          //
          // Un fundido corto de 260 ms y un empujoncito hacia arriba. Corto a
          // proposito: esto no es una entrada, es tapar el momento en que la
          // ficha aparece armada. Cualquier cosa mas larga o mas vistosa se
          // interpone entre el usuario y el boton de reproducir, que es a lo
          // que venia.
          AnimatedOpacity(
            opacity: _listo ? 1 : 0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
            child: AnimatedSlide(
              offset: _listo ? Offset.zero : const Offset(0, 0.02),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              // Hasta que no esta lista no se construye: asi el foco inicial
              // cae en la imagen justo cuando aparece, y no antes, sobre una
              // pantalla que el usuario todavia no ve.
              child:
                  !_listo
                      ? const SizedBox.expand()
                      // EL HUECO SE MUEVE AL HACER SCROLL.
                      //
                      // El vídeo vive en el `Overlay`, en coordenadas de
                      // pantalla: no baja con el contenido. Sin esto, bajar a
                      // "Quizás te guste" dejaba el vídeo flotando sobre el
                      // sitio donde ANTES estaba el recuadro.
                      : NotificationListener<ScrollNotification>(
                        onNotification: (_) {
                          _reubicarVistaPrevia();
                          return false;
                        },
                        child: SingleChildScrollView(
                          // 50 arriba y no 26: el título quedaba pegado al
                          // borde de la pantalla.
                          //
                          // Se toca aquí, en el relleno del scroll, y no en el
                          // título: así bajan con él la clasificación y los
                          // datos que lo rodean, la imagen que va al lado y todo
                          // lo de debajo, conservando la separación que ya
                          // tienen entre sí.
                          padding: const EdgeInsets.fromLTRB(48, 50, 48, 30),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ── Cabecera: texto a la izquierda, imagen a la derecha ────
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _cabeceraTexto(esSerie, episodios),
                                  ),
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
                                    clave: _huecoVistaPrevia,
                                    autofocus: true,
                                    // YA NO EMPUJA UNA PANTALLA NUEVA.
                                    //
                                    // La vista previa que se está viendo aquí y
                                    // el reproductor grande son el mismo, y ya
                                    // está reproduciendo: solo se agranda. Por
                                    // eso continúa por donde iba y no recarga.
                                    onOk:
                                        () => TvVistaPrevia.instancia.expandir(
                                          context,
                                        ),
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
                                    // Sin recorte, para que el 5% que crece la
                                    // enfocada no se corte arriba y abajo.
                                    clipBehavior: Clip.none,
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
                      ),
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
            fontSize: 24,
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
            linea.isNotEmpty ? linea : widget.item.category,
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

        // Marca de servidor y clasificacion, en la misma linea.
        //
        // Van juntas porque son la misma clase de dato: dos apuntes tecnicos
        // que se consultan, no que se leen. Repartidas en dos lineas ocupaban
        // el doble para decir lo mismo.
        Builder(
          builder: (context) {
            final hayAlternativas =
                widget.item.alternatives.isNotEmpty ||
                _episodios.any((e) => e.alternatives.isNotEmpty);
            final deLaBD =
                widget.item.esDeLaBD || _episodios.any((e) => e.esDeLaBD);
            final servidor = hayAlternativas ? 'V1+' : (deLaBD ? 'BD' : null);
            final edad = _clasificacion;
            if (servidor == null && edad == null) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  if (servidor != null) _Distintivo(texto: servidor),
                  if (servidor != null && edad != null)
                    const SizedBox(width: 8),
                  if (edad != null) _Distintivo(texto: edad),
                ],
              ),
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
                text: _sinopsis.isNotEmpty ? _sinopsis : 'Sin datos',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
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
  /// Va en el recuadro para poder medirlo desde fuera: la vista previa se
  /// pinta en el `Overlay` y necesita saber dónde cae este hueco.
  final GlobalKey clave;
  final bool autofocus;
  final VoidCallback onOk;

  const _ImagenFicha({
    required this.clave,
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
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (v) {
        setState(() => _foco = v);
        // El vídeo tapa este recuadro, así que el marco de foco lo dibuja el
        // `Overlay` por encima. Aquí solo se le avisa.
        TvVistaPrevia.instancia.foco = v;
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
        key: widget.clave,
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
        // AQUÍ YA NO VA NINGUNA IMAGEN.
        //
        // Había una foto fija —la apaisada de TMDB— que ocupaba el recuadro
        // hasta que entraba el vídeo. Se veía por detrás y por los bordes,
        // porque la proporción del vídeo no tiene por qué ser exactamente la
        // del hueco, y eso se lee como un montaje mal encajado.
        //
        // Antes dependía de un aviso: la foto se quitaba CUANDO el vídeo se
        // montaba. Eso deja una ventana —mientras la ficha carga y el
        // reproductor todavía no está— en la que la foto sí aparece, y luego
        // desaparece. Un parpadeo en el sitio que más se mira.
        //
        // Ahora simplemente no está. El recuadro es la caja oscura y el vídeo,
        // y no hay ningún instante intermedio que enseñe otra cosa.
        child: Stack(
          fit: StackFit.expand,
          children: [
            // El play mientras el vídeo aún no ha llegado: dice que ESTO es lo
            // que se pulsa. En cuanto hay imagen sobra —se está reproduciendo,
            // que es justo lo que el play prometía— y el marco del foco pasa a
            // dibujarlo el `Overlay`, por encima.
            ValueListenableBuilder<bool>(
              valueListenable: TvVistaPrevia.instancia.montada,
              builder:
                  (context, conVideo, _) =>
                      _foco && !conVideo
                          ? const Center(
                            child: Icon(
                              Icons.play_circle_fill_rounded,
                              color: Colors.white,
                              size: 58,
                            ),
                          )
                          : const SizedBox.shrink(),
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
      child: AnimatedScale(
        // ── El acercamiento al enfocar ──────────────────────────────────
        //
        // El mismo 5% que en el catalogo y en la rejilla. Que el foco se note
        // igual en las tres pantallas es la mitad del asunto: si cada una lo
        // marcara a su manera, habria que aprender tres.
        scale: _foco ? 1.09 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
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
              width: 2,
            ),
          ),
          child: FastThumbnail(
            url: widget.item.logo,
            width: 117,
            height: 176,
            title: widget.item.name,
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
///
/// En blanco y pequeña, a proposito. En el telefono va en rojo y verde, pero
/// alli es una lista de fichas y el color ayuda a distinguirlas de un vistazo.
/// Aqui hay UNA sola ficha y el rojo se llevaba la mirada por encima del
/// titulo, para decir algo que no manda nada: la marca es un dato tecnico, no
/// una llamada de atencion. La sigue leyendo quien la busca, y ya no compite.
class _Distintivo extends StatelessWidget {
  final String texto;
  const _Distintivo({required this.texto});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
      ),
      child: Text(
        texto,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
