import '../models/m3u_item.dart';

/// El pool del que sale el banner principal, en el telefono y en el televisor.
///
/// Vivia copiado en las dos pantallas —el televisor decia literalmente
/// "copiado del telefono"— y cada copia se fue tocando por su lado. Aqui se
/// decide una vez.
///
/// Es el RESPALDO: manda siempre el banner de tendencias de TMDB
/// (`getTrendingBannerItems()`), y esto solo entra mientras ese no ha llegado
/// o en las secciones donde una tendencia global no pinta nada.
///
/// Que hace:
///
///  1. QUITA lo que no es pelicula ni serie. Un canal en la portada no es un
///     descuido menor.
///
///  2. AGRUPA POR AÑO, leido del titulo: el catalogo no trae el año en un
///     campo aparte.
///
///  3. SE QUEDA SOLO CON LOS DOS AÑOS MAS RECIENTES (el actual y el anterior),
///     y pesa triple el actual. Antes sumaba años hacia atras hasta juntar
///     diez titulos, y en un catalogo donde pocos titulos llevan el año en el
///     nombre eso significaba llegar a los noventa: la portada acababa
///     enseñando cine viejo. Si con ese corte no quedan ni tres titulos, se
///     abre la mano año a año, porque un banner vacio es peor.
List<M3UItem> heroPoolPorAnio(List<M3UItem> origen, {DateTime? ahora}) {
  final validos =
      origen.where((i) => !i.isLive).where((i) {
        final n = i.name.toLowerCase();
        return !n.contains('canal ') &&
            !n.contains('tv ') &&
            !n.contains('en vivo');
      }).toList();
  if (validos.isEmpty) return const [];

  final porAnio = <int, List<M3UItem>>{};
  final reAnio = RegExp(r'(\d{4})');
  for (final item in validos) {
    // El ULTIMO año del titulo: "48 Horas (1982) [Resampled 2024]" es del 82
    // como pelicula, pero el dato de detras es el que el proveedor acaba de
    // tocar. Se mantiene el criterio que ya habia.
    final coincidencias = reAnio.allMatches(item.name);
    if (coincidencias.isEmpty) continue;
    final anio = int.tryParse(coincidencias.last.group(1) ?? '');
    if (anio == null || anio < 1950 || anio > 2100) continue;
    porAnio.putIfAbsent(anio, () => []).add(item);
  }
  if (porAnio.isEmpty) return validos;

  final anioActual = (ahora ?? DateTime.now()).year;
  // Un año futuro mal escrito en un titulo no debe mandar sobre el corte.
  final anios =
      porAnio.keys.where((a) => a <= anioActual + 1).toList()
        ..sort((a, b) => b.compareTo(a));
  if (anios.isEmpty) return validos;

  // Cuantos años hacia atras se aceptan. Se empieza en dos —este y el
  // pasado— y solo se amplia si no hay material.
  var corte = 2;
  List<M3UItem> construir(int cuantosAnios) {
    final pool = <M3UItem>[];
    var unicos = 0;
    for (var i = 0; i < anios.length && i < cuantosAnios; i++) {
      final delAnio = porAnio[anios[i]]!;
      unicos += delAnio.length;
      if (i == 0) {
        for (final item in delAnio) {
          pool
            ..add(item)
            ..add(item)
            ..add(item);
        }
      } else {
        pool.addAll(delAnio);
      }
    }
    return unicos >= 3 ? pool : const [];
  }

  var pool = construir(corte);
  while (pool.isEmpty && corte < anios.length) {
    corte++;
    pool = construir(corte);
  }
  if (pool.isEmpty) pool = construir(anios.length);
  return pool.isEmpty ? validos : pool;
}
