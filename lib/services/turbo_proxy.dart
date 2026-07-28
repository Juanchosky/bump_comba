import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../utils/dns_bypass_utils.dart';

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

  /// Hosts que ya demostraron NO soportar rangos en esta sesión. Se saltan el
  /// sondeo directamente (evita gastar segundos en cada contenido del mismo
  /// servidor sabiendo que la respuesta va a ser "no").
  final Set<String> _hostileHosts = {};

  // ── Diagnóstico ──
  // Sin esto se pierde muchísimo tiempo adivinando POR QUÉ el turbo no se
  // activa. [lastReason] guarda SIEMPRE el motivo exacto del último wrap().
  String _lastReason = 'sin usar todavía';
  String get lastReason => _lastReason;

  /// Línea de estado observable, apta para un panel de diagnóstico en pantalla.
  final ValueNotifier<String> status = ValueNotifier<String>('turbo: inactivo');

  int _bytesInWindow = 0;
  DateTime _windowStart = DateTime.now();
  double _mbps = 0;
  int _activeConnections = 0;

  /// Velocidad de descarga agregada (Mbps) medida sobre el último segundo.
  double get mbps => _mbps;

  /// Conexiones abiertas ahora mismo contra el servidor de origen.
  int get activeConnections => _activeConnections;

  /// ¿Es [url] una URL servida por este proxy?
  bool isTurboUrl(String url) => url.startsWith('http://127.0.0.1:');

  /// Dada una URL local del proxy, devuelve la URL ORIGINAL del servidor.
  ///
  /// Imprescindible para dos cosas que se rompen si se compara contra la URL
  /// local: (1) el guard de "ya está reproduciendo esto" (la URI del media pasa
  /// a ser 127.0.0.1 y la comparación con la URL del item siempre fallaría,
  /// reabriendo en bucle), y (2) la recuperación mid-stream, que necesita
  /// reabrir con la URL DIRECTA si el proxy falla después de haber arrancado.
  String? originalFor(String url) {
    if (!isTurboUrl(url)) return null;
    final segments = Uri.tryParse(url)?.pathSegments;
    if (segments == null || segments.length != 2 || segments[0] != 't') {
      return null;
    }
    return _entries[segments[1]]?.originalUrl;
  }

  /// La URL original si [url] es del proxy, o la propia [url] si no lo es.
  /// Úsalo al comparar el media actual contra la URL de un contenido.
  String resolveOriginal(String url) => originalFor(url) ?? url;

  void _setReason(String reason) {
    _lastReason = reason;
    status.value = 'turbo: $reason';
    debugPrint('TurboProxy: $reason');
  }

  void _noteBytes(int n) {
    _bytesInWindow += n;
    final elapsed = DateTime.now().difference(_windowStart);
    if (elapsed.inMilliseconds >= 1000) {
      _mbps = (_bytesInWindow * 8) / elapsed.inMilliseconds / 1000;
      _bytesInWindow = 0;
      _windowStart = DateTime.now();
      status.value =
          'turbo: activo — ${_mbps.toStringAsFixed(1)} Mbps '
          '($_activeConnections conexiones)';
    }
  }

  Future<void> _ensureServer() async {
    if (_server != null) return;
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: true,
    );
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
  ///
  /// NUNCA lanza: ante cualquier problema devuelve null y el caller sigue con
  /// la URL original, exactamente igual que si el turbo no existiera.
  Future<String?> wrap(String url, Map<String, String>? headers) async {
    try {
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        _setReason('no aplica (no es HTTP)');
        return null;
      }
      final low = url.toLowerCase();
      if (low.contains('.m3u8') ||
          low.contains('output=m3u8') ||
          low.contains('/live/') ||
          low.contains('/hls/') ||
          low.contains('type=live')) {
        _setReason('no aplica (live/HLS)');
        return null;
      }

      final host = Uri.tryParse(url)?.host ?? '';
      if (host.isNotEmpty && _hostileHosts.contains(host)) {
        _setReason('servidor sin soporte de rangos (recordado de antes)');
        return null;
      }

      await _ensureServer();

      // Candidatos de conexión, en orden de preferencia:
      //  - Bypass de DNS (DoH): imprescindible en las redes cuyo ISP no
      //    resuelve los dominios IPTV. Sin esto el sondeo NO CONECTA y el
      //    turbo quedaba desactivado en silencio.
      //  - Directo por hostname.
      // En HTTPS probamos DIRECTO primero: al conectar por IP el SNI de TLS
      // deja de llevar el hostname y muchos servidores rechazan el handshake o
      // sirven el vhost equivocado. En HTTP el bypass es siempre fiable
      // (el header `Host` basta para identificar el vhost).
      final targets = await _resolveTargets(url, headers);

      // Sondeo: pedimos 2 bytes con Range. Solo si el servidor responde 206
      // con longitud total conocida vale la pena trocear.
      ({Uri uri, Map<String, String> headers})? target;
      (int, String?)? probe;
      for (var i = 0; i < targets.length; i++) {
        // Solo el ÚLTIMO candidato puede marcar el host como "sin rangos": un
        // fallo del bypass no debe condenar a un servidor que sí los soporta.
        probe = await _probe(targets[i], markHostile: i == targets.length - 1);
        if (probe != null) {
          target = targets[i];
          break;
        }
      }
      if (probe == null || target == null) {
        return null; // _probe ya registró el motivo exacto
      }

      final id = '${_nextId++}';
      final client = HttpClient()
        // CRÍTICO: sin esto Dart descomprime por su cuenta y la aritmética de
        // bytes/Range deja de cuadrar (los trozos no encajan y el vídeo se
        // corrompe).
        ..autoUncompress = false
        ..maxConnectionsPerHost = _parallel + 1
        ..connectionTimeout = const Duration(seconds: 10)
        ..badCertificateCallback = (_, _, _) => true;

      _entries[id] = _Entry(
        proxy: this,
        originalUrl: url,
        uri: target.uri,
        headers: target.headers,
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
      _setReason('activo');
      debugPrint(
        'TurboProxy: activo para $url '
        '(${(probe.$1 / 1048576).toStringAsFixed(1)} MB) → $local',
      );
      return local;
    } catch (e) {
      _setReason('wrap falló ($e) — usando URL directa');
      return null;
    }
  }

  /// Formas de alcanzar el origen, ordenadas por probabilidad de éxito.
  /// Siempre incluye el acceso directo por hostname, y añade el bypass de DNS
  /// (DoH) cuando este resuelve a una IP distinta.
  Future<List<({Uri uri, Map<String, String> headers})>> _resolveTargets(
    String url,
    Map<String, String>? headers,
  ) async {
    final base = Map<String, String>.from(headers ?? const {});
    // La aritmética de Range exige bytes SIN comprimir. Los headers del player
    // suelen pedir gzip/deflate; aquí lo forzamos a identity.
    base['Accept-Encoding'] = 'identity';
    final direct = (uri: Uri.parse(url), headers: base);

    try {
      // Devuelve la URI reescrita a IP y los headers con el `Host` original
      // añadido — ese `Host` hay que CONSERVARLO al reenviar o el servidor
      // responde 404/403 al no saber qué vhost se le pide.
      final bypassed = await DnsBypassUtils.bypassUrl(url, base);
      if (bypassed.uri.host == direct.uri.host) return [direct];
      // HTTPS: directo primero (el SNI por IP rompe muchos handshakes).
      // HTTP: bypass primero (es el caso que arregla el ISP que no resuelve).
      return direct.uri.scheme == 'https'
          ? [direct, bypassed]
          : [bypassed, direct];
    } catch (e) {
      debugPrint('TurboProxy: bypass DNS no aplicado ($e)');
      return [direct];
    }
  }

  /// Devuelve (longitud total, content-type) o null si no hay soporte Range.
  Future<(int, String?)?> _probe(
    ({Uri uri, Map<String, String> headers}) target, {
    bool markHostile = true,
  }) async {
    // 3s por sondeo (no 6s): probamos hasta DOS candidatos (bypass y directo)
    // y el caller nos corta a los 7s. Con 6s cada uno, el segundo candidato no
    // llegaría a probarse nunca. La resolución DNS/DoH ocurre ANTES de esto y
    // tiene su propio presupuesto de tiempo.
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 3)
      ..badCertificateCallback = (_, _, _) => true;
    try {
      final rq = await client.getUrl(target.uri);
      target.headers.forEach((k, v) => rq.headers.set(k, v));
      rq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
      final rs = await rq.close().timeout(const Duration(seconds: 3));
      // Drenar los 2 bytes para liberar la conexión.
      await rs.drain<void>().catchError((_) {});
      if (rs.statusCode != HttpStatus.partialContent) {
        _setReason('servidor sin soporte de rangos (${rs.statusCode})');
        if (rs.statusCode == HttpStatus.ok && markHostile) {
          // 200 a un Range = este origen NUNCA va a poder acelerarse. Es un
          // límite del SERVIDOR, no del cliente. Lo recordamos para no
          // re-sondear todo su catálogo.
          final host = target.headers['Host'] ?? target.uri.host;
          if (host.isNotEmpty) _hostileHosts.add(host);
        }
        return null;
      }
      final cr = rs.headers.value(HttpHeaders.contentRangeHeader);
      if (cr == null) {
        _setReason('206 sin Content-Range (tamaño desconocido)');
        return null;
      }
      // Formato: "bytes 0-1/123456"
      final slash = cr.lastIndexOf('/');
      if (slash == -1) {
        _setReason('Content-Range ilegible: $cr');
        return null;
      }
      final total = int.tryParse(cr.substring(slash + 1).trim());
      if (total == null || total <= 0) {
        _setReason('tamaño total desconocido (Content-Range: $cr)');
        return null;
      }
      return (total, rs.headers.contentType?.mimeType);
    } on TimeoutException {
      _setReason('sondeo: timeout');
      return null;
    } catch (e) {
      _setReason('sondeo: no conecta ($e)');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final segments = req.uri.pathSegments;
      final entry = (segments.length == 2 && segments[0] == 't')
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
  final TurboProxy proxy;

  /// URL tal cual la conoce la app (con hostname). Se conserva para poder
  /// re-resolver el DNS si la IP cacheada deja de responder.
  final String originalUrl;

  /// URI efectiva de descarga (puede apuntar a la IP tras el bypass de DNS).
  Uri uri;
  Map<String, String> headers;
  final int length;
  final String? contentType;
  final HttpClient client;
  _Entry({
    required this.proxy,
    required this.originalUrl,
    required this.uri,
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
      e.proxy._activeConnections++;
      try {
        final rq = await e.client.getUrl(e.uri);
        e.headers.forEach((k, v) => rq.headers.set(k, v));
        rq.headers.set(HttpHeaders.rangeHeader, 'bytes=${startB + got}-$endB');
        final rs = await rq.close().timeout(const Duration(seconds: 20));
        if (rs.statusCode != HttpStatus.partialContent) {
          await rs.drain<void>().catchError((_) {});
          throw HttpException('status ${rs.statusCode} (esperaba 206)');
        }
        await for (final part in rs.timeout(const Duration(seconds: 25))) {
          builder.add(part);
          got += part.length;
          e.proxy._noteBytes(part.length);
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
        // Si la IP resuelta por DoH dejó de responder, la marcamos y
        // re-resolvemos el host antes del siguiente intento.
        if (err is SocketException) await _refreshTargetOnSocketError();
        await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      } finally {
        e.proxy._activeConnections--;
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

  /// La IP obtenida por DoH puede quedarse muerta (balanceadores). Se descarta
  /// y se pide otra; si no hay, se vuelve al hostname original.
  Future<void> _refreshTargetOnSocketError() async {
    try {
      final original = Uri.parse(e.originalUrl);
      if (e.uri.host == original.host) return; // no había bypass activo
      DnsBypassUtils.reportFailedIp(original.host, e.uri.host);
      final refreshed = await DnsBypassUtils.bypassUrl(e.originalUrl, e.headers);
      e.uri = refreshed.uri;
      e.headers = refreshed.headers;
    } catch (_) {
      // Sin bypass utilizable: seguir con lo que haya.
    }
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
