import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/fast_image_service.dart';
import '../../services/m3u_service.dart';
import 'tv_detail_screen.dart';

/// El catálogo COMPLETO de una categoría, en rejilla.
///
/// POR QUÉ EXISTE
/// En el catálogo cada categoría es una fila, y una fila enseña treinta
/// títulos. Los que vienen detrás no había forma de verlos: no es que
/// estuvieran escondidos, es que no había sitio donde ir a buscarlos. Aquí
/// entra todo lo que trae esa categoría.
///
/// POR QUÉ REJILLA Y NO FILA
/// Con seiscientos títulos, una fila son seiscientas pulsaciones a la derecha.
/// La rejilla los reparte en filas de seis: bajar recorre de seis en seis y se
/// llega al final en un número de pulsaciones que un mando aguanta.
class TvCategoryScreen extends StatefulWidget {
  final String titulo;
  final List<M3UItem> items;

  const TvCategoryScreen({
    super.key,
    required this.titulo,
    required this.items,
  });

  @override
  State<TvCategoryScreen> createState() => _TvCategoryScreenState();
}

class _TvCategoryScreenState extends State<TvCategoryScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0D),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // El mismo fondo que la ficha, para que las tres pantallas del
          // televisor se lean como la misma app y no como tres apps pegadas.
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        widget.titulo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color.fromRGBO(255, 255, 255, 1),
                          fontSize: 19.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Cuantos hay. Es el dato que dice si merece la pena
                    // seguir bajando o si ya se ha visto casi todo.
                    Text(
                      '${widget.items.length} títulos',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                Expanded(
                  child: GridView.builder(
                    // Sin recorte: la tarjeta enfocada crece un 5% y ese pelo
                    // se sale de su celda.
                    clipBehavior: Clip.none,
                    // Y con aire por los cuatro lados, que es lo que le faltaba
                    // al quitar el recorte: las de la primera fila se salian
                    // por arriba y las de los extremos por los lados. 6 de
                    // ancho y 10 de alto es lo que se ensancha una caratula de
                    // 120x180 al 5%.
                    padding: const EdgeInsets.fromLTRB(11, 14, 11, 30),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          // Algo mas pequeñas que las del catalogo: aqui hay
                          // pantalla entera y varias filas a la vez, asi que
                          // caben mas titulos de un vistazo — que es para lo
                          // que uno entra a "ver todo".
                          //
                          // Por ancho maximo y no por numero de columnas: con
                          // un numero fijo, la tarjeta valia lo que sobrara de
                          // dividir la pantalla y salia de un tamaño distinto
                          // en cada televisor. Diciendo cuanto mide la
                          // tarjeta, es la rejilla la que decide cuantas caben.
                          maxCrossAxisExtent: 132,
                          // Caratula (180) + hueco (6) + titulo, con holgura.
                          mainAxisExtent: 208,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 14,
                        ),
                    itemCount: widget.items.length,
                    itemBuilder:
                        (context, i) =>
                            _Tarjeta(item: widget.items[i], autofoco: i == 0),
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

/// Una tarjeta de la rejilla. Misma pinta que la del catálogo.
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
          // Media pantalla de margen: al bajar a la ultima fila visible, la
          // rejilla se adelanta y siempre queda algo por debajo. Sin esto se
          // navega pegado al borde inferior sin ver adonde vas.
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 180),
          );
        }
      },
      // OK SE LEE DIRECTO DE LA TECLA, sin Actions ni Intents: es lo unico que
      // funciona con el mando de un televisor. Esta explicado a fondo en la
      // tarjeta del catalogo, que fue donde se pago el aprendizaje.
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.gameButtonA) {
          _abrir();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedScale(
        // ── El acercamiento al enfocar ────────────────────────────────────────
        //
        // Un 5%, no mas. Lo que se busca es que la vista encuentre sola donde esta
        // el foco al mirar la pantalla desde el sofa; un salto mayor empuja a las
        // vecinas y convierte recorrer una fila en un oleaje.
        //
        // Es una transformacion de PINTADO: no toca la distribucion, asi que al
        // crecer no se recoloca nada de alrededor.
        scale: _foco ? 1.09 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: GestureDetector(
          onTap: _abrir,
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
                  // El mismo widget que el catalogo y que el telefono: guarda
                  // en disco y decodifica al tamaño en que se ve, asi que
                  // volver a esta rejilla no vuelve a bajar nada.
                  //
                  // Con `LayoutBuilder` porque aqui el ancho lo reparte la
                  // rejilla y cambia con la pantalla: pasarle una medida fija
                  // la haria decodificar a un tamaño que no es el que se ve.
                  child: LayoutBuilder(
                    builder:
                        (context, c) => FastThumbnail(
                          url: widget.item.logo,
                          width: c.maxWidth,
                          height: c.maxHeight,
                          title: widget.item.name,
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
                  fontWeight: FontWeight.w400,
                ),
                child: Text(
                  widget.item.name,
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
