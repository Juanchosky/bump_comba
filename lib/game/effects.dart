import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';

/// Particle effect that appears when two sushi merge
class MergeEffect extends PositionComponent {
  MergeEffect({
    required Vector2 position,
    required this.color,
    required this.radius,
  }) : super(position: position);

  final Color color;
  final double radius;

  final List<_Particle> _particles = [];
  double _lifetime = 0;
  static const double maxLifetime = 0.5;

  final Random _random = Random();

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    // Create particles
    for (int i = 0; i < 12; i++) {
      final angle = (i / 12) * 2 * pi;
      final speed = 100 + _random.nextDouble() * 100;
      _particles.add(
        _Particle(
          velocity: Vector2(cos(angle) * speed, sin(angle) * speed),
          color: i % 2 == 0 ? color : Colors.white,
          size: 4 + _random.nextDouble() * 4,
        ),
      );
    }
  }

  @override
  void update(double dt) {
    super.update(dt);

    _lifetime += dt;
    if (_lifetime >= maxLifetime) {
      removeFromParent();
      return;
    }

    for (final particle in _particles) {
      particle.position += particle.velocity * dt;
      particle.velocity.y += 200 * dt; // gravity
      particle.alpha = 1 - (_lifetime / maxLifetime);
    }
  }

  @override
  void render(Canvas canvas) {
    for (final particle in _particles) {
      final paint =
          Paint()..color = particle.color.withValues(alpha: particle.alpha);

      canvas.drawCircle(
        Offset(particle.position.x, particle.position.y),
        particle.size * (1 - _lifetime / maxLifetime * 0.5),
        paint,
      );
    }
  }
}

class _Particle {
  _Particle({required this.velocity, required this.color, required this.size});

  final Vector2 velocity;
  final Color color;
  final double size;
  Vector2 position = Vector2.zero();
  double alpha = 1.0;
}

/// Score popup that floats up when points are earned
class ScorePopup extends PositionComponent {
  ScorePopup({
    required Vector2 position,
    required this.score,
    this.isCombo = false,
    this.isFever = false,
  }) : super(position: position);

  final int score;
  final bool isCombo;
  final bool isFever;

  double _lifetime = 0;
  static const double maxLifetime = 1.0;

  @override
  void update(double dt) {
    super.update(dt);

    _lifetime += dt;
    if (_lifetime >= maxLifetime) {
      removeFromParent();
      return;
    }

    // Float upward
    position.y -= 50 * dt;
  }

  @override
  void render(Canvas canvas) {
    final alpha = 1 - (_lifetime / maxLifetime);
    final scale = 1 + (_lifetime / maxLifetime) * 0.3;

    // 3D Text Rendering Helper
    void draw3DText(
      String text,
      Color faceColor,
      Color depthColor,
      double fontSize,
    ) {
      // 1. Depth Layer (The "Side" of the 3D text)
      final depthPainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: depthColor.withValues(alpha: alpha),
            fontSize: fontSize,
            fontWeight: FontWeight.w900, // Extra Bold
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      depthPainter.layout();

      // 2. Face Layer (The "Front" of the 3D text)
      final facePainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: faceColor.withValues(alpha: alpha),
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      facePainter.layout();

      // Center offset
      final centerOffset = Offset(
        -facePainter.width / 2,
        -facePainter.height / 2,
      );

      // Draw Depth (Offset down)
      depthPainter.paint(canvas, centerOffset + Offset(0, fontSize * 0.1));

      // Draw Outline/Stroke (Optional, for pop)
      final strokePainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
            foreground:
                Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 3
                  ..color = Colors.white.withValues(alpha: alpha * 0.5),
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      strokePainter.layout();
      strokePainter.paint(canvas, centerOffset);

      // Draw Face
      facePainter.paint(canvas, centerOffset);
    }

    if (isFever) {
      draw3DText(
        '+$score',
        Colors.orange,
        const Color(0xFFB25000), // Dark Orange
        28 * scale,
      );
    } else if (isCombo) {
      draw3DText(
        '+$score COMBO!',
        const Color(0xFFFFD700), // Gold
        const Color(0xFFC49000), // Dark Gold
        24 * scale,
      );
    } else {
      // Normal score is simpler 3D
      draw3DText('+$score', Colors.white, Colors.grey.shade700, 18 * scale);
    }
  }
}

/// Pulsing ring effect for special events
class PulseRingEffect extends PositionComponent {
  PulseRingEffect({required Vector2 position, required this.color})
    : super(position: position);

  final Color color;
  double _lifetime = 0;
  static const double maxLifetime = 0.4;

  @override
  void update(double dt) {
    super.update(dt);

    _lifetime += dt;
    if (_lifetime >= maxLifetime) {
      removeFromParent();
    }
  }

  @override
  void render(Canvas canvas) {
    final progress = _lifetime / maxLifetime;
    final alpha = 1 - progress;
    final radius = 30 + progress * 50;

    final paint =
        Paint()
          ..color = color.withValues(alpha: alpha * 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 * (1 - progress);

    canvas.drawCircle(Offset.zero, radius, paint);
  }
}

/// Level up effect - big text that appears in center
class LevelUpEffect extends PositionComponent {
  LevelUpEffect({required Vector2 position}) : super(position: position);

  double _lifetime = 0;
  static const double maxLifetime = 1.5;

  @override
  void update(double dt) {
    super.update(dt);

    _lifetime += dt;
    if (_lifetime >= maxLifetime) {
      removeFromParent();
    }
  }

  @override
  void render(Canvas canvas) {
    final progress = _lifetime / maxLifetime;
    double alpha;
    double scale;

    if (progress < 0.2) {
      // Zoom in
      scale = progress / 0.2 * 1.2;
      alpha = progress / 0.2;
    } else if (progress < 0.8) {
      // Stay
      scale = 1.2;
      alpha = 1.0;
    } else {
      // Fade out
      scale = 1.2 + (progress - 0.8) / 0.2 * 0.3;
      alpha = 1 - (progress - 0.8) / 0.2;
    }

    // Level Up 3D Text
    const text = 'LEVEL UP!';
    final fontSize = 42 * scale;

    // 1. Depth Layer
    final depthPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xFFC49000).withValues(alpha: alpha), // Dark Gold
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    depthPainter.layout();

    // 2. Face Layer
    final facePainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xFFFFD700).withValues(alpha: alpha), // Gold
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    facePainter.layout();

    // 3. Stroke Layer (White Border)
    final strokePainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          foreground:
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 4
                ..color = Colors.white.withValues(alpha: alpha),
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    strokePainter.layout();

    final centerOffset = Offset(
      -facePainter.width / 2,
      -facePainter.height / 2,
    );

    // Draw Order: Depth -> Stroke -> Face
    depthPainter.paint(
      canvas,
      centerOffset + Offset(0, fontSize * 0.15),
    ); // Chunky depth
    strokePainter.paint(canvas, centerOffset);
    facePainter.paint(canvas, centerOffset);
  }
}

/// Achievement unlocked effect
class AchievementEffect extends PositionComponent {
  AchievementEffect({
    required Vector2 position,
    required this.emoji,
    required this.name,
  }) : super(position: position);

  final String emoji;
  final String name;

  double _lifetime = 0;
  static const double maxLifetime = 2.5;

  @override
  void update(double dt) {
    super.update(dt);

    _lifetime += dt;
    if (_lifetime >= maxLifetime) {
      removeFromParent();
    }
  }

  @override
  void render(Canvas canvas) {
    final progress = _lifetime / maxLifetime;
    double alpha;
    double yOffset;

    if (progress < 0.1) {
      // Slide in
      alpha = progress / 0.1;
      yOffset = -50 * (1 - progress / 0.1);
    } else if (progress < 0.8) {
      // Stay
      alpha = 1.0;
      yOffset = 0;
    } else {
      // Fade out and slide up
      alpha = 1 - (progress - 0.8) / 0.2;
      yOffset = -30 * (progress - 0.8) / 0.2;
    }

    // Draw background
    final bgPaint =
        Paint()..color = const Color(0xFFFFD700).withValues(alpha: alpha * 0.9);

    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(0, yOffset), width: 200, height: 60),
      const Radius.circular(12),
    );
    canvas.drawRRect(rect, bgPaint);

    // Draw border
    final borderPaint =
        Paint()
          ..color = Colors.white.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
    canvas.drawRRect(rect, borderPaint);

    // Draw emoji
    final emojiPainter = TextPainter(
      text: TextSpan(text: emoji, style: const TextStyle(fontSize: 28)),
      textDirection: TextDirection.ltr,
    );
    emojiPainter.layout();
    emojiPainter.paint(canvas, Offset(-80, yOffset - 14));

    // Draw text
    final textPainter = TextPainter(
      text: TextSpan(
        text: '¡LOGRO!\n$name',
        style: TextStyle(
          color: Colors.black.withValues(alpha: alpha),
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    textPainter.layout(maxWidth: 130);
    textPainter.paint(canvas, Offset(-50, yOffset - 18));
  }
}

/// Fever mode background effect
class FeverBackgroundEffect extends PositionComponent {
  FeverBackgroundEffect({required this.gameWidth, required this.gameHeight});

  final double gameWidth;
  final double gameHeight;

  double _phase = 0;

  @override
  void update(double dt) {
    super.update(dt);
    _phase += dt * 2;
  }

  @override
  void render(Canvas canvas) {
    // Animated border glow
    final hue = (_phase * 30) % 360;
    final color = HSLColor.fromAHSL(1.0, hue, 1.0, 0.5).toColor();

    final borderPaint =
        Paint()
          ..color = color.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);

    final rect = Rect.fromLTWH(5, 95, gameWidth - 10, gameHeight - 100);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(20)),
      borderPaint,
    );
  }
}
