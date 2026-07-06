import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'main_menu_screen.dart';
import '../services/score_service.dart';
import 'package:flutter/foundation.dart';
import '../services/premium_service.dart';
import '../utils/transitions.dart';
import 'stream_browser_screen.dart';
import '../services/social_rewards_service.dart';
import '../services/game_config_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  final ScoreService _scoreService = ScoreService();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutExpo),
    );

    // Fade animation — start opaque to match native splash
    _fadeAnimation = const AlwaysStoppedAnimation(1.0);

    _controller.forward();

    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Start minimum timer — reduced for faster transition
    final minDelay = Future.delayed(const Duration(milliseconds: 400));

    // Defer service initialization slightly to let the first frame render
    try {
      final rewardsService = SocialRewardsService();
      // Initialize critical services for navigation
      await Future.wait([
        PremiumService().initialize().timeout(const Duration(seconds: 3)),
        GameConfigService().init().timeout(const Duration(seconds: 3)),
        _scoreService.init().timeout(const Duration(seconds: 3)),
      ]).catchError((e) {
        debugPrint('Error initializing critical services: $e');
        return [];
      });

      // Non-critical background init
      unawaited(
        rewardsService
            .init()
            .then((_) => rewardsService.incrementLaunchCount())
            .catchError((e) => debugPrint('Rewards init error: $e')),
      );

      await minDelay;
      if (mounted) _navigateToNext();
    } catch (e) {
      debugPrint('Bootstrap error: $e');
      if (mounted) _navigateToNext();
    }
  }

  void _navigateToNext() {
    final config = GameConfigService();
    final isBrowserUnlocked =
        config.difficulty == 3 && !config.vibrationEnabled;

    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux ||
        (config.skipGameIntro && isBrowserUnlocked)) {
      Navigator.of(
        context,
      ).pushReplacement(FadeScalePageRoute(page: const StreamBrowserScreen()));
    } else {
      Navigator.of(context).pushReplacement(
        FadeScalePageRoute(
          page: MainMenuScreen(highScore: _scoreService.highScore),
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Background Image (Optional, matching theme)
          Positioned.fill(
            child: Opacity(
              opacity: 0.3,
              child: Image.asset(
                'assets/images/background.jpg',
                fit: BoxFit.cover,
              ),
            ),
          ),

          // Gradient Overlay
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.6),
                    Colors.black.withValues(alpha: 0.9),
                  ],
                ),
              ),
            ),
          ),

          // Central App Logo & Title
          Center(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // App Icon / Logo
                    Container(
                      height: 160,
                      width: 160,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFF6B6B).withValues(alpha: 0.5),
                            blurRadius: 30,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/logo.png',
                          fit: BoxFit.contain,
                          errorBuilder:
                              (_, _, _) => const Icon(
                                Icons.play_circle_filled,
                                color: Color(0xFFFF6B6B),
                                size: 100,
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 50),
                    const CupertinoActivityIndicator(
                      radius: 12,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // "By Juan" at the bottom
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'By Juan',
                style: TextStyle(
                  fontSize: 18,

                  color: const Color.fromARGB(223, 255, 149, 11),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
