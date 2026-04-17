import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';

enum PerformanceMode { auto, low, high }

class PerformanceService extends ChangeNotifier {
  static const String _performanceModeKey = 'performance_mode';
  static final PerformanceService _instance = PerformanceService._internal();
  factory PerformanceService() => _instance;
  PerformanceService._internal();

  PerformanceMode _currentMode = PerformanceMode.auto;
  bool _isLowEndHeuristic = false;
  bool _isMotorola = false;
  bool _initialized = false;

  PerformanceMode get currentMode => _currentMode;
  bool get isLowEndHeuristic => _isLowEndHeuristic;

  bool get isLowPerformance {
    if (_currentMode == PerformanceMode.low) return true;
    if (_currentMode == PerformanceMode.high) return false;
    return _isLowEndHeuristic;
  }

  /// Certain hardware (Motorola) has very low Surface buffer limits.
  /// Pre-warming a second player can cause BLASTBufferQueue exhaustion.
  bool get allowVideoPrewarm {
    if (_isMotorola) return false;
    return !isLowPerformance;
  }

  bool get shouldShowExpensiveEffects => !isLowPerformance;

  /// Whether to allow shimmers, page transitions, and subtle animations
  bool get shouldAnimateDecorations => !isLowPerformance;

  /// Whether to show expensive BoxShadows and complex gradients
  bool get shouldShowComplexShadows => !isLowPerformance;

  /// Whether we should strictly limit image memory consumption
  bool get lowMemoryLimit => isLowPerformance;

  Future<void> init() async {
    if (_initialized) return;

    final prefs = await SharedPreferences.getInstance();
    final modeIndex =
        prefs.getInt(_performanceModeKey) ?? PerformanceMode.auto.index;
    _currentMode = PerformanceMode.values[modeIndex];

    await _detectHardware();
    _initialized = true;
    _applyCacheLimits();
    notifyListeners();
  }

  void _applyCacheLimits() {
    if (!kIsWeb) {
      if (lowMemoryLimit) {
        PaintingBinding.instance.imageCache.maximumSizeBytes =
            60 * 1024 * 1024; // 60 MB
        PaintingBinding.instance.imageCache.maximumSize = 400; // 400 images
      } else {
        PaintingBinding.instance.imageCache.maximumSizeBytes =
            200 * 1024 * 1024; // 200 MB
        PaintingBinding.instance.imageCache.maximumSize = 2000; // 2000 images
      }
    }
  }

  Future<void> _detectHardware() async {
    try {
      if (kIsWeb) {
        _isLowEndHeuristic = false; // Usually desktop or good mobile web
        return;
      }

      final deviceInfo = DeviceInfoPlugin();

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        if (androidInfo.manufacturer.toLowerCase().contains('motorola') ||
            androidInfo.brand.toLowerCase().contains('motorola')) {
          _isMotorola = true;
          debugPrint(
            'PerformanceService: Motorola device detected. Disabling prewarm for stability.',
          );
        }

        final apiLevel = androidInfo.version.sdkInt;
        final cores = Platform.numberOfProcessors;

        if (apiLevel < 29 || cores < 6) {
          _isLowEndHeuristic = true;
        } else {
          _isLowEndHeuristic = false;
        }
      } else if (Platform.isIOS) {
        // iOS devices generally handle blur well, but we can check for older models if needed
        _isLowEndHeuristic = false;
      } else {
        // Desktop (Windows/Mac/Linux) is almost never low-end for these effects
        _isLowEndHeuristic = false;
      }
    } catch (e) {
      debugPrint('Error detecting hardware: $e');
      _isLowEndHeuristic = false; // Default to high if detection fails
    }
  }

  Future<void> setPerformanceMode(PerformanceMode mode) async {
    _currentMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_performanceModeKey, mode.index);
    _applyCacheLimits();
    notifyListeners();
  }
}
