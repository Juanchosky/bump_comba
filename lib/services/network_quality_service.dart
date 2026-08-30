import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

enum NetworkQuality {
  excellent, // >5 Mbps efectivos al stream
  good, // 2–5 Mbps
  fair, // 0.8–2 Mbps
  poor, // <0.8 Mbps
  offline,
}

class NetworkQualityService {
  static final NetworkQualityService _instance =
      NetworkQualityService._internal();
  factory NetworkQualityService() => _instance;
  NetworkQualityService._internal();

  final ValueNotifier<NetworkQuality> quality = ValueNotifier(
    NetworkQuality.excellent,
  );
  final ValueNotifier<double> estimatedBandwidthMbps = ValueNotifier(10.0);
  final ValueNotifier<int> latencyMs = ValueNotifier(0);
  final ValueNotifier<bool> isMobileData = ValueNotifier(false);

  int _measureCount = 0;
  NetworkQuality _lastLoggedQuality = NetworkQuality.excellent;

  Timer? _pollTimer;
  final Connectivity _connectivity = Connectivity();
  StreamSubscription? _connectivitySub;

  // URL del stream actual — se actualiza desde VideoPlayerScreen
  String? _activeStreamUrl;

  // Historial de mediciones REALES (contra el stream)
  final List<double> _bandwidthHistory = [];
  static const int _historySize = 4;

  // Anti-flicker: solo degradar si 2 mediciones seguidas son malas
  int _consecutiveGoodReadings = 0;

  // Throughput REAL del stream reportado por el player (cache-speed de MPV).
  // Cuando existe y es reciente, sustituye a la heurística latencia→Mbps,
  // que da falsos positivos con servidores lejanos (150ms+ de RTT no implica
  // poco ancho de banda).
  double? _lastRealMbps;
  DateTime? _lastRealMbpsAt;

  // Anti-falso-positivo de "offline": una señal aislada de "sin conexión"
  // suele ser un blip transitorio (reabrir la app, despertar el teléfono,
  // cambio de red) que se resuelve en menos de un segundo. Solo mostramos
  // el banner si la desconexión se confirma en una segunda lectura rápida.
  int _consecutiveOfflineSignals = 0;
  Timer? _offlineConfirmTimer;

  /// Llamar desde VideoPlayerScreen cuando cambia el stream activo
  void setActiveStreamUrl(String? url) {
    if (url == null) {
      _activeStreamUrl = null;
      _bandwidthHistory.clear();
      _consecutiveGoodReadings = 0;
      return;
    }

    final oldUrl = _activeStreamUrl;
    _activeStreamUrl = url;

    if (oldUrl != null) {
      try {
        final oldUri = Uri.parse(oldUrl);
        final newUri = Uri.parse(url);
        if (oldUri.host == newUri.host) {
          // Same host/server (e.g. local retry or alternative on same host), do NOT reset history/readings!
          debugPrint(
            'NetworkQualityService: Same host detected. Retaining network quality history.',
          );
          // Trigger an immediate background measurement check to stay up to date
          unawaited(_measure());
          return;
        }
      } catch (_) {}
    }

    // Different host: reset history but trigger immediate measurement so we have an estimate within 800ms
    _bandwidthHistory.clear();
    _consecutiveGoodReadings = 0;
    unawaited(_measure());
  }

  bool _isGlobalStarted = false;

  /// Iniciar el servicio de forma global (persistente en la app).
  void startGlobal() {
    if (_isGlobalStarted) return;
    _isGlobalStarted = true;
    start();
  }

  /// Forzar una medición manual de conectividad.
  Future<void> measureManual() async {
    await _measure();
  }

  /// El player reporta la velocidad real de descarga del stream (Mbps).
  ///
  /// [hayHambre] distingue los DOS ceros opuestos, que antes se trataban
  /// igual y por eso se descartaban los dos:
  ///
  ///  - cero con el bufer lleno  -> MPV dejo de descargar porque no necesita
  ///    nada. No dice nada de la red. Se ignora, como antes.
  ///  - cero con el bufer al borde -> necesitamos datos y NO estan llegando.
  ///    Es la peor noticia posible sobre la red, y era justo la que se tiraba
  ///    a la basura.
  ///
  /// Descartar los dos por igual dejaba al clasificador viendo solo lecturas
  /// buenas: cuando la red se caia de verdad no llegaba ninguna muestra, la
  /// ultima buena envejecia mas de 30s y `_measure` caia al fallback de
  /// "inferido del tipo de red" — 3.00 Mbps porque hay WiFi. En el log se leia
  /// `NetworkQuality: good` con el bufer agonizando.
  void reportStreamThroughput(double mbps, {bool hayHambre = false}) {
    if (mbps <= 0 && !hayHambre) return;
    _lastRealMbps = mbps < 0 ? 0 : mbps;
    _lastRealMbpsAt = DateTime.now();
  }

  void start() {
    _connectivitySub?.cancel();
    try {
      _connectivitySub = _connectivity.onConnectivityChanged.listen((results) {
        _updateConnectionType(results);
        _measure();
      });
    } catch (e) {
      debugPrint('NetworkQualityService: error listening to connectivity: $e');
    }
    _pollTimer?.cancel();
    // Medir cada 20s — más espaciado para no interferir con el stream
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) => _measure());
    // Primera medición a los 3s (esperar a que el stream esté corriendo)
    Future.delayed(const Duration(seconds: 3), _measure);
  }

  void stop() {
    if (_isGlobalStarted) {
      _activeStreamUrl = null;
      return;
    }
    _pollTimer?.cancel();
    _connectivitySub?.cancel();
    _offlineConfirmTimer?.cancel();
    _activeStreamUrl = null;
  }

  void _updateConnectionType(List<ConnectivityResult> results) {
    final isMobile =
        results.contains(ConnectivityResult.mobile) &&
        !results.contains(ConnectivityResult.wifi);
    isMobileData.value = isMobile;
  }

  Future<void> _measure() async {
    List<ConnectivityResult> results = [ConnectivityResult.wifi];
    try {
      results = await _connectivity.checkConnectivity();
      _updateConnectionType(results);
    } catch (e) {
      debugPrint('NetworkQualityService: error checking connectivity: $e');
      isMobileData.value = false;
    }

    if (results.contains(ConnectivityResult.none)) {
      _handlePotentialOffline();
      return;
    }
    _offlineConfirmTimer?.cancel();
    _consecutiveOfflineSignals = 0;

    // ESTRATEGIA: Medir latencia + throughput contra el servidor del stream
    // Si no hay stream activo, usar conectividad básica solamente
    final streamUrl = _activeStreamUrl;

    double bandwidth;
    int latency;
    // De donde salio el numero de esta muestra. El valor puede venir de una
    // medida real del reproductor o de una estimacion a partir de la latencia,
    // y el log no lo distinguia: se leia "0.30 Mbps" como si se hubiera medido
    // el ancho de banda, cuando lo que se midio fue un handshake TCP.
    //
    // El 2026-08-22 eso mando a buscar el problema en el VPS y en el proxy
    // durante un buen rato; la estimacion resulto correcta (0.30 estimado vs
    // 0.34 real en el test de velocidad), pero saber que era una estimacion
    // habria acortado el camino.
    String origen;

    if (streamUrl != null && streamUrl.startsWith('http')) {
      // Medir directamente contra el servidor IPTV
      final result = await _measureAgainstStream(streamUrl);
      bandwidth = result.$1;
      latency = result.$2;
      origen = 'estimado por latencia';
    } else {
      // Fallback: solo tipo de conexión (sin medición activa para no gastar datos)
      bandwidth = _inferBandwidthFromConnectionType(results);
      latency = 100;
      origen = 'inferido del tipo de red';
    }

    // Si el player reportó throughput real recientemente, esa es LA medida:
    // la estimación por latencia solo se usa como fallback.
    final realAt = _lastRealMbpsAt;
    final bool medidoPorReproductor =
        realAt != null && DateTime.now().difference(realAt).inSeconds < 30;
    if (medidoPorReproductor) {
      bandwidth = _lastRealMbps!;
      origen = 'medido por el reproductor';
    }

    // Actualizar historial.
    //
    // La medida del reproductor entra SIEMPRE, aunque sea 0: si llego hasta
    // aqui es porque el reproductor confirmo que tenia hambre (ver
    // `reportStreamThroughput`), y un 0 con hambre es un dato, no un hueco.
    // El `> 0` de las otras dos fuentes se mantiene: ahi un 0 significa que
    // la medicion fallo, que no es lo mismo que medir cero.
    if (bandwidth > 0 || medidoPorReproductor) {
      _bandwidthHistory.add(bandwidth);
      if (_bandwidthHistory.length > _historySize) {
        _bandwidthHistory.removeAt(0);
      }
    }

    final smoothBandwidth =
        _bandwidthHistory.isNotEmpty
            ? _bandwidthHistory.reduce((a, b) => a + b) /
                _bandwidthHistory.length
            : bandwidth;

    estimatedBandwidthMbps.value = smoothBandwidth;
    latencyMs.value = latency;

    final newQuality = _calculateQuality(smoothBandwidth, latency);
    _applyQualityWithHysteresis(newQuality);

    // Solo imprimir si la calidad cambió o cada 4 mediciones
    _measureCount = (_measureCount + 1) % 4;
    if (_measureCount == 0 || quality.value != _lastLoggedQuality) {
      _lastLoggedQuality = quality.value;
      debugPrint(
        'NetworkQuality: ${quality.value.name} | '
        '${smoothBandwidth.toStringAsFixed(2)} Mbps ($origen) | ${latency}ms | '
        'Mobile: ${isMobileData.value}',
      );
    }
  }

  /// Una lectura de "sin conexión" puede ser un blip transitorio (reabrir la
  /// app, encender la pantalla, cambio de red). Solo confirmamos offline —y
  /// por lo tanto mostramos el banner— si una segunda lectura, tomada
  /// rápidamente, sigue reportando sin conexión.
  void _handlePotentialOffline() {
    _consecutiveOfflineSignals++;
    if (_consecutiveOfflineSignals >= 2) {
      _applyQuality(NetworkQuality.offline, 0, 9999);
      return;
    }
    _offlineConfirmTimer?.cancel();
    _offlineConfirmTimer = Timer(const Duration(milliseconds: 1200), _measure);
  }

  /// Mide la latencia TCP al servidor del stream REAL y estima el ancho de banda.
  Future<(double mbps, int latencyMs)> _measureAgainstStream(
    String streamUrl,
  ) async {
    try {
      final uri = Uri.parse(streamUrl);
      final host = uri.host;
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

      // SOLO medir latencia TCP — cero bytes de descarga del stream.
      // La latencia TCP al servidor IPTV es el mejor indicador de
      // calidad de conexión sin competir con el buffer del player.
      final sw = Stopwatch()..start();
      Socket? socket;
      try {
        socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 4),
        );
        final latency = sw.elapsedMilliseconds;
        socket.destroy();

        // Estimar ancho de banda desde la latencia + tipo de conexión.
        final bwEstimate = _estimateBandwidthFromLatency(latency);
        return (bwEstimate, latency);
      } catch (_) {
        socket?.destroy();
        // No se pudo conectar al servidor → mantener último valor conocido
        return (estimatedBandwidthMbps.value, 9999);
      }
    } catch (_) {
      return (estimatedBandwidthMbps.value, 9999);
    }
  }

  double _estimateBandwidthFromLatency(int latMs) {
    // Heurística basada en correlación latencia↔ancho de banda en redes móviles.
    // Conservadora a propósito: preferimos no degradar si no estamos seguros.
    if (latMs < 60) return 8.0; // Excelente
    if (latMs < 100) return 4.0; // Bueno
    if (latMs < 200) return 2.0; // Aceptable
    if (latMs < 400) return 0.8; // Débil
    return 0.3; // Muy malo / timeout
  }

  /// Inferir ancho de banda mínimo garantizado según tipo de conexión,
  /// sin hacer ninguna petición de red.
  double _inferBandwidthFromConnectionType(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) return 5.0;
    if (results.contains(ConnectivityResult.mobile)) {
      // En Colombia, 4G típico = ~10 Mbps, 3G = ~2 Mbps, Edge = ~0.3 Mbps
      // Sin poder distinguir, asumir 4G como baseline conservador
      return 3.0;
    }
    if (results.contains(ConnectivityResult.ethernet)) return 20.0;
    return 1.0;
  }

  NetworkQuality _calculateQuality(double mbps, int latMs) {
    // Penalizar latencia alta (>300ms = red inestable aunque tenga ancho de banda)
    final latencyPenalty = latMs > 300 ? 0.5 : (latMs > 150 ? 0.75 : 1.0);
    final effective = mbps * latencyPenalty;

    // Penalizar datos móviles (más variable)
    final mobilePenalty = isMobileData.value ? 0.8 : 1.0;
    final finalEffective = effective * mobilePenalty;

    if (finalEffective >= 5.0) return NetworkQuality.excellent;
    if (finalEffective >= 2.0) return NetworkQuality.good;
    if (finalEffective >= 0.8) return NetworkQuality.fair;
    return NetworkQuality.poor;
  }

  void _applyQualityWithHysteresis(NetworkQuality newQuality) {
    if (newQuality == quality.value) {
      _consecutiveGoodReadings = 0;
      return;
    }

    final isDegrading = newQuality.index > quality.value.index;
    final isImproving = newQuality.index < quality.value.index;

    if (isDegrading) {
      _consecutiveGoodReadings = 0;

      // Degradar se aplica SIEMPRE en la primera lectura.
      //
      // FIX: antes habia una rama para offline/poor, otra para fair, y
      // NINGUNA para good. Una caida de excellent a good no se aplicaba jamas:
      // la app se quedaba clavada en excellent hasta que la red se desplomara
      // del todo hasta fair. Eso es lo que producia lineas como
      // "NetworkQuality: excellent | 2.00 Mbps" en el log — y con esa etiqueta
      // la app usaba 18 descargas de imagen en paralelo, timeouts de 4s y
      // margenes de 600ms sobre un enlace de 2 Mbps, que es justo la receta
      // para los atascos del arranque.
      //
      // Bajar es la direccion segura: equivocarse hacia abajo cuesta algo de
      // velocidad, equivocarse hacia arriba cuesta stalls. Subir sigue
      // exigiendo 3 lecturas consecutivas, que es donde la histeresis si
      // aporta (evita oscilar con un bache pasajero).
      _applyQuality(newQuality, estimatedBandwidthMbps.value, latencyMs.value);
    } else if (isImproving) {
      // Si la calidad anterior era 'offline', recuperamos inmediatamente
      // para evitar quedar atascados por 60 segundos debido a la histeresis
      if (quality.value == NetworkQuality.offline) {
        _consecutiveGoodReadings = 0;
        _applyQuality(
          newQuality,
          estimatedBandwidthMbps.value,
          latencyMs.value,
        );
        return;
      }

      _consecutiveGoodReadings++;
      // Subir calidad solo con 3 lecturas consecutivas buenas
      if (_consecutiveGoodReadings >= 3) {
        _consecutiveGoodReadings = 0;
        _applyQuality(
          newQuality,
          estimatedBandwidthMbps.value,
          latencyMs.value,
        );
      }
    }
  }

  void _applyQuality(NetworkQuality q, double bw, int lat) {
    // Solo emitir si realmente cambió el valor
    if (quality.value == q) return;
    quality.value = q;
  }

  bool canStreamWithoutStalls({int streamBitrateKbps = 0}) {
    if (streamBitrateKbps > 0) {
      return estimatedBandwidthMbps.value >= (streamBitrateKbps / 1000.0) * 1.5;
    }
    return quality.value.index <= NetworkQuality.fair.index;
  }
}
