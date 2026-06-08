import 'package:flutter/material.dart';

class AppColors {
  // Original dark gray
  static const Color background = Color.fromARGB(255, 13, 13, 13);

  // Slightly lighter variant for cards or secondary layers (original was often 1a1a1a)
  static const Color surface = Color(0xFF1a1a1a);

  // Primary accent (keeping the original salmon-red)
  static const Color primary = Color(0xFFFF6B6B);

  // High contrast text
  static const Color textBody = Color(0xFFE1E1E1);
  static const Color textMuted = Color(0xFF9CA3AF);

  // ── Design tokens (semantic) ───────────────────────────────────────────
  // Centralised so the whole UI stays coherent and the look can be retuned
  // from a single place instead of chasing hardcoded hex values.

  /// Elevated surfaces: search field, chips, pill backgrounds.
  static const Color surfaceVariant = Color(0xFF2B2B2B);

  /// Brand accent used for selection, progress and active states. Unifies the
  /// previously mixed `Colors.red` / salmon usages into one identity.
  static const Color accent = primary;

  /// Hairline separators and subtle borders over dark surfaces.
  static const Color divider = Color(0x1AFFFFFF); // white @ 10%

  /// Secondary text over posters/cards (legible but not shouting).
  static const Color textSecondary = Color(0xB3FFFFFF); // white @ 70%
}
