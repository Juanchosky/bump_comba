import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../services/premium_service.dart';
import '../utils/colors.dart';
import '../services/localization_service.dart';
import '../utils/snack_bar_utils.dart';

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  final _premiumService = PremiumService();
  final _locService = LocalizationService();
  Offering? _currentOffering; // Valid offering to display
  bool _isLoading = true;
  String? _selectedProductId;
  bool _isPurchasing = false;

  Future<void> _loadOfferings() async {
    setState(() => _isLoading = true);

    try {
      final offerings = await _premiumService.getOfferings();

      // Intentar obtener el offering específico para esta app
      // Esto evita conflictos si hay múltiples apps en el mismo proyecto de RevenueCat
      Offering? myOffering = offerings?.getOffering('subscriptions_BumpComba');

      // Fallback: Si no encuentra el específico, usa el default (current)
      myOffering ??= offerings?.current;

      setState(() {
        _currentOffering = myOffering;
        _isLoading = false;

        // Usar el offering específico encontrado
        if (myOffering != null) {
          final packages = myOffering.availablePackages;

          // Si solo hay un paquete (el mensual), selecciónalo por defecto
          if (packages.isNotEmpty) {
            _selectedProductId = packages.first.storeProduct.identifier;
          }

          // Si por casualidad agregas el anual después, esto priorizaría el anual
          // pero si solo tienes mensual, seleccionará el mensual.
          for (final package in packages) {
            if (package.storeProduct.identifier ==
                PremiumService.annualProductId) {
              _selectedProductId = package.storeProduct.identifier;
              break;
            }
          }
        }
      });
    } catch (e) {
      setState(() => _isLoading = false);
      debugPrint('Error loading offerings: $e');
    }
  }

  Future<void> _purchase() async {
    if (_selectedProductId == null || _isPurchasing) return;

    setState(() => _isPurchasing = true);

    try {
      final success = await _premiumService.purchase(
        _selectedProductId!,
        offeringIdentifier: _currentOffering?.identifier,
      );

      if (success && mounted) {
        // Show success message
        SnackBarUtils.showAppSnackBar(
          context,
          '¡Felicidades! Ahora eres Premium 👑',
        );

        // Wait a moment then close
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          Navigator.of(context).pop(true); // Return true to indicate success
        }
      } else if (mounted) {
        // This case handles user cancel or general false return from service
        // without an explicit exception thrown
        SnackBarUtils.showAppSnackBar(
          context,
          'No se pudo completar la compra',
        );
      }
    } catch (e) {
      debugPrint('Purchase error: $e');
      if (mounted) {
        String errorMessage = 'No se pudo completar la compra';

        // Extract more user-friendly message if possible
        if (e is PlatformException) {
          errorMessage = e.message ?? errorMessage;
        } else {
          errorMessage = e.toString();
        }

        SnackBarUtils.showAppSnackBar(context, 'Error: $errorMessage');
      }
    } finally {
      if (mounted) {
        setState(() => _isPurchasing = false);
      }
    }
  }

  Future<void> _restore() async {
    setState(() => _isPurchasing = true);

    try {
      final success = await _premiumService.restorePurchases();

      if (success && mounted) {
        SnackBarUtils.showAppSnackBar(
          context,
          '✓ Compras restauradas exitosamente',
        );

        Navigator.of(context).pop(true);
      } else if (mounted) {
        SnackBarUtils.showAppSnackBar(
          context,
          'No se encontraron compras previas',
        );
      }
    } catch (e) {
      debugPrint('Restore error: $e');
      if (mounted) {
        SnackBarUtils.showAppSnackBar(
          context,
          'Error al restaurar: ${e.toString()}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPurchasing = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _locService.init().then((_) => setState(() {}));
    _loadOfferings();

    // Force status bar color on init
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Top-level AnnotatedRegion to ensure status bar color is applied
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppColors.background,
        body:
            _isLoading
                ? const Center(
                  child: CircularProgressIndicator(color: Colors.amber),
                )
                : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0a0a0a), // Deep charcoal
            Color(0xFF070707), // Black oil
            Color(0xFF000000), // Pure black
          ],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      child: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 80),

                  // App Branding / Title
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Expanded(
                          child: Text(
                            '¡Desbloquea todo el potencial de Bump!',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Obtén más acceso con funciones avanzadas y beneficios exclusivos:',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Selected Plan Highlight
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.1),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Comparison Header
                        _buildComparisonRow(
                          'Característica',
                          'Gratis',
                          'Premium',
                          isHeader: true,
                        ),
                        const Divider(color: Colors.white10),

                        _buildComparisonRow('Sin anuncios', 'No', '✓'),
                        _buildComparisonRow(
                          'Listas M3U',
                          'Limitado',
                          'Ilimitadas',
                        ),
                        _buildComparisonRow(
                          'Mi Lista (Favoritos)',
                          'Máx 5',
                          'Ilimitada',
                        ),
                        _buildComparisonRow('Modo Ventana (PiP)', 'No', 'Sí'),
                        _buildComparisonRow(
                          'Velocidad de Video',
                          '1.0x',
                          'Hasta 2.0x',
                        ),
                        _buildComparisonRow(
                          'Historial de Vistos',
                          '20 items',
                          'Ilimitado',
                        ),
                        _buildComparisonRow(
                          'Soporte Prioritario',
                          'Básico',
                          'Premium ✨',
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 48),

                  // Subscriptions are usually handled via Purchases.purchasePackage or purchaseProduct
                  // The existing _purchase method uses _selectedProductId
                  Container(
                    width: double.infinity,
                    height: 56,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFFFACC15),
                          Color(0xFFA16207),
                        ], // Gold to Dark Gold
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ElevatedButton(
                      onPressed: _isPurchasing ? null : _purchase,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: const Color(
                          0xFF0a0a0a,
                        ), // Dark text on gold
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child:
                          _isPurchasing
                              ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Color(0xFF0a0a0a),
                                  strokeWidth: 2,
                                ),
                              )
                              : const Text(
                                'Suscribirse',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  if (_selectedProduct != null)
                    Text(
                      'Se renueva por ${_selectedProduct!.priceString} por mes. Cancela en cualquier momento.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.4),
                        fontSize: 12,
                      ),
                    ),

                  const SizedBox(height: 32),

                  // Bottom Legal Links
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 24,
                      runSpacing: 12,
                      children: [
                        _buildSmallLink(
                          'Privacidad',
                          () => _showPrivacyDialog(
                            _locService.tr('privacy_policy'),
                            _locService.tr('privacy_text'),
                          ),
                        ),
                        _buildSmallLink('Restaurar membresía', () {
                          if (!_isPurchasing) _restore();
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),

          // Close button (Last in stack, top of Z-order)
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, top: 8),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.maybePop(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComparisonRow(
    String feature,
    String freeValue,
    String premiumValue, {
    bool isHeader = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              feature,
              style: TextStyle(
                color: isHeader ? Colors.white : Colors.white.withOpacity(0.7),
                fontSize: 13,
                fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                freeValue,
                style: TextStyle(
                  color:
                      isHeader ? Colors.white : Colors.white.withOpacity(0.4),
                  fontSize: 13,
                  fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                premiumValue,
                style: TextStyle(
                  color: isHeader ? Colors.white : const Color(0xFFFACC15),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper to get selected product object safely
  StoreProduct? get _selectedProduct {
    if (_currentOffering == null || _selectedProductId == null) return null;
    try {
      return _currentOffering!.availablePackages
          .firstWhere((p) => p.storeProduct.identifier == _selectedProductId)
          .storeProduct;
    } catch (_) {
      return null;
    }
  }

  void _showPrivacyDialog(String title, String content) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF0a0a0a),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withOpacity(0.1), width: 1),
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 20,
              ),
              textAlign: TextAlign.center,
            ),
            content: SingleChildScrollView(
              child: Text(
                content,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
            actions: [
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'CERRAR',
                    style: TextStyle(
                      color: Color(0xFFFFD700),
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ],
          ),
    );
  }

  Widget _buildSmallLink(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Text(
        text,
        style: TextStyle(
          color: Colors.grey[400],
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
