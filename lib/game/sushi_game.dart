import 'dart:math';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'sushi_type.dart';
import 'sushi_body.dart';
import 'effects.dart';
import '../services/game_config_service.dart';

/// Main game class for the Sushi Merge game (with custom physics)
class SushiGame extends FlameGame with TapCallbacks, DragCallbacks {
  SushiGame({
    required this.onScoreChanged,
    required this.onGameOver,
    required this.onNextSushiChanged,
    required this.onLevelChanged,
    required this.onFeverModeChanged,
    required this.onAchievementUnlocked,
    required this.onPowerUpEarned,
    this.difficulty = 2,
    this.vibrationEnabled = true,
  });

  final void Function(int score) onScoreChanged;
  final void Function(int finalScore, int level, int merges) onGameOver;
  final void Function(SushiType type) onNextSushiChanged;
  final void Function(int level, String name, int progress) onLevelChanged;
  final void Function(bool active) onFeverModeChanged;
  final void Function(String achievementId) onAchievementUnlocked;
  final void Function(PowerUpType type) onPowerUpEarned;

  final int difficulty;
  final bool vibrationEnabled;

  late double gameWidth;
  late double gameHeight;

  int _score = 0;
  int get score => _score;

  int _currentLevel = 1;
  int get currentLevel => _currentLevel;

  int _totalMerges = 0;
  int get totalMerges => _totalMerges;

  SushiBody? _currentSushi;
  SushiType _nextSushiType = SushiType.tamago;

  bool _gameOver = false;
  bool _canDrop = true;

  final Random _random = Random();

  // Combo system
  int _comboCount = 0;
  double _comboTimer = 0;
  double _comboTimeout = 1.5;

  // Fever mode
  bool _feverMode = false;
  bool get feverMode => _feverMode;
  double _feverTimer = 0;
  static const double feverDuration = 10.0;
  static const int feverComboThreshold = 5;

  // Game over check
  double _gameOverCheckTimer = 0;
  static const double gameOverCheckInterval = 0.5;
  static const double dangerLineY = 120.0;

  // Wall bounds
  static const double wallThickness = 15.0;
  static const double topMargin = 100.0;

  // Base gravity (modified by level and difficulty)
  final double _baseGravity = 800.0;
  double get currentGravity {
    final levelMultiplier =
        LevelManager.getLevelForScore(_score).gravityMultiplier;
    final difficultyMultiplier =
        difficulty == 1 ? 0.8 : (difficulty == 3 ? 1.3 : 1.0);
    return _baseGravity * levelMultiplier * difficultyMultiplier;
  }

  // Power-ups
  PowerUpType? _pendingPowerUp;
  bool _slowMoActive = false;
  double _slowMoTimer = 0;
  bool _freezeActive = false;
  double _freezeTimer = 0;
  bool _doublePointsActive = false;
  double _doublePointsTimer = 0;
  bool _hasExtraLife = false;

  // Achievement tracking
  bool _firstMergeAchieved = false;
  bool _dragonRollAchieved = false;
  final Set<String> _pendingAchievements = {};

  // Vibration throttling
  double _lastVibrationTime = 0;
  static const double minVibrationInterval = 0.1; // 100ms minimum interval

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    gameWidth = size.x;
    gameHeight = size.y;

    // Add background/walls component
    await add(GameContainer(gameWidth: gameWidth, gameHeight: gameHeight));

    // Generate first next sushi type
    _nextSushiType = _getRandomSpawnableSushi();

    // Defer callback to avoid setState during build
    Future.microtask(() {
      onNextSushiChanged(_nextSushiType);
      _updateLevelUI();
    });

    // Spawn first sushi
    _spawnCurrentSushi();
  }

  @override
  void update(double dt) {
    super.update(dt);

    if (_gameOver) return;

    // Handle slow-mo effect
    double effectiveDt = dt;
    if (_slowMoActive) {
      effectiveDt *= 0.3;
      _slowMoTimer -= dt;
      if (_slowMoTimer <= 0) {
        _slowMoActive = false;
      }
    }

    // Handle freeze effect
    if (_freezeActive) {
      _freezeTimer -= dt;
      if (_freezeTimer <= 0) {
        _freezeActive = false;
        // Unfreeze all sushi
        for (final sushi in _sushiBodies) {
          sushi.isFrozen = false;
        }
      }
    }

    // Handle double points effect
    if (_doublePointsActive) {
      _doublePointsTimer -= dt;
      if (_doublePointsTimer <= 0) {
        _doublePointsActive = false;
      }
    }

    // Update combo timer
    if (_comboCount > 0) {
      _comboTimer -= effectiveDt;
      if (_comboTimer <= 0) {
        _comboCount = 0;
        if (_feverMode) {
          _feverMode = false;
          onFeverModeChanged(false);
        }
      }
    }

    // Update fever mode
    if (_feverMode) {
      _feverTimer -= effectiveDt;
      if (_feverTimer <= 0) {
        _feverMode = false;
        onFeverModeChanged(false);
      }
    }

    // Check for collisions between sushi
    _checkCollisions();

    // Check for merges
    _checkMerges();

    // Check for game over
    _gameOverCheckTimer += effectiveDt;
    if (_gameOverCheckTimer >= gameOverCheckInterval) {
      _gameOverCheckTimer = 0;
      _checkGameOver();
    }

    // Check level-up rewards
    _checkLevelRewards();
  }

  /// Get all sushi bodies in the game
  List<SushiBody> get _sushiBodies {
    return children.whereType<SushiBody>().toList();
  }

  /// Check collisions between all sushi pairs
  void _checkCollisions() {
    final bodies =
        _sushiBodies.where((b) => b.isDropping && !b.isFrozen).toList();

    for (int i = 0; i < bodies.length; i++) {
      for (int j = i + 1; j < bodies.length; j++) {
        if (bodies[i].isCollidingWith(bodies[j])) {
          bodies[i].resolveCollision(bodies[j]);
        }
      }
    }
  }

  /// Check for sushi that should merge
  void _checkMerges() {
    final bodies =
        _sushiBodies.where((b) => b.isDropping && !b.isMarkedForMerge).toList();

    for (int i = 0; i < bodies.length; i++) {
      for (int j = i + 1; j < bodies.length; j++) {
        if (bodies[i].canMergeWith(bodies[j])) {
          handleMerge(bodies[i], bodies[j]);
          return; // Handle one merge per frame to avoid issues
        }
      }
    }
  }

  /// Get a random sushi type that can spawn
  SushiType _getRandomSpawnableSushi() {
    final level = LevelManager.getLevelForScore(_score);
    final maxType = level.maxSpawnType.clamp(1, 7);

    final types = SushiType.values.take(maxType).toList();

    // Weight towards smaller sushi
    final weights = List.generate(types.length, (i) => types.length - i);
    final totalWeight = weights.reduce((a, b) => a + b);
    var random = _random.nextInt(totalWeight);

    for (int i = 0; i < types.length; i++) {
      random -= weights[i];
      if (random < 0) {
        return types[i];
      }
    }
    return types.first;
  }

  /// Spawn the current sushi at the top
  void _spawnCurrentSushi() {
    if (_gameOver) return;

    _currentSushi = SushiBody(
      sushiType: _nextSushiType,
      position: Vector2(gameWidth / 2, 120),
      isDropping: false,
      gameGravity: currentGravity,
    );

    add(_currentSushi!);

    // Prepare next sushi
    _nextSushiType = _getRandomSpawnableSushi();
    onNextSushiChanged(_nextSushiType);

    _canDrop = true;
  }

  /// Drop the current sushi
  void _dropCurrentSushi() {
    if (_currentSushi == null || !_canDrop || _gameOver) return;

    _currentSushi!.drop();
    _currentSushi = null;
    _canDrop = false;

    // Vibrate on drop (Android)
    vibrate(HapticFeedbackType.light);

    // Wait a bit before spawning next sushi
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!_gameOver) {
        _spawnCurrentSushi();
      }
    });
  }

  /// Handle merge between two sushi
  void handleMerge(SushiBody sushi1, SushiBody sushi2) {
    if (sushi1.isMarkedForMerge || sushi2.isMarkedForMerge) return;

    sushi1.markForMerge();
    sushi2.markForMerge();

    final nextType = sushi1.sushiType.nextType;
    if (nextType == null) return;

    // Calculate merge position (midpoint)
    final mergePosition = (sushi1.position + sushi2.position) / 2;

    // Remove old sushi
    sushi1.removeFromParent();
    sushi2.removeFromParent();

    // Add merge effect
    add(
      MergeEffect(
        position: mergePosition.clone(),
        color: sushi1.sushiType.color,
        radius: sushi1.sushiType.radius,
      ),
    );

    add(
      PulseRingEffect(position: mergePosition.clone(), color: nextType.color),
    );

    // Create new sushi
    final newSushi = SushiBody(
      sushiType: nextType,
      position: mergePosition.clone(),
      isDropping: true,
      gameGravity: currentGravity,
    );
    add(newSushi);

    _totalMerges++;

    // Update combo
    _comboCount++;

    // Combo timeout increases in fever mode and with level bonus
    final levelBonus = LevelManager.getLevelForScore(_score).comboTimeBonus;
    _comboTimeout = 1.5 + levelBonus + (_feverMode ? 0.5 : 0);
    _comboTimer = _comboTimeout;

    // Check for fever mode
    if (_comboCount >= feverComboThreshold && !_feverMode) {
      _feverMode = true;
      _feverTimer = feverDuration;
      onFeverModeChanged(true);

      // Vibrate on fever mode (Android)
      vibrate(HapticFeedbackType.heavy);
    }

    // Calculate points
    final basePoints = nextType.points;
    final comboMultiplier = _comboCount;
    final feverMultiplier = _feverMode ? 2 : 1;
    final doublePointsMultiplier = _doublePointsActive ? 2 : 1;
    final points =
        basePoints * comboMultiplier * feverMultiplier * doublePointsMultiplier;

    _score += points;

    final oldLevel = _currentLevel;
    final newLevel = LevelManager.getLevelForScore(_score).level;

    if (newLevel > oldLevel) {
      _currentLevel = newLevel;
      _updateLevelUI();

      // Vibrate on level up (Android)
      vibrate(HapticFeedbackType.medium);

      // Add level up effect
      add(LevelUpEffect(position: Vector2(gameWidth / 2, gameHeight / 2)));
    }

    onScoreChanged(_score);

    // Score popup
    add(
      ScorePopup(
        position: mergePosition + Vector2(0, -30),
        score: points,
        isCombo: _comboCount > 1,
        isFever: _feverMode,
      ),
    );

    // Vibrate on merge (Android)
    vibrate(HapticFeedbackType.selection);

    // Check achievements
    _checkMergeAchievements(nextType);
  }

  void _updateLevelUI() {
    final level = LevelManager.getLevelForScore(_score);
    final progress = LevelManager.getProgressToNextLevel(_score, _currentLevel);
    onLevelChanged(_currentLevel, level.name, progress);
  }

  void _checkLevelRewards() {
    final level = LevelManager.getLevelForScore(_score);
    if (level.hasPowerUp &&
        _pendingPowerUp == null &&
        _random.nextDouble() < 0.01) {
      _pendingPowerUp =
          PowerUpType.values[_random.nextInt(PowerUpType.values.length)];
      onPowerUpEarned(_pendingPowerUp!);
    }
  }

  void _checkMergeAchievements(SushiType createdType) {
    // First merge
    if (!_firstMergeAchieved) {
      _firstMergeAchieved = true;
      _pendingAchievements.add('first_merge');
      onAchievementUnlocked('first_merge');
    }

    // Combo achievements
    if (_comboCount == 3) {
      _pendingAchievements.add('combo_3');
      onAchievementUnlocked('combo_3');
    } else if (_comboCount == 5) {
      _pendingAchievements.add('combo_5');
      onAchievementUnlocked('combo_5');
    } else if (_comboCount == 10) {
      _pendingAchievements.add('combo_10');
      onAchievementUnlocked('combo_10');
    }

    // Dragon roll achievement
    if (createdType == SushiType.dragon && !_dragonRollAchieved) {
      _dragonRollAchieved = true;
      _pendingAchievements.add('dragon_roll');
      onAchievementUnlocked('dragon_roll');
    }

    // Level achievements
    if (_currentLevel == 5) {
      _pendingAchievements.add('level_5');
      onAchievementUnlocked('level_5');
    } else if (_currentLevel == 10) {
      _pendingAchievements.add('level_10');
      onAchievementUnlocked('level_10');
    } else if (_currentLevel == 15) {
      _pendingAchievements.add('level_15');
      onAchievementUnlocked('level_15');
    } else if (_currentLevel == 20) {
      _pendingAchievements.add('level_20');
      onAchievementUnlocked('level_20');
    }

    // Score achievements
    if (_score >= 1000 && !_pendingAchievements.contains('score_1000')) {
      _pendingAchievements.add('score_1000');
      onAchievementUnlocked('score_1000');
    }
    if (_score >= 5000 && !_pendingAchievements.contains('score_5000')) {
      _pendingAchievements.add('score_5000');
      onAchievementUnlocked('score_5000');
    }
  }

  /// Activate a power-up
  void activatePowerUp(PowerUpType type) {
    switch (type) {
      case PowerUpType.bomb:
        _activateBomb();
        break;
      case PowerUpType.slowMo:
        _slowMoActive = true;
        _slowMoTimer = 5.0;
        break;
      case PowerUpType.shuffle:
        _shuffleSushi();
        break;
      case PowerUpType.magnet:
        _activateMagnet();
        break;
      case PowerUpType.freeze:
        _freezeActive = true;
        _freezeTimer = 3.0;
        for (final sushi in _sushiBodies.where((s) => s.isDropping)) {
          sushi.isFrozen = true;
        }
        break;
      case PowerUpType.doublePoints:
        _doublePointsActive = true;
        _doublePointsTimer = 10.0;
        break;
      case PowerUpType.extraLife:
        _hasExtraLife = true;
        break;
    }
    _pendingPowerUp = null;

    if (vibrationEnabled) {
      vibrate(HapticFeedbackType.heavy);
    }
  }

  void _activateBomb() {
    final bodies = _sushiBodies.where((b) => b.isDropping).toList();
    if (bodies.isEmpty) return;

    bodies.shuffle();
    final toRemove = bodies.take(3).toList();
    for (final sushi in toRemove) {
      add(
        MergeEffect(
          position: sushi.position.clone(),
          color: Colors.orange,
          radius: sushi.sushiType.radius,
        ),
      );
      sushi.removeFromParent();
    }
  }

  void _shuffleSushi() {
    final bodies = _sushiBodies.where((b) => b.isDropping).toList();
    for (final sushi in bodies) {
      sushi.position.x = _random.nextDouble() * (gameWidth - 100) + 50;
      sushi.velocity = Vector2.zero();
    }
  }

  void _activateMagnet() {
    // Group sushi by type and attract them
    final bodies = _sushiBodies.where((b) => b.isDropping).toList();
    final groups = <SushiType, List<SushiBody>>{};

    for (final body in bodies) {
      groups.putIfAbsent(body.sushiType, () => []).add(body);
    }

    for (final group in groups.values) {
      if (group.length >= 2) {
        final centerX =
            group.map((b) => b.position.x).reduce((a, b) => a + b) /
            group.length;
        for (final body in group) {
          body.velocity.x += (centerX - body.position.x) * 2;
        }
      }
    }
  }

  /// Check if game is over (sushi above danger line while at rest)
  void _checkGameOver() {
    for (final sushi in _sushiBodies) {
      if (sushi.isDropping && sushi.isAtRest && !sushi.isFrozen) {
        final topY = sushi.position.y - sushi.sushiType.radius;
        if (topY < dangerLineY) {
          _triggerGameOver();
          return;
        }
      }
    }
  }

  void _triggerGameOver() {
    // Check for extra life
    if (_hasExtraLife) {
      _hasExtraLife = false;
      // Remove sushi that crossed the line
      for (final sushi in _sushiBodies.toList()) {
        final topY = sushi.position.y - sushi.sushiType.radius;
        if (topY < dangerLineY) {
          sushi.removeFromParent();
        }
      }
      vibrate(HapticFeedbackType.medium);
      return; // Don't trigger game over
    }

    _gameOver = true;

    vibrate(HapticFeedbackType.vibrate);

    onGameOver(_score, _currentLevel, _totalMerges);
  }

  @override
  void onTapUp(TapUpEvent event) {
    _dropCurrentSushi();
  }

  /// Centralized vibration method with throttling
  void vibrate(HapticFeedbackType type) {
    if (!vibrationEnabled) return;

    final currentTime = currentTimeBySession;
    if (currentTime - _lastVibrationTime < minVibrationInterval) return;

    _lastVibrationTime = currentTime;

    switch (type) {
      case HapticFeedbackType.light:
        HapticFeedback.lightImpact();
        break;
      case HapticFeedbackType.medium:
        HapticFeedback.mediumImpact();
        break;
      case HapticFeedbackType.heavy:
        HapticFeedback.heavyImpact();
        break;
      case HapticFeedbackType.selection:
        HapticFeedback.selectionClick();
        break;
      case HapticFeedbackType.vibrate:
        HapticFeedback.vibrate();
        break;
    }
  }

  double get currentTimeBySession =>
      DateTime.now().millisecondsSinceEpoch / 1000.0;

  @override
  void onDragUpdate(DragUpdateEvent event) {
    if (_currentSushi != null && _canDrop) {
      final newX = _currentSushi!.position.x + event.localDelta.x;
      _currentSushi!.moveToX(newX);
    }
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    _dropCurrentSushi();
  }

  /// Restart the game
  void restart() {
    // Remove all sushi and effects
    children.whereType<SushiBody>().toList().forEach(
      (s) => s.removeFromParent(),
    );
    children.whereType<MergeEffect>().toList().forEach(
      (e) => e.removeFromParent(),
    );
    children.whereType<ScorePopup>().toList().forEach(
      (e) => e.removeFromParent(),
    );
    children.whereType<PulseRingEffect>().toList().forEach(
      (e) => e.removeFromParent(),
    );
    children.whereType<LevelUpEffect>().toList().forEach(
      (e) => e.removeFromParent(),
    );

    // Reset state
    _score = 0;
    _currentLevel = 1;
    _totalMerges = 0;
    _gameOver = false;
    _comboCount = 0;
    _comboTimer = 0;
    _feverMode = false;
    _feverTimer = 0;
    _currentSushi = null;
    _pendingPowerUp = null;
    _slowMoActive = false;
    _freezeActive = false;
    _pendingAchievements.clear();

    onScoreChanged(0);
    onFeverModeChanged(false);
    _updateLevelUI();

    // Spawn new sushi
    _nextSushiType = _getRandomSpawnableSushi();
    onNextSushiChanged(_nextSushiType);
    _spawnCurrentSushi();
  }
}

/// Background container that renders walls and danger line
class GameContainer extends PositionComponent {
  GameContainer({required this.gameWidth, required this.gameHeight});

  final double gameWidth;
  final double gameHeight;

  @override
  void render(Canvas canvas) {
    // Draw container background
    final containerRect = Rect.fromLTWH(
      10,
      100,
      gameWidth - 20,
      gameHeight - 110,
    );

    // Semi-transparent background
    final bgPaint = Paint()..color = Colors.black.withValues(alpha: 0.3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(containerRect, const Radius.circular(16)),
      bgPaint,
    );

    // Border
    final borderPaint =
        Paint()
          ..color = Colors.white.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3;
    canvas.drawRRect(
      RRect.fromRectAndRadius(containerRect, const Radius.circular(16)),
      borderPaint,
    );

    // Game over line (danger zone)
    final linePaint =
        Paint()
          ..color = Colors.red.withValues(alpha: 0.6)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;

    const dashWidth = 10.0;
    const dashSpace = 5.0;
    double startX = 15;
    const y = 120.0;

    while (startX < gameWidth - 15) {
      canvas.drawLine(
        Offset(startX, y),
        Offset(startX + dashWidth, y),
        linePaint,
      );
      startX += dashWidth + dashSpace;
    }
  }
}

enum HapticFeedbackType { light, medium, heavy, selection, vibrate }
