import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'tv_protocol.dart';

/// Cliente emisor que corre en el TELÉFONO. Abre un WebSocket contra el
/// receptor propio (la misma app corriendo en el TV), envía comandos y recibe
/// eventos de estado.
///
/// Esta clase se ocupa SOLO del transporte de una conexión. La reconexión
/// persistente con backoff (error crítico #5) se orquesta desde
/// [CastService] en la Fase 3; aquí exponemos [onClosed] para que el
/// orquestador reaccione a las caídas.
class TvSender {
  WebSocket? _socket;
  StreamSubscription? _sub;

  /// Callback por cada evento recibido del TV (ya decodificado, con `type`).
  final void Function(Map<String, dynamic> event) onEvent;

  /// Callback cuando el socket se cierra o falla (para reconexión).
  final void Function()? onClosed;

  bool _closedByUs = false;

  TvSender({required this.onEvent, this.onClosed});

  bool get isConnected => _socket != null;

  /// Conecta a `ws://host:port/cast`. Devuelve `true` si el handshake TCP/WS
  /// tuvo éxito. Lanza/atrapa internamente; nunca propaga.
  Future<bool> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    _closedByUs = false;
    try {
      final uri = 'ws://$host:$port${TvProto.wsPath}';
      _socket = await WebSocket.connect(uri).timeout(timeout);
      _sub = _socket!.listen(
        (data) {
          final event = TvMessage.decode(data);
          if (event != null) {
            try {
              onEvent(event);
            } catch (e) {
              debugPrint('TvSender: error en onEvent: $e');
            }
          }
        },
        onDone: _handleClosed,
        onError: (e) {
          debugPrint('TvSender: error del socket: $e');
          _handleClosed();
        },
        cancelOnError: true,
      );
      debugPrint('TvSender: conectado a $uri');
      return true;
    } catch (e) {
      debugPrint('TvSender: fallo al conectar a $host:$port — $e');
      _socket = null;
      return false;
    }
  }

  void _handleClosed() {
    _sub?.cancel();
    _sub = null;
    _socket = null;
    if (!_closedByUs) {
      onClosed?.call();
    }
  }

  // ─────────────────────────── Envío de comandos ────────────────────────────

  void _send(String type, [Map<String, dynamic>? data]) {
    final socket = _socket;
    if (socket == null) return;
    try {
      final encoded = TvMessage.encode(TvMessage.build(type, data));
      if (encoded != null) socket.add(encoded);
    } catch (e) {
      debugPrint('TvSender: error enviando $type: $e');
    }
  }

  void load({
    required String url,
    required String title,
    double position = 0.0,
    Map<String, String>? headers,
    String? thumbnailUrl,
    String? seriesName,
    int? season,
    int? episode,
  }) {
    _send(TvProto.cmdLoad, {
      'url': url,
      'title': title,
      'position': position,
      if (headers != null) 'headers': headers,
      if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
      if (seriesName != null) 'seriesName': seriesName,
      if (season != null) 'season': season,
      if (episode != null) 'episode': episode,
    });
  }

  void play() => _send(TvProto.cmdPlay);
  void pause() => _send(TvProto.cmdPause);
  void seek(double positionSeconds) =>
      _send(TvProto.cmdSeek, {'position': positionSeconds});
  void stop() => _send(TvProto.cmdStop);
  void setAudio(String trackId) => _send(TvProto.cmdSetAudio, {'trackId': trackId});
  void setSubtitle(String trackId) =>
      _send(TvProto.cmdSetSubtitle, {'trackId': trackId});
  void ping() =>
      _send(TvProto.cmdPing, {'t': DateTime.now().millisecondsSinceEpoch});
  void getTracks() => _send(TvProto.cmdGetTracks);

  /// Cierra la conexión intencionalmente (no dispara [onClosed]).
  Future<void> close() async {
    _closedByUs = true;
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }
}
