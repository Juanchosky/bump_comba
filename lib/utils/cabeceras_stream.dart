import '../services/premium_service.dart';

/// Las cabeceras HTTP con las que se pide vídeo, compartidas.
///
/// POR QUE IMPORTAN, Y NO SON RELLENO
/// El reproductor del televisor las mandaba VACIAS y el mismo título que en el
/// teléfono arranca en menos de 10 s tardaba 40 o 50 en la tele. Dos de ellas
/// explican la diferencia:
///
///  · `X-Bump-Tier` es el carril de ancho de banda del VPS
///    (ver `vps/nginx-cache-vod.conf`). Sin ella, una reproducción premium cae
///    en el carril de los gratuitos y compite con la ráfaga de precarga.
///  · `User-Agent` y `Referer`: hay proveedores que estrangulan —o rechazan—
///    las peticiones que llegan sin identificar.
///
/// Viven aquí y no dentro de una pantalla porque las usan el reproductor del
/// teléfono, el del televisor y TurboProxy. Si cada uno arma las suyas, tarde o
/// temprano una se queda corta y el síntoma —"va lento y no sé por qué"— no
/// apunta a ningún sitio.
/// Host del VPS propio. Solo a él se le manda el carril: a un proveedor externo
/// esa cabecera no le dice nada y solo añadiría ruido.
const String kVpsHost = '217.216.80.212';

/// Un `User-Agent` de navegador de escritorio.
///
/// No es por disimular: varios proveedores IPTV devuelven 403 o estrangulan a
/// los clientes que no reconocen, y el de Dart no está en sus listas.
const String kUserAgentPorDefecto =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// Cabeceras para pedir [url].
///
/// [userAgent] permite al teléfono seguir rotando el suyo, que es como sortea a
/// los proveedores que limitan por cliente.
Map<String, String> cabecerasParaStream(String url, {String? userAgent}) {
  String referer = '';
  String host = '';
  try {
    final uri = Uri.parse(url);
    host = uri.host;
    referer = '${uri.scheme}://${uri.host}/';
  } catch (_) {}

  return <String, String>{
    'User-Agent': userAgent ?? kUserAgentPorDefecto,
    if (host == kVpsHost) 'X-Bump-Tier': PremiumService().isPremium ? 'p' : 'f',
    'Accept': '*/*',
    // Sin 'br': algunos proxies M3U fallan con brotli.
    'Accept-Encoding': 'gzip, deflate',
    'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
    'Connection': 'keep-alive',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
    if (referer.isNotEmpty) 'Referer': referer,
    'Origin': referer.isEmpty ? '' : referer.replaceAll(RegExp(r'/$'), ''),
    'Icy-MetaData': '1',
  }..removeWhere((k, v) => v.isEmpty);
}
