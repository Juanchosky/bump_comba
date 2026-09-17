import 'package:flutter/material.dart';

import '../../models/m3u_item.dart';
import '../../screens/tv/tv_player_screen.dart';

/// La vista previa de la ficha, y el reproductor grande: son el mismo.
///
/// ── POR QUÉ EXISTE ESTA CLASE ──────────────────────────────────────────────
///
/// Lo que se pide es que al pulsar sobre la vista previa de la ficha, ésta se
/// abra a pantalla completa SIN RECARGAR, y que al volver siga sonando donde
/// iba.
///
/// En Flutter eso no se puede hacer con dos pantallas. Un widget no conserva
/// su estado al cambiar de ruta: si el reproductor viviera dentro de la ficha,
/// navegar lo destruiría, y volver a abrirlo significa resolver la URL otra
/// vez, negociar con el proveedor otra vez y llenar el búfer otra vez. Eso es
/// exactamente la recarga que no se quiere.
///
/// La salida es no meterlo en ninguna ruta: vive en el `Overlay` de la app,
/// por encima del `Navigator`. Ahí las rutas van y vienen por debajo mientras
/// él sigue quieto y reproduciendo. Lo único que cambia es el rectángulo que
/// ocupa — el hueco de la ficha, o la pantalla entera.
///
/// ── LO QUE HAY QUE DEVOLVERLE A CAMBIO ─────────────────────────────────────
///
/// Estar fuera del `Navigator` le quita dos cosas que una pantalla normal
/// tiene gratis, y las pone esta clase:
///
///  · EL "ATRÁS". No hay `ModalRoute`, así que su `PopScope` no se enteraría.
///    Al agrandarse se empuja una ruta transparente que no pinta nada y solo
///    está para recoger el "atrás" y las teclas del mando.
///  · EL FOCO. Estando pequeño el foco es de la ficha, que es quien navega.
///    Estando grande lo tiene esa ruta transparente, que le pasa las teclas.
class TvVistaPrevia {
  TvVistaPrevia._();
  static final TvVistaPrevia instancia = TvVistaPrevia._();

  OverlayEntry? _entrada;

  /// Dónde se pinta ahora mismo. `null` mientras no se sabe el hueco.
  final ValueNotifier<Rect?> _hueco = ValueNotifier<Rect?>(null);

  /// A pantalla completa o en el hueco de la ficha.
  final ValueNotifier<bool> _expandido = ValueNotifier<bool>(false);

  /// ¿Tiene el foco el recuadro de la ficha?
  ///
  /// Lo dice la ficha, y hace falta porque el vídeo tapa su recuadro: el marco
  /// blanco del foco quedaba DEBAJO del `Overlay` y no se veía. Sin esa señal
  /// no se sabe dónde está el mando, que en un televisor es lo único que
  /// orienta. Así que se vuelve a pintar aquí arriba.
  final ValueNotifier<bool> _conFoco = ValueNotifier<bool>(false);

  set foco(bool v) => _conFoco.value = v;

  /// Para hablarle al reproductor ya montado: pasarle teclas, o el "atrás".
  final GlobalKey<TvPlayerScreenState> _clave =
      GlobalKey<TvPlayerScreenState>();

  /// Qué se está reproduciendo, para no volver a montarlo si ya es ese.
  String? _urlActual;

  /// Quién montó lo que hay ahora.
  ///
  /// ── POR QUE UN NUMERO Y NO LA URL ─────────────────────────────────────
  ///
  /// La pertenencia se comprobaba comparando URLs, y eso fallaba: la ficha
  /// monta la vista previa con el episodio que toca, y esa eleccion puede
  /// CAMBIAR mientras esta abierta —al llegar la lista de episodios, por
  /// ejemplo—. Cuando eso pasaba, la URL guardada por la ficha ya no era la
  /// del proxy, `cerrarSi` decidia que aquello era de otro y no cerraba nada.
  ///
  /// Resultado: salias al catalogo y el recuadro de video se quedaba flotando
  /// encima.
  ///
  /// Un numero de turno no depende de lo que se este viendo: quien lo monto lo
  /// cierra, pase lo que pase con el contenido.
  int _turno = 0;

  /// EL REPRODUCTOR, GUARDADO APARTE.
  ///
  /// Se construye una sola vez por titulo y se guarda aqui. Estaba creado
  /// dentro del `builder` de la entrada, y eso es fragil: basta con que Flutter
  /// decida rehacer ese subarbol para que el `State` muera, y al morir se lleva
  /// por delante el `Player` de media_kit. Eso es el
  /// `[Player] has been disposed` del log — la resolucion seguia en marcha
  /// contra un reproductor que ya no existia, y el fallo se leia como si el
  /// servidor no respondiera.
  ///
  /// Teniendo la MISMA instancia de widget en un campo, cualquier
  /// reconstruccion la reutiliza en vez de crear otra.
  Widget? _reproductor;

  bool get activa => _entrada != null;

  /// Lo mismo que `activa`, pero avisando: la ficha lo necesita para tapar su
  /// imagen fija en cuanto el vídeo se pone encima.
  final ValueNotifier<bool> montada = ValueNotifier<bool>(false);
  bool get expandido => _expandido.value;

  /// Monta la vista previa en el hueco indicado, o solo mueve el hueco si ya
  /// estaba puesta con este mismo título.
  ///
  /// Volver a llamar con el mismo contenido NO reinicia nada: es lo que
  /// permite que la ficha reajuste el rectángulo al hacer scroll sin cortar la
  /// reproducción.
  /// Devuelve el turno con el que quedo montada, para que quien la monto
  /// pueda cerrarla despues sin depender de lo que se este viendo.
  int mostrar(BuildContext context, M3UItem item, Rect hueco) {
    if (_entrada != null && _urlActual == item.url) {
      // Ya montada con este mismo titulo: solo se reubica. No se toca nada
      // mas, que es lo que permite seguir el scroll sin cortar el video.
      _hueco.value = hueco;
      return _turno;
    }

    // EL ORDEN IMPORTA: `cerrar()` deja el hueco en `null`, y con el hueco
    // nulo esto se pinta a pantalla completa. Poniendolo antes, se borraba
    // justo despues y la vista previa tapaba la ficha entera nada mas entrar.
    cerrar();
    _hueco.value = hueco;
    _urlActual = item.url;
    _turno++;
    _reproductor = TvPlayerScreen(
      key: _clave,
      item: item,
      titulo: item.name,
      expandido: _expandido,
    );
    // Se ponen aqui y no se confia en el `cerrar()` de antes: aquel limpia
    // despues del fotograma, y para entonces esto ya esta en pantalla.
    _expandido.value = false;
    _conFoco.value = false;

    _entrada = OverlayEntry(
      builder: (_) {
        return ValueListenableBuilder<bool>(
          valueListenable: _expandido,
          builder: (context, grande, hijo) {
            return ValueListenableBuilder<Rect?>(
              valueListenable: _hueco,
              builder: (context, r, _) {
                final pantalla = MediaQuery.sizeOf(context);
                final destino =
                    grande || r == null
                        ? Rect.fromLTWH(0, 0, pantalla.width, pantalla.height)
                        : r;

                // `AnimatedPositioned` y no un cambio seco: el salto del hueco
                // a la pantalla entera es de lo poco que el usuario ve de todo
                // este montaje, y hecho de golpe parece que ha cambiado de
                // pantalla — que es justo la impresión que se quiere evitar.
                return AnimatedPositioned.fromRect(
                  rect: destino,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _conFoco,
                    builder: (context, foco, video) {
                      // Solo el MARCO, y solo en pequeño.
                      //
                      // El play que había en medio sobraba: es la señal de
                      // "pulsa para reproducir" y aquí el contenido YA se está
                      // reproduciendo debajo. Tapaba el vídeo para decir algo
                      // que el propio vídeo desmiente.
                      //
                      // En grande tampoco va el marco: el foco ya no está en
                      // la ficha, y un recuadro alrededor de toda la pantalla
                      // no señala nada.
                      final marcar = !grande && foco;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRect(child: video!),
                          if (marcar)
                            IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                    child: hijo!,
                  ),
                );
              },
            );
          },
          // La instancia guardada, no una nueva: ver `_reproductor`.
          child: _reproductor,
        );
      },
    );

    Overlay.of(context, rootOverlay: true).insert(_entrada!);
    montada.value = true;
    return _turno;
  }

  /// Solo mueve el hueco. Nunca desmonta nada.
  ///
  /// La ficha lo llama en cada aviso de scroll. Antes llamaba a `mostrar`, y
  /// eso es peligroso: si el titulo calculado sale distinto por poco que sea
  /// —un episodio que acaba de cargarse, una copia con otras alternativas—,
  /// `mostrar` cierra lo que hay y monta otro. A mitad de una resolucion, eso
  /// es exactamente el reproductor destruido del log.
  void reubicar(Rect hueco) {
    if (_entrada == null) return;
    _hueco.value = hueco;
  }

  /// A pantalla completa. Empuja la ruta transparente que recoge el "atrás" y
  /// las teclas.
  void expandir(BuildContext context) {
    if (_entrada == null || _expandido.value) return;
    _expandido.value = true;

    Navigator.of(context)
        .push(
          PageRouteBuilder<void>(
            // Transparente y sin transición: el reproductor ya está en
            // pantalla, en el `Overlay`. Esta ruta no pinta, solo escucha.
            opaque: false,
            barrierColor: Colors.transparent,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (contexto, _, _) => const _RutaTeclas(),
          ),
        )
        .then((_) {
          // Se vuelve al hueco tanto si se salió con "atrás" como si la ruta
          // se cerró por cualquier otro motivo.
          _expandido.value = false;
        });
  }

  /// Las teclas del mando, de la ruta transparente al reproductor.
  KeyEventResult tecla(KeyEvent evento) =>
      _clave.currentState?.manejarTecla(evento) ?? KeyEventResult.ignored;

  /// El "atrás" estando en grande. Devuelve `true` si el reproductor lo usó
  /// para cerrar su menú o sus controles; `false` si toca encogerse.
  bool atras() => _clave.currentState?.manejarAtras() ?? false;

  /// Quita la vista previa y para la reproducción.
  ///
  /// Lo llama la ficha al cerrarse. Es lo que hace que salir de la ficha sí
  /// pare el vídeo, mientras que volver del reproductor grande no.
  /// Cierra solo si lo que suena es de este titulo.
  ///
  /// Hace falta por el salto entre fichas de "Quizas te guste", que usa
  /// `pushReplacement`: ahi el `dispose` de la ficha vieja corre DESPUES de
  /// que la nueva haya montado su vista previa, asi que un `cerrar()` a secas
  /// mataba la del sucesor y la ficha nueva se quedaba sin video.
  /// Cierra solo si el turno indicado sigue siendo el que manda.
  void cerrarSi(int turno) {
    if (turno != _turno) return;
    cerrar();
  }

  void cerrar() {
    _entrada?.remove();
    _entrada = null;
    _urlActual = null;
    _reproductor = null;

    // ── LOS AVISOS, DESPUES DEL FOTOGRAMA ─────────────────────────────────
    //
    // Esto se llama desde el `dispose` de la ficha, y ahi el arbol esta
    // BLOQUEADO: escribir en un `ValueNotifier` hace que sus oyentes pidan
    // reconstruirse, y pedirlo con el arbol bloqueado revienta con
    // "setState() or markNeedsBuild() called when widget tree was locked".
    //
    // Los oyentes son los `ValueListenableBuilder` de la entrada que se acaba
    // de quitar. Aplazando la escritura, para cuando ocurre ya estan
    // desmontados y no hay a quien avisar: el valor se limpia y no reconstruye
    // nada.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Salvo que en ese rato se haya montado otra vista previa; borrarle el
      // hueco la mandaria a pantalla completa.
      if (_entrada != null) return;
      montada.value = false;
      _expandido.value = false;
      _conFoco.value = false;
      _hueco.value = null;
    });
  }
}

/// La ruta que no pinta nada.
///
/// Existe por dos cosas que el `Overlay` no da: recoger el "atrás" del mando
/// y tener el foco para recibir las teclas. Transparente, así que lo que se ve
/// es el reproductor de encima.
class _RutaTeclas extends StatelessWidget {
  const _RutaTeclas();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (hecho, _) {
        if (hecho) return;
        // Primero que el reproductor cierre lo suyo —menú, controles—; solo
        // cuando ya no tiene nada que cerrar, esta ruta se va y la vista
        // previa vuelve al hueco de la ficha.
        if (!TvVistaPrevia.instancia.atras()) Navigator.of(context).pop();
      },
      child: FocusScope(
        autofocus: true,
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, evento) => TvVistaPrevia.instancia.tecla(evento),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
