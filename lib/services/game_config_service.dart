import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing game configuration, settings, coins, and progression
class GameConfigService {
  static const String _vibrationKey = 'vibration_enabled';
  static const String _difficultyKey = 'difficulty';
  static const String _totalGamesKey = 'total_games';
  static const String _totalMergesKey = 'total_merges';
  static const String _maxLevelReachedKey = 'max_level_reached';
  static const String _maxScoreKey = 'max_score';
  static const String _achievementsKey = 'achievements';
  static const String _coinsKey = 'coins';
  static const String _totalCoinsEarnedKey = 'total_coins_earned';
  static const String _skinUnlockedKey = 'skins_unlocked';
  static const String _dailyStreakKey = 'daily_streak';
  static const String _lastPlayDateKey = 'last_play_date';
  static const String _dailyChallengeCompletedKey = 'daily_challenge_completed';
  static const String _prestigeLevelKey = 'prestige_level';
  static const String _firstInstallDateKey = 'first_install_date';
  static const String _showExternalLinkWarningKey =
      'show_external_link_warning';
  static const String _skipGameIntroKey = 'skip_game_intro';
  static const String _volumeNormalizeKey = 'volume_normalize';

  static final GameConfigService _instance = GameConfigService._internal();
  factory GameConfigService() => _instance;
  GameConfigService._internal();

  SharedPreferences? _prefs;

  // Settings
  bool _vibrationEnabled = true;
  int _difficulty = 2; // 1=Easy, 2=Normal, 3=Hard

  // Stats
  int _totalGames = 0;
  int _totalMerges = 0;
  int _maxLevelReached = 0;
  int _maxScore = 0;
  List<String> _unlockedAchievements = [];

  // Currency & progression
  int _coins = 0;
  int _totalCoinsEarned = 0;
  List<String> _unlockedSkins = ['default'];
  int _dailyStreak = 0;
  String _lastPlayDate = '';
  bool _dailyChallengeCompleted = false;
  int _prestigeLevel = 0;
  DateTime? _firstInstallDate;
  bool _showExternalLinkWarning = true;
  bool _skipGameIntro = true;
  bool _volumeNormalize = true;

  // Getters
  bool get vibrationEnabled => _vibrationEnabled;
  int get difficulty => _difficulty;
  int get totalGames => _totalGames;
  int get totalMerges => _totalMerges;
  int get maxLevelReached => _maxLevelReached;
  int get maxScore => _maxScore;
  List<String> get unlockedAchievements => _unlockedAchievements;
  int get coins => _coins;
  int get totalCoinsEarned => _totalCoinsEarned;
  List<String> get unlockedSkins => _unlockedSkins;
  int get dailyStreak => _dailyStreak;
  bool get dailyChallengeCompleted => _dailyChallengeCompleted;
  int get prestigeLevel => _prestigeLevel;
  DateTime get firstInstallDate => _firstInstallDate ?? DateTime.now();
  bool get showExternalLinkWarning => _showExternalLinkWarning;
  bool get skipGameIntro => _skipGameIntro;
  bool get volumeNormalize => _volumeNormalize;

  /// Initialize the service
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _vibrationEnabled = _prefs?.getBool(_vibrationKey) ?? true;
    _difficulty = _prefs?.getInt(_difficultyKey) ?? 2;
    _totalGames = _prefs?.getInt(_totalGamesKey) ?? 0;
    _totalMerges = _prefs?.getInt(_totalMergesKey) ?? 0;
    _maxLevelReached = _prefs?.getInt(_maxLevelReachedKey) ?? 0;
    _maxScore = _prefs?.getInt(_maxScoreKey) ?? 0;
    _unlockedAchievements = _prefs?.getStringList(_achievementsKey) ?? [];
    _coins = _prefs?.getInt(_coinsKey) ?? 0;
    _totalCoinsEarned = _prefs?.getInt(_totalCoinsEarnedKey) ?? 0;
    _unlockedSkins = _prefs?.getStringList(_skinUnlockedKey) ?? ['default'];
    _dailyStreak = _prefs?.getInt(_dailyStreakKey) ?? 0;
    _lastPlayDate = _prefs?.getString(_lastPlayDateKey) ?? '';
    _dailyChallengeCompleted =
        _prefs?.getBool(_dailyChallengeCompletedKey) ?? false;
    _prestigeLevel = _prefs?.getInt(_prestigeLevelKey) ?? 0;
    _showExternalLinkWarning =
        _prefs?.getBool(_showExternalLinkWarningKey) ?? true;
    _skipGameIntro = _prefs?.getBool(_skipGameIntroKey) ?? true;
    _volumeNormalize = _prefs?.getBool(_volumeNormalizeKey) ?? true;

    // Load or set first install date
    final installDateStr = _prefs?.getString(_firstInstallDateKey);
    if (installDateStr != null) {
      _firstInstallDate = DateTime.tryParse(installDateStr);
    } else {
      _firstInstallDate = DateTime.now();
      await _prefs?.setString(
        _firstInstallDateKey,
        _firstInstallDate!.toIso8601String(),
      );
    }

    // Check daily streak
    _updateDailyStreak();
  }

  void _updateDailyStreak() {
    final today = DateTime.now().toIso8601String().split('T')[0];
    final yesterday =
        DateTime.now()
            .subtract(const Duration(days: 1))
            .toIso8601String()
            .split('T')[0];

    if (_lastPlayDate == yesterday) {
      // Consecutive day
      _dailyStreak++;
    } else if (_lastPlayDate != today) {
      // Streak broken
      _dailyStreak = 1;
    }

    if (_lastPlayDate != today) {
      _dailyChallengeCompleted = false;
      _prefs?.setBool(_dailyChallengeCompletedKey, false);
    }

    _lastPlayDate = today;
    _prefs?.setString(_lastPlayDateKey, today);
    _prefs?.setInt(_dailyStreakKey, _dailyStreak);
  }

  /// Set vibration enabled
  Future<void> setVibration(bool enabled) async {
    _vibrationEnabled = enabled;
    await _prefs?.setBool(_vibrationKey, enabled);
  }

  /// Set difficulty (1=Easy, 2=Normal, 3=Hard)
  Future<void> setDifficulty(int difficulty) async {
    _difficulty = difficulty.clamp(1, 3);
    await _prefs?.setInt(_difficultyKey, _difficulty);
  }

  /// Set external link warning visibility
  Future<void> setShowExternalLinkWarning(bool show) async {
    _showExternalLinkWarning = show;
    await _prefs?.setBool(_showExternalLinkWarningKey, show);
  }

  /// Set skip game intro
  Future<void> setSkipGameIntro(bool skip) async {
    _skipGameIntro = skip;
    await _prefs?.setBool(_skipGameIntroKey, skip);
  }

  /// Set volume normalization
  Future<void> setVolumeNormalize(bool enabled) async {
    _volumeNormalize = enabled;
    await _prefs?.setBool(_volumeNormalizeKey, enabled);
  }

  /// Increment total games played
  Future<void> incrementGames() async {
    _totalGames++;
    await _prefs?.setInt(_totalGamesKey, _totalGames);
  }

  /// Add merges to total
  Future<void> addMerges(int count) async {
    _totalMerges += count;
    await _prefs?.setInt(_totalMergesKey, _totalMerges);
  }

  /// Update max level reached
  Future<void> updateMaxLevel(int level) async {
    if (level > _maxLevelReached) {
      _maxLevelReached = level;
      await _prefs?.setInt(_maxLevelReachedKey, level);
    }
  }

  /// Update max score
  Future<void> updateMaxScore(int score) async {
    if (score > _maxScore) {
      _maxScore = score;
      await _prefs?.setInt(_maxScoreKey, score);
    }
  }

  /// Add coins
  Future<void> addCoins(int amount) async {
    _coins += amount;
    _totalCoinsEarned += amount;
    await _prefs?.setInt(_coinsKey, _coins);
    await _prefs?.setInt(_totalCoinsEarnedKey, _totalCoinsEarned);
  }

  /// Spend coins
  Future<bool> spendCoins(int amount) async {
    if (_coins >= amount) {
      _coins -= amount;
      await _prefs?.setInt(_coinsKey, _coins);
      return true;
    }
    return false;
  }

  /// Unlock a skin
  Future<bool> unlockSkin(String skinId, int cost) async {
    if (_unlockedSkins.contains(skinId)) return true;

    if (await spendCoins(cost)) {
      _unlockedSkins.add(skinId);
      await _prefs?.setStringList(_skinUnlockedKey, _unlockedSkins);
      return true;
    }
    return false;
  }

  /// Complete daily challenge
  Future<void> completeDailyChallenge() async {
    if (!_dailyChallengeCompleted) {
      _dailyChallengeCompleted = true;
      await _prefs?.setBool(_dailyChallengeCompletedKey, true);

      // Reward based on streak
      final reward = 50 + (_dailyStreak * 10);
      await addCoins(reward);
    }
  }

  /// Prestige (reset progress for permanent bonuses)
  Future<bool> prestige() async {
    if (_maxLevelReached >= 50) {
      _prestigeLevel++;
      _maxLevelReached = 0;
      _maxScore = 0;
      await _prefs?.setInt(_prestigeLevelKey, _prestigeLevel);
      await _prefs?.setInt(_maxLevelReachedKey, 0);
      await _prefs?.setInt(_maxScoreKey, 0);

      // Prestige reward
      await addCoins(500 * _prestigeLevel);
      return true;
    }
    return false;
  }

  /// Unlock an achievement
  Future<bool> unlockAchievement(String achievementId) async {
    if (!_unlockedAchievements.contains(achievementId)) {
      _unlockedAchievements.add(achievementId);
      await _prefs?.setStringList(_achievementsKey, _unlockedAchievements);

      // Award coins for achievement
      final achievement = AchievementManager.getById(achievementId);
      if (achievement != null) {
        await addCoins(achievement.coinReward);
      }
      return true;
    }
    return false;
  }

  /// Reset all stats
  Future<void> resetStats() async {
    _totalGames = 0;
    _totalMerges = 0;
    _maxLevelReached = 0;
    _maxScore = 0;
    _unlockedAchievements = [];
    _coins = 0;
    _totalCoinsEarned = 0;
    _unlockedSkins = ['default'];
    _dailyStreak = 0;
    _prestigeLevel = 0;
    _showExternalLinkWarning = true;

    await _prefs?.setInt(_totalGamesKey, 0);
    await _prefs?.setInt(_totalMergesKey, 0);
    await _prefs?.setInt(_maxLevelReachedKey, 0);
    await _prefs?.setInt(_maxScoreKey, 0);
    await _prefs?.setStringList(_achievementsKey, []);
    await _prefs?.setInt(_coinsKey, 0);
    await _prefs?.setInt(_totalCoinsEarnedKey, 0);
    await _prefs?.setStringList(_skinUnlockedKey, ['default']);
    await _prefs?.setInt(_dailyStreakKey, 0);
    await _prefs?.setInt(_prestigeLevelKey, 0);
    await _prefs?.setBool(_showExternalLinkWarningKey, true);
  }

  /// Get gravity multiplier based on difficulty and prestige
  double get gravityMultiplier {
    final baseMultiplier = switch (_difficulty) {
      1 => 0.8,
      3 => 1.3,
      _ => 1.0,
    };
    // Prestige makes game slightly harder but gives bonus
    return baseMultiplier * (1 + _prestigeLevel * 0.05);
  }

  /// Get coin multiplier from prestige
  double get coinMultiplier => 1 + (_prestigeLevel * 0.1);

  /// Get score multiplier from prestige
  double get scoreMultiplier => 1 + (_prestigeLevel * 0.15);
}

/// INFINITE level system - levels go forever with scaling difficulty
class LevelManager {
  /// Get level data for any level number (infinite)
  static GameLevel getLevelForScore(int score, {int prestigeLevel = 0}) {
    // Find which level based on score
    int level = 1;
    int currentThreshold = 0;

    while (true) {
      final nextThreshold = _getScoreForLevel(level + 1, prestigeLevel);
      if (score < nextThreshold) break;
      currentThreshold = nextThreshold;
      level++;
    }

    return GameLevel(
      level: level,
      scoreRequired: currentThreshold,
      gravityMultiplier: _getGravityForLevel(level),
      maxSpawnType: _getMaxSpawnForLevel(level),
      name: _getNameForLevel(level),
      hasPowerUp: level % 4 == 0, // Power-up every 4 levels
      comboTimeBonus: level >= 20 ? 0.5 : 0,
      coinBonus: _getCoinBonusForLevel(level),
    );
  }

  /// Score required to reach a level (exponential growth)
  static int _getScoreForLevel(int level, int prestigeLevel) {
    if (level <= 1) return 0;

    // Exponential formula: base + level^2 * multiplier
    // Gets progressively harder
    final prestigeMultiplier = 1 + (prestigeLevel * 0.2);

    if (level <= 20) {
      // Early levels (0-20): manageable progression
      return ((30 * level * level) * prestigeMultiplier).toInt();
    } else if (level <= 50) {
      // Mid levels (20-50): steeper curve
      final base = _getScoreForLevel(20, prestigeLevel);
      return (base + ((level - 20) * (level - 20) * 100 * prestigeMultiplier))
          .toInt();
    } else if (level <= 100) {
      // High levels (50-100): even steeper
      final base = _getScoreForLevel(50, prestigeLevel);
      return (base + ((level - 50) * (level - 50) * 300 * prestigeMultiplier))
          .toInt();
    } else {
      // Endless (100+): very steep but always possible
      final base = _getScoreForLevel(100, prestigeLevel);
      return (base + ((level - 100) * (level - 100) * 500 * prestigeMultiplier))
          .toInt();
    }
  }

  /// Gravity increases with level
  static double _getGravityForLevel(int level) {
    if (level <= 10) return 0.8 + (level * 0.05);
    if (level <= 20) return 1.3 + ((level - 10) * 0.03);
    if (level <= 50) return 1.6 + ((level - 20) * 0.02);
    if (level <= 100) return 2.2 + ((level - 50) * 0.01);
    // Cap at 3.0x for playability
    return (2.7 + ((level - 100) * 0.003)).clamp(2.7, 3.0);
  }

  /// More sushi types at higher levels
  static int _getMaxSpawnForLevel(int level) {
    if (level < 3) return 3;
    if (level < 6) return 4;
    if (level < 10) return 5;
    if (level < 20) return 6;
    if (level < 40) return 7;
    return 8; // Max variety
  }

  /// Creative level names
  static String _getNameForLevel(int level) {
    if (level <= 20) {
      return _earlyLevelNames[level.clamp(1, 20) - 1];
    } else if (level <= 50) {
      return 'Maestro ${level - 20}⭐';
    } else if (level <= 100) {
      return 'Leyenda ${level - 50}🔥';
    } else if (level <= 200) {
      return 'Inmortal ${level - 100}💎';
    } else if (level <= 500) {
      return 'Dios ${level - 200}👑';
    } else {
      return 'INFINITO $level∞';
    }
  }

  static const List<String> _earlyLevelNames = [
    'Aprendiz',
    'Novato',
    'Cocinero',
    'Chef Junior',
    'Chef',
    'Sous Chef',
    'Chef Principal',
    'Maestro',
    'Gran Maestro',
    'Itamae',
    'Itamae Senior',
    'Taisho',
    'Shokunin',
    'Artesano',
    'Virtuoso',
    'Leyenda',
    'Mito',
    'Inmortal',
    'Dios del Sushi',
    'SUSHI SUPREMO',
  ];

  /// Coin bonus per level
  static int _getCoinBonusForLevel(int level) {
    if (level <= 10) return 1;
    if (level <= 20) return 2;
    if (level <= 50) return 5;
    if (level <= 100) return 10;
    return 20;
  }

  /// Get progress percentage to next level
  static int getProgressToNextLevel(
    int score,
    int currentLevel, {
    int prestigeLevel = 0,
  }) {
    final currentRequired = _getScoreForLevel(currentLevel, prestigeLevel);
    final nextRequired = _getScoreForLevel(currentLevel + 1, prestigeLevel);

    final range = nextRequired - currentRequired;
    if (range <= 0) return 100;

    final progress = score - currentRequired;
    return ((progress / range) * 100).clamp(0, 100).toInt();
  }
}

/// Level data structure
class GameLevel {
  final int level;
  final int scoreRequired;
  final double gravityMultiplier;
  final int maxSpawnType;
  final String name;
  final bool hasPowerUp;
  final double comboTimeBonus;
  final int coinBonus;

  const GameLevel({
    required this.level,
    required this.scoreRequired,
    required this.gravityMultiplier,
    required this.maxSpawnType,
    required this.name,
    this.hasPowerUp = false,
    this.comboTimeBonus = 0,
    this.coinBonus = 1,
  });
}

/// Achievement definitions with coin rewards
class Achievement {
  final String id;
  final String name;
  final String description;
  final String emoji;
  final int coinReward;

  const Achievement({
    required this.id,
    required this.name,
    required this.description,
    required this.emoji,
    this.coinReward = 0,
  });
}

class AchievementManager {
  static const List<Achievement> achievements = [
    // Basic achievements
    Achievement(
      id: 'first_merge',
      name: '¡Primera Fusión!',
      description: 'Fusiona tu primer sushi',
      emoji: '🎉',
      coinReward: 10,
    ),
    Achievement(
      id: 'combo_3',
      name: 'Combo x3',
      description: 'Consigue un combo de 3',
      emoji: '⚡',
      coinReward: 25,
    ),
    Achievement(
      id: 'combo_5',
      name: 'Combo x5',
      description: 'Consigue un combo de 5',
      emoji: '🔥',
      coinReward: 50,
    ),
    Achievement(
      id: 'combo_10',
      name: 'COMBO MAESTRO',
      description: 'Consigue un combo de 10',
      emoji: '💥',
      coinReward: 100,
    ),
    Achievement(
      id: 'combo_15',
      name: 'COMBO LEGENDARIO',
      description: 'Consigue un combo de 15',
      emoji: '🌟',
      coinReward: 250,
    ),

    // Level achievements
    Achievement(
      id: 'level_5',
      name: 'Chef Certificado',
      description: 'Alcanza el nivel 5',
      emoji: '👨‍🍳',
      coinReward: 30,
    ),
    Achievement(
      id: 'level_10',
      name: 'Itamae',
      description: 'Alcanza el nivel 10',
      emoji: '🏆',
      coinReward: 75,
    ),
    Achievement(
      id: 'level_20',
      name: 'SUSHI SUPREMO',
      description: 'Alcanza el nivel 20',
      emoji: '👑',
      coinReward: 150,
    ),
    Achievement(
      id: 'level_50',
      name: 'Leyenda Viviente',
      description: 'Alcanza el nivel 50',
      emoji: '🔥',
      coinReward: 500,
    ),
    Achievement(
      id: 'level_100',
      name: 'INMORTAL',
      description: 'Alcanza el nivel 100',
      emoji: '💎',
      coinReward: 1000,
    ),

    // Sushi achievements
    Achievement(
      id: 'dragon_roll',
      name: 'Dragon Roll',
      description: 'Crea un Dragon Roll',
      emoji: '🐉',
      coinReward: 200,
    ),

    // Score achievements
    Achievement(
      id: 'score_1000',
      name: 'Mil Puntos',
      description: 'Alcanza 1000 puntos',
      emoji: '💰',
      coinReward: 50,
    ),
    Achievement(
      id: 'score_5000',
      name: 'Cinco Mil',
      description: 'Alcanza 5000 puntos',
      emoji: '💎',
      coinReward: 100,
    ),
    Achievement(
      id: 'score_10000',
      name: 'Diez Mil',
      description: 'Alcanza 10000 puntos',
      emoji: '🌟',
      coinReward: 250,
    ),
    Achievement(
      id: 'score_50000',
      name: 'Cincuenta Mil',
      description: 'Alcanza 50000 puntos',
      emoji: '🚀',
      coinReward: 500,
    ),
    Achievement(
      id: 'score_100000',
      name: 'CIEN MIL',
      description: 'Alcanza 100000 puntos',
      emoji: '👑',
      coinReward: 1000,
    ),

    // Engagement achievements
    Achievement(
      id: 'games_10',
      name: 'Adicto',
      description: 'Juega 10 partidas',
      emoji: '🎮',
      coinReward: 25,
    ),
    Achievement(
      id: 'games_50',
      name: 'Veterano',
      description: 'Juega 50 partidas',
      emoji: '🎖️',
      coinReward: 100,
    ),
    Achievement(
      id: 'games_100',
      name: 'Maestro del Juego',
      description: 'Juega 100 partidas',
      emoji: '🏅',
      coinReward: 300,
    ),
    Achievement(
      id: 'merges_100',
      name: 'Fusionador',
      description: 'Realiza 100 fusiones',
      emoji: '🔄',
      coinReward: 50,
    ),
    Achievement(
      id: 'merges_500',
      name: 'Fusión Infinita',
      description: 'Realiza 500 fusiones',
      emoji: '♾️',
      coinReward: 150,
    ),
    Achievement(
      id: 'merges_1000',
      name: 'Fusión Máxima',
      description: 'Realiza 1000 fusiones',
      emoji: '⚡',
      coinReward: 300,
    ),

    // Daily achievements
    Achievement(
      id: 'streak_3',
      name: 'Racha de 3',
      description: '3 días seguidos',
      emoji: '📅',
      coinReward: 50,
    ),
    Achievement(
      id: 'streak_7',
      name: 'Semana Completa',
      description: '7 días seguidos',
      emoji: '🗓️',
      coinReward: 150,
    ),
    Achievement(
      id: 'streak_30',
      name: 'Mes Dedicado',
      description: '30 días seguidos',
      emoji: '🏆',
      coinReward: 500,
    ),

    // Prestige achievements
    Achievement(
      id: 'prestige_1',
      name: 'Primer Prestigio',
      description: 'Alcanza prestigio 1',
      emoji: '⭐',
      coinReward: 200,
    ),
    Achievement(
      id: 'prestige_5',
      name: 'Maestro del Prestigio',
      description: 'Alcanza prestigio 5',
      emoji: '🌟',
      coinReward: 1000,
    ),
  ];

  static Achievement? getById(String id) {
    try {
      return achievements.firstWhere((a) => a.id == id);
    } catch (_) {
      return null;
    }
  }
}

/// Power-up types
enum PowerUpType {
  bomb('💣', 'Bomba', 'Elimina 3 sushis aleatorios', 50),
  slowMo('🐌', 'Cámara Lenta', 'Reduce la velocidad por 5 segundos', 30),
  shuffle('🔀', 'Mezclar', 'Reorganiza todos los sushis', 40),
  magnet('🧲', 'Imán', 'Atrae sushis iguales', 60),
  freeze('❄️', 'Congelar', 'Pausa la gravedad por 3 segundos', 50),
  doublePoints('✨', 'Puntos x2', 'Duplica puntos por 10 segundos', 80),
  extraLife('❤️', 'Vida Extra', 'Una oportunidad más', 100);

  final String emoji;
  final String name;
  final String description;
  final int cost; // For shop

  const PowerUpType(this.emoji, this.name, this.description, this.cost);
}

/// Daily challenge types
enum DailyChallengeType {
  reachLevel('Alcanza nivel', '📈'),
  scoreMerges('Realiza fusiones', '🔄'),
  reachScore('Consigue puntos', '⭐'),
  getCombo('Consigue combo x', '🔥');

  final String description;
  final String emoji;

  const DailyChallengeType(this.description, this.emoji);
}

class DailyChallenge {
  final DailyChallengeType type;
  final int target;
  final int coinReward;

  DailyChallenge({
    required this.type,
    required this.target,
    required this.coinReward,
  });

  factory DailyChallenge.generate() {
    final random = Random(DateTime.now().day);
    final types = DailyChallengeType.values;
    final type = types[random.nextInt(types.length)];

    int target;
    int reward;

    switch (type) {
      case DailyChallengeType.reachLevel:
        target = 5 + random.nextInt(10);
        reward = 50 + (target * 5);
        break;
      case DailyChallengeType.scoreMerges:
        target = 20 + random.nextInt(30);
        reward = 40 + (target * 2);
        break;
      case DailyChallengeType.reachScore:
        target = (500 + random.nextInt(1500)).round();
        reward = 30 + (target ~/ 50);
        break;
      case DailyChallengeType.getCombo:
        target = 3 + random.nextInt(5);
        reward = 60 + (target * 15);
        break;
    }

    return DailyChallenge(type: type, target: target, coinReward: reward);
  }

  String get displayText => '${type.emoji} ${type.description} $target';
}
