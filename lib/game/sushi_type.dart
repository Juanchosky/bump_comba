import 'dart:ui';

/// Represents different types of sushi that can appear in the game.
/// Each type has a specific size, color, and point value.
/// When two sushi of the same type collide, they merge into the next level.
enum SushiType {
  // Level 1 - Smallest
  tamago(
    level: 1,
    radius: 18.0,
    points: 1,
    color: Color(0xFFFFE066),
    name: 'Tamago',
    emoji: '🥚',
  ),

  // Level 2
  ebi(
    level: 2,
    radius: 24.0,
    points: 3,
    color: Color(0xFFFF8A80),
    name: 'Ebi',
    emoji: '🦐',
  ),

  // Level 3
  sake(
    level: 3,
    radius: 30.0,
    points: 6,
    color: Color(0xFFFF6B6B),
    name: 'Sake',
    emoji: '🍣',
  ),

  // Level 4
  maguro(
    level: 4,
    radius: 36.0,
    points: 10,
    color: Color(0xFFE53935),
    name: 'Maguro',
    emoji: '🐟',
  ),

  // Level 5
  ikura(
    level: 5,
    radius: 42.0,
    points: 15,
    color: Color(0xFFFF5722),
    name: 'Ikura',
    emoji: '🔴',
  ),

  // Level 6
  uni(
    level: 6,
    radius: 50.0,
    points: 21,
    color: Color(0xFFFFAB00),
    name: 'Uni',
    emoji: '🟠',
  ),

  // Level 7
  hotate(
    level: 7,
    radius: 58.0,
    points: 28,
    color: Color(0xFFF5F5DC),
    name: 'Hotate',
    emoji: '🥟',
  ),

  // Level 8
  unagi(
    level: 8,
    radius: 68.0,
    points: 36,
    color: Color(0xFF8D6E63),
    name: 'Unagi',
    emoji: '🐍',
  ),

  // Level 9
  otoro(
    level: 9,
    radius: 78.0,
    points: 45,
    color: Color(0xFFFFCDD2),
    name: 'Otoro',
    emoji: '🍖',
  ),

  // Level 10 - Largest
  dragon(
    level: 10,
    radius: 90.0,
    points: 55,
    color: Color(0xFF4CAF50),
    name: 'Dragon Roll',
    emoji: '🐉',
  );

  const SushiType({
    required this.level,
    required this.radius,
    required this.points,
    required this.color,
    required this.name,
    required this.emoji,
  });

  final int level;
  final double radius;
  final int points;
  final Color color;
  final String name;
  final String emoji;

  /// Returns the next sushi type after merging, or null if this is the max level
  SushiType? get nextType {
    if (level >= SushiType.values.length) return null;
    return SushiType.values.firstWhere(
      (type) => type.level == level + 1,
      orElse: () => this,
    );
  }

  /// Get sushi type by level
  static SushiType fromLevel(int level) {
    return SushiType.values.firstWhere(
      (type) => type.level == level,
      orElse: () => SushiType.tamago,
    );
  }

  /// Get a list of sushi types available for spawning (typically levels 1-5)
  static List<SushiType> get spawnableTypes {
    return SushiType.values.where((type) => type.level <= 5).toList();
  }
}
