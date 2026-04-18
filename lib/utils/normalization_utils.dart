class NormalizationUtils {
  /// Limpia una URL de fragmentos de tiempo (#t=...) y parámetros de búsqueda comunes.
  static String cleanUrl(String url) {
    if (url.isEmpty) return url;
    try {
      final uri = Uri.parse(url);
      if (!uri.hasQuery && !uri.hasFragment) return url;

      String cleaned = url.split('#')[0]; // Quitar fragmento
      final innerUri = Uri.parse(cleaned);

      if (innerUri.queryParameters.isEmpty) return cleaned;

      // Filtrar parámetros de tiempo conocidos
      final Map<String, String> newParams = Map<String, String>.from(
        innerUri.queryParameters,
      );
      const timeParams = ['t', 'time', 'start', 'at', 'position'];
      for (final p in timeParams) {
        newParams.remove(p);
      }

      if (newParams.isEmpty) {
        return innerUri.replace(query: '').toString().replaceAll('?', '');
      }

      return innerUri.replace(queryParameters: newParams).toString();
    } catch (_) {
      // Fallback regex si Uri.parse falla
      return url.replaceFirst(
        RegExp(r'[#&?](t|time|start|at|position)=\d+[smh]?.*$'),
        '',
      );
    }
  }

  /// Normaliza el nombre de una categoría: Primera mayúscula, resto minúsculas,
  /// y elimina etiquetas técnicas comunes ([HD], CAM, etc).
  static String normalizeCategory(String category) {
    if (category.isEmpty) return 'Sin categoría';

    // 1. Limpieza básica
    String result = category.trim();

    // 2. Eliminar etiquetas comunes entre corchetes o paréntesis
    result = result.replaceAll(RegExp(r'\[.*?\]'), '').replaceAll(RegExp(r'\(.*?\)'), '');

    // 3. Eliminar términos técnicos sueltos
    result = result.replaceAll(
      RegExp(
        r'\b(cam|ts|tc|hd|4k|uhd|fhd|sd|dual|multi|latino|sub|subtitulado|line|scr|full hd|movies|vod)\b',
        caseSensitive: false,
      ),
      '',
    );

    // 4. Limpiar espacios dobles generados por los reemplazos
    result = result.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (result.isEmpty) return 'General';

  /// Title Case: Primera Mayúscula, demás minúsculas
    return result[0].toUpperCase() + result.substring(1).toLowerCase();
  }

  /// Normaliza agresivamente el nombre de una serie para búsqueda e indexación.
  /// Elimina años, etiquetas [HD], símbolos y normaliza espacios.
  static String normalizeSeriesName(String name) {
    if (name.isEmpty) return '';

    String result = name.toLowerCase();

    // 1. Eliminar años entre paréntesis o solos (ej: (2024), 2023)
    result = result.replaceAll(RegExp(r'[\(\[\{]?\b(19|20)\d{2}\b[\)\]\}]?'), '');

    // 2. Eliminar etiquetas de calidad y técnicas
    result = result.replaceAll(
      RegExp(r'\b(4k|uhd|fhd|hd|sd|720p|1080p|latino|castellano|español|multi|sub|scr|cam|ts)\b'),
      '',
    );

    // 3. Eliminar caracteres especiales (excepto espacios)
    result = _removeDiacritics(result).replaceAll(RegExp(r'[^a-z0-9\s]'), '');

    // 4. Limpiar espacios extra
    result = result.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 5. Eliminar prefijos comunes redundantes (opcional pero reduce ruido)
    result = result.replaceFirst(RegExp(r'^(the|tv series|series|serie)\s+'), '');

    return result;
  }

  static String _removeDiacritics(String str) {
    const withDia =
        'ÀÁÂÃÄÅàáâãäåÒÓÔÕÕÖØòóôõöøÈÉÊËèéêëðÇçÐÌÍÎÏìíîïÙÚÛÜùúûüÑñŠšŸÿýŽž';
    const withoutDia =
        'AAAAAAaaaaaaOOOOOOOooooooEEEEeeeeecCcDIIIIiiiiUUUUuuuuNnSsYyyZz';
    for (int i = 0; i < withDia.length; i++) {
       str = str.replaceAll(withDia[i], withoutDia[i]);
    }
    return str;
  }
}
