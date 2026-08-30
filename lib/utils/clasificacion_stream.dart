/// Decide si una URL es de emisión EN VIVO o de contenido bajo demanda (VOD).
///
/// POR QUE ESTO VIVE EN UN SOLO SITIO
/// La regla estaba copiada en dos lugares —el catálogo y el reproductor— y
/// escrita distinto en cada uno (`endsWith('.m3u8')` frente a
/// `contains('.m3u8')`). Dos copias de una regla delicada es una que tarde o
/// temprano se corrige a medias.
///
/// POR QUE IMPORTA TANTO ACERTAR
/// La etiqueta no es cosmética: decide si el televisor recibe la película a
/// través de TurboProxy o pide la URL del proveedor directamente. Y el
/// proveedor trunca cada respuesta HTTP en ~104 KB, asi que una película de
/// 2,3 GB pedida en directo son más de 22.000 reconexiones EN SERIE. Eso se ve
/// exactamente asi: la imagen se congela, el audio sigue por su cuenta con el
/// búfer que ya tenía, y después el vídeo corre para alcanzarlo. Un VOD mal
/// etiquetado como directo es, en la práctica, un título que no se puede ver.
///
/// LA REGLA
/// Una ruta de catálogo (`/movie/`, `/series/`, `/vod/`) es prueba POSITIVA de
/// que hay un archivo detrás, y manda sobre cualquier otra señal. El heurístico
/// viejo no la miraba: veía el `.m3u8` del final y daba el título por directo,
/// aunque la URL dijera `/movie/` con todas sus letras. Los proveedores Xtream
/// sirven muchísimo VOD como `/movie/usuario/clave/12345.m3u8`.
///
/// Solo cuando no hay ninguna pista de catálogo se recurre al `.m3u8`, que por
/// sí solo no distingue nada: es el envoltorio de las dos cosas.
bool esEnVivoPorUrl(String url) {
  final u = url.toLowerCase();

  // 1. Ruta de catálogo: hay un archivo detrás. No es directo, se ponga como
  //    se ponga la extensión.
  if (u.contains('/movie/') ||
      u.contains('/movies/') ||
      u.contains('/series/') ||
      u.contains('/vod/')) {
    return false;
  }

  // 2. Ruta de directo declarada.
  if (u.contains('/live/') || u.contains('type=live')) return true;

  // 3. Sin pistas: un .m3u8 suelto se trata como directo. Es la suposición
  //    prudente para un canal, y aquí ya sabemos que no hay ruta de catálogo
  //    que la contradiga.
  return u.contains('.m3u8');
}
