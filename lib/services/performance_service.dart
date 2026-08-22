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

  /// RAM fisica total del equipo en MB (0 = desconocida / no es Android).
  int _physicalRamMb = 0;

  /// Bandera del propio Android (`ActivityManager.isLowRamDevice`).
  bool _isLowRamDevice = false;

  /// Por debajo de esto se considera que el equipo NO aguanta los topes de
  /// gama alta (256 MB de buffer MPV + 200 MB de cache de imagenes + un
  /// segundo Player de prewarm).
  ///
  /// 3072 MB y no 2048: `totalMem` que reporta Android siempre es menor que la
  /// RAM nominal (el kernel y la GPU se quedan con su parte), asi que un equipo
  /// vendido como "3 GB" reporta ~2700-2900 MB. Ese es justo el equipo que se
  /// muere con los topes de gama alta. Uno de 4 GB reporta ~3700 MB y sigue
  /// clasificando como gama alta, sin cambios.
  static const int _minRamMbGamaAlta = 3072;

  PerformanceMode get currentMode => _currentMode;
  bool get isLowEndHeuristic => _isLowEndHeuristic;

  /// RAM fisica total en MB. 0 si no se pudo determinar.
  int get physicalRamMb => _physicalRamMb;

  bool get isLowPerformance {
    if (_currentMode == PerformanceMode.low) return true;
    if (_currentMode == PerformanceMode.high) return false;
    return _isLowEndHeuristic;
  }

  /// Hardware con el camino de Surface (zero-copy) inestable.
  ///
  /// En estos equipos el decodificador MediaTek se desincroniza: el audio
  /// sigue sonando y el video se queda congelado, con errores de
  /// BLASTBufferQueue / GraphicsTracker en el log. Por eso conviene usar
  /// `mediacodec-copy` desde el primer intento en vez de esperar a que falle.
  bool get isMotorola => _isMotorola;

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
        _physicalRamMb = androidInfo.physicalRamSize;
        _isLowRamDevice = androidInfo.isLowRamDevice;

        // ── Por que hace falta mirar la RAM ──────────────────────────────────
        //
        // Antes la heuristica solo miraba API level y numero de nucleos. Un
        // telefono barato reciente (8 nucleos, Android 11) pasaba como gama
        // ALTA aunque solo tuviera 2-3 GB de RAM, y con esa etiqueta recibia
        // 256 MB de buffer nativo de MPV, 200 MB de cache de imagenes y
        // permiso para precalentar un SEGUNDO Player MPV cerca del final del
        // episodio. Mas de 500 MB en un equipo de 3 GB: el recolector de
        // basura entra en bucle, el hilo de UI se congela y Android saca el
        // dialogo "Bump Comba no responde".
        //
        // La RAM solo puede BAJAR de gama, nunca subir: un equipo que hoy se
        // clasifica como gama baja sigue igual. Lo unico que cambia es que los
        // equipos con poca RAM dejan de recibir los topes de gama alta.
        final bool pocaRam =
            _isLowRamDevice ||
            (_physicalRamMb > 0 && _physicalRamMb < _minRamMbGamaAlta);

        if (apiLevel < 29 || cores < 6 || pocaRam) {
          _isLowEndHeuristic = true;
        } else {
          _isLowEndHeuristic = false;
        }

        debugPrint(
          'PerformanceService: api=$apiLevel cores=$cores '
          'ram=${_physicalRamMb}MB lowRamFlag=$_isLowRamDevice '
          '-> ${_isLowEndHeuristic ? "GAMA BAJA" : "gama alta"}',
        );
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
