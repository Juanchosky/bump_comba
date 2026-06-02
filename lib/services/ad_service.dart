import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui';
import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'premium_service.dart';
import '../utils/snack_bar_utils.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../screens/subscription_screen.dart';

// ═══════════════════════════════════════════════════════════════════════════
// ALGORITMO ADAPTATIVO v2 — Anti-fatiga + Anti-adblocker + Revenue floor
//
// TRES PILARES:
//   1. Segmentación de usuario (nuevo / habitual / leal)
//   2. Score de tolerancia adaptativo (20–100)
//   3. Rotación de formatos (no solo interstitials)
//
// FLOOR RULES (garantía de ingresos):
//   - Score mínimo absoluto: 20 (nunca cae más abajo)
//   - Cooldown máximo: 4 minutos (240s), sin importar el score
//   - Native ads: siempre activos, nunca bloqueados por el algoritmo
//   - Rewarded: recupera CPM cuando el score es bajo
//
// ANTI-ADBLOCKER:
//   - Capa 1: detección silenciosa (probe a AdMob, sin alertas)
//   - Capa 2: si bloqueado → paywall suave (límite de acciones)
// ═══════════════════════════════════════════════════════════════════════════

enum _UserSegment { newUser, regular, loyal }

class AdService {
  static final AdService _instance = AdService._internal();
  factory AdService() => _instance;
  AdService._internal();

  // ── PRUEBAS iOS ─────────────────────────────────────────────────────────────
  // Cuando es true, se omite la "puerta" de anuncios (rewarded/confirmación) y
  // el contenido se reproduce directamente, sin el modo offline.
  // ⚠️ PONER EN false ANTES DE PUBLICAR para reactivar los anuncios.
  static const bool kBypassAdGateForTesting = true;

  // ── Ads ───────────────────────────────────────────────────────────────────
  InterstitialAd? _interstitialAd;
  RewardedAd? _rewardedAd;
  RewardedInterstitialAd? _rewardedInterstitialAd;

  bool _isInterstitialAdLoading = false;
  bool _isRewardedAdLoading = false;
  bool _isRewardedInterstitialLoading = false;

  static final ValueNotifier<bool> isAdInProgress = ValueNotifier<bool>(false);

  // ── Anti-adblocker ────────────────────────────────────────────────────────
  bool _adBlockerDetected = false;
  int _blockedActionsCount = 0;
  static const int _maxBlockedActionsBeforePaywall = 5;

  // ── Unverified Views & Fallbacks ──────────────────────────────────────────
  int _unverifiedViewsThisSession = 0;
  static const int _maxUnverifiedViews = 3;
  int? _lastLoadErrorCode;
  static const String _unverifiedViewsKey = 'ad_unverified_views_count';

  bool get hasReachedUnverifiedLimit =>
      _unverifiedViewsThisSession >= _maxUnverifiedViews;
  int get unverifiedViewsThisSession => _unverifiedViewsThisSession;
  int? get lastLoadErrorCode => _lastLoadErrorCode;
  bool get adBlockerDetected => _adBlockerDetected;

  void incrementUnverifiedViews() {
    _unverifiedViewsThisSession++;
    _prefs?.setInt(_unverifiedViewsKey, _unverifiedViewsThisSession);
  }

  void resetUnverifiedViews() {
    _unverifiedViewsThisSession = 0;
    _prefs?.setInt(_unverifiedViewsKey, 0);
  }

  // ── Plataforma ────────────────────────────────────────────────────────────
  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  // ── Estado de sesión ──────────────────────────────────────────────────────
  DateTime? _sessionStartTime;
  DateTime? _lastAdShownTime;
  DateTime? _lastInterstitialShownTime;
  int _adsShownThisSession = 0;
  int _detailsVisitCount = 0;

  // ── Segmentación de usuario ───────────────────────────────────────────────
  _UserSegment _userSegment = _UserSegment.newUser;
  static const String _firstLaunchDateKey = 'ad_first_launch_date';
  static const String _totalSessionsKey = 'ad_total_sessions';

  // ── Score adaptativo ──────────────────────────────────────────────────────
  int _toleranceScore = 50;
  static const String _toleranceScoreKey = 'ad_tolerance_score';
  static const String _lastAdDateKey = 'ad_last_date';
  static const String _adsShownTodayKey = 'ad_shown_today';

  SharedPreferences? _prefs;

  // ── IDs ───────────────────────────────────────────────────────────────────
  static String get _realInterstitialId =>
      dotenv.env['ADMOB_INTERSTITIAL_ID'] ??
      'ca-app-pub-4239841158013104/9278645985';
  static String get _realRewardedId =>
      dotenv.env['ADMOB_REWARDED_ID'] ??
      'ca-app-pub-4239841158013104/9987208522';
  static String get _realRewardedInterstitialId =>
      dotenv.env['ADMOB_REWARDED_INTERSTITIAL_ID'] ??
      'ca-app-pub-4239841158013104/1766987477';
  static String get _realNativeId =>
      dotenv.env['ADMOB_NATIVE_ID'] ?? 'ca-app-pub-4239841158013104/9574791316';

  static const String _testInterstitialId =
      'ca-app-pub-3940256099942544/1033173712';
  static const String _testRewardedId =
      'ca-app-pub-3940256099942544/5224354917';
  static const String _testRewardedInterstitialId =
      'ca-app-pub-3940256099942544/5354046379';
  static const String _testNativeId = 'ca-app-pub-3940256099942544/2247696110';

  String get interstitialAdUnitId =>
      kDebugMode ? _testInterstitialId : _realInterstitialId;
  String get rewardedAdUnitId => kDebugMode ? _testRewardedId : _realRewardedId;
  String get rewardedInterstitialAdUnitId =>
      kDebugMode ? _testRewardedInterstitialId : _realRewardedInterstitialId;
  String get nativeAdUnitId => kDebugMode ? _testNativeId : _realNativeId;

  // ═══════════════════════════════════════════════════════════════════════════
  // CONFIG DINÁMICA POR SCORE + SEGMENTO
  // ═══════════════════════════════════════════════════════════════════════════

  // Cooldown base en segundos. Floor: 45s (score 80+), ceiling: 240s (score 20).
  int get _minSecondsBetweenAds {
    final base =
        _toleranceScore >= 80
            ? 45
            : _toleranceScore >= 60
            ? 90
            : _toleranceScore >= 40
            ? 150
            : 240;

    // Usuarios leales: 20% más de tiempo entre anuncios (recompensa)
    if (_userSegment == _UserSegment.loyal) return (base * 1.2).round();
    // Usuarios nuevos: 50% más en los primeros días (no asustarles)
    if (_userSegment == _UserSegment.newUser) return (base * 1.5).round();
    return base;
  }

  int get _maxInterstitialsPerSession {
    if (_toleranceScore >= 80) return 10;
    if (_toleranceScore >= 60) return 7;
    if (_toleranceScore >= 40) return 5;
    return 3;
  }

  // Cada cuántas visitas a detalles se dispara un interstitial
  int get _detailVisitsPerAd {
    if (_userSegment == _UserSegment.newUser) return 3; // menos agresivo
    if (_toleranceScore >= 60) return 1;
    return 2;
  }

  // Periodo de gracia al inicio de sesión (segundos)
  int get _sessionGracePeriodSeconds {
    if (_userSegment == _UserSegment.newUser) return 300; // 5 min para nuevos
    if (_userSegment == _UserSegment.loyal) return 120; // 2 min para leales
    return 60;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // INICIALIZACIÓN
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _sessionStartTime = DateTime.now();
    _adsShownThisSession = 0;

    await _initUserSegment();
    _toleranceScore = (_prefs?.getInt(_toleranceScoreKey) ?? 50).clamp(20, 100);
    _unverifiedViewsThisSession = _prefs?.getInt(_unverifiedViewsKey) ?? 0;

    final lastDate = _prefs?.getString(_lastAdDateKey) ?? '';
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (lastDate != today) {
      await _prefs?.setString(_lastAdDateKey, today);
      await _prefs?.setInt(_adsShownTodayKey, 0);
      await _prefs?.setInt(_unverifiedViewsKey, 0);
      _unverifiedViewsThisSession = 0;
    }

    if (!isSupported) return;

    // ── Colección de Consentimiento (UMP) ──────────────────────────────────
    // Se debe llamar ANTES de inicializar MobileAds.
    await _collectConsent();

    if (await ConsentInformation.instance.canRequestAds()) {
      await MobileAds.instance.initialize();
    } else {
      debugPrint('AdMob: Ads restricted by consent settings.');
    }

    if (kDebugMode) {
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(
          testDeviceIds: ['C144E4EEB4AF727C44726857F3120B2E'],
        ),
      );
    }

    if (!PremiumService().isPremium) {
      await _detectAdBlocker();
      loadInterstitialAd();
      loadRewardedAd();
      loadRewardedInterstitialAd();
    }

    debugPrint(
      'AdMob v2: Segmento=${_userSegment.name} | '
      'Score=$_toleranceScore | '
      'Cooldown=${_minSecondsBetweenAds}s | '
      'Máx/sesión=$_maxInterstitialsPerSession | '
      'AdBlocker=$_adBlockerDetected',
    );
  }

  // ── Consentimiento (UMP) ──────────────────────────────────────────────────

  /// Solicita el estado de consentimiento y muestra el formulario si es necesario.
  /// En modo DEBUG simula estar en el EEA para forzar la aparición del diálogo.
  Future<void> _collectConsent() async {
    final completer = Completer<void>();

    final params = ConsentRequestParameters(
      consentDebugSettings:
          kDebugMode
              ? ConsentDebugSettings(
                debugGeography: DebugGeography.debugGeographyEea,
                testIdentifiers: ['C144E4EEB4AF727C44726857F3120B2E'],
              )
              : null,
    );

    ConsentInformation.instance.requestConsentInfoUpdate(
      params,
      () async {
        ConsentForm.loadAndShowConsentFormIfRequired((loadAndShowError) {
          if (loadAndShowError != null) {
            debugPrint('UMP: Form error: ${loadAndShowError.message}');
          }
          completer.complete();
        });
      },
      (FormError error) {
        debugPrint('UMP: Update error: ${error.message}');
        // Si hay error en la actualización, procedemos igual para no bloquear la app
        completer.complete();
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('UMP: Timeout alcanzado recolectando consentimiento');
      },
    );
  }

  /// Muestra el formulario de opciones de privacidad para que el usuario pueda cambiar su consentimiento.
  /// Requerido por las políticas de Google para permitir al usuario retirar el consentimiento.
  Future<void> showPrivacyOptionsForm() async {
    ConsentForm.showPrivacyOptionsForm((formError) {
      if (formError != null) {
        debugPrint('UMP: Privacy options error: ${formError.message}');
      }
    });
  }

  // ── Segmentación ──────────────────────────────────────────────────────────

  Future<void> _initUserSegment() async {
    final firstLaunch = _prefs?.getString(_firstLaunchDateKey);
    if (firstLaunch == null) {
      await _prefs?.setString(
        _firstLaunchDateKey,
        DateTime.now().toIso8601String(),
      );
    }

    final totalSessions = (_prefs?.getInt(_totalSessionsKey) ?? 0) + 1;
    await _prefs?.setInt(_totalSessionsKey, totalSessions);

    if (firstLaunch != null) {
      final daysSinceFirst =
          DateTime.now().difference(DateTime.parse(firstLaunch)).inDays;
      if (daysSinceFirst > 30) {
        _userSegment = _UserSegment.loyal;
      } else if (daysSinceFirst > 7) {
        _userSegment = _UserSegment.regular;
      } else {
        _userSegment = _UserSegment.newUser;
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ANTI-ADBLOCKER
  // ═══════════════════════════════════════════════════════════════════════════

  /// Detección silenciosa: intenta cargar un rewarded en background.
  /// Si falla con un código de error específico de ad blocker → activar paywall suave.
  /// Sin alertas al usuario — solo registramos el estado internamente.
  Future<void> _detectAdBlocker() async {
    if (!isSupported) return;

    bool probeLoaded = false;

    await RewardedAd.load(
      adUnitId: rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          probeLoaded = true;
          _adBlockerDetected = false;
          // Reutilizar el ad cargado como el rewarded principal
          _rewardedAd = ad;
          _setupRewardedCallbacks(ad);
          _isRewardedAdLoading = false;
        },
        onAdFailedToLoad: (error) {
          // Códigos 2 y 3 suelen indicar bloqueo de red (adblocker)
          if (error.code == 2 || error.code == 3) {
            _adBlockerDetected = true;
            debugPrint(
              'AdMob: Posible adblocker detectado (código ${error.code})',
            );
          } else {
            _adBlockerDetected = false;
          }
          probeLoaded = false;
          _isRewardedAdLoading = false;
        },
      ),
    );

    // Si el probe cargó el rewarded, marcamos la carga como completa
    if (probeLoaded) _isRewardedAdLoading = false;
  }

  /// Verifica si el usuario bloqueado ha superado el límite de acciones gratuitas.
  /// Llama a [onPaywall] si corresponde mostrar el paywall suave.
  bool checkAndHandleBlockedUser({VoidCallback? onPaywall}) {
    if (!_adBlockerDetected) return false;

    _blockedActionsCount++;
    if (_blockedActionsCount >= _maxBlockedActionsBeforePaywall) {
      onPaywall?.call();
      return true;
    }
    return false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SCORE ADAPTATIVO
  // ═══════════════════════════════════════════════════════════════════════════

  void _onAdWatchedCompletely() {
    _toleranceScore = (_toleranceScore + 15).clamp(20, 100);
    _saveScore();
  }

  void _onInterstitialDismissed(int secondsVisible) {
    if (secondsVisible < 3) {
      _toleranceScore = (_toleranceScore - 20).clamp(20, 100);
    } else if (secondsVisible < 8) {
      _toleranceScore = (_toleranceScore - 10).clamp(20, 100);
    } else {
      _onAdWatchedCompletely();
    }
    _saveScore();
    debugPrint(
      'AdMob: Cerrado en ${secondsVisible}s → Score: $_toleranceScore',
    );
  }

  void _onAdFrequencyAbuse() {
    _toleranceScore = (_toleranceScore - 15).clamp(20, 100);
    _saveScore();
  }

  /// Bonificación por acciones positivas del usuario (share, valorar la app, etc.)
  void recordPositiveEngagement() {
    _toleranceScore = (_toleranceScore + 10).clamp(20, 100);
    _saveScore();
    debugPrint('AdMob: Engagement positivo → Score: $_toleranceScore');
  }

  void _saveScore() => _prefs?.setInt(_toleranceScoreKey, _toleranceScore);

  // ═══════════════════════════════════════════════════════════════════════════
  // LÓGICA SMART
  // ═══════════════════════════════════════════════════════════════════════════

  bool _isInGracePeriod() {
    if (_sessionStartTime == null) return true;
    return DateTime.now().difference(_sessionStartTime!).inSeconds <
        _sessionGracePeriodSeconds;
  }

  bool _isCooldownElapsed() {
    if (_lastAdShownTime == null) return true;
    return DateTime.now().difference(_lastAdShownTime!).inSeconds >=
        _minSecondsBetweenAds;
  }

  bool _isSessionLimitReached() =>
      _adsShownThisSession >= _maxInterstitialsPerSession;

  bool _isFrequencyAbusive() {
    if (_lastAdShownTime == null) return false;
    // Más de 3 anuncios en menos de 3 minutos = abusivo
    return _adsShownThisSession >= 3 &&
        DateTime.now().difference(_lastAdShownTime!).inMinutes < 3;
  }

  void _recordAdShown() {
    if (_isFrequencyAbusive()) _onAdFrequencyAbuse();

    _lastAdShownTime = DateTime.now();
    _lastInterstitialShownTime = DateTime.now();
    _adsShownThisSession++;

    final today = DateTime.now().toIso8601String().substring(0, 10);
    final todayAds = (_prefs?.getInt(_adsShownTodayKey) ?? 0) + 1;
    _prefs?.setInt(_adsShownTodayKey, todayAds);
    _prefs?.setString(_lastAdDateKey, today);

    debugPrint(
      'AdMob: #$_adsShownThisSession sesión | Hoy: $todayAds | Score: $_toleranceScore',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SELECCIÓN DE FORMATO
  // ═══════════════════════════════════════════════════════════════════════════

  /// Decide el formato óptimo según score y disponibilidad de ads.
  /// Score bajo → preferir rewarded (el usuario elige verlo, menos intrusivo).
  /// Score alto → interstitial o rewarded interstitial (más CPM, mejor UX).
  void showBestAvailableAd({
    VoidCallback? onAdDismissed,
    VoidCallback? onAdFailed,
    bool force = false,
  }) {
    if (!isSupported || PremiumService().isPremium) {
      onAdDismissed?.call();
      return;
    }

    if (!force) {
      if (_isInGracePeriod() ||
          !_isCooldownElapsed() ||
          _isSessionLimitReached()) {
        onAdDismissed?.call();
        return;
      }
    }

    // Score ≤ 35: preferir rewarded para evitar fricción
    if (_toleranceScore <= 35 && _rewardedAd != null) {
      _recordAdShown();
      _rewardedAd!.show(onUserEarnedReward: (_, _) => onAdDismissed?.call());
      return;
    }

    // Score ≥ 70 + rewarded interstitial disponible: mayor CPM
    if (_toleranceScore >= 70 && _rewardedInterstitialAd != null) {
      _recordAdShown();
      _rewardedInterstitialAd!.show(
        onUserEarnedReward: (_, _) => onAdDismissed?.call(),
      );
      _rewardedInterstitialAd = null;
      loadRewardedInterstitialAd();
      return;
    }

    // Default: interstitial
    showInterstitialAd(force: force, onAdDismissed: onAdDismissed);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // INTERSTITIAL AD
  // ═══════════════════════════════════════════════════════════════════════════

  void loadInterstitialAd() {
    if (!isSupported || _isInterstitialAdLoading) return;
    _isInterstitialAdLoading = true;

    InterstitialAd.load(
      adUnitId: interstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interstitialAd = ad;
          _isInterstitialAdLoading = false;
          _setupInterstitialCallbacks(ad);
        },
        onAdFailedToLoad: (error) {
          _interstitialAd = null;
          _isInterstitialAdLoading = false;
        },
      ),
    );
  }

  void _setupInterstitialCallbacks(InterstitialAd ad) {
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) {
        isAdInProgress.value = true;
        _lastInterstitialShownTime = DateTime.now();
      },
      onAdDismissedFullScreenContent: (ad) {
        isAdInProgress.value = false;
        if (_lastInterstitialShownTime != null) {
          _onInterstitialDismissed(
            DateTime.now().difference(_lastInterstitialShownTime!).inSeconds,
          );
        }
        ad.dispose();
        _interstitialAd = null;
        loadInterstitialAd();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        isAdInProgress.value = false;
        ad.dispose();
        _interstitialAd = null;
        loadInterstitialAd();
      },
    );
  }

  void showInterstitialAd({bool force = false, VoidCallback? onAdDismissed}) {
    if (!isSupported || PremiumService().isPremium) {
      onAdDismissed?.call();
      return;
    }

    if (!force) {
      if (_isInGracePeriod() ||
          !_isCooldownElapsed() ||
          _isSessionLimitReached()) {
        onAdDismissed?.call();
        return;
      }
    }

    if (_interstitialAd == null) {
      loadInterstitialAd();
      onAdDismissed?.call();
      return;
    }

    _doShowInterstitial(onAdDismissed);
  }

  void _doShowInterstitial(VoidCallback? onAdDismissed) {
    if (_interstitialAd == null) {
      onAdDismissed?.call();
      return;
    }

    if (onAdDismissed != null) {
      _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdShowedFullScreenContent: (_) {
          isAdInProgress.value = true;
          _lastInterstitialShownTime = DateTime.now();
        },
        onAdDismissedFullScreenContent: (ad) {
          isAdInProgress.value = false;
          if (_lastInterstitialShownTime != null) {
            _onInterstitialDismissed(
              DateTime.now().difference(_lastInterstitialShownTime!).inSeconds,
            );
          }
          ad.dispose();
          _interstitialAd = null;
          loadInterstitialAd();
          onAdDismissed();
        },
        onAdFailedToShowFullScreenContent: (ad, _) {
          isAdInProgress.value = false;
          ad.dispose();
          _interstitialAd = null;
          loadInterstitialAd();
          onAdDismissed();
        },
      );
    }
    _recordAdShown();
    _interstitialAd!.show();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // REWARDED AD
  // ═══════════════════════════════════════════════════════════════════════════

  void loadRewardedAd() {
    if (!isSupported || _isRewardedAdLoading) return;
    _isRewardedAdLoading = true;

    RewardedAd.load(
      adUnitId: rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedAd = ad;
          _isRewardedAdLoading = false;
          _setupRewardedCallbacks(ad);
        },
        onAdFailedToLoad: (error) {
          _rewardedAd = null;
          _isRewardedAdLoading = false;
          _lastLoadErrorCode = error.code;
          if (error.code == 2 || error.code == 3) {
            _adBlockerDetected = true;
          }
        },
      ),
    );
  }

  void _setupRewardedCallbacks(RewardedAd ad) {
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) => isAdInProgress.value = true,
      onAdDismissedFullScreenContent: (ad) {
        isAdInProgress.value = false;
        // Doble bonus — rewarded es voluntario
        _onAdWatchedCompletely();
        _onAdWatchedCompletely();
        ad.dispose();
        _rewardedAd = null;
        loadRewardedAd();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        isAdInProgress.value = false;
        ad.dispose();
        _rewardedAd = null;
        loadRewardedAd();
      },
    );
  }

  void showRewardedAd({
    required VoidCallback onUserEarnedReward,
    VoidCallback? onAdFailed,
  }) {
    if (kBypassAdGateForTesting || !isSupported || PremiumService().isPremium) {
      onUserEarnedReward();
      return;
    }
    if (_rewardedAd != null) {
      _recordAdShown();
      _rewardedAd!.show(onUserEarnedReward: (_, _) => onUserEarnedReward());
    } else {
      loadRewardedAd();
      onAdFailed?.call();
    }
  }

  void showRewardedAdWithConfirmation(
    BuildContext context, {
    required VoidCallback onUserEarnedReward,
    VoidCallback? onAdFailed,
    VoidCallback? onCancel,
    String? message,
    int quarterTurns = 0,
  }) {
    if (kBypassAdGateForTesting || !isSupported || PremiumService().isPremium) {
      onUserEarnedReward();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      showGeneralDialog<dynamic>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '',
        barrierColor: const Color(0xFF0a0a0a).withOpacity(0.4),
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, _, _) => const SizedBox.shrink(),
        transitionBuilder: (context, anim, _, _) {
          final curve = CurvedAnimation(
            parent: anim,
            curve: Curves.easeOutBack,
            reverseCurve: Curves.easeIn,
          );
          final dialog = Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 24),
            child: _RewardedAdConfirmationDialog(
              message: message,
              adService: this,
              onUserEarnedReward: onUserEarnedReward,
              onAdFailed: onAdFailed,
            ),
          );

          return FadeTransition(
            opacity: anim,
            child: ScaleTransition(
              scale: curve,
              child:
                  quarterTurns != 0
                      ? RotatedBox(quarterTurns: quarterTurns, child: dialog)
                      : dialog,
            ),
          );
        },
      ).then((result) async {
        if (result == 'premium') {
          if (context.mounted) {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            );
            if (PremiumService().isPremium) {
              onUserEarnedReward();
            } else {
              onCancel?.call();
            }
          }
        } else if (result != true) {
          onCancel?.call();
        }
      });
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // REWARDED INTERSTITIAL
  // ═══════════════════════════════════════════════════════════════════════════

  void loadRewardedInterstitialAd() {
    if (!isSupported || _isRewardedInterstitialLoading) return;
    _isRewardedInterstitialLoading = true;

    RewardedInterstitialAd.load(
      adUnitId: rewardedInterstitialAdUnitId,
      request: const AdRequest(),
      rewardedInterstitialAdLoadCallback: RewardedInterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedInterstitialAd = ad;
          _isRewardedInterstitialLoading = false;
        },
        onAdFailedToLoad: (_) {
          _rewardedInterstitialAd = null;
          _isRewardedInterstitialLoading = false;
        },
      ),
    );
  }

  void showRewardedInterstitialAd({required Function onUserEarnedReward}) {
    if (!isSupported) {
      onUserEarnedReward();
      return;
    }
    if (_rewardedInterstitialAd != null) {
      _recordAdShown();
      _rewardedInterstitialAd!.show(
        onUserEarnedReward: (_, _) => onUserEarnedReward(),
      );
      _rewardedInterstitialAd = null;
      loadRewardedInterstitialAd();
    } else {
      loadRewardedInterstitialAd();
      onUserEarnedReward();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SMART TRIGGERS
  // ═══════════════════════════════════════════════════════════════════════════

  void recordDetailsVisit() {
    _detailsVisitCount++;
    if (_detailsVisitCount % _detailVisitsPerAd == 0) {
      // Usar showBestAvailableAd en lugar de forzar siempre interstitial
      showBestAvailableAd(force: false);
    }
  }

  void triggerSmartMidRoll({
    bool force = false,
    VoidCallback? onAdDismissed,
    VoidCallback? onAdFailed,
  }) {
    if (!isSupported || PremiumService().isPremium) {
      onAdDismissed?.call();
      return;
    }
    if (!force && !_isCooldownElapsed()) {
      onAdDismissed?.call();
      return;
    }
    if (_interstitialAd != null) {
      if (onAdDismissed != null) {
        _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
          onAdShowedFullScreenContent: (_) {
            isAdInProgress.value = true;
            _lastInterstitialShownTime = DateTime.now();
          },
          onAdDismissedFullScreenContent: (ad) {
            isAdInProgress.value = false;
            if (_lastInterstitialShownTime != null) {
              _onInterstitialDismissed(
                DateTime.now()
                    .difference(_lastInterstitialShownTime!)
                    .inSeconds,
              );
            }
            ad.dispose();
            _interstitialAd = null;
            loadInterstitialAd();
            onAdDismissed();
          },
          onAdFailedToShowFullScreenContent: (ad, _) {
            isAdInProgress.value = false;
            ad.dispose();
            _interstitialAd = null;
            loadInterstitialAd();
            onAdFailed != null ? onAdFailed() : onAdDismissed();
          },
        );
      }
      _recordAdShown();
      _interstitialAd!.show();
    } else {
      loadInterstitialAd();
      onAdFailed?.call();
    }
  }

  bool shouldShowMidRoll(int videoDurationMinutes) => _isCooldownElapsed();

  int getMidRollPosition(int videoDurationSeconds) {
    if (videoDurationSeconds < 300) return -1;
    return (videoDurationSeconds ~/ 2) + 120;
  }

  void recordVideoStart() {}

  Map<String, dynamic> getAdStats() {
    return {
      'user_segment': _userSegment.name,
      'tolerance_score': _toleranceScore,
      'cooldown_seconds': _minSecondsBetweenAds,
      'max_per_session': _maxInterstitialsPerSession,
      'visits_per_ad': _detailVisitsPerAd,
      'grace_period_seconds': _sessionGracePeriodSeconds,
      'ads_this_session': _adsShownThisSession,
      'ads_today': _prefs?.getInt(_adsShownTodayKey) ?? 0,
      'in_grace_period': _isInGracePeriod(),
      'cooldown_elapsed': _isCooldownElapsed(),
      'adblocker_detected': _adBlockerDetected,
      'blocked_actions': _blockedActionsCount,
    };
  }
}
// ═══════════════════════════════════════════════════════════════════════════
// REWARDED CONFIRMATION DIALOG
// ═══════════════════════════════════════════════════════════════════════════

enum DialogState { initial, loading, fallbackAllowed, limitReached, adblocker }

class _RewardedAdConfirmationDialog extends StatefulWidget {
  final String? message;
  final AdService adService;
  final VoidCallback onUserEarnedReward;
  final VoidCallback? onAdFailed;

  const _RewardedAdConfirmationDialog({
    this.message,
    required this.adService,
    required this.onUserEarnedReward,
    this.onAdFailed,
  });

  @override
  State<_RewardedAdConfirmationDialog> createState() =>
      _RewardedAdConfirmationDialogState();
}

class _RewardedAdConfirmationDialogState
    extends State<_RewardedAdConfirmationDialog> {
  DialogState _state = DialogState.initial;
  int _secondsLeft = 10;
  Timer? _countdownTimer;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _handleConfirm() async {
    if (widget.adService._adBlockerDetected) {
      setState(() {
        _state = DialogState.adblocker;
      });
      return;
    }
    if (widget.adService.hasReachedUnverifiedLimit) {
      setState(() {
        _state = DialogState.limitReached;
      });
      return;
    }

    setState(() {
      _state = DialogState.loading;
      _secondsLeft = 10;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (widget.adService._rewardedAd != null) {
        timer.cancel();
        Navigator.pop(context, true);
        widget.adService.showRewardedAd(
          onUserEarnedReward: widget.onUserEarnedReward,
          onAdFailed: widget.onAdFailed,
        );
        return;
      }
      if (_secondsLeft <= 1) {
        timer.cancel();
        _handleTimeout();
      } else {
        setState(() {
          _secondsLeft--;
        });
      }
    });

    // Proactivamente intentar cargar si es nulom
    if (widget.adService._rewardedAd == null &&
        !widget.adService._isRewardedAdLoading) {
      widget.adService.loadRewardedAd();
    }
  }

  void _handleTimeout() {
    if (!mounted) return;
    if (widget.adService._adBlockerDetected) {
      setState(() {
        _state = DialogState.adblocker;
      });
    } else if (widget.adService.hasReachedUnverifiedLimit) {
      setState(() {
        _state = DialogState.limitReached;
      });
    } else {
      setState(() {
        _state = DialogState.fallbackAllowed;
      });
    }
  }

  void _navigateToPremium() {
    Navigator.pop(context, 'premium');
  }

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color iconColor;
    Color iconBgColor;
    String title;
    String message;
    Widget buttons;

    switch (_state) {
      case DialogState.initial:
        icon = Icons.play_circle_filled_rounded;
        iconColor = Colors.red;
        iconBgColor = Colors.red.withOpacity(0.15);
        title = '¡Todo listo!';
        message =
            widget.message ?? 'Para iniciar la reproducción, mira un anuncio.';
        buttons = Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              child: const Text(
                'Ahora no',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _handleConfirm,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF44336).withOpacity(0.9),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Ver ahora',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        );
        break;

      case DialogState.loading:
        icon = Icons.play_circle_filled_rounded;
        iconColor = Colors.red;
        iconBgColor = Colors.red.withOpacity(0.15);
        title = '¡Todo listo!';
        message =
            widget.message ?? 'Para iniciar la reproducción, mira un anuncio.';
        buttons = Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            ElevatedButton(
              onPressed: null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF44336).withOpacity(0.4),
                foregroundColor: Colors.white60,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Cargando ($_secondsLeft s)',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
        break;

      case DialogState.adblocker:
        icon = Icons.gpp_bad_rounded;
        iconColor = Colors.redAccent;
        iconBgColor = Colors.redAccent.withOpacity(0.15);
        title = 'Bloqueador activo';
        message =
            'Hemos detectado un bloqueador de anuncios (AdBlock) o VPN activo. Desactívalo o suscríbete a Premium para ver el contenido directamente.';
        buttons = Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              child: const Text(
                'Cerrar',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _navigateToPremium,

              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF44336).withOpacity(0.9),
                foregroundColor: const Color.fromARGB(255, 235, 235, 235),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              label: const Text(
                'Hazte Premium',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        );
        break;

      case DialogState.limitReached:
        icon = Icons.block_flipped;
        iconColor = Colors.redAccent;
        iconBgColor = Colors.redAccent.withOpacity(0.15);
        title =
            'Sin conexión (${widget.adService.unverifiedViewsThisSession}/3)';
        message =
            'Espera un momento... Si el error persiste, desactiva tu VPN o AdBlocker, o Hazte Premium.';
        buttons = Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              child: const Text(
                'Cerrar',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _navigateToPremium,

              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF44336).withOpacity(0.9),
                foregroundColor: const Color.fromARGB(255, 235, 235, 235),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              label: const Text(
                '¡Hazte Premium!',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        );
        break;

      case DialogState.fallbackAllowed:
        icon = Icons.wifi_off_rounded;
        iconColor = Colors.amber;
        iconBgColor = Colors.amber.withOpacity(0.15);
        title = 'Sin conexión';
        message =
            'Puedes seguir viendo. (${widget.adService.unverifiedViewsThisSession}/3 accesos offline usados).';
        buttons = Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _navigateToPremium,
              style: TextButton.styleFrom(
                foregroundColor: Colors.amber,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
              child: const Text(
                '¡Hazte Premium!',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () {
                widget.adService.incrementUnverifiedViews();
                SnackBarUtils.showAppSnackBar(
                  context,
                  'Sin conexión (${widget.adService.unverifiedViewsThisSession}/3 accesos offline)',
                );
                Navigator.pop(context, true);
                widget.onUserEarnedReward();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF44336).withOpacity(0.9),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Continuar',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        );
        break;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 45, sigmaY: 45),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
              width: 1.5,
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.1),
                Colors.white.withOpacity(0.02),
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: iconBgColor,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: iconColor, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19.6,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                message,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 28),
              buttons,
            ],
          ),
        ),
      ),
    );
  }
}
