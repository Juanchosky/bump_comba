import 'package:flutter/foundation.dart';
import 'network_quality_service.dart';

/// Perfiles de buffer y decoder para cada nivel de calidad.
/// Estos se aplican dinámicamente a MPV cuando la red cambia.
class AdaptiveBufferConfig {
  final String name;

  // Buffer
  final int cacheSecs;
  final int demuxerMaxBytes;      // bytes
  final int demuxerMaxBackBytes;  // bytes
  final int streamBufferSize;     // bytes
  final int demuxerReadaheadSecs;
  final String cachePauseWait;    // segundos que MPV espera antes de pausar

  // Decoder — sacrificar calidad para ahorrar CPU y ancho de banda
  final String hwdec;
  final String skipLoopFilter;    // none, nonref, bidir, nonkey, all
  final String framedrop;         // no, vo, decoder, decoder+vo
  final bool fastDecoding;
  final String videoSync;         // audio, display-resample, etc.

  // Red
  final int networkTimeout;
  final String reconnectSleep;
  final bool httpPipelining;

  // Extra
  final bool dropNonRefFrames;    // Si true, solo decodifica keyframes (modo emergencia)
  final String? hlsBitrate;       // auto, min, max o un valor numérico

  const AdaptiveBufferConfig({
    required this.name,
    required this.cacheSecs,
    required this.demuxerMaxBytes,
    required this.demuxerMaxBackBytes,
    required this.streamBufferSize,
    required this.demuxerReadaheadSecs,
    required this.cachePauseWait,
    required this.hwdec,
    required this.skipLoopFilter,
    required this.framedrop,
    required this.fastDecoding,
    required this.videoSync,
    required this.networkTimeout,
    required this.reconnectSleep,
    required this.httpPipelining,
    this.dropNonRefFrames = false,
    this.hlsBitrate,
  });
}

class AdaptiveBufferService {
  static final AdaptiveBufferService _instance =
      AdaptiveBufferService._internal();
  factory AdaptiveBufferService() => _instance;
  AdaptiveBufferService._internal();

  // ── Perfiles ─────────────────────────────────────────────────────────────

  static const AdaptiveBufferConfig _excellent = AdaptiveBufferConfig(
    name: 'Excellent',
    cacheSecs: 300,
    demuxerMaxBytes: 268435456,    // 256 MB
    demuxerMaxBackBytes: 67108864, // 64 MB
    streamBufferSize: 16777216,    // 16 MB
    demuxerReadaheadSecs: 180,
    cachePauseWait: '2',
    hwdec: 'mediacodec',           // Zero-copy, máxima eficiencia
    skipLoopFilter: 'none',
    framedrop: 'vo',
    fastDecoding: true,
    videoSync: 'audio',
    networkTimeout: 60,
    reconnectSleep: '0.5',
    httpPipelining: true,
    hlsBitrate: 'max',
  );

  static const AdaptiveBufferConfig _good = AdaptiveBufferConfig(
    name: 'Good',
    cacheSecs: 180,
    demuxerMaxBytes: 134217728,    // 128 MB
    demuxerMaxBackBytes: 33554432, // 32 MB
    streamBufferSize: 8388608,     // 8 MB
    demuxerReadaheadSecs: 90,
    cachePauseWait: '3',
    hwdec: 'mediacodec',
    skipLoopFilter: 'none',
    framedrop: 'vo',
    fastDecoding: true,
    videoSync: 'audio',
    networkTimeout: 45,
    reconnectSleep: '0.5',
    httpPipelining: true,
    hlsBitrate: 'auto',
  );

  static const AdaptiveBufferConfig _fair = AdaptiveBufferConfig(
    name: 'Fair — Data Saver',
    cacheSecs: 90,
    demuxerMaxBytes: 52428800,     // 50 MB — conservamos RAM
    demuxerMaxBackBytes: 10485760, // 10 MB
    streamBufferSize: 4194304,     // 4 MB
    demuxerReadaheadSecs: 30,
    cachePauseWait: '5',           // Esperar 5s antes de pausar para acumular buffer
    hwdec: 'mediacodec-copy',      // Más estable en dispositivos mid-range
    skipLoopFilter: 'nonref',      // Saltar filtro en frames no-referencia → -20% CPU
    framedrop: 'decoder+vo',       // Drop agresivo para mantener sync
    fastDecoding: true,
    videoSync: 'audio',
    networkTimeout: 30,
    reconnectSleep: '1',
    httpPipelining: false,         // Desactivar para conexiones inestables
    hlsBitrate: 'min',             // HLS: usar el segmento de menor calidad
  );

  static const AdaptiveBufferConfig _poor = AdaptiveBufferConfig(
    name: 'Poor — Emergency Mode',
    cacheSecs: 60,
    demuxerMaxBytes: 20971520,     // 20 MB — mínimo viable
    demuxerMaxBackBytes: 4194304,  // 4 MB
    streamBufferSize: 2097152,     // 2 MB
    demuxerReadaheadSecs: 10,
    cachePauseWait: '8',           // Acumular más buffer antes de reproducir
    hwdec: 'mediacodec-copy',
    skipLoopFilter: 'nonkey',      // Solo decodificar keyframes referencia
    framedrop: 'decoder+vo',
    fastDecoding: true,
    videoSync: 'audio',
    networkTimeout: 20,
    reconnectSleep: '2',
    httpPipelining: false,
    dropNonRefFrames: true,        // Modo de emergencia: solo keyframes
    hlsBitrate: 'min',
  );

  AdaptiveBufferConfig getConfig(NetworkQuality quality) {
    switch (quality) {
      case NetworkQuality.excellent:
        return _excellent;
      case NetworkQuality.good:
        return _good;
      case NetworkQuality.fair:
        return _fair;
      case NetworkQuality.poor:
      case NetworkQuality.offline:
        return _poor;
    }
  }

  /// Aplica el perfil al player MPV dado.
  /// [mpv] es el `player.platform as dynamic` de media_kit.
  Future<void> applyConfig(dynamic mpv, NetworkQuality quality,
      {bool isLive = false}) async {
    if (mpv == null) return;
    final cfg = getConfig(quality);

    debugPrint('AdaptiveBuffer: Applying profile "${cfg.name}"');

    try {
      // Buffer
      await mpv.setProperty('cache-secs', cfg.cacheSecs.toString());
      await mpv.setProperty(
          'demuxer-max-bytes', cfg.demuxerMaxBytes.toString());
      await mpv.setProperty(
          'demuxer-max-back-bytes', cfg.demuxerMaxBackBytes.toString());
      await mpv.setProperty(
          'stream-buffer-size', cfg.streamBufferSize.toString());
      await mpv.setProperty(
          'demuxer-readahead-secs', cfg.demuxerReadaheadSecs.toString());
      await mpv.setProperty('cache-pause-wait', cfg.cachePauseWait);

      // Decoder
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        await mpv.setProperty('hwdec', cfg.hwdec);
      }
      await mpv.setProperty('vd-lavc-skiploopfilter', cfg.skipLoopFilter);
      await mpv.setProperty('framedrop', cfg.framedrop);
      await mpv.setProperty(
          'vd-lavc-fast-decoding', cfg.fastDecoding ? 'yes' : 'no');
      await mpv.setProperty('video-sync', cfg.videoSync);

      // Modo emergencia: solo decodificar keyframes
      if (cfg.dropNonRefFrames) {
        await mpv.setProperty(
            'vd-lavc-o', 'err_detect=ignore_err,flags2=+fast,skip_frame=nonref');
      } else {
        await mpv.setProperty(
            'vd-lavc-o', 'err_detect=ignore_err,flags2=+fast');
      }

      // Red
      await mpv.setProperty('network-timeout', cfg.networkTimeout.toString());
      await mpv.setProperty('http-reconnect-sleep', cfg.reconnectSleep);
      await mpv.setProperty(
          'http-pipelining', cfg.httpPipelining ? 'yes' : 'no');

      // HLS bitrate selection (solo para streams HLS)
      if (cfg.hlsBitrate != null) {
        await mpv.setProperty('hls-bitrate', cfg.hlsBitrate!);
      }

      // Si es live y la calidad es mala, usar menor latencia de buffer
      if (isLive && quality == NetworkQuality.poor) {
        await mpv.setProperty('cache-pause-wait', '3');
        await mpv.setProperty('demuxer-readahead-secs', '5');
      }
    } catch (e) {
      debugPrint('AdaptiveBuffer: Error applying config: $e');
    }
  }
}
