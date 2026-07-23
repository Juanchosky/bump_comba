import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Proxy TURBO local para VOD sobre HTTP.
///
/// Problema que resuelve: los servidores IPTV/M3U saturados suelen limitar la
/// velocidad POR CONEXIÓN. MPV descarga con UNA sola conexión, así que aunque
/// la red dé para más, el stream llega a cuentagotas y la reproducción se
/// detiene a re-bufferear constantemente.
///
/// Solución (la misma técnica de un gestor de descargas): un servidor HTTP en
/// 127.0.0.1 que descarga el archivo en TROZOS con VARIAS conexiones paralelas
/// al servidor de origen y se los sirve en orden a MPV. Con 4 conexiones, un
/// servidor que limita a 2 Mbps por conexión entrega ~8 Mbps.
///
/// Seguridad de uso:
///  - Solo se activa si el origen soporta rangos (respuesta 206 verificada).
///  - Live/HLS (.m3u8, /live/) nunca se proxean (no aplica el troceo).
///  - Ante cualquier fallo, [wrap] devuelve null y el caller usa la URL
///    original — comportamiento idéntico al actual.
class TurboProxy {
  TurboProxy._();
  static final TurboProxy instance = TurboProxy._();

  static const int _chunkSize = 2 * 1024 * 1024; // 2 MB por trozo
  static const int _parallel = 4; // conexiones simultáneas al origen
  static const int _windowChunks = 16; // ~32 MB de ventana por delante

  HttpServer? _server;
  final Map<String, _Entry> _entries = {};
  int _nextId = 1;

  Future<void> _ensureServer() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(
      (req) {
        // Cada petición se maneja aislada; un error no tumba el proxy.
        unawaited(_handle(req));
      },
      onError: (e) => debugPrint('TurboProxy: server error: $e'),
    );
    debugPrint('TurboProxy: escuchando en 127.0.0.1:${_server!.port}');
  }

  /// Intenta envolver [url] tras el proxy turbo. Devuelve la URL local
  /// (`http://127.0.0.1:PORT/t/ID`) o `null` si el origen no es apto
  /// (live/HLS, sin soporte de rangos, error de red...).
  Future<String?> wrap(String url, Map<String, String>? headers) async {
    try {
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        return null;
      }
      final low = url.toLowerCase();
      if (low.contains('.m3u8') ||
          low.contains('output=m3u8') ||
          low.contains('/live/')) {
        return null;
      }

      await _ensureServer();

      // Sondeo: pedimos 2 bytes con Range. Solo si el servidor responde 206
      // con longitud total conocida vale la pena trocear.
      final probe = await _probe(url, headers);
      if (probe == null) return null;

      final id = '${_nextId++}';
      final client = HttpClient()
        ..autoUncompress = false
        ..maxConnectionsPerHost = _parallel + 1
        ..connectionTimeout = const Duration(seconds: 10)
        ..badCertificateCallback = (_, _, _) => true;

      _entries[id] = _Entry(
        url: url,
        headers: headers ?? const {},
        length: probe.$1,
        contentType: probe.$2,
        client: client,
      );

      // Mantener pocas entradas vivas (cada una tiene su HttpClient).
      if (_entries.length > 4) {
        final oldest = _entries.keys.first;
        _entries.remove(oldest)?.client.close(force: true);
      }

      final local = 'http://127.0.0.1:${_server!.port}/t/$id';
      debugPrint(
        'TurboProxy: activo para $url '
        '(${(probe.$1 / 1048576).toStringAsFixed(1)} MB) → $local',
      );
      return local;
    } catch (e) {
      debugPrint('TurboProxy: wrap falló ($e) — usando URL directa');
      return null;
    }
  }

  /// Devuelve (longitud total, content-type) o null si no hay soporte Range.
  Future<(int, String?)?> _probe(String url, Map<String, String>? headers) async {
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 6)
      ..badCertificateCallback = (_, _, _) => true;
    try {
      final rq = await client.getUrl(Uri.parse(url));
      headers?.forEach((k, v) => rq.headers.set(k, v));
      rq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
      final rs = await rq.close().timeout(const Duration(seconds: 6));
      // Drenar los 2 bytes para liberar la conexión.
      await rs.drain<void>().catchError((_) {});
      if (rs.statusCode != HttpStatus.partialContent) return null;
      final cr = rs.headers.value(HttpHeaders.contentRangeHeader);
      if (cr == null) return null;
      // Formato: "bytes 0-1/123456"
      final slash = cr.lastIndexOf('/');
      if (slash == -1) return null;
      final total = int.tryParse(cr.substring(slash + 1).trim());
      if (total == null || total <= 0) return null;
      return (total, rs.headers.contentType?.mimeType);
    } catch (e) {
      debugPrint('TurboProxy: probe falló: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final segments = req.uri.pathSegments;
      final entry =
          (segments.length == 2 && segments[0] == 't')
              ? _entries[segments[1]]
              : null;
      if (entry == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      await _serve(req, entry);
    } catch (e) {
      debugPrint('TurboProxy: error sirviendo petición: $e');
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serve(HttpRequest req, _Entry e) async {
    // Parsear "Range: bytes=START-" de MPV (los seeks llegan así).
    int start = 0;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final m = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
      if (m != null) start = int.parse(m.group(1)!);
    }
    if (start >= e.length) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await req.response.close();
      return;
    }

    final resp = req.response;
    resp.bufferOutput = false;
    if (rangeHeader != null) {
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${e.length - 1}/${e.length}',
      );
    } else {
      resp.statusCode = HttpStatus.ok;
    }
    resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (e.contentType != null) {
      resp.headers.set(HttpHeaders.contentTypeHeader, e.contentType!);
    }
    resp.contentLength = e.length - start;

    // CRÍTICO: enviar la línea de estado + headers AL INSTANTE, antes de
    // empezar a descargar. Si esperamos al primer trozo (que con servidores
    // que cortan conexiones puede tardar bastante), MPV agota su timeout de
    // "abrir stream" y reporta "Failed to open" aunque el proxy acabe
    // entregando datos. Con los headers ya enviados, MPV entra en estado
    // "conectado, buffering" y espera pacientemente (spinner) los datos.
    try {
      await resp.flush();
    } catch (_) {
      return; // el cliente ya se fue
    }

    final pipeline = _Pipeline(e, start);
    var closed = false;
    // Si MPV cierra la conexión (seek, stop), cancelamos las descargas.
    unawaited(
      resp.done.then((_) => closed = true).catchError((_) => closed = true),
    );

    try {
      while (!closed) {
        final data = await pipeline.next();
        if (data == null) break; // fin del archivo
        if (closed) break;
        resp.add(data);
        await resp.flush();
      }
    } catch (e2) {
      debugPrint('TurboProxy: stream interrumpido: $e2');
    } finally {
      pipeline.cancel();
      try {
        await resp.close();
      } catch (_) {}
    }
  }
}

class _Entry {
  final String url;
  final Map<String, String> headers;
  final int length;
  final String? contentType;
  final HttpClient client;
  _Entry({
    required this.url,
    required this.headers,
    required this.length,
    required this.contentType,
    required this.client,
  });

  // ── Paralelismo ADAPTATIVO ──
  // Algunos servidores (protección anti-multi-conexión) cortan las conexiones
  // a mitad de descarga cuando hay varias en paralelo. Si acumulamos fallos,
  // reducimos 4 → 2 → 1 conexiones. Con 1 quedamos igual que la descarga
  // directa de MPV (nunca peor).
  int parallel = TurboProxy._parallel;
  int _failures = 0;

  void noteFailure() {
    _failures++;
    if (_failures == 4 && parallel > 2) {
      parallel = 2;
      debugPrint(
        'TurboProxy: el servidor corta conexiones — bajando a 2 paralelas',
      );
    } else if (_failures == 10 && parallel > 1) {
      parallel = 1;
      debugPrint(
        'TurboProxy: el servidor sigue cortando — bajando a 1 conexión',
      );
    }
  }
}

/// Descarga trozos en paralelo por delante de la posición servida y los
/// entrega EN ORDEN. Ventana limitada para acotar memoria (~32 MB).
class _Pipeline {
  final _Entry e;
  final int startOffset;
  bool _cancelled = false;

  late final int _firstChunk = startOffset ~/ TurboProxy._chunkSize;
  late final int _totalChunks =
      (e.length + TurboProxy._chunkSize - 1) ~/ TurboProxy._chunkSize;

  int _serving = 0; // índice relativo del próximo trozo a entregar
  int _scheduled = 0; // cuántos trozos hemos lanzado a descargar
  int _active = 0;
  final Map<int, Completer<Uint8List>> _chunks = {};

  _Pipeline(this.e, this.startOffset) {
    _pump();
  }

  void _pump() {
    while (!_cancelled &&
        _active < e.parallel &&
        _scheduled - _serving < TurboProxy._windowChunks &&
        _firstChunk + _scheduled < _totalChunks) {
      final rel = _scheduled++;
      final completer = Completer<Uint8List>();
      // Evita "unhandled exception" si el trozo falla cuando ya nadie lo
      // espera (p. ej. tras cancel por un seek). El await de next() sigue
      // recibiendo el resultado normalmente.
      completer.future.ignore();
      _chunks[rel] = completer;
      _active++;
      unawaited(
        _fetchChunk(_firstChunk + rel)
            .then((bytes) {
              if (!completer.isCompleted) completer.complete(bytes);
            })
            .catchError((Object err) {
              if (!completer.isCompleted) completer.completeError(err);
            })
            .whenComplete(() {
              _active--;
              _pump();
            }),
      );
    }
  }

  /// Siguiente bloque en orden, o null al llegar al final.
  Future<Uint8List?> next() async {
    if (_cancelled) return null;
    if (_firstChunk + _serving >= _totalChunks) return null;
    final completer = _chunks[_serving];
    if (completer == null) {
      // No debería pasar; re-lanzar la bomba por si la ventana quedó vacía.
      _pump();
      if (_chunks[_serving] == null) return null;
    }
    final bytes = await _chunks[_serving]!.future;
    _chunks.remove(_serving);
    final isFirst = _serving == 0;
    _serving++;
    _pump();
    // El primer trozo puede empezar a mitad de chunk (seek de MPV).
    if (isFirst) {
      final skip = startOffset - _firstChunk * TurboProxy._chunkSize;
      if (skip > 0) return Uint8List.sublistView(bytes, skip);
    }
    return bytes;
  }

  Future<Uint8List> _fetchChunk(int index) async {
    final startB = index * TurboProxy._chunkSize;
    final endB = math.min(startB + TurboProxy._chunkSize, e.length) - 1;
    final expected = endB - startB + 1;

    // Acumulador PERSISTENTE entre intentos: si el servidor corta la conexión
    // a mitad de trozo (común en servidores con anti-multi-conexión), el
    // siguiente intento REANUDA desde el byte donde se quedó en vez de
    // descargar el trozo entero de nuevo.
    final builder = BytesBuilder(copy: false);
    int got = 0;
    Object? lastErr;

    for (int attempt = 0; attempt < 6 && !_cancelled; attempt++) {
      try {
        final rq = await e.client.getUrl(Uri.parse(e.url));
        e.headers.forEach((k, v) => rq.headers.set(k, v));
        rq.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=${startB + got}-$endB',
        );
        final rs = await rq.close().timeout(const Duration(seconds: 20));
        if (rs.statusCode != HttpStatus.partialContent) {
          await rs.drain<void>().catchError((_) {});
          throw HttpException('status ${rs.statusCode} (esperaba 206)');
        }
        await for (final part in rs.timeout(const Duration(seconds: 25))) {
          builder.add(part);
          got += part.length;
          if (_cancelled) throw const HttpException('cancelado');
        }
        if (got >= expected) break; // trozo completo
        // Conexión cerrada a mitad sin excepción: reintentar (reanudando).
        lastErr = HttpException('parcial $got/$expected');
        e.noteFailure();
      } catch (err) {
        lastErr = err;
        e.noteFailure();
        if (_cancelled) break;
        await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
      if (got >= expected) break;
    }

    if (got >= expected) {
      final bytes = builder.takeBytes();
      // Por seguridad ante servidores que envían de más: recortar exacto.
      return bytes.length == expected
          ? bytes
          : Uint8List.sublistView(bytes, 0, expected);
    }
    throw HttpException('chunk $index falló: $lastErr');
  }

  void cancel() {
    _cancelled = true;
    // Completar los pendientes con error para soltar a quien espere.
    for (final c in _chunks.values) {
      if (!c.isCompleted) {
        c.completeError(const HttpException('pipeline cancelado'));
      }
    }
    _chunks.clear();
  }
}
