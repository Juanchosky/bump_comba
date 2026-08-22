import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Utility class for local data obfuscation using XOR + Base64.
/// This prevents sensitive strings (like M3U URLs) from being stored in plain text.
class SecurityUtils {
  // A unique key used for XOR operations.
  static String get _key => dotenv.env['SECURITY_KEY'] ?? 'bump_comba_v1_secure_layer_2026';

  // Prefix to identify obfuscated strings and avoid double-obfuscation.
  static const String _prefix = 'obf:';

  /// Obfuscates a string if it's not already obfuscated.
  static String obfuscate(String input) {
    if (input.isEmpty) return input;
    if (input.startsWith(_prefix)) return input;

    return '$_prefix${base64.encode(_xor(utf8.encode(input)))}';
  }

  /// De-obfuscates a string if it has the security prefix.
  static String deobfuscate(String input) {
    if (input.isEmpty) return input;
    if (!input.startsWith(_prefix)) return input;

    final actualData = input.substring(_prefix.length);
    try {
      return utf8.decode(_xor(base64.decode(actualData)));
    } catch (_) {
      // If decoding or XOR fails (e.g. key mismatch), return original string
      // trimmed of prefix if it was really plain text that happened to start with it.
      return input;
    }
  }

  /// XOR con la clave, repetida ciclicamente. Mismo resultado que antes.
  ///
  /// Antes se usaba `List<int>.generate`, que devuelve una lista de enteros
  /// CON BOXING: un objeto en el heap por cada byte. Sobre el historial
  /// completo de reproduccion (cientos de KB) eso son cientos de miles de
  /// objetos basura en cada guardado, y el guardado ocurria en el hilo de UI
  /// mientras el video corria. `Uint8List` reserva un unico bloque plano.
  static Uint8List _xor(List<int> bytes) {
    final keyBytes = utf8.encode(_key);
    final keyLen = keyBytes.length;
    final out = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      out[i] = bytes[i] ^ keyBytes[i % keyLen];
    }
    return out;
  }

  /// Checks if a string follows the obfuscated format.
  static bool isObfuscated(String input) => input.startsWith(_prefix);
}
