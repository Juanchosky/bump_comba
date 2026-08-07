import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'network_quality_service.dart';
import 'performance_service.dart';

/// Perfiles de buffer y decoder para cada nivel de calidad.
/// Estos se aplican dinámicamente a MPV cuando la red cambia.
class AdaptiveBufferConfig {
  final String name;

  // Buffer
  final int cacheSecs;
  final int demuxerMaxBytes; // bytes
  final int demuxerMaxBackBytes; // bytes
  final int streamBufferSize; // bytes
  final int demuxerReadaheadSecs;
  final String cachePauseWait; // segundos que MPV espera antes de pausar

  // Decoder — sacrificar calidad para ahorrar CPU y ancho de banda
  final String hwdec;
  final String skipLoopFilter; // none, nonref, bidir, nonkey, all
  final String framedrop; // no, vo, decoder, decoder+vo
  final bool fastDecoding;
  final String videoSync; // audio, display-resample, etc.

  // Red
  final int networkTimeout;
  final String reconnectSleep;
  final bool httpPipelining;

  // Extra
  final bool
  dropNonRefFrames; // Si true, solo decodifica keyframes (modo emergencia)
  final String? hlsBitrate; // auto, min, max o un valor numérico

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
    demuxerMaxBytes: 268435456, // 256 MB
    demuxerMaxBackBytes: 67108864, // 64 MB
    streamBufferSize: 16777216, // 16 MB
    demuxerReadaheadSecs: 180,
    cachePauseWait: '2',
    hwdec: 'mediacodec', // Zero-copy, máxima eficiencia
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
    demuxerMaxBytes: 134217728, // 128 MB
    demuxerMaxBackBytes: 33554432, // 32 MB
    streamBufferSize: 8388608, // 8 MB
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
    demuxerMaxBytes: 52428800, // 50 MB — conservamos RAM
    demuxerMaxBackBytes: 10485760, // 10 MB
    streamBufferSize: 4194304, // 4 MB
    demuxerReadaheadSecs: 30,
    cachePauseWait: '5', // Esperar 5s antes de pausar para acumular buffer
    hwdec: 'mediacodec-copy', // Más estable en dispositivos mid-range
    skipLoopFilter:
        'nonref', // Saltar filtro en frames no-referencia → -20% CPU
    framedrop: 'decoder+vo', // Drop agresivo para mantener sync
    fastDecoding: true,
    videoSync: 'audio',
    networkTimeout: 30,
    reconnectSleep: '1',
    httpPipelining: false, // Desactivar para conexiones inestables
    hlsBitrate: 'min', // HLS: usar el segmento de menor calidad
  );

  static const AdaptiveBufferConfig _poor = AdaptiveBufferConfig(
    name: 'Poor — Emergency Mode',
    cacheSecs: 60,
    demuxerMaxBytes: 20971520, // 20 MB — mínimo viable
    demuxerMaxBackBytes: 4194304, // 4 MB
    streamBufferSize: 2097152, // 2 MB
    demuxerReadaheadSecs: 10,
    cachePauseWait: '8', // Acumular más buffer antes de reproducir
    hwdec: 'mediacodec-copy',
    skipLoopFilter: 'nonkey', // Solo decodificar keyframes referencia
    framedrop: 'decoder+vo',
    fastDecoding: true,
    videoSync: 'audio',
    networkTimeout: 20,
    reconnectSleep: '2',
    httpPipelining: false,
    dropNonRefFrames: true, // Modo de emergencia: solo keyframes
    hlsBitrate: 'min',
  );

  void resetState() {}

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
  Future<void> applyConfig(
    dynamic mpv,
    NetworkQuality quality, {
    bool isLive = false,
  }) async {
    if (mpv == null) return;

    // ── LIVE: perfil RESILIENTE al jitter (no data-saver) ────────────────────
    // La TV en vivo es un stream de bitrate único (.ts/HLS sin escalera ABR):
    // no se puede "bajar de calidad", así que el único remedio real contra el
    // jitter de datos móviles es un buffer amplio y un decoder estable.
    // Los perfiles VOD degradados hacían lo contrario (encoger buffer a 5-20s +
    // decodificar solo keyframes), lo que provoca justo el síntoma clásico:
    // cortes cada 1-3s y pantalla en negro. Por eso el live tiene su propia
    // ruta, que AUMENTA la colchoneta cuando la red flaquea en lugar de recortarla.
    if (isLive) {
      await _applyLiveResilientConfig(mpv, quality);
      return;
    }

    final cfg = getConfig(quality);

    debugPrint('AdaptiveBuffer: Applying profile "${cfg.name}"');

    // ── VOD: el buffer NUNCA se encoge por red débil ────────────────────────
    // Una película es un archivo único sin variantes de calidad: la ÚNICA
    // defensa contra cortes (túneles, ascensores, señal fluctuante en datos
    // móviles) es acumular MÁS buffer mientras hay señal. Los perfiles
    // "data saver" que reducían cache/readahead eran contraproducentes.
    // Piso = perfil normal (180s / 128MB / readahead 90s); la gama baja
    // mantiene su tope de RAM (~64MB) para no provocar GC/ANR.
    final bool lowMem = PerformanceService().lowMemoryLimit;
    final int cacheSecs = lowMem ? 90 : math.max(cfg.cacheSecs, 180);
    final int maxBytes =
        lowMem ? 67108864 : math.max(cfg.demuxerMaxBytes, 134217728);
    final int backBytes =
        lowMem ? 16777216 : math.max(cfg.demuxerMaxBackBytes, 33554432);
    final int readahead = lowMem ? 60 : math.max(cfg.demuxerReadaheadSecs, 90);
    final int streamBuf = math.max(cfg.streamBufferSize, 8388608);

    try {
      // Buffer (con piso VOD — ver bloque de arriba)
      await mpv.setProperty('cache-secs', cacheSecs.toString());
      await mpv.setProperty('demuxer-max-bytes', maxBytes.toString());
      await mpv.setProperty('demuxer-max-back-bytes', backBytes.toString());
      await mpv.setProperty('stream-buffer-size', streamBuf.toString());
      await mpv.setProperty('demuxer-readahead-secs', readahead.toString());
      await mpv.setProperty('cache-pause-wait', cfg.cachePauseWait);

      // ── Decoder — hardware-safe en Android E iOS ───────────────────────────
      // En Android el decoder es mediacodec y en iOS es videotoolbox (AMBOS
      // hardware) y NO se debe:
      //  (a) cambiar 'hwdec' EN CALIENTE → fuerza reinicio del decoder =
      //      parpadeo negro/stutter cada vez que la red cambia a mitad de peli.
      //      El hwdec correcto ya se fijó al abrir el media (según gama/reintento).
      //  (b) enviar skiploopfilter/skip_frame 'nonref' → argumento inválido para
      //      el codec HW → error de stream → recarga → pantalla negra.
      //  (c) usar framedrop 'decoder' → drops a nivel de codec HW = stutter.
      // Estas optimizaciones de CPU solo son válidas y útiles en decoders de
      // software (desktop), así que las aplicamos únicamente allí. (Antes iOS
      // caía en la rama "software" y recibía nonref/nonkey con videotoolbox →
      // error de stream → reload, justo cuando la red estaba débil.)
      final bool hwDecoder =
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);

      if (hwDecoder) {
        // hwdec: NO se toca en caliente (evita reinicio del decoder).
        await mpv.setProperty('vd-lavc-skiploopfilter', 'none');
        await mpv.setProperty(
          'framedrop',
          'vo',
        ); // solo en pantalla, nunca en el codec
        await mpv.setProperty(
          'vd-lavc-o',
          'err_detect=ignore_err,flags2=+fast',
        );
      } else {
        await mpv.setProperty('vd-lavc-skiploopfilter', cfg.skipLoopFilter);
        await mpv.setProperty('framedrop', cfg.framedrop);
        // Modo emergencia (solo software): decodificar casi solo keyframes.
        if (cfg.dropNonRefFrames) {
          await mpv.setProperty(
            'vd-lavc-o',
            'err_detect=ignore_err,flags2=+fast,skip_frame=nonref',
          );
        } else {
          await mpv.setProperty(
            'vd-lavc-o',
            'err_detect=ignore_err,flags2=+fast',
          );
        }
      }
      await mpv.setProperty(
        'vd-lavc-fast-decoding',
        cfg.fastDecoding ? 'yes' : 'no',
      );
      await mpv.setProperty('video-sync', cfg.videoSync);

      // Red
      await mpv.setProperty('network-timeout', cfg.networkTimeout.toString());
      await mpv.setProperty('http-reconnect-sleep', cfg.reconnectSleep);
      await mpv.setProperty(
        'http-pipelining',
        cfg.httpPipelining ? 'yes' : 'no',
      );

      // HLS bitrate selection (solo para streams HLS)
      if (cfg.hlsBitrate != null) {
        await mpv.setProperty('hls-bitrate', cfg.hlsBitrate!);
      }
    } catch (e) {
      debugPrint('AdaptiveBuffer: Error applying config: $e');
    }
  }

  /// Perfil de buffer para TV EN VIVO, diseñado para absorber el jitter de
  /// datos móviles sin cortes. Regla de oro: cuando la red flaquea NO se
  /// reduce el buffer — se AMPLÍA la colchoneta de tiempo y se sube el umbral
  /// de reanudación para no caer en el ciclo pausa-1s→reproduce-1s (thrash).
  /// Además, el decoder se mantiene 100% seguro para hardware (mediacodec):
  /// jamás keyframe-only ni skiploopfilter 'nonref', que en Android generan
  /// error de stream → recarga → pantalla negra.
  Future<void> _applyLiveResilientConfig(
    dynamic mpv,
    NetworkQuality quality,
  ) async {
    final bool weak =
        quality == NetworkQuality.poor ||
        quality == NetworkQuality.fair ||
        quality == NetworkQuality.offline;

    debugPrint(
      'AdaptiveBuffer: Applying LIVE-resilient profile '
      '(${quality.name}${weak ? ' → colchón ampliado' : ''})',
    );

    try {
      // ── Buffer: piso alto SIEMPRE; más colchón de tiempo si la red es débil ──
      await mpv.setProperty('cache', 'yes');
      await mpv.setProperty('cache-secs', weak ? '240' : '180');
      await mpv.setProperty('demuxer-max-bytes', '134217728'); // 128 MB fijo
      await mpv.setProperty('demuxer-max-back-bytes', '33554432'); // 32 MB
      // Colchón de tiempo GRANDE en red débil para absorber el jitter (NO 5-10s).
      await mpv.setProperty('demuxer-readahead-secs', weak ? '60' : '40');
      await mpv.setProperty('stream-buffer-size', '8388608'); // 8 MB

      // ── Reanudación tras vaciado: esperar un colchón SANO antes de volver a
      // reproducir para romper el thrash. Más alto en red débil. ──────────────
      await mpv.setProperty('cache-pause', 'yes');
      await mpv.setProperty('cache-pause-wait', weak ? '4' : '3');

      // ── Decoder: hardware-safe SIEMPRE ──────────────────────────────────────
      // En Android (mediacodec) e iOS (videotoolbox) el loop-filter y el drop
      // de frames los hace el propio codec. Enviar skiploopfilter/skip_frame
      // 'nonref' genera un argumento inválido → error de stream → recarga →
      // pantalla negra. Solo en decoders de software (desktop) se puede
      // ahorrar CPU con el loop filter.
      final bool hwDecoder =
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      if (hwDecoder) {
        await mpv.setProperty('vd-lavc-skiploopfilter', 'none');
      } else {
        // En decoders de software sí podemos ahorrar CPU con el loop filter.
        await mpv.setProperty(
          'vd-lavc-skiploopfilter',
          weak ? 'nonref' : 'none',
        );
      }
      // framedrop=vo descarta solo en pantalla (nunca en el decoder) → no
      // desincroniza ni provoca flushes del codec por hardware.
      await mpv.setProperty('framedrop', 'vo');
      await mpv.setProperty('vd-lavc-fast-decoding', 'yes');
      await mpv.setProperty('vd-lavc-o', 'err_detect=ignore_err,flags2=+fast');
      await mpv.setProperty('video-sync', 'audio');

      // ── Red: timeouts GENEROSOS para live en móvil. Un pico de latencia
      // normal en 4G no debe disparar una reconexión prematura. ───────────────
      await mpv.setProperty('network-timeout', weak ? '30' : '20');
      await mpv.setProperty('http-reconnect', 'yes');
      await mpv.setProperty('http-reconnect-sleep', '0.5');
      // HLS: mantener 'auto'. 'min' fuerza la peor calidad sin necesidad y para
      // .ts crudo (Xtream) no aplica.
      await mpv.setProperty('hls-bitrate', 'auto');
    } catch (e) {
      debugPrint('AdaptiveBuffer: Error applying LIVE-resilient config: $e');
    }
  }
}
