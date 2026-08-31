import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../../services/fast_image_service.dart';
import '../../services/m3u_service.dart';
import '../../services/watch_progress_service.dart';
import 'tv_category_screen.dart';
import 'tv_detail_screen.dart';
import 'tv_search_screen.dart';

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
    (texto: 'BUSCAR', icono: Icons.search),
  ];

  /// BUSCAR no es una seccion del catalogo: es una pantalla aparte.
  ///
  /// Vive en la misma lista porque en el menu se recorre igual que las demas
  /// —con las mismas flechas y el mismo aspecto—, pero al pulsarla NO cambia
  /// las filas: abre el buscador y al cerrarlo el catalogo sigue como estaba,
  /// en la seccion en la que lo dejaste.
  static const int _iBuscar = 5;

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

  /// Una llave por fila, para poder decirle "ponte el foco en la columna N".
  ///
  /// Subir y bajar de fila NO se le deja a la traversal de Flutter: elige por
  /// geometria, y con las filas moviendose por su cuenta la geometria cambia
  /// mientras decide. De ahi que a veces subieras y acabaras dos filas mas
  /// abajo, o en la de al lado.
  ///
  /// POR TITULO Y NO POR POSICION.
  ///
  /// "Recomendados para ti" tarda en llegar —depende del historial y del
  /// catalogo ya indexado— y al aparecer se mete ENTRE las que ya estaban.
  /// Con llaves por posicion, esa fila nueva le pasaba su estado a la
  /// siguiente: la de la posicion 1 pasaba a ser otra categoria conservando el
  /// desplazamiento y el foco de la anterior. Se veia como que el foco saltaba
  /// solo a una fila que no habias tocado.
  ///
  /// Con la llave atada al titulo, cada fila se lleva SU estado adonde la
  /// muevan.
  final Map<String, GlobalKey<_FilaState>> _llavesFila = {};

  GlobalKey<_FilaState> _llaveDe(String titulo) =>
      _llavesFila.putIfAbsent(titulo, () => GlobalKey<_FilaState>());

  final ScrollController _scrollVertical = ScrollController();

  /// Donde estaba el foco la ultima vez. Fila y columna.
  ///
  /// Es lo que hace que volver de una ficha te devuelva DONDE ESTABAS. Sin
  /// esto, al cerrar la ficha el foco recaia en el contenedor del contenido,
  /// que lo mandaba a la primera tarjeta de la primera fila: la pantalla se
  /// iba sola al principio del catalogo y habias perdido por donde ibas.
  int _filaActual = 0;
  int _columnaActual = 0;

  /// El hueco de arriba de la lista. Entra en la cuenta del desplazamiento:
  /// sin sumarlo, la fila de destino quedaba 40 pixeles mas arriba de lo
  /// pedido — medio tapada por el borde de la pantalla. Por eso al subir a
  /// "Últimamente nuevo" o a "Recomendados para ti" el foco parecia perderse:
  /// estaba puesto, pero fuera de la vista.
  static const double _huecoArriba = 40;

  /// Alto exacto de una fila: titulo (33 con su hueco) + caratulas (248) +
  /// separacion (18), y 5 de holgura.
  ///
  /// Fijo a proposito — con `itemExtent` la lista sabe donde esta cada fila sin
  /// medirlas, y bajar a la fila N es una cuenta en vez de una busqueda.
  ///
  /// Los 33 del titulo son MEDIDOS en el aparato, no calculados: un texto de 16
  /// con la altura de linea del tema ocupa 23, no 16. Ponerlos a ojo fue lo que
  /// dejo la fila 3 pixeles corta y las rayas amarillas de desbordamiento.
  static const double _altoFila = 304;

  /// Mueve el foco a la fila `destino`, conservando la columna.
  ///
  /// PRIMERO SE DESPLAZA Y DESPUES SE PIDE EL FOCO. La lista vertical tambien
  /// es perezosa: una fila que no se ve NO existe, asi que su `currentState`
  /// es null y pedirle el foco no hace nada. Por eso bajar dos filas seguidas
  /// rapido se quedaba a medias. Se desplaza, se espera al fotograma en que la
  /// fila ya esta armada, y entonces se le da el foco.
  void _irAFila(int destino, int columna, {int intento = 0}) {
    if (destino < 0 || destino >= _filas.length) return;
    _filaActual = destino;
    _columnaActual = columna;

    if (_scrollVertical.hasClients) {
      // La fila de destino, arrimada al borde de arriba pero sin pegarse: se
      // ve entera y se intuye la siguiente.
      final objetivo = (_huecoArriba + destino * _altoFila - 24).clamp(
        0.0,
        _scrollVertical.position.maxScrollExtent,
      );
      if (intento > 0) {
        // En los reintentos se salta de golpe: volver a animar en cada
        // fotograma reinicia la animacion y la lista no llega nunca.
        _scrollVertical.jumpTo(objetivo);
      } else {
        _scrollVertical.animateTo(
          objetivo,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }

    final fila = _llaveDe(_filas[destino].titulo).currentState;
    if (fila != null) {
      fila.enfocar(columna);
      return;
    }
    if (intento >= 8) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _irAFila(destino, columna, intento: intento + 1);
    });
  }

  /// Devuelve el foco al contenido cuando se ha quedado sin dueño.
  ///
  /// Pasa al cambiar de seccion o al llegar el catalogo indexado: las filas se
  /// rehacen y la tarjeta que tenia el foco desaparece. Sin esto la pantalla
  /// queda muerta —ninguna tecla responde— y solo se sale apagando. Es la red
  /// de seguridad, no el camino normal.
  KeyEventResult _rescatarFoco(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_filas.isEmpty) return KeyEventResult.ignored;
    _irAFila(_filaActual, _columnaActual);
    return KeyEventResult.handled;
  }

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
    _scrollVertical.dispose();
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
      if (_esRecienAgregadas(it.category)) continue;
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
      if (_esRecienAgregadas(it.category)) continue;
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

  /// Las mil formas en que el proveedor llama a "lo ultimo que subimos".
  static bool _esRecienAgregadas(String cat) {
    final c = cat.toLowerCase();
    return c.contains('recientemente') ||
        c.contains('recien agreg') ||
        c.contains('recién agreg') ||
        c.contains('agregadas recient') ||
        c.contains('agregados recient');
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
      // "Recientemente agregadas" del proveedor no se enseña: es lo mismo que
      // ya cuenta "Últimamente nuevo" ahi arriba, con otro nombre y en otro
      // orden. Dos filas que dicen lo mismo hacen dudar de cual es la buena.
      if (_esRecienAgregadas(cat)) continue;
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
                // Si una tecla llega hasta aqui es que ninguna tarjeta tenia el
                // foco: se rescata en vez de dejar la pantalla muerta.
                onKeyEvent: (node, event) => _rescatarFoco(event),
                // Al recibir el foco lo pasa a la primera tarjeta: este nodo
                // es solo la puerta de entrada desde el lateral.
                //
                // Y va a la primera de la PRIMERA fila, a mano. Con
                // `nextFocus()` lo elegia la traversal, que con las filas
                // desplazadas podia dejarlo en cualquier tarjeta del medio.
                onFocusChange: (v) {
                  if (!v) return;
                  if (_filas.isEmpty) {
                    _nodoContenido.nextFocus();
                    return;
                  }
                  // A DONDE ESTABAS, no al principio.
                  //
                  // Este nodo recibe el foco tanto al entrar desde el menu
                  // como al volver de una ficha, y mandar siempre a la fila 0
                  // era lo que tiraba el catalogo al principio cada vez que
                  // entrabas a un titulo y salias.
                  //
                  // Por `_irAFila` y no directo a la fila: si todavia no esta
                  // construida, el reintento espera a que exista en vez de
                  // perder la pulsacion.
                  _irAFila(_filaActual, _columnaActual);
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
                          controller: _scrollVertical,
                          // Con el mando no se arrastra: quien manda es el
                          // foco, y el desplazamiento lo decide `_irAFila`.
                          physics: const NeverScrollableScrollPhysics(),
                          // 40 arriba y no 92: los 92 eran el hueco que
                          // ocupaba la marca. Quitada la marca, ese hueco es
                          // una franja vacia en lo alto de la pantalla, y en
                          // un televisor eso es una fila de caratulas que se
                          // deja de ver.
                          padding: const EdgeInsets.fromLTRB(
                            0,
                            _huecoArriba,
                            0,
                            40,
                          ),
                          itemExtent: _altoFila,
                          // Una fila de margen construida arriba y abajo: al
                          // bajar, la siguiente ya existe y el foco entra sin
                          // esperar a que se arme.
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            320,
                          ),
                          itemCount: _filas.length,
                          itemBuilder: (context, i) {
                            final fila = _filas[i];
                            return _Fila(
                              key: _llaveDe(fila.titulo),
                              titulo: fila.titulo,
                              items: fila.items,
                              // Solo la primerísima tarjeta pide el foco: si lo
                              // pidieran las primeras de cada fila, el foco
                              // saltaría a la última en construirse y la
                              // pantalla arrancaría por el medio.
                              autofocoPrimero: i == 0,
                              onSalirIzquierda:
                                  () => _nodosLateral[_seccion].requestFocus(),
                              onArriba: (col) => _irAFila(i - 1, col),
                              onAbajo: (col) => _irAFila(i + 1, col),
                              // Cada vez que el foco cae en una tarjeta se
                              // apunta donde: es lo que se restaura al volver.
                              onFocoEn: (col) {
                                _filaActual = i;
                                _columnaActual = col;
                              },
                            );
                          },
                        ),
              ),
            ),
          ),

          // ── Velo superior ───────────────────────────────────────────
          //
          // Estaba puesto para que la marca se apoyara siempre en lo mismo.
          // Sin marca sigue haciendo falta, pero por otro motivo: las
          // caratulas de la primera fila se desplazan por debajo y sin la
          // banda asoman enteras por arriba, como si se salieran de la
          // pantalla.
          //
          // Mas corto que antes —80 en vez de 120—: ya no tiene que cubrir un
          // texto, solo difuminar el borde de arriba.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 80,
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
                onElegir: (i) async {
                  if (i == _iBuscar) {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const TvSearchScreen(),
                      ),
                    );
                    // Al volver, el foco se queda en BUSCAR: es de donde
                    // saliste, y dejarlo en otro sitio obliga a buscar con la
                    // vista donde estabas.
                    if (mounted) _nodosLateral[_iBuscar].requestFocus();
                    return;
                  }
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

/// Una fila del catálogo: el título de la categoría y sus carátulas.
///
/// LA NAVEGACIÓN NO SE DEJA AL AZAR
/// Antes el recorrido lo resolvía la traversal direccional de Flutter, que
/// elige el siguiente widget por geometría. Con dos listas anidadas y un
/// desplazamiento en marcha, la geometría cambia MIENTRAS se decide: pulsabas
/// derecha y el foco se iba a otra fila, o volvía por donde había venido. Aquí
/// cada tecla dice exactamente a qué nodo va, y el desplazamiento se calcula
/// por índice en vez de perseguir al widget enfocado.
class _Fila extends StatefulWidget {
  final String titulo;
  final List<M3UItem> items;
  final bool autofocoPrimero;
  final VoidCallback onSalirIzquierda;

  /// Sube o baja de fila conservando la columna. El índice es la posición en
  /// ESTA fila; la de destino lo recorta a lo que tenga.
  final void Function(int indice)? onArriba;
  final void Function(int indice)? onAbajo;

  /// Avisa de en qué columna quedó el foco dentro de esta fila.
  final void Function(int indice)? onFocoEn;

  const _Fila({
    super.key,
    required this.titulo,
    required this.items,
    required this.autofocoPrimero,
    required this.onSalirIzquierda,
    this.onArriba,
    this.onAbajo,
    this.onFocoEn,
  });

  @override
  State<_Fila> createState() => _FilaState();
}

class _FilaState extends State<_Fila> {
  /// Cuantas caben en la fila antes de mandar al catalogo completo.
  ///
  /// Treinta ya son treinta pulsaciones a la derecha; mas alla de eso nadie
  /// llega con un mando, y para eso esta la rejilla de "ver todo".
  static const int _maxEnFila = 30;

  /// Ancho de tarjeta mas separacion. Con esto el desplazamiento se calcula en
  /// vez de buscarse: la tarjeta `i` esta en `i * _paso`, siempre.
  static const double _paso = 150;

  final ScrollController _scroll = ScrollController();
  final List<FocusNode> _nodos = [];

  List<M3UItem> get _visibles =>
      widget.items.length > _maxEnFila
          ? widget.items.take(_maxEnFila).toList()
          : widget.items;

  bool get _hayMas => widget.items.length > _visibles.length;

  int get _celdas => _visibles.length + (_hayMas ? 1 : 0);

  @override
  void initState() {
    super.initState();
    _prepararNodos();
    if (widget.autofocoPrimero) {
      // Tras el primer fotograma: `autofocus` no basta porque el `Focus` raiz
      // del receptor pide el foco en su propio `initState`, que corre antes.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _nodos.isNotEmpty) _nodos.first.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(_Fila viejo) {
    super.didUpdateWidget(viejo);
    _prepararNodos();
  }

  void _prepararNodos() {
    while (_nodos.length < _celdas) {
      _nodos.add(FocusNode(debugLabel: 'fila_${_nodos.length}'));
    }
  }

  @override
  void dispose() {
    for (final n in _nodos) {
      n.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  /// Pone el foco en la celda `i` de esta fila y la trae a la vista.
  /// Pone el foco en la celda `i` de esta fila y la trae a la vista.
  ///
  /// PRIMERO SE DESPLAZA Y DESPUES SE PIDE EL FOCO, y si hace falta se espera
  /// un fotograma.
  ///
  /// La lista es perezosa: las tarjetas que no se ven NO estan construidas, y
  /// un `FocusNode` de una tarjeta sin construir no acepta el foco — la
  /// llamada no falla, sencillamente no pasa nada. Eso era el "se traba": al
  /// llegar al borde de lo construido, la flecha dejaba de responder y el foco
  /// se quedaba clavado en la ultima tarjeta viva.
  ///
  /// Desplazando primero, la tarjeta se construye; el `postFrame` espera a que
  /// exista y entonces le da el foco. Los intentos estan acotados para que un
  /// destino imposible no deje un bucle dando vueltas.
  void enfocar(int i, {int intento = 0}) {
    if (_celdas == 0) return;
    final destino = i.clamp(0, _celdas - 1);
    _traerALaVista(destino, inmediato: intento > 0);

    final nodo = _nodos[destino];
    if (nodo.context != null) {
      nodo.requestFocus();
      widget.onFocoEn?.call(destino);
      return;
    }
    if (intento >= 8) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) enfocar(destino, intento: intento + 1);
    });
  }

  /// Desplaza la fila por CUENTA, no persiguiendo al widget.
  ///
  /// `Scrollable.ensureVisible` sube por el arbol y mueve TODOS los
  /// desplazables que encuentra: al enfocar una tarjeta movia tambien la lista
  /// vertical, y ese era medio baile. Aqui solo se mueve esta fila, y a una
  /// posicion que se sabe antes de empezar.
  void _traerALaVista(int i, {bool inmediato = false}) {
    if (!_scroll.hasClients) return;
    final ancho = _scroll.position.viewportDimension;
    // Un hueco de cortesia a cada lado: deja ver que hay algo mas alla y evita
    // que la tarjeta enfocada quede pegada al filo.
    const margen = _paso;
    final izquierda = i * _paso;
    final derecha = izquierda + _paso;
    double destino = _scroll.offset;
    if (izquierda - margen < destino) {
      destino = izquierda - margen;
    } else if (derecha + margen > destino + ancho) {
      destino = derecha + margen - ancho;
    } else {
      return;
    }
    final objetivo = destino.clamp(0.0, _scroll.position.maxScrollExtent);
    // `inmediato` es para el reintento: si se vuelve a animar en cada
    // fotograma, la animacion se reinicia sola y la fila no llega nunca.
    if (inmediato) {
      _scroll.jumpTo(objetivo);
      return;
    }
    _scroll.animateTo(
      objetivo,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _tecla(int i, KeyEvent event) {
    // `KeyRepeatEvent` tambien cuenta: es lo que llega al MANTENER pulsada la
    // flecha. Sin atenderlo habia que dar treinta pulsaciones sueltas para
    // recorrer una fila, y mantener el mando no hacia nada.
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;

    if (k == LogicalKeyboardKey.arrowRight) {
      if (i + 1 < _celdas) enfocar(i + 1);
      // En la ultima no se hace nada, pero se da por atendida: sin esto el
      // foco saltaba a otra fila, que es el "me muevo a un lado y se va para
      // otro".
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (i > 0) {
        enfocar(i - 1);
      } else {
        widget.onSalirIzquierda();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      widget.onArriba?.call(i);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      widget.onAbajo?.call(i);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final visibles = _visibles;

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
              widget.titulo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18.7,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // ── El margen izquierdo va FUERA del `ListView` ────────────────
          //
          // No es lo mismo que ponerlo en su `padding`: el padding se desplaza
          // con el contenido, asi que las caratulas se seguian pintando por
          // debajo del menu y asomaban por su lateral al recorrer la fila.
          //
          // 100 y no 106: los 6 que faltan se los queda el `padding` del
          // propio ListView, para que la tarjeta enfocada crezca sin salirse.
          Padding(
            // 94 y no 106: los 12 que faltan se los queda el `padding` del
            // propio ListView, para que la tarjeta enfocada crezca sin salirse
            // por la izquierda. La suma sigue dando 106, que es donde empieza
            // el titulo de la seccion.
            padding: const EdgeInsets.only(left: 94),
            child: SizedBox(
              // Caratula (204) + hueco (8) + titulo (~15), y 12 mas de aire:
              // al crecer un 5%, la caratula gana 10 de alto y sin ese margen
              // se comia el titulo de la fila de arriba.
              height: 248,
              child: ListView.builder(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                // Con el mando no se arrastra: quien manda es el foco. Dejarla
                // desplazable a mano solo abria la puerta a que la fila
                // quedara en una posicion que el calculo del foco no espera.
                physics: const NeverScrollableScrollPhysics(),
                // Sin recorte: la tarjeta enfocada crece un 5% y ese pelo se
                // sale de su hueco.
                clipBehavior: Clip.none,
                // El aire por donde crece la tarjeta enfocada: 12 a cada lado,
                // que es lo que se ensancha una caratula de 136 al 9%.
                padding: const EdgeInsets.only(left: 12, right: 32),
                // Ancho fijo por celda: es lo que deja calcular la posicion de
                // cada tarjeta sin medir nada, y de paso le ahorra a la lista
                // el trabajo de ir midiendo hijo por hijo mientras se mueve.
                itemExtent: _paso,
                // Dos pantallas de margen construidas por delante y por
                // detras: al llegar al borde la siguiente tarjeta ya existe y
                // el foco entra sin esperar a que se arme.
                scrollCacheExtent: const ScrollCacheExtent.pixels(900),
                itemCount: _celdas,
                itemBuilder: (context, i) {
                  if (i == visibles.length) {
                    return _TarjetaMas(
                      nodo: _nodos[i],
                      restantes: widget.items.length - visibles.length,
                      onTecla: (e) => _tecla(i, e),
                      onOk: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder:
                                (_) => TvCategoryScreen(
                                  titulo: widget.titulo,
                                  items: widget.items,
                                ),
                          ),
                        );
                        if (mounted) enfocar(i);
                      },
                    );
                  }
                  return _Tarjeta(
                    item: visibles[i],
                    nodo: _nodos[i],
                    onTecla: (e) => _tecla(i, e),
                    onVolver: () => enfocar(i),
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
  final FocusNode nodo;
  final VoidCallback onOk;
  final KeyEventResult Function(KeyEvent) onTecla;

  const _TarjetaMas({
    required this.restantes,
    required this.nodo,
    required this.onOk,
    required this.onTecla,
  });

  @override
  State<_TarjetaMas> createState() => _TarjetaMasState();
}

class _TarjetaMasState extends State<_TarjetaMas> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.nodo,
      onFocusChange: (v) => setState(() => _foco = v),
      // OK SE LEE DIRECTO DE LA TECLA, sin Actions ni Intents: es lo unico que
      // responde con el mando de un televisor. Las flechas las resuelve la
      // fila, que es quien sabe cuantas tarjetas hay y donde esta cada una.
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onOk();
          return KeyEventResult.handled;
        }
        return widget.onTecla(event);
      },
      child: AnimatedScale(
        scale: _foco ? 1.09 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: GestureDetector(
          onTap: widget.onOk,
          child: SizedBox(
            width: 136,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 136,
                  height: 204,
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
                  width: 122,
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
      ),
    );
  }
}

/// Una carátula del catálogo.
class _Tarjeta extends StatefulWidget {
  final M3UItem item;
  final FocusNode nodo;
  final KeyEventResult Function(KeyEvent) onTecla;

  /// Se llama al volver de la ficha, para recuperar el foco.
  final VoidCallback onVolver;

  const _Tarjeta({
    required this.item,
    required this.nodo,
    required this.onTecla,
    required this.onVolver,
  });

  @override
  State<_Tarjeta> createState() => _TarjetaState();
}

class _TarjetaState extends State<_Tarjeta> {
  bool _foco = false;

  /// Abre la ficha y, AL VOLVER, se queda con el foco.
  ///
  /// Flutter no lo devuelve solo: mientras la ficha esta encima, esta fila se
  /// queda fuera de pantalla y la lista la desmonta, asi que el nodo con el
  /// foco deja de existir. Al cerrar la ficha, el foco no tenia adonde volver
  /// y aparecia en la primera tarjeta viva — que casi nunca era la que habias
  /// abierto.
  ///
  /// El aviso sube a la fila, que es quien sabe en que columna estaba y sabe
  /// esperar a que la tarjeta se vuelva a construir.
  Future<void> _abrir() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvDetailScreen(item: widget.item),
      ),
    );
    if (mounted) widget.onVolver();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.nodo,
      onFocusChange: (v) => setState(() => _foco = v),
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
      // Las flechas las resuelve la fila: es quien sabe cuantas tarjetas hay.
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          _abrir();
          return KeyEventResult.handled;
        }
        return widget.onTecla(event);
      },
      child: AnimatedScale(
        // ── El acercamiento al enfocar ────────────────────────────────────
        //
        // Un 5%, no mas: lo justo para que la vista encuentre sola donde esta
        // el foco desde el sofa. Es una transformacion de PINTADO, asi que no
        // recoloca nada de alrededor al crecer.
        scale: _foco ? 1.09 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: GestureDetector(
          onTap: _abrir,
          child: SizedBox(
            width: 136,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── La carátula ──────────────────────────────────────────
                //
                // Sin esquinas redondeadas y con el borde de foco fino: el
                // poster ya trae su propio diseño y enmarcarlo grueso le quita
                // presencia.
                //
                // La sirve `FastThumbnail`, no `Image.network`: guarda en
                // disco y decodifica al tamaño en que se ve, asi que volver
                // sobre una fila ya vista no vuelve a bajar nada.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 136,
                  height: 204,
                  foregroundDecoration: BoxDecoration(
                    border: Border.all(
                      color: _foco ? Colors.white : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  decoration: const BoxDecoration(color: Color(0xFF1A1A1E)),
                  child: FastThumbnail(
                    url: widget.item.logo,
                    width: 136,
                    height: 204,
                  ),
                ),

                const SizedBox(height: 8),

                // ── El título, SIEMPRE debajo ────────────────────────────
                //
                // Debajo y permanente se lee mejor —no compite con la imagen—
                // y de un vistazo se ve toda la fila sin ir tarjeta por
                // tarjeta. Mismo grosor con foco y sin el: la negrita
                // ensancharia el texto y movería las tarjetas al recorrerla.
                SizedBox(
                  width: 122,
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
