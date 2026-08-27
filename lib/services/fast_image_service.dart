import 'dart:io';
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'performance_service.dart';
import 'metadata_fallback_service.dart';
import 'network_quality_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FAILED IMAGE TRACKER — Retries on app resume
// ─────────────────────────────────────────────────────────────────────────────

/// Global tracker that watches for app lifecycle changes and triggers
/// silent retries on all registered widgets when the app comes back
/// to the foreground. This handles the common case where images fail
/// due to a momentary network issue and the user backgrounds the app.
class _FailedImageTracker with WidgetsBindingObserver {
  static final _FailedImageTracker instance = _FailedImageTracker._();
  _FailedImageTracker._();

  bool _initialized = false;
  final Set<VoidCallback> _retryCallbacks = {};
  NetworkQuality _lastQuality = NetworkQuality.excellent;
  DateTime? _lastLimitChange;
  // Última calidad realmente aplicada al semáforo/HttpClient.
  NetworkQuality? _lastAppliedQuality;

  void init() {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);

    // Dynamically adjust global image cache based on device hardware performance limits
    final performance = PerformanceService();
    if (performance.lowMemoryLimit) {
      PaintingBinding.instance.imageCache.maximumSize = 500;
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          50 * 1024 * 1024; // 50MB
    } else if (performance.isLowPerformance) {
      PaintingBinding.instance.imageCache.maximumSize = 1000;
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          100 * 1024 * 1024; // 100MB
    } else {
      PaintingBinding.instance.imageCache.maximumSize = 3000;
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          250 * 1024 * 1024; // 250MB
    }

    // Silence Flutter's internal "image resource service" error logs for
    // TimeoutExceptions and network errors. We already handle these gracefully
    // in each widget's errorBuilder, so the default console spam is unnecessary.
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      final isImageService = details.library == 'image resource service';
      if (isImageService) {
        // Silently swallow image loading errors — our widgets handle them
        return;
      }
      // Forward all other errors to the original handler
      originalOnError?.call(details);
    };

    // Listen to network quality changes — auto-retry all failed images
    // when network recovers from offline/poor to fair/good/excellent
    _lastQuality = NetworkQualityService().quality.value;
    _adaptConnectionLimits(_lastQuality);
    NetworkQualityService().quality.addListener(_onNetworkQualityChanged);
  }

  void _onNetworkQualityChanged() {
    final newQuality = NetworkQualityService().quality.value;

    final wasOffline = _lastQuality == NetworkQuality.offline;
    final wasPoor = _lastQuality == NetworkQuality.poor;
    final isNowConnected = newQuality != NetworkQuality.offline;
    final isNowBetterThanPoor =
        newQuality == NetworkQuality.fair ||
        newQuality == NetworkQuality.good ||
        newQuality == NetworkQuality.excellent;

    final recoveredFromOffline = wasOffline && isNowConnected;
    final recoveredFromPoor = wasPoor && isNowBetterThanPoor;

    if ((recoveredFromOffline || recoveredFromPoor) &&
        _retryCallbacks.isNotEmpty) {
      final callbacks = List<VoidCallback>.from(_retryCallbacks);
      // Escalonar: 1 retry cada 40ms → 200 imágenes = 8 segundos de rampa suave
      for (int i = 0; i < callbacks.length; i++) {
        Future.delayed(Duration(milliseconds: 600 + (i * 40)), () {
          if (_retryCallbacks.contains(callbacks[i])) callbacks[i]();
        });
      }
    }

    // Also adapt HttpClient connection limits dynamically
    _adaptConnectionLimits(newQuality);

    _lastQuality = newQuality;
  }

  /// Dynamically adjust HttpClient parallelism based on network quality.
  /// Fewer parallel connections on slow networks = each image gets more
  /// bandwidth and completes faster instead of all stalling together.
  void _adaptConnectionLimits(NetworkQuality quality) {
    // Nada que hacer si la calidad no cambió.
    if (_lastAppliedQuality == quality) return;

    // FIX: el guard anti-rebote de 5s se saltaba updateLimit() por completo.
    // Estando offline el semáforo queda en 0 descargas concurrentes, así que
    // si la red volvía dentro de esos 5s — exactamente lo que pasa al apagar y
    // encender la pantalla — el semáforo se quedaba en 0 y NINGUNA imagen
    // podía descargar más. Ahora la salida anticipada nunca aplica cuando se
    // viene de (o se va a) offline.
    final now = DateTime.now();
    if (_lastLimitChange != null &&
        now.difference(_lastLimitChange!) < const Duration(seconds: 5) &&
        quality != NetworkQuality.offline &&
        _lastAppliedQuality != NetworkQuality.offline) {
      return;
    }
    _lastAppliedQuality = quality;
    _lastLimitChange = now;

    switch (quality) {
      case NetworkQuality.excellent:
        _sharedHttpClient.maxConnectionsPerHost = 16;
      case NetworkQuality.good:
        _sharedHttpClient.maxConnectionsPerHost = 12;
      case NetworkQuality.fair:
        _sharedHttpClient.maxConnectionsPerHost = 8;
      case NetworkQuality.poor:
        _sharedHttpClient.maxConnectionsPerHost = 4;
      case NetworkQuality.offline:
        _sharedHttpClient.maxConnectionsPerHost = 1;
    }
    _DownloadSemaphore.instance.updateLimit(quality);
  }

  void register(VoidCallback callback) {
    init();
    _retryCallbacks.add(callback);
  }

  void unregister(VoidCallback callback) {
    _retryCallbacks.remove(callback);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Red de seguridad: re-aplicar los límites por si el semáforo quedó en 0
      // concurrentes tras un corte de red mientras la pantalla estaba apagada.
      _lastAppliedQuality = null;
      _adaptConnectionLimits(NetworkQualityService().quality.value);
    }
    if (state == AppLifecycleState.resumed && _retryCallbacks.isNotEmpty) {
      final callbacks = List<VoidCallback>.from(_retryCallbacks);
      // Escalonado: disparar cientos de reintentos en el mismo frame satura la
      // red y el semáforo de descargas, y termina haciendo que TODAS las
      // carátulas tarden más. Las primeras salen ya (son las visibles) y el
      // resto entra de a poco.
      for (int i = 0; i < callbacks.length; i++) {
        final cb = callbacks[i];
        if (i < 8) {
          if (_retryCallbacks.contains(cb)) cb();
          continue;
        }
        Future.delayed(Duration(milliseconds: (i - 8) * 30), () {
          if (_retryCallbacks.contains(cb)) cb();
        });
      }
    }
  }

  @override
  void didHaveMemoryPressure() {
    // Release all in-memory decoded image resources immediately under OS memory pressure.
    // This prevents background process termination and improves OS-level scheduling.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

// Track successfully loaded URLs during this session to allow 0ms instant loading.
final Set<String> _loadedUrls = {};

// Headers mínimos — solo lo imprescindible para evitar 403.
// Menos headers = handshake más rápido con el CDN.
const Map<String, String> _kImageHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  'Accept': 'image/*,*/*;q=0.8',
};

// ─────────────────────────────────────────────────────────────────────────────
// APP CACHE MANAGER — Optimizado para velocidad
// ─────────────────────────────────────────────────────────────────────────────

/// HttpClient compartido con pool de conexiones agresivo.
/// maxConnectionsPerHost se ajusta dinámicamente por _FailedImageTracker
/// según la calidad de red detectada.
final HttpClient _sharedHttpClient =
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 8) // era 20 — demasiado
      ..idleTimeout = const Duration(
        seconds: 20,
      ) // era 60 — retiene slots innecesariamente
      ..maxConnectionsPerHost =
          8 // era 16 — el semáforo lo controla ahora
      ..autoUncompress = true
      ..findProxy =
          null // Bypass proxy search to shave off ~50ms off initial handshakes
      ..badCertificateCallback =
          ((X509Certificate cert, String host, int port) => true);

/// Returns adaptive timeout based on current network quality.
Duration _adaptiveTimeout() {
  final quality = NetworkQualityService().quality.value;
  switch (quality) {
    case NetworkQuality.excellent:
      return const Duration(seconds: 4);
    case NetworkQuality.good:
      return const Duration(seconds: 5);
    case NetworkQuality.fair:
      return const Duration(seconds: 6);
    case NetworkQuality.poor:
      return const Duration(seconds: 8);
    case NetworkQuality.offline:
      return const Duration(seconds: 2);
  }
} 

// ─────────────────────────────────────────────────────────────────────────────
// VALIDATING IMAGE FILE SERVICE
// Intercepts HTTP responses to reject non-image content (HTML error pages, etc.)
// BEFORE they get cached. This prevents the root cause of images never loading:
// the Xtream server sometimes returns HTML ("XUI.one - Debug Mode") which
// flutter_cache_manager would cache as a valid file, causing permanent
// ImageDecoder failures on Android.
// ─────────────────────────────────────────────────────────────────────────────

class _ValidatingImageFileService extends FileService {
  _ValidatingImageFileService();

  /// Descargas directas al origen en curso ahora mismo, y su tope.
  /// Ver la nota en `lanzarDirecta`: el origen hace rate-limiting a partir de
  /// ~8 conexiones concurrentes, así que el adelanto se queda por debajo.
  static int _directasEnVuelo = 0;
  static const int _maxDirectasEnVuelo = 4;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    // Pasar por el semáforo para que el timeout solo cuente el tiempo de descarga real
    return _DownloadSemaphore.instance.run(() => _doGet(url, headers: headers));
  }

  Future<FileServiceResponse> _doGet(
    String url, {
    Map<String, String>? headers,
  }) async {
    final host = Uri.tryParse(url)?.host ?? '';
    // Estrategia Híbrida: Servidores IPTV (imágenes pesadas sin comprimir) usan Proxy WebP,
    // mientras TMDB carga directo desde su CDN oficial optimizada (w185/w500) en 20ms.
    final shouldProxy =
        (host.contains('ultratvsv.site') || host.contains('red4tv.lat')) &&
        !host.contains('image.tmdb.org');

    final directa = Uri.parse(url);

    // UN SOLO proxy: el VPS propio, con caché en disco.
    //
    // Antes había tres proxies externos encadenados (un Worker de Cloudflare,
    // wsrv.nl e images.weserv.nl). Cuando fallaban —cosa frecuente— cada uno
    // agotaba su timeout antes de pasar al siguiente: ~18 segundos por carátula
    // antes de intentar la descarga directa, que se comprobó que responde en
    // 0,65s. Peor aún: eran tres dependencias externas fuera de nuestro control
    // para algo crítico de la UI.
    //
    // Se reescribe SOLO el host, conservando la ruta:
    //   http://ultratvsv.site/images/abc.jpg
    //   -> http://217.216.80.212/images/abc.jpg
    //
    // NO se usa la variante /img?url=<codificada>: nginx no decodifica
    // $arg_url, asi que la URL percent-encoded que manda la app no casa con el
    // `map` que extrae la ruta, y el proxy termina pidiendo "/" al origen ->
    // 404 (y encima se cachea). Reescribir el host evita todo ese problema: la
    // ruta viaja tal cual.
    Uri? viaVps;
    if (shouldProxy && directa.path.length > 1) {
      viaVps = Uri.parse('http://217.216.80.212${directa.path}');
    }

    if (viaVps == null) {
      return _abrir(directa, headers: headers);
    }
    return _carreraVpsVsDirecto(viaVps, directa, headers);
  }

  /// Cuánto se espera al VPS antes de lanzar TAMBIÉN la descarga directa.
  ///
  /// Un HIT del VPS manda cabeceras en un RTT; un MISS no manda nada hasta que
  /// el origen le contesta. Así que "no hay cabeceras todavía" es la señal de
  /// que esa carátula aún no está cacheada, y es el momento de dejar de
  /// esperarla.
  static Duration _margenVps() {
    switch (NetworkQualityService().quality.value) {
      case NetworkQuality.excellent:
      case NetworkQuality.good:
        return const Duration(milliseconds: 600);
      case NetworkQuality.fair:
        return const Duration(milliseconds: 900);
      case NetworkQuality.poor:
        return const Duration(milliseconds: 1500);
      case NetworkQuality.offline:
        return const Duration(milliseconds: 400);
    }
  }

  /// Pide la carátula al VPS y, si no contesta dentro de [_margenVps], lanza EN
  /// PARALELO la descarga directa al origen. Gana la primera que devuelva
  /// cabeceras válidas; la perdedora se aborta.
  ///
  /// POR QUE UNA CARRERA Y NO UNA CADENA
  /// -----------------------------------
  /// Antes esto era secuencial: VPS y, sólo si FALLABA, directo. El problema es
  /// que un MISS no falla — se queda esperando a que el VPS baje la imagen del
  /// origen, que es justo el servidor lento. Resultado: las carátulas que
  /// todavía no estaban en el VPS cargaban MÁS lento que sin proxy.
  ///
  /// Abortar la petición perdedora no desperdicia el trabajo del VPS: nginx
  /// tiene `proxy_ignore_client_abort on`, así que termina de bajarla y la deja
  /// cacheada igual. O sea que cada miss se precarga solo y la próxima vez ya
  /// sale del disco, instantánea.
  Future<FileServiceResponse> _carreraVpsVsDirecto(
    Uri viaVps,
    Uri directa,
    Map<String, String>? headers,
  ) {
    final resultado = Completer<FileServiceResponse>();
    Timer? temporizador;
    var lanzadas = 1;
    var terminadas = 0;
    var directaLanzada = false;

    void entregar(_ValidatingHttpGetResponse respuesta) {
      terminadas++;
      if (resultado.isCompleted) {
        // Llegó segunda: soltar la conexión sin leer el cuerpo.
        respuesta.descartar();
        return;
      }
      temporizador?.cancel();
      resultado.complete(respuesta);
    }

    // `fallo` y `lanzarDirecta` se llaman entre sí, así que una de las dos
    // tiene que ser una variable `late` para poder nombrarla antes.
    late final void Function(Object error) fallo;

    // [forzar] distingue las dos razones para ir al origen:
    //
    //  - Sin forzar (venció el margen): es un ADELANTO opcional. El VPS quizá
    //    conteste igual; solo queremos no esperarlo. Si ya hay muchas directas
    //    en vuelo se deja pasar y se sigue esperando al VPS.
    //  - Con forzar (el VPS ya falló): es el último recurso y sale siempre.
    //
    // El tope existe porque el origen tiene rate-limiting: se comprobó que con
    // 8 peticiones en paralelo empieza a descartar conexiones (fue lo que
    // cortó la precarga nocturna a los 2.007 títulos). El semáforo de imágenes
    // permite hasta 18 descargas a la vez, y con el catálogo frío casi todas
    // agotarían el margen y saltarían al origen — más presión de la que ya se
    // sabe que no tolera. Pasado el tope, esperar al VPS es lo correcto:
    // perder unos milisegundos es mucho mejor que hacer que el origen nos
    // corte y que fallen las dos vías a la vez.
    void lanzarDirecta({bool forzar = false}) {
      if (directaLanzada || resultado.isCompleted) return;
      if (!forzar && _directasEnVuelo >= _maxDirectasEnVuelo) return;
      directaLanzada = true;
      lanzadas++;
      _directasEnVuelo++;
      _abrir(directa, headers: headers).then<void>(
        (respuesta) {
          _directasEnVuelo--;
          entregar(respuesta);
        },
        onError: (Object error) {
          _directasEnVuelo--;
          fallo(error);
        },
      );
    }

    fallo = (Object error) {
      terminadas++;
      if (resultado.isCompleted) return;
      // El VPS cayó (o el adelanto quedó bloqueado por el tope): la directa ya
      // no es un adelanto opcional sino la única vía que queda.
      if (!directaLanzada) {
        lanzarDirecta(forzar: true);
        return;
      }
      if (terminadas >= lanzadas) {
        temporizador?.cancel();
        resultado.completeError(error);
      }
    };

    _abrir(viaVps, esVps: true).then<void>(entregar, onError: fallo);
    temporizador = Timer(_margenVps(), lanzarDirecta);

    return resultado.future;
  }

  /// Abre una petición y valida que la respuesta sea realmente una imagen.
  ///
  /// Con [esVps] se es más estricto: cualquier 4xx/5xx o JSON descarta esa vía
  /// para que la carrera se quede con la directa. En la directa, en cambio, el
  /// status se deja pasar tal cual — flutter_cache_manager lo convierte en
  /// HttpExceptionWithStatus y así _isRetryableError puede distinguir un 404
  /// real (no reintentar) de un problema de red (reintentar).
  Future<_ValidatingHttpGetResponse> _abrir(
    Uri uri, {
    Map<String, String>? headers,
    bool esVps = false,
  }) async {
    HttpClientRequest? req;
    try {
      req = await _sharedHttpClient.getUrl(uri).timeout(_adaptiveTimeout());

      if (esVps) {
        req.headers.set('Accept', 'image/webp,image/*,*/*;q=0.8');
      } else if (headers != null) {
        headers.forEach((key, value) {
          req!.headers.set(key, value);
        });
      }

      final ioResponse = await req.close().timeout(_adaptiveTimeout());

      // Check content-type BEFORE creating the cache response
      final contentType =
          ioResponse.headers.value('content-type')?.toLowerCase() ?? '';
      final noEsImagen =
          contentType.contains('text/html') ||
          contentType.contains('text/plain') ||
          (esVps && contentType.contains('application/json'));

      if (noEsImagen || (esVps && ioResponse.statusCode >= 400)) {
        // Abort the request cleanly to release connection resources
        req.abort();
        throw HttpExceptionWithStatus(
          ioResponse.statusCode,
          'Server returned non-image content-type: $contentType',
          uri: uri,
        );
      }

      final responseHeaders = <String, String>{};
      ioResponse.headers.forEach((key, values) {
        responseHeaders[key] = values.join(',');
      });

      final streamedResponse = http.StreamedResponse(
        ioResponse,
        ioResponse.statusCode,
        contentLength:
            ioResponse.contentLength == -1 ? null : ioResponse.contentLength,
        request: http.Request('GET', uri),
        headers: responseHeaders,
        isRedirect: ioResponse.isRedirect,
        persistentConnection: ioResponse.persistentConnection,
        reasonPhrase: ioResponse.reasonPhrase,
      );

      // Wrap the stream to also peek at the first bytes
      // (some IPTV servers don't set content-type correctly)
      return _ValidatingHttpGetResponse(streamedResponse, req);
    } on TimeoutException {
      req?.abort(); // CRITICAL: Free connection on timeout!
      rethrow;
    } catch (e) {
      req?.abort();
      rethrow;
    }
  }
}

/// Extends HttpGetResponse with first-bytes HTML validation.
class _ValidatingHttpGetResponse extends HttpGetResponse {
  final http.StreamedResponse _rawResponse;
  final HttpClientRequest _ioRequest;
  Stream<List<int>>? _validatedStream;

  _ValidatingHttpGetResponse(this._rawResponse, this._ioRequest)
    : super(_rawResponse);

  /// Soltar esta respuesta sin leerla — la usa la carrera VPS/directo para
  /// cerrar la conexión de la que llegó segunda.
  void descartar() {
    try {
      _ioRequest.abort();
    } catch (_) {}
  }

  @override
  Stream<List<int>> get content {
    if (_validatedStream != null) return _validatedStream!;

    final controller = StreamController<List<int>>();
    bool firstChunk = true;

    // Timeout adaptativo para chunks — redes lentas necesitan más tiempo
    _rawResponse.stream
        .timeout(_adaptiveTimeout())
        .listen(
          (data) {
            if (firstChunk && data.length >= 5) {
              firstChunk = false;
              // Check for HTML signature: <!DOC, <html, <HTML
              final header = String.fromCharCodes(data.take(15).toList());
              if (header.trimLeft().startsWith('<') &&
                  (header.contains('html') ||
                      header.contains('HTML') ||
                      header.contains('!DOC'))) {
                controller.addError(
                  Exception('Response body is HTML, not an image'),
                );
                _ioRequest.abort();
                controller.close();
                return;
              }
            }
            firstChunk = false;
            controller.add(data);
          },
          onError: (Object error) {
            controller.addError(error);
            _ioRequest.abort();
          },
          onDone: controller.close,
        );

    _validatedStream = controller.stream;
    return _validatedStream!;
  }
}

// ── GLOBAL DOWNLOAD SEMAPHORE FOR NETWORK MANAGEMENT ──

class _DownloadSemaphore {
  static final _DownloadSemaphore instance = _DownloadSemaphore._();
  _DownloadSemaphore._();

  int _maxConcurrent = 4;
  int _running = 0;
  final List<_PrioritizedCompleter> _waiters = [];

  void updateLimit(NetworkQuality quality) {
    _maxConcurrent = switch (quality) {
      NetworkQuality.excellent => 18,
      NetworkQuality.good => 14,
      NetworkQuality.fair => 8,
      NetworkQuality.poor => 4,
      NetworkQuality.offline => 0,
    };
    // Si ahora hay slots libres, despertar waiters
    _drainWaiters();
  }

  void _drainWaiters() {
    while (_running < _maxConcurrent && _waiters.isNotEmpty) {
      // Ordenar por prioridad (visible = mayor prioridad)
      _waiters.sort((a, b) => b.priority.compareTo(a.priority));
      _waiters.removeAt(0).completer.complete();
    }
  }

  Future<T> run<T>(Future<T> Function() task, {int priority = 0}) async {
    if (_running >= _maxConcurrent) {
      final pc = _PrioritizedCompleter(priority);
      _waiters.add(pc);
      await pc.completer.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      _drainWaiters();
    }
  }

  /// Cancelar todos los waiters cuando el usuario sale de la pantalla
  void cancelAll() {
    for (final w in _waiters) {
      w.completer.completeError(Exception('cancelled'));
    }
    _waiters.clear();
  }
}

class _PrioritizedCompleter {
  final int priority;
  final Completer<void> completer = Completer<void>();
  _PrioritizedCompleter(this.priority);
}

class AppCacheManager {
  static const key = 'bump_comba_img_cache';
  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 7),
      maxNrOfCacheObjects: 3000,
      fileService: _ValidatingImageFileService(),
    ),
  );
}

// Helper to determine if an error is permanently non-retryable.
// Timeouts ARE now retryable — on slow networks, timeouts are the #1 cause
// of image failures, and the adaptive timeout + backoff system prevents
// starvation loops that the old code was guarding against.
bool _isRetryableError(Object error) {
  final errStr = error.toString().toLowerCase();

  // Timeouts are now RETRYABLE — the adaptive timeout system ensures
  // each retry uses a longer timeout appropriate to the current network.
  // The exponential backoff in _scheduleRetry prevents starvation.

  // Check for HTTP status exceptions — these are permanent
  if (error is HttpExceptionWithStatus) {
    final code = error.statusCode;
    if (code == 404 || code == 403 || code == 401 || code == 400) {
      return false;
    }
  }

  // HTML debug pages or non-image content responses — permanent server issue
  if (errStr.contains('html') || errStr.contains('non-image')) {
    return false;
  }

  // Common HTTP error tags in strings — permanent
  if (errStr.contains('404') ||
      errStr.contains('403') ||
      errStr.contains('401')) {
    return false;
  }

  return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// FAST IMAGE SERVICE
// ─────────────────────────────────────────────────────────────────────────────

class FastImageService {
  static final FastImageService _instance = FastImageService._internal();
  factory FastImageService() => _instance;
  FastImageService._internal() {
    _loadSettings();
  }

  static bool forceLowQuality = false;

  void _loadSettings() {
    SharedPreferences.getInstance()
        .then((prefs) {
          forceLowQuality = prefs.getBool('force_low_image_quality') ?? false;
        })
        .catchError((_) {});
  }

  static Future<void> setForceLowQuality(bool enabled) async {
    forceLowQuality = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('force_low_image_quality', enabled);
    } catch (_) {}
  }

  // FIX 2: isValidImageUrl acepta URLs sin extensión (logos IPTV frecuentes)
  static bool isValidImageUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    if (!url.startsWith('http')) return false;

    if (url.contains('ejemplo.com') || url.contains('placeholder.com')) {
      return false;
    }

    // Rutas base de TMDB sin filename — no son imágenes válidas
    const tmdbIncompleteSuffixes = [
      '/w600_and_h900_bestv2',
      '/original',
      '/w500',
      '/w300',
      '/w185',
      '/w92',
    ];
    for (final suffix in tmdbIncompleteSuffixes) {
      if (url.endsWith(suffix)) return false;
    }

    // Validar que sea parseable con host real
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;

    return true;
  }

  // FIX 5: Limitar _queued para evitar leak de memoria en sesiones largas
  static const int _maxQueuedMemory = 3000;
  final Set<String> _queued = {};

  /// Adaptive batch size based on network quality.
  /// Fewer parallel downloads on slow networks = each one completes faster.
  int get _batchSize {
    final quality = NetworkQualityService().quality.value;
    switch (quality) {
      case NetworkQuality.excellent:
      case NetworkQuality.good:
        return 16;
      case NetworkQuality.fair:
        return 10;
      case NetworkQuality.poor:
        return 4;
      case NetworkQuality.offline:
        return 0;
    }
  }

  /// Adaptive max prewarm count — don't saturate a slow network.
  int get _maxBackgroundPrewarm {
    final quality = NetworkQualityService().quality.value;
    switch (quality) {
      case NetworkQuality.excellent:
      case NetworkQuality.good:
        return 40;
      case NetworkQuality.fair:
        return 20;
      case NetworkQuality.poor:
        return 10;
      case NetworkQuality.offline:
        return 0; // Don't even try when offline
    }
  }

  /// Nullable thumbnail width — returns null to ensure cover arts are cached
  /// at their full/original resolution for maximum visual quality.
  int? get _thumbWidth => null;

  /// Llamar cuando se recarga la lista con forceRefresh
  void clearQueue() => _queued.clear();

  Future<void> prewarm(List<String> urls, BuildContext context) async {
    if (urls.isEmpty) return;

    // Don't prewarm when offline — waste of resources
    if (NetworkQualityService().quality.value == NetworkQuality.offline) return;

    // FIX 5: limpiar si el set creció demasiado
    if (_queued.length > _maxQueuedMemory) _queued.clear();

    final fresh =
        urls
            .where((u) => isValidImageUrl(u) && !_queued.contains(u))
            .take(_maxBackgroundPrewarm)
            .toSet()
            .toList();
    if (fresh.isEmpty) return;

    _queued.addAll(fresh);

    SchedulerBinding.instance.addPostFrameCallback((_) {
      // Guard: context may already be unmounted by the time the frame fires.
      if ((context as Element).mounted) {
        _warmBatch(fresh, context);
      }
    });
  }

  Future<void> _warmBatch(List<String> urls, BuildContext context) async {
    final batchSz = _batchSize; // Capture once per warm cycle
    for (int start = 0; start < urls.length; start += batchSz) {
      // Stop if the context element has been unmounted between batches.
      if (!(context as Element).mounted) return;

      final end = (start + batchSz).clamp(0, urls.length);
      final batch = urls.sublist(start, end);

      await Future.wait(
        batch.map((url) => _precacheOne(url, context)),
        eagerError: false,
      );

      // Longer pause between batches on slow networks to avoid congestion
      final pauseMs = switch (NetworkQualityService().quality.value) {
        NetworkQuality.excellent || NetworkQuality.good => 30,
        NetworkQuality.fair => 150,
        NetworkQuality.poor => 400,
        NetworkQuality.offline => 0,
      };
      await Future.delayed(Duration(milliseconds: pauseMs));
    }
  }

  Future<void> _precacheOne(String url, BuildContext context) async {
    if (!(context as Element).mounted) return;
    try {
      final thumbW = _thumbWidth;
      final ImageProvider provider =
          thumbW == null
              ? CachedNetworkImageProvider(
                url,
                headers: _kImageHeaders,
                cacheManager: AppCacheManager.instance,
              )
              : ResizeImage(
                CachedNetworkImageProvider(
                  url,
                  headers: _kImageHeaders,
                  cacheManager: AppCacheManager.instance,
                ),
                width: thumbW,
              );
      await precacheImage(provider, context, onError: (_, _) {});
    } catch (_) {}
  }

  void prewarmPriority(List<String> urls, BuildContext context) {
    // Skip if offline
    if (NetworkQualityService().quality.value == NetworkQuality.offline) return;

    final maxPriority =
        NetworkQualityService().quality.value.index >= NetworkQuality.fair.index
            ? 10
            : 30;
    for (final url in urls.take(maxPriority)) {
      if (!isValidImageUrl(url) || _queued.contains(url)) continue;
      _queued.add(url);
      final thumbW = _thumbWidth;
      final ImageProvider provider =
          thumbW == null
              ? CachedNetworkImageProvider(
                url,
                headers: _kImageHeaders,
                cacheManager: AppCacheManager.instance,
              )
              : ResizeImage(
                CachedNetworkImageProvider(
                  url,
                  headers: _kImageHeaders,
                  cacheManager: AppCacheManager.instance,
                ),
                width: thumbW,
              );
      precacheImage(provider, context, onError: (_, _) {});
    }
  }

  Future<void> prewarmAndAwait(
    List<String> urls,
    BuildContext context, {
    bool isHD = false,
  }) async {
    if (urls.isEmpty) return;

    // Skip awaiting online network images when offline to render cached/fallback items instantly
    if (NetworkQualityService().quality.value == NetworkQuality.offline) {
      return;
    }

    // Filter valid URLs
    final validUrls = urls.where((u) => isValidImageUrl(u)).toList();
    if (validUrls.isEmpty) return;

    final thumbW = _thumbWidth;

    // Run precaching for all of them in parallel
    await Future.wait(
      validUrls.map((url) async {
        // Bail out if the context element has been unmounted (e.g. user navigated away).
        if (!(context as Element).mounted) return;
        try {
          final ImageProvider provider =
              thumbW == null
                  ? CachedNetworkImageProvider(
                    url,
                    headers: _kImageHeaders,
                    cacheManager: AppCacheManager.instance,
                  )
                  : ResizeImage(
                    CachedNetworkImageProvider(
                      url,
                      headers: _kImageHeaders,
                      cacheManager: AppCacheManager.instance,
                    ),
                    width: thumbW,
                  );
          await precacheImage(provider, context, onError: (_, _) {});
        } catch (_) {}
      }),
      eagerError: false,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAST THUMBNAIL WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class FastThumbnail extends StatefulWidget {
  final String? url;
  final double width;
  final double height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final int? cacheWidth;
  final String? title;
  final bool isSeries;
  final bool useTMDBFallback;
  final VoidCallback? onError;
  final bool isHD;

  const FastThumbnail({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.title,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.cacheWidth,
    this.isSeries = false,
    this.useTMDBFallback = false,
    this.onError,
    this.isHD = false,
  });

  @override
  State<FastThumbnail> createState() => _FastThumbnailState();
}

class _FastThumbnailState extends State<FastThumbnail>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  ImageProvider? _cachedProvider;
  int? _effectiveCacheWidth;
  String? _fallbackUrl;
  bool _isResolvingFallback = false;

  // Silent retry state — NEVER gives up permanently.
  // Uses exponential backoff with cap at 30s.
  int _retryCount = 0;
  Timer? _retryTimer;
  Timer? _hardTimeoutTimer;
  // Cuántas veces disparó ya el hard timeout — alarga el margen y decide
  // a partir de cuándo vale la pena borrar el caché de disco.
  int _hardTimeoutCount = 0;
  int _imageKey = 0;
  bool _hasLoaded = false;

  /// Evita reintentos superpuestos. Al mismo `_performRetry` pueden llegar a la
  /// vez el toque del usuario, el hard timeout y el tracker de reanudación de la
  /// app; encadenar dos borrados de caché sobre la misma URL solo desperdicia
  /// trabajo y puede tirar lo que la otra pasada acababa de bajar.
  bool _reintentoEnVuelo = false;

  // Retry intervals with exponential backoff, capped at 30s.
  // After index 7, all retries use 30s.
  static const List<int> _retryDelays = [1, 2, 4, 8, 15, 20, 25, 30];

  @override
  void initState() {
    super.initState();
    final url = _resolveUrl();
    final wasAlreadyLoaded = url != null && _loadedUrls.contains(url);

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: wasAlreadyLoaded ? 1.0 : 0.0,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _effectiveCacheWidth = _computeCacheWidth();
    _checkAndResolveFallback();
    // Register for app resume retries
    _FailedImageTracker.instance.register(_onAppResumeRetry);
    _resetHardTimeout(); // ← NUEVO: Iniciar el hard timeout
  }

  void _checkAndResolveFallback() async {
    if (!widget.useTMDBFallback || widget.title == null) return;
    if (FastImageService.isValidImageUrl(widget.url)) return;
    if (_fallbackUrl != null || _isResolvingFallback) return;

    setState(() => _isResolvingFallback = true);
    final url = await MetadataFallbackService().getFallbackPoster(
      widget.title!,
      isSeries: widget.isSeries,
    );
    if (mounted) {
      setState(() {
        _fallbackUrl = url;
        _isResolvingFallback = false;
      });
    }
  }

  int? _computeCacheWidth() {
    // Return null to ensure cover arts are always rendered at full resolution/original size,
    // avoiding any pixelation or low-quality scaling as requested by the user.
    return null;
  }

  @override
  void didUpdateWidget(FastThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _cachedProvider = null;
      _fallbackUrl = null;
      _effectiveCacheWidth = _computeCacheWidth();

      final url = _resolveUrl();
      final wasAlreadyLoaded = url != null && _loadedUrls.contains(url);
      if (wasAlreadyLoaded) {
        _fadeController.value = 1.0;
      } else {
        _fadeController.reset();
      }

      _retryCount = 0;
      _hardTimeoutCount = 0;
      _retryTimer?.cancel();
      _hasLoaded = false;
      _imageKey = 0;
      _checkAndResolveFallback();
      _resetHardTimeout();
    }
  }

  /// Called when the app resumes from background — retry if image hasn't loaded.
  void _onAppResumeRetry() {
    if (!mounted || _hasLoaded) return;
    // Reset retry count so the user gets fresh attempts after resume
    _retryCount = 0;
    _hardTimeoutCount = 0;
    _performRetry();
  }

  /// Silently retry loading the image after an adaptive delay.
  /// NEVER gives up — uses exponential backoff with 30s cap.
  /// Non-retryable errors (404, 403, HTML responses) stop immediately.
  void _scheduleRetry(Object error) {
    if (!mounted || _hasLoaded) return;

    // Errores "permanentes" (404 / 403 / respuesta HTML): NO se abandona.
    //
    // Antes esto hacia `return` y la caratula quedaba MUERTA hasta reiniciar la
    // app — que es exactamente el sintoma reportado. Pero un 404 aqui casi
    // nunca es definitivo: el origen sobrecargado responde 404, y encima el VPS
    // cachea esa respuesta un rato. Con un backoff largo la imagen se recupera
    // sola en cuanto esa respuesta caduca, sin que el usuario haga nada.
    final bool permanente = !_isRetryableError(error);

    // Don't schedule if offline — _FailedImageTracker will auto-retry
    // when network recovers
    if (NetworkQualityService().quality.value == NetworkQuality.offline) {
      return;
    }

    // Backoff normal para fallos transitorios; mucho mas espaciado para los
    // "permanentes", que no conviene machacar pero tampoco dar por perdidos.
    final Duration delay;
    if (permanente) {
      delay = Duration(seconds: 45 * (1 << _retryCount.clamp(0, 3)));
    } else {
      delay = Duration(
        seconds: _retryDelays[_retryCount.clamp(0, _retryDelays.length - 1)],
      );
    }
    _retryCount++;
    _retryTimer?.cancel();

    _retryTimer = Timer(delay, () {
      if (!mounted || _hasLoaded) return;
      _performRetry();
    });
  }

  /// Core retry logic shared by timer-based and app-resume retries.
  /// Awaits cache eviction before triggering a rebuild to guarantee
  /// the corrupted file is gone before a fresh download starts.
  Future<void> _performRetry({bool evictCache = true}) async {
    if (!mounted || _hasLoaded || _reintentoEnVuelo) return;
    _reintentoEnVuelo = true;
    try {
      await _performRetryInterno(evictCache: evictCache);
    } finally {
      _reintentoEnVuelo = false;
    }
  }

  Future<void> _performRetryInterno({bool evictCache = true}) async {
    final url = _resolveUrl();
    // FIX: con evictCache=false no se borra nada y sólo se vuelve a enganchar
    // el stream. Es lo que usa el hard timeout en sus primeros disparos: una
    // descarga lenta pero sana no debe perder el progreso ya bajado.
    if (url != null && evictCache) {
      // 1. Evict from disk cache FIRST and wait for completion
      try {
        await AppCacheManager.instance.removeFile(url);
      } catch (_) {}

      // 2. Evict every form of this image from Flutter's in-memory cache
      //    (including ResizeImage wrappers)
      final provider = CachedNetworkImageProvider(
        url,
        headers: _kImageHeaders,
        cacheManager: AppCacheManager.instance,
      );
      try {
        await provider.evict();
      } catch (_) {}
      if (_effectiveCacheWidth != null) {
        try {
          await ResizeImage(provider, width: _effectiveCacheWidth!).evict();
        } catch (_) {}
      }

      // 3. Also clear from Flutter's global image cache by key
      PaintingBinding.instance.imageCache.evict(url);
    }

    if (!mounted || _hasLoaded) return;

    // 4. Drop our own cached reference
    _cachedProvider = null;

    // 5. Reset fade — image will appear seamlessly via gaplessPlayback
    _fadeController.reset();

    _resetHardTimeout(); // ← NUEVO: Reiniciar el hard timeout con cada retry

    // 6. Rebuild with new key
    setState(() {
      _imageKey++;
    });
  }

  void _resetHardTimeout() {
    _hardTimeoutTimer?.cancel();
    if (_hasLoaded) return;
    // Si en N segundos no hay frame ni error → forzar retry
    final base = switch (NetworkQualityService().quality.value) {
      NetworkQuality.excellent || NetworkQuality.good => 5,
      NetworkQuality.fair => 7,
      NetworkQuality.poor => 10,
      NetworkQuality.offline => 3,
    };
    // FIX: antes el timeout era fijo y SIEMPRE borraba el caché de disco. En
    // una red lenta, una carátula que necesitaba 8s se cancelaba a los 5s, se
    // tiraba lo ya descargado y se empezaba de cero — en bucle, sin terminar
    // nunca. Ahora cada intento da más margen y los primeros no borran nada.
    final seconds = base * (1 << _hardTimeoutCount.clamp(0, 3));
    _hardTimeoutTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted || _hasLoaded) return;
      _hardTimeoutCount++;
      _performRetry(evictCache: _hardTimeoutCount > 2);
    });
  }

  /// Resolve the effective image URL (primary or fallback), trimmed and CDN-optimized.
  String? _resolveUrl() {
    final String? raw =
        FastImageService.isValidImageUrl(widget.url)
            ? widget.url
            : _fallbackUrl;
    if (raw == null) return null;
    String clean = raw.trim();

    // Determine target CDN parameters based on whether HD is requested (Hero Banners & Details Screen)
    final String targetParams =
        widget.isHD
            ? 'imageView2/1/w/700/h/1050/format/webp/q/88'
            : 'imageView2/1/w/300/h/450/format/webp/q/82';

    // Upgrade or adjust existing params if present
    if (clean.contains('imageView2')) {
      if (widget.isHD) {
        clean = clean.replaceAll(
          RegExp(r'imageView2\/1\/w\/\d+\/h\/\d+\/format\/webp\/q\/\d+'),
          targetParams,
        );
      }
    } else if ((clean.contains('img.') || clean.contains('/cover/')) &&
        !clean.contains('imageMogr2')) {
      clean = clean.replaceAll(RegExp(r'!$'), '');
      final separator = clean.contains('?') ? '&' : '?';
      clean = '$clean$separator$targetParams';
    }

    // Optimizar URLs directas de TMDB asignando w185 (para cuadrículas, ~18KB) o w500 (pantalla de detalle)
    if (clean.contains('image.tmdb.org/t/p/')) {
      final String tmdbTargetSize = widget.isHD ? 'w500' : 'w185';
      clean = clean.replaceAll(
        RegExp(r'\/t\/p\/(w\d+(_and_h\d+_\w+)?|original)\/'),
        '/t/p/$tmdbTargetSize/',
      );
    }

    return clean;
  }

  @override
  void dispose() {
    _FailedImageTracker.instance.unregister(_onAppResumeRetry);
    _fadeController.dispose();
    _retryTimer?.cancel();
    _hardTimeoutTimer?.cancel(); // ← NUEVO
    super.dispose();
  }

  ImageProvider _getProvider() {
    if (_cachedProvider != null) return _cachedProvider!;

    final String? imageTarget = _resolveUrl();

    if (imageTarget == null || imageTarget.isEmpty) {
      return const AssetImage('assets/placeholder.png');
    }

    ImageProvider provider = CachedNetworkImageProvider(
      imageTarget,
      headers: _kImageHeaders,
      cacheManager: AppCacheManager.instance,
    );

    if (_effectiveCacheWidth != null) {
      provider = ResizeImage(provider, width: _effectiveCacheWidth!);
    }
    _cachedProvider = provider;
    return provider;
  }

  /// Marcador de posicion mientras la caratula no esta.
  ///
  /// Sin boton de reintento ni gesto de toque: los reintentos ocurren SOLOS en
  /// segundo plano (ver _scheduleRetry y _resetHardTimeout). El boton daba una
  /// falsa sensacion de control —en las cuadriculas el toque se lo llevaba la
  /// navegacion al detalle, asi que no pasaba nada— y encima ensuciaba el
  /// diseño mostrando un icono de error en cada hueco.
  Widget _placeholder() {
    final bool isLow = PerformanceService().isLowPerformance;

    return Container(
      width: widget.width,
      height: widget.height,
      color: const Color(0xFF1a1a1a),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.title != null && !isLow)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  widget.title!,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            )
          else
            Center(
              child: Icon(
                Icons.movie_creation_outlined,
                color: Colors.white.withValues(alpha: 0.1),
                size: 30,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    final bool hasValidPrimary = FastImageService.isValidImageUrl(widget.url);
    final bool hasValidFallback = FastImageService.isValidImageUrl(
      _fallbackUrl,
    );

    if (!hasValidPrimary && !hasValidFallback) {
      content = _placeholder();
    } else {
      content = Stack(
        children: [
          _placeholder(),
          FadeTransition(
            opacity: _fadeAnimation,
            child: Image(
              key: ValueKey('thumb_$_imageKey'),
              image: _getProvider(),
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                // FIX: frame == null significa que la imagen TODAVÍA se está
                // cargando. Antes se marcaba _hasLoaded=true en esa primera
                // llamada, se cancelaba el hard timeout y se desregistraba del
                // tracker de reintentos. Consecuencia: una carátula que nunca
                // terminaba de bajar quedaba marcada como cargada para siempre
                // y ya no se recuperaba — ni con reintentos ni al volver a la
                // app. Sólo contamos como cargada si de verdad llegó un frame.
                final bool hasFrame = frame != null || wasSynchronouslyLoaded;
                if (hasFrame && !_hasLoaded) {
                  _hasLoaded = true;
                  _hardTimeoutTimer?.cancel();
                  final url = _resolveUrl();
                  if (url != null) {
                    if (_loadedUrls.length > 4000) {
                      _loadedUrls.clear(); // evitar leak
                    }
                    _loadedUrls.add(url);
                  }
                  _FailedImageTracker.instance.unregister(_onAppResumeRetry);
                }

                if (wasSynchronouslyLoaded) {
                  if (!_fadeController.isCompleted) {
                    SchedulerBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _fadeController.value = 1.0;
                    });
                  }
                  return child;
                }
                if (frame == null) return const SizedBox.shrink();
                if (!_fadeController.isCompleted) {
                  SchedulerBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _fadeController.forward();
                  });
                }
                return child;
              },
              errorBuilder: (context, error, stackTrace) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _scheduleRetry(error);
                });
                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      );
    }

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: content);
    }
    return content;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAST CHANNEL LOGO WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class FastChannelLogo extends StatefulWidget {
  final String? url;
  final double size;
  final BorderRadius? borderRadius;
  final VoidCallback? onError;

  const FastChannelLogo({
    super.key,
    required this.url,
    this.size = 48,
    this.borderRadius,
    this.onError,
  });

  @override
  State<FastChannelLogo> createState() => _FastChannelLogoState();
}

class _FastChannelLogoState extends State<FastChannelLogo>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  ImageProvider? _cachedProvider;

  // Silent retry state — NEVER gives up permanently.
  int _retryCount = 0;
  Timer? _retryTimer;
  Timer? _hardTimeoutTimer;
  int _hardTimeoutCount = 0;
  int _imageKey = 0;
  bool _hasLoaded = false;

  // Retry intervals with exponential backoff, capped at 30s.
  static const List<int> _retryDelays = [1, 2, 4, 8, 15, 20, 25, 30];

  @override
  void initState() {
    super.initState();
    final url = widget.url?.trim();
    final wasAlreadyLoaded = url != null && _loadedUrls.contains(url);

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: wasAlreadyLoaded ? 1.0 : 0.0,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    // Register for app resume retries
    _FailedImageTracker.instance.register(_onAppResumeRetry);
    _resetHardTimeout(); // ← NUEVO: Iniciar el hard timeout
  }

  @override
  void didUpdateWidget(FastChannelLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _cachedProvider = null;

      final url = widget.url?.trim();
      final wasAlreadyLoaded = url != null && _loadedUrls.contains(url);
      if (wasAlreadyLoaded) {
        _fadeController.value = 1.0;
      } else {
        _fadeController.reset();
      }

      _retryCount = 0;
      _hardTimeoutCount = 0;
      _retryTimer?.cancel();
      _hasLoaded = false;
      _imageKey = 0;
      _resetHardTimeout();
    }
  }

  /// Called when the app resumes from background — retry if image hasn't loaded.
  void _onAppResumeRetry() {
    if (!mounted || _hasLoaded) return;
    _retryCount = 0;
    _hardTimeoutCount = 0;
    _performRetry();
  }

  void _scheduleRetry(Object error) {
    if (!mounted || _hasLoaded) return;

    // Truly permanent errors — stop but allow network-recovery retries
    if (!_isRetryableError(error)) {
      return;
    }

    // Don't schedule if offline — _FailedImageTracker auto-retries on recovery
    if (NetworkQualityService().quality.value == NetworkQuality.offline) {
      return;
    }

    final delayIndex = _retryCount.clamp(0, _retryDelays.length - 1);
    final delay = Duration(seconds: _retryDelays[delayIndex]);
    _retryCount++;
    _retryTimer?.cancel();

    _retryTimer = Timer(delay, () {
      if (!mounted || _hasLoaded) return;
      _performRetry();
    });
  }

  /// Core retry logic shared by timer-based and app-resume retries.
  Future<void> _performRetry({bool evictCache = true}) async {
    if (!mounted || _hasLoaded) return;

    final url = widget.url?.trim();
    if (url != null && evictCache) {
      // Evict from disk cache FIRST and wait for completion
      try {
        await AppCacheManager.instance.removeFile(url);
      } catch (_) {}

      // Evict every form from Flutter's in-memory cache
      final provider = CachedNetworkImageProvider(
        url,
        headers: _kImageHeaders,
        cacheManager: AppCacheManager.instance,
      );
      try {
        await provider.evict();
      } catch (_) {}
      try {
        await ResizeImage(provider, width: widget.size.toInt() * 2).evict();
      } catch (_) {}

      // Also clear from Flutter's global image cache
      PaintingBinding.instance.imageCache.evict(url);
    }

    if (!mounted || _hasLoaded) return;

    _cachedProvider = null;
    _fadeController.reset();

    _resetHardTimeout(); // ← NUEVO: Reiniciar el hard timeout con cada retry

    setState(() {
      _imageKey++;
    });
  }

  void _resetHardTimeout() {
    _hardTimeoutTimer?.cancel();
    if (_hasLoaded) return;
    // Si en N segundos no hay frame ni error → forzar retry
    final base = switch (NetworkQualityService().quality.value) {
      NetworkQuality.excellent || NetworkQuality.good => 12,
      NetworkQuality.fair => 18,
      NetworkQuality.poor => 25,
      NetworkQuality.offline => 8,
    };
    // Mismo criterio que en FastThumbnail: margen creciente y sin borrar el
    // caché en los primeros intentos, para no matar descargas lentas sanas.
    final seconds = base * (1 << _hardTimeoutCount.clamp(0, 3));
    _hardTimeoutTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted || _hasLoaded) return;
      _hardTimeoutCount++;
      _performRetry(evictCache: _hardTimeoutCount > 2);
    });
  }

  @override
  void dispose() {
    _FailedImageTracker.instance.unregister(_onAppResumeRetry);
    _fadeController.dispose();
    _retryTimer?.cancel();
    _hardTimeoutTimer?.cancel(); // ← NUEVO
    super.dispose();
  }

  ImageProvider _getProvider() {
    if (_cachedProvider != null) return _cachedProvider!;
    _cachedProvider = ResizeImage(
      CachedNetworkImageProvider(
        widget.url!.trim(),
        headers: _kImageHeaders,
        cacheManager: AppCacheManager.instance,
      ),
      width: widget.size.toInt() * 2,
    );
    return _cachedProvider!;
  }

  @override
  Widget build(BuildContext context) {
    final child = _buildImage();
    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: child);
    }
    return child;
  }

  Widget _buildImage() {
    if (!FastImageService.isValidImageUrl(widget.url)) return _placeholder();

    return Stack(
      children: [
        _placeholder(),
        FadeTransition(
          opacity: _fadeAnimation,
          child: Image(
            key: ValueKey('logo_$_imageKey'),
            image: _getProvider(),
            width: widget.size,
            height: widget.size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              // FIX: ver la nota en FastThumbnail — frame == null es "cargando
              // todavía", no "cargada". Marcarla aquí dejaba los logos que
              // fallaban sin ningún reintento posible.
              final bool hasFrame = frame != null || wasSynchronouslyLoaded;
              if (hasFrame && !_hasLoaded) {
                _hasLoaded = true;
                _hardTimeoutTimer?.cancel();
                final url = widget.url?.trim();
                if (url != null) {
                  if (_loadedUrls.length > 4000) {
                    _loadedUrls.clear(); // evitar leak
                  }
                  _loadedUrls.add(url);
                }
                _FailedImageTracker.instance.unregister(_onAppResumeRetry);
              }

              if (wasSynchronouslyLoaded) {
                if (!_fadeController.isCompleted) {
                  SchedulerBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _fadeController.value = 1.0;
                  });
                }
                return child;
              }
              if (frame == null) return const SizedBox.shrink();
              if (!_fadeController.isCompleted) {
                SchedulerBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _fadeController.forward();
                });
              }
              return child;
            },
            errorBuilder: (context, error, stackTrace) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _scheduleRetry(error);
              });
              return const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }

  Widget _placeholder() {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_hasLoaded) {
          _performRetry();
        }
      },
      child:
          PerformanceService().isLowPerformance
              ? SizedBox(
                width: widget.size,
                height: widget.size,
                child: const Center(
                  child: Icon(Icons.tv, color: Color(0xFF2d2d2d), size: 20),
                ),
              )
              : Container(
                width: widget.size,
                height: widget.size,
                decoration: const BoxDecoration(
                  color: Color(0xFF1a1a1a),
                  shape: BoxShape.circle,
                ),
              ),
    );
  }
}
