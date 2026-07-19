import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Detección de si la app corre en un dispositivo de TV (Android TV / Google
/// TV / Fire TV), para rutear a la pantalla receptora en `main.dart`.
///
/// La detección real la hace la capa nativa (MainActivity.kt) combinando
/// `UiModeManager.MODE_TYPE_TELEVISION` + `PackageManager.FEATURE_LEANBACK`
/// + `!FEATURE_TOUCHSCREEN`. Aquí solo invocamos el MethodChannel con un
/// timeout corto para no retrasar el primer frame.
class TvPlatform {
  TvPlatform._();

  static const MethodChannel _channel =
      MethodChannel('com.juanchosky.bumpcomba/tv');

  /// Devuelve `true` si el dispositivo es un TV.
  ///
  /// En TVs de gama baja (p. ej. Chromecast HD) el arranque satura el main
  /// thread ("Skipped 1008 frames") y la primera llamada al canal puede tardar
  /// más de 800ms. Un solo timeout corto hacía que el TV arrancara como
  /// teléfono (salía el juego en vez del receptor). Por eso REINTENTAMOS con
  /// timeouts crecientes: en un teléfono la primera llamada responde en
  /// milisegundos (cero retraso), y el caso lento solo ocurre en TVs.
  static Future<bool> isAndroidTv() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    const timeouts = [
      Duration(milliseconds: 800),
      Duration(milliseconds: 1500),
      Duration(milliseconds: 3000),
    ];
    for (int i = 0; i < timeouts.length; i++) {
      try {
        final result = await _channel
            .invokeMethod<bool>('isAndroidTv')
            .timeout(timeouts[i]);
        return result ?? false;
      } on MissingPluginException {
        // El handler nativo aún no está registrado: dar un respiro y reintentar.
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        debugPrint(
          'TvPlatform: isAndroidTv intento ${i + 1} falló: $e',
        );
      }
    }
    debugPrint('TvPlatform: isAndroidTv agotó reintentos (asumiendo teléfono)');
    return false;
  }

  /// Adquiere PARTIAL_WAKE_LOCK (CPU) + WifiLock mientras hay transmisión, para
  /// que Doze no duerma la radio Wi-Fi y tumbe el WebSocket con la pantalla
  /// apagada. Idempotente en la capa nativa.
  static Future<void> acquireCastLocks() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('acquireCastLocks');
    } catch (e) {
      debugPrint('TvPlatform: acquireCastLocks falló: $e');
    }
  }

  /// Libera los locks al terminar la transmisión.
  static Future<void> releaseCastLocks() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('releaseCastLocks');
    } catch (e) {
      debugPrint('TvPlatform: releaseCastLocks falló: $e');
    }
  }
}
