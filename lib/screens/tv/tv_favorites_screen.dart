import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/fast_image_service.dart';
import '../../services/m3u_service.dart';
import '../../utils/colors.dart';
import 'tv_detail_screen.dart';

/// Pantalla "Mi lista" para el televisor.
///
/// Muestra todas las películas y series que el usuario ha guardado como
/// favoritas, en una rejilla adaptada para control remoto de TV.
class TvFavoritesScreen extends StatefulWidget {
  const TvFavoritesScreen({super.key});

  @override
  State<TvFavoritesScreen> createState() => _TvFavoritesScreenState();
}

class _TvFavoritesScreenState extends State<TvFavoritesScreen> {
  final _servicio = M3UService();
  List<M3UItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _cargarFavoritos();
  }

  void _cargarFavoritos() {
    final favs = _servicio.getFavorites();
    setState(() {
      _items = List<M3UItem>.from(favs);
    });
  }

  Future<void> _abrir(M3UItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvDetailScreen(item: item),
      ),
    );
    // Al volver, refrescamos por si el usuario quitó el contenido de su lista:
    if (mounted) {
      _cargarFavoritos();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool vacio = _items.isEmpty;

    return Focus(
      autofocus: vacio,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.escape ||
            k == LogicalKeyboardKey.goBack ||
            k == LogicalKeyboardKey.gameButtonB) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: AppColors.fondoTv,
        body: Stack(
          fit: StackFit.expand,
          children: [
          // Fondo temático compartido con la ficha y las categorías de TV:
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
            padding: const EdgeInsets.fromLTRB(48, 28, 48, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Cabecera: Título y contador ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text(
                      'Mi lista',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      vacio
                          ? '0 títulos'
                          : '${_items.length} ${_items.length == 1 ? "título" : "títulos"}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    const _AvisoAtras(),
                  ],
                ),
                const SizedBox(height: 14),

                // ── Contenido: Rejilla o Estado Vacío ──
                Expanded(
                  child: vacio
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 84,
                                height: 84,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withValues(alpha: 0.06),
                                ),
                                child: const Icon(
                                  Icons.bookmark_border_rounded,
                                  size: 44,
                                  color: Colors.white38,
                                ),
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                'Tu lista está vacía',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 40),
                                child: Text(
                                  'Agrega películas y series usando el botón "Agregar a mi lista"\nen los detalles de cualquier título para verlos aquí.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 15,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : GridView.builder(
                          clipBehavior: Clip.none,
                          padding: const EdgeInsets.fromLTRB(11, 14, 11, 30),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 132,
                            mainAxisExtent: 208,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 24,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (context, i) => _TarjetaFavorito(
                            item: _items[i],
                            autofoco: i == 0,
                            onOk: () => _abrir(_items[i]),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  }
}

/// Tarjeta para la rejilla de favoritos.
class _TarjetaFavorito extends StatefulWidget {
  final M3UItem item;
  final bool autofoco;
  final VoidCallback onOk;

  const _TarjetaFavorito({
    required this.item,
    required this.autofoco,
    required this.onOk,
  });

  @override
  State<_TarjetaFavorito> createState() => _TarjetaFavoritoState();
}

class _TarjetaFavoritoState extends State<_TarjetaFavorito> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofoco,
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
        scale: _foco ? 1.09 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: GestureDetector(
          onTap: widget.onOk,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
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
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LayoutBuilder(
                        builder: (context, c) => FastThumbnail(
                          url: widget.item.logo,
                          width: c.maxWidth,
                          height: c.maxHeight,
                          title: widget.item.name,
                        ),
                      ),
                      if (widget.item.esDeLaBD)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5A623),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text(
                              'BD',
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 5),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 130),
                style: TextStyle(
                  color: _foco ? Colors.white : Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
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

/// Recordatorio visual de que se puede pulsar Atrás en el mando.
class _AvisoAtras extends StatelessWidget {
  const _AvisoAtras();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'ATRÁS',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          'para salir',
          style: TextStyle(
            color: Colors.white38,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}
