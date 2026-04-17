import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'sushi_type.dart';
import 'sushi_game.dart';

/// A sushi body with custom physics (no Forge2D)
class SushiBody extends CircleComponent {
  SushiBody({
    required this.sushiType,
    required Vector2 position,
    this.isDropping = false,
    this.gameGravity = 800.0,
  }) : super(
         position: position,
         radius: sushiType.radius,
         anchor: Anchor.center,
       );

  final SushiType sushiType;
  bool isDropping;
  bool _isMarkedForMerge = false;
  bool isFrozen = false;
  final double gameGravity;

  // Physics
  Vector2 velocity = Vector2.zero();
  static const double friction = 0.98;
  static const double bounceFactor = 0.3;

  // For spawn animation
  double _spawnScale = 0.3;
  bool _isSpawning = true;

  // Glow effect for fever mode
  double _glowPhase = 0;

  // Collision vibration cooldown
  double _vibrationCooldown = 0;

  SushiGame get gameRef => findGame()! as SushiGame;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    _spawnScale = 0.3;
    _isSpawning = true;
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Update vibration cooldown
    if (_vibrationCooldown > 0) {
      _vibrationCooldown -= dt;
    }

    // Spawn animation
    if (_isSpawning) {
      _spawnScale += dt * 5;
      if (_spawnScale >= 1.0) {
        _spawnScale = 1.0;
        _isSpawning = false;
      }
    }

    // Glow animation
    _glowPhase += dt * 3;

    if (!isDropping || isFrozen) return;

    // Apply gravity
    velocity.y += gameGravity * dt;

    // Apply friction
    velocity.x *= friction;

    // Update position
    position += velocity * dt;

    // Wall collisions
    final leftBound = sushiType.radius + 15;
    final rightBound = gameRef.gameWidth - sushiType.radius - 15;
    final bottomBound = gameRef.gameHeight - sushiType.radius - 15;

    if (position.x < leftBound) {
      position.x = leftBound;
      velocity.x = -velocity.x * bounceFactor;
      _vibrateOnImpact();
    }
    if (position.x > rightBound) {
      position.x = rightBound;
      velocity.x = -velocity.x * bounceFactor;
      _vibrateOnImpact();
    }
    if (position.y > bottomBound) {
      position.y = bottomBound;
      final hadSignificantVelocity = velocity.y.abs() > 100;
      velocity.y = -velocity.y * bounceFactor;
      if (velocity.y.abs() < 20) velocity.y = 0;
      if (hadSignificantVelocity) {
        _vibrateOnImpact();
      }
    }
  }

  /// Vibrate on impact (with cooldown to avoid excessive vibration)
  void _vibrateOnImpact() {
    gameRef.vibrate(HapticFeedbackType.selection);
  }

  @override
  void render(Canvas canvas) {
    final screenRadius = sushiType.radius * _spawnScale;

    // 1. Draw glow effect in fever mode (behind everything)
    if (gameRef.feverMode) {
      final glowIntensity = (0.3 + 0.2 * (1 + ((_glowPhase) % 1)));
      final glowPaint =
          Paint()
            ..color = sushiType.color.withValues(alpha: glowIntensity)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);
      canvas.drawCircle(Offset.zero, screenRadius + 5, glowPaint);
    }

    // 2. Draw "Depth/Shadow" Layer (The darker bottom part) - Chunky 3D effect
    final depthOffset = screenRadius * 0.15; // Height of the 3D effect
    final depthColor =
        HSLColor.fromColor(sushiType.color)
            .withLightness(
              (HSLColor.fromColor(sushiType.color).lightness - 0.2).clamp(
                0.0,
                1.0,
              ),
            )
            .toColor();

    final depthPaint = Paint()..color = depthColor;
    // Draw the depth circle slightly lower
    canvas.drawCircle(Offset(0, depthOffset), screenRadius, depthPaint);

    // 3. Draw "Face" Layer (Main Body)
    final facePaint = Paint()..color = sushiType.color;
    canvas.drawCircle(Offset.zero, screenRadius, facePaint);

    // 4. Draw Highlight/Shine (Simple white curve at top)
    final shinePaint =
        Paint()
          ..color = Colors.white.withValues(alpha: 0.3)
          ..style = PaintingStyle.fill;

    // Draw a subtle oval shine at the top
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(0, -screenRadius * 0.5),
        width: screenRadius * 1.2,
        height: screenRadius * 0.6,
      ),
      shinePaint,
    );

    // 5. Draw Frozen Overlay (if active)
    if (isFrozen) {
      final frozenPaint =
          Paint()
            ..color = Colors.cyan.withValues(alpha: 0.4)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      canvas.drawCircle(Offset.zero, screenRadius, frozenPaint);

      // Icy border
      final frozenBorder =
          Paint()
            ..color = Colors.white.withValues(alpha: 0.8)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2;
      canvas.drawCircle(Offset.zero, screenRadius, frozenBorder);
    }

    // 6. Draw Emoji
    final textPainter = TextPainter(
      text: TextSpan(
        text: sushiType.emoji,
        style: TextStyle(
          fontSize: screenRadius * 0.9,
          shadows: [
            // Subtle shadow for the emoji itself to make it pop
            Shadow(
              color: Colors.black.withValues(alpha: 0.2),
              offset: const Offset(0, 2),
              blurRadius: 2,
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(-textPainter.width / 2, -textPainter.height / 2),
    );
  }

  /// Drop the sushi into the game
  void drop() {
    if (!isDropping) {
      isDropping = true;
    }
  }

  /// Move the sushi horizontally (before dropping)
  void moveToX(double x) {
    if (!isDropping) {
      final clampedX = x.clamp(
        sushiType.radius + 15,
        gameRef.gameWidth - sushiType.radius - 15,
      );
      position.x = clampedX;
    }
  }

  /// Check collision with another sushi
  bool isCollidingWith(SushiBody other) {
    final distance = position.distanceTo(other.position);
    final minDistance = sushiType.radius + other.sushiType.radius;
    return distance < minDistance;
  }

  /// Resolve collision with another sushi
  void resolveCollision(SushiBody other) {
    final delta = position - other.position;
    final distance = delta.length;
    final overlap = (sushiType.radius + other.sushiType.radius) - distance;

    if (overlap > 0 && distance > 0) {
      final normal = delta.normalized();

      // Separate the bodies
      position += normal * (overlap / 2);
      other.position -= normal * (overlap / 2);

      // Exchange velocity along collision normal
      final relativeVelocity = velocity - other.velocity;
      final velocityAlongNormal = relativeVelocity.dot(normal);

      if (velocityAlongNormal > 0) return;

      const restitution = 0.4;
      final impulse = -(1 + restitution) * velocityAlongNormal / 2;

      velocity += normal * impulse;
      other.velocity -= normal * impulse;

      if (impulse.abs() > 50) {
        _vibrateOnImpact();
      }
    }
  }

  /// Check if this sushi should merge with another
  bool canMergeWith(SushiBody other) {
    return sushiType == other.sushiType &&
        !_isMarkedForMerge &&
        !other._isMarkedForMerge &&
        sushiType.nextType != null &&
        isDropping &&
        other.isDropping &&
        !isFrozen &&
        !other.isFrozen &&
        isCollidingWith(other);
  }

  /// Mark this sushi for merging (to prevent double merges)
  void markForMerge() {
    _isMarkedForMerge = true;
  }

  bool get isMarkedForMerge => _isMarkedForMerge;

  bool get isAtRest => velocity.length < 10;
}
