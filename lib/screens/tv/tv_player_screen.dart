import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../models/m3u_item.dart';
import '../../services/dynamic_scraper_service.dart';
import '../../services/turbo_proxy.dart';
import '../../services/tv/tv_mpv_config.dart';
import '../../utils/cabeceras_stream.dart';
import '../../utils/clasificacion_stream.dart';
import 'tv_loading_animation.dart';
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

  const TvPlayerScreen({super.key, required this.item, required this.titulo});

  @override
  State<TvPlayerScreen> createState() => _TvPlayerScreenState();
}

class _TvPlayerScreenState extends State<TvPlayerScreen> {
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

  late final VideoController _controlador = VideoController(
    _player,
    configuration: const VideoControllerConfiguration(
      enableHardwareAcceleration: true,
      hwdec: 'mediacodec',
    ),
  );
  final List<StreamSubscription> _subs = [];

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

  /// Velocidad de descarga, para la esquina superior izquierda.
  double _kbps = 0;
  Timer? _sondeoVelocidad;
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

  bool _menuAbierto = false;
  int _menuTab = 0;
  int _menuIdx = 0;

  DateTime? _ultimoAtras;

  // ── Seguir viendo ────────────────────────────────────────────────────────
  final _progreso = WatchProgressService();
  Timer? _guardado;
  Duration? _reanudadoDesde;

  // ── Cambio de servidor ───────────────────────────────────────────────────
  //
  // Mismo problema que en la transmision y misma solucion: el titulo puede
  // estar en varios sitios y el primero no siempre responde.
  late final List<String> _urls;
  int _idxServidor = 0;

  Timer? _vigilante;
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
  int _segundosSinDatos = 0;
  int _segundosDesdeAbrir = 0;

  /// Segundos SIN QUE ENTRE UN SOLO BYTE antes de dar el servidor por muerto.
  static const int _umbralSinDatos = 12;

  /// Tope absoluto: aunque entren datos, si a los 45s no hay imagen es que algo
  /// va mal —un archivo corrupto, un servidor que gotea— y se prueba otro.
  static const int _topeArranque = 45;

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
        if (mounted) setState(() => _reproduciendo = v);
      }),
      _player.stream.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }),
      _player.stream.position.listen((v) {
        if (mounted && !_preparandoSalto) setState(() => _posicion = v);
      }),
      _player.stream.duration.listen((v) {
        if (mounted) setState(() => _duracion = v);
      }),
      // Cuanto hay cargado por delante. Lo pinta la linea de tiempo como una
      // pista mas clara, igual que el receptor: sin ella no se sabe si el
      // video esta cargando o parado.
      _player.stream.buffer.listen((v) {
        if (mounted) setState(() => _bufer = v);
      }),
    ]);

    // El titulo primero y sus alternativas despues, sin repetidos.
    //
    // FUERA LAS QUE NO SON UN VIDEO.
    //
    // Parte del contenido propio no guarda el enlace al fichero, sino la
    // PAGINA de donde se saca. El telefono la resuelve con un navegador
    // invisible; SE PROBO AQUI y en este aparato no sale a cuenta: cargar la
    // pagina de cuevana se comio ~150 fotogramas de golpe, dejo la interfaz a
    // tirones durante todo el proceso... y termino sin encontrar ningun video.
    //
    // Descartadas, el cambio de servidor va directo a una que si puede
    // funcionar, y la reproduccion no se para a cargar paginas.
    final todas =
        <String>{
          widget.item.url,
          for (final alt in widget.item.alternatives) alt.url,
        }.toList();

    final reproducibles = [
      for (final u in todas)
        if (!DynamicScraperService().isSupported(u)) u,
    ];

    // Si TODAS necesitan navegador no se descarta ninguna: mas vale intentarlo
    // y fallar que quedarse sin nada que abrir.
    _urls = reproducibles.isEmpty ? todas : reproducibles;

    if (reproducibles.length != todas.length) {
      debugPrint(
        'TvPlayer: ${todas.length - reproducibles.length} servidor(es) '
        'descartados por no ser un video directo',
      );
    }

    _subs.add(
      _player.stream.log.listen((l) {
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
        setState(() => _primerFrameListo = true);
      }
    });

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
    // LA CONFIGURACION DE MPV SE ESPERA, no se lanza y se olvida.
    //
    // Estaba con `unawaited`, asi que el `open()` podia salir ANTES de que
    // estuvieran puestos el tamaño de cache, el reparto del bufer y el resto.
    // MPV arrancaba con sus valores por defecto y se comportaba de otra forma
    // — justo lo que este perfil existe para evitar.
    await TvMpvConfig.aplicarBase(_player);

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
    if (desde > Duration.zero) setState(() => _reanudadoDesde = desde);

    try {
      await _abrir(desde);
    } catch (e) {
      // Si el PRIMER servidor no arranca —tipico del de la base de datos,
      // cuya pagina puede no soltar el video— se pasa al siguiente en vez de
      // quedarse en negro esperando a un vigilante que aun no existe.
      debugPrint('TvPlayer: el primer servidor fallo ($e) — cambiando');
      unawaited(_siguienteServidor('fallo al abrir'));
    }
    _armarVigilante();
    _armarGuardado();
  }

  Future<void> _abrir(Duration desde) async {
    // Servidor nuevo, cuenta nueva: lo que tardara el anterior no puede
    // condenar a este.
    _segundosSinDatos = 0;
    _segundosDesdeAbrir = 0;

    final original = _urls[_idxServidor];

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

    if (!esEnVivoPorUrl(original)) {
      try {
        final local = await TurboProxy()
            .wrap(original, cabeceras)
            .timeout(const Duration(seconds: 7));
        if (local != null) {
          url = local;
          debugPrint('TvPlayer: enrutado por TurboProxy');
        }
      } catch (e) {
        debugPrint('TvPlayer: TurboProxy fallo ($e) — URL directa');
      }
    }

    await _player.open(
      Media(
        url,
        // Si TurboProxy no entro, MPV pide directo y necesita las cabeceras el
        // mismo. Con el envoltorio puesto no estorban: la URL ya es local.
        httpHeaders: cabeceras,
        start: desde > Duration.zero ? desde : null,
      ),
    );
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

      // En pausa no se vigila NADA: ni la posicion, ni los bytes, ni el
      // arranque. Se congela todo tal cual estaba para que al reanudar no
      // arrastre segundos que el servidor no debe.
      if (_pausadoAdrede) {
        _segundosSinAvance = 0;
        _segundosSinDatos = 0;
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
      // ── Todavia ARRANCANDO ─────────────────────────────────────────────
      if (!_primerFrameListo) {
        _segundosSinAvance = 0;
        _posVigilada = _posicion;
        _segundosDesdeAbrir++;

        // Sin un solo byte entrando: el servidor no esta lento, esta muerto.
        if (_kbps <= 0) {
          _segundosSinDatos++;
        } else {
          _segundosSinDatos = 0;
        }

        if (_segundosSinDatos >= _umbralSinDatos) {
          unawaited(
            _siguienteServidor('sin datos en ${_umbralSinDatos}s al arrancar'),
          );
        } else if (_segundosDesdeAbrir >= _topeArranque) {
          unawaited(_siguienteServidor('sin imagen tras ${_topeArranque}s'));
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

  Future<void> _siguienteServidor(String motivo) async {
    if (_urls.length < 2 || _cambiandoServidor) return;

    _cambiandoServidor = true;
    // Servidor nuevo: vuelve a no haber imagen hasta que llegue la primera. Sin
    // esto, el vigilante seguiria contando desde el primer segundo del video
    // nuevo y encadenaria otro cambio.
    if (mounted) setState(() => _primerFrameListo = false);
    _segundosSinDatos = 0;
    _segundosDesdeAbrir = 0;
    final desde = _posicion;
    _idxServidor = (_idxServidor + 1) % _urls.length;
    debugPrint('TvPlayer: cambio de servidor ($motivo) -> $_idxServidor');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cambiando de servidor...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      // Se retoma por donde iba, no desde cero: cambiar de servidor no puede
      // costarle al usuario volver a buscar su minuto.
      await _abrir(desde);
    } catch (e) {
      debugPrint('TvPlayer: el cambio de servidor fallo: $e');
    }

    _segundosSinAvance = 0;
    _posVigilada = desde;
    _cambiandoServidor = false;
  }

  @override
  void dispose() {
    // Una extraccion a medias deja un WebView invisible corriendo: en un
    // televisor de 1 GB eso es memoria que no vuelve.
    unawaited(DynamicScraperService().stopCurrentScraping());
    for (final s in _subs) {
      s.cancel();
    }
    _ocultar?.cancel();
    _confirmarSalto?.cancel();
    _sondeoVelocidad?.cancel();
    _vigilante?.cancel();
    _guardado?.cancel();
    // Un ultimo guardado al salir: sin el se pierden hasta 5 s, y salir es
    // justo cuando el usuario espera que quede anotado por donde iba.
    _guardar();
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
  }

  // ── Controles ────────────────────────────────────────────────────────────
  void _mostrarControles() {
    _ocultar?.cancel();
    if (!_controlesVisibles && mounted) {
      setState(() => _controlesVisibles = true);
    }
    _ocultar = Timer(const Duration(seconds: 5), () {
      if (mounted && !_menuAbierto) {
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
      _segundosSinDatos = 0;
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

  /// `direccion` es -1 o 1; el tamaño del paso lo decide la carrerilla.
  void _saltar(int direccion) {
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

    // Se aplica 400 ms después de la ÚLTIMA pulsación. Saltar en cada
    // pulsación vacía el búfer una vez por tecla, y recorrer un minuto a base
    // de toques dejaba el vídeo inservible.
    // Se aplica 500 ms despues de la ULTIMA pulsacion —antes 400—: con la
    // flecha mantenida, 400 se quedaba corto y el salto se ejecutaba a mitad
    // del recorrido, vaciando el bufer sin que hubieras terminado de elegir.
    _confirmarSalto?.cancel();
    _confirmarSalto = Timer(const Duration(milliseconds: 500), _aplicarSalto);
  }

  void _aplicarSalto() {
    if (!_preparandoSalto) return;
    _saltosSeguidos = 0; // la carrerilla se pierde al soltar
    _player.seek(_saltoPrevisto);
    setState(() => _preparandoSalto = false);
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
          await _player.setAudioTrack(l[_menuIdx]);
        }
      } else {
        if (_menuIdx == 0) {
          await _player.setSubtitleTrack(SubtitleTrack.no());
        } else {
          final l = _pistasSubs;
          final i = _menuIdx - 1;
          if (i >= 0 && i < l.length) await _player.setSubtitleTrack(l[i]);
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
  bool _manejarAtras() {
    if (_menuAbierto) {
      setState(() => _menuAbierto = false);
      _mostrarControles();
      return true;
    }
    if (_controlesVisibles) {
      setState(() => _controlesVisibles = false);
      return true;
    }
    // Dos veces para salir: con una sola, un roce del pulgar te saca de la
    // película y hay que volver a buscarla en el catálogo.
    final ahora = DateTime.now();
    final previo = _ultimoAtras;
    _ultimoAtras = ahora;
    if (previo != null && ahora.difference(previo).inSeconds < 3) {
      return false; // que salga de verdad
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pulsa atrás otra vez para salir'),
        duration: Duration(seconds: 2),
      ),
    );
    return true;
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
      Navigator.of(context).pop();
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

    if (k == LogicalKeyboardKey.mediaPlayPause) {
      _alternarReproduccion();
      _mostrarControles();
      return KeyEventResult.handled;
    }

    // La primera pulsación con los controles ocultos solo los revela.
    final estaban = _controlesVisibles;
    _mostrarControles();
    if (!estaban) return KeyEventResult.handled;

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
        _aplicarSalto();
        setState(() => _foco = 0);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Iconos de pistas ──────────────────────────────────────────────────
    if (_foco == 2 || _foco == 3) {
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight) {
        setState(() => _foco = _foco == 2 ? 3 : 2);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        setState(() => _foco = 1);
        return KeyEventResult.handled;
      }
      // Abajo da la vuelta al play: volver a reproducir es lo que se quiere
      // casi siempre después de pasar por aquí.
      if (k == LogicalKeyboardKey.arrowDown) {
        setState(() => _foco = 0);
        return KeyEventResult.handled;
      }
      if (ok) {
        _abrirMenu(_foco == 2 ? 1 : 0);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Botón de play ─────────────────────────────────────────────────────
    if (k == LogicalKeyboardKey.arrowLeft) {
      _saltar(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _saltar(1);
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (hecho, _) {
        if (hecho) return;
        if (!_manejarAtras()) Navigator.of(context).pop();
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _tecla,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Video(controller: _controlador, controls: NoVideoControls),

              // MISMO SPINNER Y MISMA CONDICION QUE EL RECEPTOR.
              //
              // Antes era el `CircularProgressIndicator` de Material y solo
              // con `_buffering`. Entre que MPV deja de bufferear y llega la
              // imagen hay un hueco, y ahi la pantalla se quedaba negra y
              // vacia: parecia colgada. Con `!_primerFrameListo` el spinner
              // cubre tambien ese tramo.
              if (_buffering || !_primerFrameListo)
                const Center(
                  child: TvLoadingAnimation(size: 54, strokeWidth: 4),
                ),

              // Velocidad de descarga, arriba a la izquierda. Sale cuando
              // ACOMPAÑA a algo: mientras carga, o con los controles abiertos.
              if (_buffering || !_primerFrameListo || _controlesVisibles)
                Positioned(
                  top: 40,
                  left: 48,
                  child: Text(
                    '${_kbps.toStringAsFixed(0)} KB/s',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      backgroundColor: Color(0x99000000),
                      shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                    ),
                  ),
                ),

              // Se avisa de que se reanudo, pero no se pregunta. Enterarse
              // es util; tener que decidir con el mando, no.
              if (_reanudadoDesde != null && _controlesVisibles)
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
              if (!_reproduciendo &&
                  !_buffering &&
                  _primerFrameListo &&
                  !_menuAbierto)
                const Center(child: _BotonEsfera()),

              if (_controlesVisibles && !_menuAbierto)
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
                ),

              if (_menuAbierto)
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
        ),
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
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
          stops: [0.0, 0.55],
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
                  width: 90,
                  height: 130,
                  fit: BoxFit.cover,
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
                    Visibility(
                      visible: duracion > Duration.zero,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: Row(
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
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
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
                    ),
                    const SizedBox(height: 14),

                    // Título a la izquierda, pistas a la derecha, en la misma línea.
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
                          focused: foco == 2,
                        ),
                        const SizedBox(width: 26),
                        _IconoPista(
                          icon: Icons.multitrack_audio_rounded,
                          etiqueta: 'Audio',
                          focused: foco == 3,
                        ),
                      ],
                    ),
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
  final String etiqueta;
  final bool focused;

  const _IconoPista({
    required this.icon,
    required this.etiqueta,
    required this.focused,
  });

  @override
  Widget build(BuildContext context) {
    final color = focused ? Colors.white : Colors.white54;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 7),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 130),
          style: TextStyle(
            color: color,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          child: Text(etiqueta),
        ),
      ],
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
