import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'premium_service.dart';
import '../utils/security_utils.dart';
import '../models/m3u_item.dart';
import 'package:flutter/foundation.dart';

/// Model for storing watch progress
class WatchProgress {
  final String url; // Added URL field
  final int positionSeconds;
  final int durationSeconds;
  final int timestamp;
  final bool isCompleted;

  final String? name; // Display name
  final String? seriesName;
  final int? seasonNumber;
  final int? episodeNumber;

  WatchProgress({
    required this.url,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.timestamp,
    this.isCompleted = false,
    this.name,
    this.seriesName,
    this.seasonNumber,
    this.episodeNumber,
  });

  Map<String, dynamic> toJson() => {
    'position': positionSeconds,
    'duration': durationSeconds,
    'timestamp': timestamp,
    'isCompleted': isCompleted,
    'name': name,
    'seriesName': seriesName,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
  };

  factory WatchProgress.fromJson(String url, Map<String, dynamic> json) {
    return WatchProgress(
      url: url,
      positionSeconds: json['position'] as int,
      durationSeconds: json['duration'] as int,
      timestamp: json['timestamp'] as int,
      isCompleted: json['isCompleted'] as bool? ?? false,
      name: json['name'] as String?,
      seriesName: json['seriesName'] as String?,
      seasonNumber: json['seasonNumber'] as int?,
      episodeNumber: json['episodeNumber'] as int?,
    );
  }

  double get progressPercentage {
    if (durationSeconds == 0) return 0.0;
    return (positionSeconds / durationSeconds) * 100;
  }
}

/// Service to manage watch progress for videos
class WatchProgressService with ChangeNotifier {
  static final WatchProgressService _instance =
      WatchProgressService._internal();
  factory WatchProgressService() => _instance;
  WatchProgressService._internal();

  static const String _progressKey = 'watch_progress';
  static const int _minProgressSeconds = 30; // Don't save if watched < 30s
  static const double _maxProgressPercentage =
      95.0; // Consider completed if > 95%

  /// Cada cuanto, COMO MUCHO, se escribe el historial a disco.
  ///
  /// El temporizador del reproductor llama a `saveProgress` cada 5 s. Antes
  /// cada una de esas llamadas hacia, en el hilo de UI y con el video
  /// corriendo: `jsonEncode` del historial ENTERO + XOR byte a byte + base64 +
  /// `SharedPreferences.setString` (que en Android reescribe el XML completo).
  /// Con un historial de meses eso es un pico de trabajo cada 5 segundos que
  /// crece sin parar, y encaja con que la app empezara a congelarse "de un
  /// momento a otro" despues de tiempo de uso.
  ///
  /// Ahora `saveProgress` solo toca el mapa en memoria (instantaneo) y el
  /// volcado a disco va a este ritmo. No se pierde progreso al salir porque
  /// `flush(force: true)` se llama al pausar, al mandar la app a segundo plano
  /// y al cerrar el reproductor.
  static const Duration _minFlushInterval = Duration(seconds: 30);

  /// Techo de entradas del historial.
  ///
  /// El mapa crece rapido porque se guarda UNA entrada por cada URL
  /// alternativa del contenido, no una por pelicula. Sin techo, el JSON que se
  /// codifica en cada volcado crece para siempre. 3000 entradas son de sobra
  /// incluso para un usuario intensivo (la vista de historial libre muestra
  /// 20); al pasarse se descartan las MAS ANTIGUAS por `timestamp`.
  static const int _maxEntries = 3000;

  SharedPreferences? _prefs;
  Map<String, dynamic>? _cachedAllProgress;

  /// Hay cambios en memoria que todavia no estan en disco.
  bool _dirty = false;
  DateTime? _lastFlushAt;
  Timer? _flushTimer;
  Future<void>? _flushInFlight;

  /// Initialize the service
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _migrateToObfuscatedStorage();
  }

  Future<void> _migrateToObfuscatedStorage() async {
    await _ensureInitialized();
    final raw = _prefs!.getString(_progressKey);
    if (raw != null && raw.isNotEmpty && !SecurityUtils.isObfuscated(raw)) {
      await _prefs!.setString(_progressKey, SecurityUtils.obfuscate(raw));
    }
  }

  /// Save watch progress for a video URL
  /// Returns true if saved, false if not (due to thresholds)
  Future<bool> saveProgress(
    String videoUrl,
    Duration position,
    Duration duration, {
    List<String>? alternativeUrls,
    String? name,
    String? seriesName,
    int? seasonNumber,
    int? episodeNumber,
  }) async {
    await _ensureInitialized();

    final positionSeconds = position.inSeconds;
    final durationSeconds = duration.inSeconds;

    // Don't save if too short
    if (positionSeconds < _minProgressSeconds) {
      return false;
    }

    // Don't save if duration is unknown or invalid
    if (durationSeconds <= 0) {
      return false;
    }

    // Calculate progress percentage
    final percentage = (positionSeconds / durationSeconds) * 100;

    // If video is nearly complete, mark as completed
    bool completed = false;
    if (percentage >= _maxProgressPercentage) {
      completed = true;
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    // Save progress
    final progress = WatchProgress(
      url: videoUrl,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      timestamp: now,
      isCompleted: completed,
      name: name,
      seriesName: seriesName,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
    );

    final allProgress = await _getAllProgress();
    allProgress[videoUrl] = progress.toJson();

    // Synchronize progress to all alternative server URLs of the same content
    if (alternativeUrls != null && alternativeUrls.isNotEmpty) {
      for (final altUrl in alternativeUrls) {
        if (altUrl.isNotEmpty && altUrl != videoUrl) {
          final altProgress = WatchProgress(
            url: altUrl,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            timestamp: now,
            isCompleted: completed,
            name: name,
            seriesName: seriesName,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
          );
          allProgress[altUrl] = altProgress.toJson();
        }
      }
    }

    _dirty = true;
    _scheduleFlush();
    notifyListeners();
    return true;
  }

  /// Programa un volcado a disco respetando `_minFlushInterval`.
  void _scheduleFlush() {
    if (!_dirty || _flushTimer != null) return;
    final last = _lastFlushAt;
    final pendiente =
        last == null
            ? Duration.zero
            : _minFlushInterval - DateTime.now().difference(last);
    if (pendiente <= Duration.zero) {
      unawaited(flush());
      return;
    }
    _flushTimer = Timer(pendiente, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// Escribe el historial a disco si hay algo pendiente.
  ///
  /// [force] ignora el intervalo minimo. Usalo en los momentos en que el
  /// proceso puede morir sin aviso: pausa, app a segundo plano, cierre del
  /// reproductor. Fuera de esos casos deja que el throttle haga su trabajo.
  Future<void> flush({bool force = false}) async {
    if (!_dirty) return;
    if (!force) {
      final last = _lastFlushAt;
      if (last != null && DateTime.now().difference(last) < _minFlushInterval) {
        _scheduleFlush();
        return;
      }
    }
    // Si ya hay una escritura en curso, esperarla en vez de lanzar otra en
    // paralelo sobre la misma clave.
    final enCurso = _flushInFlight;
    if (enCurso != null) {
      await enCurso;
      if (!_dirty) return;
    }
    final futuro = _persist();
    _flushInFlight = futuro;
    try {
      await futuro;
    } finally {
      if (identical(_flushInFlight, futuro)) _flushInFlight = null;
    }
  }

  Future<void> _persist() async {
    final mapa = _cachedAllProgress;
    if (mapa == null) {
      _dirty = false;
      return;
    }
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    _lastFlushAt = DateTime.now();
    try {
      _podarSiHaceFalta(mapa);
      await _ensureInitialized();
      final jsonStr = jsonEncode(mapa);
      await _prefs!.setString(_progressKey, SecurityUtils.obfuscate(jsonStr));
    } catch (e) {
      // Si falla la escritura, los datos siguen en memoria: se marca sucio
      // otra vez para reintentar en el siguiente ciclo en vez de perderlos.
      _dirty = true;
      debugPrint('WatchProgressService: fallo al guardar historial: $e');
    }
  }

  /// Descarta las entradas mas antiguas si el mapa supera `_maxEntries`.
  void _podarSiHaceFalta(Map<String, dynamic> mapa) {
    if (mapa.length <= _maxEntries) return;
    final entradas =
        mapa.entries.toList()..sort((a, b) {
          final tA =
              (a.value is Map ? a.value['timestamp'] as int? : null) ?? 0;
          final tB =
              (b.value is Map ? b.value['timestamp'] as int? : null) ?? 0;
          return tB.compareTo(tA); // mas reciente primero
        });
    for (final e in entradas.skip(_maxEntries)) {
      mapa.remove(e.key);
    }
    debugPrint(
      'WatchProgressService: historial podado a $_maxEntries entradas',
    );
  }

  /// Get watch progress for a video URL
  Future<WatchProgress?> getProgress(String videoUrl) async {
    await _ensureInitialized();

    final allProgress = await _getAllProgress();
    final progressData = allProgress[videoUrl];

    if (progressData == null) return null;

    return WatchProgress.fromJson(videoUrl, progressData);
  }

  /// Get watch progress for an M3UItem checking its main URL and any alternative URLs
  Future<WatchProgress?> getProgressForItem(M3UItem item) async {
    final urls = <String>[
      if (item.url.isNotEmpty) item.url,
      ...item.alternatives.map((a) => a.url).where((u) => u.isNotEmpty),
    ];
    if (urls.isEmpty) return null;
    return getLastWatchedFromList(urls);
  }

  /// Clear progress for a specific video URL
  Future<void> clearProgress(String videoUrl) async {
    await _ensureInitialized();

    final allProgress = await _getAllProgress();
    allProgress.remove(videoUrl);
    _dirty = true;
    await flush(force: true);
    notifyListeners();
  }

  /// Clear progress for an M3UItem and all its alternative URLs
  Future<void> clearProgressForItem(M3UItem item) async {
    final urls = <String>[
      if (item.url.isNotEmpty) item.url,
      ...item.alternatives.map((a) => a.url).where((u) => u.isNotEmpty),
    ];
    for (final url in urls) {
      await clearProgress(url);
    }
  }

  /// Get all progress data
  Future<Map<String, dynamic>> _getAllProgress() async {
    if (_cachedAllProgress != null) return _cachedAllProgress!;

    await _ensureInitialized();

    final raw = _prefs!.getString(_progressKey);
    if (raw == null) {
      _cachedAllProgress = {};
      return _cachedAllProgress!;
    }

    try {
      final decrypted = SecurityUtils.deobfuscate(raw);
      _cachedAllProgress = Map<String, dynamic>.from(jsonDecode(decrypted));
      return _cachedAllProgress!;
    } catch (e) {
      // If corrupted or legacy during first transition, return empty or try plain
      try {
        if (raw.isNotEmpty) {
          _cachedAllProgress = Map<String, dynamic>.from(jsonDecode(raw));
          return _cachedAllProgress!;
        }
      } catch (_) {}
      _cachedAllProgress = {};
      return _cachedAllProgress!;
    }
  }

  /// Get history sorted by timestamp (newest first)
  /// Free users are limited to 20 items
  Future<List<WatchProgress>> getHistory() async {
    final allProgress = await _getAllProgress();

    // Sort keys by timestamp desc
    final entries = allProgress.entries.toList();
    entries.sort((a, b) {
      final tA = a.value['timestamp'] as int? ?? 0;
      final tB = b.value['timestamp'] as int? ?? 0;
      return tB.compareTo(tA);
    });

    final history =
        entries.map((e) {
          return WatchProgress.fromJson(e.key, e.value);
        }).toList();

    // Apply limit for free users
    if (!PremiumService().isPremium && history.length > 20) {
      return history.take(20).toList();
    }

    return history;
  }

  /// Get distinct sorted URLs for history
  Future<List<String>> getHistoryUrls() async {
    final allProgress = await _getAllProgress();

    // Sort keys by timestamp desc
    final entries = allProgress.entries.toList();
    entries.sort((a, b) {
      final tA = a.value['timestamp'] as int? ?? 0;
      final tB = b.value['timestamp'] as int? ?? 0;
      return tB.compareTo(tA);
    });

    return entries.map((e) => e.key).toList();
  }

  /// Find the last watched item from a provided list of URLs
  Future<WatchProgress?> getLastWatchedFromList(List<String> urls) async {
    final history = await getHistory();

    // History is already sorted by timestamp desc (newest first)
    try {
      return history.firstWhere((progress) => urls.contains(progress.url));
    } catch (_) {
      return null;
    }
  }

  /// Clear all watch progress
  Future<void> clearAllProgress() async {
    await _ensureInitialized();
    // Cancelar cualquier volcado pendiente: si no, el mapa viejo todavia en
    // vuelo podria reescribirse encima de lo que acabamos de borrar.
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    _cachedAllProgress = {};
    await _prefs!.remove(_progressKey);
    notifyListeners();
  }

  /// Ensure SharedPreferences is initialized
  Future<void> _ensureInitialized() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Format duration as MM:SS or HH:MM:SS
  static String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }
}
