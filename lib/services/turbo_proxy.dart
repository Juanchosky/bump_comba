import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/dns_bypass_utils.dart';

enum _ProxyMode { passthrough, turbo }

/// Métricas de rendimiento observables en tiempo real para paneles de diagnóstico UI.
class TurboMetrics {
  /// Tiempo hasta el primer byte entregado al reproductor (ms). NO es TTFF real
  /// (que requiere decodificación); es el momento en que las cabeceras HTTP y los
  /// primeros bytes están disponibles para el demuxer de MPV.
  final int ttfbMs;
  final bool turboActivated;
  final int turboActivationTimeSec;
  final int maxConnectionsUsed;

  /// Intervenciones preventivas del Turbo. Indica cuántas veces el sistema
  /// conmutó a modo paralelo por velocidad baja o stall detectado.
  /// NO confirma que se evitó un rebuffer; es una intervención, no una garantía.
  final int turboInterventions;

  /// Duración real medida en milisegundos que el pipeline Turbo estuvo activo.
  final int turboActiveDurationMs;
  final String host;
  final String hostLearningSummary;

  /// true si la sesión reutilizó una conexión precalentada por [TurboProxy.preconnect].
  final bool wasPreconnected;

  TurboMetrics({
    this.ttfbMs = 0,
    this.turboActivated = false,
    this.turboActivationTimeSec = 0,
    this.maxConnectionsUsed = 1,
    this.turboInterventions = 0,
    this.turboActiveDurationMs = 0,
    this.host = '',
    this.hostLearningSummary = 'Sin perfil',
    this.wasPreconnected = false,
  });
}

/// Rastreador de velocidad deslizante en ventana de 500 ms con detección de stalls.
class _SlidingSpeedTracker {
  final int windowMs;
  final List<({DateTime time, int bytes})> _samples = [];
  DateTime _lastChunkTime = DateTime.now();

  _SlidingSpeedTracker({this.windowMs = 500});

  void add(int bytes) {
    final now = DateTime.now();
    _lastChunkTime = now;
    _samples.add((time: now, bytes: bytes));
    _prune(now);
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(Duration(milliseconds: windowMs));
    _samples.removeWhere((s) => s.time.isBefore(cutoff));
  }

  double get mbps {
    final now = DateTime.now();
    _prune(now);
    if (_samples.isEmpty) return 0.0;
    final totalBytes = _samples.fold<int>(0, (sum, s) => sum + s.bytes);
    final elapsedMs = now.difference(_samples.first.time).inMilliseconds;
    final duration = math.max(elapsedMs, 50);
    return (totalBytes * 8) / duration / 1000.0;
  }

  int get msSinceLastChunk =>
      DateTime.now().difference(_lastChunkTime).inMilliseconds;
}

/// Perfil de Memoria Aprendida por Host/CDN Persistente en Disco con Telemetría.
class _HostProfile {
  final String host;
  int maxWorkingParallel = 4;
  int consecutiveFailures = 0;
  bool isHostile = false;
  bool turboHelpful = false;
  double minSpeedMbps = 0.0;
  double maxSpeedMbps = 0.0;
  double avgSpeedMbps = 0.0;

  // Telemetría de efectividad acumulada
  int totalSessions = 0;
  int sessionsWithTurbo = 0;
  int sessionsWithoutTurbo = 0;

  DateTime? lastEvaluation;

  _HostProfile(this.host) : lastEvaluation = DateTime.now();

  Map<String, dynamic> toJson() => {
    'host': host,
    'maxWorkingParallel': maxWorkingParallel,
    'consecutiveFailures': consecutiveFailures,
    'isHostile': isHostile,
    'turboHelpful': turboHelpful,
    'minSpeedMbps': minSpeedMbps,
    'maxSpeedMbps': maxSpeedMbps,
    'avgSpeedMbps': avgSpeedMbps,
    'totalSessions': totalSessions,
    'sessionsWithTurbo': sessionsWithTurbo,
    'sessionsWithoutTurbo': sessionsWithoutTurbo,
    'lastEvaluation': lastEvaluation?.toIso8601String(),
  };

  factory _HostProfile.fromJson(Map<String, dynamic> json) {
    final p = _HostProfile(json['host'] as String? ?? '');
    p.maxWorkingParallel = (json['maxWorkingParallel'] as int?) ?? 4;
    p.consecutiveFailures = (json['consecutiveFailures'] as int?) ?? 0;
    p.isHostile = (json['isHostile'] as bool?) ?? false;
    p.turboHelpful = (json['turboHelpful'] as bool?) ?? false;
    p.minSpeedMbps = (json['minSpeedMbps'] as num?)?.toDouble() ?? 0.0;
    p.maxSpeedMbps = (json['maxSpeedMbps'] as num?)?.toDouble() ?? 0.0;
    p.avgSpeedMbps = (json['avgSpeedMbps'] as num?)?.toDouble() ?? 0.0;
    p.totalSessions = (json['totalSessions'] as int?) ?? 0;
    p.sessionsWithTurbo = (json['sessionsWithTurbo'] as int?) ?? 0;
    p.sessionsWithoutTurbo = (json['sessionsWithoutTurbo'] as int?) ?? 0;
    if (json['lastEvaluation'] != null) {
      p.lastEvaluation = DateTime.tryParse(json['lastEvaluation'] as String);
    }
    return p;
  }

  // --- Helpers de Decisión Automática ---
  bool get shouldPreemptivelyTurbo =>
      totalSessions >= 20 && turboUsagePercent >= 90.0;

  bool get shouldDisableTurbo =>
      totalSessions >= 10 && turboUsagePercent == 0.0;

  /// Devuelve si el host es hostil, expirando la sanción tras 30 días.
  bool get effectiveIsHostile {
    if (!isHostile) return false;
    if (lastEvaluation != null) {
      final days = DateTime.now().difference(lastEvaluation!).inDays;
      if (days >= 30) {
        // Expirar la marca hostil tras 30 días para re-evaluar el servidor
        isHostile = false;
        consecutiveFailures = 0;
        TurboProxy.instance._markProfilesDirty(); // Persistir la recuperación
        return false;
      }
    }
    return true;
  }

  /// Veces SEGUIDAS que este host respondio 200 a una peticion con Range.
  ///
  /// Es lo unico que demuestra "no sirve rangos". Va aparte de
  /// `consecutiveFailures` a proposito: ese contador lo suben tambien los
  /// cortes de conexion, que no prueban nada sobre el soporte de Range.
  /// No se persiste: cada arranque empieza limpio.
  int rangeIgnorados = 0;

  void noteSuccess(int parallel, double speedMbps) {
    consecutiveFailures = 0;
    rangeIgnorados = 0;
    turboHelpful = true;
    lastEvaluation = DateTime.now(); // Registrar fecha de éxito

    if (minSpeedMbps == 0 || speedMbps < minSpeedMbps) minSpeedMbps = speedMbps;
    if (speedMbps > maxSpeedMbps) maxSpeedMbps = speedMbps;
    // Media móvil reactiva (50% historia, 50% muestra actual)
    avgSpeedMbps =
        avgSpeedMbps == 0
            ? speedMbps
            : (avgSpeedMbps * 0.5) + (speedMbps * 0.5);
  }

  /// [porRotura] marca un corte a mitad de descarga —el origen cerró la
  /// conexión con el cuerpo a medias— para diferenciarlo de un fallo
  /// estructural del host.
  ///
  /// POR QUE ESTA DISTINCION
  /// -----------------------
  /// `isHostile` significa literalmente "este host no sirve rangos", y lo
  /// único que puede demostrarlo es un 200 en respuesta a un Range (ver el
  /// único sitio que llama sin `porRotura`). Un "Connection closed while
  /// receiving data" NO demuestra eso: normalmente es un tramo concreto del
  /// archivo que el origen corta siempre en el mismo offset.
  ///
  /// Antes ese corte escalaba hasta hostil, y como el perfil se guarda en
  /// disco y la sanción dura 30 días, UNA película con un tramo roto
  /// desactivaba Turbo para ese host —para TODAS las demás películas— durante
  /// un mes. Ahora un corte baja el paralelismo, que sí ayuda cuando el origen
  /// va justo, pero nunca llega a hostil.
  void noteFailure({bool porRotura = false, bool rangeIgnorado = false}) {
    consecutiveFailures++;
    lastEvaluation = DateTime.now();

    // ── Hostil SOLO por rangos ignorados, y solo si se repite ──────────────
    //
    // Antes era `consecutiveFailures >= 10 && !porRotura`, y ahi estaba el
    // problema: `consecutiveFailures` lo suben TAMBIEN los cortes de conexion.
    // En una pelicula grande sobre una conexion justa se llega a 10 sin
    // esfuerzo, y entonces UN solo 200 suelto —de esos que un proxy devuelve
    // en un hueco de cache— bastaba para marcar el host como hostil.
    //
    // Y hostil no es una nota al pie: se guarda en disco y dura 30 dias,
    // desactivando Turbo para TODO el contenido de ese host durante un mes.
    // Comprobado el 2026-08-22 contra 217.216.80.212: el host devuelve 206 con
    // Content-Range correcto tanto desde el byte 0 como desde mitad de archivo
    // —soporta rangos perfectamente— y aun asi la app lo habia marcado
    // "Hostil (Sin Rangos)". A partir de ahi la reproduccion queda degradada
    // sin motivo, que es justo lo que se reporto como "empeoro".
    //
    // Ahora hace falta que ignore el Range 3 veces SEGUIDAS, y un 206
    // cualquiera pone el contador a cero (ver `noteRangeOk`).
    if (rangeIgnorado) {
      rangeIgnorados++;
      if (rangeIgnorados >= 3) {
        isHostile = true;
        debugPrint(
          'TurboProxy [$host]: perfil marcado como Hostil (Sin Rangos) '
          'tras $rangeIgnorados respuestas 200 seguidas a peticiones con Range',
        );
      }
    }

    if (consecutiveFailures >= 3 && maxWorkingParallel > 2) {
      maxWorkingParallel = 2;
      debugPrint('TurboProxy [$host]: perfil restringido a máx 2 conexiones');
    } else if (consecutiveFailures >= 6 && maxWorkingParallel > 1) {
      maxWorkingParallel = 1;
      debugPrint('TurboProxy [$host]: perfil restringido a máx 1 conexión');
    }
  }

  /// El host respondio 206: la racha de rangos ignorados se corta.
  void noteRangeOk() {
    rangeIgnorados = 0;
  }

  void noteSessionEnd({required bool turboWasUsed}) {
    totalSessions++;
    if (turboWasUsed) {
      sessionsWithTurbo++;
    } else {
      sessionsWithoutTurbo++;
    }
  }

  /// Porcentaje de sesiones en las que Turbo se activó en este host.
  double get turboUsagePercent =>
      totalSessions > 0 ? (sessionsWithTurbo / totalSessions) * 100 : 0;

  String get summary =>
      isHostile
          ? 'Hostil (Sin Rangos)'
          : 'máx $maxWorkingParallel conex | '
              '${minSpeedMbps.toStringAsFixed(1)}-${maxSpeedMbps.toStringAsFixed(1)} Mbps | '
              'Turbo ${turboUsagePercent.toStringAsFixed(0)}% de $totalSessions rep.';
}

/// Entrada de una conexión "precalentada": DNS ya resuelto, TCP/TLS ya
/// establecido (vía HEAD) y, si el origen respondió, algunos metadatos
/// conocidos por adelantado (largo, tipo, soporte de Range).
///
/// El objetivo es sacar del camino crítico de Play todo lo que se pueda
/// resolver antes: DNS + TCP + TLS + primera vuelta de cabeceras.
class _PreconnectEntry {
  final HttpClient client;
  final Uri effectiveUri;
  final Map<String, String> headers;
  final int? length;
  final String? contentType;
  final bool? supportsRange;
  final DateTime createdAt;

  /// Bytes ya descargados durante el precalentamiento (el pequeño
  /// `GET Range: bytes=0-N` que se usó en vez de un `HEAD`). Si están
  /// presentes, [wrap] puede entregárselos al reproductor de inmediato sin
  /// volver a pedirlos: es tiempo real ganado, no solo un socket caliente.
  final Uint8List? primedBytes;

  _PreconnectEntry({
    required this.client,
    required this.effectiveUri,
    required this.headers,
    required this.createdAt,
    this.length,
    this.contentType,
    this.supportsRange,
    this.primedBytes,
  });
}

/// Proxy TURBO local para VOD sobre HTTP con Persistencia de Aprendizaje y Panel de Métricas.
class TurboProxy {
  TurboProxy._();
  static final TurboProxy instance = TurboProxy._();
  factory TurboProxy() => instance;

  static const String _prefsKey = 'turbo_proxy_host_profiles_v1';

  /// Versión de la limpieza de perfiles ya guardados. Subirla vuelve a
  /// ejecutar la limpieza una vez en cada instalación. Ver `_loadHostProfiles`.
  static const String _prefsCleanupKey = 'turbo_proxy_profiles_cleanup';
  /// Se sube cada vez que hay que rehabilitar perfiles mal sancionados.
  ///
  /// v3 (2026-08-22): la marca hostil se ponia con 10 fallos consecutivos de
  /// cualquier tipo mas un 200 suelto, asi que hosts que SI sirven rangos
  /// quedaron marcados "Sin Rangos" y con Turbo apagado 30 dias. Arreglado en
  /// `noteFailure`, pero la marca ya escrita en disco hay que borrarla.
  static const int _prefsCleanupVersion = 3;

  /// Bytes mínimos que una pierna de fallback tiene que entregar para contar
  /// como progreso y perdonar los reintentos acumulados. Por debajo de esto la
  /// pierna no sirvió de nada aunque el servidor haya respondido 206.
  static const int _kMinProgresoPierna = 64 * 1024;
  static const int _turboChunkSize = 1024 * 1024; // 1 MB por trozo de prefetch
  static const int _windowChunks = 8; // ~8 MB de ventana de prefetch

  /// Conexiones simultáneas permitidas CONTRA EL ORIGEN por reproducción.
  ///
  /// IMPORTANTE: las líneas Xtream se venden con un tope de conexiones
  /// concurrentes (`max_connections` en player_api.php) que se reparte entre
  /// TODOS los usuarios de la app. Con el valor anterior (4), un único
  /// espectador podía agotar él solo una línea de 3 conexiones y dejar al
  /// resto sin servicio — que era exactamente el síntoma de "se satura y se
  /// corta cada minuto".
  ///
  /// Por eso el valor por defecto es 1: una reproducción, una conexión.
  ///
  /// Para subirlo cuando se contraten más conexiones NO hace falta publicar
  /// una versión nueva: en Supabase, tabla `sys_config`, agregar la clave
  /// `turbo_max_parallel` con el valor deseado (1..8) e `is_active = true`.
  ///
  /// Regla práctica: max_connections / espectadores simultáneos esperados.
  /// Si el tope es 3 y esperás 3 espectadores a la vez, dejalo en 1.
  static int maxParallel = 1;
  static const int _parallelCeiling = 8;

  /// Aplica el valor remoto de `turbo_max_parallel`. Ignora valores inválidos.
  static void configureMaxParallel(String? raw) {
    final parsed = int.tryParse((raw ?? '').trim());
    if (parsed == null) return;
    maxParallel = parsed.clamp(1, _parallelCeiling);
    debugPrint('TurboProxy: maxParallel = $maxParallel (config remota)');
  }

  /// Techo de piernas cuando el VPS sirve el contenido desde su PROPIA cache.
  ///
  /// `maxParallel` es bajo (1-2) para no agotar la linea Xtream, que tiene 3
  /// conexiones compartidas entre todos los usuarios. Esa cuenta es correcta
  /// cuando las piernas terminan pidiendole bytes al proveedor.
  ///
  /// Pero cuando nginx responde `X-Cache: HIT` los bytes salen del disco del
  /// VPS y NO se abre ni una conexion al proveedor. Ahi el paralelismo es
  /// gratis para la linea, y es justo lo que hace falta: el VPS esta en España
  /// y los usuarios en America, con 100-150 ms de RTT. Una sola conexion TCP a
  /// esa distancia queda limitada por la ventana de congestion mucho antes que
  /// por el ancho de banda — se midio el puerto del VPS al 11% (23 de 200
  /// Mbit/s) mientras el telefono recibia 3-4 Mbps con el bufer muriendose.
  /// Ese es el patron de sierra de los logs: 0.0 -> 7.9 -> 0.3 Mbps.
  ///
  /// Varias conexiones en paralelo son el remedio clasico para eso, y aqui se
  /// pueden usar SIN arriesgar la linea del proveedor porque solo se activan
  /// cuando el contenido ya esta en el VPS.
  static int maxParallelEnCache = 4;

  static void configureMaxParallelEnCache(String? raw) {
    final parsed = int.tryParse((raw ?? '').trim());
    if (parsed == null) return;
    maxParallelEnCache = parsed.clamp(1, _parallelCeiling);
    debugPrint(
      'TurboProxy: maxParallelEnCache = $maxParallelEnCache (config remota)',
    );
  }

  /// Tiempo máximo que se conserva una conexión precalentada sin usar antes
  /// de considerarla obsoleta (el usuario pudo quedarse mirando el detalle
  /// mucho tiempo, o la IP/CDN pudo cambiar).
  static const Duration _preconnectTtl = Duration(minutes: 4);

  /// Sin entregar un byte durante este tiempo, una sesion que dice estar
  /// sirviendo se considera colgada y se puede cerrar. 45s es holgado: el
  /// timeout mas largo del pipeline son 6s por trozo, asi que una sesion sana
  /// nunca llega aqui ni con la peor red.
  static const Duration tiempoMuerta = Duration(seconds: 45);

  HttpServer? _server;
  final Map<String, _Session> _sessions = {};
  final Map<String, _HostProfile> _hostProfiles = {};
  final Map<String, _PreconnectEntry> _preconnected = {};
  int _nextId = 1;

  // Escritura diferida en disco (dirty flag + timer de 30s)
  bool _profilesDirty = false;
  Timer? _saveTimer;

  String _lastReason = 'sin usar todavía';
  String get lastReason => _lastReason;

  /// Línea de estado observable.
  final ValueNotifier<String> status = ValueNotifier<String>('turbo: inactivo');

  /// Panel de métricas detalladas en tiempo real observables desde la UI.
  final ValueNotifier<TurboMetrics> metrics = ValueNotifier<TurboMetrics>(
    TurboMetrics(),
  );

  /// Momento en que el pipe hacia el reproductor se rompió de forma
  /// INESPERADA (no por un cierre normal del cliente al salir o hacer seek).
  ///
  /// El reproductor lo consulta para distinguir "va lento" de "se rompió":
  /// en el primer caso conviene tener paciencia, en el segundo la conexión ya
  /// está muerta y esperar 35s es tiempo perdido.
  DateTime? _lastStreamBreak;
  DateTime? get lastStreamBreak => _lastStreamBreak;

  /// Devuelve true si hubo una rotura reciente Y la consume (one-shot).
  ///
  /// Es one-shot A PROPOSITO: si se dejara consultable durante una ventana de
  /// tiempo, una unica rotura haria que TODOS los stalls siguientes — incluido
  /// el de despues de recargar — usaran el umbral corto. Eso encadena recargas
  /// y termina haciendo que el reproductor abandone el servidor por completo.
  bool consumeRecentStreamBreak({
    Duration within = const Duration(seconds: 15),
  }) {
    final t = _lastStreamBreak;
    if (t == null) return false;
    _lastStreamBreak = null;
    return DateTime.now().difference(t) <= within;
  }

  int _bytesInWindow = 0;
  DateTime _windowStart = DateTime.now();
  double _mbps = 0;
  int _activeConnections = 0;
  int _totalBytesDownloaded = 0;

  double get mbps => _mbps;
  int get activeConnections => _activeConnections;
  int get currentBytesDownloaded => _totalBytesDownloaded;
  double sampleMbps() => _mbps;
  bool get isActive => _activeConnections > 0 || _sessions.isNotEmpty;
  int get currentParallel => _activeConnections;
  double get currentTotalMB => _totalBytesDownloaded / (1024 * 1024);

  /// Puerto efimero en el que escucha el proxy, o `null` si aun no arranco.
  int? get puerto => _server?.port;

  /// La misma URL de sesion pero apuntando a [ip] en vez de a 127.0.0.1, para
  /// dar al TELEVISOR una direccion que si pueda alcanzar por la red local.
  ///
  /// Devuelve `null` si [urlLocal] no es una URL de este proxy.
  String? paraLan(String urlLocal, String ip) {
    final u = Uri.tryParse(urlLocal);
    if (u == null || !isTurboUrl(urlLocal)) return null;
    return u.replace(host: ip).toString();
  }

  /// Una URL servida por ESTE proxy, la pida el telefono por loopback o el
  /// televisor por la IP de la LAN. Antes solo reconocia 127.0.0.1, asi que al
  /// enrutar el TV la misma URL dejaba de identificarse como turbo y
  /// `cerrarSesion`/`resolveOriginal` fallaban en silencio.
  bool isTurboUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.scheme != 'http') return false;
    final p = _server?.port;
    if (p == null || u.port != p) return false;
    return u.pathSegments.length == 2 && u.pathSegments[0] == 't';
  }

  String? originalFor(String url) {
    if (!isTurboUrl(url)) return null;
    final segments = Uri.tryParse(url)?.pathSegments;
    if (segments == null || segments.length != 2 || segments[0] != 't') {
      return null;
    }
    return _sessions[segments[1]]?.originalUrl;
  }

  String resolveOriginal(String url) => originalFor(url) ?? url;

  _HostProfile _getProfile(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return _hostProfiles.putIfAbsent(host, () => _HostProfile(host));
  }

  /// Carga perfiles de host guardados en SharedPreferences
  Future<void> _loadHostProfiles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final Map<String, dynamic> decoded = jsonDecode(raw);
        decoded.forEach((key, value) {
          if (value is Map<String, dynamic>) {
            _hostProfiles[key] = _HostProfile.fromJson(value);
          }
        });
        debugPrint(
          'TurboProxy: ${_hostProfiles.length} perfiles de host cargados de disco',
        );
      }

      // ── Limpieza única de sanciones mal puestas ────────────────────────
      // Hasta ahora un corte a mitad de descarga podía escalar hasta
      // `isHostile`, y esa marca se guarda en disco y dura 30 días. O sea que
      // los perfiles ya guardados pueden traer hosts sanos —el propio VPS—
      // marcados como "sin rangos" por culpa de una sola película con un tramo
      // roto, con Turbo desactivado hasta que expire la sanción.
      //
      // Arreglar el código no basta: hay que borrar la marca que ya está
      // escrita. Se hace una sola vez y queda registrado con la versión.
      if (prefs.getInt(_prefsCleanupKey) != _prefsCleanupVersion) {
        var limpiados = 0;
        for (final p in _hostProfiles.values) {
          if (p.isHostile) {
            p.isHostile = false;
            p.consecutiveFailures = 0;
            p.maxWorkingParallel = 4;
            limpiados++;
          }
        }
        await prefs.setInt(_prefsCleanupKey, _prefsCleanupVersion);
        if (limpiados > 0) {
          _profilesDirty = true;
          await _flushHostProfiles();
          debugPrint(
            'TurboProxy: $limpiados perfil(es) rehabilitados '
            '(marca hostil puesta por cortes, no por falta de rangos)',
          );
        }
      }
    } catch (e) {
      debugPrint('TurboProxy: error cargando perfiles: $e');
    }
  }

  /// Marca los perfiles como pendientes de guardar. Se escriben en disco
  /// como máximo cada 30 segundos para evitar cientos de escrituras por película.
  void _markProfilesDirty() {
    _profilesDirty = true;
    _saveTimer ??= Timer(const Duration(seconds: 30), () {
      _saveTimer = null;
      if (_profilesDirty) _flushHostProfiles();
    });
  }

  /// Fuerza la escritura inmediata de perfiles (al finalizar sesión o ir a background).
  Future<void> flushProfiles() async => _flushHostProfiles();

  Future<void> _flushHostProfiles() async {
    if (!_profilesDirty) return;
    _profilesDirty = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, dynamic>{};
      _hostProfiles.forEach((key, profile) {
        map[key] = profile.toJson();
      });
      await prefs.setString(_prefsKey, jsonEncode(map));
    } catch (e) {
      debugPrint('TurboProxy: error guardando perfiles: $e');
    }
  }

  void setMediaMetadata(
    String url, {
    int? lengthBytes,
    double? durationSeconds,
  }) {
    for (final session in _sessions.values) {
      if (session.originalUrl == url) {
        if (lengthBytes != null && lengthBytes > 0) {
          session.length = lengthBytes;
        }
        if (durationSeconds != null && durationSeconds > 0) {
          session.durationSeconds = durationSeconds;
        }
      }
    }
  }

  void _setReason(String reason) {
    _lastReason = reason;
    status.value = 'turbo: $reason';
    debugPrint('TurboProxy: $reason');
  }

  void _noteBytes(int n) {
    _totalBytesDownloaded += n;
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
    await _loadHostProfiles();
    // anyIPv4 y no loopbackIPv4: cuando se transmite al televisor, el TV tiene
    // que poder pedirle los bytes a ESTE servidor. Con loopback solo era
    // alcanzable desde el propio telefono.
    //
    // Sigue sin ser un proxy abierto util para nadie mas: cada sesion vive bajo
    // un id aleatorio en /t/<id>, solo existe mientras dura la reproduccion, y
    // el puerto es efimero (0 = el que asigne el sistema). Sin el id no se
    // puede sacar nada del servidor.
    _server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      0,
      shared: true,
    );
    _server!.listen((req) {
      unawaited(_handle(req));
    }, onError: (e) => debugPrint('TurboProxy: server error: $e'));
    debugPrint('TurboProxy: escuchando en 127.0.0.1:${_server!.port}');
  }

  HttpClient _newClient() =>
      HttpClient()
        ..autoUncompress = false
        // +1 para dejar margen a la petición del redirect (302 → /vauth/…),
        // no para abrir descargas extra.
        ..maxConnectionsPerHost = maxParallel + 1
        ..connectionTimeout = const Duration(seconds: 8)
        ..badCertificateCallback = (_, _, _) => true;

  // ---------------------------------------------------------------------
  // PRECONEXIÓN: DNS + TCP + TLS + HEAD, ANTES de que el usuario pulse Play.
  // ---------------------------------------------------------------------

  /// Precalienta la conexión hacia [url] sin descargar contenido: resuelve
  /// DNS (vía [DnsBypassUtils]), abre y deja lista la conexión TCP/TLS, y
  /// hace un `HEAD` para conocer de antemano el largo, el tipo de contenido
  /// y si el origen soporta `Range`.
  ///
  /// Pensado para llamarse en cuanto el usuario entra a la pantalla de
  /// detalles (con el póster ya visible), mucho antes de pulsar Play. Así,
  /// cuando realmente se reproduce, [wrap] reutiliza esta conexión ya
  /// caliente y el primer `GET` no tiene que pagar DNS+TCP+TLS.
  ///
  /// Es "best effort": cualquier fallo se ignora en silencio y [wrap]
  /// simplemente abrirá una conexión nueva como hacía antes.
  Future<void> preconnect(String url, {Map<String, String>? headers}) async {
    try {
      if (!url.startsWith('http://') && !url.startsWith('https://')) return;

      final existing = _preconnected[url];
      if (existing != null &&
          DateTime.now().difference(existing.createdAt) < _preconnectTtl) {
        return; // ya precalentado y todavía fresco
      }

      if (_hostProfiles.isEmpty && _server == null) {
        await _loadHostProfiles();
      }
      final profile = _getProfile(url);
      if (profile.effectiveIsHostile) {
        return; // no vale la pena precalentar un host que sabemos hostil
      }

      final baseHeaders = Map<String, String>.from(headers ?? const {});
      baseHeaders['Accept-Encoding'] = 'identity';
      final bypassed = await DnsBypassUtils.bypassUrl(url, baseHeaders);

      final client = _newClient();

      // Un HEAD no sirve para esto: muchos servidores IPTV/CDN solo dejan
      // el socket "caliente" y la caché de ese archivo lista ante un GET
      // real. Pedimos un rango minúsculo (128 KB) para lograr ese efecto
      // pagando casi nada de datos — y de paso nos quedamos con esos bytes
      // para no tener que volver a pedirlos cuando el usuario dé Play.
      // 128 KB en vez de 64 KB: en MKV, el bloque inicial (EBML, metadata,
      // cues, attachments, pistas de subtítulos) a veces no entra en 64 KB.
      // 128 KB sigue siendo poquísimo tráfico pero cubre mejor ese caso.
      const primeBytes = 128 * 1024;
      final rq = await client.getUrl(bypassed.uri);
      bypassed.headers.forEach((k, v) => rq.headers.set(k, v));
      rq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${primeBytes - 1}');
      final rs = await rq.close().timeout(const Duration(seconds: 6));

      int? length;
      bool? supportsRange;
      String? contentType;
      Uint8List? primed;

      if (rs.statusCode == HttpStatus.partialContent) {
        supportsRange = true;
        final cr = rs.headers.value(HttpHeaders.contentRangeHeader);
        if (cr != null) {
          final slash = cr.lastIndexOf('/');
          if (slash != -1) {
            length = int.tryParse(cr.substring(slash + 1).trim());
          }
        }
      } else if (rs.statusCode == HttpStatus.ok) {
        supportsRange = false;
        if (rs.contentLength > 0) length = rs.contentLength;
      }
      if (rs.headers.contentType?.mimeType != null) {
        contentType = rs.headers.contentType!.mimeType;
      }

      final builder = BytesBuilder(copy: false);
      await for (final part in rs.timeout(const Duration(seconds: 6))) {
        builder.add(part);
        if (builder.length >= primeBytes) break;
      }
      if (builder.length > 0 && supportsRange == true) {
        // Solo tiene sentido reutilizar estos bytes como "primeros bytes de
        // la reproducción" si el servidor sí respetó el Range pedido
        // (206). Si respondió 200 (archivo completo, servidor sin soporte
        // de Range), esos primeros bytes ya no coinciden con lo que se
        // necesitará pedir después, así que se descartan.
        primed = builder.takeBytes();
      }

      // Si había una precalentada previa sin usar para esta misma URL,
      // ciérrala antes de reemplazarla.
      _preconnected.remove(url)?.client.close(force: false);

      _preconnected[url] = _PreconnectEntry(
        client: client,
        effectiveUri: bypassed.uri,
        headers: bypassed.headers,
        length: length,
        contentType: contentType,
        supportsRange: supportsRange,
        primedBytes: primed,
        createdAt: DateTime.now(),
      );

      debugPrint(
        'TurboProxy: preconnect OK ($url) -> len=$length range=$supportsRange '
        'type=$contentType primed=${primed?.length ?? 0}B',
      );
    } catch (e) {
      debugPrint('TurboProxy: preconnect falló para $url: $e');
    }
  }

  /// Descarta una conexión precalentada que no llegó a usarse (p. ej. el
  /// usuario salió de la pantalla de detalles sin reproducir). Llamar esto
  /// en el `dispose()` de la pantalla de detalles evita conexiones colgadas.
  /// Cierra la sesion que estaba sirviendo [urlLocal] (la `http://127.0.0.1:
  /// PUERTO/t/ID` que devolvio [wrap]).
  ///
  /// Lo llama el reproductor cuando destruye el player que la estaba usando.
  /// La expulsion por `tiempoMuerta` ya limpia las sesiones colgadas sola,
  /// pero tarda 45s en darse cuenta y solo mira al crear una sesion nueva.
  /// Avisar explicitamente al soltar el player las cierra en el acto, que es
  /// lo que evita que una recarga arrastre la descarga de la anterior
  /// compitiendo por el ancho de banda con la que la reemplaza.
  ///
  /// Es seguro: la sesion que se cierra es la del player que YA se destruyo,
  /// nunca la del stream vivo.
  void cerrarSesion(String? urlLocal) {
    if (urlLocal == null || !isTurboUrl(urlLocal)) return;
    final segments = Uri.parse(urlLocal).pathSegments;
    if (segments.length != 2 || segments[0] != 't') return;
    final muerta = _sessions.remove(segments[1]);
    if (muerta == null) return;
    debugPrint('TurboProxy: sesion ${segments[1]} cerrada por el reproductor');
    muerta.cerradaAdrede = true;
    muerta.client.close(force: true);
  }

  void cancelPreconnect(String url) {
    _preconnected.remove(url)?.client.close(force: false);
  }

  /// Intenta envolver [url] tras el proxy. Devuelve la URL local en 0ms.
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

      final profile = _getProfile(url);
      if (profile.effectiveIsHostile) {
        _setReason('servidor marcado sin soporte de rangos (${profile.host})');
        return null;
      }

      await _ensureServer();

      final id = '${_nextId++}';

      // Si ya precalentamos esta URL (preconnect fue llamado al entrar al
      // detalle), reutilizamos esa conexión TCP/TLS ya establecida en vez
      // de abrir una nueva desde cero: eso es lo que realmente ahorra los
      // 300-800 ms de DNS+TCP+TLS en el camino crítico del primer byte.
      final pre = _preconnected.remove(url);
      final bool reusedPreconnect =
          pre != null &&
          DateTime.now().difference(pre.createdAt) < _preconnectTtl;

      final HttpClient client;
      final Map<String, String> effectiveHeaders;
      if (reusedPreconnect) {
        client = pre.client;
        effectiveHeaders = pre.headers;
        _setReason('activo (conexión precalentada reutilizada)');
      } else {
        pre?.client.close(force: false);
        client = _newClient();
        effectiveHeaders = headers ?? const {};
      }

      final session = _Session(
        proxy: this,
        id: id,
        originalUrl: url,
        headers: effectiveHeaders,
        client: client,
        profile: profile,
        wasPreconnected: reusedPreconnect,
      );

      if (reusedPreconnect) {
        // Nos ahorramos también la resolución DNS y la primera vuelta de
        // cabeceras: ya sabemos el destino real y, si el GET de
        // precalentamiento respondió, ya sabemos largo/tipo/soporte de
        // Range de antemano — y hasta tenemos los primeros bytes en mano.
        session._effectiveUri = pre.effectiveUri;
        if (pre.length != null && pre.length! > 0) session.length = pre.length!;
        if (pre.contentType != null) session.contentType = pre.contentType;
        if (pre.supportsRange != null) {
          session.supportsRange = pre.supportsRange!;
        }
        session._primedBytes = pre.primedBytes;
      }

      _sessions[id] = session;

      // ── Expulsion de sesiones viejas, sin matar las que estan vivas ──────
      //
      // Antes esto cerraba a la fuerza la sesion MAS ANTIGUA por orden de
      // creacion, sin mirar si estaba sirviendo. Cada recarga o cambio de
      // servidor crea una sesion nueva, asi que en una pelicula larga con
      // varios tropiezos se llegaba a la quinta y se le arrancaba el
      // `HttpClient` por debajo a la que estaba REPRODUCIENDO.
      //
      // En el log se veia asi, a mitad de pelicula:
      //   pipeline.next fallo: chunk 572 fallo: Bad state: Client is closed
      // y a continuacion los 3 reintentos fallando al instante contra el mismo
      // cliente cerrado, terminando en "origen no responde tras reintentos" y
      // penalizando el perfil del host. O sea: se culpaba al servidor de un
      // fallo nuestro, y esa penalizacion baja el paralelismo para todo lo
      // demas.
      //
      // Ahora solo se expulsan sesiones con cero peticiones en curso. Si las
      // cuatro estan ocupadas no se cierra ninguna: es preferible que el mapa
      // crezca un poco de mas —son objetos pequenos y se limpian en cuanto
      // queden libres— antes que cortar un stream que el usuario esta viendo.
      //
      // AMPLIACION (2026-08-25): "cero peticiones en curso" no alcanzaba. Un
      // `_serve` puede quedarse colgado esperando al origen despues de que el
      // reproductor ya se fue —el socket local muere, pero el `await` contra
      // el origen no— y entonces `sirviendoAhora` no vuelve a bajar nunca. El
      // log de la recarga a los 4554s lo mostraba: 10 sesiones, todas "en
      // uso", cero expulsables. Esas descargas zombis siguen tirando del
      // ancho de banda del telefono y del puerto del VPS mientras el usuario
      // ve el spinner, asi que empeoran justo el corte que las creo.
      //
      // Ahora tambien se cierran las que llevan `tiempoMuerta` sin entregar un
      // byte (ver `_Session.estaColgada`), y se limpian TODAS las expulsables
      // de una pasada en vez de una sola: si se acumularon seis, sacar una por
      // recarga nunca alcanza a vaciar el mapa.
      if (_sessions.length > 4) {
        final aExpulsar = <String>[];
        for (final e in _sessions.entries) {
          if (e.key == id) continue;
          if (e.value.sirviendoAhora == 0 || e.value.estaColgada) {
            aExpulsar.add(e.key);
          }
        }
        for (final k in aExpulsar) {
          final muerta = _sessions.remove(k);
          if (muerta == null) continue;
          if (muerta.sirviendoAhora > 0) {
            debugPrint(
              'TurboProxy: cerrando sesion colgada $k '
              '(${muerta.sirviendoAhora} peticiones sin avanzar desde hace '
              '${DateTime.now().difference(muerta.ultimaActividad).inSeconds}s)',
            );
          }
          muerta.cerradaAdrede = true;
          muerta.client.close(force: true);
        }
        if (aExpulsar.isEmpty) {
          debugPrint(
            'TurboProxy: ${_sessions.length} sesiones, todas en uso — '
            'no se expulsa ninguna',
          );
        }
      }

      final local = 'http://127.0.0.1:${_server!.port}/t/$id';
      if (!reusedPreconnect) {
        _setReason('activo (passthrough inicial)');
      }
      debugPrint(
        'TurboProxy: sesión creada $url -> $local (preconnect=$reusedPreconnect)',
      );
      return local;
    } catch (e) {
      _setReason('wrap falló ($e) — usando URL directa');
      return null;
    }
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final segments = req.uri.pathSegments;
      final session =
          (segments.length == 2 && segments[0] == 't')
              ? _sessions[segments[1]]
              : null;
      if (session == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      session.sirviendoAhora++;
      try {
        await _serve(req, session);
      } finally {
        session.sirviendoAhora--;
      }
    } catch (e) {
      debugPrint('TurboProxy: error sirviendo petición: $e');
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serve(HttpRequest req, _Session session) async {
    int start = 0;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final m = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
      if (m != null) start = int.parse(m.group(1)!);
    }

    if (!session.supportsTurbo || session.mode == _ProxyMode.passthrough) {
      await _servePassthrough(req, session, start, rangeHeader);
    } else {
      await _serveTurbo(req, session, start, rangeHeader);
    }
  }

  /// FASE 1 & FASE 2: STREAMING DIRECTO PASSTHROUGH CON CONMUTACIÓN MID-STREAM EXACTA.
  ///
  /// Cuando el rango pedido por el reproductor es abierto (reproducción
  /// normal desde `start`, sin fin explícito), esta función NO hace una
  /// única petición abierta ("bytes=start-") al origen. En su lugar pide
  /// "piernas" acotadas de 2 MB ("bytes=start-start+2MB") de forma
  /// transparente para el reproductor (que sigue viendo un único stream
  /// continuo). Muchos CDNs entregan el primer byte más rápido ante un
  /// Range acotado que ante uno abierto, lo que reduce el TTFB inicial.
  ///
  /// Si el reproductor pidió un rango con fin explícito (p. ej. una
  /// descarga parcial puntual), se respeta tal cual en una sola petición,
  /// igual que antes.
  Future<void> _servePassthrough(
    HttpRequest req,
    _Session session,
    int start,
    String? rangeHeader,
  ) async {
    _activeConnections++;
    final resp = req.response;
    resp.bufferOutput = false;

    var closed = false;
    unawaited(
      resp.done.then((_) => closed = true).catchError((_) => closed = true),
    );

    int? explicitEnd;
    if (rangeHeader != null) {
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rangeHeader);
      if (m != null) explicitEnd = int.parse(m.group(2)!);
    }

    // Tamaño de las piernas acotadas que pedimos al origen mientras estamos
    // en modo Passthrough con rango abierto. La primera es deliberadamente
    // más chica (512 KB) para que ese primer bloque llegue lo antes
    // posible; las siguientes ya van a 2 MB para amortizar el overhead de
    // hacer una petición HTTP nueva por pierna.
    const firstLegBytes = 512 * 1024; // 512 KB
    const laterLegBytes = 2 * 1024 * 1024; // 2 MB

    // Flush por lote en vez de por cada chunk: en Android cada
    // resp.flush() es una llamada al socket, y hacerla en cada trocito de
    // ~16-64 KB que llega genera muchísimo overhead sin acelerar el
    // arranque en nada. Acumulamos hasta 128 KB o 50 ms, lo que ocurra
    // primero, y forzamos el flush cuando de verdad importa (cabeceras,
    // primer byte, fin de pierna).
    const flushBatchBytes = 128 * 1024;
    const flushBatchMs = 50;
    int pendingFlushBytes = 0;
    var lastFlushAt = DateTime.now();
    Future<void> maybeFlush({bool force = false}) async {
      final elapsed = DateTime.now().difference(lastFlushAt).inMilliseconds;
      if (!force &&
          pendingFlushBytes < flushBatchBytes &&
          elapsed < flushBatchMs) {
        return;
      }
      try {
        await resp.flush();
      } catch (_) {}
      pendingFlushBytes = 0;
      lastFlushAt = DateTime.now();
    }

    int currentOffset = start;
    final tracker = _SlidingSpeedTracker(windowMs: 250);
    final startTime = DateTime.now();
    final requestStartTime = DateTime.now();
    int lowSpeedConsecutiveCount = 0;
    var switchedToTurbo = false;
    var headersSent = false;
    // Se activa cuando la primera pierna confirma soporte de Range (206).
    // A partir de ahí seguimos troceando en piernas acotadas; si el origen
    // no soporta Range (200), servimos todo en una sola pierna como antes.
    var legging = false;

    var switchThresholdMs = 250;

    // Si ya tenemos bytes primados de preconnect() para esta URL y estamos
    // arrancando limpio desde el byte 0, los entregamos de inmediato: cero
    // espera de red, porque ya están en memoria desde que el usuario vio
    // el póster.
    if (start == 0 && explicitEnd == null && session._primedBytes != null) {
      final primed = session._primedBytes!;
      session._primedBytes = null; // consumir una sola vez
      headersSent = true;
      resp.statusCode =
          rangeHeader != null ? HttpStatus.partialContent : HttpStatus.ok;
      if (session.contentType != null) {
        resp.headers.set(HttpHeaders.contentTypeHeader, session.contentType!);
      }
      resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (session.length > 0) {
        resp.headers.set(
          HttpHeaders.contentLengthHeader,
          session.length.toString(),
        );
        if (rangeHeader != null) {
          resp.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-${session.length - 1}/${session.length}',
          );
        }
      }
      resp.add(primed);
      await resp.flush();
      currentOffset = primed.length;
      pendingFlushBytes = 0;
      lastFlushAt = DateTime.now();
      if (session.ttfbMs == 0) {
        session.ttfbMs =
            DateTime.now().difference(requestStartTime).inMilliseconds;
        session.updateMetrics();
      }
      if (session.supportsRange) legging = true;
      _setReason('activo (primeros bytes servidos desde preconnect, TTFB≈0)');
    }

    // El umbral de conmutación se acorta si el histórico indica que este
    // host siempre necesita Turbo (90%+ de sesiones): no hace falta
    // esperar tanto para decidir. Se calcula una sola vez, con lo que ya
    // se sepa del host/sesión en este punto (puede refinarse tras la
    // primera pierna real si todavía no había datos de soporte de Range).
    bool computeEarlySwitch() =>
        session.supportsTurbo && session.profile.shouldPreemptivelyTurbo;
    if (computeEarlySwitch()) {
      switchThresholdMs = 100;
      _setReason(
        'umbral reducido a ${switchThresholdMs}ms (histórico >90% Turbo)',
      );
    }

    try {
      while (!closed && !switchedToTurbo) {
        final isFirstLeg = !headersSent;
        final legSize = isFirstLeg ? firstLegBytes : laterLegBytes;

        final legRangeHeader =
            explicitEnd != null
                ? rangeHeader!
                : 'bytes=$currentOffset-'
                    '${session.length > 0 ? math.min(currentOffset + legSize - 1, session.length - 1) : currentOffset + legSize - 1}';

        final targetUri = await session.getEffectiveTarget();
        final rq = await session.client.getUrl(targetUri);
        session.headers.forEach((k, v) => rq.headers.set(k, v));
        rq.headers.set('Accept-Encoding', 'identity');
        rq.headers.set(HttpHeaders.rangeHeader, legRangeHeader);

        final rs = await rq.close().timeout(const Duration(seconds: 10));

        session.anotarCache(rs.headers);

        if (rs.statusCode == HttpStatus.partialContent) {
          session.supportsRange = true;
          // Sirvio el rango: lo anterior no era un host sin soporte de Range.
          session.profile.noteRangeOk();
          final cr = rs.headers.value(HttpHeaders.contentRangeHeader);
          if (cr != null) {
            final slash = cr.lastIndexOf('/');
            if (slash != -1) {
              final total = int.tryParse(cr.substring(slash + 1).trim());
              if (total != null && total > 0) session.length = total;
            }
          }
          if (rs.headers.contentType?.mimeType != null) {
            session.contentType = rs.headers.contentType!.mimeType;
          }
          if (isFirstLeg && explicitEnd == null) legging = true;
        } else if (rs.statusCode == HttpStatus.ok) {
          if (rangeHeader != null) {
            session.profile.noteFailure(rangeIgnorado: true);
            _markProfilesDirty();
          }
          session.supportsRange = false;
          legging = false;
          if (rs.contentLength > 0) session.length = rs.contentLength;
        }

        if (isFirstLeg && switchThresholdMs != 100 && computeEarlySwitch()) {
          // Recién ahora (tras la primera pierna real) se confirmó soporte
          // de Range; si no veníamos de bytes primados, es la primera vez
          // que podemos saberlo con certeza.
          switchThresholdMs = 100;
          _setReason(
            'umbral reducido a ${switchThresholdMs}ms (histórico >90% Turbo)',
          );
        }

        if (!headersSent) {
          headersSent = true;

          if (legging) {
            // El status lo decide lo que pidio EL REPRODUCTOR, nunca lo que
            // contesto el origen.
            //
            // Aqui troceamos en piernas con Range por dentro, asi que el origen
            // responde 206 aunque el reproductor no haya pedido ningun rango.
            // Antes ese 206 se reenviaba tal cual: el reproductor recibia una
            // respuesta PARCIAL sin cabecera Content-Range —HTTP invalido, esa
            // cabecera solo se pone si el reproductor pidio rango— y ademas con
            // el Content-Length del archivo completo. Con esas cabeceras MPV
            // calcula mal el timeline y se comporta de forma rara al buscar.
            resp.statusCode =
                rangeHeader != null ? HttpStatus.partialContent : HttpStatus.ok;

            // OJO: el Content-Length de ESTA pierna acotada no es el largo
            // total que enviaremos al reproductor (seguirán llegando más
            // piernas después). Construimos nosotros las cabeceras en vez
            // de reenviar las del origen tal cual.
            if (session.contentType != null) {
              resp.headers.set(
                HttpHeaders.contentTypeHeader,
                session.contentType!,
              );
            }
            resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
            if (session.length > 0) {
              resp.headers.set(
                HttpHeaders.contentLengthHeader,
                (session.length - start).toString(),
              );
              if (rangeHeader != null) {
                resp.headers.set(
                  HttpHeaders.contentRangeHeader,
                  'bytes $start-${session.length - 1}/${session.length}',
                );
              }
            }
            // Si el largo total aún no se conoce, se omite Content-Length
            // y Dart sirve la respuesta en chunked transfer-encoding.
          } else {
            // Sin soporte confirmado de Range, o pierna única con fin
            // explícito: aquí sí hay correspondencia 1:1 entre lo que pedimos
            // al origen y lo que entregamos, así que se reenvía tal cual.
            resp.statusCode = rs.statusCode;
            rs.headers.forEach((name, values) {
              if (name.toLowerCase() != 'transfer-encoding') {
                for (final val in values) {
                  resp.headers.add(name, val);
                }
              }
            });
          }

          // ENVIAR CABECERAS INMEDIATAMENTE AL REPRODUCTOR (< 10 ms)
          await resp.flush();

          // MEDICIÓN DE TTFB (Time To First Byte entregado al reproductor)
          if (session.ttfbMs == 0) {
            session.ttfbMs =
                DateTime.now().difference(requestStartTime).inMilliseconds;
            session.updateMetrics();
          }
        }

        final legStartOffset = currentOffset;
        final completer = Completer<void>();
        StreamSubscription<List<int>>? subscription;
        subscription = rs.listen(
          (chunk) {
            if (closed || completer.isCompleted) return;

            try {
              resp.add(chunk);
            } catch (e) {
              // La respuesta local ya no acepta escrituras. Puede ser un cierre
              // normal del cliente (salir, hacer seek) o una rotura real del
              // pipe. Sin este catch, la excepción se va al manejador global sin
              // pasar por el completer, que queda colgado para siempre → el
              // reproductor se queda sin bytes hasta que algo más lo destrabe.
              debugPrint('TurboProxy: resp.add falló: $e');
              if (!closed) {
                // `closed` seguía en false → el cliente NO había cerrado: esto
                // fue una rotura inesperada. Se marca para que el reproductor
                // recargue rápido en vez de esperar el timeout completo.
                _lastStreamBreak = DateTime.now();
              }
              closed = true;
              if (!completer.isCompleted) completer.complete();
              return;
            }

            try {
              currentOffset += chunk.length;
              pendingFlushBytes += chunk.length;
              // NO se llama a flush() aqui a proposito. `resp.bufferOutput`
              // ya esta en false, asi que cada add() va al socket sin buffer y
              // el flush periodico no aportaba nada. Lo que si hacia era dejar
              // un flush() corriendo en paralelo (unawaited) mientras seguian
              // entrando add() sobre el mismo sink: esas dos operaciones se
              // pisan y Dart lanza "StreamSink is bound to a stream", que
              // rompia el pipe hacia el reproductor a mitad de reproduccion.
              // Los flush que quedan son los de los limites de pierna, que si
              // se esperan y nunca coinciden con un add().
            } catch (_) {
              closed = true;
              return;
            }

            _noteBytes(chunk.length);
            session.tocar();
            tracker.add(chunk.length);

            final elapsedTotal =
                DateTime.now().difference(startTime).inMilliseconds;
            if (elapsedTotal >= switchThresholdMs && session.supportsTurbo) {
              final speed = tracker.mbps;
              final stalled = tracker.msSinceLastChunk > 600;
              final requiredBitrate = session.targetBitrateMbps;

              if (speed < requiredBitrate) {
                lowSpeedConsecutiveCount++;
              } else {
                lowSpeedConsecutiveCount = 0;
              }

              if (stalled || lowSpeedConsecutiveCount >= 2) {
                switchedToTurbo = true;
                session.turboActivated = true;
                session.turboActivationTimeSec = (elapsedTotal / 1000).round();
                session.turboInterventions++;
                session._turboStartTime = DateTime.now();
                session.updateMetrics();

                _setReason(
                  stalled
                      ? 'acelerando mid-stream (socket origen pausado >600ms)'
                      : 'acelerando mid-stream (${speed.toStringAsFixed(1)} Mbps < ${requiredBitrate.toStringAsFixed(1)} Mbps requeridos)',
                );
                subscription?.pause();
                if (!completer.isCompleted) completer.complete();
              }
            }
          },
          onError: (err) {
            if (!completer.isCompleted) completer.completeError(err);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );

        await completer.future.catchError((_) {});
        await subscription.cancel();
        await maybeFlush(force: true);

        if (switchedToTurbo || closed) break;
        if (explicitEnd != null) {
          break; // pierna única ya cubría exactamente lo pedido
        }
        if (!legging) {
          break; // sin Range: ya se envió el cuerpo completo en esta pierna
        }
        if (session.length > 0 && currentOffset >= session.length) {
          break; // fin de archivo
        }
        if (currentOffset == legStartOffset) {
          break; // sin progreso, evita bucle infinito
        }
        // seguimos con la siguiente pierna acotada, transparente para el reproductor
      }

      if (switchedToTurbo && !closed && session.supportsTurbo) {
        session.mode = _ProxyMode.turbo;

        final pipeline = _TurboPipeline(session, currentOffset);
        bool pipelineDone = false;
        try {
          while (!closed) {
            Uint8List? data;
            try {
              data = await pipeline.next();
            } catch (e) {
              debugPrint(
                'TurboProxy: pipeline.next mid-stream falló: $e -> Retornando a Passthrough de emergencia',
              );
              session.noteFailure(porRotura: true);
              break;
            }
            if (data == null) {
              pipelineDone = true;
              break;
            }
            if (closed) break;
            resp.add(data);
            currentOffset += data.length;
            pendingFlushBytes += data.length;
            await maybeFlush();
          }
          await maybeFlush(force: true);

          // FALLBACK TO PASSTHROUGH ON FAILURE
          if (!closed && !pipelineDone && currentOffset < session.length) {
            debugPrint(
              'TurboProxy: Iniciando fallback Passthrough mid-stream desde offset $currentOffset',
            );
            int fallbackRetries = 0;
            // Ver `esClienteCerrado`: separa un fallo NUESTRO de uno del servidor.
            bool clienteCerradoLocal = false;
            while (!closed &&
                currentOffset < session.length &&
                fallbackRetries < 3) {
              final useRange =
                  session.supportsRange && !session.profile.effectiveIsHostile;

              // Ver la nota del otro fallback: sin Range, reanudar a mitad
              // duplicaria la pelicula dentro del mismo stream.
              if (!useRange && currentOffset > 0) {
                _setReason(
                  'sin soporte de Range: no se puede reanudar desde '
                  '$currentOffset sin duplicar contenido',
                );
                break;
              }

              final legSize = 2 * 1024 * 1024; // 2 MB legs
              final legRangeHeader =
                  'bytes=$currentOffset-${math.min(currentOffset + legSize - 1, session.length - 1)}';

              try {
                final targetUri = await session.getEffectiveTarget();
                final rq = await session.client.getUrl(targetUri);
                session.headers.forEach((k, v) => rq.headers.set(k, v));
                rq.headers.set('Accept-Encoding', 'identity');
                if (useRange) {
                  rq.headers.set(HttpHeaders.rangeHeader, legRangeHeader);
                }

                final rs = await rq.close().timeout(const Duration(seconds: 5));

                // Ver la nota del otro fallback: un 200 trae el cuerpo desde el
                // byte 0 y solo vale si aun no enviamos nada.
                final cuerpoDesdeCero = rs.statusCode == HttpStatus.ok;
                if (cuerpoDesdeCero && currentOffset > 0) {
                  await rs.listen(null).cancel();
                  throw HttpException(
                    'status 200 con offset $currentOffset: el cuerpo empezaria '
                    'desde 0 y duplicaria contenido',
                  );
                }

                if (rs.statusCode == HttpStatus.partialContent ||
                    cuerpoDesdeCero) {
                  // El contador se pone a cero SOLO si esta pierna entregó
                  // bytes de verdad — nunca al recibir las cabeceras.
                  //
                  // Antes se reseteaba aquí mismo, y el corte de este
                  // proveedor llega SIEMPRE con las cabeceras bien y el cuerpo
                  // a medias. Resultado: cada vuelta ponía el contador en 0,
                  // el catch lo subía a 1, y el `fallbackRetries < 3` del
                  // while no se cumplía JAMAS -> reintento infinito cada
                  // 800 ms, con el reproductor sin datos y el perfil del host
                  // penalizado en cada vuelta. Es el "(1/3)" que se repite
                  // eternamente en el log, sin llegar nunca a 2/3.
                  final offsetAlEmpezar = currentOffset;
                  await for (final chunk in rs.timeout(
                    const Duration(seconds: 6),
                  )) {
                    if (closed) break;
                    resp.add(chunk);
                    currentOffset += chunk.length;
                    pendingFlushBytes += chunk.length;
                    // NO se llama a flush() aqui a proposito. `resp.bufferOutput`
                    // ya esta en false, asi que cada add() va al socket sin buffer y
                    // el flush periodico no aportaba nada. Lo que si hacia era dejar
                    // un flush() corriendo en paralelo (unawaited) mientras seguian
                    // entrando add() sobre el mismo sink: esas dos operaciones se
                    // pisan y Dart lanza "StreamSink is bound to a stream", que
                    // rompia el pipe hacia el reproductor a mitad de reproduccion.
                    // Los flush que quedan son los de los limites de pierna, que si
                    // se esperan y nunca coinciden con un add().
                    session.proxy._noteBytes(chunk.length);
                    session.tocar();
                  }
                  if (currentOffset - offsetAlEmpezar >= _kMinProgresoPierna) {
                    fallbackRetries = 0;
                  } else {
                    // Cuerpo vacío o ridículamente corto sin lanzar error:
                    // cuenta como intento fallido igual, o el while no avanza.
                    fallbackRetries++;
                  }
                  if (!useRange) break;
                } else {
                  throw HttpException('status ${rs.statusCode}');
                }
              } catch (err) {
                if (esClienteCerrado(err)) {
                  // Ver `esClienteCerrado`: reintentar es inútil y culpar al
                  // host, injusto. Se abandona el fallback en el acto.
                  debugPrint(
                    'TurboProxy: cliente local cerrado — se abandona el '
                    'fallback sin penalizar al host',
                  );
                  clienteCerradoLocal = true;
                  break;
                }
                fallbackRetries++;
                // FIX: antes este catch no llamaba a session.noteFailure(),
                // así que el _HostProfile nunca se enteraba de que el
                // origen estaba fallando en modo fallback, y una sesión
                // nueva repetía el mismo ciclo passthrough -> turbo ->
                // fallback contra un host ya muerto, generando la cadena
                // de TimeoutException que se ve en el log.
                session.noteFailure(porRotura: true);
                debugPrint(
                  'TurboProxy: fallback Passthrough mid-stream error ($fallbackRetries/3): $err',
                );
                if (err is SocketException) await session.refreshTarget();
                // Backoff creciente en vez de fijo (1000ms, 1600ms, 2000ms...)
                await Future.delayed(
                  Duration(milliseconds: math.min(800 * fallbackRetries, 4000)),
                );
              }
            }

            // Si se agotaron los 3 reintentos sin terminar el archivo,
            // penalizamos más fuerte para que el host baje a 1 conexión antes
            // y las próximas sesiones no repitan este mismo ciclo costoso.
            //
            // Sigue siendo `porRotura`: que un archivo no se pueda terminar no
            // prueba que el host no sirva rangos, así que esto acelera el
            // recorte de paralelismo pero nunca marca el perfil como hostil.
            if (!closed &&
                !clienteCerradoLocal &&
                fallbackRetries >= 3 &&
                currentOffset < session.length) {
              for (var i = 0; i < 3; i++) {
                session.noteFailure(porRotura: true);
              }
              _setReason(
                'origen no responde tras reintentos (${session.profile.host}) — penalizando perfil',
              );
            }
          }
        } catch (e) {
          debugPrint(
            'TurboProxy: error en pipeline turbo mid-stream general: $e',
          );
        } finally {
          pipeline.cancel();
        }
      }
    } catch (e) {
      debugPrint('TurboProxy: passthrough error: $e');
      if (e is SocketException) {
        await session.refreshTarget();
      }
    } finally {
      _activeConnections--;
      session.noteSessionEndOnce();
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  /// FASE 3: ACELERACIÓN PARALELA ADAPTATIVA CON HISTÉRESIS DE DESESCALADO
  Future<void> _serveTurbo(
    HttpRequest req,
    _Session session,
    int start,
    String? rangeHeader,
  ) async {
    if (session.length <= 0 || start >= session.length) {
      await _servePassthrough(req, session, start, rangeHeader);
      return;
    }

    final resp = req.response;
    resp.bufferOutput = false;
    if (rangeHeader != null) {
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${session.length - 1}/${session.length}',
      );
    } else {
      resp.statusCode = HttpStatus.ok;
    }
    resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (session.contentType != null) {
      resp.headers.set(HttpHeaders.contentTypeHeader, session.contentType!);
    }
    resp.contentLength = session.length - start;

    try {
      await resp.flush();
    } catch (_) {
      return;
    }

    final pipeline = _TurboPipeline(session, start);
    var closed = false;
    unawaited(
      resp.done.then((_) => closed = true).catchError((_) => closed = true),
    );

    // Misma estrategia de flush por lote que en _servePassthrough: aunque
    // aquí los chunks del pipeline ya son de ~1 MB (no de 16-64 KB como en
    // passthrough), seguir haciendo un resp.flush() por cada uno es una
    // llamada al socket por chunk durante TODA la reproducción. Agrupar
    // reduce CPU sin afectar el primer frame (que ya se resolvió antes,
    // en passthrough).
    const flushBatchBytes = 128 * 1024;
    const flushBatchMs = 50;
    int pendingFlushBytes = 0;
    var lastFlushAt = DateTime.now();
    Future<void> maybeFlush({bool force = false}) async {
      final elapsed = DateTime.now().difference(lastFlushAt).inMilliseconds;
      if (!force &&
          pendingFlushBytes < flushBatchBytes &&
          elapsed < flushBatchMs) {
        return;
      }
      try {
        await resp.flush();
      } catch (_) {}
      pendingFlushBytes = 0;
      lastFlushAt = DateTime.now();
    }

    int currentOffset = start;
    bool pipelineDone = false;
    try {
      while (!closed) {
        Uint8List? data;
        try {
          data = await pipeline.next();
        } catch (e) {
          if (session.cerradaAdrede) {
            // La cerramos nosotros: no hay nada que recuperar ni a quien
            // culpar. Salir en silencio en vez de arrancar el fallback de
            // emergencia y gastar tres reintentos con backoff.
            closed = true;
            break;
          }
          debugPrint(
            'TurboProxy: pipeline.next falló: $e -> Conmutando a Passthrough de emergencia',
          );
          session.noteFailure(porRotura: true);
          break;
        }
        if (data == null) {
          pipelineDone = true;
          break;
        }
        if (closed) break;
        resp.add(data);
        currentOffset += data.length;
        pendingFlushBytes += data.length;
        await maybeFlush();
      }
      await maybeFlush(force: true);

      // FALLBACK TO PASSTHROUGH ON FAILURE
      if (!closed && !pipelineDone && currentOffset < session.length) {
        debugPrint(
          'TurboProxy: Iniciando fallback Passthrough de emergencia desde offset $currentOffset',
        );
        int fallbackRetries = 0;
        while (!closed &&
            !session.cerradaAdrede &&
            currentOffset < session.length &&
            fallbackRetries < 3) {
          final useRange =
              session.supportsRange && !session.profile.effectiveIsHostile;

          // Sin Range NO se puede reanudar a mitad de archivo: el origen
          // mandaria el cuerpo desde el byte 0 y esos bytes se pegarian detras
          // de los currentOffset ya enviados. El reproductor ve la pelicula
          // REPETIRSE a mitad, el timeline deja de coincidir con el audio, y de
          // ahi los adelantos, los frenazos y la imagen corriendo para
          // alcanzar al sonido. Mejor cortar el stream: el detector de
          // congelamiento recarga y reanuda con un Range limpio.
          if (!useRange && currentOffset > 0) {
            _setReason(
              'sin soporte de Range: no se puede reanudar desde '
              '$currentOffset sin duplicar contenido',
            );
            break;
          }

          final legSize = 2 * 1024 * 1024; // 2 MB legs
          final legRangeHeader =
              'bytes=$currentOffset-${math.min(currentOffset + legSize - 1, session.length - 1)}';

          try {
            final targetUri = await session.getEffectiveTarget();
            final rq = await session.client.getUrl(targetUri);
            session.headers.forEach((k, v) => rq.headers.set(k, v));
            rq.headers.set('Accept-Encoding', 'identity');
            if (useRange) {
              rq.headers.set(HttpHeaders.rangeHeader, legRangeHeader);
            }

            final rs = await rq.close().timeout(const Duration(seconds: 5));

            // Un 200 significa que el origen IGNORO el Range y esta mandando
            // el cuerpo DESDE EL BYTE 0. Solo sirve si todavia no enviamos
            // nada: si ya vamos por currentOffset, pegar eso duplica la
            // pelicula a mitad del stream. Antes se aceptaba igual que un 206.
            final cuerpoDesdeCero = rs.statusCode == HttpStatus.ok;
            if (cuerpoDesdeCero && currentOffset > 0) {
              await rs.listen(null).cancel();
              throw HttpException(
                'status 200 con offset $currentOffset: el cuerpo empezaria '
                'desde 0 y duplicaria contenido',
              );
            }

            if (rs.statusCode == HttpStatus.partialContent || cuerpoDesdeCero) {
              // Ver la nota extensa en el fallback de _servePassthrough: el
              // reseteo va DESPUES del cuerpo y solo si hubo progreso real.
              // Resetear al recibir cabeceras convertía esto en un bucle
              // infinito ante un proveedor que corta el cuerpo a mitad.
              final offsetAlEmpezar = currentOffset;
              await for (final chunk in rs.timeout(
                const Duration(seconds: 6),
              )) {
                if (closed) break;
                resp.add(chunk);
                currentOffset += chunk.length;
                pendingFlushBytes += chunk.length;
                // NO se llama a flush() aqui a proposito. `resp.bufferOutput`
                // ya esta en false, asi que cada add() va al socket sin buffer y
                // el flush periodico no aportaba nada. Lo que si hacia era dejar
                // un flush() corriendo en paralelo (unawaited) mientras seguian
                // entrando add() sobre el mismo sink: esas dos operaciones se
                // pisan y Dart lanza "StreamSink is bound to a stream", que
                // rompia el pipe hacia el reproductor a mitad de reproduccion.
                // Los flush que quedan son los de los limites de pierna, que si
                // se esperan y nunca coinciden con un add().
                session.proxy._noteBytes(chunk.length);
                session.tocar();
              }
              if (currentOffset - offsetAlEmpezar >= _kMinProgresoPierna) {
                fallbackRetries = 0;
              } else {
                fallbackRetries++;
              }
              if (!useRange) break;
            } else {
              throw HttpException('status ${rs.statusCode}');
            }
          } catch (err) {
            fallbackRetries++;
            // FIX: mismo problema que en _servePassthrough — sin esto el
            // perfil del host nunca aprendía que el origen estaba fallando
            // en el camino de fallback.
            session.noteFailure(porRotura: true);
            debugPrint(
              'TurboProxy: fallback Passthrough error ($fallbackRetries/3): $err',
            );
            if (err is SocketException) await session.refreshTarget();
            // Backoff creciente en vez de fijo.
            await Future.delayed(
              Duration(milliseconds: math.min(800 * fallbackRetries, 4000)),
            );
          }
        }

        // Igual que en el camino passthrough: si se agotaron los reintentos y
        // no se terminó el archivo, penalizar fuerte para bajar el
        // paralelismo antes. Sigue sin marcar hostil (ver `porRotura`).
        if (!closed &&
            !session.cerradaAdrede &&
            fallbackRetries >= 3 &&
            currentOffset < session.length) {
          for (var i = 0; i < 3; i++) {
            session.noteFailure(porRotura: true);
          }
          _setReason(
            'origen no responde tras reintentos (${session.profile.host}) — penalizando perfil',
          );
        }
      }
    } catch (e) {
      debugPrint('TurboProxy: turbo stream error general: $e');
      session.noteFailure(porRotura: true);
    } finally {
      pipeline.cancel();
      session.noteSessionEndOnce();
      try {
        await resp.close();
      } catch (_) {}
    }
  }
}

class _Session {
  final TurboProxy proxy;
  final String id;
  final String originalUrl;
  Map<String, String> headers;
  final HttpClient client;
  final _HostProfile profile;
  final bool wasPreconnected;

  Uri? _effectiveUri;
  bool supportsRange = false;

  /// Peticiones del reproductor que se estan sirviendo AHORA con esta sesion.
  ///
  /// Existe para que la expulsion por limite de sesiones no le arranque el
  /// `HttpClient` por debajo a un stream vivo (ver la nota en `_wrap`).
  int sirviendoAhora = 0;

  /// Ultimo momento en que esta sesion entrego bytes de verdad al reproductor.
  ///
  /// `sirviendoAhora` solo dice que hay un `_serve` en curso, NO que ese
  /// `_serve` este avanzando. Si se queda colgado esperando al origen (que es
  /// lo que pasa cuando el reproductor se destruye a mitad de descarga: el
  /// socket local muere pero el `await` contra el origen sigue vivo), el
  /// contador nunca vuelve a cero y la sesion queda marcada "en uso" para
  /// siempre. Ese era el `10 sesiones, todas en uso — no se expulsa ninguna`
  /// del log: diez descargas zombis peleando por el ancho de banda del
  /// telefono y por el puerto del VPS contra la reproduccion real.
  DateTime ultimaActividad = DateTime.now();

  void tocar() => ultimaActividad = DateTime.now();

  /// La cerramos NOSOTROS a proposito (el reproductor la solto, o se expulso
  /// por colgada). Todo lo que falle despues es consecuencia de eso, no del
  /// origen: `Bad state: Client is closed` en el pipeline, en el fallback de
  /// emergencia, en todos lados.
  ///
  /// Sin esta bandera esos fallos se le cargaban al perfil del host — hasta
  /// siete `noteFailure` seguidos por un solo cierre nuestro — y ese perfil
  /// baja el paralelismo para TODAS las sesiones futuras contra ese host. O
  /// sea: cerrar limpio una sesion muerta empeoraba la reconexion siguiente.
  bool cerradaAdrede = false;

  /// El VPS respondio `X-Cache: HIT`: estos bytes salen de su disco y no le
  /// cuestan una conexion al proveedor. Habilita el techo de paralelismo alto
  /// (ver `TurboProxy.maxParallelEnCache`).
  bool servidoDesdeCache = false;

  /// Techo de piernas que aplica a ESTA sesion, segun de donde salgan los
  /// bytes. Un MISS se queda con el techo conservador.
  int get techoParalelo =>
      servidoDesdeCache
          ? math.max(TurboProxy.maxParallel, TurboProxy.maxParallelEnCache)
          : TurboProxy.maxParallel;

  /// Lee `X-Cache` de una respuesta del origen. Solo sube el techo; nunca lo
  /// baja, porque una peticion suelta puede dar MISS mientras el resto del
  /// archivo sigue en cache y no queremos perder el paralelismo por eso.
  void anotarCache(HttpHeaders cabeceras) {
    if (servidoDesdeCache) return;
    final v = cabeceras.value('x-cache')?.trim().toUpperCase();
    if (v == null || !v.startsWith('HIT')) return;
    servidoDesdeCache = true;
    debugPrint(
      'TurboProxy [${profile.host}]: X-Cache HIT — el VPS sirve de disco, '
      'techo de piernas sube a $techoParalelo',
    );
  }

  /// Colgada: dice estar sirviendo pero no entrega un byte desde hace rato.
  bool get estaColgada =>
      sirviendoAhora > 0 &&
      DateTime.now().difference(ultimaActividad) > TurboProxy.tiempoMuerta;
  int length = -1;
  double? durationSeconds;
  String? contentType;

  /// Primeros bytes ya descargados durante [TurboProxy.preconnect]. Si están
  /// presentes y la reproducción arranca desde el byte 0, se le entregan al
  /// reproductor de inmediato, sin pedirlos de nuevo al origen.
  Uint8List? _primedBytes;

  _ProxyMode mode = _ProxyMode.passthrough;

  late int activeParallel = math.min(
    TurboProxy.maxParallel,
    profile.maxWorkingParallel,
  );
  int parallelFailures = 0;
  int successfulChunks = 0;
  int highSpeedStreak = 0;

  // Diagnóstico / Métricas
  int ttfbMs = 0;
  bool turboActivated = false;
  int turboActivationTimeSec = 0;
  int maxConnectionsUsed = 1;
  int turboInterventions = 0;
  int turboActiveDurationMs = 0;
  DateTime? _turboStartTime;

  _Session({
    required this.proxy,
    required this.id,
    required this.originalUrl,
    required this.headers,
    required this.client,
    required this.profile,
    this.wasPreconnected = false,
  });

  bool _sessionEnded = false;

  void _recordTurboDuration() {
    if (_turboStartTime != null) {
      turboActiveDurationMs +=
          DateTime.now().difference(_turboStartTime!).inMilliseconds;
      _turboStartTime = null;
    }
  }

  void noteSessionEndOnce() {
    if (_sessionEnded) return;
    _sessionEnded = true;
    _recordTurboDuration();
    profile.noteSessionEnd(turboWasUsed: turboActivated);
    proxy._markProfilesDirty();
  }

  void updateMetrics() {
    maxConnectionsUsed = math.max(maxConnectionsUsed, activeParallel);

    proxy.metrics.value = TurboMetrics(
      ttfbMs: ttfbMs,
      turboActivated: turboActivated,
      turboActivationTimeSec: turboActivationTimeSec,
      maxConnectionsUsed: maxConnectionsUsed,
      turboInterventions: turboInterventions,
      turboActiveDurationMs: turboActiveDurationMs,
      host: profile.host,
      hostLearningSummary: profile.summary,
      wasPreconnected: wasPreconnected,
    );
  }

  double get targetBitrateMbps {
    if (length > 0 && durationSeconds != null && durationSeconds! > 0) {
      final exactBitrate = (length * 8) / durationSeconds! / 1000000.0 * 1.3;
      return math.max(exactBitrate, 2.0);
    }
    if (length > 5 * 1024 * 1024 * 1024) return 14.0;
    if (length > 2 * 1024 * 1024 * 1024) return 8.0;
    if (length > 0) return 4.5;
    return 8.0;
  }

  Future<Uri> getEffectiveTarget() async {
    if (_effectiveUri != null) return _effectiveUri!;
    try {
      final base = Map<String, String>.from(headers);
      base['Accept-Encoding'] = 'identity';
      final bypassed = await DnsBypassUtils.bypassUrl(originalUrl, base);
      _effectiveUri = bypassed.uri;
      headers = bypassed.headers;
    } catch (_) {
      _effectiveUri = Uri.parse(originalUrl);
    }
    return _effectiveUri!;
  }

  Future<void> refreshTarget() async {
    try {
      final original = Uri.parse(originalUrl);
      if (_effectiveUri?.host != original.host) {
        DnsBypassUtils.reportFailedIp(original.host, _effectiveUri?.host ?? '');
        final refreshed = await DnsBypassUtils.bypassUrl(originalUrl, headers);
        _effectiveUri = refreshed.uri;
        headers = refreshed.headers;
      }
    } catch (_) {
      _effectiveUri = Uri.parse(originalUrl);
    }
  }

  void noteSuccess(double speedMbps) {
    successfulChunks++;
    profile.noteSuccess(activeParallel, speedMbps);
    proxy._markProfilesDirty();

    // El presupuesto de conexiones nunca puede superar el global: es el que
    // protege el tope de la línea Xtream compartida entre todos los usuarios.
    final budget = math.min(techoParalelo, profile.maxWorkingParallel);
    if (speedMbps < targetBitrateMbps * 1.2 &&
        activeParallel < budget &&
        parallelFailures == 0) {
      if (successfulChunks >= 2 && activeParallel < 3 && budget >= 3) {
        activeParallel = 3;
        debugPrint(
          'TurboProxy [${profile.host}]: rampa ascendente -> 3 conexiones',
        );
      } else if (successfulChunks >= 5 && activeParallel < 4 && budget >= 4) {
        activeParallel = 4;
        debugPrint(
          'TurboProxy [${profile.host}]: rampa ascendente -> 4 conexiones',
        );
      }
    }

    if (speedMbps > targetBitrateMbps * 1.8) {
      highSpeedStreak++;
      if (highSpeedStreak >= 10 && activeParallel > 1) {
        highSpeedStreak = 0;
        activeParallel--;
        debugPrint(
          'TurboProxy [${profile.host}]: histéresis — velocidad holgada (${speedMbps.toStringAsFixed(1)} Mbps), bajando a $activeParallel conexiones',
        );
      } else if (highSpeedStreak >= 15 &&
          activeParallel == 1 &&
          mode != _ProxyMode.passthrough) {
        // El `mode !=` y el reseteo de la racha no son cosmeticos: sin ellos
        // esta rama se volvia a cumplir en CADA trozo descargado —la racha
        // seguia por encima de 15 y el paralelismo en 1— y repetia el mismo
        // mensaje una y otra vez. En un log real salio diez veces seguidas,
        // tapando lo que de verdad importaba.
        highSpeedStreak = 0;
        mode = _ProxyMode.passthrough;
        debugPrint(
          'TurboProxy [${profile.host}]: histéresis — retorno a Passthrough (velocidad óptima en 1 conexión)',
        );
      }
    } else {
      highSpeedStreak = 0;
    }
    updateMetrics();
  }

  /// [porRotura] y [rangeIgnorado] se propagan al perfil del host: ver
  /// `_HostProfile.noteFailure`.
  void noteFailure({bool porRotura = false, bool rangeIgnorado = false}) {
    // Cierre nuestro: el origen no hizo nada mal. Se filtra aqui, en el unico
    // punto por el que pasan los diez sitios que reportan fallo.
    if (cerradaAdrede) return;
    parallelFailures++;
    profile.noteFailure(porRotura: porRotura, rangeIgnorado: rangeIgnorado);
    proxy._markProfilesDirty();

    if (parallelFailures >= 3 && activeParallel > 2) {
      activeParallel = 2;
      debugPrint(
        'TurboProxy [${profile.host}]: bajando paralelismo a 2 conexiones',
      );
    } else if (parallelFailures >= 6 && activeParallel > 1) {
      activeParallel = 1;
      debugPrint(
        'TurboProxy [${profile.host}]: bajando paralelismo a 1 conexión',
      );
    } else if (parallelFailures >= 10) {
      mode = _ProxyMode.passthrough;
      debugPrint(
        'TurboProxy [${profile.host}]: degradando completamente a Passthrough',
      );
    }
    updateMetrics();
  }

  /// Con una sola conexión permitida, el pipeline Turbo no aporta velocidad y
  /// sí mucho coste: trocea en peticiones de 1 MB y este proveedor responde un
  /// 302 a `/vauth/…` en CADA petición, así que una película de 2 GB serían
  /// ~2000 requests + 2000 redirects contra una línea ya saturada. En ese caso
  /// conviene el passthrough, que mantiene un único stream continuo.
  bool get supportsTurbo =>
      TurboProxy.maxParallel > 1 &&
      supportsRange &&
      length > 0 &&
      !profile.effectiveIsHostile &&
      parallelFailures < 10 &&
      !profile.shouldDisableTurbo;
}

/// ¿El fallo es que NUESTRO cliente HTTP ya estaba cerrado?
///
/// Se manifiesta como `Bad state: Client is closed` y no dice absolutamente
/// nada sobre el servidor: es un fallo local. Distinguirlo importa por dos
/// motivos: reintentar contra un cliente cerrado falla al instante y quema los
/// tres intentos para nada, y penalizar el perfil del host por esto le baja el
/// paralelismo a TODO el contenido de ese servidor por un bug nuestro.
bool esClienteCerrado(Object e) =>
    e is StateError && e.message.contains('Client is closed');

class _TurboPipeline {
  final _Session session;
  final int startOffset;
  bool _cancelled = false;

  late final int _firstChunk = startOffset ~/ TurboProxy._turboChunkSize;
  late final int _totalChunks =
      (session.length + TurboProxy._turboChunkSize - 1) ~/
      TurboProxy._turboChunkSize;

  int _serving = 0;
  int _scheduled = 0;
  int _active = 0;
  final Map<int, Completer<Uint8List>> _chunks = {};

  _TurboPipeline(this.session, this.startOffset) {
    _pump();
  }

  void _pump() {
    while (!_cancelled &&
        _active < session.activeParallel &&
        _scheduled - _serving < TurboProxy._windowChunks &&
        _firstChunk + _scheduled < _totalChunks) {
      final rel = _scheduled++;
      final completer = Completer<Uint8List>();
      completer.future.ignore();
      _chunks[rel] = completer;
      _active++;

      unawaited(
        _fetchChunk(_firstChunk + rel)
            .then((bytes) {
              if (!completer.isCompleted) {
                completer.complete(bytes);
              }
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

  Future<Uint8List?> next() async {
    if (_cancelled) return null;
    if (_firstChunk + _serving >= _totalChunks) return null;
    final completer = _chunks[_serving];
    if (completer == null) {
      _pump();
      if (_chunks[_serving] == null) return null;
    }

    final bytes = await _chunks[_serving]!.future;
    _chunks.remove(_serving);
    final isFirst = _serving == 0;
    _serving++;
    _pump();

    if (isFirst) {
      final skip = startOffset - _firstChunk * TurboProxy._turboChunkSize;
      if (skip > 0) return Uint8List.sublistView(bytes, skip);
    }
    return bytes;
  }

  Future<Uint8List> _fetchChunk(int index) async {
    final startB = index * TurboProxy._turboChunkSize;
    final endB =
        math.min(startB + TurboProxy._turboChunkSize, session.length) - 1;
    final expected = endB - startB + 1;

    final builder = BytesBuilder(copy: false);
    int got = 0;
    Object? lastErr;
    final chunkStartTime = DateTime.now();

    for (int attempt = 0; attempt < 4 && !_cancelled; attempt++) {
      session.proxy._activeConnections++;
      try {
        final targetUri = await session.getEffectiveTarget();
        final rq = await session.client.getUrl(targetUri);
        session.headers.forEach((k, v) => rq.headers.set(k, v));
        rq.headers.set(HttpHeaders.rangeHeader, 'bytes=${startB + got}-$endB');

        final rs = await rq.close().timeout(const Duration(seconds: 5));

        // Solo 206 es válido para un chunk con Range. Un 200 indica que el
        // servidor ignoró la cabecera Range y devuelve el archivo completo,
        // lo que corrompería el ensamblado del pipeline.
        if (rs.statusCode != HttpStatus.partialContent) {
          await rs.drain<void>().catchError((_) {});
          throw HttpException('status ${rs.statusCode} (esperaba 206)');
        }

        session.anotarCache(rs.headers);

        // Verificar alineación del Content-Range: protege contra servidores
        // que responden con un rango diferente al solicitado.
        final cr = rs.headers.value(HttpHeaders.contentRangeHeader);
        if (cr != null) {
          final m = RegExp(r'bytes\s+(\d+)-(\d+)').firstMatch(cr);
          if (m != null) {
            final serverStart = int.parse(m.group(1)!);
            final expectedStart = startB + got;
            if (serverStart != expectedStart) {
              await rs.drain<void>().catchError((_) {});
              throw HttpException(
                'Content-Range desalineado: servidor entregó byte $serverStart, esperaba $expectedStart',
              );
            }
          }
        }

        await for (final part in rs.timeout(const Duration(seconds: 6))) {
          builder.add(part);
          got += part.length;
          session.proxy._noteBytes(part.length);
          session.tocar();
          if (_cancelled) throw const HttpException('cancelado');
        }

        if (got >= expected) {
          final elapsedMs =
              DateTime.now().difference(chunkStartTime).inMilliseconds;
          final speedMbps = (expected * 8) / math.max(elapsedMs, 50) / 1000.0;
          session.noteSuccess(speedMbps);
          break;
        }
        lastErr = HttpException('parcial $got/$expected');
        if (attempt == 3) {
          // Trozo truncado: es el caso de rotura por excelencia.
          session.noteFailure(porRotura: true);
        }
      } catch (err) {
        lastErr = err;
        // Cliente cerrado por debajo: no es del servidor. Se sale ya, sin
        // gastar los reintentos ni penalizar al host por un fallo nuestro.
        if (esClienteCerrado(err)) break;
        if (attempt == 3) {
          // Fallo de red bajando un trozo: es rotura, no prueba de que el host
          // no sirva rangos. Marcar hostil desde aquí desactivaba Turbo 30 días
          // para todo el host por culpa de un tramo con mala suerte.
          session.noteFailure(porRotura: true);
        }
        if (_cancelled) break;
        if (err is SocketException) await session.refreshTarget();
        await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      } finally {
        session.proxy._activeConnections--;
      }
      if (got >= expected) break;
    }

    if (got >= expected) {
      final bytes = builder.takeBytes();
      return bytes.length == expected
          ? bytes
          : Uint8List.sublistView(bytes, 0, expected);
    }
    throw HttpException('chunk $index falló: $lastErr');
  }

  void cancel() {
    _cancelled = true;
    for (final c in _chunks.values) {
      if (!c.isCompleted) {
        c.completeError(const HttpException('pipeline cancelado'));
      }
    }
    _chunks.clear();
  }
}
