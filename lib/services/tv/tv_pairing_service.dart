import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../m3u_service.dart';

/// Cliente de la vinculación de televisores, para los DOS lados.
///
/// El televisor enseña un código; el teléfono, que es donde vive la
/// suscripción, lo escribe. A cambio el televisor recibe un token y ya no
/// vuelve a pedir nada.
///
/// AQUÍ NO SE DECIDE NADA.
/// Todas las respuestas vienen de la Edge Function `tv-pairing`. Este archivo
/// acaba dentro de un APK que se reparte a mano, así que cualquier
/// comprobación que hiciera por su cuenta sería una comprobación que el
/// primer curioso con el APK descompilado puede quitar. Lo único que guarda es
/// el token, y un token robado se revoca desde el teléfono.
class TvPairingService {
  TvPairingService._();
  static final TvPairingService instance = TvPairingService._();

  static const String _kToken = 'tv_pairing_token';
  static const String _kDeviceId = 'tv_pairing_device_id';

  /// URL base del proyecto. Se inyecta al arrancar para no repetir las
  /// credenciales en un tercer sitio, con fallback a las públicas compiladas.
  static String? _baseUrl = M3UService.supabaseUrlPublica;
  static String? _anonKey = M3UService.supabaseAnonKeyPublica;

  static void configurar({required String url, required String anonKey}) {
    _baseUrl = url;
    _anonKey = anonKey;
  }

  Uri get _endpoint => Uri.parse('$_baseUrl/functions/v1/tv-pairing');

  // ── Identidad del aparato ────────────────────────────────────────────────
  //
  // Un identificador propio guardado en disco, NO el del hardware.
  //
  // El de hardware sería más estable, pero es un dato del aparato que no nos
  // hace falta para nada: aquí solo se necesita distinguir "este televisor" de
  // "otro televisor". Un número al azar hace ese trabajo igual de bien, y si
  // el usuario desinstala la app se va con ella.
  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final guardado = prefs.getString(_kDeviceId);
    if (guardado != null && guardado.isNotEmpty) return guardado;

    final nuevo =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '-${(identityHashCode(Object()) & 0x7fffffff).toRadixString(36)}';
    await prefs.setString(_kDeviceId, nuevo);
    return nuevo;
  }

  Future<String?> tokenGuardado() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString(_kToken);
    return (t == null || t.isEmpty) ? null : t;
  }

  Future<void> _guardarToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, token);
  }

  Future<void> olvidarToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
  }

  // ── Llamada ──────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>?> _llamar(Map<String, dynamic> cuerpo) async {
    if (_baseUrl == null || _anonKey == null) {
      debugPrint('TvPairing: sin configurar (falta configurar())');
      return null;
    }
    try {
      final rs = await http
          .post(
            _endpoint,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_anonKey',
              'apikey': _anonKey!,
            },
            body: jsonEncode(cuerpo),
          )
          .timeout(const Duration(seconds: 12));

      if (rs.statusCode >= 500) {
        debugPrint('TvPairing: servidor ${rs.statusCode}');
        return null;
      }
      return jsonDecode(rs.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('TvPairing: fallo de red: $e');
      return null;
    }
  }

  // ── Lado TELEVISOR ───────────────────────────────────────────────────────

  /// Pide (o recupera) el código que se enseña en pantalla.
  Future<({String codigo, DateTime expira})?> pedirCodigo({
    String? nombreAparato,
  }) async {
    final r = await _llamar({
      'accion': 'crear',
      'deviceId': await deviceId(),
      if (nombreAparato != null) 'deviceName': nombreAparato,
    });
    final codigo = r?['code'] as String?;
    final expira = r?['expiraEn'] as String?;
    if (codigo == null || expira == null) return null;
    return (codigo: codigo, expira: DateTime.parse(expira));
  }

  /// Consulta si ya lo canjearon. Si sí, guarda el token y devuelve `vinculado`.
  Future<String> consultarEstado(String codigo) async {
    final r = await _llamar({
      'accion': 'estado',
      'code': codigo,
      'deviceId': await deviceId(),
    });
    final estado = r?['estado'] as String? ?? 'error';
    if (estado == 'vinculado') {
      final token = r?['token'] as String?;
      if (token != null && token.isNotEmpty) {
        await _guardarToken(token);
      } else {
        // Vinculado sin token es un estado imposible; tratarlo como error
        // evita dar por buena una vinculación que no se puede usar.
        return 'error';
      }
    }
    return estado;
  }

  /// Comprueba al arrancar que el token sigue valiendo.
  ///
  /// Devuelve `null` cuando no se pudo preguntar (sin red, servidor caído).
  /// Eso NO es lo mismo que "no tienes derecho", y quien llame debe
  /// distinguirlo: cortarle el acceso a un usuario de pago porque su wifi va
  /// mal sería peor que el problema que esto resuelve.
  Future<bool?> validarToken() async {
    final token = await tokenGuardado();
    if (token == null) return false;

    final r = await _llamar({'accion': 'validar', 'token': token});
    if (r == null) return null;

    // Las fuentes llegan aqui, en cada arranque, no solo al vincular. Asi un
    // cambio de proveedor en el telefono alcanza al televisor solo.
    final fuentes = r['sources'];
    if (fuentes is String && fuentes.isNotEmpty) {
      await M3UService().importarFuentes(fuentes);
    }

    if (r['ok'] == true) return true;

    final motivo = r['motivo'] as String?;

    // NO TODO "ok: false" SIGNIFICA "no tienes derecho".
    //
    // El servidor devuelve lo mismo cuando no hay suscripcion que cuando no
    // pudo PREGUNTARLE a RevenueCat. Tratarlos igual es lo que dejaba fuera a
    // un usuario de pago porque la API de RevenueCat tuvo un mal minuto: se le
    // cerraba el televisor y volvia a la pantalla de vincular.
    //
    // Solo estos tres son un NO de verdad; cualquier otra cosa es "no se pudo
    // comprobar" y se conserva el acceso, que se revalida en el proximo
    // arranque de todas formas.
    const definitivos = {
      'token_desconocido',
      'revocado',
      'sin_suscripcion_activa',
    };
    if (!definitivos.contains(motivo)) {
      debugPrint('TvPairing: no se pudo comprobar ($motivo); se conserva');
      return null;
    }

    // El token se borra en tres casos: el aparato ya no existe, fue revocado
    // desde el telefono, o la suscripcion ha caducado. Al vencer el premium el
    // televisor SE DESVINCULA —vuelve a la pantalla de emparejar— y hay que
    // volver a canjear un codigo despues de renovar. `sin_suscripcion_activa`
    // solo llega cuando el servidor pudo confirmar con RevenueCat que no hay
    // plan; los fallos al comprobar caen mas arriba, en `definitivos`, y
    // conservan el acceso.
    if (motivo == 'token_desconocido' ||
        motivo == 'revocado' ||
        motivo == 'sin_suscripcion_activa') {
      await olvidarToken();
    }
    return false;
  }

  // ── Lado TELÉFONO ────────────────────────────────────────────────────────

  /// Canjea el código que el usuario ha leído en el televisor.
  Future<({bool ok, String? motivo, int? max})> canjear({
    required String codigo,
    required String userRef,
    String userKind = 'revenuecat',
  }) async {
    // Se manda la configuracion de fuentes junto con el canje. Sin ella el
    // televisor queda vinculado pero con el catalogo vacio, que para el usuario
    // se ve igual que si no hubiera funcionado.
    String? fuentes;
    try {
      fuentes = M3UService().exportarFuentes();
    } catch (e) {
      debugPrint('TvPairing: no se pudieron exportar las fuentes: $e');
    }

    final r = await _llamar({
      'accion': 'canjear',
      'code': codigo.trim().toUpperCase(),
      'userRef': userRef,
      'userKind': userKind,
      if (fuentes != null) 'sources': fuentes,
    });
    if (r == null) return (ok: false, motivo: 'sin_conexion', max: null);
    return (
      ok: r['ok'] == true,
      motivo: r['motivo'] as String?,
      max: (r['max'] as num?)?.toInt(),
    );
  }

  Future<({List<Map<String, dynamic>> lista, int max})> listarTelevisores(
    String userRef,
  ) async {
    final r = await _llamar({'accion': 'listar', 'userRef': userRef});
    final lista =
        (r?['dispositivos'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    return (lista: lista, max: (r?['max'] as num?)?.toInt() ?? 2);
  }

  Future<bool> revocar({required String userRef, required String id}) async {
    final r = await _llamar({
      'accion': 'revocar',
      'userRef': userRef,
      'id': id,
    });
    return r?['ok'] == true;
  }

  /// Texto para el usuario a partir del motivo que devuelve el servidor.
  ///
  /// Cada uno dice qué hacer a continuación. "Error" a secas deja al usuario
  /// sin saber si el problema es suyo, del código o de la app.
  static String explicar(String? motivo, {int? max}) {
    switch (motivo) {
      case 'codigo_invalido':
        return 'Ese código no existe. Revísalo en la pantalla del televisor.';
      case 'codigo_caducado':
        return 'El código ha caducado. Genera uno nuevo en el televisor.';
      case 'codigo_ya_usado':
        return 'Ese código ya se usó. Genera uno nuevo en el televisor.';
      case 'demasiados_intentos':
        return 'Demasiados intentos con ese código. Genera uno nuevo en el '
            'televisor.';
      case 'limite_dispositivos':
        return 'Ya tienes ${max ?? 2} televisores vinculados. Quita uno antes '
            'de añadir otro.';
      case 'sin_suscripcion_activa':
      case 'no_premium':
        return 'Necesitas una suscripción activa para ver el contenido en el '
            'televisor.';
      case 'sin_conexion':
        return 'No hay conexión con el servidor. Inténtalo de nuevo.';
      case 'servidor_sin_configurar':
      case 'revenuecat_error':
        return 'No pudimos comprobar tu suscripción ahora mismo. Inténtalo en '
            'unos minutos.';
      default:
        return 'No se pudo vincular el televisor.';
    }
  }
}
