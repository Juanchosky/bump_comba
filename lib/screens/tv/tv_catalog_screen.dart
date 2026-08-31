import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/m3u_service.dart';
import '../../services/watch_progress_service.dart';
import 'tv_category_screen.dart';
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

  /// "Recomendados para ti", lo mismo que calcula el telefono.
  ///
  /// Sale del historial cruzado con las categorias mas vistas, y lo resuelve
  /// el propio servicio: aqui solo se guarda el resultado, para no recalcularlo
  /// en cada repintado.
  List<M3UItem> _recomendados = const [];

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

  /// ¿Esta el usuario dentro del menu?
  ///
  /// El lateral se ENSANCHA mientras se navega por el y se recoge al pasar al
  /// contenido. Es el patron de las apps de television: mientras eliges seccion
  /// el menu manda, y en cuanto estas mirando caratulas se aparta.
  ///
  /// Recogido no desaparece: quedan los iconos, que bastan para saber donde
  /// estas y para volver.
  bool _lateralAbierto = false;
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

    // Las recomendaciones necesitan el catalogo YA indexado, y la primera vez
    // se calculan antes de que lo este: salen vacias y la fila no aparece.
    // Aqui se reintenta cuando llegan los datos buenos, una sola vez.
    if (_recomendados.isEmpty) _recalcularRecomendados();
  }

  Future<void> _recalcularRecomendados() async {
    try {
      final historial = await WatchProgressService().getHistory();
      final r = _agrupar(_servicio.getRecommendedItems(historial));
      if (!mounted || r.isEmpty) return;
      setState(() {
        _recomendados = r;
        _filas = _armarFilas();
      });
    } catch (_) {
      // Es una fila de mas: si no sale, el catalogo se ve igual.
    }
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
      // El mismo filtro que el inicio y que el telefono: fuera deportes,
      // religion, canales en directo y las categorias de cada pais.
      if (!_servicio.categoriaVisible(it.category)) continue;
      if (filtro != null && !filtro(it.category)) continue;
      (porCategoria[it.category] ??= <M3UItem>[]).add(it);
    }

    for (final cat in _servicio.ordenarCategorias(porCategoria.keys)) {
      if (filas.length >= _maxFilas) break;
      final items = porCategoria[cat]!;
      if (items.length < 3) continue;
      filas.add((titulo: cat, items: items));
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
      if (!_servicio.categoriaVisible(it.category)) continue;
      (porCategoria[it.category] ??= <M3UItem>[]).add(it);
    }
    // EN EL MISMO ORDEN QUE TENDRAN DESPUES.
    //
    // Recorrer el mapa tal cual daba el orden del proveedor, que empieza por
    // donde le parece. Se veian diez segundos de categorias en un orden y de
    // golpe la pantalla se recolocaba entera al terminar el indexado. Con la
    // misma prioridad aplicada aqui, lo que llega despues encaja donde ya
    // estaba en vez de mover todo de sitio.
    for (final cat in _servicio.ordenarCategorias(porCategoria.keys)) {
      if (filas.length >= _maxFilas) break;
      final items = porCategoria[cat]!;
      if (items.length < 3) continue;
      filas.add((titulo: cat, items: items));
    }
    return filas;
  }

  /// Cambia los episodios sueltos por SU SERIE, sin repetir.
  ///
  /// Las listas del servicio —recientes, recomendados, una categoria— traen
  /// episodios uno a uno. Un "Capitulo 7" suelto en una fila no dice de que
  /// serie es y al abrirlo no hay temporadas donde elegir. Aqui se sustituye
  /// por la serie entera, que es lo que la ficha sabe manejar.
  /// Con `tope` a null no recorta: es lo que necesita la pantalla de
  /// categoria completa, que existe justo para enseñar lo que no cabe en la
  /// fila.
  List<M3UItem> _agrupar(List<M3UItem> origen, {int? tope = _maxPorFila}) {
    final porNombreSerie = {
      for (final se in _servicio.series)
        if (se.seriesName != null) se.seriesName!: se,
    };
    final salida = <M3UItem>[];
    final vistos = <String>{};
    for (final it in origen) {
      final elegido = porNombreSerie[it.seriesName] ?? it;
      if (elegido.isLive || !vistos.add(elegido.url)) continue;
      salida.add(elegido);
      if (tope != null && salida.length >= tope) break;
    }
    return salida;
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

    final filas = <({String titulo, List<M3UItem> items})>[];

    // ── EL MISMO INICIO QUE EL TELEFONO, EN EL MISMO ORDEN ────────────────
    //
    // Ultimamente nuevo, Recomendados para ti, Seguir viendo y despues las
    // categorias del proveedor. Antes aqui habia un orden propio —Seguir
    // viendo primero, luego "Novedades", luego peliculas y series
    // intercaladas por categoria— y el resultado era que las dos pantallas de
    // la misma app enseñaban cosas distintas en sitios distintos.
    //
    // Las tres primeras filas salen de los MISMOS metodos del servicio que usa
    // el telefono, no de un calculo parecido hecho aqui: parecido no basta,
    // porque en cuanto uno de los dos cambie volveran a separarse.
    final recientes = _agrupar(_servicio.getRecentItems());
    if (recientes.isNotEmpty) {
      filas.add((titulo: 'Últimamente nuevo', items: recientes));
    }

    if (_recomendados.isNotEmpty) {
      filas.add((titulo: 'Recomendados para ti', items: _recomendados));
    }

    if (_seguirViendo.isNotEmpty) {
      filas.add((titulo: 'Seguir viendo', items: _seguirViendo));
    }

    // Y las categorias del proveedor, en el orden que manda el servicio y ya
    // sin las de deportes, religion, canales en directo ni las de cada pais:
    // ese filtro es el que le faltaba al televisor y por el que aparecian de
    // primeras categorias que en el telefono no salen.
    for (final cat in _servicio.categoriasParaMostrar()) {
      if (filas.length >= _maxFilas) break;
      // Sin tope: la fila enseña las primeras y el boton "Más" abre el resto.
      // Recortar aqui era lo que dejaba fuera medio catalogo sin manera de
      // llegar a el.
      final items = _agrupar(
        _servicio.filterValidItems(_servicio.getItemsByCategory(cat)),
        tope: null,
      );
      // Una fila de dos se ve rota, asi que se salta.
      if (items.length < 3) continue;
      filas.add((titulo: cat, items: items));
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

        // Las recomendaciones salen del mismo historial que ya se acaba de
        // leer: pedirlo dos veces seria pagar dos veces por lo mismo.
        _recomendados = _agrupar(_servicio.getRecommendedItems(historial));
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

    return DecoratedBox(
      // ── Fondo ──────────────────────────────────────────────────────────
      //
      // Sustituye al negro plano. Es oscuro y de contraste bajo a proposito:
      // detras de un catalogo, un fondo con fuerza compite con las caratulas,
      // que son lo que se viene a mirar. Este solo da temperatura.
      //
      // `cover` y no `fill`: en un televisor la proporcion puede no ser 16:9
      // exacta y estirar la imagen se nota enseguida en las diagonales.
      decoration: const BoxDecoration(
        color: Colors.black,
        image: DecorationImage(
          image: AssetImage('assets/images/fondotv.png'),
          fit: BoxFit.cover,
        ),
      ),
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
                          // 92 arriba: es lo que ocupa la marca. Sin ello el
                          // titulo de la primera categoria se le montaba
                          // encima.
                          padding: const EdgeInsets.fromLTRB(0, 92, 0, 40),
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

          // ── Velo superior ───────────────────────────────────────────
          //
          // La marca se veia "medio oscura y medio clara": la mitad caia sobre
          // el degradado del menu y la otra mitad sobre el fondo, asi que el
          // texto cambiaba de contraste por la mitad.
          //
          // Con una banda propia de negro a transparente, la marca se apoya
          // SIEMPRE en lo mismo, pase lo que pase por detras.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 120,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.92),
                      Colors.black.withValues(alpha: 0.55),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // ── La marca, FUERA del menu ────────────────────────────────────
          //
          // Vive en la pantalla, no dentro del lateral: asi no se recoge ni se
          // desvanece con el, y deja de competir por su ancho.
          Positioned(
            left: 52,
            top: 30,
            child: Text(
              'Bump Comba',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.95),
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
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
                  // El velo cubre casi todo el menu y se difumina al final: al
                  // abrirse, el texto nuevo tiene que caer sobre negro, no
                  // sobre una caratula.
                  stops: [0.0, 0.72, 1.0],
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
                abierto: _lateralAbierto,
                onFoco: (dentro) {
                  if (dentro != _lateralAbierto) {
                    setState(() => _lateralAbierto = dentro);
                  }
                },
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

  /// Cuantas caben en la fila antes de mandar al catalogo completo.
  ///
  /// Treinta ya son treinta pulsaciones a la derecha; mas alla de eso nadie
  /// llega con un mando, y para eso esta la rejilla.
  static const int _maxEnFila = 30;

  @override
  Widget build(BuildContext context) {
    final visibles =
        items.length > _maxEnFila ? items.take(_maxEnFila).toList() : items;
    final hayMas = items.length > visibles.length;

    return Padding(
      // 18 y no 34. Con el titulo ya debajo de cada caratula, la separacion
      // anterior dejaba un vacio que hacia parecer que faltaba algo entre una
      // fila y otra. Lo justo para que se lean como grupos distintos.
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 106, bottom: 10),
            child: Text(
              titulo,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // ── El margen izquierdo va FUERA del `ListView` ────────────────
          //
          // No es lo mismo que ponerlo en su `padding`: el padding se desplaza
          // con el contenido, asi que las caratulas se seguian pintando por
          // debajo del menu y asomaban por su lateral al recorrer la fila.
          // Puesto fuera, lo que se estrecha es la ventana y la fila se
          // recorta limpia justo donde empieza el titulo de la seccion.
          //
          // A la DERECHA no se toca: ahi las caratulas llegan al filo de la
          // pantalla a proposito, que es lo que dice que la fila sigue y
          // invita a seguir moviendose.
          Padding(
            padding: const EdgeInsets.only(left: 106),
            child: SizedBox(
              // Caratula (222) + hueco (8) + titulo (~15), con holgura.
              //
              // La holgura NO sobra: el televisor aplica su propia escala de
              // texto, asi que el titulo de debajo sale un pelo mas alto que
              // la cuenta de aqui. Sin ese margen, el pelo desborda la columna
              // y Flutter pinta las rayas amarillas.
              height: 252,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(right: 20),
                // Una tarjeta mas cuando la categoria no cabe entera: la de
                // "Más", que abre el catalogo completo. Solo aparece si hay
                // algo detras — ponerla siempre seria prometer contenido que
                // no existe.
                itemCount: visibles.length + (hayMas ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i == visibles.length) {
                    return _TarjetaMas(
                      restantes: items.length - visibles.length,
                      onOk:
                          () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder:
                                  (_) => TvCategoryScreen(
                                    titulo: titulo,
                                    items: items,
                                  ),
                            ),
                          ),
                    );
                  }
                  return _Tarjeta(
                    item: visibles[i],
                    autofoco: autofocoPrimero && i == 0,
                    // Solo la primera de cada fila vuelve al lateral: desde
                    // las de en medio, izquierda tiene que seguir
                    // recorriendo.
                    onSalirIzquierda: i == 0 ? onSalirIzquierda : null,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// La última tarjeta de una fila: abre la categoría entera.
///
/// Se ve distinta a proposito —sin caratula, con el icono y el numero de lo
/// que queda—: si pareciera un titulo mas, uno la abriria pensando que va a
/// ver una pelicula.
class _TarjetaMas extends StatefulWidget {
  final int restantes;
  final VoidCallback onOk;

  const _TarjetaMas({required this.restantes, required this.onOk});

  @override
  State<_TarjetaMas> createState() => _TarjetaMasState();
}

class _TarjetaMasState extends State<_TarjetaMas> {
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
      child: GestureDetector(
        onTap: widget.onOk,
        child: SizedBox(
          width: 148,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 148,
                height: 222,
                margin: const EdgeInsets.only(right: 14),
                foregroundDecoration: BoxDecoration(
                  border: Border.all(
                    color: _foco ? Colors.white : Colors.transparent,
                    width: 2,
                  ),
                ),
                decoration: BoxDecoration(
                  color: _foco ? Colors.white12 : const Color(0xFF1A1A1E),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.more_horiz_rounded,
                      color: _foco ? Colors.white : Colors.white54,
                      size: 40,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '+${widget.restantes}',
                      style: TextStyle(
                        color: _foco ? Colors.white : Colors.white38,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 134,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 130),
                  style: TextStyle(
                    color: _foco ? Colors.white : Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                  child: const Text('Ver todo'),
                ),
              ),
            ],
          ),
        ),
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
          width: 148,
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
                width: 148,
                height: 222,
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
                width: 134,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 130),
                  style: TextStyle(
                    color: _foco ? Colors.white : Colors.white54,
                    fontSize: 12,
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
  final bool abierto;
  final ValueChanged<bool> onFoco;

  const _Lateral({
    required this.secciones,
    required this.activa,
    required this.nodos,
    required this.onElegir,
    required this.onEntrarContenido,
    required this.abierto,
    required this.onFoco,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      // Estrecho y pegado al contenido, como en la referencia: el lateral es
      // una guia, no una columna con peso propio. Cuanto menos separe, mas
      // sitio queda para lo que se viene a ver.
      // Recogido caben los iconos; abierto, iconos y texto. La transicion es
      // de 220 ms: lo bastante para que se lea como un movimiento y no como un
      // salto, y lo bastante corta para no estorbar a quien va rapido.
      width: abierto ? 218 : 90,
      padding: const EdgeInsets.only(left: 30, top: 26, bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── El menu, CENTRADO en vertical ──────────────────────────
          //
          // Pegado arriba quedaba desequilibrado: marca y secciones formaban un
          // bloque en la esquina con toda la mitad inferior vacia. Centrado, el
          // menu acompaña a las filas de caratulas en vez de colgar de arriba.
          //
          // La marca se queda donde estaba —arriba es su sitio— y son los
          // `Spacer` los que empujan las secciones al centro.
          const Spacer(),

          for (int i = 0; i < secciones.length; i++)
            _ItemLateral(
              texto: secciones[i].texto,
              icono: secciones[i].icono,
              activa: i == activa,
              abierto: abierto,
              onFoco: onFoco,
              nodo: nodos[i],
              onElegir: () => onElegir(i),
              onDerecha: onEntrarContenido,
              onArriba: i > 0 ? () => nodos[i - 1].requestFocus() : null,
              onAbajo:
                  i < secciones.length - 1
                      ? () => nodos[i + 1].requestFocus()
                      : null,
            ),

          const Spacer(),
        ],
      ),
    );
  }
}

class _ItemLateral extends StatefulWidget {
  final String texto;
  final IconData icono;
  final bool activa;
  final bool abierto;
  final ValueChanged<bool> onFoco;
  final FocusNode nodo;
  final VoidCallback onElegir;
  final VoidCallback onDerecha;
  final VoidCallback? onArriba;
  final VoidCallback? onAbajo;

  const _ItemLateral({
    required this.texto,
    required this.icono,
    required this.activa,
    required this.abierto,
    required this.onFoco,
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
      onFocusChange: (v) {
        setState(() => _foco = v);
        // Cualquier item con el foco abre el menu; al salir, se recoge. El
        // padre agrupa los avisos, asi que pasar de un item a otro no lo cierra
        // y lo vuelve a abrir.
        widget.onFoco(v);
      },
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
            Icon(widget.icono, size: 20, color: color),
            const SizedBox(width: 13),
            Expanded(
              // Recogido el texto se desvanece en vez de desaparecer de golpe:
              // el ancho del menu y la opacidad viajan juntos y el movimiento
              // se lee como uno solo.
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: widget.abierto ? 1 : 0,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 130),
                  style: TextStyle(
                    color: color,
                    fontSize: 15,
                    fontWeight:
                        widget.activa || _foco
                            ? FontWeight.w700
                            : FontWeight.w500,
                    letterSpacing: 0.7,
                  ),
                  child: Text(
                    widget.texto,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
