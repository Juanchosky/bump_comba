import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'premium_service.dart';
import '../utils/security_utils.dart';
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

  SharedPreferences? _prefs;

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

    // Save progress
    final progress = WatchProgress(
      url: videoUrl,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isCompleted: completed,
      name: name,
      seriesName: seriesName,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
    );

    final allProgress = await _getAllProgress();
    allProgress[videoUrl] = progress.toJson();

    final jsonStr = jsonEncode(allProgress);
    await _prefs!.setString(_progressKey, SecurityUtils.obfuscate(jsonStr));
    notifyListeners();
    return true;
  }

  /// Get watch progress for a video URL
  Future<WatchProgress?> getProgress(String videoUrl) async {
    await _ensureInitialized();

    final allProgress = await _getAllProgress();
    final progressData = allProgress[videoUrl];

    if (progressData == null) return null;

    return WatchProgress.fromJson(videoUrl, progressData);
  }

  /// Clear progress for a specific video URL
  Future<void> clearProgress(String videoUrl) async {
    await _ensureInitialized();

    final allProgress = await _getAllProgress();
    allProgress.remove(videoUrl);
    final jsonStr = jsonEncode(allProgress);
    await _prefs!.setString(_progressKey, SecurityUtils.obfuscate(jsonStr));
    notifyListeners();
  }

  /// Get all progress data
  Future<Map<String, dynamic>> _getAllProgress() async {
    await _ensureInitialized();

    final raw = _prefs!.getString(_progressKey);
    if (raw == null) return {};

    try {
      final decrypted = SecurityUtils.deobfuscate(raw);
      return Map<String, dynamic>.from(jsonDecode(decrypted));
    } catch (e) {
      // If corrupted or legacy during first transition, return empty or try plain
      try {
        if (raw.isNotEmpty) {
           return Map<String, dynamic>.from(jsonDecode(raw));
        }
      } catch (_) {}
      return {};
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
