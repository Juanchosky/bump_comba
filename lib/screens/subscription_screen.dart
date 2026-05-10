import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../services/premium_service.dart';
import '../services/localization_service.dart';
import '../utils/snack_bar_utils.dart';

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen>
    with TickerProviderStateMixin {
  final _premiumService = PremiumService();
  final _locService = LocalizationService();
  Offering? _currentOffering;
  bool _isLoading = true;
  String? _selectedProductId;
  bool _isPurchasing = false;

  // Animations
  late AnimationController _shimmerController;
  late AnimationController _entryController;
  late AnimationController _floatController;
  late Animation<double> _fadeIn;
  late Animation<Offset> _slideUp;

  @override
  void initState() {
    super.initState();

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat(reverse: true);

    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _fadeIn = CurvedAnimation(parent: _entryController, curve: Curves.easeOut);

    _slideUp = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _entryController, curve: Curves.easeOutCubic),
    );

    _locService.init().then((_) => setState(() {}));
    _loadOfferings();

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
  void dispose() {
    _shimmerController.dispose();
    _entryController.dispose();
    _floatController.dispose();
    super.dispose();
  }

  Future<void> _loadOfferings() async {
    setState(() => _isLoading = true);

    try {
      final offerings = await _premiumService.getOfferings();
      Offering? myOffering = offerings?.getOffering('subscriptions_BumpComba');
      myOffering ??= offerings?.current;

      setState(() {
        _currentOffering = myOffering;
        _isLoading = false;

        if (myOffering != null) {
          final packages = myOffering.availablePackages;
          if (packages.isNotEmpty) {
            _selectedProductId = packages.first.storeProduct.identifier;
          }
          for (final package in packages) {
            if (package.storeProduct.identifier ==
                PremiumService.annualProductId) {
              _selectedProductId = package.storeProduct.identifier;
              break;
            }
          }
        }
      });

      _entryController.forward();
    } catch (e) {
      setState(() => _isLoading = false);
      debugPrint('Error loading offerings: $e');
      _entryController.forward();
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
        SnackBarUtils.showAppSnackBar(
          context,
          '¡Felicidades! Ahora eres Premium 👑',
        );
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) Navigator.of(context).pop(true);
      } else if (mounted) {
        SnackBarUtils.showAppSnackBar(
          context,
          'No se pudo completar la compra',
        );
      }
    } catch (e) {
      debugPrint('Purchase error: $e');
      if (mounted) {
        String errorMessage = 'No se pudo completar la compra';
        if (e is PlatformException) {
          errorMessage = e.message ?? errorMessage;
        } else {
          errorMessage = e.toString();
        }
        SnackBarUtils.showAppSnackBar(context, 'Error: $errorMessage');
      }
    } finally {
      if (mounted) setState(() => _isPurchasing = false);
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
      if (mounted) setState(() => _isPurchasing = false);
    }
  }

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

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF030303),
        body:
            _isLoading
                ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFFFFD700)),
                )
                : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF1a1000), // Warm dark top
            Color(0xFF0a0800),
            Color(0xFF050300),
            Color(0xFF030303),
          ],
          stops: [0.0, 0.25, 0.5, 1.0],
        ),
      ),
      child: Stack(
        children: [
          // Ambient glow behind crown
          Positioned(
            top: -60,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFFFFD700).withOpacity(0.12),
                      const Color(0xFFFFD700).withOpacity(0.04),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.4, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // Main scrollable content
          SafeArea(
            child: SlideTransition(
              position: _slideUp,
              child: FadeTransition(
                opacity: _fadeIn,
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    children: [
                      const SizedBox(height: 30),

                      // ── Crown Icon ──
                      _buildCrownBadge(),

                      const SizedBox(height: 10),

                      // ── Headline ──
                      const Text(
                        'Bump Premium',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'La mejor experiencia sin límites',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.3,
                        ),
                      ),

                      const SizedBox(height: 26),

                      // ── Benefits List ──
                      _buildBenefitItem(
                        Icons.block,
                        'Sin anuncios',
                        'Disfruta sin interrupciones',
                      ),
                      _buildBenefitItem(
                        Icons.playlist_add_rounded,
                        'Listas M3U ilimitadas',
                        'Agrega todas las fuentes que quieras',
                      ),
                      _buildBenefitItem(
                        Icons.favorite_rounded,
                        'Favoritos ilimitados',
                        'Guarda todo tu contenido favorito',
                      ),
                      _buildBenefitItem(
                        Icons.picture_in_picture_alt_rounded,
                        'Modo Ventana (PiP)',
                        'Sigue viendo mientras usas otras apps',
                      ),
                      _buildBenefitItem(
                        Icons.speed_rounded,
                        'Velocidad hasta 2x',
                        'Controla la velocidad de reproducción',
                      ),
                      _buildBenefitItem(
                        Icons.history_rounded,
                        'Historial ilimitado',
                        'Nunca pierdas lo que has visto',
                      ),

                      const SizedBox(height: 28),

                      // ── Price Card ──
                      _buildPriceCard(),

                      const SizedBox(height: 20),

                      // ── CTA Button with shimmer ──
                      _buildCTAButton(),

                      const SizedBox(height: 14),

                      // ── Renewal info ──
                      if (_selectedProduct != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'Se renueva automáticamente por ${_selectedProduct!.priceString}/mes. Cancela cuando quieras desde Google Play.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.3),
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ),

                      const SizedBox(height: 24),

                      // ── Legal links ──
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 24,
                        runSpacing: 8,
                        children: [
                          _buildSmallLink(
                            'Privacidad',
                            () => _showPrivacyDialog(
                              _locService.tr('privacy_policy'),
                              _locService.tr('privacy_text'),
                            ),
                          ),
                          _buildSmallLink('Restaurar compra', () {
                            if (!_isPurchasing) _restore();
                          }),
                        ],
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Close button
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, top: 8),
                child: IconButton(
                  icon: Icon(
                    Icons.close,
                    color: Colors.white.withOpacity(0.5),
                    size: 22,
                  ),
                  onPressed: () => Navigator.maybePop(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Crown badge with animated glow
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildCrownBadge() {
    return AnimatedBuilder(
      animation: Listenable.merge([_shimmerController, _floatController]),
      builder: (context, child) {
        final glow = (sin(_shimmerController.value * 2 * pi) + 1) / 2;
        // Smooth floating: -6px to +6px using easeInOut curve
        final floatOffset =
            Curves.easeInOut.transform(_floatController.value) * 12 - 6;
        return Transform.translate(
          offset: Offset(0, floatOffset),
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(
                    0xFFFFD700,
                  ).withOpacity(0.15 + glow * 0.12),
                  blurRadius: 35 + glow * 15,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/images/logodepremium.png',
                width: 100,
                height: 100,
                fit: BoxFit.cover,
              ),
            ),
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Benefit item row
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildBenefitItem(IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFFFD700).withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFFFFD700), size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.check_circle_rounded,
            color: const Color(0xFFFFD700).withOpacity(0.7),
            size: 20,
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Price card
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildPriceCard() {
    final product = _selectedProduct;
    final priceStr = product?.priceString ?? '\$';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFFFD700).withOpacity(0.35),
          width: 1.5,
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFFFFD700).withOpacity(0.08),
            const Color(0xFFFFD700).withOpacity(0.03),
          ],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Plan Mensual',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFD700),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'POPULAR',
                        style: TextStyle(
                          color: Color(0xFF1a1000),
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Acceso completo a todas las funciones',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                priceStr,
                style: const TextStyle(
                  color: Color(0xFFFFD700),
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                '/mes',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CTA Button with animated shimmer
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildCTAButton() {
    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (context, _) {
        return Container(
          width: double.infinity,
          height: 58,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              begin: Alignment(-1.0 + _shimmerController.value * 3, 0),
              end: Alignment(0.0 + _shimmerController.value * 3, 0),
              colors: const [
                Color(0xFFB8860B),
                Color(0xFFFFD700),
                Color(0xFFFFF8DC),
                Color(0xFFFFD700),
                Color(0xFFB8860B),
              ],
              stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFD700).withOpacity(0.3),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: _isPurchasing ? null : _purchase,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              foregroundColor: const Color(0xFF1a1000),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child:
                _isPurchasing
                    ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Color(0xFF1a1000),
                        strokeWidth: 2.5,
                      ),
                    )
                    : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Comenzar ahora',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.3,
                          ),
                        ),
                        SizedBox(width: 8),
                        Icon(Icons.arrow_forward_rounded, size: 20),
                      ],
                    ),
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Legal
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildSmallLink(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Text(
        text,
        style: TextStyle(
          color: Colors.grey[500],
          fontSize: 12,
          fontWeight: FontWeight.w500,
          decoration: TextDecoration.underline,
          decorationColor: Colors.grey[600],
        ),
      ),
    );
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
}
