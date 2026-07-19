import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import 'tv_protocol.dart';

/// Servicio singleton que corre en el TV (receptor propio).
///
/// Responsabilidades:
///  - Levantar un [HttpServer] (dart:io) que hace upgrade a WebSocket en
///    [TvProto.wsPath], con REINTENTOS de bind al puerto fijo.
///  - Anunciarse por mDNS con `bonsoir` ([BonsoirBroadcast]) usando
///    [TvProto.serviceType].
///  - Aceptar UN cliente (teléfono) a la vez.
///  - Exponer los comandos entrantes como [commands] (`Stream<Map>`).
///  - Reenviar eventos de estado al teléfono con [sendEvent].
///
/// La pantalla receptora ([TvReceiverScreen]) es dueña del [Player] de
/// media_kit y consume este servicio: escucha [commands] y usa [sendEvent].
class TvReceiverService {
  TvReceiverService._();
  static final TvReceiverService _instance = TvReceiverService._();
  factory TvReceiverService() => _instance;

  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  WebSocket? _client;

  final StreamController<Map<String, dynamic>> _commandController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream de comandos entrantes del teléfono (ya decodificados). Cada mapa
  /// incluye la clave `type` con uno de los `TvProto.cmd*`.
  Stream<Map<String, dynamic>> get commands => _commandController.stream;

  /// Indica si hay un teléfono conectado actualmente.
  final ValueNotifier<bool> hasClient = ValueNotifier<bool>(false);

  /// Nombre legible del dispositivo, usado en el handshake HELLO y en la
  /// pantalla de espera.
  String deviceName = 'Bump Comba TV';

  bool _running = false;
  bool get isRunning => _running;

  /// Arranca el servidor y el anuncio mDNS. Idempotente.
  Future<void> start({String? name}) async {
    if (_running) return;
    if (name != null && name.trim().isNotEmpty) deviceName = name.trim();

    try {
      await _bindWithRetries();
      _serveConnections();
      await _startBroadcast();
      _running = true;
      debugPrint(
        'TvReceiver: escuchando en puerto ${TvProto.port}, '
        'anunciando "$deviceName" (${TvProto.serviceType})',
      );
    } catch (e) {
      debugPrint('TvReceiver: fallo al arrancar: $e');
      await stop();
      rethrow;
    }
  }

  /// Bind al puerto FIJO con reintentos.
  ///
  /// Si el proceso se reinició, el socket anterior tarda 1-2s en liberarse.
  /// NO caemos a un puerto efímero: eso desincronizaría el mDNS (el teléfono
  /// espera siempre [TvProto.port]).
  Future<void> _bindWithRetries() async {
    const maxAttempts = 20;
    Object? lastError;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        _server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          TvProto.port,
          shared: true,
        );
        return;
      } catch (e) {
        lastError = e;
        debugPrint(
          'TvReceiver: bind puerto ${TvProto.port} falló '
          '(intento $attempt/$maxAttempts): $e',
        );
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    throw Exception('No se pudo enlazar al puerto ${TvProto.port}: $lastError');
  }

  void _serveConnections() {
    _server!.listen(
      (HttpRequest request) async {
        try {
          if (request.uri.path != TvProto.wsPath ||
              !WebSocketTransformer.isUpgradeRequest(request)) {
            request.response.statusCode = HttpStatus.forbidden;
            await request.response.close();
            return;
          }
          final ws = await WebSocketTransformer.upgrade(request);
          _attachClient(ws);
        } catch (e) {
          debugPrint('TvReceiver: error en conexión entrante: $e');
        }
      },
      onError: (e) => debugPrint('TvReceiver: error en el servidor: $e'),
    );
  }

  /// Acepta UN cliente a la vez. Si ya hay uno, el nuevo lo reemplaza (el
  /// teléfono se reconectó tras una caída).
  void _attachClient(WebSocket ws) {
    debugPrint('TvReceiver: cliente conectado');
    try {
      _client?.close();
    } catch (_) {}
    _client = ws;
    hasClient.value = true;

    // Handshake: el TV se presenta.
    sendEvent(TvProto.evtHello, {'name': deviceName});

    ws.listen(
      (data) {
        final msg = TvMessage.decode(data);
        if (msg == null) return;
        try {
          _commandController.add(msg);
        } catch (e) {
          debugPrint('TvReceiver: error entregando comando: $e');
        }
      },
      onDone: () {
        debugPrint('TvReceiver: cliente desconectado');
        if (identical(_client, ws)) {
          _client = null;
          hasClient.value = false;
        }
      },
      onError: (e) {
        debugPrint('TvReceiver: error del socket cliente: $e');
        if (identical(_client, ws)) {
          _client = null;
          hasClient.value = false;
        }
      },
      cancelOnError: true,
    );
  }

  /// Envía un evento al teléfono. Silencioso si no hay cliente.
  void sendEvent(String type, [Map<String, dynamic>? data]) {
    final client = _client;
    if (client == null) return;
    try {
      final encoded = TvMessage.encode(TvMessage.build(type, data));
      if (encoded != null) client.add(encoded);
    } catch (e) {
      debugPrint('TvReceiver: error enviando evento $type: $e');
    }
  }

  Future<void> _startBroadcast() async {
    final service = BonsoirService(
      name: deviceName,
      type: TvProto.serviceType,
      port: TvProto.port,
    );
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.ready;
    await _broadcast!.start();
  }

  /// Detiene todo y libera el puerto. Idempotente.
  Future<void> stop() async {
    _running = false;
    try {
      await _broadcast?.stop();
    } catch (_) {}
    _broadcast = null;
    try {
      await _client?.close();
    } catch (_) {}
    _client = null;
    hasClient.value = false;
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }
}
