import '../models/m3u_item.dart';

/// Los motivos para reportar un título, compartidos por la ficha del teléfono
/// y la del televisor: los reportes llegan a la misma tabla
/// (`content_reports`), y si cada pantalla escribiera los suyos, el mismo
/// problema llegaría con dos textos distintos.
///
/// [tieneEpisodios]: la ficha ya cargó capítulos. Es la señal más fiable de
/// que es una serie, por encima de la categoría.
List<String> motivosReporte(M3UItem item, {bool tieneEpisodios = false}) {
  final cat = item.category.toLowerCase();
  final esSerie =
      item.isSeries ||
      tieneEpisodios ||
      cat.contains('serie') ||
      cat.contains('anime') ||
      cat.contains('dorama') ||
      cat.contains('novela') ||
      cat.contains('show');

  return [
    'No carga el video',
    'Se traba / Mucho buffering',
    if (esSerie)
      'Serie desactualizada (faltan capítulos / temporadas)'
    else
      'Contenido desactualizado / Nueva versión',
    'Audio desincronizado / Sin audio',
    'Subtítulos faltantes o mal sincronizados',
    'El contenido no corresponde al título',
    'Mala calidad de imagen',
    'Carátula en mala calidad',
    'Otro problema',
  ];
}
