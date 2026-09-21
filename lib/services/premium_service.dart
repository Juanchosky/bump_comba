import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
  /// Con qué identidad se presenta este usuario al vincular un televisor.
  ///
  /// Es el `appUserID` de RevenueCat, que es donde vive la suscripción. El
  /// servidor lo usa para preguntarle a RevenueCat si esa cuenta esta al
  /// corriente.
  ///
  /// Devuelve null cuando no hay identidad, y entonces no hay nada que
  /// vincular. Ojo: esto NO decide si el usuario es premium — solo dice con
  /// que nombre preguntarlo. Quien decide es el servidor.
  Future<({String ref, String kind})?> identidadParaTv() async {
    try {
      final id = await Purchases.appUserID;
      if (id.isNotEmpty) return (ref: id, kind: 'revenuecat');
    } catch (e) {
      debugPrint('Premium: no se pudo leer el appUserID: $e');
    }
    return null;
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

  // ═══════════════════════════════════════════════════════════════════════════
  // CLEANUP
  // ═══════════════════════════════════════════════════════════════════════════

  void dispose() {
    _premiumStatusController.close();
  }
}
