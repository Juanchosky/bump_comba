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

/// Cuantos titulos de la CABEZA del banner entran en el sorteo.
///
/// `getTrendingBannerItems()` devuelve la lista ya ordenada: primero lo que
/// TMDB marca como tendencia esta semana, y detras el relleno por año de
/// estreno. Sortear sobre los quince acababa sacando la cola, que es lo mas
/// viejo que entro.
const int cabezaDelBanner = 6;

/// La semilla de la SESION: se sortea una vez al arrancar la app y no cambia
/// mientras la app vive.
///
/// No es por dia a proposito. Con la semilla del dia el destacado era siempre
/// el mismo titulo durante 24 horas —abrias y cerrabas y ahi seguia South
/// Park—, y eso se ve peor que el problema que venia a arreglar. Y no es
/// aleatoria en cada llamada porque entonces vuelve el fallo de origen: cada
/// sitio que elige el destacado sacaria un titulo distinto del mismo pool y la
/// portada se cambiaria sola al segundo.
///
/// Por sesion: cada vez que abres la app hay otro destacado, pero MIENTRAS la
/// usas no se mueve y el telefono y el televisor coinciden.
final int _semillaDeSesion = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;

int semillaDeSesion() => _semillaDeSesion;

/// El destacado del banner de tendencias.
///
/// DETERMINISTA A PROPOSITO. Antes cada sitio que lo elegia hacia su propio
/// `DateTime.now().microsecond % pool.length`, y habia TRES: el que pinta el
/// banner durante el build, el que responde a `notifyListeners()` cuando llega
/// TMDB, y el del televisor. Con el mismo pool daban titulos DISTINTOS, asi que
/// la portada enseñaba un titulo y al segundo se cambiaba sola por otro. Con la
/// semilla del dia, el mismo pool da siempre el mismo titulo: el cambio que
/// queda es uno solo —el respaldo dando paso a la tendencia— y el telefono y el
/// televisor coinciden.
M3UItem? destacadoDeTendencia(List<M3UItem> pool) {
  final lista = destacadosDeTendencia(pool, 1);
  return lista.isEmpty ? null : lista.first;
}

/// Los `cuantos` destacados del mosaico del televisor, con el mismo criterio
/// y la misma semilla que el banner del telefono.
///
/// Sin caratula no entra —un hueco gris en la portada se ve roto— y no se
/// repite el mismo titulo (una serie cuenta por su nombre de serie).
List<M3UItem> destacadosDeTendencia(List<M3UItem> pool, int cuantos) {
  if (pool.isEmpty || cuantos <= 0) return const [];

  // SIN REPETIDOS ANTES DE CORTAR LA CABEZA. `heroPoolPorAnio` mete el año mas
  // reciente TRES VECES para darle peso, asi que los seis primeros de ese pool
  // pueden ser dos titulos repetidos: el sorteo se quedaba sin variedad justo
  // en el televisor, que es quien usa ese pool en las secciones. Se quita el
  // duplicado conservando el orden, y el peso sigue notandose porque lo del
  // año reciente sigue estando delante.
  final unicos = <M3UItem>[];
  final yaEsta = <String>{};
  for (final item in pool) {
    if (yaEsta.add(item.seriesName ?? item.name)) unicos.add(item);
  }

  // Se sortea entre la cabeza, pero si ahi no hay bastante con caratula se
  // sigue por el resto en ORDEN: lo de mas arriba es lo mas relevante.
  final cabeza =
      unicos.length > cabezaDelBanner
          ? unicos.take(cabezaDelBanner).toList()
          : unicos;

  final elegidos = <M3UItem>[];
  final vistos = <String>{};
  void agregar(M3UItem item) {
    if (elegidos.length >= cuantos) return;
    if (item.isLive || (item.logo ?? '').isEmpty) return;
    if (!vistos.add(item.seriesName ?? item.name)) return;
    elegidos.add(item);
  }

  var semilla = semillaDeSesion();
  for (var intento = 0; intento < cabeza.length * 3; intento++) {
    if (elegidos.length >= cuantos) break;
    agregar(cabeza[semilla.abs() % cabeza.length]);
    semilla = semilla * 31 + 17;
  }
  for (final item in unicos) {
    if (elegidos.length >= cuantos) break;
    agregar(item);
  }
  return elegidos;
}
