import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/m3u_service.dart';
import '../../services/watch_progress_service.dart';
import 'tv_detail_screen.dart';

/// Catálogo del televisor: filas por categoría, navegación con el mando.
///
/// POR QUÉ FILAS Y NO UNA REJILLA
/// Una rejilla obliga a recordar dónde estabas en dos ejes a la vez. Con filas,
/// arriba/abajo cambia de tema y izquierda/derecha recorre ese tema: cada
/// dirección significa una sola cosa. Es lo que hacen todas las apps de TV, y
/// es por esto.
///
/// EL FOCO LO LLEVA FLUTTER
/// No hay índices a mano. Cada tarjeta es un `Focus` y el recorrido lo resuelve
/// el motor de Flutter; lo único que se añade es desplazar la fila para que la
/// tarjeta enfocada quede a la vista. Llevar los índices a mano parece más
/// controlable hasta que hay filas de distinta longitud, y entonces son cien
/// casos límite escritos a mano contra uno ya resuelto.
class TvCatalogScreen extends StatefulWidget {
  const TvCatalogScreen({super.key});

  @override
  State<TvCatalogScreen> createState() => _TvCatalogScreenState();
}

class _TvCatalogScreenState extends State<TvCatalogScreen> {
  final _servicio = M3UService();
  bool _cargando = true;
  String? _error;
  List<({String titulo, List<M3UItem> items})> _filas = const [];

  /// Lo que el usuario dejo a medias. Se cruza el historial con el catalogo
  /// por URL: el historial guarda donde te quedaste, pero no la caratula.
  List<M3UItem> _seguirViendo = const [];

  // Techos deliberados. Un proveedor puede traer cientos de categorías y miles
  // de títulos; pintarlos todos en un aparato de 1 GB de RAM es cómo se cuelga
  // un televisor. Nadie baja de la fila veinte con un mando, tampoco.
  static const int _maxFilas = 20;
  static const int _maxPorFila = 30;

  // ── Secciones del lateral ────────────────────────────────────────────────
  //
  // No hay "TV en vivo": esta app no lo maneja, y una entrada que no lleva a
  // ningun sitio es peor que no tenerla.
  //
  // Telenovelas y Animacion se resuelven por el NOMBRE de la categoria del
  // proveedor, que es el unico dato que hay. Es aproximado a proposito: mas
  // vale que caiga alguna de mas a que la seccion salga vacia.
  static const List<({String texto, IconData icono})> _secciones = [
    (texto: 'INICIO', icono: Icons.home_outlined),
    (texto: 'PELÍCULAS', icono: Icons.movie_outlined),
    (texto: 'SERIES', icono: Icons.smart_display_outlined),
    (texto: 'TELENOVELAS', icono: Icons.favorite_outline),
    (texto: 'ANIMACIÓN', icono: Icons.child_care_outlined),
  ];

  int _seccion = 0;
  final List<FocusNode> _nodosLateral = List.generate(
    _secciones.length,
    (i) => FocusNode(debugLabel: 'lateral$i'),
  );

  /// Cambia el foco del contenido al lateral y al reves. Se guarda para poder
  /// volver a la tarjeta que se estaba mirando.
  final FocusNode _nodoContenido = FocusNode(
    debugLabel: 'contenido',
    skipTraversal: true,
  );

  static const Set<String> _clavesNovela = {'novela', 'telenovela', 'turca'};
  static const Set<String> _clavesAnimacion = {
    'anime',
    'animad',
    'animacion',
    'animación',
    'infantil',
    'kids',
    'dibujos',
  };

  bool _encaja(String categoria, Set<String> claves) {
    final c = categoria.toLowerCase();
    return claves.any(c.contains);
  }

  @override
  void initState() {
    super.initState();
    // El servicio avisa DOS veces: al publicar los items en crudo —antes de
    // indexar— y al terminar. La primera llena la pantalla en segundos; la
    // segunda añade las series agrupadas y el contenido propio.
    _servicio.addListener(_alLlegarDatos);
    _cargar();
  }

  @override
  void dispose() {
    _servicio.removeListener(_alLlegarDatos);
    for (final n in _nodosLateral) {
      n.dispose();
    }
    _nodoContenido.dispose();
    super.dispose();
  }

  void _alLlegarDatos() {
    if (!mounted) return;
    // Solo se repinta si hay algo nuevo que enseñar. `notifyListeners` salta
    // por muchos motivos y reconstruir el catalogo entero por cada uno costaria
    // mas que lo que se gana.
    final hayPreliminares = _servicio.itemsPreliminares.isNotEmpty;
    final hayIndexado =
        _servicio.movies.isNotEmpty || _servicio.series.isNotEmpty;
    if (!hayPreliminares && !hayIndexado) return;
    setState(() {
      _filas = _armarFilas();
      _cargando = false;
      if (_filas.isNotEmpty) _error = null;
    });
  }

  /// Filas de una seccion concreta del lateral.
  ///
  /// PELÍCULAS y SERIES salen de las listas ya clasificadas. Telenovelas y
  /// Animacion se sacan del nombre de la categoria: el proveedor no marca el
  /// genero de ninguna otra forma.
  List<({String titulo, List<M3UItem> items})> _filasDeSeccion() {
    final filas = <({String titulo, List<M3UItem> items})>[];
    final porCategoria = <String, List<M3UItem>>{};

    Iterable<M3UItem> fuente;
    bool Function(String)? filtro;

    switch (_seccion) {
      case 1: // PELÍCULAS
        fuente = _servicio.movies;
        break;
      case 2: // SERIES
        fuente = _servicio.series;
        break;
      case 3: // TELENOVELAS
        fuente = [..._servicio.movies, ..._servicio.series];
        filtro = (c) => _encaja(c, _clavesNovela);
        break;
      default: // ANIMACIÓN
        fuente = [..._servicio.movies, ..._servicio.series];
        filtro = (c) => _encaja(c, _clavesAnimacion);
    }

    for (final it in fuente) {
      if (it.isLive) continue;
      if (filtro != null && !filtro(it.category)) continue;
      (porCategoria[it.category] ??= <M3UItem>[]).add(it);
    }

    for (final e in porCategoria.entries) {
      if (filas.length >= _maxFilas) break;
      if (e.value.length < 3) continue;
      filas.add((titulo: e.key, items: e.value.take(_maxPorFila).toList()));
    }
    return filas;
  }

  /// Primera pasada: SOLO PELICULAS, con los items en crudo.
  ///
  /// El agrupado por serie sale del isolate que todavia no ha terminado, asi
  /// que de las series solo hay episodios sueltos. Una fila de "Capitulo 3",
  /// "Capitulo 7"... se ve rota y barata: mejor enseñar unicamente lo que ya
  /// esta completo y bien, y que las series aparezcan cuando existan de verdad.
  List<({String titulo, List<M3UItem> items})> _filasPreliminares() {
    final filas = <({String titulo, List<M3UItem> items})>[];
    final porCategoria = <String, List<M3UItem>>{};

    for (final it in _servicio.itemsPreliminares) {
      if (it.isLive || it.seriesName != null) continue;
      (porCategoria[it.category] ??= <M3UItem>[]).add(it);
    }
    for (final e in porCategoria.entries) {
      if (filas.length >= _maxFilas) break;
      if (e.value.length < 3) continue;
      filas.add((titulo: e.key, items: e.value.take(_maxPorFila).toList()));
    }
    return filas;
  }

  /// Arma las filas con lo mejor que haya AHORA MISMO.
  List<({String titulo, List<M3UItem> items})> _armarFilas() {
    // Todavia sin indexar: se pinta lo que se puede en vez de dejar la pantalla
    // vacia 15 segundos mas.
    if (_servicio.movies.isEmpty && _servicio.series.isEmpty) {
      return _filasPreliminares();
    }

    // Cada seccion se sirve de una fuente distinta. INICIO es la mezcla de
    // siempre; el resto filtra.
    if (_seccion != 0) return _filasDeSeccion();

    // Cuantas peliculas y cuantas series hay de verdad, y cuantas de esas
    // series traen episodios. Sin este dato es imposible saber si una serie
    // sale mal porque esta mal agrupada o porque nunca llego a la fila.
    final conEpisodios =
        _servicio.series.where((e) => e.episodes.isNotEmpty).length;
    debugPrint(
      'TvCatalogo: peliculas=${_servicio.movies.length} '
      'series=${_servicio.series.length} (con episodios: $conEpisodios)',
    );

    final filas = <({String titulo, List<M3UItem> items})>[];

    // Seguir viendo. Se calcula aparte porque el historial es una lectura
    // asincrona y esto tiene que poder correr en cualquier momento.
    if (_seguirViendo.isNotEmpty) {
      filas.add((titulo: 'Seguir viendo', items: _seguirViendo));
    }

    // Novedades, con los episodios sustituidos por SU SERIE.
    //
    // `latestItems` mezcla peliculas y episodios recien anadidos. Un episodio
    // suelto en la fila de novedades no sirve de nada: no se sabe de que
    // serie es y al abrirlo no hay donde elegir. Se cambia por la serie
    // entera, sin repetir.
    final porNombreSerie = {
      for (final se in _servicio.series)
        if (se.seriesName != null) se.seriesName!: se,
    };
    final novedades = <M3UItem>[];
    final vistos = <String>{};
    for (final it in _servicio.latestItems) {
      final elegido = porNombreSerie[it.seriesName] ?? it;
      if (elegido.isLive || !vistos.add(elegido.url)) continue;
      novedades.add(elegido);
      if (novedades.length >= _maxPorFila) break;
    }
    if (novedades.isNotEmpty) {
      filas.add((titulo: 'Novedades', items: novedades));
    }

    // PELICULAS y SERIES, INTERCALADAS.
    //
    // `items` no vale: trae los episodios SUELTOS, uno por tarjeta, asi que
    // la lista salia llena de "Capitulo 3" y una serie no se distinguia de
    // una pelicula. `series` los trae ya agrupados, con sus episodios dentro,
    // que es lo que la ficha necesita para ofrecer temporadas.
    //
    // Y se INTERCALAN. Al concatenar peliculas y luego series, el mapa
    // quedaba con todas las categorias de peliculas primero: con el tope de
    // filas, las series no llegaban a pintarse NUNCA. Alternando una y una,
    // ambas entran pase lo que pase.
    final catPelis = <String, List<M3UItem>>{};
    for (final it in _servicio.movies) {
      if (it.isLive) continue;
      (catPelis[it.category] ??= <M3UItem>[]).add(it);
    }
    final catSeries = <String, List<M3UItem>>{};
    for (final it in _servicio.series) {
      if (it.isLive) continue;
      (catSeries[it.category] ??= <M3UItem>[]).add(it);
    }

    final colaPelis = catPelis.entries.toList();
    final colaSeries = catSeries.entries.toList();
    int ip = 0, iss = 0;

    while (filas.length < _maxFilas &&
        (ip < colaPelis.length || iss < colaSeries.length)) {
      for (final cola in [colaPelis, colaSeries]) {
        final esPelis = identical(cola, colaPelis);
        var i = esPelis ? ip : iss;
        // Una fila de dos se ve rota, asi que se salta.
        while (i < cola.length && cola[i].value.length < 3) {
          i++;
        }
        if (i >= cola.length) {
          if (esPelis) {
            ip = i;
          } else {
            iss = i;
          }
          continue;
        }
        filas.add((
          titulo: cola[i].key,
          items: cola[i].value.take(_maxPorFila).toList(),
        ));
        if (esPelis) {
          ip = i + 1;
        } else {
          iss = i + 1;
        }
        if (filas.length >= _maxFilas) break;
      }
    }

    return filas;
  }

  Future<void> _cargar() async {
    try {
      await _servicio.init();

      // `init()` prepara el servicio pero NO descarga los titulos: eso lo hace
      // `loadM3UContent()`. Faltaba, y por eso el catalogo salia vacio aunque
      // las fuentes estuvieran bien puestas — el televisor no llegaba a pedir
      // nada al proveedor.
      //
      // Con reintentos: el TV suele arrancar a la vez que el wifi, y un primer
      // intento fallido no puede dejar la pantalla en "no hay contenido" para
      // siempre.
      if (_servicio.items.isEmpty) {
        await _servicio.loadM3UContent(useRetry: true);
      }

      // El historial, antes de armar nada: es una lectura asincrona y no puede
      // vivir dentro del armado, que corre tambien desde el listener.
      try {
        final historial = await WatchProgressService().getHistory();
        final porUrl = <String, M3UItem>{
          for (final it in _servicio.items) it.url: it,
        };
        final siguiendo = <M3UItem>[];
        for (final h in historial) {
          if (h.isCompleted) continue; // terminado no es "seguir viendo"
          final it = porUrl[h.url];
          if (it != null) siguiendo.add(it);
          if (siguiendo.length >= 12) break;
        }
        _seguirViendo = siguiendo;
      } catch (_) {
        // El historial es un extra: si falla, el catalogo sale igual.
      }
      if (!mounted) return;

      if (!mounted) return;
      setState(() {
        _filas = _armarFilas();
        _cargando = false;
        // Sin fuentes el mensaje del servicio habla de "URL M3U", que al
        // usuario de un televisor no le dice nada: el nunca configuro ninguna
        // URL, la trajo la vinculacion.
        _error =
            _filas.isEmpty
                ? (_servicio.sources.isEmpty
                    ? 'No se pudo traer tu contenido. Vuelve a vincular el '
                        'televisor desde el teléfono.'
                    : (_servicio.lastError ?? 'No hay contenido disponible.'))
                : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = 'No se pudo cargar el catálogo.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const _Centrado(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Centrado(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: const TextStyle(color: Colors.white70, fontSize: 20),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              autofocus: true,
              onPressed: () {
                setState(() {
                  _cargando = true;
                  _error = null;
                });
                _cargar();
              },
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    return Container(
      color: Colors.black,
      // ── El lateral va ENCIMA del contenido, no al lado ──────────────
      //
      // Es lo que le da el aire moderno de la referencia: las caratulas siguen
      // por debajo y el menu flota sobre ellas. En una columna aparte el
      // lateral se lleva un trozo de pantalla que en un televisor es justo lo
      // que no sobra.
      //
      // Debajo del menu va un degradado de negro a transparente. Sin el, el
      // texto se pierde en cuanto pasa por encima de un poster claro — y ese
      // es el precio de superponer: hay que ganarse la legibilidad.
      child: Stack(
        children: [
          Positioned.fill(
            child: FocusTraversalGroup(
              child: Focus(
                focusNode: _nodoContenido,
                // Al recibir el foco lo pasa a la primera tarjeta: este nodo es
                // solo la puerta de entrada desde el lateral.
                onFocusChange: (v) {
                  if (v) {
                    _nodoContenido.nextFocus();
                  }
                },
                child:
                    _filas.isEmpty
                        ? const Center(
                          child: Text(
                            'Nada por aquí todavía.',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 18,
                            ),
                          ),
                        )
                        : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(0, 36, 0, 40),
                          itemCount: _filas.length,
                          itemBuilder: (context, i) {
                            final fila = _filas[i];
                            return _Fila(
                              titulo: fila.titulo,
                              items: fila.items,
                              // Solo la primerísima tarjeta pide el foco: si lo pidieran todas
                              // las primeras de cada fila, el foco saltaría a la última en
                              // construirse y la pantalla arrancaría por el medio.
                              autofocoPrimero: i == 0,
                              onSalirIzquierda:
                                  () => _nodosLateral[_seccion].requestFocus(),
                            );
                          },
                        ),
              ),
            ),
          ),

          // ── El menu, ENCIMA del contenido ──────────────────────────────
          //
          // Con un degradado de negro a transparente por debajo. Sin el, el
          // texto se pierde en cuanto pasa sobre un poster claro: ese es el
          // precio de superponer, y hay que pagarlo o no se lee.
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [Colors.black, Colors.black87, Colors.transparent],
                  stops: [0.0, 0.6, 1.0],
                ),
              ),
              // ── Barra lateral ──────────────────────────────────────────────
              //
              // Sin buscador ni iconos de cuenta: cada uno seria una promesa que
              // hay que cumplir, y hoy no llevan a ninguna parte. Y sin "TV en
              // vivo", que esta app no maneja.
              child: _Lateral(
                secciones: _secciones,
                activa: _seccion,
                nodos: _nodosLateral,
                onElegir: (i) {
                  if (i == _seccion) return;
                  setState(() {
                    _seccion = i;
                    _filas = _armarFilas();
                  });
                },
                onEntrarContenido: () => _nodoContenido.requestFocus(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Fila extends StatelessWidget {
  final String titulo;
  final List<M3UItem> items;
  final bool autofocoPrimero;
  final VoidCallback onSalirIzquierda;

  const _Fila({
    required this.titulo,
    required this.items,
    required this.autofocoPrimero,
    required this.onSalirIzquierda,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 34),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 172, bottom: 14),
            child: Text(
              titulo,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            // Caratula (240) + separacion + titulo debajo.
            height: 284,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              // Empieza donde acaba el menu: las caratulas pasan POR DEBAJO de
              // el al desplazarse, pero la primera nunca queda tapada.
              padding: const EdgeInsets.only(left: 172, right: 20),
              itemCount: items.length,
              itemBuilder:
                  (context, i) => _Tarjeta(
                    item: items[i],
                    autofoco: autofocoPrimero && i == 0,
                    // Solo la primera de cada fila vuelve al lateral: desde las
                    // de en medio, izquierda tiene que seguir recorriendo.
                    onSalirIzquierda: i == 0 ? onSalirIzquierda : null,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tarjeta extends StatefulWidget {
  final M3UItem item;
  final bool autofoco;
  final VoidCallback? onSalirIzquierda;
  const _Tarjeta({
    required this.item,
    required this.autofoco,
    this.onSalirIzquierda,
  });

  @override
  State<_Tarjeta> createState() => _TarjetaState();
}

class _TarjetaState extends State<_Tarjeta> {
  bool _foco = false;
  final FocusNode _nodo = FocusNode(debugLabel: 'tarjetaTv');

  @override
  void initState() {
    super.initState();
    // La primera tarjeta TOMA el foco tras el primer fotograma.
    //
    // `autofocus` no basta: solo actua cuando NADIE tiene el foco, y el `Focus`
    // raiz del receptor lo pide a mano en su `initState`, que corre antes. Con
    // el raiz ocupando la pantalla entera, la navegacion direccional tampoco
    // sabe bajar hasta aqui: el catalogo se pintaba y no habia forma de mover
    // el foco ni de pulsar OK.
    //
    // Es el mismo patron que ya resolvio el boton "Activar este televisor".
    if (widget.autofoco) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nodo.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _nodo.dispose();
    super.dispose();
  }

  void _abrir() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvDetailScreen(item: widget.item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _nodo,
      onFocusChange: (v) {
        setState(() => _foco = v);
        if (v) {
          // Traer la tarjeta a la vista. `alignment: 0.5` la deja centrada, que
          // es lo que hace que se intuya que hay mas a los lados.
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      },
      // OK SE LEE DIRECTO DE LA TECLA, sin Actions ni Intents.
      //
      // Dos intentos fallaron antes en el aparato:
      //  1. `Actions` colgado DENTRO del `Focus`. `ActivateIntent` se despacha
      //     hacia ARRIBA desde el nodo con foco, asi que ese `Actions` no se
      //     consultaba nunca. El foco se movia y OK no hacia nada.
      //  2. `FocusableActionDetector` con `onShowFocusHighlight`. Ese callback
      //     depende de `FocusManager.highlightMode`, que con el mando de un
      //     televisor no se pone en modo teclado: dejo de pintarse el foco.
      //
      // Leer la tecla en `onKeyEvent` no depende de ninguna de las dos cosas.
      // Es lo que ya hace el boton de activar el televisor, que si responde.
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.gameButtonA) {
          _abrir();
          return KeyEventResult.handled;
        }
        // Izquierda desde la PRIMERA tarjeta devuelve al lateral. Es el camino
        // de vuelta: sin el, una vez dentro del contenido no habria forma de
        // cambiar de seccion.
        if (k == LogicalKeyboardKey.arrowLeft &&
            widget.onSalirIzquierda != null) {
          widget.onSalirIzquierda!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: _abrir,
        child: SizedBox(
          width: 160,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── La carátula ────────────────────────────────────────────
              //
              // Sin esquinas redondeadas y con el borde de foco fino, como en
              // la referencia: el poster ya trae su propio diseño y recortarlo
              // o enmarcarlo grueso le quita presencia.
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 160,
                height: 240,
                margin: const EdgeInsets.only(right: 14),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _foco ? Colors.white : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: const Color(0xFF1A1A1E)),
                    if (widget.item.logo != null &&
                        widget.item.logo!.isNotEmpty)
                      Image.network(
                        widget.item.logo!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // ── El título, SIEMPRE debajo ──────────────────────────────
              //
              // Antes solo salia encima de la caratula al enfocarla. Debajo y
              // permanente se lee mejor —no compite con la imagen— y de un
              // vistazo se ve toda la fila sin ir tarjeta por tarjeta.
              //
              // El de la tarjeta enfocada se aclara; el resto queda en gris.
              // Mismo grosor en los dos: la negrita ensancharia el texto y
              // movería las tarjetas al recorrer la fila.
              SizedBox(
                width: 146,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 130),
                  style: TextStyle(
                    color: _foco ? Colors.white : Colors.white54,
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                  ),
                  child: Text(
                    widget.item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Centrado extends StatelessWidget {
  final Widget child;
  const _Centrado({required this.child});

  @override
  Widget build(BuildContext context) =>
      Container(color: Colors.black, child: Center(child: child));
}

/// Barra lateral del catálogo.
///
/// SIN BUSCADOR NI ICONOS DE CUENTA
/// La referencia los lleva arriba a la derecha, pero cada uno sería una promesa
/// que hay que cumplir: hoy no llevan a ninguna parte. Un icono que no hace
/// nada resta más de lo que decora.
///
/// Y sin "TV en vivo": esta app no lo maneja.
class _Lateral extends StatelessWidget {
  final List<({String texto, IconData icono})> secciones;
  final int activa;
  final List<FocusNode> nodos;
  final ValueChanged<int> onElegir;
  final VoidCallback onEntrarContenido;

  const _Lateral({
    required this.secciones,
    required this.activa,
    required this.nodos,
    required this.onElegir,
    required this.onEntrarContenido,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // Estrecho y pegado al contenido, como en la referencia: el lateral es
      // una guia, no una columna con peso propio. Cuanto menos separe, mas
      // sitio queda para lo que se viene a ver.
      width: 158,
      padding: const EdgeInsets.only(left: 26, top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Marca arriba, como en la referencia.
          Row(
            children: [
              Container(
                width: 15,
                height: 15,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: Alignment(-0.4, -0.5),
                    radius: 1.2,
                    colors: [
                      Color(0xFFFF6B5E),
                      Color(0xFFE53935),
                      Color(0xFFB71C1C),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Text(
                'Bump Comba',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 44),

          for (int i = 0; i < secciones.length; i++)
            _ItemLateral(
              texto: secciones[i].texto,
              icono: secciones[i].icono,
              activa: i == activa,
              nodo: nodos[i],
              onElegir: () => onElegir(i),
              onDerecha: onEntrarContenido,
              onArriba: i > 0 ? () => nodos[i - 1].requestFocus() : null,
              onAbajo:
                  i < secciones.length - 1
                      ? () => nodos[i + 1].requestFocus()
                      : null,
            ),
        ],
      ),
    );
  }
}

class _ItemLateral extends StatefulWidget {
  final String texto;
  final IconData icono;
  final bool activa;
  final FocusNode nodo;
  final VoidCallback onElegir;
  final VoidCallback onDerecha;
  final VoidCallback? onArriba;
  final VoidCallback? onAbajo;

  const _ItemLateral({
    required this.texto,
    required this.icono,
    required this.activa,
    required this.nodo,
    required this.onElegir,
    required this.onDerecha,
    this.onArriba,
    this.onAbajo,
  });

  @override
  State<_ItemLateral> createState() => _ItemLateralState();
}

class _ItemLateralState extends State<_ItemLateral> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    // Tres estados y no dos, porque son tres cosas distintas y el usuario tiene
    // que poder separarlas de un vistazo desde el sofá:
    //  · la sección ABIERTA (roja, es donde estás)
    //  · la que estás MIRANDO con el mando (blanca)
    //  · el resto (gris)
    //
    // Sin separar "abierta" de "enfocada", mover el mando parecería cambiar de
    // sección sin haber pulsado nada.
    final Color color;
    if (_foco) {
      color = Colors.white;
    } else if (widget.activa) {
      color = const Color(0xFFE50914);
    } else {
      color = Colors.white38;
    }

    return Focus(
      focusNode: widget.nodo,
      onFocusChange: (v) => setState(() => _foco = v),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;

        if (k == LogicalKeyboardKey.arrowRight) {
          widget.onDerecha();
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowUp && widget.onArriba != null) {
          widget.onArriba!();
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowDown && widget.onAbajo != null) {
          widget.onAbajo!();
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.gameButtonA) {
          widget.onElegir();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 26),
        child: Row(
          children: [
            Icon(widget.icono, size: 19, color: color),
            const SizedBox(width: 11),
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 130),
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight:
                      widget.activa || _foco
                          ? FontWeight.w700
                          : FontWeight.w500,
                  letterSpacing: 0.6,
                ),
                child: Text(widget.texto, maxLines: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
