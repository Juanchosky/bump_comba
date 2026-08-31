import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../services/fast_image_service.dart';
import '../../services/m3u_service.dart';
import 'tv_detail_screen.dart';

/// Buscador del televisor: teclado en pantalla a la izquierda, resultados a la
/// derecha, y los resultados cambian mientras se escribe.
///
/// POR QUÉ UN TECLADO PROPIO Y NO EL DEL SISTEMA
/// El teclado de Android TV se abre encima, tapa los resultados y obliga a
/// cerrarlo para ver qué salió. Con el teclado al lado, cada letra que pulsas
/// deja ver el resultado al instante: se escribe hasta que aparece lo que
/// buscas y se para, que es como se busca de verdad con un mando.
///
/// POR QUÉ EL ÍNDICE SE PREPARA UNA VEZ
/// El televisor se salta el indexado de búsqueda al arrancar (son ~7 segundos
/// que no se usan en el resto de la app). Aquí se hace una sola pasada al
/// abrir la pantalla, y a partir de ahí cada letra solo recorre una lista de
/// cadenas ya normalizadas. Buscar en 20.000 títulos a cada pulsación es lo
/// que haría que el teclado fuera a tirones.
class TvSearchScreen extends StatefulWidget {
  const TvSearchScreen({super.key});

  @override
  State<TvSearchScreen> createState() => _TvSearchScreenState();
}

class _TvSearchScreenState extends State<TvSearchScreen> {
  final _servicio = M3UService();

  /// El catálogo con su nombre ya normalizado. Se arma una vez.
  final List<({M3UItem item, String nombre})> _indice = [];

  String _texto = '';
  List<M3UItem> _resultados = const [];
  Timer? _debounce;

  /// Teclado en letras o en números.
  bool _numeros = false;

  static const int _columnasResultados = 5;

  /// Llaves para pasar el foco de un lado a otro: el teclado no puede llamar a
  /// los resultados por su cuenta —son hermanos, no padre e hijo— asi que el
  /// paso lo hace esta pantalla, que es quien los tiene a los dos.
  final GlobalKey<_ResultadosState> _foco = GlobalKey<_ResultadosState>();
  final GlobalKey<_TecladoState> _tecladoFoco = GlobalKey<_TecladoState>();
  static const int _maxResultados = 60;

  @override
  void initState() {
    super.initState();
    _prepararIndice();
    _buscar('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Una sola pasada por el catálogo, con las series ya agrupadas.
  ///
  /// Se usan `movies` y `series` y no `items`: `items` trae los episodios
  /// sueltos, asi que buscar "mr robot" devolvia treinta "Capitulo 4" en vez de
  /// la serie. Con `series` sale la ficha entera, que es la que tiene las
  /// temporadas dentro.
  void _prepararIndice() {
    final vistos = <String>{};
    for (final lista in [_servicio.movies, _servicio.series]) {
      for (final it in lista) {
        if (it.isLive) continue;
        final nombre = it.seriesName ?? it.name;
        if (!vistos.add('${nombre.toLowerCase()}|${it.url}')) continue;
        _indice.add((item: it, nombre: _normalizar(nombre)));
      }
    }
  }

  /// Minúsculas y sin tildes, que es como se teclea con un mando.
  static String _normalizar(String s) {
    var t = s.toLowerCase();
    const con = 'áàäâãéèëêíìïîóòöôõúùüûñç';
    const sin = 'aaaaaeeeeiiiiooooouuuunc';
    final b = StringBuffer();
    for (final c in t.split('')) {
      final i = con.indexOf(c);
      b.write(i >= 0 ? sin[i] : c);
    }
    t = b.toString();
    // Los signos no se pueden teclear con este teclado, asi que estorban.
    return t
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Busca con un respiro de 220 ms.
  ///
  /// Sin el, mantener pulsada una letra lanzaba una busqueda por pulsacion y
  /// el teclado se quedaba atras. Con el respiro solo se busca cuando dejas de
  /// escribir, que es cuando el resultado importa.
  void _programarBusqueda(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () => _buscar(q));
  }

  void _buscar(String q) {
    final consulta = _normalizar(q);
    if (consulta.isEmpty) {
      setState(() => _resultados = const []);
      return;
    }

    // Dos montones: los que EMPIEZAN por lo tecleado y los que solo lo
    // contienen. Escribiendo "mr robot", "Mr. Robot" tiene que salir antes que
    // "Los hermanos robot", y ordenar despues por relevancia costaria recorrer
    // otra vez toda la lista.
    final empiezan = <M3UItem>[];
    final contienen = <M3UItem>[];
    for (final e in _indice) {
      if (e.nombre.startsWith(consulta)) {
        empiezan.add(e.item);
      } else if (e.nombre.contains(consulta)) {
        contienen.add(e.item);
      }
      if (empiezan.length >= _maxResultados) break;
    }

    setState(() {
      _resultados = [...empiezan, ...contienen].take(_maxResultados).toList();
    });
  }

  void _escribir(String c) {
    setState(() => _texto += c);
    _programarBusqueda(_texto);
  }

  void _borrarUno() {
    if (_texto.isEmpty) return;
    setState(() => _texto = _texto.substring(0, _texto.length - 1));
    _programarBusqueda(_texto);
  }

  void _borrarTodo() {
    if (_texto.isEmpty) return;
    setState(() => _texto = '');
    _programarBusqueda('');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0D),
      body: Stack(
        fit: StackFit.expand,
        children: [
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
          const DecoratedBox(
            decoration: BoxDecoration(color: Color(0xD9000000)),
            child: SizedBox.expand(),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(40, 28, 40, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 300,
                  child: _Teclado(
                    key: _tecladoFoco,
                    texto: _texto,
                    numeros: _numeros,
                    onLetra: _escribir,
                    onBorrarUno: _borrarUno,
                    onBorrarTodo: _borrarTodo,
                    onCambiarModo: () => setState(() => _numeros = !_numeros),
                    onSalirDerecha: () => _foco.currentState?.enfocar(0),
                  ),
                ),
                const SizedBox(width: 36),
                Expanded(
                  child: _Resultados(
                    key: _foco,
                    items: _resultados,
                    columnas: _columnasResultados,
                    vacio: _texto.isEmpty,
                    onSalirIzquierda: () => _tecladoFoco.currentState?.volver(),
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

// ─────────────────────────────────────────────────────────────────────────────
// TECLADO
// ─────────────────────────────────────────────────────────────────────────────

/// El teclado en pantalla: la caja con lo escrito y las teclas.
class _Teclado extends StatefulWidget {
  final String texto;
  final bool numeros;
  final ValueChanged<String> onLetra;
  final VoidCallback onBorrarUno;
  final VoidCallback onBorrarTodo;
  final VoidCallback onCambiarModo;
  final VoidCallback onSalirDerecha;

  const _Teclado({
    super.key,
    required this.texto,
    required this.numeros,
    required this.onLetra,
    required this.onBorrarUno,
    required this.onBorrarTodo,
    required this.onCambiarModo,
    required this.onSalirDerecha,
  });

  @override
  State<_Teclado> createState() => _TecladoState();
}

class _TecladoState extends State<_Teclado> {
  /// Siete columnas, como la referencia: entran las 26 letras en cuatro filas
  /// sin que las teclas queden diminutas.
  static const int _columnas = 7;

  static const List<String> _letras = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', //
    'H', 'I', 'J', 'K', 'L', 'M', 'N', //
    'O', 'P', 'Q', 'R', 'S', 'T', 'U', //
    'V', 'W', 'X', 'Y', 'Z', //
  ];

  static const List<String> _digitos = [
    '1', '2', '3', '4', '5', '6', '7', //
    '8', '9', '0', //
  ];

  /// Las cuatro teclas de arriba: modo, borrar todo, borrar uno y espacio.
  static const int _especiales = 4;

  final List<FocusNode> _nodos = [];
  int _ultimo = 0;

  List<String> get _teclas => widget.numeros ? _digitos : _letras;

  int get _total => _especiales + _teclas.length;

  @override
  void initState() {
    super.initState();
    _prepararNodos();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _nodos.isNotEmpty) _nodos[_especiales].requestFocus();
    });
  }

  @override
  void didUpdateWidget(_Teclado viejo) {
    super.didUpdateWidget(viejo);
    _prepararNodos();
  }

  void _prepararNodos() {
    while (_nodos.length < _total) {
      _nodos.add(FocusNode(debugLabel: 'tecla${_nodos.length}'));
    }
  }

  @override
  void dispose() {
    for (final n in _nodos) {
      n.dispose();
    }
    super.dispose();
  }

  /// Devuelve el foco al teclado, a la última tecla que se usó.
  void volver() => _enfocar(_ultimo);

  void _enfocar(int i) {
    if (_total == 0) return;
    final destino = i.clamp(0, _total - 1);
    _ultimo = destino;
    _nodos[destino].requestFocus();
  }

  /// Fila de una tecla. Las cuatro especiales son la fila 0; las letras
  /// empiezan en la 1.
  int _fila(int i) =>
      i < _especiales ? 0 : 1 + ((i - _especiales) ~/ _columnas);

  int _columna(int i) => i < _especiales ? i : (i - _especiales) % _columnas;

  /// Primer índice de una fila, o -1 si esa fila no existe.
  int _inicioDeFila(int f) {
    if (f < 0) return -1;
    if (f == 0) return 0;
    final i = _especiales + (f - 1) * _columnas;
    return i < _total ? i : -1;
  }

  void _mover(int desde, int df, int dc) {
    if (df != 0) {
      final destinoFila = _fila(desde) + df;
      final inicio = _inicioDeFila(destinoFila);
      if (inicio < 0) return;
      final anchoFila =
          destinoFila == 0
              ? _especiales
              : (_total - inicio).clamp(0, _columnas);
      final col = _columna(desde).clamp(0, anchoFila - 1);
      _enfocar(inicio + col);
      return;
    }

    final destino = desde + dc;
    // Solo dentro de su fila: saltar de la Z a la A de la fila de arriba
    // desorienta, porque el foco cruza la pantalla entera.
    if (destino < 0) return;
    if (destino >= _total) return;
    if (_fila(destino) != _fila(desde)) {
      // Salir por la derecha lleva a los resultados, que es lo natural: el
      // teclado esta a la izquierda de lo que se busca.
      if (dc > 0) widget.onSalirDerecha();
      return;
    }
    _enfocar(destino);
  }

  KeyEventResult _tecla(int i, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight) {
      // Desde la ultima columna se sale a los resultados.
      if (_columna(i) == _anchoDeFila(_fila(i)) - 1) {
        widget.onSalirDerecha();
      } else {
        _mover(i, 0, 1);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      // EN LA PRIMERA COLUMNA, IZQUIERDA NO HACE NADA.
      //
      // Antes cerraba el buscador entero. Y la primera columna no es un sitio
      // raro al que se llega por accidente: son la A, la H, la O, la V y la
      // tecla de numeros — se pasa por ahi constantemente al escribir. Bastaba
      // una pulsacion de mas hacia la izquierda para que la pantalla se
      // cerrara sola en mitad de una busqueda.
      //
      // Se da por atendida igualmente: si se deja pasar, la traversal de
      // Flutter busca "algo a la izquierda" y acaba sacando el foco del
      // teclado, que es otra forma de lo mismo.
      //
      // Para salir esta el boton de atras del mando, que es donde todo el
      // mundo lo busca.
      if (_columna(i) > 0) _mover(i, 0, -1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _mover(i, -1, 0);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _mover(i, 1, 0);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int _anchoDeFila(int f) {
    if (f == 0) return _especiales;
    final inicio = _inicioDeFila(f);
    if (inicio < 0) return 0;
    return (_total - inicio).clamp(0, _columnas);
  }

  void _pulsar(int i) {
    _ultimo = i;
    switch (i) {
      case 0:
        widget.onCambiarModo();
      case 1:
        widget.onBorrarTodo();
      case 2:
        widget.onBorrarUno();
      case 3:
        widget.onLetra(' ');
      default:
        widget.onLetra(_teclas[i - _especiales]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Lo escrito ──────────────────────────────────────────────────
        //
        // Con un cursor pintado a mano: no es un campo de texto de verdad
        // —nadie va a escribir aqui con un teclado fisico— pero sin el cursor
        // la caja parece apagada y no se sabe que es donde va lo que tecleas.
        Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1E),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.texto.isEmpty ? 'Buscar…' : widget.texto,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.texto.isEmpty ? Colors.white38 : Colors.white,
                    fontSize: 17,
                  ),
                ),
              ),
              if (widget.texto.isNotEmpty)
                Container(width: 2, height: 22, color: Colors.white70),
            ],
          ),
        ),

        const SizedBox(height: 18),

        // ── Las teclas ──────────────────────────────────────────────────
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                Row(
                  children: [
                    for (int i = 0; i < _especiales; i++)
                      Expanded(
                        child: _Tecla(
                          nodo: _nodos[i],
                          onTecla: (e) => _tecla(i, e),
                          onOk: () => _pulsar(i),
                          etiqueta: switch (i) {
                            0 => widget.numeros ? 'ABC' : '123',
                            3 => '',
                            _ => null,
                          },
                          icono: switch (i) {
                            1 => Icons.delete_outline_rounded,
                            2 => Icons.backspace_outlined,
                            3 => Icons.space_bar_rounded,
                            _ => null,
                          },
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                for (int f = 0; f * _columnas < _teclas.length; f++)
                  Row(
                    children: [
                      for (int c = 0; c < _columnas; c++)
                        Expanded(
                          child:
                              (f * _columnas + c) < _teclas.length
                                  ? _Tecla(
                                    nodo:
                                        _nodos[_especiales + f * _columnas + c],
                                    etiqueta: _teclas[f * _columnas + c],
                                    onTecla:
                                        (e) => _tecla(
                                          _especiales + f * _columnas + c,
                                          e,
                                        ),
                                    onOk:
                                        () => _pulsar(
                                          _especiales + f * _columnas + c,
                                        ),
                                  )
                                  : const SizedBox(height: 44),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Una tecla. Blanca con el foco, apagada sin él.
class _Tecla extends StatefulWidget {
  final FocusNode nodo;
  final String? etiqueta;
  final IconData? icono;
  final VoidCallback onOk;
  final KeyEventResult Function(KeyEvent) onTecla;

  const _Tecla({
    required this.nodo,
    required this.onOk,
    required this.onTecla,
    this.etiqueta,
    this.icono,
  });

  @override
  State<_Tecla> createState() => _TeclaState();
}

class _TeclaState extends State<_Tecla> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.nodo,
      onFocusChange: (v) => setState(() => _foco = v),
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
      child: GestureDetector(
        onTap: widget.onOk,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 44,
          margin: const EdgeInsets.all(3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _foco ? Colors.white : Colors.white10,
            borderRadius: BorderRadius.circular(4),
          ),
          child:
              widget.icono != null
                  ? Icon(
                    widget.icono,
                    size: 20,
                    color: _foco ? Colors.black : Colors.white70,
                  )
                  : Text(
                    widget.etiqueta ?? '',
                    style: TextStyle(
                      color: _foco ? Colors.black : Colors.white70,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULTADOS
// ─────────────────────────────────────────────────────────────────────────────

class _Resultados extends StatefulWidget {
  final List<M3UItem> items;
  final int columnas;
  final bool vacio;
  final VoidCallback onSalirIzquierda;

  const _Resultados({
    super.key,
    required this.items,
    required this.columnas,
    required this.vacio,
    required this.onSalirIzquierda,
  });

  @override
  State<_Resultados> createState() => _ResultadosState();
}

class _ResultadosState extends State<_Resultados> {
  /// Alto de una celda: carátula (180) + hueco (6) + título + separación.
  static const double _altoCelda = 222;

  final ScrollController _scroll = ScrollController();
  final List<FocusNode> _nodos = [];

  @override
  void didUpdateWidget(_Resultados viejo) {
    super.didUpdateWidget(viejo);
    _prepararNodos();
    // Cada busqueda nueva empieza por arriba: si la lista se acorta, quedarse
    // desplazado en una posicion que ya no existe deja la pantalla en blanco.
    if (viejo.items != widget.items && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  void _prepararNodos() {
    while (_nodos.length < widget.items.length) {
      _nodos.add(FocusNode(debugLabel: 'resultado${_nodos.length}'));
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

  /// Pone el foco en el resultado `i`, esperando a que exista si hace falta.
  ///
  /// La rejilla es perezosa: lo que no se ve no esta construido, y un nodo sin
  /// construir no acepta el foco. Se desplaza primero y se pide el foco
  /// despues, con reintentos acotados.
  void enfocar(int i, {int intento = 0}) {
    _prepararNodos();
    if (widget.items.isEmpty) return;
    final destino = i.clamp(0, widget.items.length - 1);
    _traerALaVista(destino, inmediato: intento > 0);

    if (_nodos[destino].context != null) {
      _nodos[destino].requestFocus();
      return;
    }
    if (intento >= 8) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) enfocar(destino, intento: intento + 1);
    });
  }

  void _traerALaVista(int i, {bool inmediato = false}) {
    if (!_scroll.hasClients) return;
    final fila = i ~/ widget.columnas;
    final alto = _scroll.position.viewportDimension;
    final arriba = fila * _altoCelda;
    final abajo = arriba + _altoCelda;
    double destino = _scroll.offset;
    if (arriba < destino) {
      destino = arriba;
    } else if (abajo > destino + alto) {
      destino = abajo - alto;
    } else {
      return;
    }
    final objetivo = destino.clamp(0.0, _scroll.position.maxScrollExtent);
    if (inmediato) {
      _scroll.jumpTo(objetivo);
      return;
    }
    _scroll.animateTo(
      objetivo,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _tecla(int i, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    final col = i % widget.columnas;

    if (k == LogicalKeyboardKey.arrowLeft) {
      if (col == 0) {
        widget.onSalirIzquierda();
      } else {
        enfocar(i - 1);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (col < widget.columnas - 1 && i + 1 < widget.items.length) {
        enfocar(i + 1);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (i - widget.columnas >= 0) enfocar(i - widget.columnas);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (i + widget.columnas < widget.items.length) {
        enfocar(i + widget.columnas);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return Center(
        child: Text(
          widget.vacio ? 'Escribe para buscar' : 'Nada con ese nombre',
          style: const TextStyle(color: Colors.white38, fontSize: 17),
        ),
      );
    }

    _prepararNodos();

    return GridView.builder(
      controller: _scroll,
      // Manda el foco, no el arrastre: asi la rejilla nunca queda en una
      // posicion que el calculo del foco no espera.
      physics: const NeverScrollableScrollPhysics(),
      // Sin recorte y con aire por los cuatro lados: la tarjeta enfocada
      // crece un 9% y ese pelo se sale de su celda.
      clipBehavior: Clip.none,
      padding: const EdgeInsets.fromLTRB(11, 14, 11, 20),
      scrollCacheExtent: const ScrollCacheExtent.pixels(320),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.columnas,
        mainAxisExtent: _altoCelda - 14,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: widget.items.length,
      itemBuilder:
          (context, i) => _Resultado(
            item: widget.items[i],
            nodo: _nodos[i],
            onTecla: (e) => _tecla(i, e),
            onVolver: () => enfocar(i),
          ),
    );
  }
}

class _Resultado extends StatefulWidget {
  final M3UItem item;
  final FocusNode nodo;
  final KeyEventResult Function(KeyEvent) onTecla;
  final VoidCallback onVolver;

  const _Resultado({
    required this.item,
    required this.nodo,
    required this.onTecla,
    required this.onVolver,
  });

  @override
  State<_Resultado> createState() => _ResultadoState();
}

class _ResultadoState extends State<_Resultado> {
  bool _foco = false;

  Future<void> _abrir() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvDetailScreen(item: widget.item),
      ),
    );
    // Al volver, el foco vuelve a ESTA tarjeta: mientras la ficha estaba
    // encima, la rejilla se desmonto y el nodo con el foco dejo de existir.
    if (mounted) widget.onVolver();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.nodo,
      onFocusChange: (v) => setState(() => _foco = v),
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
        scale: _foco ? 1.09 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: GestureDetector(
          onTap: _abrir,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: double.infinity,
                  foregroundDecoration: BoxDecoration(
                    border: Border.all(
                      color: _foco ? Colors.white : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  decoration: const BoxDecoration(color: Color(0xFF1A1A1E)),
                  child: LayoutBuilder(
                    builder:
                        (context, c) => FastThumbnail(
                          url: widget.item.logo,
                          width: c.maxWidth,
                          height: c.maxHeight,
                        ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 130),
                style: TextStyle(
                  color: _foco ? Colors.white : Colors.white54,
                  fontSize: 12,
                ),
                child: Text(
                  widget.item.seriesName ?? widget.item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
