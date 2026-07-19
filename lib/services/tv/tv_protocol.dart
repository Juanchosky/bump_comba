/// Protocolo compartido entre el EMISOR (teléfono) y el RECEPTOR (TV) de
/// Bump Comba. Es un protocolo JSON simple sobre WebSocket.
///
/// La MISMA app instalada en un Android TV / Google TV / Fire TV actúa como
/// receptor propio y reproduce con el mismo motor `media_kit`/MPV que el
/// teléfono. Esto permite MKV, audio AC3/DTS y cambio de idioma sin las
/// limitaciones del Chromecast.
///
/// Tanto el emisor como el receptor importan este archivo, de modo que las
/// constantes de comandos/eventos y las claves JSON nunca se desincronicen.
library;

import 'dart:convert';

/// Constantes de descubrimiento y transporte.
class TvProto {
  TvProto._();

  /// Tipo de servicio mDNS con el que el TV se anuncia y el teléfono busca.
  /// Debe ser único para esta app (no `_googlecast._tcp`).
  static const String serviceType = '_bumpcombatv._tcp';

  /// Puerto FIJO del WebSocket del receptor. Fijo (no efímero) para que el
  /// sondeo TCP directo funcione aunque el mDNS falle.
  static const int port = 7345;

  /// Ruta del endpoint WebSocket dentro del HttpServer del receptor.
  static const String wsPath = '/cast';

  /// Clave común: todos los mensajes JSON llevan un campo `type`.
  static const String kType = 'type';

  // ─────────────────────────── Comandos EMISOR → TV ──────────────────────────

  /// Cargar y reproducir un medio.
  /// Payload: url, title, position (segundos), headers (Map), seriesName,
  /// season, episode.
  static const String cmdLoad = 'LOAD';

  /// Reanudar reproducción.
  static const String cmdPlay = 'PLAY';

  /// Pausar reproducción.
  static const String cmdPause = 'PAUSE';

  /// Buscar a una posición. Payload: position (segundos).
  static const String cmdSeek = 'SEEK';

  /// Detener reproducción y volver a la pantalla de espera.
  static const String cmdStop = 'STOP';

  /// Seleccionar pista de audio. Payload: trackId (String id de media_kit).
  static const String cmdSetAudio = 'SET_AUDIO';

  /// Seleccionar/desactivar subtítulos. Payload: trackId (String id) | 'off'.
  static const String cmdSetSubtitle = 'SET_SUBTITLE';

  /// Keepalive del socket. Payload: t (timestamp ms).
  static const String cmdPing = 'PING';

  // ─────────────────────────── Eventos TV → EMISOR ───────────────────────────

  /// Handshake inicial que el TV envía al conectar. Payload: name (nombre del
  /// dispositivo).
  static const String evtHello = 'HELLO';

  /// Estado de reproducción periódico (~2/s). Payload: state, position,
  /// duration, playing, bufferPercent.
  static const String evtStatus = 'STATUS';

  /// Lista de pistas de audio disponibles. Payload: tracks (List<Map>).
  static const String evtAudioTracks = 'AUDIO_TRACKS';

  /// Lista de subtítulos disponibles. Payload: tracks (List<Map>).
  static const String evtSubtitleTracks = 'SUBTITLE_TRACKS';

  /// Media cargado correctamente. Payload: duration (segundos).
  static const String evtLoaded = 'LOADED';

  /// Falló la carga del medio. Payload: error (String opcional).
  static const String evtLoadFailed = 'LOAD_FAILED';

  /// La reproducción llegó al final.
  static const String evtEnded = 'ENDED';

  /// Respuesta al PING. Payload: t (echo del timestamp).
  static const String evtPong = 'PONG';

  // ─────────────────────────── Valores del campo `state` ─────────────────────

  static const String stateIdle = 'IDLE';
  static const String statePlaying = 'PLAYING';
  static const String statePaused = 'PAUSED';
  static const String stateBuffering = 'BUFFERING';
  static const String stateEnded = 'ENDED';

  /// Valor especial de trackId para desactivar subtítulos.
  static const String subtitleOff = 'off';
}

/// Un mensaje del protocolo. Es un simple `Map<String, dynamic>` con la clave
/// `type` obligatoria y un payload arbitrario. Estas utilidades garantizan que
/// ambos lados serialicen/parseen igual y de forma tolerante a errores.
class TvMessage {
  /// Construye un mapa de mensaje con `type` y campos adicionales.
  static Map<String, dynamic> build(String type, [Map<String, dynamic>? data]) {
    return <String, dynamic>{TvProto.kType: type, if (data != null) ...data};
  }

  /// Serializa un mensaje a texto JSON. Nunca lanza; devuelve `null` si falla.
  static String? encode(Map<String, dynamic> message) {
    try {
      return jsonEncode(message);
    } catch (_) {
      return null;
    }
  }

  /// Parsea texto JSON a un mapa de mensaje. Devuelve `null` si no es un objeto
  /// JSON válido con clave `type`.
  static Map<String, dynamic>? decode(dynamic raw) {
    try {
      if (raw is! String) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded[TvProto.kType] is String) {
        return decoded;
      }
      if (decoded is Map && decoded[TvProto.kType] is String) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
