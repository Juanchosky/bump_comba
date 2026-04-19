import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/game_config_service.dart';
import '../services/localization_service.dart';
import 'game_screen.dart';
import '../utils/colors.dart';
import 'settings_screen.dart';
import '../utils/transitions.dart';
import '../utils/snack_bar_utils.dart';
import '../services/social_rewards_service.dart';
import '../widgets/rate_dialog.dart';

class MainMenuScreen extends StatefulWidget {
  const MainMenuScreen({super.key, required this.highScore});

  final int highScore;

  @override
  State<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends State<MainMenuScreen>
    with TickerProviderStateMixin {
  final GameConfigService _configService = GameConfigService();
  final LocalizationService _locService = LocalizationService();
  late AnimationController _shineController;
  late AnimationController _logoController;
  late Animation<double> _logoAnimation;
  DateTime? _lastPressedAt;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _checkRateDialog();
    _shineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(period: const Duration(seconds: 3));

    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _logoAnimation = CurvedAnimation(
      parent: _logoController,
      curve: Curves.elasticOut,
    );

    _logoController.forward();
  }

  @override
  void dispose() {
    _shineController.dispose();
    _logoController.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    await _configService.init();
    await _locService.init();
  }

  void _checkRateDialog() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (SocialRewardsService().shouldShowRateDialog()) {
        showDialog(context: context, builder: (context) => const RateDialog());
      }
    });
  }

  void _startGame() {
    Navigator.pushReplacement(
      context,
      FadeScalePageRoute(page: const GameScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        final now = DateTime.now();
        final backButtonHasNotBeenPressedOrSnackBarHasExpired =
            _lastPressedAt == null ||
            now.difference(_lastPressedAt!) > const Duration(seconds: 2);

        if (backButtonHasNotBeenPressedOrSnackBarHasExpired) {
          _lastPressedAt = now;
          SnackBarUtils.showAppSnackBar(
            context,
            _locService.tr('Presiona de nuevo para salir'),
          );
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Container(
          decoration: BoxDecoration(
            image: const DecorationImage(
              image: AssetImage('assets/images/background.jpg'),
              fit: BoxFit.cover,
            ),
            color: const Color(0xFF0a0a0a).withOpacity(0.1),
            backgroundBlendMode: BlendMode.darken,
          ),
          child: SafeArea(
            child: Stack(
              children: [
                // Settings button
                Positioned(
                  top: 16,
                  right: 16,
                  child: IconButton(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        FadeScalePageRoute(page: const SettingsScreen()),
                      );
                      _loadStats();
                    },
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                        ),
                      ),
                      child: const Icon(
                        Icons.settings,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ),

                // Main content
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          height: 20,
                        ), // Reduced from 40 to move logo higher
                        // Logo Image replacing text title
                        ScaleTransition(
                          scale: _logoAnimation,
                          child: Image.asset(
                            'assets/images/logo.png',
                            width:
                                MediaQuery.of(context).size.width *
                                0.85, // Reduced from 0.95
                            fit: BoxFit.contain,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _locService.tr('combine_sushi'),
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withOpacity(0.7),
                            letterSpacing: 2,
                          ),
                        ),

                        const SizedBox(height: 100),

                        // Premium 3D Play Button with Reflection & Scale Animation
                        StatefulBuilder(
                          builder: (context, setState) {
                            bool isPressed = false;
                            return GestureDetector(
                              onTapDown:
                                  (_) => setState(() => isPressed = true),
                              onTapUp: (_) => setState(() => isPressed = false),
                              onTapCancel:
                                  () => setState(() => isPressed = false),
                              onTap: _startGame,
                              child: AnimatedScale(
                                // ignore: dead_code
                                scale: isPressed ? 0.95 : 1.0,
                                duration: const Duration(milliseconds: 100),
                                child: Container(
                                  width: 240,
                                  height: 75,
                                  clipBehavior: Clip.hardEdge,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xFFFFD700), // Gold/Yellow
                                        Color(0xFFFF9600), // Logo Orange
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                    boxShadow: [
                                      // Outer Glow
                                      BoxShadow(
                                        color: const Color(
                                          0xFFFF9600,
                                        ).withOpacity(0.5),
                                        blurRadius: 20,
                                        spreadRadius: 2,
                                        offset: const Offset(0, 4),
                                      ),
                                      // 3D Bottom Edge
                                      const BoxShadow(
                                        color: Color(0xFFCC7900),
                                        offset: Offset(0, 6),
                                      ),
                                    ],
                                  ),
                                  child: Stack(
                                    children: [
                                      // Glossy reflection on top half
                                      Positioned(
                                        top: 0,
                                        left: 0,
                                        right: 0,
                                        height: 35,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                Colors.white.withOpacity(0.3),
                                                Colors.white.withOpacity(0.0),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      // Shine Effect Animation
                                      AnimatedBuilder(
                                        animation: _shineController,
                                        builder: (context, child) {
                                          return Positioned(
                                            left:
                                                -300 +
                                                (600 * _shineController.value),
                                            top: 0,
                                            bottom: 0,
                                            width: 120,
                                            child: Transform(
                                              transform: Matrix4.skewX(-0.5),
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  gradient: LinearGradient(
                                                    colors: [
                                                      Colors.white.withOpacity(
                                                        0.0,
                                                      ),
                                                      Colors.white.withOpacity(
                                                        0.4,
                                                      ),
                                                      Colors.white.withOpacity(
                                                        0.0,
                                                      ),
                                                    ],
                                                    stops: const [
                                                      0.0,
                                                      0.5,
                                                      1.0,
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                      // Button Text
                                      Center(
                                        child: Text(
                                          _locService.tr('play').toUpperCase(),
                                          style: const TextStyle(
                                            fontSize: 32,
                                            fontWeight: FontWeight.w900,
                                            color: Colors.white,
                                            letterSpacing: 3,
                                            shadows: [
                                              Shadow(
                                                color: Colors.black26,
                                                offset: Offset(0, 2),
                                                blurRadius: 4,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
