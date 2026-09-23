import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../services/dynamic_scraper_service.dart';
import '../../services/turbo_proxy.dart';
import '../../services/tv/tv_mpv_config.dart';
import '../../services/filtro_calidad_service.dart';
import '../../utils/atras_tv.dart';
import '../../utils/cabeceras_stream.dart';
import '../../utils/motivos_reporte.dart';
import '../../utils/clasificacion_stream.dart';
import 'tv_loading_animation.dart';
import '../../services/m3u_service.dart';
import '../../services/watch_progress_service.dart';

/// Reproductor del televisor en modo autónomo (sin teléfono).
///
/// Es hermano del receptor de transmisiones, no el mismo: aquel obedece
/// órdenes que llegan por la red y este obedece al mando. Compartir uno solo
/// habría significado un archivo con dos dueños y un `if` en cada método.
///
/// Lo que sí comparten es el LENGUAJE: misma línea de tiempo, mismos iconos de
/// pistas, mismo selector a dos columnas, mismo criterio de que el foco se
/// marca con brillo y nunca con tamaño.
class TvPlayerScreen extends StatefulWidget {
  final M3UItem item;
  final String titulo;

  /// Solo lo rellena la vista previa de la ficha. Si es `null`, esto es una
  /// pantalla normal empujada al `Navigator` y todo funciona como siempre.
  ///
  /// SI NO ES NULL, este reproductor NO vive en una ruta: vive en el `Overlay`
  /// de la app, por encima del `Navigator`. Ese es el truco entero de que
  /// pasar de la ficha al reproductor grande no recargue el vídeo — al no
  /// estar dentro de una ruta, navegar no lo destruye ni lo vuelve a montar.
  ///
  /// A cambio hay dos cosas que aquí NO puede hacer, y por eso se consulta
  /// este valor en varios sitios:
  ///
  ///  · `PopScope` necesita una `ModalRoute` para engancharse, y en el
  ///    `Overlay` no hay ninguna. El "atrás" lo intercepta quien lo montó.
  ///  · No puede robar el foco: mientras está pequeño, el foco es de la ficha.
  ///
  /// El valor dice si está en grande. Los controles solo se pintan entonces:
  /// en un recuadro de 360 px son ilegibles y además tapan el vídeo.
  final ValueListenable<bool>? expandido;

  const TvPlayerScreen({
    super.key,
    required this.item,
    required this.titulo,
    this.expandido,
  });

  @override
  State<TvPlayerScreen> createState() => TvPlayerScreenState();
}

class TvPlayerScreenState extends State<TvPlayerScreen> {
  /// ¿Vive en el `Overlay` en vez de en una ruta?
  bool get _enOverlay => widget.expandido != null;

  /// ¿Se está viendo a pantalla completa?
  bool get _grande => widget.expandido?.value ?? true;

  /// Para que quien lo monta en el `Overlay` pueda pasarle las teclas del
  /// mando: allí arriba no las recibe por su cuenta.
  KeyEventResult manejarTecla(KeyEvent evento) =>
      _tecla(_playerFocusNode, evento);

  /// El "atrás", con el mismo orden de siempre: primero cierra el menú, luego
  /// los controles, y solo entonces admite que se quiere salir.
  bool manejarAtras() => _manejarAtras();
  // EXACTAMENTE la misma configuracion que el receptor de transmisiones.
  //
  // `hwdec: 'mediacodec'` va AQUI, en la creacion, y no por `setProperty`:
  // `AndroidVideoController.create()` aplica lo suyo DESPUES, y con 'auto-safe'
  // este SoC (Amlogic) elige `mediacodec-copy` — una copia por CPU de cada
  // fotograma 1080p, que son tirones.
  //
  // Creandolo tarde y sin esto, el log decia
  // "h264_mediacodec: Both surface and native_window are NULL": el decodificador
  // arrancaba sin superficie donde pintar y la pantalla se quedaba NEGRA con el
  // audio corriendo por detras.
  final Player _player = Player(
    configuration: PlayerConfiguration(
      title: 'Bump Comba TV',
      bufferSize: 32 * 1024 * 1024, // 32 MB — moderado para TVs de gama baja
      logLevel: kDebugMode ? MPVLogLevel.info : MPVLogLevel.error,
      // libass apagado: el widget Video solo pinta subtitulos con su
      // SubtitleView de Flutter cuando libass no esta. Con libass, MPV los
      // dibuja sobre la Surface de Android y no se ven.
      libass: false,
    ),
  );

  /// El nivel 2 del filtro de calidad esta puesto en ESTA reproduccion.
  ///
  /// Significa `mediacodec-copy` en vez de `mediacodec`, que es la unica forma
  /// de que MPV vea el fotograma y pueda aplicarle el shader de desbloqueo.
  bool _nivel2EnUso = false;

  /// El decoder ya elegido. Se decide en `initState` y NO aqui: este campo es
  /// `late final`, asi que su inicializador correria la primera vez que
  /// `build` lo leyera — y eso puede pasar DESPUES de aplicar los ajustes de
  /// MPV. Si eso ocurriera, se pagaria la copia por CPU sin el filtro puesto,
  /// que es lo peor de los dos mundos.
  String _hwdec = 'mediacodec';

  late final VideoController _controlador = VideoController(
    _player,
    configuration: VideoControllerConfiguration(
      enableHardwareAcceleration: true,
      hwdec: _hwdec,
    ),
  );

  /// Decide entre el camino rapido y el camino con filtro, ANTES de crear el
  /// controlador — que es el unico momento en que se puede elegir (ver el
  /// comentario de `_player`: por `setProperty` llega tarde).
  ///
  /// ── POR QUE AQUI HAY MAS CUIDADO QUE EN EL TELEFONO ────────────────────
  ///
  /// `mediacodec-copy` saca cada fotograma a memoria por CPU. En este SoC
  /// (Amlogic) eso ya se probo a 1080p y eran tirones —esta documentado justo
  /// arriba—, asi que aqui se exige ademas que la fuente NO pase de 720p, que
  /// es la mitad de pixeles que copiar y ademas el unico caso en que el filtro
  /// tiene algo que hacer.
  ///
  /// Un directo tampoco entra: no tiene segunda oportunidad, y si el aparato
  /// no da, lo que se pierde es lo que se estaba viendo en ese momento.
  ///
  /// El resto de condiciones —aparato ya descartado, gama baja, cuarentena—
  /// las decide `permiteNivel2`, que es el MISMO juez que en el telefono. Si
  /// esta reproduccion se atraganta, la prueba se cancela sola y este aparato
  /// no vuelve a intentarlo en una semana.
  /// El nivel 2 NO entra en el televisor.
  ///
  /// Se cableo el 2026-09-21 y se probo el mismo dia: la reproduccion se puso
  /// "super lenta, nada fluida". O sea que el aviso que ya estaba escrito en
  /// el comentario de `_player` —`mediacodec-copy` en este SoC son tirones—
  /// vale tambien a 720p, no solo a 1080p como se supuso al cablearlo.
  ///
  /// Se deja el cableado entero en su sitio, apagado por aqui, y NO se borra
  /// a proposito: el trabajo de averiguar donde enchufarlo ya esta hecho, y
  /// si algun dia hay un televisor con mas musculo esto es una linea.
  ///
  /// Lo que SI sigue llegando al televisor, porque no depende del decodificador
  /// y no cuesta rendimiento: el filtro de capa (`RealceDeVideo`), el registro
  /// de alturas y el tope de bitrate levantado para fuentes de 720p.
  /// El nivel 2 NO entra en el televisor.
  ///
  /// Se cableo el 2026-09-21 y la reproduccion se puso "super lenta, nada
  /// fluida". Se preparo despues una prueba con el shader LIGERO —una sola
  /// pasada, ~11 tomas por pixel en vez de ~30— para separar si costaba la
  /// copia del fotograma o las pasadas, pero se decidio no seguir por ahi y
  /// quedarse con lo que ya funcionaba.
  ///
  /// Esa prueba queda montada y lista: poner esto en `true` la enciende
  /// entera —shader ligero, ajustes minimos y el desenfoque de capa apagado
  /// para no medir dos cosas a la vez—. Si algun dia interesa saberlo, no hay
  /// que rehacer nada.
  ///
  /// Lo que SI llega al televisor: el desenfoque de capa de aqui abajo, el
  /// filtro de color, el registro de alturas y el tope de bitrate levantado.
  /// CERRADO: el televisor no puede con `mediacodec-copy`. Y ya no es una
  /// suposicion — esta medido, y por accidente de la forma mas limpia
  /// posible.
  ///
  /// La prueba del 2026-09-21 iba a comparar la copia CON el shader ligero.
  /// El shader no llego a extraerse a tiempo y la reproduccion fue sin el
  /// (lo canto el aviso de mas abajo). Asi que lo que se midio fue la copia
  /// DESNUDA, sin una sola instruccion de shader encima:
  ///
  ///   hwdec-current = mediacodec-copy
  ///   glsl-shaders  = (vacio)
  ///   descartados(vo): 0 -> 0 -> 9 -> 31
  ///
  /// Con `hwdec: mediacodec` ese contador se quedaba en 1 durante minutos.
  /// O sea que **la copia por si sola ya descarta fotogramas**, antes de
  /// pedirle ningun trabajo extra a la GPU. El log se llena ademas de
  /// `mali_gralloc: Attempt to call unlock*() on an buffer locked with
  /// invalid write locks`, que es el camino de la copia machacando al
  /// asignador de la GPU.
  ///
  /// Esto cierra el asunto: el coste NO eran las pasadas del shader, era
  /// sacar cada fotograma a memoria. Y como el shader necesita esa copia para
  /// existir, **en el televisor no se puede desbloquear por software**, ni
  /// con una pasada ni con media.
  ///
  /// Lo que queda para los cuadros ahi: el desenfoque de capa de aqui abajo
  /// (ciego, pero gratis) y el bitrate, que ya pide `max`.
  static const bool _nivel2PermitidoEnTv = false;

  String _decodificadorElegido() {
    if (!_nivel2PermitidoEnTv) {
      _nivel2EnUso = false;
      return 'mediacodec';
    }
    final filtro = FiltroCalidadService();
    final techo = filtro.techoConocido(widget.item.url);
    final bool fuenteBaja = techo != null && techo > 0 && techo <= 720;

    if (widget.item.isLive || !fuenteBaja) {
      _nivel2EnUso = false;
      return 'mediacodec';
    }
    if (!filtro.permiteNivel2(widget.item.url, intento: 0)) {
      _nivel2EnUso = false;
      return 'mediacodec';
    }

    _nivel2EnUso = true;
    unawaited(filtro.marcarNivel2EnPrueba());
    debugPrint('TvPlayer: nivel 2 puesto (fuente de ${techo}p)');
    return 'mediacodec-copy';
  }

  final List<StreamSubscription> _subs = [];
  final FocusNode _playerFocusNode = FocusNode(debugLabel: 'TvPlayerKeys');

  /// La pantalla ya se fue y el `Player` esta destruido.
  ///
  /// ── POR QUE HACE FALTA ADEMAS DE `mounted` ─────────────────────────────
  ///
  /// Resolver la pagina de un servidor tarda SEGUNDOS: se abre un WebView, se
  /// carga la web del proveedor entera y se espera a pillar el enlace del
  /// video. En ese rato el usuario puede salir de la ficha de sobra.
  ///
  /// Cuando la resolucion termina, el `State` ya esta destruido y el `Player`
  /// con el; tocarlo entonces revienta con `[Player] has been disposed`. Y lo
  /// peor no es el error: es que ese fallo se tomaba por un servidor caido y
  /// disparaba el failover sobre un reproductor que ya no existe, dejando en
  /// el log "el unico servidor disponible fallo" cuando el servidor no habia
  /// dicho nada.
  ///
  /// `mounted` no basta: el `Player` se destruye en `dispose`, y hay tramos
  /// `async` que siguen despues. Esto es explicito y no depende del orden.
  bool _muerto = false;

  bool _reproduciendo = false;
  bool _buffering = true;

  /// ¿Ha llegado ya el primer fotograma?
  ///
  /// Sin esto el spinner solo salia con `buffering`, y hay un hueco entre que
  /// MPV deja de bufferear y aparece la imagen: ahi la pantalla se quedaba
  /// NEGRA y sin nada, que es lo que hace pensar que se colgo.
  bool _primerFrameListo = false;

  /// Hasta donde hay datos cargados (posicion ABSOLUTA, no una duracion).
  Duration _bufer = Duration.zero;

  /// Cuando avanzo la posicion por ultima vez.
  DateTime _ultimoAvance = DateTime.now();

  /// Si toca enseñar el spinner.
  ///
  /// EL JUEZ ES EL AVANCE, NO `buffering`.
  ///
  /// El spinner se quedaba puesto con el video ya corriendo, y el motivo es
  /// que dependia de `_buffering`: MPV mantiene esa bandera levantada mientras
  /// rellena el bufer, y con una lista HLS que reconecta cada pocos segundos
  /// no la baja casi nunca. Preguntarle a MPV "¿estas cargando?" da una
  /// respuesta que no coincide con lo que se ve.
  ///
  /// Si el vídeo está pausado, o si ya arrancó y la reproducción avanza,
  /// el spinner no debe mostrarse jamás.
  /// Solo se muestra:
  /// 1. Durante la carga inicial antes de arrancar (a menos que ya haya frame y progreso).
  /// 2. Si MPV reporta `_buffering == true` y la posición lleva más de 1.5s congelada.
  bool get _cargando {
    if (_pausadoAdrede) return false;
    // ANTES DE ARRANCAR, "no reproduciendo" NO es una pausa: es que MPV aún no
    // empezó (se está resolviendo la página del servidor, abriendo el video o
    // llenando el búfer). Comprobar `_reproduciendo` aquí ocultaba el spinner
    // justo en el tramo más largo de espera, y la pantalla negra parecía un
    // fallo hasta que el video salía solo.
    if (!_arranco) {
      if (_primerFrameListo && _posicion > Duration.zero) return false;
      return true;
    }
    // Ya arrancado, no reproducir sí es una pausa: sin spinner.
    if (!_reproduciendo) return false;
    return _buffering &&
        DateTime.now().difference(_ultimoAvance) >
            const Duration(milliseconds: 1500);
  }

  /// Lo ultimo que se pinto, para repintar solo cuando cambia.
  bool _spinnerVisible = true;

  // ── EL COLCHON CRECE SI LA LINEA NO DA ─────────────────────────────────
  //
  // Arrancar con el bufer vacio hace que el video empiece al instante, pero si
  // el proveedor da 1,5 Mbps para un video de 8 se queda sin datos enseguida y
  // aparecen los cortes cada pocos segundos.
  //
  // Un valor fijo no sirve para las dos cosas: alto, la primera imagen tarda
  // quince segundos; bajo, la pelicula va a tirones. Asi que se empieza bajo
  // —arranque rapido— y CADA VEZ QUE SE CORTA se pide mas colchon para
  // reanudar. El resultado es menos cortes y mas largos en vez de muchos y
  // cortos, que es lo que de verdad se nota mirando.
  //
  // Es lo mismo que hace un reproductor de streaming serio: adaptarse a la
  // linea que hay, no a la que uno querria.
  final List<DateTime> _cortes = [];
  int _esperaBufer = _esperaBuferInicial;
  static const int _esperaBuferInicial = 2;
  static const int _esperaBuferMaxima = 20;

  /// Velocidad de descarga, para la esquina superior izquierda.
  double _kbps = 0;
  Timer? _sondeoVelocidad;
  Timer? _diagnostico;
  Timer? _prepararAlternativas;
  Duration _posicion = Duration.zero;
  Duration _duracion = Duration.zero;

  bool _controlesVisibles = true;
  Timer? _ocultar;

  /// 0 = play, 1 = línea de tiempo, 2 = subtítulos, 3 = audio.
  int _foco = 0;

  // Salto en curso: se acumula mientras se pulsa y se aplica al soltar, para
  // no vaciar el decodificador en cada pulsación.
  bool _preparandoSalto = false;
  Duration _saltoPrevisto = Duration.zero;
  Timer? _confirmarSalto;

  // ── Acciones del titulo, DENTRO DEL REPRODUCTOR ──────────────────────────
  //
  // Estaban en la ficha, debajo de la sinopsis. Aqui tienen mas sentido: es
  // donde estas viendo el contenido, que es cuando decides si lo guardas, si te
  // gusta o si algo va mal y quieres reportarlo.
  //
  // El estilo es el del reproductor —icono plano y texto, blanco si el mando
  // esta encima y gris si no—, no el de la ficha: aqui no hay recuadros.
  bool _esFavorito = false;

  /// De adorno, como estaban en la ficha: no se manda nada a la BD ni se
  /// guarda. Viven mientras el reproductor esta abierto.
  bool _meGusta = false;
  bool _noMeGusta = false;

  bool _reportando = false;

  /// El menu del engranaje.
  bool _ajustesAbierto = false;
  int _ajustesIdx = 0;

  /// El menu de motivos de reporte, hermano del de pistas.
  bool _reporteAbierto = false;
  int _reporteIdx = 0;
  List<String> _motivos = const [];

  bool _menuAbierto = false;
  int _menuTab = 0;
  int _menuIdx = 0;

  // ── Seguir viendo ────────────────────────────────────────────────────────
  final _progreso = WatchProgressService();
  Timer? _guardado;
  Duration? _reanudadoDesde;

  /// Borra el aviso de "Reanudado desde...".
  ///
  /// El aviso se ponia y NO se quitaba nunca: como solo se pinta con los
  /// controles abiertos, cada vez que se abrian volvia a salir, aunque
  /// llevaras media pelicula. Un dato de hace cuarenta minutos presentado como
  /// si acabara de pasar.
  ///
  /// Es una nota de paso —informa de que no empezaste desde cero— y como tal
  /// tiene que caducar.
  Timer? _olvidarReanudado;

  // ── Cambio de servidor ───────────────────────────────────────────────────
  //
  // Mismo problema que en la transmision y misma solucion: el titulo puede
  // estar en varios sitios y el primero no siempre responde.
  late List<String> _urls;
  late List<M3UItem> _items;
  int _idxServidor = 0;

  /// Cuantas veces se ha cambiado de servidor POR CAUDAL BAJO.
  ///
  /// Tope de uno por reproduccion, y es deliberado. Cambiar de servidor le
  /// cuesta al usuario un corte y una recarga; encadenar varios buscando el
  /// mejor convierte "se ve con cuadros" en "no para de cortarse", que es
  /// peor. Con un salto se sale del servidor claramente malo; si el siguiente
  /// tampoco da, al menos no se le arruina la pelicula probando.
  int _saltosPorCaudal = 0;

  /// Lecturas seguidas de caudal bajo. Hacen falta DOS para actuar.
  ///
  /// `video-bitrate` es una media movil: justo despues de un salto de
  /// posicion, de un corte o del arranque sale hundido sin que la fuente
  /// tenga nada malo. Exigir dos lecturas seguidas (10 s) filtra ese ruido.
  int _lecturasCaudalBajo = 0;

  /// Si el caudal es insuficiente según [TvMpvConfig.caudalInsuficiente],
  /// el macrobloqueo es inevitable del origen: el desenfoque de capa no lo
  /// arregla y solo cobra fotogramas. Se desactiva cuando esto es true.
  bool _bloqueoInevitable = false;
  int _ticksBloqueoInevitable = 0;
  bool _avisoCalidadBaja = false;
  bool _avisoCalidadYaMostrado = false;
  int _contadorAviso = 5;
  Timer? _timerAviso;
  VoidCallback? _m3uListener;

  Timer? _vigilante;
  /// Retardo para no mostrar el spinner de inmediato al cambiar de servidor.
  /// El último frame del video se mantiene visible en la Surface de Android;
  /// si el servidor nuevo carga en menos de 2 s, el usuario no ve spinner.
  Timer? _spinnerDemorado;
  Duration _posVigilada = Duration.zero;
  int _segundosSinAvance = 0;
  bool _cambiandoServidor = false;

  /// Segundos parado que bastan para probar otro servidor. El mismo numero que
  /// usa el telefono, y por el mismo motivo: por debajo se cambia por baches
  /// normales del bufer, y por encima el usuario ya se ha ido.
  static const int _umbralParado = 9;

  /// ¿Lo paró el usuario?
  ///
  /// EL VIGILANTE NO PUEDE CONTAR MIENTRAS ESTA EN PAUSA.
  ///
  /// En pausa no entran bytes y la posicion no se mueve: para el vigilante era
  /// exactamente igual que un servidor muerto, asi que a los 45 segundos de
  /// haber pausado cambiaba de servidor solo. Y al cambiar, volvia a
  /// reproducir — el usuario habia pulsado pausa y la pelicula arrancaba sola
  /// por otro sitio.
  ///
  /// El estado `playing` de MPV no basta para distinguirlo: tambien se pone en
  /// falso al bufferear o al cambiar de pista. Esta bandera dice quien lo paro,
  /// que es lo unico que importa aqui.
  bool _pausadoAdrede = false;

  // ── Vigilante de ARRANQUE ────────────────────────────────────────────────
  //
  // Es un fallo DISTINTO del de "se paro a mitad", y necesita su propio juez.
  //
  // El de mitad mira si la posicion avanza. Ese no sirve aqui: durante el
  // arranque la posicion es 0 y no se mueve porque aun no hay imagen. Aplicarle
  // el mismo criterio provocaba que cambiara de servidor cada 9s sin dejar
  // arrancar nunca; excluir el arranque del todo dejaba el caso contrario, un
  // servidor que se queda cargando para siempre y nadie lo releva.
  //
  // Lo que se mide aqui es si ENTRAN DATOS. Con `cache-speed` a cero no esta
  // cargando lento: no esta cargando.
  int _segundosDesdeAbrir = 0;

  /// Segundos que se le dan a un servidor para EMPEZAR antes de pasar al
  /// siguiente. Los mismos 9 que usa el telefono, para que la espera se sienta
  /// igual se abra desde donde se abra.
  static const int _umbralArranque = 9;

  /// Tope absoluto de espera al arrancar, en segundos.
  ///
  /// Los 9 de arriba cuentan SIN DATOS; este cuenta desde que se abrio, pasen
  /// o no pasen bytes. Es la red de seguridad para el caso en que el servidor
  /// mande y mande sin llegar nunca a soltar un fotograma.
  static const int _umbralArranqueMaximo = 45;

  /// Segundos seguidos sin que llegue NADA mientras arranca.
  int _segundosSinDatos = 0;

  /// Cuanto bufer habia en la ultima vuelta del vigilante.
  Duration _buferVigilado = Duration.zero;

  /// Cuantos bytes llevaba bajados TurboProxy en la ultima vuelta.
  int _bytesVigilados = 0;

  /// El fichero pide mas caudal del que hay. NO es un fallo del servidor.
  bool _faltaCaudal = false;

  /// A partir de aqui se juzga el caudal, en segundos desde que se abrio.
  ///
  /// Antes no se puede: TurboProxy arranca en passthrough y sube conexiones
  /// poco a poco —la "rampa ascendente" del log—, asi que medir en los
  /// primeros segundos daria por lento algo que todavia no ha acelerado.
  static const int _cuandoJuzgarCaudal = 18;

  /// La primera posicion observada tras abrir. La referencia contra la que se
  /// mide si el video avanza de verdad.
  Duration? _posReferencia;

  /// Si este servidor llego a arrancar. Se reinicia en cada apertura.
  bool _arranco = false;

  /// Avisos de MPV de que los bytes que llegan estan rotos.
  ///
  /// Un vigilante que solo mira si la posicion avanza NO ve este fallo: con
  /// datos corruptos la posicion avanza —a tirones, y con el audio por su
  /// lado— y todo parece sano. Aqui se lee lo que dice el demuxer.
  static const List<String> _marcasCorrupcion = [
    'Invalid EBML length',
    'Corrupt file detected',
    'Invalid audio PTS',
    'Audio/Video desynchronisation',
  ];
  final List<DateTime> _corrupcion = [];
  static const int _corrupcionParaCambiar = 6;

  @override
  void initState() {
    super.initState();
    // LO PRIMERO, antes de que nada pueda leer `_controlador`.
    _hwdec = _decodificadorElegido();
    // EL MISMO PERFIL DE MPV QUE EL RECEPTOR.
    //
    // Faltaba, y era la diferencia entera: el mismo video se veia fino al
    // transmitirlo desde el telefono y a tirones al abrirlo desde el catalogo,
    // porque aqui el reproductor arrancaba con los valores por defecto de MPV.
    // Ahora los dos comparten `TvMpvConfig` — framedrop=vo, cache en RAM, el
    // reparto 96/48 MB del bufer... — que son decisiones ganadas peleando con
    // este proveedor en este aparato.

    _subs.addAll([
      _player.stream.playing.listen((v) {
        if (mounted) {
          setState(() {
            _reproduciendo = v;
            if (_spinnerDemorado == null || !_spinnerDemorado!.isActive) {
              _spinnerVisible = _cargando;
            }
          });
        }
      }),
      _player.stream.buffering.listen((v) {
        if (mounted) {
          setState(() {
            _buffering = v;
            if (_spinnerDemorado == null || !_spinnerDemorado!.isActive) {
              _spinnerVisible = _cargando;
            }
          });
        }
        if (v) _anotarCorte();
      }),
      // La altura REAL de la fuente, que es lo unico que no miente sobre la
      // calidad: ni la URL ni la lista maestra lo dicen del todo. Mueve el
      // filtro de capa y deja apuntado el techo del titulo, que es lo que
      // luego decide si a este contenido se le puede levantar el tope de
      // bitrate. En HLS la altura cambia en marcha, de ahi que sea un
      // `listen` y no una comprobacion de una sola vez.
      _player.stream.height.listen((v) {
        if (!mounted || v == null || v <= 0) return;
        unawaited(
          FiltroCalidadService().anotarAltura(
            widget.item.url,
            v,
            nombre: widget.item.name,
          ),
        );
      }),
      _player.stream.position.listen((v) {
        // Cada vez que la posicion se mueve de verdad se apunta la hora: es lo
        // unico que prueba que el video esta corriendo. Se apunta SIEMPRE,
        // tambien mientras se apunta un salto: el vigilante necesita saber que
        // el video sigue vivo pase lo que pase.
        final bool avanzo = v != _posicion;
        if (avanzo) _ultimoAvance = DateTime.now();

        // La prueba del nivel 2 se da por buena cuando el video lleva un rato
        // corriendo de verdad. Se mira la POSICION y no un temporizador: un
        // reloj corre igual con la pantalla en negro.
        if (_nivel2EnUso && v >= FiltroCalidadService.margenDePrueba) {
          _nivel2EnUso = false;
          unawaited(FiltroCalidadService().confirmarNivel2Estable());
        }

        // ── MIENTRAS SE APUNTA UN SALTO, MANDA EL USUARIO ────────────────
        if (_preparandoSalto) return;

        bool estadoCambio = false;
        if (!_arranco &&
            _reproduciendo &&
            (v > const Duration(milliseconds: 200) || _primerFrameListo)) {
          _arranco = true;
          _primerFrameListo = true;
          if (_spinnerVisible) {
            _spinnerDemorado?.cancel();
            _spinnerVisible = false;
            estadoCambio = true;
          }
        } else if (_spinnerDemorado == null || !_spinnerDemorado!.isActive) {
          if (_cargando != _spinnerVisible) {
            _spinnerVisible = _cargando;
            estadoCambio = true;
          }
        }

        if (!_preparandoSalto) {
          _posicion = v;
        }
        if (mounted && (_controlesVisibles || estadoCambio)) setState(() {});
      }),
      _player.stream.duration.listen((v) {
        if (mounted) setState(() => _duracion = v);
      }),
      // Cuanto hay cargado por delante. Lo pinta la linea de tiempo como una
      // pista mas clara, igual que el receptor: sin ella no se sabe si el
      // video esta cargando o parado.
      _player.stream.buffer.listen((v) {
        _bufer = v;
        if (mounted && (_controlesVisibles || _preparandoSalto)) {
          setState(() {});
        }
      }),
    ]);

    // El titulo primero y sus alternativas despues, sin repetidos.
    //
    // Si el item fue abierto antes de que terminara el cruce en segundo plano,
    // se consulta M3UService para obtener las alternativas ya conocidas o de la BD.
    final alts =
        widget.item.alternatives.isNotEmpty
            ? widget.item.alternatives
            : M3UService().getAlternativesFor(widget.item);

    _urls = <String>{widget.item.url, for (final alt in alts) alt.url}.toList();
    _items = [widget.item, ...alts];

    if (_urls.length <= 1) {
      debugPrint(
        'TvPlayer: "${widget.item.name}" no tiene servidor alternativo '
        '— buscando alternativas en otros proveedores...',
      );
      unawaited(_buscarAlternativasDeOtrosProveedores());
    } else {
      debugPrint('TvPlayer: ${_urls.length} servidores disponibles');
    }

    // Escuchar a M3UService por si el indexado en segundo plano termina mientras
    // se reproduce y añade alternativas desde la BD (Supabase).
    _m3uListener = () {
      if (_urls.length <= 1 && mounted) {
        final freshAlts = M3UService().getAlternativesFor(widget.item);
        if (freshAlts.isNotEmpty) {
          final nuevasUrls =
              <String>{
                widget.item.url,
                for (final alt in freshAlts) alt.url,
              }.toList();
          if (nuevasUrls.length > _urls.length) {
            setState(() {
              _urls = nuevasUrls;
            });
            debugPrint(
              'TvPlayer: ${_urls.length} servidores disponibles (actualizado tras indexado de BD)',
            );
          }
        }
      }
    };
    M3UService().addListener(_m3uListener!);

    _subs.add(
      _player.stream.log.listen((l) {
        // Fallo definitivo: no se espera a los 9 segundos, se pasa ya al
        // siguiente y este se marca para no volver a probarlo.
        // Ojo: solo si el servidor actual es ya una URL de video. Si es una
        // pagina a medio resolver, los errores son de la pagina, no del video.
        if (!_arranco &&
            !_resolviendo.contains(_idxServidor) &&
            _marcasFatales.any(l.text.contains)) {
          debugPrint(
            'TvPlayer: servidor $_idxServidor roto (${l.text.trim()})',
          );
          _rotos.add(_idxServidor);
          unawaited(_siguienteServidor('el servidor no sirve el video'));
          return;
        }
        if (_marcasCorrupcion.any(l.text.contains)) {
          final ahora = DateTime.now();
          _corrupcion.add(ahora);
          _corrupcion.removeWhere(
            (t) => ahora.difference(t) > const Duration(seconds: 60),
          );
        }
      }),
    );

    // El primer fotograma: en cuanto el video tiene tamaño real, hay imagen.
    _controlador.rect.addListener(() {
      final r = _controlador.rect.value;
      if (r != null && r.width > 0 && !_primerFrameListo && mounted) {
        _spinnerDemorado?.cancel();
        setState(() {
          _primerFrameListo = true;
          if (_posicion > Duration.zero) {
            _arranco = true;
            _spinnerVisible = false;
          }
        });
      }
    });

    _esFavorito =
        widget.item.isFavorite ||
        M3UService().getFavorites().any(
          (f) =>
              (f.url.isNotEmpty && f.url == widget.item.url) ||
              (f.name == widget.item.name &&
                  f.seriesName == widget.item.seriesName),
        );

    _arrancarSondeoVelocidad();
    _arrancar();
    _mostrarControles();
  }

  /// Carga el titulo, reanudando donde se dejo.
  ///
  /// Se reanuda SIN PREGUNTAR, que es lo que hace Netflix. Un dialogo de
  /// "¿continuar o empezar de cero?" con un mando en la mano es una decision
  /// que nadie pidio: en el 95% de los casos se quiere continuar, y para el
  /// otro 5% ya esta la barra de tiempo.
  Future<void> _arrancar() async {
    // PRIMERO SE PINTA, DESPUES SE TRABAJA.
    //
    // Todo lo que viene detras —las ~30 propiedades de MPV, leer el historial,
    // levantar TurboProxy— corre por el canal de plataforma y en un Chromecast
    // HD tarda lo suyo. Lanzandolo aqui mismo, el hilo de interfaz se queda
    // ocupado ANTES de haber pintado un solo fotograma: se veia pantalla
    // negra, sin spinner, y parecia que no estaba cargando.
    //
    // Esperar al final del primer fotograma cuesta ~16 ms y garantiza que el
    // spinner ya este en pantalla cuando empieza lo pesado.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    // LA CONFIGURACION DE MPV SE ESPERA, no se lanza y se olvida.
    //
    // Estaba con `unawaited`, asi que el `open()` podia salir ANTES de que
    // estuvieran puestos el tamaño de cache, el reparto del bufer y el resto.
    // MPV arrancaba con sus valores por defecto y se comportaba de otra forma
    // — justo lo que este perfil existe para evitar.
    await TvMpvConfig.aplicarBase(
      _player,
      // Para decidir si se conserva el filtro de bucle del codec: con una
      // fuente de 720p hay holgura, con una de 1080p no.
      techoFuente: FiltroCalidadService().techoConocido(widget.item.url),
    );

    // QUE DECODIFICADOR ACABO USANDO, de verdad.
    //
    // Hace falta porque las opciones `vd-lavc-*` que acaba de poner
    // `aplicarBase` SOLO cuentan si MPV cayo a software: con MediaCodec
    // quien descodifica es el hardware y libavcodec no pinta nada. Sin esta
    // linea no hay forma de saber si el ajuste esta actuando o es un no-op,
    // que es exactamente el tipo de suposicion que ya nos costo cinco rondas
    // con el velo.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 4), () async {
        if (_muerto) return;
        try {
          final mpv = _player.platform as dynamic;
          if (mpv == null) return;
          for (final propiedad in const [
            'hwdec-current',
            'video-codec',
            'video-params/w',
            'video-params/h',
            'hls-bitrate',
          ]) {
            debugPrint(
              'TvPlayer DIAGNOSTICO $propiedad = '
              '${await mpv.getProperty(propiedad)}',
            );
          }
        } catch (e) {
          debugPrint('TvPlayer DIAGNOSTICO no se pudo leer -> $e');
        }
      }),
    );

    // Y encima del perfil base, el nivel 2 si entro. VA DESPUES A PROPOSITO:
    // `aplicarBase` pone `scale: bilinear` y `deband: no`, que son justo las
    // que el nivel 2 tiene que pisar. Al reves no serviria de nada.
    if (_nivel2EnUso) {
      try {
        final mpv = _player.platform as dynamic;
        if (mpv != null) {
          final filtro = FiltroCalidadService();
          // Los ajustes MINIMOS, no los del telefono: solo el shader ligero.
          // Meter el escalador sharp o `deband` encima contaminaria la
          // medida — si fuera a tirones no sabriamos a cuenta de que.
          // Se AWAITA la extraccion en vez de leer la ruta ya lista.
          //
          // El 2026-09-21 se leyo la version sincrona y salio `null`: el
          // precalentado no habia terminado y la prueba corrio sin shader.
          // Aqui ya estamos en un tramo asincrono, despues de `aplicarBase`,
          // asi que esperar no cuesta nada al arranque — y depender del reloj
          // para algo asi es como se pierde un experimento entero.
          final rutaLigero =
              filtro.rutaShaderLigeroSiYaEsta ??
              await filtro.rutaDelShaderLigero();
          if (rutaLigero == null) {
            debugPrint(
              'TvPlayer: AVISO el shader ligero no estaba extraido todavia; '
              'esta reproduccion va SIN desbloqueo',
            );
          }
          final ajustes = filtro.ajustesMpvTvLigero(rutaShader: rutaLigero);
          for (final e in ajustes.entries) {
            await mpv.setProperty(e.key, e.value);
          }
          debugPrint('TvPlayer: ajustes de nivel 2 aplicados');
          // Un respiro para que MPV tenga ya los parametros del video
          // decodificados; recien aplicados los ajustes todavia salen vacios.
          unawaited(
            Future<void>.delayed(const Duration(seconds: 3), () async {
              if (!_muerto) await filtro.diagnosticoDeImagen(mpv);
            }),
          );
        }
      } catch (e) {
        // Que un ajuste no exista en este build no puede tumbar la
        // reproduccion: el video se ve igual, solo que sin realce.
        debugPrint('TvPlayer: no se pudieron aplicar los ajustes -> $e');
      }
    }

    if (widget.item.esDeLaBD) {
      try {
        final mpv = _player.platform as dynamic;
        if (mpv != null) {
          await mpv.setProperty(
            'hls-bitrate',
            TvMpvConfig.hlsBitrate(
              techoFuente: FiltroCalidadService().techoConocido(
                widget.item.url,
              ),
            ),
          );
          await mpv.setProperty('scale', 'bilinear');
          await mpv.setProperty('cscale', 'bilinear');
          await mpv.setProperty('sharpen', '0.0');
          await mpv.setProperty('linear-upscaling', 'no');
          await mpv.setProperty('sigmoid-upscaling', 'no');
          await mpv.setProperty('deband', 'no');
          await mpv.setProperty('dither-depth', 'auto');
          await mpv.setProperty('vd-lavc-fast', 'yes');
          await mpv.setProperty('vd-lavc-skiploopfilter', 'nonref');
        }
      } catch (e) {
        debugPrint('TvPlayer: error aplicando perfil BD: $e');
      }
    }

    Duration desde = Duration.zero;
    try {
      final p = await _progreso.getProgressForItem(widget.item);
      // Los ultimos 60 s no se reanudan: quien llego al final quiere empezar
      // de nuevo, no ver los creditos otra vez.
      if (p != null &&
          !p.isCompleted &&
          p.positionSeconds > 30 &&
          p.durationSeconds - p.positionSeconds > 60) {
        desde = Duration(seconds: p.positionSeconds);
      }
    } catch (_) {}

    if (!mounted) return;
    if (desde > Duration.zero) {
      setState(() => _reanudadoDesde = desde);
      // 10 segundos: lo que se tarda en leerlo con calma, incluso si los
      // controles se abren un momento despues de que arranque el video.
      _olvidarReanudado?.cancel();
      _olvidarReanudado = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _reanudadoDesde = null);
      });
    }

    try {
      await _abrir(desde);
    } catch (e) {
      // Si el PRIMER servidor no arranca —tipico del de la base de datos,
      // cuya pagina puede no soltar el video— se pasa al siguiente en vez de
      // quedarse en negro esperando a un vigilante que aun no existe.
      debugPrint('TvPlayer: el primer servidor fallo ($e) — cambiando');
      unawaited(_siguienteServidor('fallo al abrir'));
    }
    // ── LAS ALTERNATIVAS SE PREPARAN DESDE EL PRINCIPIO ─────────────────
    //
    // Antes esto solo arrancaba cuando el primer servidor ECHABA A ANDAR. Pero
    // el caso en que hace falta cambiar es justo el contrario: el primero no
    // arranca, a los 9 segundos toca saltar, y ahi es cuando se ponia a cargar
    // la pagina en el navegador invisible — con el usuario mirando una pantalla
    // parada. De ahi el "al cambiar de servidor se pone lentisimo".
    //
    // ── SOLO SI EL VIDEO VA BIEN DE VERDAD ────────────────────────────────
    //
    // Esto abre un WebView para resolver la pagina de OTRO servidor por
    // adelantado. Un WebView es un Chromium entero: carga la web del proveedor
    // con sus fuentes, su JavaScript y su analitica.
    //
    // Estaba lanzado a los 3 segundos de abrir, SIEMPRE. Y en el log se ve lo
    // que eso provoca en un televisor de gama baja: el bufer ya venia justo
    // —"acelerando mid-stream, 1.7 Mbps"—, arranca el navegador encima, y MPV
    // empieza con "End of file" y "Packet corrupt". El adelanto que pretendia
    // ahorrar tiempo era justo lo que tumbaba la reproduccion.
    //
    // Ahora se comprueba cada 8 segundos y solo se dispara cuando el video
    // lleva un rato largo yendo fino. Si nunca va fino, no se prepara nada:
    // ese aparato no da para las dos cosas a la vez, y el video es lo que el
    // usuario esta mirando.
    _prepararAlternativas = Timer.periodic(const Duration(seconds: 8), (t) {
      if (_muerto) {
        t.cancel();
        return;
      }
      if (!_reproduccionSana) return;
      t.cancel();
      _prepararAlternativasEnSegundoPlano();
    });

    _armarVigilante();
    _armarGuardado();
  }

  /// Apunta un corte y, si se repiten, agranda el colchon de reanudacion.
  void _anotarCorte() {
    // Los primeros segundos no cuentan: ahi "bufferear" es cargar, no cortarse.
    if (!_arranco) return;

    final ahora = DateTime.now();
    _cortes.add(ahora);
    _cortes.removeWhere(
      (t) => ahora.difference(t) > const Duration(minutes: 2),
    );

    // Tres cortes en dos minutos ya no es mala suerte: es que la linea no da.
    if (_cortes.length < 3 || _esperaBufer >= _esperaBuferMaxima) return;
    _cortes.clear();
    _esperaBufer = (_esperaBufer * 2).clamp(
      _esperaBuferInicial,
      _esperaBuferMaxima,
    );
    debugPrint(
      'TvPlayer: cortes repetidos -> colchon de reanudacion a ${_esperaBufer}s',
    );
    unawaited(_ponerEsperaBufer(_esperaBufer));
  }

  Future<void> _ponerEsperaBufer(int segundos) async {
    try {
      final mpv = _player.platform as dynamic;
      await mpv?.setProperty('cache-pause-wait', '$segundos');
    } catch (e) {
      debugPrint('TvPlayer: no se pudo ajustar cache-pause-wait: $e');
    }
  }

  /// La URL local que sirve TurboProxy para el servidor actual.
  String? _urlTurbo;

  /// Baja los topes del demuxer cuando la fuente es una lista HLS.
  ///
  /// Ver la nota de `_abrir`: el perfil VOD contra un `.m3u8` produce cortes
  /// constantes. Es el mismo fallo que ya se corrigio en el receptor cuando el
  /// telefono no mandaba `isLive`.
  Future<void> _ajustarPerfilSegunFuente(String url) async {
    final low = url.toLowerCase();
    final esHls =
        esHlsPorUrl(url) ||
        DynamicScraperService().isSupported(widget.item.url);
    try {
      final mpv = _player.platform as dynamic;
      if (mpv == null) return;
      if (esHls) {
        if (widget.item.isLive) {
          await mpv.setProperty('cache-secs', '60');
          await mpv.setProperty('demuxer-readahead-secs', '20');
          // Tambien el directo: 'max' fijo le pedia la copia mas gorda a un
          // aparato flojo o a una linea justa, que es donde peor sienta.
          await mpv.setProperty(
            'hls-bitrate',
            TvMpvConfig.hlsBitrate(
              techoFuente: FiltroCalidadService().techoConocido(
                widget.item.url,
              ),
            ),
          );
          await mpv.setProperty('hls-forward-cache-secs', '30');
          await mpv.setProperty('hls-back-cache-secs', '10');
          await mpv.setProperty('cache-pause-initial', 'no');
          await mpv.setProperty('cache-pause-wait', '2');
          await mpv.setProperty('demuxer-cache-wait', 'no');
          debugPrint('TvPlayer: perfil HLS DIRECTO aplicado');
        } else {
          // HLS VOD (películas / series con manifiesto .m3u8):
          // Tienen toda la duración disponible. Un readahead de 45s y cache-pause-wait de 2s
          // permite iniciar de inmediato y saltar sin pausas excesivas.
          await mpv.setProperty('cache-secs', '120');
          await mpv.setProperty('demuxer-readahead-secs', '45');
          final bool esScrapeado =
              DynamicScraperService().isSupported(widget.item.url) ||
              low.contains('savefiles') ||
              low.contains('okcdn') ||
              low.contains('gnula');
          await mpv.setProperty(
            'hls-bitrate',
            TvMpvConfig.hlsBitrate(
              esScrapeado: esScrapeado,
              techoFuente: FiltroCalidadService().techoConocido(
                widget.item.url,
              ),
            ),
          );
          await mpv.setProperty('hls-forward-cache-secs', '45');
          await mpv.setProperty('hls-back-cache-secs', '30');
          await mpv.setProperty('cache-pause-initial', 'no');
          await mpv.setProperty('cache-pause-wait', '2');
          await mpv.setProperty('demuxer-cache-wait', 'no');
          await mpv.setProperty('hr-seek', 'default');
          await mpv.setProperty('hr-seek-framedrop', 'yes');
          debugPrint('TvPlayer: perfil HLS VOD aplicado');
        }
      } else {
        // Fichero entero: se restauran los valores del perfil base, por si el
        // servidor anterior era una lista HLS y los dejo bajados.
        await mpv.setProperty('cache-secs', '120');
        await mpv.setProperty('demuxer-readahead-secs', '90');
        await mpv.setProperty('cache-pause-initial', 'yes');
        await mpv.setProperty('cache-pause-wait', '4');
      }
    } catch (e) {
      debugPrint('TvPlayer: no se pudo ajustar el perfil: $e');
    }
  }

  /// Saca la URL del video de una pagina, con el extractor del telefono.
  ///
  /// SE HACE POR ADELANTADO, NO CUANDO YA HACE FALTA.
  ///
  /// Cargar la pagina en un navegador invisible cuesta lo suyo en un aparato
  /// de 1 GB: si se hace en el momento del fallo, se suma a una pantalla que
  /// ya lleva 9 segundos parada. Lanzandolo mientras el otro servidor va bien,
  /// el trabajo caro ocurre cuando NO molesta, y si luego hace falta cambiar,
  /// la URL ya esta lista y el cambio es inmediato.
  Future<String?> _resolverPagina(int indice) async {
    if (_resueltos.containsKey(indice)) return _resueltos[indice];
    if (_resolviendo.contains(indice)) return null;

    final pagina = _urls[indice];
    if (!DynamicScraperService().isSupported(pagina)) return pagina;

    _resolviendo.add(indice);
    debugPrint('TvPlayer: resolviendo la pagina del servidor $indice...');
    try {
      // ── DOS INTENTOS, COMO EN EL TELEFONO ──────────────────────────────
      //
      // Aqui se probaba UNA vez y, si fallaba, el servidor se daba por roto.
      // Pero la extraccion no falla solo cuando el servidor esta caido: falla
      // cuando la web tarda de mas, cuando el WebView arranca justo con poca
      // memoria, cuando un anuncio se cuela antes que el reproductor... y a la
      // segunda sale. El telefono reintenta por eso, y era la diferencia por
      // la que en el televisor habia titulos de la BD que "no funcionaban" y
      // en el movil si.
      for (var intento = 0; intento < 2; intento++) {
        if (_muerto) return null;
        if (intento > 0) {
          debugPrint('TvPlayer: reintentando la pagina del servidor $indice');
          // Un respiro antes de repetir: reintentar al instante suele repetir
          // el mismo fallo, porque lo que fallo sigue ocupado.
          await Future<void>.delayed(const Duration(seconds: 2));
          if (_muerto) return null;
        }

        final r = await DynamicScraperService()
            .extractStreamResult(pagina)
            .timeout(const Duration(seconds: 45));

        if (r != null && r.videoUrl.isNotEmpty) {
          String urlElegida = r.videoUrl;

          // Si hay alternativas en el resultado, agregarlas a la lista de URLs
          if (r.alternativeUrls.isNotEmpty) {
            for (final alt in r.alternativeUrls) {
              if (!_urls.contains(alt)) {
                _urls.add(alt);
              }
            }
          }

          // ── VERIFICACIÓN DE BITRATE/CAUDAL ANTES DE ABRIR ─────────
          // Si el candidato primario tiene caudal insuficiente pero alguna
          // de las alternativas tiene mejor caudal, elegimos la alternativa.
          if (urlElegida.toLowerCase().contains('.m3u8')) {
            try {
              final info = await DynamicScraperService.analizarManifiestoHls(urlElegida);
              if (info != null && info.esCaudalInsuficiente) {
                debugPrint(
                  'TvPlayer: stream primario ($urlElegida) tiene caudal insuficiente '
                  '(<0.07 bpp). Verificando alternativas antes de abrir...',
                );
                for (final alt in r.alternativeUrls) {
                  if (alt.toLowerCase().contains('.m3u8')) {
                    final altInfo = await DynamicScraperService.analizarManifiestoHls(alt);
                    if (altInfo != null && !altInfo.esCaudalInsuficiente) {
                      debugPrint(
                        'TvPlayer: alternativa pre-validada con caudal adecuado -> $alt',
                      );
                      urlElegida = alt;
                      break;
                    }
                  }
                }
              }
            } catch (_) {}
          }

          _resueltos[indice] = urlElegida;
          if (indice < _urls.length) {
            _urls[indice] = urlElegida;
          }
          // LOS SUBTITULOS SE GUARDAN, no se tiran.
          //
          // El extractor los devuelve junto al video —el telefono los recoge
          // en `_scrapedSubtitles`— y aqui se estaba usando solo `videoUrl`.
          // Por eso el contenido de la BD salia siempre sin subtitulos en el
          // televisor: no es que no los tuviera, es que se descartaban al
          // resolver.
          if (r.subtitles.isNotEmpty) {
            _subsWeb[indice] = r.subtitles;
            debugPrint(
              'TvPlayer: servidor $indice trae ${r.subtitles.length} '
              'pistas de subtitulos',
            );
          }
          debugPrint('TvPlayer: servidor $indice resuelto');
          return r.videoUrl;
        }
        debugPrint('TvPlayer: la pagina del servidor $indice no solto video');
      }
      DynamicScraperService().invalidateCache(pagina);
      _rotos.add(indice);
    } catch (e) {
      debugPrint('TvPlayer: no se pudo resolver el servidor $indice: $e');
      DynamicScraperService().invalidateCache(pagina);
      _rotos.add(indice);
    } finally {
      _resolviendo.remove(indice);
      await DynamicScraperService().stopCurrentScraping();
    }
    return null;
  }

  /// Cuantos reintentos automaticos se han gastado ya.
  int _reintentosAuto = 0;

  /// Solo uno. Con mas, un titulo que de verdad no existe tendria al usuario
  /// mirando un spinner que reintenta en bucle, que es peor que un mensaje
  /// claro.
  static const int _maxReintentosAuto = 1;

  Timer? _reintento;

  /// Se acabaron los servidores.
  ///
  /// ── PERO NO DEFINITIVAMENTE ────────────────────────────────────────────
  ///
  /// Antes esto pintaba el error y ahi se quedaba: para volver a intentarlo
  /// habia que salir de la pantalla y entrar de nuevo.
  ///
  /// Y la mayoria de los fallos de este proveedor son PASAJEROS —una respuesta
  /// cortada, el VPS con la cache fria, una extraccion que tardo de mas—. El
  /// segundo intento suele funcionar, y el usuario no tiene por que ser quien
  /// lo descubra.
  ///
  /// Se reintenta UNA vez, desde el primer servidor y olvidando los que se
  /// dieron por rotos: si el fallo fue pasajero, ya no lo son.
  ///
  /// NO se reintenta si el problema es de caudal: la conexion no va a mejorar
  /// en cuatro segundos, y repetir solo alarga la espera para acabar igual.
  void _rendirse() {
    _vigilante?.cancel();
    // Parar antes de cerrar: si no, MPV se queda reconectando contra la sesion
    // cerrada.
    //
    // CON SU `catch`: `stop()` lanza si el `Player` ya esta destruido —el
    // `[Player] has been disposed` que salia en el log— y aqui se llamaba sin
    // nadie que recogiera esa excepcion, asi que acababa como error sin
    // atender. Parar es una limpieza: si el reproductor ya no esta, el trabajo
    // ya esta hecho.
    unawaited(
      _player.stop().catchError((Object e) {
        debugPrint('TvPlayer: no se pudo parar (ya estaba fuera): $e');
      }),
    );
    _cerrarTurbo();

    if (!_faltaCaudal && _reintentosAuto < _maxReintentosAuto && !_muerto) {
      _reintentosAuto++;
      debugPrint('TvPlayer: reintento automatico $_reintentosAuto');
      _reintento?.cancel();
      _reintento = Timer(const Duration(seconds: 4), () async {
        if (_muerto || !mounted) return;
        _rotos.clear();
        _fallosSeguidos = 0;
        _idxServidor = 0;
        _cambiandoServidor = false;
        setState(() {
          _agotado = false;
          _primerFrameListo = false;
        });
        _armarVigilante();

        // CON SU `catch`, y no `unawaited` a secas.
        //
        // `_abrir` lanza cuando la pagina no da video, y aqui nadie mas lo
        // recoge: la excepcion se escaparia del temporizador y quedaria como
        // error sin atender, con la pantalla esperando un video que ya se sabe
        // que no viene. Recogiendola, el segundo fallo se enseña como lo que
        // es — esta vez ya sin mas reintentos, porque el cupo esta gastado.
        try {
          await _abrir(_posicion);
        } catch (e) {
          debugPrint('TvPlayer: el reintento automatico fallo: $e');
          if (!_muerto && mounted) _rendirse();
        }
      });
      return;
    }

    if (mounted) setState(() => _agotado = true);
  }

  /// Los subtitulos que trajo el extractor de cada servidor.
  final Map<int, List<ScrapedSubtitle>> _subsWeb = {};

  /// Registra en MPV los subtitulos que venian con la pagina.
  ///
  /// Va DESPUES de `open`: antes no hay medio al que engancharlos.
  Future<void> _cargarSubsWeb() async {
    final subs = _subsWeb[_idxServidor];
    if (subs == null || subs.isEmpty || _muerto) return;

    // `open()` vuelve antes de que MPV haya demuxado nada, y un `sub-add`
    // lanzado en ese hueco se pierde sin aviso. Se espera a que el medio tenga
    // duracion —o se agota un margen corto— antes de engancharlos.
    for (var i = 0; i < 20; i++) {
      if (_muerto) return;
      if (_player.state.duration > Duration.zero) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (_muerto) return;

    // 1. Se registran todas las pistas que trajo la pagina.
    for (final sub in subs) {
      if (_muerto) return;
      try {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(sub.url, title: sub.label, language: sub.language),
        );
      } catch (e) {
        // Una pista que no carga no puede tumbar la reproduccion.
        debugPrint('TvPlayer: no se pudo añadir el subtitulo ${sub.label}: $e');
      }
    }

    // 2. Y se ACTIVA una, releyendo la lista real de MPV — igual que el
    //    telefono. Anadir con `SubtitleTrack.uri` no deja siempre la pista
    //    seleccionada, y sin seleccion el `SubtitleView` no pinta nada: ese
    //    era el motivo de que el contenido de la BD con subtitulos siguiera
    //    saliendo sin ellos aunque ya se guardaran.
    if (_muerto) return;
    try {
      final pistas = _pistasSubs;
      if (pistas.isEmpty) return;
      final preferida = pistas.firstWhere((t) {
        final etiqueta = (t.title ?? t.language ?? '').toLowerCase();
        return etiqueta.contains('es') ||
            etiqueta.contains('spa') ||
            etiqueta.contains('lat') ||
            etiqueta.contains('web');
      }, orElse: () => pistas.first);
      await _player.setSubtitleTrack(preferida);
      debugPrint(
        'TvPlayer: subtitulo activado '
        '(${preferida.title ?? preferida.language ?? preferida.id})',
      );
    } catch (e) {
      debugPrint('TvPlayer: no se pudo activar el subtitulo: $e');
    }
  }

  /// Deja listos, en segundo plano, los servidores que necesitan extractor.
  /// ¿La reproduccion va lo bastante bien como para robarle recursos?
  ///
  /// Estricta a proposito: `_cortes` vacio significa que NO ha habido ni un
  /// tiron desde que se abrio este servidor. Con un solo corte ya no se
  /// adelanta nada — en un aparato justo, el que ha tenido un tiron tendra
  /// otro, y lo ultimo que necesita es un navegador arrancando al lado.
  bool get _reproduccionSana =>
      _reproduciendo &&
      _primerFrameListo &&
      !_buffering &&
      _cortes.isEmpty &&
      _segundosDesdeAbrir >= 25;

  Future<void> _prepararAlternativasEnSegundoPlano() async {
    // DE UNA EN UNA, no todas de golpe.
    //
    // Antes se lanzaban todas a la vez con `unawaited`: con tres servidores
    // eran tres Chromium simultaneos. Y entre una y otra se vuelve a mirar si
    // el video sigue fino, para parar en cuanto empiece a sufrir.
    for (var i = 0; i < _urls.length; i++) {
      if (_muerto) return;
      if (i == _idxServidor || _rotos.contains(i)) continue;
      if (!DynamicScraperService().isSupported(_urls[i])) continue;
      if (_resueltos.containsKey(i)) continue;
      if (!_reproduccionSana) return;
      await _resolverPagina(i);
    }
  }

  /// Busca alternativas en segundo plano cruzando con otros dominios y con el catálogo.
  Future<void> _buscarAlternativasDeOtrosProveedores() async {
    if (_muerto) return;
    try {
      final altsM3u = M3UService().getAlternativesFor(widget.item);
      for (final a in altsM3u) {
        if (!_urls.contains(a.url)) _urls.add(a.url);
      }

      final hostActual = Uri.tryParse(widget.item.url)?.host;
      final altsScraper = await DynamicScraperService().buscarAlternativasPorTitulo(
        widget.item.name,
        excluirHost: hostActual,
      );
      if (_muerto) return;
      for (final s in altsScraper) {
        if (!_urls.contains(s)) _urls.add(s);
      }

      if (_urls.length > 1 && mounted) {
        setState(() {});
        debugPrint(
          'TvPlayer: ${_urls.length} servidores disponibles tras búsqueda cruzada',
        );
        _prepararAlternativasEnSegundoPlano();
      }
    } catch (e) {
      debugPrint('TvPlayer: error buscando alternativas cruzadas: $e');
    }
  }


  /// La URL de video REAL de cada servidor que guarda una pagina en vez de un
  /// fichero (el contenido propio: cuevana, flixlat...).
  ///
  /// El telefono hace justo esto antes de reproducir; el televisor no lo hacia
  /// y por eso ese servidor "no funcionaba aqui y en el movil si". No es que
  /// el TV lo hiciera distinto: es que no lo hacia.
  final Map<int, String> _resueltos = {};

  /// Resoluciones en marcha, para no lanzar dos veces la misma pagina.
  final Set<int> _resolviendo = {};

  /// Servidores que ya se sabe que NO van a funcionar en esta reproduccion.
  ///
  /// Hay fallos que no son mala suerte ni lentitud: un 403, una cabecera que
  /// no se puede leer, un fichero cortado. Reintentar eso a los 9 segundos es
  /// perder 9 segundos con total seguridad. Se apunta y no se vuelve.
  final Set<int> _rotos = {};

  /// Cuantos servidores seguidos han fallado sin que ninguno arrancara.
  ///
  /// Cuando da la vuelta entera sin exito, se para: seguir girando entre dos
  /// servidores que no funcionan no es tolerancia a fallos, es un bucle. Y
  /// ademas cada vuelta creaba otra sesion de TurboProxy.
  int _fallosSeguidos = 0;

  /// Se acabaron los servidores. Se enseña y se deja de intentar.
  bool _agotado = false;

  /// Lo que dice MPV cuando el servidor no va a dar el video, pase lo que pase.
  static const List<String> _marcasFatales = [
    'HTTP error 403',
    'HTTP error 404',
    'HTTP error 401',
    'error reading header',
    'Failed to open',
    'partial file',
  ];

  void _cerrarTurbo() {
    final anterior = _urlTurbo;
    _urlTurbo = null;
    if (anterior != null) TurboProxy().cerrarSesion(anterior);
  }

  Future<void> _abrir(Duration desde) async {
    // Servidor nuevo, cuenta nueva: lo que tardara el anterior no puede
    // condenar a este.
    _segundosDesdeAbrir = 0;
    _segundosSinDatos = 0;
    _buferVigilado = Duration.zero;
    _bytesVigilados = TurboProxy.instance.currentBytesDownloaded;
    _arranco = false;
    // ── TRANSICIÓN SUAVE: spinner demorado ─────────────────────────────────
    //
    // NO se muestra el spinner de inmediato. El último frame del video se
    // mantiene visible en la Surface de Android mientras MPV está parado;
    // si el servidor nuevo carga en menos de 2 s, el usuario no ve spinner
    // — solo un instante de frame congelado, que es mucho menos molesto.
    //
    // El timer se cancela en cuanto llega el primer frame del servidor nuevo
    // (en el listener de `rect` o en el de `position`).
    final bool esCambioServidor = _posicion > Duration.zero || _idxServidor > 0;
    _spinnerDemorado?.cancel();
    if (esCambioServidor) {
      _spinnerVisible = false;
      _spinnerDemorado = Timer(const Duration(seconds: 2), () {
        if (mounted && !_primerFrameListo && _cargando) {
          setState(() => _spinnerVisible = true);
        }
      });
    } else {
      _spinnerVisible = _cargando;
    }
    _posReferencia = null;
    // Servidor nuevo, colchon nuevo: lo que no daba el anterior no condena a
    // este, y arrancar rapido vuelve a ser lo primero.
    _cortes.clear();
    _esperaBufer = _esperaBuferInicial;
    unawaited(_ponerEsperaBufer(_esperaBuferInicial));

    var original = _urls[_idxServidor];

    // ── SI ESTE SERVIDOR ES UNA PAGINA, SE RESUELVE ANTES ───────────────
    //
    // Es lo que hace el telefono y lo que aqui faltaba. Si ya venia resuelto
    // de la preparacion en segundo plano, esto no cuesta nada; si no, se
    // resuelve ahora y se espera, que sigue siendo mejor que abrir HTML con
    // MPV y ver como falla.
    if (DynamicScraperService().isSupported(original)) {
      final resuelto = await _resolverPagina(_idxServidor);
      // Aqui se ha ido el tiempo largo. Si ya no hay pantalla, se abandona en
      // silencio: no es un fallo del servidor, es que nadie esta mirando.
      if (_muerto) return;
      if (resuelto == null || resuelto.isEmpty) {
        throw StateError('la pagina del servidor $_idxServidor no dio video');
      }
      original = resuelto;
    }

    String url = original;

    // ── TurboProxy, igual que en el telefono ────────────────────────────
    //
    // El proveedor corta cada respuesta HTTP en ~104 KB: una pelicula de 2,3 GB
    // son mas de 22.000 reconexiones. Servidas de una en una se ven como
    // parones, el audio adelantandose y el video corriendo despues para
    // alcanzarlo — exactamente el sintoma que llevamos todo el dia persiguiendo.
    //
    // TurboProxy las pide en paralelo por rangos y se las entrega a MPV como un
    // flujo continuo. Corre DENTRO de esta app, asi que en el televisor
    // autonomo funciona igual que en el movil: no hace falta ningun telefono
    // encendido.
    //
    // Todo el camino es opcional: si el envoltorio falla o tarda mas de 7s se
    // usa la URL original y se reproduce como antes.
    // Las MISMAS cabeceras que el telefono. Iban vacias, y esa era la
    // diferencia entre arrancar en 10s y tardar 40 o 50: sin `X-Bump-Tier` la
    // peticion cae en el carril lento del VPS, y sin `User-Agent` hay
    // proveedores que estrangulan al cliente que no reconocen.
    final cabeceras = cabecerasParaStream(original);

    // LA SESION ANTERIOR SE CIERRA ANTES DE ABRIR OTRA.
    //
    // No se cerraba nunca, y el log lo cantaba: "9 sesiones, todas en uso —
    // no se expulsa ninguna", luego 10, luego 11. Cada cambio de servidor
    // dejaba una descarga zombi viva, peleando por el ancho de banda y por el
    // puerto del VPS contra la reproduccion de verdad. Con un servidor que no
    // arranca y otro roto, el bucle de failover fabricaba una fuga cada 9
    // segundos: cuanto mas lo intentaba, peor iba.
    // ── PRIMERO SE PARA MPV, DESPUES SE CIERRA LA SESION ────────────────
    //
    // El orden importa, y al reves hace daño de verdad. Cerrando la sesion
    // antes, la URL local `127.0.0.1/t/N` deja de existir mientras MPV SIGUE
    // enganchado a ella: se pasa los siguientes segundos —el envoltorio tarda
    // hasta 7s, y resolver una pagina bastante mas— reconectando contra un
    // endpoint muerto. Eso es lo que llenaba el log de
    //
    //   http: HTTP error 404 Not Found
    //   http: Stream ends prematurely at 14211
    //
    // y lo que ponia el aparato de rodillas justo al cambiar de servidor: no
    // era el cambio, era MPV martilleando una direccion que ya no existia
    // mientras el resto de la app intentaba trabajar.
    //
    // Parando MPV primero, ademas, se suelta enseguida la conexion del
    // proveedor — que con un tope de 4 por linea no es un detalle menor.
    try {
      await _player.stop();
    } catch (_) {
      // Si no se puede parar, seguir igualmente: `open()` lo reemplaza.
    }
    _cerrarTurbo();

    final bool esHls =
        esHlsPorUrl(original) ||
        DynamicScraperService().isSupported(widget.item.url);

    if (!esEnVivoPorUrl(original) && !esHls) {
      try {
        final local = await TurboProxy()
            .wrap(original, cabeceras)
            .timeout(const Duration(seconds: 7));
        if (local != null) {
          url = local;
          _urlTurbo = local;
          debugPrint('TvPlayer: enrutado por TurboProxy');
        }
      } catch (e) {
        debugPrint('TvPlayer: TurboProxy fallo ($e) — URL directa');
      }
    }

    // ── EL PERFIL SE AJUSTA AL TIPO DE FUENTE ──────────────────────────
    //
    // El perfil base es de VOD: 120s de cache y 90s de lectura adelantada,
    // pensados para un fichero entero servido por rangos. Contra una lista
    // HLS —que es lo que devuelve el extractor del contenido propio— eso es
    // contraproducente: solo hay unos pocos segmentos publicados, MPV choca
    // contra el final de la lista una y otra vez, y de ahi salen el
    // "End of file" repetido y los cortes cada pocos segundos.
    //
    // Son los mismos valores que ya usa el receptor para HLS, y todos BAJAN
    // respecto al perfil VOD, asi que no tocan el techo del VPS.
    if (_muerto) return;
    await _ajustarPerfilSegunFuente(url);

    // ── QUE EL EXTRACTOR SE HAYA IDO DEL TODO ─────────────────────────────
    //
    // Es lo que hace el telefono justo antes de abrir, y su comentario dice
    // que es el paso mas importante para que el bufer se comporte. Tiene
    // sentido: el WebView de extraccion es un Chromium entero: aunque se le
    // haya dicho que pare, tarda un momento en soltar memoria y CPU. Abrir
    // MPV en ese momento es hacerle competir con lo que se esta muriendo, y
    // en un aparato de 1 GB eso se nota en los primeros segundos de video.
    //
    // 300 ms de margen cuestan menos que un arranque a tirones.
    await DynamicScraperService().stopCurrentScraping();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    if (_muerto) return;
    await _player.open(
      Media(
        url,
        // Si TurboProxy no entro, MPV pide directo y necesita las cabeceras el
        // mismo. Con el envoltorio puesto no estorban: la URL ya es local.
        httpHeaders: cabeceras,
        // En HLS, pasar start a Media() cuelga el demuxer por 20s (network-timeout)
        // y dispara el watchdog de failover del TV (9s). Se abre en 0s y se salta en caliente.
        start: esHls ? null : (desde > Duration.zero ? desde : null),
      ),
    );

    // Y los subtitulos que vinieran con la pagina, ya con el medio abierto.
    await _cargarSubsWeb();

    if (esHls && desde > Duration.zero) {
      unawaited(() async {
        // Espera hasta 20 s (TVs lentas tardan mas de 6 s en arrancar).
        int waitCount = 0;
        while (waitCount < 200 && !_muerto && mounted) {
          final st = _player.state;
          final bool hasVideo = (st.width ?? 0) > 0 || _primerFrameListo;
          final bool hasPlayback =
              st.playing && st.position.inMilliseconds > 100;
          if (hasVideo && hasPlayback) break;
          await Future.delayed(const Duration(milliseconds: 100));
          waitCount++;
        }
        if (_muerto || !mounted) return;
        final pos = _player.state.position.inSeconds;
        if (pos < desde.inSeconds - 5) {
          debugPrint(
            'TvPlayer: aplicando seek rápido a ${desde.inSeconds}s tras inicio de stream HLS',
          );
          _posReferencia = desde;
          await _player.seek(desde);
          // Reintento si MPV no honró el seek (puede ocurrir con algunos HLS).
          await Future.delayed(const Duration(milliseconds: 1000));
          if (_muerto || !mounted) return;
          final posAfter = _player.state.position.inSeconds;
          if (posAfter < desde.inSeconds - 5) {
            debugPrint('TvPlayer: seek no llegó, reintentando');
            await _player.seek(desde);
          }
        }
      }());
    }
  }

  // ── Guardar por donde va ─────────────────────────────────────────────────
  void _armarGuardado() {
    _guardado?.cancel();
    _guardado = Timer.periodic(const Duration(seconds: 5), (_) => _guardar());
  }

  void _guardar() {
    if (_posicion.inSeconds < 10 || _duracion <= Duration.zero) return;
    unawaited(
      _progreso.saveProgress(
        widget.item.url,
        _posicion,
        _duracion,
        alternativeUrls: [for (final a in widget.item.alternatives) a.url],
        name: widget.item.name,
        seriesName: widget.item.seriesName,
        seasonNumber: widget.item.seasonNumber,
        episodeNumber: widget.item.episodeNumber,
      ),
    );
  }

  // ── Vigilante: cambiar de servidor cuando este va mal ────────────────────
  void _armarVigilante() {
    _vigilante?.cancel();
    // Se arma SIEMPRE, aunque no haya alternativa: `_siguienteServidor` ya
    // comprueba si hay adonde ir, y el contador de arranque sirve igual para
    // dejar constancia en el log de que ese servidor no dio un byte.

    _vigilante = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _cambiandoServidor) return;

      // Repintar SOLO cuando el spinner cambia de estado. Un `setState` por
      // segundo en un televisor de gama baja se nota.
      // Durante los primeros 2s de un cambio de servidor, el spinner se
      // gobierna por el timer demorado, no por el vigilante: sin esto el
      // vigilante lo enciende a la primera vuelta y el delay no sirve.
      if (_spinnerDemorado == null || !_spinnerDemorado!.isActive) {
        if (_cargando != _spinnerVisible) {
          setState(() => _spinnerVisible = _cargando);
        }
      }

      // En pausa no se vigila NADA: ni la posicion, ni los bytes, ni el
      // arranque. Se congela todo tal cual estaba para que al reanudar no
      // arrastre segundos que el servidor no debe.
      if (_pausadoAdrede) {
        _segundosSinAvance = 0;
        _segundosDesdeAbrir = 0;
        _posVigilada = _posicion;
        return;
      }

      // Corrupcion: la prueba mas directa, y la que el detector de posicion
      // no puede ver.
      final ahora = DateTime.now();
      _corrupcion.removeWhere(
        (t) => ahora.difference(t) > const Duration(seconds: 60),
      );
      if (_corrupcion.length >= _corrupcionParaCambiar) {
        _corrupcion.clear();
        unawaited(_siguienteServidor('datos corruptos'));
        return;
      }

      // ── Nada de esto cuenta mientras el video todavia ARRANCA ──────────
      //
      // Este vigilante mide "la posicion no se mueve". Pero durante la carga
      // inicial la posicion es 0 y no se mueve porque aun no hay imagen, no
      // porque el servidor falle.
      //
      // Sin esta guarda el resultado era demoledor: a los 9s saltaba, cambiaba
      // de servidor, volvia a empezar, y a los 9s otra vez. El contenido no
      // llegaba a cargar NUNCA y en pantalla se veia "Cambiando de servidor"
      // una y otra vez sobre un fondo negro. El arranque lento que se estaba
      // viendo no era lentitud: era este bucle.
      //
      // Mientras bufferea tampoco: bufferear es estar cargando, no estar
      // atascado. El caso de "no arranca" tiene su propio remedio — si el video
      // nunca empieza, no hay nada que vigilar aqui.
      // ── Todavia ARRANCANDO: el failover de 9s del telefono ─────────────
      //
      // Copiado de `video_player_screen`, donde ya esta probado. La clave es
      // COMO se decide que "arranco", porque las dos formas evidentes fallan:
      //
      //  - Mirar `posicion < 300ms` asume que se empieza en cero. Al reanudar,
      //    el video abre en el minuto 40 y la condicion no se cumple nunca.
      //  - Mirar `playing` tampoco vale: MPV se considera reproduciendo en
      //    cuanto se le dijo que reprodujera, aunque este llenando el bufer.
      //
      // Con las dos fallando, el failover no disparaba y se quedaba en Xtream
      // indefinidamente — exactamente el sintoma. Aqui la unica prueba que se
      // acepta es que la posicion AVANCE de verdad respecto a la PRIMERA
      // observada, sea cual sea. Asi reanudar a las dos horas funciona igual
      // que empezar de cero.
      if (!_arranco) {
        _segundosSinAvance = 0;
        _posVigilada = _posicion;
        _segundosDesdeAbrir++;

        _posReferencia ??= _posicion;
        if (_reproduciendo &&
            _posicion > _posReferencia! + const Duration(milliseconds: 500)) {
          _arranco = true;
          _primerFrameListo = true;
          _spinnerDemorado?.cancel();
          _spinnerVisible = false;
          // Este servidor SI va: la cuenta de fallos seguidos vuelve a cero.
          _fallosSeguidos = 0;
          // Y el veredicto de "no hay caudal" se anula: acaba de demostrarse
          // falso. Sin esto se quedaba puesto para siempre, y si mas tarde se
          // agotaban los servidores por OTRO motivo, la pantalla culpaba a la
          // conexion de algo que no habia hecho.
          _faltaCaudal = false;
          if (mounted) setState(() {});
          return;
        }

        // ── EL PLAZO CUENTA SIN DATOS, NO DESDE QUE SE ABRIO ────────────
        //
        // Antes bastaba con que pasaran 9 segundos: si el video no habia
        // empezado, fuera. Y eso mata reproducciones que van perfectamente,
        // solo que lentas.
        //
        // El caso del log: un `.mp4` de la BD por TurboProxy a 2,3 Mbps. Los
        // bytes ESTABAN llegando —"X-Cache HIT", "acelerando mid-stream"— pero
        // un MP4 necesita su cabecera entera antes del primer fotograma, y a
        // esa velocidad no da tiempo en 9 segundos. El vigilante lo mataba, se
        // cerraba TurboProxy a media descarga, y MPV se quedaba leyendo un
        // fichero truncado: de ahi los "STSZ atom truncated" y "error reading
        // header" que salen DESPUES en el log. No era el servidor fallando,
        // era la app cortandole.
        //
        // Sin servidor alternativo, ademas, eso es terminal: no carga nada.
        //
        // Ahora los 9 segundos cuentan SIN DATOS. Mientras entren bytes o el
        // bufer crezca, se le deja seguir, con un tope de 45 segundos para que
        // un servidor que manda basura sin arrancar tampoco se eternice.
        // ── SE LE PREGUNTA AL PROXY, NO A MPV ───────────────────────────
        //
        // Mirar solo `_kbps` y `_bufer` no valia, y el log lo dejo claro:
        // TurboProxy decia "acelerando mid-stream (1.7 Mbps)" y su offset
        // avanzaba hasta 119.917 bytes, pero el vigilante seguia contando
        // "sin datos" y mataba la reproduccion igual.
        //
        // El motivo es que las dos medidas de MPV se quedan a cero MIENTRAS
        // NO PUEDE LEER LA CABECERA: no hay cache que crecer ni caudal que
        // reportar hasta que el demuxer entiende el fichero. Justo el tramo
        // que hay que esperar.
        //
        // TurboProxy si sabe lo que esta bajando, porque es quien lo baja.
        // Sus bytes son la prueba de que el servidor responde.
        final bytes = TurboProxy.instance.currentBytesDownloaded;
        final hayDatos =
            bytes > _bytesVigilados ||
            _kbps > 0 ||
            _bufer > _buferVigilado ||
            _primerFrameListo ||
            (_player.state.width ?? 0) > 0 ||
            _posicion > Duration.zero ||
            _reproduciendo ||
            _player.state.playing;
        _bytesVigilados = bytes;
        _buferVigilado = _bufer;
        _segundosSinDatos = hayDatos ? 0 : _segundosSinDatos + 1;

        // ── ¿ES EL SERVIDOR, O ES LA CONEXION? ──────────────────────────
        //
        // Se parecen en pantalla —negro y a esperar— pero piden respuestas
        // opuestas: cambiar de servidor no arregla que el fichero pese mas de
        // lo que cabe por el cable.
        //
        // El caso del log: un MKV de mas de 5 GB, que pide 14 Mbps, servido a
        // 0,9. Bajaron 9 MB en 45 segundos y el video nunca arranco. No fallo
        // nadie: ese fichero no cabe por esa conexion. Lo unico que se sacaba
        // de esperar eran 45 segundos de pantalla negra y luego un mensaje
        // que culpaba al servidor.
        //
        // Con margen amplio —la mitad de lo pedido— para no rendirse con algo
        // que iba justo pero habria arrancado.
        final pedido = TurboProxy.instance.bitrateRequeridoActual;
        final caudal = TurboProxy.instance.mbps;
        if (!_faltaCaudal &&
            pedido != null &&
            pedido > 0 &&
            caudal > 0 &&
            _segundosDesdeAbrir >= _cuandoJuzgarCaudal &&
            caudal < pedido * 0.5) {
          _faltaCaudal = true;
          unawaited(
            _siguienteServidor(
              'la conexion da ${caudal.toStringAsFixed(1)} Mbps y el titulo '
              'pide ${pedido.toStringAsFixed(1)}',
            ),
          );
          return;
        }

        if (_segundosSinDatos >= _umbralArranque) {
          unawaited(_siguienteServidor('sin datos en ${_umbralArranque}s'));
        } else if (_segundosDesdeAbrir >= _umbralArranqueMaximo) {
          unawaited(
            _siguienteServidor('no arranco en ${_umbralArranqueMaximo}s'),
          );
        }
        return;
      }

      // Bufferear con imagen ya en pantalla es cargar, no estar atascado.
      if (_buffering) {
        _segundosSinAvance = 0;
        _posVigilada = _posicion;
        return;
      }

      // En pausa no se cuenta: parado a proposito no es parado por fallo.
      if (!_reproduciendo || _preparandoSalto) {
        _segundosSinAvance = 0;
        _posVigilada = _posicion;
        return;
      }

      if (_posicion == _posVigilada) {
        _segundosSinAvance++;
        if (_segundosSinAvance >= _umbralParado) {
          _segundosSinAvance = 0;
          unawaited(_siguienteServidor('sin avance en ${_umbralParado}s'));
        }
      } else {
        _segundosSinAvance = 0;
        _posVigilada = _posicion;
      }
    });
  }

  /// Cambia de servidor si el que suena trae tan poco caudal que los
  /// macrobloques son inevitables.
  ///
  /// ── POR QUE ESTO ES LO UNICO QUE FUNCIONA EN EL TELEVISOR ──────────────
  ///
  /// Los cuadritos son informacion que el codificador TIRO en origen. No se
  /// recuperan; como mucho se disimulan. En el telefono se disimulan con el
  /// shader de desbloqueo, pero en el televisor eso no se puede —esta medido:
  /// `mediacodec-copy` solo ya descarta fotogramas— y el desenfoque de capa
  /// tampoco cabe.
  ///
  /// Asi que en el televisor no queda mas que ATACAR LA CAUSA: si esta
  /// llegando una copia mala y hay otro servidor, se pide la otra. El dato
  /// que lo delata es "solo pasa con algunos titulos": si fuera el aparato,
  /// pasaria con todos.
  ///
  /// ── LAS CONDICIONES, Y POR QUE CADA UNA ────────────────────────────────
  void _revisarCaudal(double? bitsPorSegundo) {
    // En vivo no: no hay segunda oportunidad y un corte se lleva justo lo que
    // se estaba viendo. Ademas el caudal de un directo sube y baja solo.
    if (widget.item.isLive) return;

    // Nada de meterse si ya hay algo en marcha o ya no hay adonde ir.
    if (_muerto || _cambiandoServidor || _agotado) return;
    if (_urls.length <= 1) return;
    if (_saltosPorCaudal > 0) return;

    // Solo con el video ya asentado. Durante el arranque y los primeros
    // segundos la media del bitrate no vale para nada.
    if (!_primerFrameListo) return;
    if (_posicion.inSeconds < 12) return;

    // Y durante un salto de posicion, menos aun: al saltar se vacia el bufer
    // y la media del bitrate se hunde varios segundos sin que la fuente tenga
    // nada malo. Se reinicia la cuenta para no arrastrar una lectura falsa.
    if (_preparandoSalto) {
      _lecturasCaudalBajo = 0;
      return;
    }

    final bajo = TvMpvConfig.caudalInsuficiente(
      ancho: _player.state.width,
      alto: _player.state.height,
      bitsPorSegundo: bitsPorSegundo,
    );

    if (!bajo) {
      _lecturasCaudalBajo = 0;
      return;
    }

    // Dos lecturas seguidas (10 s) antes de molestar al usuario.
    _lecturasCaudalBajo++;
    if (_lecturasCaudalBajo < 2) return;

    _saltosPorCaudal++;
    final mbps = (bitsPorSegundo! / 1000000).toStringAsFixed(2);
    debugPrint(
      'TvPlayer: caudal bajo (${mbps}Mbps para '
      '${_player.state.width}x${_player.state.height}) — se prueba otro '
      'servidor a ver si trae una copia mejor',
    );
    unawaited(_siguienteServidor('caudal bajo: ${mbps}Mbps'));
  }

  Future<void> _siguienteServidor(String motivo) async {
    // Sin pantalla no hay nada que rescatar: cambiar de servidor aqui solo
    // abriria otro WebView para nadie.
    if (_muerto) return;
    if (_cambiandoServidor || _agotado) return;

    // Nunca cambiar servidor para contenidos de peelink o pelisflix.
    final urlBaja = widget.item.url.toLowerCase();
    if (urlBaja.contains('peelink') || urlBaja.contains('pelisflix')) {
      debugPrint('TvPlayer: contenido peelink/pelisflix — no se cambia de servidor ($motivo)');
      return;
    }

    // Si solo hay un servidor, no hay adonde saltar
    if (_urls.length <= 1) {
      debugPrint('TvPlayer: el único servidor disponible falló ($motivo)');
      _rendirse();
      return;
    }

    // ── ¿QUEDA ALGUN SERVIDOR AL QUE IR? ────────────────────────────────
    //
    // Se buscan los otros servidores disponibles (excluyendo el actual _idxServidor)
    final candidatos = [
      for (var i = 1; i < _urls.length; i++)
        if (!_rotos.contains((_idxServidor + i) % _urls.length))
          (_idxServidor + i) % _urls.length,
    ];
    if (candidatos.isEmpty || _fallosSeguidos >= _urls.length) {
      debugPrint(
        'TvPlayer: sin servidores utiles '
        '(${_rotos.length} rotos de ${_urls.length}) — se deja de intentar',
      );
      _rendirse();
      return;
    }

    // No cambiar a un servidor que trae otro idioma: si el actual es español
    // y el candidato esta marcado como ingles, se descarta.
    final actualEsEspanol = !widget.item.esAudioIngles;
    if (actualEsEspanol) {
      candidatos.removeWhere((i) {
        if (i >= _items.length) return false;
        return _items[i].esAudioIngles;
      });
      if (candidatos.isEmpty) {
        debugPrint('TvPlayer: todos los candidatos traen otro idioma — no se cambia');
        return;
      }
    }

    _fallosSeguidos++;
    _cambiandoServidor = true;
    // Servidor nuevo: vuelve a no haber imagen hasta que llegue la primera. Sin
    // esto, el vigilante seguiria contando desde el primer segundo del video
    // nuevo y encadenaria otro cambio.
    // NO se pone _spinnerVisible = true aquí. El timer demorado de _abrir()
    // se encarga: si el servidor nuevo carga rápido, no se ve spinner.
    if (mounted) setState(() => _primerFrameListo = false);
    _segundosDesdeAbrir = 0;
    _lecturasCaudalBajo = 0;
    _bloqueoInevitable = false;
    final desde = _posicion;
    _idxServidor = candidatos.first;
    debugPrint('TvPlayer: cambio de servidor ($motivo) -> $_idxServidor');

    // SIN AVISO EN PANTALLA.
    //
    // El cambio de servidor es cosa interna: al usuario le da igual de donde
    // salgan los bytes, y ver "Cambiando de servidor..." tres veces seguidas
    // solo transmite que algo va mal. Lo que si se ve es el spinner, que ya
    // dice lo unico importante — que todavia no hay imagen.
    //
    // Queda en el log, que es donde sirve.

    // Se guarda la pista de audio que sonaba ANTES de cambiar: el servidor
    // nuevo puede tener las pistas en distinto orden o con distintas
    // etiquetas, y sin esto MPV elige la primera que le cuadra con `alang`
    // — que puede ser otra.
    final pistaAntes = _player.state.track.audio;

    try {
      // Se retoma por donde iba, no desde cero: cambiar de servidor no puede
      // costarle al usuario volver a buscar su minuto.
      await _abrir(desde);
    } catch (e) {
      debugPrint('TvPlayer: el cambio de servidor fallo: $e');
    }

    // Se restaura la misma pista de audio por INDICE. El id cambia entre
    // servidores, pero la posicion (1.a, 2.a...) suele coincidir.
    if (pistaAntes.id != 'auto' && pistaAntes.id != 'no') {
      unawaited(
        Future<void>.delayed(const Duration(seconds: 2), () async {
          if (_muerto) return;
          final pistas = _pistasAudio;
          final idx = int.tryParse(pistaAntes.id);
          if (idx != null && idx > 0 && idx <= pistas.length) {
            final destino = pistas[idx - 1];
            if (_player.state.track.audio.id != destino.id) {
              await _player.setAudioTrack(destino);
              debugPrint(
                'TvPlayer: pista de audio restaurada -> ${destino.id}',
              );
            }
          }
        }),
      );
    }

    _segundosSinAvance = 0;
    _posVigilada = desde;
    _cambiandoServidor = false;
  }

  @override
  void dispose() {
    // LO PRIMERO: lo que siga corriendo por detras tiene que enterarse de que
    // ya no hay a quien servir, antes de que nada mas se destruya.
    _muerto = true;

    // Salir antes de que la prueba cuajara NO es un fallo del aparato: lo
    // normal es que el usuario se haya ido. Se cancela, y el veredicto se
    // queda sin decidir para la proxima. Sin esto, la marca de "probando"
    // sobrevive y al siguiente arranque se lee como un cuelgue.
    if (_nivel2EnUso) {
      _nivel2EnUso = false;
      unawaited(FiltroCalidadService().cancelarPruebaNivel2());
    }

    // ── LA EXTRACCION A MEDIAS SE CANCELA AQUI ───────────────────────────
    //
    // Sin esto, el WebView de una extraccion en curso sobrevivia a su
    // reproductor: seguia cargando la web entera del proveedor —fuentes,
    // JavaScript, analitica— para nadie.
    //
    // Y lo grave es lo que pasaba al encadenar: sales de una ficha y entras en
    // otra, la segunda abre SU WebView, y durante unos segundos hay DOS
    // Chromium cargando el mismo sitio a la vez. En un aparato de 1 GB eso
    // deja el hilo de la interfaz sin aire —"Skipped 733 frames" en el log— y
    // el mando deja de responder. Ese es el cuelgue de la navegacion.
    //
    // Solo si de verdad habia algo resolviendose: `stopCurrentScraping` sobre
    // una extraccion ajena mataria la del reproductor que si sigue vivo.
    if (_resolviendo.isNotEmpty) {
      unawaited(
        DynamicScraperService().stopCurrentScraping().catchError((Object e) {
          debugPrint('TvPlayer: no se pudo cortar la extraccion: $e');
        }),
      );
    }

    // Una extraccion a medias deja un WebView invisible corriendo: en un
    // televisor de 1 GB eso es memoria que no vuelve.
    _cerrarTurbo();
    for (final s in _subs) {
      s.cancel();
    }
    _ocultar?.cancel();
    _olvidarReanudado?.cancel();
    _diagnostico?.cancel();
    _prepararAlternativas?.cancel();
    _confirmarSalto?.cancel();
    _reintento?.cancel();
    _sondeoVelocidad?.cancel();
    _vigilante?.cancel();
    _spinnerDemorado?.cancel();
    _guardado?.cancel();
    // Un ultimo guardado al salir: sin el se pierden hasta 5 s, y salir es
    // justo cuando el usuario espera que quede anotado por donde iba.
    _guardar();
    if (_ticksBloqueoInevitable >= 4) {
      unawaited(FiltroCalidadService().anotarFuenteFloja(
        widget.item.url,
        titulo: widget.item.name,
      ));
      unawaited(M3UService().reportContent(
        name: widget.item.name,
        category: widget.item.category,
        url: widget.item.url,
        reason: 'fuente_floja_caudal_insuficiente',
      ));
    }
    _timerAviso?.cancel();
    _playerFocusNode.dispose();
    _player.dispose();
    super.dispose();
  }

  /// Los KB/s que MPV esta metiendo en su cache.
  ///
  /// Solo se repinta cuando se esta VIENDO —cargando o con los controles
  /// abiertos—: un setState por segundo para un texto invisible se nota en un
  /// Chromecast HD. Es el mismo criterio que el receptor.
  void _arrancarSondeoVelocidad() {
    _sondeoVelocidad = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      try {
        final mpv = _player.platform as dynamic;
        if (mpv == null) return;
        final raw = await mpv.getProperty('cache-speed');
        final kbps = (double.tryParse(raw?.toString() ?? '') ?? 0) / 1024;
        if (!mounted || kbps == _kbps) return;
        _kbps = kbps;
        if (_buffering || !_primerFrameListo || _controlesVisibles) {
          setState(() {});
        }
      } catch (_) {}
    });

    // ── DIAGNOSTICO: ¿falta red o no da el aparato? ──────────────────────
    //
    // Son dos averias distintas y desde fuera se ven parecidas: el video "va
    // mal". Sin estos numeros no hay forma de separarlas, y se acaba tocando
    // el bufer para arreglar un problema de decodificacion (o al reves).
    //
    // Como se leen las tres cifras, cada 5 segundos:
    //
    //  · bufer ~0s          -> FALTA RED. MPV se queda sin datos y para.
    //    Se ve como cortes: la imagen se congela y sigue.
    //
    //  · bufer alto Y drops -> NO DA EL APARATO. Hay datos de sobra pero los
    //    fotogramas se descartan sin llegar a pintarse. Se ve como tirones
    //    con el video corriendo: la imagen avanza a saltos.
    //
    //  · drops que suben sin parar con bufer sano, en un .mkv de este
    //    proveedor -> son los PTS rotos ("Input packet is missing PTS"): los
    //    paquetes llegan sin marca de tiempo y MPV no sabe cuando pintarlos.
    //    Ni es la red ni es el aparato; es el archivo.
    _diagnostico = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || !_arranco) return;
      try {
        final mpv = _player.platform as dynamic;
        if (mpv == null) return;
        final descartados = await mpv.getProperty('frame-drop-count');
        final descartadosDec = await mpv.getProperty(
          'decoder-frame-drop-count',
        );
        final segundosBufer = _bufer - _posicion;

        // ── EL BITRATE DEL VIDEO, QUE ES LO QUE DECIDE SI HAY CUADROS ────
        //
        // "Solo pasa con algunos titulos" es el dato que cambia el
        // diagnostico: si fuera el aparato pasaria con TODOS. Que pase solo
        // con algunos significa que esas fuentes concretas vienen peor, y
        // para saber cuanto peor hace falta el numero.
        //
        // La referencia, para leerlo: un 720p decente va sobre los 3-5 Mbps.
        // Por debajo de ~1,5 Mbps los macrobloques son inevitables y no hay
        // reproductor que los quite — lo que falta es informacion que el
        // codificador tiro en origen.
        //
        // `video-bitrate` es el del flujo que se esta pintando AHORA, asi que
        // en HLS refleja la variante elegida de verdad, no la que anuncia la
        // lista.
        final bitrate = await mpv.getProperty('video-bitrate');
        final mbps = double.tryParse('${bitrate ?? ''}');

        // Si el caudal no alcanza para evitar macrobloqueos inevitables,
        // el desenfoque de capa solo consume fotogramas sin solucionar el
        // defecto de compresión de origen. Se apaga condicionalmente en ese caso.
        final insuficiente = TvMpvConfig.caudalInsuficiente(
          ancho: _player.state.width,
          alto: _player.state.height,
          bitsPorSegundo: mbps,
        );
        if (insuficiente != _bloqueoInevitable && mounted) {
          setState(() => _bloqueoInevitable = insuficiente);
        }

        if (_bloqueoInevitable && _urls.length <= 1) {
          _ticksBloqueoInevitable++;
          if (_ticksBloqueoInevitable >= 3 &&
              !_avisoCalidadBaja &&
              !_avisoCalidadYaMostrado &&
              mounted) {
            _avisoCalidadYaMostrado = true;
            _contadorAviso = 5;
            setState(() => _avisoCalidadBaja = true);
            _timerAviso?.cancel();
            _timerAviso = Timer.periodic(const Duration(seconds: 1), (t) {
              if (!mounted) { t.cancel(); return; }
              _contadorAviso--;
              if (_contadorAviso <= 0) {
                t.cancel();
                setState(() => _avisoCalidadBaja = false);
              } else {
                setState(() {});
              }
            });
          }
        } else {
          _ticksBloqueoInevitable = 0;
        }

        debugPrint(
          'TvPlayer diag: bufer=${segundosBufer.inSeconds}s '
          '${_kbps.toStringAsFixed(0)}KB/s '
          'descartados(vo)=${descartados ?? "?"} '
          'descartados(dec)=${descartadosDec ?? "?"} '
          'colchon=${_esperaBufer}s '
          'video=${mbps == null ? "?" : "${(mbps / 1000000).toStringAsFixed(2)}Mbps"}'
          '${_bloqueoInevitable ? " [bloqueo inevitable -> blur 0.0]" : ""}',
        );

        _revisarCaudal(mbps);
      } catch (_) {}
    });
  }

  // ── Controles ────────────────────────────────────────────────────────────
  void _mostrarControles() {
    _ocultar?.cancel();
    if (!_controlesVisibles && mounted) {
      setState(() => _controlesVisibles = true);
    }
    _ocultar = Timer(const Duration(seconds: 5), () {
      if (mounted && !_menuAbierto && !_ajustesAbierto) {
        setState(() => _controlesVisibles = false);
      }
    });
  }

  void _alternarReproduccion() {
    if (_reproduciendo) {
      _pausadoAdrede = true;
      _player.pause();
    } else {
      _pausadoAdrede = false;
      // Al reanudar, los contadores empiezan de cero: los segundos que estuvo
      // en pausa no son culpa del servidor.
      _segundosSinAvance = 0;
      _segundosDesdeAbrir = 0;
      _posVigilada = _posicion;
      _player.play();
    }
  }

  /// Cuantos saltos seguidos se llevan sin aplicar. Manda el tamaño del paso.
  int _saltosSeguidos = 0;

  /// El paso crece si se sigue saltando: 10 s, 30 s, 60 s y 120 s.
  ///
  /// Es lo que hace que llegar al minuto 40 sea cuestion de mantener la flecha
  /// un par de segundos en vez de dar cien toques. El primer toque sigue
  /// siendo de 10 s para que un ajuste fino —te perdiste una frase— siga
  /// siendo posible.
  int get _paso {
    if (_saltosSeguidos < 4) return 10;
    if (_saltosSeguidos < 10) return 30;
    if (_saltosSeguidos < 20) return 60;
    return 120;
  }

  /// Cuando se atendio el ultimo salto. Ver `_saltar`.
  DateTime? _ultimoSalto;

  /// Ritmo maximo al mantener la flecha.
  ///
  /// `KeyRepeatEvent` llega CADA 40-50 ms. Sin frenarlo, un segundo de flecha
  /// mantenida eran ~20 saltos, y para entonces la carrerilla ya iba por 120 s
  /// cada uno: unos QUINCE MINUTOS de pelicula en un segundo de pulsacion.
  /// Imposible de apuntar, y de ahi que recorrer la pelicula no funcionara.
  ///
  /// A 150 ms salen 6-7 pasos por segundo, que es un ritmo que la vista sigue
  /// — y ademas hace que la carrerilla se mida en tiempo real: 10 s por paso
  /// el primer medio segundo, 30 s hasta el segundo y medio, 60 s hasta los
  /// tres, y 120 s de ahi en adelante.
  static const Duration _ritmoSalto = Duration(milliseconds: 150);

  /// `direccion` es -1 o 1; el tamaño del paso lo decide la carrerilla.
  void _saltar(int direccion) {
    final ahora = DateTime.now();
    final previo = _ultimoSalto;
    if (previo != null && ahora.difference(previo) < _ritmoSalto) return;
    _ultimoSalto = ahora;

    _saltosSeguidos++;
    final segundos = direccion.sign * _paso;
    final base = _preparandoSalto ? _saltoPrevisto : _posicion;
    var destino = base + Duration(seconds: segundos);
    if (destino < Duration.zero) destino = Duration.zero;
    if (_duracion > Duration.zero && destino > _duracion) destino = _duracion;

    setState(() {
      _preparandoSalto = true;
      _saltoPrevisto = destino;
      _posicion = destino;
    });

    // Se aplica 500 ms despues de la ULTIMA pulsacion, no en cada una: saltar
    // por cada tecla vacia el bufer una vez por pulsacion y recorrer un minuto
    // a base de toques dejaba el video inservible. Con la flecha mantenida,
    // ademas, 500 da margen a soltar antes de que se ejecute.
    _confirmarSalto?.cancel();
    _confirmarSalto = Timer(const Duration(milliseconds: 500), _aplicarSalto);
  }

  void _aplicarSalto() {
    if (!_preparandoSalto) return;
    _confirmarSalto?.cancel();
    _confirmarSalto = null;
    _saltosSeguidos = 0; // la carrerilla se pierde al soltar
    _ultimoSalto = null;
    final destino = _saltoPrevisto;
    _player.seek(destino);
    setState(() {
      _posicion = destino;
      _preparandoSalto = false;
    });
  }

  // ── Pistas ───────────────────────────────────────────────────────────────
  List<AudioTrack> get _pistasAudio =>
      _player.state.tracks.audio
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();

  List<SubtitleTrack> get _pistasSubs =>
      _player.state.tracks.subtitle
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();

  int get _menuLargo =>
      _menuTab == 0 ? _pistasAudio.length : _pistasSubs.length + 1;

  int _indiceActual(int pestana) {
    try {
      if (pestana == 0) {
        final id = _player.state.track.audio.id;
        final i = _pistasAudio.indexWhere((t) => t.id == id);
        return i < 0 ? 0 : i;
      }
      final id = _player.state.track.subtitle.id;
      if (id == 'no' || id == 'auto') return 0;
      final i = _pistasSubs.indexWhere((t) => t.id == id);
      return i < 0 ? 0 : i + 1;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _alternarFavorito() async {
    try {
      await M3UService().toggleFavorite(widget.item);
      if (mounted) setState(() => _esFavorito = widget.item.isFavorite);
    } catch (e) {
      _aviso(e.toString().replaceAll('Exception: ', ''), error: true);
    }
  }

  void _abrirReporte() {
    setState(() {
      _motivos = motivosReporte(
        widget.item,
        tieneEpisodios: widget.item.episodes.isNotEmpty,
      );
      _reporteIdx = 0;
      _reporteAbierto = true;
    });
  }

  /// Envia el reporte elegido. La MISMA llamada que la ficha del telefono, asi
  /// que llega a la misma tabla (`content_reports`).
  Future<void> _enviarReporte(String motivo) async {
    setState(() {
      _reporteAbierto = false;
      _reportando = true;
    });
    var ok = false;
    try {
      ok = await M3UService().reportContent(
        name: widget.item.name,
        category: widget.item.category,
        url: widget.item.url,
        reason: motivo,
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() => _reportando = false);
    _aviso(
      ok
          ? 'Reporte enviado. ¡Gracias!'
          : 'No se pudo enviar el reporte. Inténtalo de nuevo.',
      error: !ok,
    );
  }

  void _aviso(String texto, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          texto,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        backgroundColor:
            error ? const Color(0xFFE53935) : const Color(0xFF2E7D32),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _abrirMenu(int pestana) {
    _ocultar?.cancel();
    setState(() {
      _menuAbierto = true;
      _menuTab = pestana;
      _menuIdx = _indiceActual(pestana);
    });
  }

  Future<void> _aplicarPista() async {
    try {
      if (_menuTab == 0) {
        final l = _pistasAudio;
        if (_menuIdx >= 0 && _menuIdx < l.length) {
          if (_player.state.track.audio.id == l[_menuIdx].id) return;
          await _player.setAudioTrack(l[_menuIdx]);
        }
      } else {
        if (_menuIdx == 0) {
          final actual = _player.state.track.subtitle.id;
          if (actual == 'no' || actual == 'auto') return;
          await _player.setSubtitleTrack(SubtitleTrack.no());
        } else {
          final l = _pistasSubs;
          final i = _menuIdx - 1;
          if (i >= 0 && i < l.length) {
            if (_player.state.track.subtitle.id == l[i].id) return;
            await _player.setSubtitleTrack(l[i]);
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  String _etiqueta(String? titulo, String? idioma, String id) {
    final partes = [
      if (titulo != null && titulo.trim().isNotEmpty) titulo.trim(),
      if (idioma != null && idioma.trim().isNotEmpty) idioma.trim(),
    ];
    return partes.isEmpty ? 'Pista $id' : partes.join(' · ');
  }

  // ── Mando ────────────────────────────────────────────────────────────────

  /// Si ya se pidio cerrar esta pantalla.
  bool _cerrando = false;

  /// Cierra el reproductor UNA SOLA VEZ, venga el "atras" por donde venga.
  ///
  /// ── POR QUE HACE FALTA UN CERROJO ──────────────────────────────────────
  ///
  /// El "atras" llega por DOS caminos: la tecla `goBack` que recoge `_tecla`, y
  /// el "atras" del sistema que recoge el `PopScope`. En el Chromecast llega
  /// solo uno; el mando de un Xiaomi manda LOS DOS con una sola pulsacion, y
  /// entonces se hacian dos `pop`: se cerraba el reproductor Y la ficha de
  /// detras, apareciendo el catalogo. Se veia como "en este televisor el atras
  /// se salta la ficha", que no apunta a ningun sitio.
  ///
  /// Con el cerrojo, la segunda llamada no hace nada. No hay que reponerlo: la
  /// pantalla se esta yendo.
  void _cerrarUnaVez() {
    if (_cerrando || !mounted) return;
    _cerrando = true;
    // Queda anotado en el filtro compartido: el aviso gemelo que llegue
    // despues —ya con esta pantalla cerrada— lo descarta la ficha de debajo.
    AtrasTv.esEco();
    Navigator.of(context).pop();
  }

  bool _manejarAtras() {
    if (_reporteAbierto) {
      // Al volver de los motivos se vuelve a los ajustes, que es de donde se
      // entro: salir del todo obligaria a rehacer el camino.
      setState(() {
        _reporteAbierto = false;
        _ajustesAbierto = true;
      });
      _mostrarControles();
      return true;
    }
    if (_ajustesAbierto) {
      setState(() => _ajustesAbierto = false);
      _mostrarControles();
      return true;
    }
    if (_menuAbierto) {
      setState(() => _menuAbierto = false);
      _mostrarControles();
      return true;
    }
    if (_controlesVisibles) {
      setState(() => _controlesVisibles = false);
      return true;
    }
    // ATRAS SALE A LA PRIMERA.
    //
    // Antes pedia dos pulsaciones, para que un roce no te sacara de la
    // pelicula. Pero con el mando en la mano no hay roces —hay que apuntar y
    // pulsar—, asi que la proteccion no protegia de nada y si obligaba a
    // pulsar dos veces cada vez que querias salir. Y donde se vuelve es al
    // catalogo, con la posicion guardada: salir no cuesta nada.
    return false;
  }

  KeyEventResult _tecla(FocusNode node, KeyEvent evento) {
    final k = evento.logicalKey;

    // ── MANTENER LA FLECHA ADELANTA ────────────────────────────────────
    //
    // Solo se atendia `KeyDownEvent`, o sea la pulsacion suelta: cada toque
    // eran 10 segundos y adelantar veinte minutos salian 120 toques. Por eso
    // moverse por la pelicula era una tortura.
    //
    // `KeyRepeatEvent` es lo que llega al DEJAR la flecha apretada. Se atiende
    // solo para las flechas de la linea de tiempo: repetir "OK" o "atras"
    // mantenidos no significa nada bueno.
    final esFlecha =
        k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight;
    if (evento is KeyRepeatEvent && esFlecha && !_menuAbierto) {
      if (_foco == 0 || _foco == 1) {
        // Los controles siguen a la vista mientras se recorre. Sin esto, el
        // temporizador de 5s no se refrescaba y la linea de tiempo
        // desaparecia justo mientras la estabas usando.
        _mostrarControles();
        _saltar(k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
        return KeyEventResult.handled;
      }
    }
    if (evento is! KeyDownEvent) return KeyEventResult.ignored;

    final ok =
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA;

    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      if (_manejarAtras()) return KeyEventResult.handled;
      _cerrarUnaVez();
      return KeyEventResult.handled;
    }

    // ── Opciones de información del título ────────────────────────────────
    //
    // Se despliegan al navegar o pulsar hacia abajo.
    // Al pulsar hacia arriba ("cuando suba"), se vuelve a los controles normales.
    // Las opciones se recorren con izquierda y derecha.
    if (_ajustesAbierto) {
      _mostrarControles();
      if (k == LogicalKeyboardKey.arrowLeft) {
        if (_ajustesIdx > 0) {
          setState(() => _ajustesIdx--);
        }
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        if (_ajustesIdx < 3) {
          setState(() => _ajustesIdx++);
        }
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _ajustesAbierto = false;
          _foco = 4;
        });
        _mostrarControles();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        return KeyEventResult.handled;
      }
      if (ok) {
        switch (_ajustesIdx) {
          case 0:
            unawaited(_alternarFavorito());
          case 1:
            setState(() {
              _meGusta = !_meGusta;
              // Una cosa o la otra, nunca las dos.
              if (_meGusta) _noMeGusta = false;
            });
          case 2:
            setState(() {
              _noMeGusta = !_noMeGusta;
              if (_noMeGusta) _meGusta = false;
            });
          case 3:
            setState(() => _ajustesAbierto = false);
            if (!_reportando) _abrirReporte();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Motivos del reporte ───────────────────────────────────────────────
    if (_reporteAbierto) {
      if (k == LogicalKeyboardKey.arrowUp) {
        setState(
          () => _reporteIdx = (_reporteIdx - 1).clamp(0, _motivos.length - 1),
        );
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        setState(
          () => _reporteIdx = (_reporteIdx + 1).clamp(0, _motivos.length - 1),
        );
        return KeyEventResult.handled;
      }
      if (ok) {
        unawaited(_enviarReporte(_motivos[_reporteIdx]));
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Selector de pistas ────────────────────────────────────────────────
    if (_menuAbierto) {
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight) {
        setState(() {
          _menuTab = _menuTab == 0 ? 1 : 0;
          _menuIdx = _indiceActual(_menuTab);
        });
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        if (_menuIdx > 0) setState(() => _menuIdx--);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        if (_menuIdx < _menuLargo - 1) setState(() => _menuIdx++);
        return KeyEventResult.handled;
      }
      if (ok) {
        unawaited(_aplicarPista());
        setState(() {
          _menuAbierto = false;
          _foco = 0; // elegida la pista, lo siguiente es seguir viendo
        });
        _mostrarControles();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Teclas multimedia dedicadas de reproducción y salto ─────────────
    if (k == LogicalKeyboardKey.mediaPlayPause) {
      _alternarReproduccion();
      _mostrarControles();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlay) {
      if (!_reproduciendo) _alternarReproduccion();
      _mostrarControles();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPause ||
        k == LogicalKeyboardKey.mediaStop) {
      if (_reproduciendo) _alternarReproduccion();
      _mostrarControles();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward ||
        k == LogicalKeyboardKey.mediaTrackNext) {
      _saltar(1);
      _mostrarControles();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind ||
        k == LogicalKeyboardKey.mediaTrackPrevious) {
      _saltar(-1);
      _mostrarControles();
      return KeyEventResult.handled;
    }

    // Si los controles estaban ocultos:
    // - OK pausa / reproduce inmediatamente sin requerir una segunda pulsación.
    // - Flechas Izquierda / Derecha saltan inmediatamente 10 s y muestran controles.
    final estaban = _controlesVisibles;
    _mostrarControles();
    if (!estaban) {
      if (ok) {
        _alternarReproduccion();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowLeft) {
        _saltar(-1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        _saltar(1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Línea de tiempo ───────────────────────────────────────────────────
    if (_foco == 1) {
      if (k == LogicalKeyboardKey.arrowLeft) {
        _saltar(-1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        _saltar(1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        _aplicarSalto();
        setState(() => _foco = 0);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        _aplicarSalto();
        setState(() => _foco = 2);
        return KeyEventResult.handled;
      }
      if (ok) {
        if (_preparandoSalto) {
          _aplicarSalto();
        } else {
          _alternarReproduccion();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── La fila de iconos ─────────────────────────────────────────────────
    //
    // 2 subtitulos · 3 audio · 4 info. Izquierda y derecha la recorren sin
    // dar la vuelta: al llegar al filo no pasa nada, que es lo que uno espera
    // de una fila.
    if (_foco >= 2 && _foco <= 4) {
      if (k == LogicalKeyboardKey.arrowLeft) {
        if (_foco > 2) setState(() => _foco--);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        if (_foco < 4) setState(() => _foco++);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        setState(() => _foco = 1);
        return KeyEventResult.handled;
      }
      // Al pulsar hacia abajo desde la fila de controles, se despliegan
      // directamente las opciones disponibles (Mi lista, Me gusta, No me gusta, Reportar).
      if (k == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _ajustesIdx = 0;
          _ajustesAbierto = true;
        });
        return KeyEventResult.handled;
      }
      if (ok) {
        switch (_foco) {
          case 2:
            _abrirMenu(1);
          case 3:
            _abrirMenu(0);
          case 4:
            setState(() {
              _ajustesIdx = 0;
              _ajustesAbierto = true;
            });
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Botón de play ─────────────────────────────────────────────────────
    if (k == LogicalKeyboardKey.arrowLeft) {
      _saltar(-1);
      setState(() => _foco = 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _saltar(1);
      setState(() => _foco = 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _foco = 1);
      return KeyEventResult.handled;
    }
    if (ok) {
      _alternarReproduccion();
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progreso =
        _duracion.inMilliseconds <= 0
            ? 0.0
            : (_posicion.inMilliseconds / _duracion.inMilliseconds).clamp(
              0.0,
              1.0,
            );

    // Asegurar que el foco esté en NUESTRO nodo, no en el del widget Video
    // de media_kit. Sin esto el Video reclama el foco, nuestro onKeyEvent
    // deja de recibir las teclas, y el framework las propaga a la ruta de
    // debajo (TvDetailScreen) — que actúa sobre ellas y navega a otro
    // contenido o hace cosas del detalle mientras se ve el reproductor.
    // En el `Overlay` NO se reclama el foco. Mientras la vista previa está
    // pequeña, el foco pertenece a la ficha —es ella quien navega— y robárselo
    // dejaría al usuario sin poder moverse por la pantalla que está viendo.
    // Estando en grande, las teclas se las pasa a mano quien lo montó.
    if (!_enOverlay &&
        !_playerFocusNode.hasFocus &&
        !_playerFocusNode.hasPrimaryFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playerFocusNode.requestFocus();
      });
    }

    // Al vivir en el `Overlay`, este widget no se reconstruye al navegar: hay
    // que escuchar el cambio de tamaño para que los controles aparezcan y
    // desaparezcan.
    if (_enOverlay) {
      return ValueListenableBuilder<bool>(
        valueListenable: widget.expandido!,
        builder: (_, _, _) => _cuerpo(progreso),
      );
    }

    final cuerpo = _cuerpo(progreso);

    // En el `Overlay` se devuelve el cuerpo pelado: ni `PopScope` (no hay
    // `ModalRoute` a la que engancharse) ni `Focus` propio (lo tiene la ficha).
    if (_enOverlay) return cuerpo;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (hecho, _) {
        if (hecho) return;
        if (!_manejarAtras()) _cerrarUnaVez();
      },
      child: FocusScope(
        autofocus: true,
        child: Focus(
          focusNode: _playerFocusNode,
          autofocus: true,
          onKeyEvent: _tecla,
          child: cuerpo,
        ),
      ),
    );
  }

  Widget _cuerpo(double progreso) {
    return LayoutBuilder(
      builder: (context, restricciones) {
        // ── NO BASTA CON QUE ESTE "EN GRANDE" ─────────────────────────────
        //
        // Al pulsar, `expandido` se pone a `true` de inmediato pero el
        // rectangulo tarda 260 ms en llegar a la pantalla entera. En ese rato
        // los controles ya se estan pintando dentro de una caja de 360 px:
        // la barra del titulo no cabe y desborda 53 px, que es el aviso del
        // log.
        //
        // Midiendo el ancho de verdad, los controles esperan a que haya sitio.
        // Aparecen al terminar la transicion, que ademas es donde tienen
        // sentido.
        final grande = _grande && restricciones.maxWidth > 700;
        return _pantalla(progreso, grande);
      },
    );
  }

  Widget _pantalla(double progreso, bool grande) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            // Igual que en el telefono: el realce va por fuera del `Video`
            // porque es una capa del motor, no un shader de MPV. Se queda
            // dormido con cualquier fuente que pase de 720p.
            child: RealceDeVideo(
              // SUAVIZADO DE CAPA: SOLO AQUI, SOLO EN EL TELEVISOR.
              //
              // El telefono no lo lleva y no debe llevarlo: alli el shader de
              // desbloqueo hace este trabajo CON CRITERIO —solo en la rejilla
              // de macrobloques y solo donde no hay textura— y añadirle
              // encima un desenfoque ciego seria devolverle el velo que
              // costo cinco rondas quitar.
              //
              // Aqui es distinto porque aqui no hay shader: el diagnostico
              // midio `hwdec-current = mediacodec` (el fotograma no pasa por
              // MPV) y `hls-bitrate = max` (la palanca del bitrate ya esta
              // abierta del todo). No queda nada mas barato que probar.
              //
              // ── DE DONDE SALE EL 0,5 ───────────────────────────────
              //
              // Un gaussiano no sabe que esta borrando, pero SI ataca mas a
              // lo estrecho que a lo ancho. Midiendo cuanto sobrevive a cada
              // radio (escalon de bloque de 6 niveles, detalle fino de 2 px):
              //
              //   sigma | escalon de bloque | detalle conservado
              //    0,45 |    2,2 niveles    |   78%
              //    0,50 |    1,7 niveles    |   73%
              //    0,55 |    1,3 niveles    |   69%
              //    0,60 |    1,0 niveles    |   64%
              //    0,65 |    0,8 niveles    |   59%   <- aqui
              //    0,70 |    0,5 niveles    |   55%   <- probado y RECHAZADO
              //
              // 0,65 es medio escalon del 0,70 que se rechazo, y ya no queda
              // sitio: el bloque esta en 0,8 niveles —la mitad del umbral de
              // visibilidad— asi que subir mas no puede quitar bloque que ya
              // no se ve, solo detalle. Si aun se notan cuadros a partir de
              // aqui, NO son los macrobloques que este filtro ataca.
              //
              // El 0,70 se probo y la respuesta fue "se ve de menos calidad":
              // ahi ya se tira casi la mitad del detalle. 0,60 es el ultimo
              // escalon antes de ese, asi que si este tambien se ve pobre, el
              // margen se acabo y hay que aceptar que un filtro CIEGO no
              // puede quitar mas bloque sin cobrarlo en detalle.
              //
              // En una zona lisa el ojo empieza a ver un escalon sobre los
              // 2 niveles de 255. A 0,50 el bloque cae a 1,7 —justo por
              // debajo de verse— y todavia se conserva casi tres cuartas
              // partes del detalle. A 0,70 el bloque estaba requetemuerto
              // pero se tiraba casi la mitad del detalle, y eso es lo que se
              // vio como "menos calidad".
              //
              // OJO CON LA TENTACION DE COMPENSARLO CON CONTRASTE: no sirve.
              // El contraste multiplica todo por igual, incluido el escalon
              // que el desenfoque acaba de rebajar. Subir contraste tras
              // desenfocar es, matematicamente, lo mismo que haber
              // desenfocado menos. El unico mando de verdad es este.
              // 0 MIENTRAS DURE LA PRUEBA DEL SHADER.
              //
              // Este desenfoque de capa existe porque en el televisor no
              // habia shader. Si ahora lo hay, dejar los dos puestos seria
              // suavizar dos veces —y medir dos cosas a la vez, que es como
              // se pierden cinco rondas—. El shader filtra con criterio y
              // este no, asi que si el shader entra, este sobra.
              //
              // Si la prueba sale mal y se vuelve a `_nivel2PermitidoEnTv =
              // false`, hay que devolver esto a 0.5 (ver la tabla de radios
              // que hay en el historial: 0,50 deja el bloque en 1,7 niveles
              // —por debajo de verse— conservando el 73% del detalle).
              // 0,45: EL ESCALON MAS BAJO DE LA TABLA, y a proposito.
              //
              // El recorrido fue 0,5 -> 0,6 -> 0,65 subiendo, y luego a 0 para
              // ver la imagen desnuda. Sin nada se veia MEJOR que con 0,65, y
              // eso ordena la escala: el desenfoque estaba cobrando mas de lo
              // que devolvia. Asi que al volver a poner algo, se entra por
              // abajo y no por el medio.
              //
              // A 0,45 se conserva el 78% del detalle fino (contra el 59% que
              // dejaba 0,65) y el escalon de bloque queda en 2,2 niveles, justo
              // en el umbral de lo visible: rebaja los cuadros sin llegar a
              // borrarlos. Ese es el compromiso que se pidio.
              //
              // ── LA ESCALA EN PORCENTAJE ──────────────────────────
              //
              // El radio en pixeles no dice nada a simple vista, asi que va
              // aqui la equivalencia. El % se lee como CUANTO DETALLE FINO SE
              // CEDE, que es lo que de verdad se paga:
              //
              //     %  | sigma | bloque que queda
              //     1% | 0,09  | 5,8 niveles
              //     5% | 0,20  | 4,9 niveles
              //    10% | 0,29  | 3,9 niveles
              //    20% | 0,43  | 2,5 niveles   <- AQUI
              //    30% | 0,54  | 1,4 niveles
              //    45% | 0,70  | 0,6 niveles   <- probado, se veia peor que 0
              //
              // El umbral de lo visible en zona lisa esta sobre los 2
              // niveles. Al 10% el bloque queda en 3,9 —o sea que SE VE, no
              // se ha borrado— a cambio de conservar el 90% del detalle.
              //
              // Esa es la eleccion, y conviene tenerla clara: a partir de
              // aqui hacia abajo el filtro casi no quita cuadros, solo deja
              // de restar nitidez. El recorrido ha sido
              // 0,5 -> 0,6 -> 0,65 -> 0 -> 0,45 -> 0,50 -> 0,25 -> 0,43 ->
              // 0,29, y cada vez que se ha subido por encima del 20% la
              // respuesta ha sido que se veia peor.
              //
              // OJO POR ABAJO: el desenfoque cuesta una capa intermedia y una
              // pasada a pantalla completa en CADA fotograma, y ese coste no
              // baja con el radio. Por debajo del 2% se paga entero a cambio
              // de algo que no se ve — ahi es mejor 0,0, que se salta la capa
              // y sale gratis.
              // ── APAGADO: MEDIDO, NO CABE ─────────────────────────
              //
              // El 2026-09-22, con el suavizado al 10% (el valor mas bajo que
              // llego a probarse en el aparato):
              //
              //   descartados(vo)  141 -> 173 -> 210 -> 246 -> 280  (cada 5s)
              //   descartados(dec) 0
              //   bufer 240s, 0 KB/s
              //
              // Son ~7 fotogramas por segundo tirados: a 24 fps, casi un
              // tercio de la pelicula. Y las otras dos cifras senalan donde:
              // el DECODIFICADOR va fino (dec=0) y la red tampoco es (bufer
              // lleno). Se cae entero en `vo`, que es el pintado — y lo unico
              // que se le habia anadido al pintado era esto.
              //
              // POR QUE NO SIRVE BAJAR EL PORCENTAJE. El coste de esto no
              // esta en el radio: esta en que `ImageFiltered` obliga a pintar
              // el video en una CAPA INTERMEDIA de 1920x1080 y luego
              // componerla. Esa parte se paga igual con radio 0,29 que con
              // 0,65. Bajar el porcentaje reduce el beneficio y NO reduce el
              // coste — por eso seguia a tirones al 10%.
              // AL 20% a peticion (2026-09-22).
              //
              // Subir de 10% a 20% no cambia practicamente nada del coste: lo
              // caro es la capa intermedia de 1920x1080, que se crea igual
              // para cualquier radio mayor que cero. Asi que si al 10% iba a
              // tirones, al 20% ira parecido — y si aqui va fluido, al 10%
              // tambien habria ido.
              //
              // Lo que si cambia es el efecto: 80% del detalle conservado en
              // vez del 90%, y el bloque baja de 3,9 a 2,5 niveles, que es
              // justo el umbral de lo visible.
              //
              // O sea que la decision de verdad es binaria —capa o no capa— y
              // dentro de "capa" conviene el valor que mejor se vea, no el
              // mas bajo.
              //
              // CONDICIONAL: Cuando el caudal es insuficiente (_bloqueoInevitable),
              // el macrobloqueo es inevitable del origen (<0.07 bpp) y el
              // blur ciego solo cuesta fotogramas sin arreglarlo; se apaga (0.0).
              // Con caudal adecuado, se sube a 0.55 para acabado liso y suave.
              suavizado: _bloqueoInevitable ? 0.0 : 0.55,
              child: Video(
                controller: _controlador,
                controls: NoVideoControls,
                // ── NITIDEZ AL AMPLIAR: `low` Y NO SE TOCA ──────────────
                //
                // La fuente es 1280x720 y el Chromecast saca 1920x1080, asi
                // que cada fotograma se amplia 1,5x. `low` es un bilineal y
                // es lo mas blando que hay para eso, asi que se probo `high`
                // (bicubico) el 2026-09-21.
                //
                // RESULTADO: LA PANTALLA SE QUEDO TODA EN BLANCO.
                //
                // La razon es que esto NO es una imagen normal: es un
                // `Texture`, una superficie externa de Android que el motor
                // no posee. Esta app corre sobre Skia (tiene Impeller
                // desactivado), y el muestreo bicubico sobre una textura
                // externa no esta soportado por ese camino: en vez de fallar
                // con un error, devuelve basura.
                //
                // O sea que no es cuestion de que cueste demasiado —no llego
                // ni a ser un problema de rendimiento—. Simplemente no se
                // puede. `medium` tampoco se ha probado y NO merece la pena
                // arriesgarse: usa mipmaps, que es otro camino que la textura
                // externa puede no tener.
                //
                // La nitidez de la ampliacion, en el televisor, hay que darla
                // por cerrada igual que el desbloqueo.
                filterQuality: FilterQuality.low,
                // EN PEQUEÑO LLENA EL RECUADRO; EN GRANDE, NO.
                //
                // Por defecto el vídeo se ajusta entero (`contain`), así que si
                // su proporción no es la del hueco deja franjas negras — el
                // recuadro de la ficha se veía a medio ocupar.
                //
                // Ahí `cover` es lo correcto: es una vista previa, se recorta un
                // poco por los lados y llena el hueco. A pantalla completa se
                // vuelve a `contain`, porque recortar una película para que
                // cuadre con el televisor sí sería quitarle imagen al usuario.
                fit: grande ? BoxFit.contain : BoxFit.cover,
              ),
            ),
          ),

          // MISMO SPINNER Y MISMA CONDICION QUE EL RECEPTOR.
          //
          // Antes era el `CircularProgressIndicator` de Material y solo
          // con `_buffering`. Entre que MPV deja de bufferear y llega la
          // imagen hay un hueco, y ahi la pantalla se quedaba negra y
          // vacia: parecia colgada. Con `!_primerFrameListo` el spinner
          // cubre tambien ese tramo.
          // El spinner, mientras haya algo que esperar. Si ya no queda
          // servidor, esperar es mentir: se dice lo que pasa.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: (_spinnerVisible && !_agotado)
                ? Center(
                    key: const ValueKey('tv_spinner_active'),
                    // Se queda también en pequeño —es lo que explica por qué el
                    // recuadro está negro— pero a escala: 54 px dentro de
                    // 360 x 203 lo llenan entero.
                    child: TvLoadingAnimation(
                      size: grande ? 58 : 34,
                      strokeWidth: grande ? 4 : 2.5,
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('tv_spinner_empty')),
          ),

          // ── Se acabaron los servidores ────────────────────────────
          //
          // Antes esto era un bucle silencioso: "Cambiando de servidor"
          // una y otra vez sobre negro, sin final. Un mensaje claro y la
          // salida a mano valen mas que un intento numero cuarenta.
          // En pequeño solo el icono: el mensaje entero son 54 px de icono
          // más dos textos, y en un recuadro de 203 de alto no entra —
          // desbordaba 19 px. El icono ya dice que algo va mal, y quien
          // quiera el detalle lo tiene al abrirlo en grande.
          if (_agotado && !grande)
            const Center(
              child: Icon(
                Icons.cloud_off_rounded,
                color: Colors.white38,
                size: 34,
              ),
            ),

          if (_agotado && grande)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 80),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_off_rounded,
                      color: Colors.white38,
                      size: 54,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _faltaCaudal
                          ? 'Tu conexión está muy lenta'
                          : _urls.length > 1
                          ? 'Ninguno de los ${_urls.length} servidores '
                              'pudo reproducir este título'
                          : 'El servidor no pudo reproducir este título',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _faltaCaudal
                          ? 'Intenta con otro título o vuelve a intentar más tarde.'
                          : 'Pulsa atrás para volver e inténtalo más tarde.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Aviso de Calidad Baja cuando no hay servidores alternativos ──
          if (_avisoCalidadBaja && grande && !_agotado)
            Positioned(
              top: 24,
              left: 48,
              right: 48,
              child: AnimatedOpacity(
                opacity: 0.9,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xEB1E1E1E),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black45,
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.amber,
                        size: 28,
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Calidad de origen baja para este título',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'El proveedor comprimió en exceso este video.',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: _contadorAviso / 5,
                              strokeWidth: 2.5,
                              color: Colors.amber,
                              backgroundColor: Colors.white12,
                            ),
                            Text(
                              '$_contadorAviso',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Velocidad de descarga, arriba a la izquierda. Sale cuando
          // ACOMPAÑA a algo: mientras carga, o con los controles abiertos.
          // Se avisa de que se reanudo, pero no se pregunta. Enterarse
          // es util; tener que decidir con el mando, no.
          if (grande && _reanudadoDesde != null && _controlesVisibles)
            Positioned(
              top: 44,
              left: 56,
              child: Text(
                'Reanudado desde ${_fmt(_reanudadoDesde!)}',
                style: const TextStyle(color: Colors.white54, fontSize: 15),
              ),
            ),

          // ── Play, SOLO EN PAUSA ─────────────────────────────────
          //
          // Es lo que hace el receptor, y tenia razon de ser: no es un
          // control permanente sino un "dale para seguir". Mientras se
          // reproduce no pinta nada en mitad de la pantalla; en cuanto
          // pausas, aparece y dice que hacer.
          //
          // Yo lo habia quitado del todo al malinterpretar que no debia
          // salir "ahi" — no salia SIEMPRE, que es distinto.
          if (grande &&
              !_reproduciendo &&
              !_buffering &&
              _primerFrameListo &&
              !_menuAbierto)
            const Center(child: _BotonEsfera()),

          if (grande && _controlesVisibles && !_menuAbierto)
            _Controles(
              titulo: widget.titulo,
              caratula: widget.item.logo,
              posicion: _posicion,
              duracion: _duracion,
              bufer: _bufer,
              progreso: progreso,
              reproduciendo: _reproduciendo,
              foco: _foco,
              fmt: _fmt,
              reportando: _reportando,
              opcionesAbiertas: _ajustesAbierto,
              opcionesIdx: _ajustesIdx,
              esFavorito: _esFavorito,
              meGusta: _meGusta,
              noMeGusta: _noMeGusta,
            ),

          if (grande && _reporteAbierto)
            _MenuReporte(motivos: _motivos, indice: _reporteIdx),

          if (grande && _menuAbierto)
            _MenuPistas(
              tab: _menuTab,
              indice: _menuIdx,
              audio: [
                for (final t in _pistasAudio)
                  _etiqueta(t.title, t.language, t.id),
              ],
              subtitulos: [
                'Desactivados',
                for (final t in _pistasSubs)
                  _etiqueta(t.title, t.language, t.id),
              ],
              audioActivo: _indiceActual(0),
              subtituloActivo: _indiceActual(1),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Controles inferiores
// ═══════════════════════════════════════════════════════════════════════════
/// El botón de play del centro: la misma esfera roja del receptor.
///
/// Estaba "parecida" y no igual: le faltaba el brillo especular —la chispa
/// blanca de arriba a la izquierda, que es lo que hace que se lea como una
/// esfera y no como un circulo plano— y el icono iba a 40 en vez de 46.
///
/// Copiado de `_CtrlButton` del receptor a proposito: transmitir desde el
/// telefono y ver desde el propio televisor tienen que verse igual, porque
/// para quien mira son la misma app.
class _BotonEsfera extends StatelessWidget {
  const _BotonEsfera();

  static const double _tamano = 72;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _tamano,
      height: _tamano,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: Alignment(-0.4, -0.5),
          radius: 1.2,
          colors: [
            Color(0xFFFF6B5E), // luz cálida arriba-izquierda
            Color(0xFFE53935), // rojo principal
            Color(0xFFB71C1C), // rojo profundo en el borde
          ],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // El brillo especular: la "chispa" blanca de la esfera.
          Positioned(
            top: _tamano * 0.13,
            left: _tamano * 0.22,
            child: Container(
              width: _tamano * 0.26,
              height: _tamano * 0.15,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_tamano),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.85),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 46),
        ],
      ),
    );
  }
}

class _Controles extends StatelessWidget {
  final String titulo;
  final String? caratula;
  final Duration posicion;
  final Duration duracion;
  final Duration bufer;
  final double progreso;
  final bool reproduciendo;
  final int foco;
  final String Function(Duration) fmt;
  final bool reportando;
  final bool opcionesAbiertas;
  final int opcionesIdx;
  final bool esFavorito;
  final bool meGusta;
  final bool noMeGusta;

  const _Controles({
    required this.titulo,
    required this.caratula,
    required this.posicion,
    required this.duracion,
    required this.bufer,
    required this.progreso,
    required this.reproduciendo,
    required this.foco,
    required this.fmt,
    required this.reportando,
    required this.opcionesAbiertas,
    required this.opcionesIdx,
    required this.esFavorito,
    required this.meGusta,
    required this.noMeGusta,
  });

  @override
  Widget build(BuildContext context) {
    final enBarra = foco == 1;

    // Fraccion cargada. El `buffer` de MPV es la posicion ABSOLUTA hasta donde
    // hay datos, no una duracion, asi que se divide igual que la posicion.
    // Nunca por detras de lo ya reproducido: si el bufer se vacia, la pista
    // secundaria se esconde bajo la principal en vez de dibujarse al reves.
    final double cargado =
        duracion.inMilliseconds > 0
            ? (bufer.inMilliseconds / duracion.inMilliseconds).clamp(
              progreso,
              1.0,
            )
            : 0.0;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: const [Colors.black87, Colors.transparent],
          stops: [0.0, opcionesAbiertas ? 0.70 : 0.55],
        ),
      ),
      // Mismas medidas que el receptor: 40 a la izquierda, 48 a la derecha,
      // 36 abajo. Si no coinciden, la misma pelicula se ve descolocada segun
      // como la hayas abierto.
      padding: const EdgeInsets.fromLTRB(40, 0, 48, 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // SIN BOTON DE PLAY FLOTANTE.
          //
          // El receptor no lo tiene, y con razon: al transmitir se pausa desde
          // el telefono, y aqui se pausa con OK sobre la linea de tiempo. Un
          // circulo rojo en mitad de la pantalla tapa el video y no aporta nada
          // que el mando no haga ya.
          // ── Carátula a la izquierda, línea de tiempo y título a la
          // derecha ── Es la disposición del receptor, y estaba sin replicar:
          // al transmitir salía la carátula y al abrir desde el catálogo no,
          // así que la misma película se veía de dos formas distintas.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (caratula != null && caratula!.isNotEmpty) ...[
                Image.network(
                  caratula!,
                  width: 95,
                  height: 140,
                  fit: BoxFit.cover,
                  cacheWidth: 220,
                  cacheHeight: 320,
                  // Si la carátula falla no se deja hueco: mejor sin ella que
                  // con un rectángulo vacío.
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                const SizedBox(width: 24),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // La barra NO se pinta hasta saber la duracion.
                    //
                    // Mismo criterio que el receptor y que el telefono: un
                    // "00:00 / 00:00" no se lee como "cargando", se lee como
                    // "esto dura cero". `maintainSize` reserva el alto para
                    // que el titulo de debajo no pegue un salto al aparecer.
                    // La barra se pinta SIEMPRE, tambien mientras carga.
                    //
                    // Antes se escondia hasta saber la duracion, para no
                    // enseñar un "00:00 / 00:00". Pero esconderla sale mas
                    // caro: al pulsar el mando durante la carga no habia linea
                    // de tiempo y la pantalla parecia otra. Que ponga ceros un
                    // momento se entiende; que el control desaparezca y vuelva,
                    // no.
                    Row(
                      children: [
                        Text(
                          fmt(posicion),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, c) {
                              const alto = 6.0;
                              const tirador = 20.0;
                              final x = c.maxWidth * progreso;
                              return SizedBox(
                                height: 28,
                                child: Stack(
                                  alignment: Alignment.centerLeft,
                                  children: [
                                    // Pista vacia.
                                    Container(
                                      height: alto,
                                      decoration: BoxDecoration(
                                        color: Colors.white24,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                    // Pista de BUFER: por debajo de la
                                    // reproducida, para que esta la tape. Mas
                                    // opaca que la vacia y mas tenue que el
                                    // acento, igual que el receptor. Faltaba
                                    // aqui, y es lo que dice si el video esta
                                    // cargando o parado.
                                    FractionallySizedBox(
                                      alignment: Alignment.centerLeft,
                                      widthFactor: cargado,
                                      child: Container(
                                        height: alto,
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.45,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Lo reproducido: BLANCO, no rojo.
                                    //
                                    // El receptor lo pinta en blanco y aqui
                                    // iba en rojo: la misma pelicula se veia
                                    // distinta segun la hubieras abierto desde
                                    // el catalogo o transmitido. El rojo se
                                    // queda para el tirador y el boton de
                                    // play, que son los controles.
                                    //
                                    // Sin foco se apaga un poco: es la marca
                                    // que sustituye al cambio de grosor, que
                                    // haria "saltar" la barra al entrar y
                                    // salir el foco.
                                    FractionallySizedBox(
                                      alignment: Alignment.centerLeft,
                                      widthFactor: progreso,
                                      child: Container(
                                        height: alto,
                                        decoration: BoxDecoration(
                                          color:
                                              enBarra
                                                  ? Colors.white
                                                  : Colors.white.withValues(
                                                    alpha: 0.6,
                                                  ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: (x - tirador / 2).clamp(
                                        0.0,
                                        (c.maxWidth - tirador).clamp(
                                          0.0,
                                          double.infinity,
                                        ),
                                      ),
                                      child: AnimatedOpacity(
                                        duration: const Duration(
                                          milliseconds: 150,
                                        ),
                                        opacity: enBarra ? 1.0 : 0.5,
                                        child: Container(
                                          width: tirador,
                                          height: tirador,
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
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 18),
                        Text(
                          fmt(duracion),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Título a la izquierda, pistas a la derecha, en la misma línea.
                    //
                    // `Expanded` Y NO `Flexible`: el título se queda con todo
                    // el hueco sobrante y EMPUJA las pistas contra el borde
                    // derecho, que es donde van.
                    //
                    // Lo probé con `Flexible` para atajar un desbordamiento, y
                    // el efecto fue que el título encogía a su ancho natural y
                    // "Subtítulos" y "Audio" se le pegaban al lado, en medio
                    // de la barra. El desbordamiento venía de otro sitio —los
                    // controles se estaban dibujando en la vista previa de
                    // 360 px— y ya está resuelto ahí.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            titulo,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                            ),
                          ),
                        ),
                        const SizedBox(width: 28),
                        _IconoPista(
                          icon: Icons.subtitles_outlined,
                          etiqueta: 'Subtítulos',
                          focused: foco == 2 && !opcionesAbiertas,
                        ),
                        const SizedBox(width: 26),
                        _IconoPista(
                          icon: Icons.multitrack_audio_rounded,
                          etiqueta: 'Audio',
                          focused: foco == 3 && !opcionesAbiertas,
                        ),
                        const SizedBox(width: 26),
                        // ── Botón Info con flechita hacia abajo ───────────────
                        _BotonInfo(
                          focused: foco == 4 && !opcionesAbiertas,
                          abierta: opcionesAbiertas,
                          reportando: reportando,
                        ),
                      ],
                    ),
                    // ── Opciones disponibles al pulsar/navegar hacia abajo ──
                    if (opcionesAbiertas) ...[
                      const SizedBox(height: 16),
                      _FilaOpciones(
                        indice: opcionesIdx,
                        esFavorito: esFavorito,
                        meGusta: meGusta,
                        noMeGusta: noMeGusta,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Mismo criterio que en el receptor: el foco es solo color, nunca tamaño.
class _IconoPista extends StatelessWidget {
  final IconData icon;

  /// Sin etiqueta, solo el icono: lo usan las acciones del titulo.
  final String? etiqueta;
  final bool focused;

  const _IconoPista({required this.icon, this.etiqueta, required this.focused});

  @override
  Widget build(BuildContext context) {
    final color = focused ? Colors.white : Colors.white54;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        if (etiqueta != null) ...[
          const SizedBox(width: 7),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 130),
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
            child: Text(etiqueta!),
          ),
        ],
      ],
    );
  }
}

/// Botón "Info" con flechita hacia abajo (o hacia arriba al estar desplegado).
class _BotonInfo extends StatelessWidget {
  final bool focused;
  final bool abierta;
  final bool reportando;

  const _BotonInfo({
    required this.focused,
    required this.abierta,
    required this.reportando,
  });

  @override
  Widget build(BuildContext context) {
    final color = focused ? Colors.white : Colors.white54;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 130),
          style: TextStyle(
            color: color,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          child: const Text('Info'),
        ),
        const SizedBox(width: 4),
        Icon(
          reportando
              ? Icons.hourglass_empty_rounded
              : (abierta
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded),
          size: 20,
          color: color,
        ),
      ],
    );
  }
}

/// Fila horizontal de opciones disponibles para el título:
/// Mi lista, Me gusta, No me gusta y Reportar.
class _FilaOpciones extends StatelessWidget {
  final int indice;
  final bool esFavorito;
  final bool meGusta;
  final bool noMeGusta;

  const _FilaOpciones({
    required this.indice,
    required this.esFavorito,
    required this.meGusta,
    required this.noMeGusta,
  });

  @override
  Widget build(BuildContext context) {
    final opciones = <({String texto, bool activo})>[
      (
        texto: esFavorito ? 'En Mi lista' : 'Añadir a Mi lista',
        activo: esFavorito,
      ),
      (texto: 'Me gusta', activo: meGusta),
      (texto: 'No me gusta', activo: noMeGusta),
      (texto: 'Reportar problema', activo: false),
    ];

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < opciones.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            _ItemOpcion(
              texto: opciones[i].texto,
              activo: opciones[i].activo,
              enfocado: i == indice,
            ),
          ],
          const SizedBox(width: 16),
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_upward_rounded, size: 14, color: Colors.white38),
              SizedBox(width: 4),
              Text(
                'Subir para volver',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Botón individual de opción con estilo TV y realce de foco (solo texto).
class _ItemOpcion extends StatelessWidget {
  final String texto;
  final bool activo;
  final bool enfocado;

  const _ItemOpcion({
    required this.texto,
    required this.activo,
    required this.enfocado,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color:
            enfocado
                ? Colors.white
                : activo
                ? Colors.white.withValues(alpha: 0.18)
                : const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color:
              enfocado
                  ? Colors.white
                  : activo
                  ? Colors.white38
                  : Colors.white12,
          width: 1.2,
        ),
      ),
      child: Text(
        texto,
        style: TextStyle(
          color: enfocado ? const Color(0xFF0B0B0D) : Colors.white,
          fontSize: 14,
          fontWeight: enfocado ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

/// "¿Qué problema encontraste?", con el mismo trato que el menú de pistas:
/// fondo oscuro a pantalla completa, sin caja, y el elegido en blanco.
class _MenuReporte extends StatelessWidget {
  final List<String> motivos;
  final int indice;

  const _MenuReporte({required this.motivos, required this.indice});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 2, bottom: 14),
              child: Text(
                '¿QUÉ PROBLEMA ENCONTRASTE?',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            for (var i = 0; i < motivos.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Text(
                  motivos[i],
                  style: TextStyle(
                    color: i == indice ? Colors.white : Colors.white54,
                    fontSize: 16,
                    fontWeight: i == indice ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Las dos listas a la vez, sin caja. Igual que en el receptor.
class _MenuPistas extends StatelessWidget {
  final int tab;
  final int indice;
  final List<String> audio;
  final List<String> subtitulos;
  final int audioActivo;
  final int subtituloActivo;

  const _MenuPistas({
    required this.tab,
    required this.indice,
    required this.audio,
    required this.subtitulos,
    required this.audioActivo,
    required this.subtituloActivo,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 560),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Columna(
                titulo: 'AUDIO',
                filas: audio,
                seleccionada: audioActivo,
                enfocada: tab == 0,
                indiceFoco: indice,
              ),
            ),
            const SizedBox(width: 36),
            Expanded(
              child: _Columna(
                titulo: 'SUBTÍTULOS',
                filas: subtitulos,
                seleccionada: subtituloActivo,
                enfocada: tab == 1,
                indiceFoco: indice,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Columna extends StatelessWidget {
  final String titulo;
  final List<String> filas;
  final int seleccionada;
  final bool enfocada;
  final int indiceFoco;

  const _Columna({
    required this.titulo,
    required this.filas,
    required this.seleccionada,
    required this.enfocada,
    required this.indiceFoco,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          titulo,
          style: TextStyle(
            color: enfocada ? Colors.white : Colors.white24,
            fontSize: 15,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 20),
        if (filas.isEmpty)
          Text(
            'No hay',
            style: TextStyle(
              color: enfocada ? Colors.white38 : Colors.white24,
              fontSize: 18,
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: filas.length,
              itemBuilder: (context, i) {
                final foco = enfocada && i == indiceFoco;
                final puesta = i == seleccionada;
                final Color color;
                if (foco) {
                  color = Colors.white;
                } else if (!enfocada) {
                  color = Colors.white24;
                } else {
                  color = puesta ? Colors.white70 : Colors.white54;
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        child:
                            puesta
                                ? Icon(
                                  Icons.check_rounded,
                                  size: 18,
                                  color: color,
                                )
                                : null,
                      ),
                      Expanded(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 120),
                          style: TextStyle(
                            color: color,
                            fontSize: 18,
                            fontWeight:
                                foco ? FontWeight.w600 : FontWeight.w400,
                          ),
                          child: Text(
                            filas[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
