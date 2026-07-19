import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'cast_service.dart';

class CastAudioHandler extends BaseAudioHandler {
  final CastService _castService = CastService();
  Timer? _positionUpdateTimer;

  CastAudioHandler() {
    // Escuchar el estado de reproduccin (play/pause)
    _castService.castPlaying.addListener(_updatePlaybackState);

    // Escuchar la posicin para mantenerla sincronizada
    _castService.castPosition.addListener(_updatePlaybackState);

    // La duración llega DESPUÉS del LOAD (evento LOADED/STATUS del TV).
    // Sin duración en el MediaItem, Android no dibuja la barra de tiempo de
    // la notificación, así que re-emitimos el item al conocerla.
    _castService.castDuration.addListener(_updateDuration);

    // Escuchar cuando el estado de la sesin cambie (ej: conectado -> desconectado)
    _castService.sessionState.addListener(() {
      if (!_castService.isConnected) {
        // Ignoramos el Future de stop() aqu
        stop();
      }
    });

    // Iniciar un timer para forzar actualizaciones frecuentes si est reproduciendo
    _positionUpdateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_castService.isConnected && _castService.castPlaying.value) {
        _updatePlaybackState();
      }
    });
  }

  /// Actualiza el MediaItem con la duración real cuando el TV la reporta,
  /// para que la notificación muestre la barra de tiempo.
  void _updateDuration() {
    final item = mediaItem.value;
    final duration = _castService.castDuration.value;
    if (item == null || duration <= Duration.zero) return;
    if (item.duration == duration) return;
    mediaItem.add(item.copyWith(duration: duration));
  }

  void _updatePlaybackState() {
    if (!_castService.isConnected) return;

    final isPlaying = _castService.castPlaying.value;
    final position = _castService.castPosition.value;

    playbackState.add(
      playbackState.value.copyWith(
        // Retroceder 10s · play/pausa · adelantar 10s · desconectar (como la
        // referencia visual del usuario).
        controls: [
          MediaControl.rewind,
          isPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.fastForward,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: isPlaying,
        updatePosition: position,
      ),
    );
  }

  void setMediaItem({
    required String id,
    required String title,
    String? album,
    String? artist,
    String? artUri,
    Duration? duration,
  }) {
    mediaItem.add(
      MediaItem(
        id: id,
        title: title,
        album: album,
        artist: artist,
        artUri: artUri != null ? Uri.parse(artUri) : null,
        duration: duration ?? _castService.castDuration.value,
      ),
    );
    _updatePlaybackState();
  }

  @override
  Future<void> play() async {
    _castService.play();
  }

  @override
  Future<void> pause() async {
    _castService.pause();
  }

  @override
  Future<void> stop() async {
    await _castService.disconnect();
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
    mediaItem.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    _castService.seek(position.inMilliseconds / 1000.0);
  }

  @override
  Future<void> fastForward() async {
    _castService.seekForward(seconds: 10);
  }

  @override
  Future<void> rewind() async {
    _castService.seekBackward(seconds: 10);
  }

  @override
  Future<void> onTaskRemoved() async {
    if (_castService.isConnected) {
      await stop();
    }
  }

  void dispose() {
    _positionUpdateTimer?.cancel();
  }
}

late CastAudioHandler castAudioHandler;

Future<void> initAudioService() async {
  castAudioHandler = await AudioService.init(
    builder: () => CastAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId:
          'com.juanchosky.bumpcomba.cast.channel.audio',
      androidNotificationChannelName: 'Reproduccin Cast',
      // stopForegroundOnPause en false: mantener el FOREGROUND SERVICE vivo
      // aunque el usuario pause. Con true, Android degrada el servicio al
      // pausar y a los pocos minutos Doze mata el proceso → el socket con el
      // TV se cae y la notificación desaparece. La transmisión debe durar
      // hasta que el usuario la corte.
      // NOTA: audio_service exige ongoing=false cuando stopForegroundOnPause
      // es false (assert interno). La notificación sigue siendo no
      // descartable mientras el foreground service esté activo.
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidShowNotificationBadge: true,
    ),
  );
}
