import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../game/sushi_game.dart';
import '../game/sushi_type.dart';
import '../services/score_service.dart';
import '../services/game_config_service.dart';
import '../services/localization_service.dart';
import '../utils/colors.dart';
import 'main_menu_screen.dart';
import '../utils/transitions.dart';
import '../utils/snack_bar_utils.dart';

import '../services/ad_service.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with TickerProviderStateMixin {
  SushiGame? _game;
  int _score = 0;
  SushiType _nextSushi = SushiType.tamago;
  bool _isGameOver = false;
  bool _isNewHighScore = false;
  int _finalScore = 0;
  int _finalLevel = 1;
  int _finalMerges = 0;
  int _coinsEarned = 0;
  bool _isInitialized = false;

  // Level system
  int _currentLevel = 1;
  String _levelName = 'Aprendiz';
  int _levelProgress = 0;

  // Fever mode
  bool _feverMode = false;

  // Power-ups
  PowerUpType? _pendingPowerUp;

  // Achievements
  String? _lastAchievement;

  // Animation
  late AnimationController _feverController;
  DateTime? _lastBackPressed;

  final ScoreService _scoreService = ScoreService();
  final GameConfigService _configService = GameConfigService();
  final LocalizationService _locService = LocalizationService();

  @override
  void initState() {
    super.initState();
    _feverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
    _loadAndInitGame();
  }

  @override
  void dispose() {
    _feverController.dispose();
    super.dispose();
  }

  Future<void> _loadAndInitGame() async {
    await _scoreService.init();
    await _configService.init();
    await _locService.init();
    await _configService.incrementGames();
    _initGame();
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(fn);
      }
    });
  }

  void _initGame() {
    _game = SushiGame(
      difficulty: _configService.difficulty,
      vibrationEnabled: _configService.vibrationEnabled,
      onScoreChanged: (score) {
        _safeSetState(() {
          _score = score;
        });
      },
      onGameOver: (finalScore, level, merges) async {
        AdService().showInterstitialAd();
        await _configService.addMerges(merges);
        await _configService.updateMaxLevel(level);
        await _configService.updateMaxScore(finalScore);
        final isNewHighScore = await _scoreService.checkAndSaveHighScore(
          finalScore,
        );

        // Calculate coins earned
        final levelBonus = LevelManager.getLevelForScore(finalScore).coinBonus;
        final baseCoins = (finalScore / 100).floor();
        final mergeCoins = (merges / 5).floor();
        final levelBonusCoins = level * levelBonus;
        final newHighScoreBonus = isNewHighScore ? 50 : 0;

        final totalCoins =
            ((baseCoins + mergeCoins + levelBonusCoins + newHighScoreBonus) *
                    _configService.coinMultiplier)
                .toInt();

        await _configService.addCoins(totalCoins);

        _safeSetState(() {
          _isGameOver = true;
          _finalScore = finalScore;
          _finalLevel = level;
          _finalMerges = merges;
          _coinsEarned = totalCoins;
          _isNewHighScore = isNewHighScore;
        });
      },
      onNextSushiChanged: (type) {
        _safeSetState(() {
          _nextSushi = type;
        });
      },
      onLevelChanged: (level, name, progress) {
        _safeSetState(() {
          _currentLevel = level;
          _levelName = name;
          _levelProgress = progress;
        });
      },
      onFeverModeChanged: (active) {
        _safeSetState(() {
          _feverMode = active;
        });
      },
      onAchievementUnlocked: (achievementId) async {
        final isNew = await _configService.unlockAchievement(achievementId);
        if (isNew) {
          final achievement = AchievementManager.getById(achievementId);
          if (achievement != null) {
            _safeSetState(() {
              _lastAchievement = achievement.name;
            });
            // Auto-hide after 3 seconds
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) {
                setState(() {
                  _lastAchievement = null;
                });
              }
            });
          }
        }
      },
      onPowerUpEarned: (type) {
        _safeSetState(() {
          _pendingPowerUp = type;
        });
      },
    );

    setState(() {
      _isInitialized = true;
    });
  }

  void _restartGame() {
    setState(() {
      _isGameOver = false;
      _score = 0;
      _currentLevel = 1;
      _levelProgress = 0;
      _feverMode = false;
      _pendingPowerUp = null;
    });
    _configService.incrementGames();
    _game?.restart();
  }

  void _handleBackAction() {
    final now = DateTime.now();
    final backButtonHasNotBeenPressedOrSnackBarHasExpired =
        _lastBackPressed == null ||
        now.difference(_lastBackPressed!) > const Duration(seconds: 2);

    if (backButtonHasNotBeenPressedOrSnackBarHasExpired) {
      _lastBackPressed = now;
      SnackBarUtils.showAppSnackBar(
        context,
        _locService.tr('Presiona de nuevo para salir al menú'),
      );
    } else {
      _goToMenu();
    }
  }

  void _goToMenu() {
    Navigator.of(context).pushReplacement(
      FadeScalePageRoute(
        page: MainMenuScreen(highScore: _scoreService.highScore),
      ),
    );
  }

  void _usePowerUp() {
    if (_pendingPowerUp != null && _game != null) {
      _game!.activatePowerUp(_pendingPowerUp!);
      setState(() {
        _pendingPowerUp = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackAction();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              color: AppColors.background,
              border:
                  _feverMode
                      ? Border.all(
                        color: Color.lerp(
                          Colors.orange,
                          Colors.red,
                          _feverController.value,
                        )!.withValues(alpha: 0.3),
                        width: 2,
                      )
                      : null,
            ),
            child: SafeArea(
              child:
                  _isInitialized && _game != null
                      ? Stack(
                        children: [
                          // Game
                          GameWidget(game: _game!),

                          // Fever mode border animation
                          if (_feverMode) _buildFeverBorder(),

                          // Top HUD
                          _buildTopHUD(),

                          // Level progress bar
                          _buildLevelBar(),

                          // Power-up button
                          if (_pendingPowerUp != null) _buildPowerUpButton(),

                          // Achievement notification
                          if (_lastAchievement != null)
                            if (_lastAchievement != null)
                              _buildAchievementNotification(),

                          // Game Over overlay
                          if (_isGameOver) _buildGameOverOverlay(),
                        ],
                      )
                      : const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeverBorder() {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _feverController,
        builder: (context, child) {
          return Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: Color.lerp(
                  Colors.orange,
                  Colors.red,
                  _feverController.value,
                )!.withValues(alpha: 0.6),
                width: 4,
              ),
              borderRadius: BorderRadius.circular(0),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopHUD() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFFFF1B8D).withValues(alpha: 0.4),
              Colors.transparent,
            ],
          ),
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.3), width: 3),
          ),
        ),
        child: Row(
          children: [
            // Back button
            IconButton(
              onPressed: _handleBackAction,
              icon: const Icon(
                Icons.arrow_back_ios,
                color: Colors.white,
                size: 20,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),

            const SizedBox(width: 8),

            // Level badge (Chunky Blue)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red, // UI Red
                borderRadius: BorderRadius.circular(12),
                border: const Border(
                  bottom: BorderSide(color: Color(0xFFB20000), width: 4),
                ),
              ),
              child: Text(
                'LV.$_currentLevel',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),

            const SizedBox(width: 8),

            // Score (Chunky White)
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE5E5E5), width: 2),
                  boxShadow: const [
                    BoxShadow(color: Color(0xFFE5E5E5), offset: Offset(0, 4)),
                  ],
                ),
                child: Center(
                  child: Text(
                    '$_score',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF4B4B4B),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(width: 8),

            // Next sushi indicator
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Text(
                    _locService.tr('next'),
                    style: TextStyle(
                      fontSize: 8,
                      color: Colors.white.withValues(alpha: 0.6),
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _nextSushi.color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.5),
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        _nextSushi.emoji,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLevelBar() {
    return Positioned(
      top: 52,
      left: 16,
      right: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _levelName,
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '$_levelProgress%',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            height: 16,
            decoration: BoxDecoration(
              color: const Color(0xFFE5E5E5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Stack(
              children: [
                FractionallySizedBox(
                  widthFactor: (_levelProgress / 100).clamp(0.02, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF58CC02),
                      borderRadius: BorderRadius.circular(10),
                      border: const Border(
                        bottom: BorderSide(color: Color(0xFF46A302), width: 4),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPowerUpButton() {
    return Positioned(
      bottom: 100,
      right: 16,
      child: GestureDetector(
        onTap: _usePowerUp,
        child: AnimatedScale(
          scale: _isInitialized ? 1.0 : 0.9,
          duration: const Duration(milliseconds: 100),
          child: Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              gradient: const RadialGradient(
                colors: [Color(0xFF1BFFFF), Color(0xFF1899D6)],
                center: Alignment(-0.2, -0.2),
                radius: 0.8,
              ),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1899D6).withValues(alpha: 0.5),
                  blurRadius: 10,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _pendingPowerUp!.emoji,
                  style: const TextStyle(fontSize: 28),
                ),
                Text(
                  _locService.tr('use').toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    shadows: [Shadow(color: Colors.black26, blurRadius: 2)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAchievementNotification() {
    return Positioned(
      top: 100,
      left: 20,
      right: 20,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF1B8D), Color(0xFF8B1BFF)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
          ),
          child: Row(
            children: [
              const Text('🏆', style: TextStyle(fontSize: 28)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _locService.tr('achievement_unlocked'),
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.black54,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _lastAchievement!,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.black87,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGameOverOverlay() {
    return Container(
      color: const Color(0xFF0a0a0a).withValues(alpha: 0.8),
      child: Center(
        child: SingleChildScrollView(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 30),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            decoration: BoxDecoration(
              color: const Color(0xFF2d3436),
              borderRadius: BorderRadius.circular(40),
              border: Border.all(color: const Color(0xFF0a0a0a), width: 3),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0a0a0a).withValues(alpha: 0.8),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
                const BoxShadow(
                  color: Color(0xFF0a0a0a),
                  blurRadius: 0,
                  spreadRadius: -10,
                  offset: Offset(0, -10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header (Chunky Blue)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red, // UI Red
                    borderRadius: BorderRadius.circular(16),
                    border: const Border(
                      bottom: BorderSide(color: Color(0xFF0a0a0a), width: 4),
                    ),
                  ),
                  child: Text(
                    _isNewHighScore
                        ? 'NEW RECORD!'
                        : _locService.tr('game_over').toUpperCase(),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                // Stats grid with better contrast
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0a0a0a).withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Column(
                    children: [
                      _StatRowWidget(
                        icon: '🎯',
                        label: _locService.tr('score'),
                        value: '$_finalScore',
                        isHighlight: true,
                        highlightColor: Colors.red,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Divider(
                          color: Colors.white.withValues(alpha: 0.1),
                          height: 1,
                        ),
                      ),
                      _StatRowWidget(
                        icon: '📈',
                        label: _locService.tr('level_reached'),
                        value: '$_finalLevel',
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Divider(
                          color: Colors.white.withValues(alpha: 0.1),
                          height: 1,
                        ),
                      ),
                      _StatRowWidget(
                        icon: '🔄',
                        label: _locService.tr('merges'),
                        value: '$_finalMerges',
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Divider(
                          color: Colors.white.withValues(alpha: 0.1),
                          height: 1,
                        ),
                      ),
                      _StatRowWidget(
                        icon: '🪙',
                        label: _locService.tr('coins_won'),
                        value: '+$_coinsEarned',
                        isHighlight: true,
                        highlightColor: const Color(0xFF58CC02),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: _GameOverButton(
                        onPressed: _goToMenu,
                        icon: Icons.home_rounded,
                        label: _locService.tr('menu'),
                        isPrimary: false,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _GameOverButton(
                        onPressed: _restartGame,
                        icon: Icons.refresh_rounded,
                        label: _locService.tr('restart'),
                        isPrimary: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatRowWidget extends StatelessWidget {
  const _StatRowWidget({
    required this.icon,
    required this.label,
    required this.value,
    this.isHighlight = false,
    this.highlightColor,
  });

  final String icon;
  final String label;
  final String value;
  final bool isHighlight;
  final Color? highlightColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 14,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color:
                  isHighlight
                      ? (highlightColor ?? const Color(0xFFFFD700))
                      : Colors.white,
              fontSize: isHighlight ? 22 : 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _GameOverButton extends StatelessWidget {
  const _GameOverButton({
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.isPrimary,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: isPrimary ? const Color(0xFF58CC02) : const Color(0xFF2d3436),
          borderRadius: BorderRadius.circular(25),
          border: Border.all(
            color: isPrimary ? Colors.transparent : const Color(0xFF0a0a0a),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color:
                  isPrimary
                      ? const Color(0xFF46A302)
                      : const Color(0xFF0a0a0a), // Dark green shade or black
              blurRadius: 0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
