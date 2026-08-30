import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../models/m3u_item.dart';
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
  late final Player _player;
  late final VideoController _controlador;
  final List<StreamSubscription> _subs = [];

  bool _reproduciendo = false;
  bool _buffering = true;
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
    _player = Player();
    _controlador = VideoController(_player);

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
    ]);

    // El titulo primero y sus alternativas despues, sin repetidos.
    _urls =
        <String>[
          widget.item.url,
          for (final alt in widget.item.alternatives) alt.url,
        ].toSet().toList();

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

    await _abrir(desde);
    _armarVigilante();
    _armarGuardado();
  }

  Future<void> _abrir(Duration desde) async {
    final url = _urls[_idxServidor];
    await _player.open(Media(url, start: desde > Duration.zero ? desde : null));
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
    if (_urls.length < 2) return; // sin alternativa no hay nada que vigilar

    _vigilante = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _cambiandoServidor) return;

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
    for (final s in _subs) {
      s.cancel();
    }
    _ocultar?.cancel();
    _confirmarSalto?.cancel();
    _vigilante?.cancel();
    _guardado?.cancel();
    // Un ultimo guardado al salir: sin el se pierden hasta 5 s, y salir es
    // justo cuando el usuario espera que quede anotado por donde iba.
    _guardar();
    _player.dispose();
    super.dispose();
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
    _reproduciendo ? _player.pause() : _player.play();
  }

  void _saltar(int segundos) {
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
    _confirmarSalto?.cancel();
    _confirmarSalto = Timer(const Duration(milliseconds: 400), _aplicarSalto);
  }

  void _aplicarSalto() {
    if (!_preparandoSalto) return;
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
    if (evento is! KeyDownEvent) return KeyEventResult.ignored;
    final k = evento.logicalKey;

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
        _saltar(-10);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        _saltar(10);
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
      _saltar(-10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _saltar(10);
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

              if (_buffering)
                const Center(
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: CircularProgressIndicator(strokeWidth: 4),
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

              if (_controlesVisibles && !_menuAbierto)
                _Controles(
                  titulo: widget.titulo,
                  posicion: _posicion,
                  duracion: _duracion,
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
class _Controles extends StatelessWidget {
  final String titulo;
  final Duration posicion;
  final Duration duracion;
  final double progreso;
  final bool reproduciendo;
  final int foco;
  final String Function(Duration) fmt;

  const _Controles({
    required this.titulo,
    required this.posicion,
    required this.duracion,
    required this.progreso,
    required this.reproduciendo,
    required this.foco,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final enBarra = foco == 1;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
          stops: [0.0, 0.55],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(56, 0, 56, 44),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Botón de play
          Padding(
            padding: const EdgeInsets.only(bottom: 26),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 140),
              opacity: foco == 0 ? 1.0 : 0.5,
              child: Container(
                width: 64,
                height: 64,
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
                child: Icon(
                  reproduciendo
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 34,
                ),
              ),
            ),
          ),

          // Línea de tiempo
          Row(
            children: [
              Text(
                fmt(posicion),
                style: const TextStyle(color: Colors.white, fontSize: 17),
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
                          Container(
                            height: alto,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: progreso,
                            child: Container(
                              height: alto,
                              decoration: BoxDecoration(
                                color:
                                    enBarra
                                        ? const Color(0xFFE50914)
                                        : const Color(
                                          0xFFE50914,
                                        ).withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(4),
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
                              duration: const Duration(milliseconds: 150),
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
                style: const TextStyle(color: Colors.white, fontSize: 17),
              ),
            ],
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
                  style: const TextStyle(color: Colors.white, fontSize: 19),
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
