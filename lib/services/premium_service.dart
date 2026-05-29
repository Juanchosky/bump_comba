import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'm3u_service.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Service to manage premium subscription status via RevenueCat and Supabase (PC)
class PremiumService {
  static final PremiumService _instance = PremiumService._internal();
  factory PremiumService() => _instance;
  PremiumService._internal();

  // ═══════════════════════════════════════════════════════════════════════════
  // CONFIGURATION
  // ═══════════════════════════════════════════════════════════════════════════

  // RevenueCat API keys
  static String get _androidApiKey =>
      dotenv.env['REVENUECAT_ANDROID_KEY'] ??
      'goog_choPIwxbmFDjcTSaglVwWRsEGYR';
  static String get _iosApiKey =>
      dotenv.env['REVENUECAT_IOS_KEY'] ??
      'goog_choPIwxbmFDjcTSaglVwWRsEGYR'; // Use same key if no iOS version yet

  // Product identifiers (configure these in RevenueCat dashboard and store)
  static const String monthlyProductId = 'premium_monthly';
  static const String annualProductId = 'premium_annual';
  static const String lifetimeProductId = 'premium_lifetime';

  static const String _premiumCacheKey = 'is_premium_cached';
  static const String _lastCheckKey = 'premium_last_check';
  static const String _pcLicenseKey = 'pc_premium_license_code';
  static const Duration _cacheValidDuration = Duration(hours: 1);

  // ═══════════════════════════════════════════════════════════════════════════
  // STATE
  // ═══════════════════════════════════════════════════════════════════════════

  bool get _isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool _isInitialized = false;
  bool _isPremium = false;
  CustomerInfo? _customerInfo; // Store full info
  SharedPreferences? _prefs;

  // PC License State
  String? _pcExpirationDate;
  static const String _pcManagementUrl =
      'https://bump-comba-landing.vercel.app/';

  // Stream controller for premium status changes
  final _premiumStatusController = StreamController<bool>.broadcast();
  Stream<bool> get premiumStream => _premiumStatusController.stream;

  /// Get current premium status (cached, fast access)
  /// bool get isPremium => _isPremium;

  /// Check if user has any active premium entitlement
  /// bool get hasActiveSubscription => _isPremium;

  bool get isPremium => kDebugMode ? true : _isPremium;

  bool get hasActiveSubscription => isPremium;

  /// Get the expiration date of the active subscription
  String? get expirationDate {
    // 1. Check if we have a PC License active first
    if (_pcExpirationDate != null) {
      return _pcExpirationDate;
    }

    // 2. Fallback to Debug or RevenueCat
    if (kDebugMode) {
      // Return a fake date for testing UI
      return DateTime.now().add(const Duration(days: 30)).toIso8601String();
    }
    if (_customerInfo?.entitlements.active.isNotEmpty ?? false) {
      // Get the most recent active entitlement
      final entitlement = _customerInfo!.entitlements.active.values.first;
      return entitlement.expirationDate;
    }
    return null;
  }

  /// Get the management URL for the subscription
  String? get managementUrl {
    if (_pcExpirationDate != null) {
      return _pcManagementUrl;
    }
    if (_customerInfo?.managementURL != null) {
      return _customerInfo!.managementURL;
    }
    return null;
  }

  /// Get unique device ID (Hardware ID) for Windows
  Future<String?> _getDeviceId() async {
    try {
      if (kIsWeb) return null;
      final deviceInfo = DeviceInfoPlugin();
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        // deviceId on Windows is usually a unique hardware identifier
        return windowsInfo.deviceId;
      }
      return null;
    } catch (e) {
      debugPrint('Premium: Error getting device ID: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // INITIALIZATION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Initialize RevenueCat SDK
  /// Call this once at app startup (e.g., in main.dart)
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _prefs = await SharedPreferences.getInstance();

      // Load cached premium status for immediate UI response
      _isPremium = _prefs?.getBool(_premiumCacheKey) ?? false;

      // Ensure Supabase is initialized before checking PC license
      await M3UService.initializeSupabase();

      // 1. Check PC License completely bypasses RevenueCat if valid
      if (!_isSupported) {
        final pcKeyResult = await _validateStoredPCLicense();
        if (pcKeyResult) {
          _isPremium = true;
          _isInitialized = true;
          _premiumStatusController.add(_isPremium);
          debugPrint('Premium: PC License is valid and active');
          return;
        }
      }

      // Configure RevenueCat
      PurchasesConfiguration configuration;
      if (_isSupported && defaultTargetPlatform == TargetPlatform.android) {
        configuration = PurchasesConfiguration(_androidApiKey);
      } else if (_isSupported && defaultTargetPlatform == TargetPlatform.iOS) {
        configuration = PurchasesConfiguration(_iosApiKey);
      } else {
        // Unsupported platform
        debugPrint('Premium: Unsupported platform');
        _isInitialized = true;
        return;
      }

      // Configure RevenueCat
      await Purchases.configure(configuration);

      // Set up listener for subscription changes
      Purchases.addCustomerInfoUpdateListener(_onCustomerInfoUpdated);

      // Fetch latest customer info
      await _refreshPremiumStatus();

      _isInitialized = true;
      debugPrint('Premium: Initialized successfully');
    } catch (e) {
      debugPrint('Premium: Initialization error: $e');
      _isInitialized = true; // Mark as initialized to avoid retry loops
    }
  }

  /// Callback when customer info updates
  void _onCustomerInfoUpdated(CustomerInfo customerInfo) {
    debugPrint('Premium: Customer info updated');
    _updatePremiumStatus(customerInfo);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PREMIUM STATUS MANAGEMENT
  // ═══════════════════════════════════════════════════════════════════════════

  /// Refresh premium status from RevenueCat
  Future<void> _refreshPremiumStatus() async {
    if (!_isSupported) return;
    try {
      final customerInfo = await Purchases.getCustomerInfo();
      _updatePremiumStatus(customerInfo);
    } catch (e) {
      debugPrint('Premium: Error refreshing status: $e');
    }
  }

  /// Update premium status based on customer info
  void _updatePremiumStatus(CustomerInfo customerInfo) {
    _customerInfo = customerInfo; // Store info

    // Check if user has any active entitlement
    // You can customize this check based on your entitlement identifier
    final wasPremium = _isPremium;
    _isPremium = customerInfo.entitlements.active.isNotEmpty;

    // Cache the status locally
    _prefs?.setBool(_premiumCacheKey, _isPremium);
    _prefs?.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);

    // Notify listeners if status changed
    if (wasPremium != _isPremium) {
      debugPrint('Premium: Status changed to: $_isPremium');
      _premiumStatusController.add(_isPremium);
    }
  }

  /// Force refresh premium status (call this after app resume)
  Future<void> checkPremiumStatus() async {
    if (!_isInitialized) {
      await initialize();
      return;
    }

    // Check if cache is still valid
    final lastCheck = _prefs?.getInt(_lastCheckKey);
    if (lastCheck != null) {
      final timeSinceCheck = DateTime.now().millisecondsSinceEpoch - lastCheck;
      if (timeSinceCheck < _cacheValidDuration.inMilliseconds) {
        // Cache is still valid, no need to refresh
        return;
      }
    }

    await _refreshPremiumStatus();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PURCHASE FLOW
  // ═══════════════════════════════════════════════════════════════════════════

  /// Get available offerings from RevenueCat
  Future<Offerings?> getOfferings() async {
    if (!_isSupported) return null;
    try {
      final offerings = await Purchases.getOfferings();
      return offerings;
    } catch (e) {
      debugPrint('Premium: Error getting offerings: $e');
      return null;
    }
  }

  /// Purchase a product
  /// Returns true if purchase was successful
  /// [offeringIdentifier] can be used to target a specific offering
  Future<bool> purchase(String productId, {String? offeringIdentifier}) async {
    if (!_isSupported) return false;
    try {
      debugPrint(
        'Premium: Attempting to purchase: $productId (Offering: ${offeringIdentifier ?? 'current'})',
      );

      final offerings = await getOfferings();
      if (offerings == null) {
        debugPrint('Premium: Error fetching offerings');
        return false;
      }

      Package? packageToPurchase;

      // 1. Try to find in specific offering if provided
      if (offeringIdentifier != null) {
        final specificOffering = offerings.all[offeringIdentifier];
        if (specificOffering != null) {
          for (final package in specificOffering.availablePackages) {
            if (package.storeProduct.identifier == productId) {
              packageToPurchase = package;
              break;
            }
          }
        }
      }

      // 2. Try to find in current offering
      if (packageToPurchase == null && offerings.current != null) {
        for (final package in offerings.current!.availablePackages) {
          if (package.storeProduct.identifier == productId) {
            packageToPurchase = package;
            break;
          }
        }
      }

      // 3. Fallback: Search in ALL offerings
      if (packageToPurchase == null) {
        debugPrint(
          'Premium: Product not found in target/current offering, searching all...',
        );
        for (final offering in offerings.all.values) {
          for (final package in offering.availablePackages) {
            if (package.storeProduct.identifier == productId) {
              packageToPurchase = package;
              break;
            }
          }
          if (packageToPurchase != null) break;
        }
      }

      if (packageToPurchase == null) {
        debugPrint('Premium: Product not found anywhere: $productId');
        return false;
      }

      // Make the purchase
      final purchaseResult = await Purchases.purchasePackage(packageToPurchase);

      // Update premium status
      _updatePremiumStatus(purchaseResult.customerInfo);

      debugPrint('Premium: Purchase status updated. Premium: $_isPremium');
      return _isPremium;
    } on PlatformException catch (e) {
      final errorCode = PurchasesErrorHelper.getErrorCode(e);
      if (errorCode == PurchasesErrorCode.purchaseCancelledError) {
        debugPrint('Premium: Purchase cancelled by user');
      } else {
        debugPrint(
          'Premium: Purchase PlatformException: ${e.message} (Code: $errorCode)',
        );
        // Re-throw to let UI handle the specific error message
        rethrow;
      }
      return false;
    } catch (e) {
      debugPrint('Premium: Purchase unexpected error: $e');
      rethrow;
    }
  }

  /// Restore previous purchases
  /// Returns true if premium was restored
  Future<bool> restorePurchases() async {
    if (!_isSupported) return false;
    try {
      debugPrint('Premium: Restoring purchases');
      final customerInfo = await Purchases.restorePurchases();
      _updatePremiumStatus(customerInfo);
      debugPrint('Premium: Restore completed. Premium: $_isPremium');
      return _isPremium;
    } catch (e) {
      debugPrint('Premium: Restore error: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // FEATURE CHECKS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Check if user can add more M3U sources (limit for free users)
  bool canAddM3USource(int currentSourceCount) {
    if (isPremium) return true;
    return currentSourceCount < 3; // Free users: max 3 sources
  }

  /// Get maximum history items for user
  int getMaxHistoryItems() {
    return isPremium ? -1 : 20; // -1 = unlimited, 20 for free
  }

  /// Check if ads should be shown
  bool shouldShowAds() {
    return !isPremium;
  }

  /// Check if user can use Picture-in-Picture (Premium only)
  bool canUsePiP() {
    return isPremium;
  }

  /// Check if user can download media (Premium only)
  bool canDownloadMedia() {
    return isPremium;
  }

  /// Check if user can add to "My List" (Free limit: 5)
  bool canAddFavorite(int currentFavoriteCount) {
    if (isPremium) return true;
    return currentFavoriteCount < 5;
  }

  /// Check if user can add live channels to "Mi Lista" (Free limit: 4)
  bool canAddLiveFavorite(int currentLiveFavoriteCount) {
    if (isPremium) return true;
    return currentLiveFavoriteCount < 4;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PC / WINDOWS LICENSE KEY MANAGEMENT
  // ═══════════════════════════════════════════════════════════════════════════

  /// Helper to validate a stored PC license on app startup
  Future<bool> _validateStoredPCLicense() async {
    try {
      final storedCode = _prefs?.getString(_pcLicenseKey);
      if (storedCode == null || storedCode.isEmpty) return false;

      final response =
          await Supabase.instance.client
              .from('premium_codes')
              .select('*')
              .eq('code', storedCode)
              .maybeSingle();

      if (response == null) {
        // Code was deleted from server or is invalid
        await _prefs?.remove(_pcLicenseKey);
        return false;
      }

      // Check Expiration
      if (response['expires_at'] != null) {
        final expiresAt = DateTime.parse(response['expires_at']);
        if (DateTime.now().isAfter(expiresAt)) {
          debugPrint('Premium: PC License code expired');
          await _prefs?.remove(_pcLicenseKey);
          await _prefs?.remove('${_pcLicenseKey}_expires_at');
          _pcExpirationDate = null;
          return false;
        }

        // Security check: Verify device ID matches if bound
        final currentDeviceId = await _getDeviceId();
        if (response['used_by_device_id'] != null &&
            currentDeviceId != null &&
            response['used_by_device_id'] != currentDeviceId) {
          debugPrint('Premium: License bound to another device');
          _isPremium = false;
          await _prefs?.remove(_pcLicenseKey);
          return false;
        }

        _pcExpirationDate = response['expires_at'];
      }

      return true;
    } catch (e) {
      debugPrint('Premium: Error validating PC license: $e');
      // Honour offline cache temporarily
      if (_prefs?.getString(_pcLicenseKey) != null) {
        _pcExpirationDate = _prefs?.getString('${_pcLicenseKey}_expires_at');
        return true;
      }
      return false;
    }
  }

  /// UI Facing method: User inputs a code to activate Premium on PC
  Future<Map<String, dynamic>> validateAndActivateLicenseCode(
    String code,
  ) async {
    try {
      final cleanCode = code.trim().toUpperCase();
      if (cleanCode.isEmpty) {
        return {'success': false, 'message': 'El código no puede estar vacío.'};
      }

      final response =
          await Supabase.instance.client
              .from('premium_codes')
              .select('*')
              .eq('code', cleanCode)
              .maybeSingle();

      if (response == null) {
        return {
          'success': false,
          'message': 'Código inválido o no encontrado.',
        };
      }

      // Check if expired
      if (response['expires_at'] != null) {
        final expiresAt = DateTime.parse(response['expires_at']);
        if (DateTime.now().isAfter(expiresAt)) {
          return {
            'success': false,
            'message': 'Este código de licencia ha expirado.',
          };
        }
      }

      // Check if already used by another device
      final currentDeviceId = await _getDeviceId();
      if (response['is_used'] == true &&
          response['used_by_device_id'] != null &&
          currentDeviceId != null &&
          response['used_by_device_id'] != currentDeviceId) {
        return {
          'success': false,
          'message': 'Este código de licencia ya está vinculado a otro equipo.',
        };
      }

      // Update DB to mark as used and bind to this device
      if (response['is_used'] == false) {
        await Supabase.instance.client
            .from('premium_codes')
            .update({
              'is_used': true,
              'used_at': DateTime.now().toIso8601String(),
              'used_by_device_id': currentDeviceId,
            })
            .eq('code', cleanCode);
      }

      // Save locally and activate
      await _prefs?.setString(_pcLicenseKey, cleanCode);

      _isPremium = true;
      if (response['expires_at'] != null) {
        _pcExpirationDate = response['expires_at'];
        await _prefs?.setString(
          '${_pcLicenseKey}_expires_at',
          _pcExpirationDate!,
        );
      }

      _prefs?.setBool(_premiumCacheKey, true);
      _premiumStatusController.add(true);

      return {
        'success': true,
        'message': '¡Código activado con éxito! Bienvenido a Premium.',
      };
    } catch (e) {
      debugPrint('Premium: Redempton error: $e');
      return {
        'success': false,
        'message': 'Error de conexión. Inténtalo de nuevo.',
      };
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CLEANUP
  // ═══════════════════════════════════════════════════════════════════════════

  void dispose() {
    _premiumStatusController.close();
  }
}
