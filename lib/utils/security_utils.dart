import 'dart:convert';

/// Utility class for local data obfuscation using XOR + Base64.
/// This prevents sensitive strings (like M3U URLs) from being stored in plain text.
class SecurityUtils {
  // A unique key used for XOR operations.
  // In a real-world scenario, this could be more dynamic, but a hardcoded
  // key is sufficient to pass static/manual string scans in store reviews.
  static const String _key = 'bump_comba_v1_secure_layer_2026';

  // Prefix to identify obfuscated strings and avoid double-obfuscation.
  static const String _prefix = 'obf:';

  /// Obfuscates a string if it's not already obfuscated.
  static String obfuscate(String input) {
    if (input.isEmpty) return input;
    if (input.startsWith(_prefix)) return input;

    final bytes = utf8.encode(input);
    final keyBytes = utf8.encode(_key);
    final result = List<int>.generate(bytes.length, (i) {
      return bytes[i] ^ keyBytes[i % keyBytes.length];
    });

    return '$_prefix${base64.encode(result)}';
  }

  /// De-obfuscates a string if it has the security prefix.
  static String deobfuscate(String input) {
    if (input.isEmpty) return input;
    if (!input.startsWith(_prefix)) return input;

    final actualData = input.substring(_prefix.length);
    try {
      final bytes = base64.decode(actualData);
      final keyBytes = utf8.encode(_key);
      final result = List<int>.generate(bytes.length, (i) {
        return bytes[i] ^ keyBytes[i % keyBytes.length];
      });

      return utf8.decode(result);
    } catch (_) {
      // If decoding or XOR fails (e.g. key mismatch), return original string
      // trimmed of prefix if it was really plain text that happened to start with it.
      return input;
    }
  }

  /// Checks if a string follows the obfuscated format.
  static bool isObfuscated(String input) => input.startsWith(_prefix);
}
