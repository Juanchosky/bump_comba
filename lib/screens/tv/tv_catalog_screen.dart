import 'package:flutter/material.dart';
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

  // Techos deliberados. Un proveedor puede traer cientos de categorías y miles
  // de títulos; pintarlos todos en un aparato de 1 GB de RAM es cómo se cuelga
  // un televisor. Nadie baja de la fila veinte con un mando, tampoco.
  static const int _maxFilas = 20;
  static const int _maxPorFila = 30;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      await _servicio.init();
      if (!mounted) return;

      final filas = <({String titulo, List<M3UItem> items})>[];

      // ── Seguir viendo, lo primero de todo ────────────────────────────
      //
      // Va antes que nada porque es lo que el usuario viene a hacer casi
      // siempre. Guardar el progreso y luego esconderlo tres filas mas abajo
      // seria hacer el trabajo y no cobrarlo.
      //
      // Se cruza el historial con el catalogo por URL: el historial guarda
      // donde te quedaste, pero no la caratula ni los episodios.
      try {
        final historial = await WatchProgressService().getHistory();
        if (historial.isNotEmpty) {
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
          if (siguiendo.isNotEmpty) {
            filas.add((titulo: 'Seguir viendo', items: siguiendo));
          }
        }
      } catch (_) {
        // El historial es un extra: si falla, el catalogo sale igual.
      }

      final novedades = _servicio.latestItems;
      if (novedades.isNotEmpty) {
        filas.add((
          titulo: 'Novedades',
          items: novedades.take(_maxPorFila).toList(),
        ));
      }

      // Agrupar por categoría conservando el orden en que vienen: ese orden ya
      // lo decide el catálogo, y reordenar aquí desharía ese trabajo.
      final porCategoria = <String, List<M3UItem>>{};
      for (final it in _servicio.items) {
        if (it.isLive) continue; // los canales en directo van aparte
        (porCategoria[it.category] ??= <M3UItem>[]).add(it);
      }

      for (final e in porCategoria.entries) {
        if (filas.length >= _maxFilas) break;
        if (e.value.length < 3) continue; // una fila de dos se ve rota
        filas.add((titulo: e.key, items: e.value.take(_maxPorFila).toList()));
      }

      setState(() {
        _filas = filas;
        _cargando = false;
        _error = filas.isEmpty ? 'No hay contenido disponible.' : null;
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
      child: ListView.builder(
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
          );
        },
      ),
    );
  }
}

class _Fila extends StatelessWidget {
  final String titulo;
  final List<M3UItem> items;
  final bool autofocoPrimero;

  const _Fila({
    required this.titulo,
    required this.items,
    required this.autofocoPrimero,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 34),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 48, bottom: 14),
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
            height: 208,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 48),
              itemCount: items.length,
              itemBuilder:
                  (context, i) => _Tarjeta(
                    item: items[i],
                    autofoco: autofocoPrimero && i == 0,
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
  const _Tarjeta({required this.item, required this.autofoco});

  @override
  State<_Tarjeta> createState() => _TarjetaState();
}

class _TarjetaState extends State<_Tarjeta> {
  bool _foco = false;

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
      autofocus: widget.autofoco,
      onFocusChange: (v) {
        setState(() => _foco = v);
        if (v) {
          // Traer la tarjeta a la vista. `alignment: 0.5` la deja centrada, que
          // es lo que hace que se intuya que hay más a los lados.
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      },
      onKeyEvent: (node, event) {
        if (event.logicalKey.keyLabel == 'Select' ||
            event.logicalKey.keyLabel == 'Enter') {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          return GestureDetector(
            onTap: _abrir,
            child: Actions(
              actions: <Type, Action<Intent>>{
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    _abrir();
                    return null;
                  },
                ),
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 132,
                margin: const EdgeInsets.only(right: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    // El foco se marca con un borde y no cambiando el tamaño:
                    // una tarjeta que crece empuja a sus vecinas y la fila
                    // entera se mueve al recorrerla.
                    color: _foco ? Colors.white : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
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
                      // El título solo se pinta cuando la tarjeta tiene el
                      // foco. Con todos los títulos encima, una fila de
                      // carátulas se convierte en una pared de texto.
                      if (_foco)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Colors.black87],
                              ),
                            ),
                            child: Text(
                              widget.item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
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
