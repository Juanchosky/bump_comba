import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:bump_comba/services/cast_service.dart';

class CastAudioHandler extends BaseAudioHandler {
  final CastService _castService = CastService();
  Timer? _positionUpdateTimer;

  CastAudioHandler() {
    // Escuchar el estado de reproduccin (play/pause)
    _castService.castPlaying.addListener(_updatePlaybackState);

    // Escuchar la posicin para mantenerla sincronizada
    _castService.castPosition.addListener(_updatePlaybackState);

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

  void _updatePlaybackState() {
    if (!_castService.isConnected) return;

    final isPlaying = _castService.castPlaying.value;
    final position = _castService.castPosition.value;

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          isPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1],
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
      androidNotificationOngoing: true,
      androidStopForegroundOnPause:
          true, // Cambiado a true para evitar error de asercin
      androidShowNotificationBadge: true,
    ),
  );
}
