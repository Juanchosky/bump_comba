/// Deja el título de un proveedor en algo que TMDB pueda encontrar.
///
/// POR QUÉ HACE FALTA
/// Los nombres llegan así: "Spider Man - Un Nuevo Día (HDTS) (2026)". Con la
/// marca de calidad y el año pegados, TMDB no devuelve nada — y no es un fallo
/// de TMDB: le estamos pasando un nombre que no existe.
///
/// POR QUÉ VIVE AQUÍ Y NO DENTRO DE UNA PANTALLA
/// Estaba dentro de la ficha del televisor, privado. El destacado del catálogo
/// buscaba con el título CRUDO y por eso casi nunca encontraba nada: sin
/// resultado no hay imagen apaisada, y el destacado salía sobre el fondo de la
/// app, que estirado se ve pixelado. Dos pantallas que preguntan lo mismo a
/// TMDB tienen que preguntarlo igual.
library;

/// Marcas de calidad, año entre paréntesis y corchetes del proveedor.
final RegExp _basura = RegExp(
  r'\((?:HDTS|CAM|TS|HDRIP|BRRIP|WEBRIP|WEB-?DL|HD|SD|4K|FHD|UHD|LAT|CAST|'
  r'SUB|VOSE|DUAL|REMUX|BLURAY|DVDRIP|SCREENER|LINE)\)|\[[^\]]*\]|'
  r'(?:19|20)\d{2}|\(\s*\)',
  caseSensitive: false,
);

/// El año NO se pierde del todo: `searchAndGetDetails` lo extrae por su cuenta
/// del texto original para afinar la búsqueda.
String limpiarTituloParaTmdb(String bruto) {
  var t = bruto.replaceAll(_basura, ' ');
  // Los paréntesis que quedan vacíos tras vaciar su contenido.
  t = t.replaceAll(RegExp(r'\(\s*\)'), ' ');
  // Separadores del proveedor: barras verticales, puntos medios.
  t = t.replaceAll(RegExp(r'\s*[|·]\s*'), ' ');
  t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  // Un guion suelto al final no aporta y estorba a la búsqueda.
  t = t.replaceAll(RegExp(r'\s*-\s*$'), '').trim();
  return t.isEmpty ? bruto : t;
}
