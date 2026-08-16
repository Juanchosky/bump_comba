import 'dart:convert';

class NormalizationUtils {
  // ── Regex precompiladas ───────────────────────────────────────────────────
  // PERF: antes se construian con RegExp(...) DENTRO de cada funcion, asi que
  // se recompilaban en cada llamada. Con ~32.000 items por carga eso son
  // cientos de miles de compilaciones y era una parte importante del tiempo
  // de indexado. Declaradas aqui se compilan una sola vez.
  static final RegExp _reUhd = RegExp(r'\buhd\b', caseSensitive: false);
  static final RegExp _reUrlTime =
      RegExp(r'[#&?](t|time|start|at|position)=\d+[smh]?.*$');
  static final RegExp _reBrackets = RegExp(r'\[.*?\]');
  static final RegExp _reParens = RegExp(r'\(.*?\)');
  static final RegExp _reCatTags = RegExp(
    r'\b(cam|ts|tc|hd|4k|uhd|fhd|sd|dual|multi|latino|sub|subtitulado|line|scr|full hd|movies|vod)\b',
    caseSensitive: false,
  );
  static final RegExp _reSpaces = RegExp(r'\s+');
  static final RegExp _reYear = RegExp(r'[\(\[\{]?\b(19|20)\d{2}\b[\)\]\}]?');
  static final RegExp _reQualityTags = RegExp(
    r'\b(4k|uhd|fhd|hd|sd|720p|1080p|latino|castellano|español|multi|sub|scr|cam|ts)\b',
  );
  static final RegExp _reNonAlnum = RegExp(r'[^a-z0-9\s]');
  static final RegExp _rePrefixes = RegExp(r'^(the|tv series|series|serie)\s+');
  static final RegExp _reEpMarker = RegExp(
    r'\b(S\d+E\d+|S\d+\s+E\d+|\d+x\d+|Capitulo\s*\d+|Episodio\s*\d+|Episode\s*\d+|Ep\.\s*\d+|Cap\s*\d+|E\d+|Cap.\s*\d+)\b',
    caseSensitive: false,
  );
  static final RegExp _reLeadSep = RegExp(r'^[:\s\-–—|]+');
  static final List<RegExp> _reEpisodeNums = [
    RegExp(r'\bS\d+E(\d+)\b', caseSensitive: false),
    RegExp(r'\bE(\d+)\b', caseSensitive: false),
    RegExp(
      r'\b(?:Cap|Capitulo|Episodio|Episode|Cap\.|Ep\.)\s*(\d+)\b',
      caseSensitive: false,
    ),
    RegExp(r'\d+x(\d+)\b', caseSensitive: false),
  ];

  /// Detecta si un título o categoría corresponde a contenido 4K / UHD / 2160p.
  static bool is4kTitle(String name) {
    if (name.isEmpty) return false;
    final n = name.toLowerCase();
    if (n.contains('4k') || n.contains('4 k') || n.contains('2160p')) return true;
    if (_reUhd.hasMatch(n)) return true;
    return false;
  }
  /// Repara cadenas con codificación UTF-8 doble / Mojibake (garabatos raros).
  /// Ej: "algÃºn" -> "algún", "SuperaciÃ³n" -> "Superación", "Â¿" -> "¿".
  static String fixMojibake(String input) {
    if (input.isEmpty) return input;
    if (!input.contains('Ã') && !input.contains('Â')) return input;

    String text = input;

    // Intentar re-decodificar Latin1 a UTF8 si la cadena completa es Latin1 mal interpretado
    try {
      final latin1Bytes = latin1.encode(text);
      final decoded = utf8.decode(latin1Bytes, allowMalformed: false);
      if (decoded.isNotEmpty &&
          !decoded.contains('Ã') &&
          !decoded.contains('Â')) {
        return decoded;
      }
    } catch (_) {}

    // Tabla de reemplazo directa para secuencias Mojibake UTF-8 dobles
    final Map<String, String> replacements = {
      'Ã¡': 'á',
      'Ã©': 'é',
      // OJO: \xAD es un guion suave invisible. Escribirlo literal ('Ã­')
      // produce la MISMA clave y el analizador lo marcaba como duplicada.
      'Ã\xAD': 'í',
      'Ã³': 'ó',
      'Ãº': 'ú',
      'Ã±': 'ñ',
      'Ã‘': 'Ñ',
      'Ã\x81': 'Á',
      'Ã\x89': 'É',
      'Ã\x8D': 'Í',
      'Ã\x93': 'Ó',
      'Ã\x9A': 'Ú',
      'Ã¼': 'ü',
      'ÃÜ': 'Ü',
      'Â¿': '¿',
      'Â¡': '¡',
      'Ã§': 'ç',
      'Ã‡': 'Ç',
      'Ã¢': 'â',
      'Ãª': 'ê',
      'Ã®': 'î',
      'Ã´': 'ô',
      'Ã»': 'û',
      'Ã°': 'ú',
      'Â°': 'º',
      'Â³': '³',
      'Âª': 'ª',
      'Â': '',
    };

    replacements.forEach((bad, good) {
      text = text.replaceAll(bad, good);
    });

    return text;
  }

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
        _reUrlTime,
        '',
      );
    }
  }

  /// Normaliza el nombre de una categoría: Primera mayúscula, resto minúsculas,
  /// y elimina etiquetas técnicas comunes ([HD], CAM, etc).
  static String normalizeCategory(String category) {
    if (category.isEmpty) return 'Sin categoría';

    // 1. Limpieza básica y reparación de garabatos (Mojibake)
    String result = fixMojibake(category.trim());

    // 2. Eliminar etiquetas comunes entre corchetes o paréntesis
    result = result
        .replaceAll(_reBrackets, '')
        .replaceAll(_reParens, '');

    // 3. Eliminar términos técnicos sueltos
    result = result.replaceAll(_reCatTags, '');

    // 4. Limpiar espacios dobles generados por los reemplazos
    result = result.replaceAll(_reSpaces, ' ').trim();

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
    result = result.replaceAll(_reYear, '');

    // 2. Eliminar etiquetas de calidad y técnicas
    result = result.replaceAll(_reQualityTags, '');

    // 3. Eliminar caracteres especiales (excepto espacios)
    result = _removeDiacritics(result).replaceAll(_reNonAlnum, '');

    // 4. Limpiar espacios extra
    result = result.replaceAll(_reSpaces, ' ').trim();

    // 5. Eliminar prefijos comunes redundantes (opcional pero reduce ruido)
    result = result.replaceFirst(_rePrefixes, '');

    return result;
  }

  /// Extrae el título específico de un episodio eliminando el nombre de la serie
  /// y los marcadores de temporada/episodio (S01E01, etc).
  /// Retorna un String vacío si no se detecta el formato esperado para limpieza.
  static String extractEpisodeTitle(String fullName) {
    if (fullName.isEmpty) return '';

    // 1. Intentar encontrar marcadores comunes SXXEXX o NXN
    final match = _reEpMarker.firstMatch(fullName);
    if (match != null) {
      String titlePart = fullName.substring(match.end).trim();
      // Limpiar separadores líderes como " - ", ": ", etc.
      titlePart = titlePart.replaceFirst(_reLeadSep, '').trim();
      if (titlePart.isNotEmpty) return titlePart;
    }

    // No se detectó marcador o no hay título después, retornamos vacío para
    // indicar que no hubo limpieza y se debe usar el nombre original.
    return '';
  }

  /// Tenta extraer el número de episodio de un nombre de string si el objeto
  /// no lo tiene definido.
  static int? parseEpisodeNumber(String fullName) {
    if (fullName.isEmpty) return null;

    // Patrones comunes: E16, Cap 16, Episodio 16, 1x16, etc.
    for (final pattern in _reEpisodeNums) {
      final match = pattern.firstMatch(fullName);
      if (match != null && match.groupCount >= 1) {
        final val = int.tryParse(match.group(1)!);
        if (val != null) return val;
      }
    }
    return null;
  }

  /// Formatea una duración (en segundos o formato HH:MM:SS) a un formato amigable (ej: 44m, 1h 20m).
  static String formatDuration(dynamic rawDuration) {
    if (rawDuration == null) return '';

    int totalSeconds = 0;

    if (rawDuration is int) {
      totalSeconds = rawDuration;
    } else if (rawDuration is String) {
      if (rawDuration.isEmpty) return '';
      // Manejar "HH:MM:SS"
      final parts = rawDuration.split(':');
      if (parts.length == 3) {
        final h = int.tryParse(parts[0]) ?? 0;
        final m = int.tryParse(parts[1]) ?? 0;
        final s = int.tryParse(parts[2]) ?? 0;
        totalSeconds = h * 3600 + m * 60 + s;
      } else if (parts.length == 2) {
        final m = int.tryParse(parts[0]) ?? 0;
        final s = int.tryParse(parts[1]) ?? 0;
        totalSeconds = m * 60 + s;
      } else {
        totalSeconds = int.tryParse(rawDuration) ?? 0;
      }
    }

    if (totalSeconds <= 0) return '';

    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;

    if (h > 0) {
      if (m > 0) {
        return '${h}h ${m}m';
      }
      return '${h}h';
    } else {
      return '${m}m';
    }
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
