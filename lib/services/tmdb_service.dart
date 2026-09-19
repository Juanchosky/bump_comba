import 'dart:convert';
import 'package:http/http.dart' as http;

class TMDBService {
  static const String _apiKey = '4d1a1f42684a12a2fed02f05b35b4bb8';
  static const String _baseUrl = 'https://api.themoviedb.org/3';

  Future<Map<String, dynamic>> searchAndGetDetails(
    String query, {
    bool isSeries = false,
  }) async {
    try {
      // Clean query (extract year if present)
      String cleanQuery = query;
      String? year;

      // Regex to find year in parentheses or brackets like (2023) or [2023]
      final yearRegex = RegExp(r'[\(\[]?\b(19|20)\d{2}\b[\)\]]?');
      final match = yearRegex.firstMatch(query);
      if (match != null) {
        year = match.group(0)?.replaceAll(RegExp(r'[\(\)\[\]]'), '').trim();
        cleanQuery = query.replaceAll(match.group(0)!, '').trim();
      }

      // If cleaning left us with an empty string, fallback to original
      if (cleanQuery.isEmpty) cleanQuery = query;

      // 1. Search for the item
      final searchType = isSeries ? 'tv' : 'movie';
      String searchUrl =
          '$_baseUrl/search/$searchType?api_key=$_apiKey&query=${Uri.encodeComponent(cleanQuery)}&language=es-ES';

      if (year != null) {
        if (isSeries) {
          searchUrl += '&first_air_date_year=$year';
        } else {
          searchUrl += '&primary_release_year=$year';
        }
      }

      final searchResponse = await http.get(Uri.parse(searchUrl));

      if (searchResponse.statusCode != 200) return {};

      final searchData = json.decode(searchResponse.body);
      final results = searchData['results'] as List;
      if (results.isEmpty) {
        // Fallback: If no results with year, try searching without year filter and with original query
        if (year != null || cleanQuery != query) {
          final fallbackResponse = await http.get(
            Uri.parse(
              '$_baseUrl/search/$searchType?api_key=$_apiKey&query=${Uri.encodeComponent(query)}&language=es-ES',
            ),
          );
          if (fallbackResponse.statusCode == 200) {
            final fallbackData = json.decode(fallbackResponse.body);
            final fallbackResults = fallbackData['results'] as List;
            if (fallbackResults.isNotEmpty) {
              return await _getDetails(fallbackResults.first['id'], searchType);
            }
          }
        }
        return {};
      }

      return await _getDetails(results.first['id'], searchType);
    } catch (e) {
      print('Error fetching TMDB data: $e');
      return {};
    }
  }

  Future<String?> _sinopsisEnOtroIdioma(int id, String searchType) async {
    for (final idioma in const ['es-MX', 'en-US']) {
      try {
        final r = await http
            .get(
              Uri.parse(
                '$_baseUrl/$searchType/$id?api_key=$_apiKey&language=$idioma',
              ),
            )
            .timeout(const Duration(seconds: 5));
        if (r.statusCode != 200) continue;
        final texto = (json.decode(r.body)['overview'] ?? '').toString().trim();
        if (texto.isNotEmpty) return texto;
      } catch (_) {}
    }
    return null;
  }

  Future<Map<String, dynamic>> _getDetails(int id, String searchType) async {
    final append =
        searchType == 'tv'
            ? 'videos,content_ratings,credits'
            : 'videos,release_dates,credits';
    final detailsResponse = await http.get(
      Uri.parse(
        '$_baseUrl/$searchType/$id?api_key=$_apiKey&append_to_response=$append&language=es-ES',
      ),
    );

    if (detailsResponse.statusCode != 200) return {};

    final details = json.decode(detailsResponse.body);

    String overview = (details['overview'] ?? '').toString().trim();
    // Muchos títulos (anime, producciones latinas, estrenos recientes) no
    // tienen sinopsis en es-ES y la ficha salía vacía. Se prueba español de
    // México y, si tampoco, inglés. Solo cuando falta: el caso normal no hace
    // ninguna llamada de más.
    if (overview.isEmpty) {
      overview = await _sinopsisEnOtroIdioma(id, searchType) ?? '';
    }
    String? trailerUrl;

    // Find trailer in videos
    if (details['videos'] != null && details['videos']['results'] != null) {
      final videos = details['videos']['results'] as List;
      final trailer = videos.firstWhere(
        (v) => v['type'] == 'Trailer' && v['site'] == 'YouTube',
        orElse: () => videos.isNotEmpty ? videos.first : null,
      );
      if (trailer != null) {
        trailerUrl = 'https://www.youtube.com/watch?v=${trailer['key']}';
      }
    }

    // Extract Certification/Rating
    String? rating;
    if (searchType == 'tv') {
      if (details['content_ratings'] != null &&
          details['content_ratings']['results'] != null) {
        final results = details['content_ratings']['results'] as List;
        // Search for ES, then US, then anything
        final r = results.firstWhere(
          (e) => e['iso_3166_1'] == 'ES',
          orElse:
              () => results.firstWhere(
                (e) => e['iso_3166_1'] == 'US',
                orElse: () => results.isNotEmpty ? results.first : null,
              ),
        );
        if (r != null) rating = r['rating'];
      }
    } else {
      if (details['release_dates'] != null &&
          details['release_dates']['results'] != null) {
        final results = details['release_dates']['results'] as List;
        final country = results.firstWhere(
          (e) => e['iso_3166_1'] == 'ES',
          orElse:
              () => results.firstWhere(
                (e) => e['iso_3166_1'] == 'US',
                orElse: () => results.isNotEmpty ? results.first : null,
              ),
        );
        if (country != null && country['release_dates'] != null) {
          final dates = country['release_dates'] as List;
          // Find first non-empty certification
          final c = dates.firstWhere(
            (d) =>
                d['certification'] != null &&
                d['certification'].toString().isNotEmpty,
            orElse: () => null,
          );
          if (c != null) rating = c['certification'];
        }
      }
    }

    // Construct image URL helper
    String getImageUrl(String? path) {
      if (path == null || path.isEmpty) return '';
      return 'https://image.tmdb.org/t/p/w500$path';
    }

    // Extract Cast and Director/Creator
    String? cast;
    String? director;

    if (details['credits'] != null && details['credits']['cast'] != null) {
      final castList = details['credits']['cast'] as List;
      cast = castList.take(5).map((e) => e['name']).join(', ');
    }

    if (searchType == 'tv') {
      if (details['created_by'] != null) {
        final creators = details['created_by'] as List;
        director = creators.map((e) => e['name']).join(', ');
      }
      // Fallback to crew if created_by is empty
      if ((director == null || director.isEmpty) &&
          details['credits'] != null &&
          details['credits']['crew'] != null) {
        final crew = details['credits']['crew'] as List;
        final creators = crew
            .where(
              (e) => e['job'] == 'Executive Producer' || e['job'] == 'Director',
            )
            .take(2);
        if (creators.isNotEmpty) {
          director = creators.map((e) => e['name']).join(', ');
        }
      }
    } else {
      if (details['credits'] != null && details['credits']['crew'] != null) {
        final crew = details['credits']['crew'] as List;
        final d = crew.firstWhere(
          (e) => e['job'] == 'Director',
          orElse: () => null,
        );
        if (d != null) director = d['name'];
      }
    }

    return {
      'id': details['id'],
      'overview': overview,
      'trailer_url': trailerUrl,
      'poster_url': getImageUrl(details['poster_path']),
      'backdrop_url': getImageUrl(details['backdrop_path']),
      'release_date':
          searchType == 'tv'
              ? details['first_air_date']
              : details['release_date'],
      'vote_average': details['vote_average'],
      'rating': rating,
      'cast': cast,
      'director': director,
      // Titulo tal y como se llama en su idioma y pais de produccion: la ficha
      // del televisor los enseña en la linea de debajo del titulo, igual que
      // hacen las fichas de las apps de IPTV al uso.
      'original_title': details['original_title'] ?? details['original_name'],
      'country': _primerPais(details),
    };
  }

  /// Pais de produccion, en una sola palabra para la linea de la ficha.
  static String? _primerPais(Map<String, dynamic> details) {
    final paises = details['production_countries'];
    if (paises is List && paises.isNotEmpty) {
      final n = paises.first['name'];
      if (n is String && n.isNotEmpty) return n;
    }
    final origen = details['origin_country'];
    if (origen is List && origen.isNotEmpty) {
      final c = origen.first;
      if (c is String && c.isNotEmpty) return c;
    }
    return null;
  }

  /// Lo POPULAR de TMDB del año que se le pida, peliculas y series juntas.
  ///
  /// Existe porque la tendencia de la semana (`getTrendingTitles`) son 20
  /// titulos globales y de esos suelen estar en el catalogo tres o cuatro: la
  /// fila "Busqueda popular" se quedaba corta y habia que rellenarla con
  /// contenido local, que ya no es "popular". Esto da mucho mas material
  /// popular Y del año pedido, asi que el relleno local pasa a ser el ultimo
  /// recurso de verdad.
  ///
  /// `discover` ordenado por popularidad y acotado por año de estreno: es la
  /// unica forma de pedirle a TMDB "lo mas popular DE 2026" — `movie/popular`
  /// mezcla años sin control.
  Future<List<Map<String, String>>> getPopularTitlesForYear(int year) async {
    final urls = [
      '$_baseUrl/discover/movie?api_key=$_apiKey&language=es-ES'
          '&sort_by=popularity.desc&include_adult=false'
          '&primary_release_year=$year',
      '$_baseUrl/discover/tv?api_key=$_apiKey&language=es-ES'
          '&sort_by=popularity.desc&include_adult=false'
          '&first_air_date_year=$year',
    ];

    final salida = <Map<String, String>>[];
    for (final url in urls) {
      try {
        final response = await http.get(Uri.parse(url));
        if (response.statusCode != 200) continue;
        final data = json.decode(response.body);
        final results = data['results'];
        if (results is! List) continue;
        for (final item in results) {
          final title = (item['title'] ?? item['name'] ?? '').toString();
          if (title.isEmpty) continue;
          salida.add({'title': title, 'year': '$year'});
        }
      } catch (e) {
        print('Error fetching TMDB popular for $year: $e');
      }
    }
    return salida;
  }

  /// La tendencia de la semana de TMDB.
  ///
  /// TRES PAGINAS, NO UNA. Cada pagina son 20 titulos globales, y de esos
  /// suelen estar en el catalogo tres o cuatro: la fila "Busqueda popular" se
  /// llenaba con populares-por-año en vez de con tendencia de verdad. Con 60
  /// titulos hay material para llenarla entera con lo que esta sonando ahora,
  /// que es lo que la fila promete. Las paginas van en ORDEN: la 1 es lo que
  /// mas suena, asi que lo mejor sigue entrando primero.
  ///
  /// Si una pagina falla se sigue con lo que haya: mejor tres titulos que
  /// ninguno.
  Future<List<Map<String, String>>> getTrendingTitles({int paginas = 3}) async {
    final salida = <Map<String, String>>[];
    final vistos = <String>{};

    for (var pagina = 1; pagina <= paginas; pagina++) {
      try {
        final response = await http.get(
          Uri.parse(
            '$_baseUrl/trending/all/week?api_key=$_apiKey&language=es-ES'
            '&page=$pagina',
          ),
        );
        if (response.statusCode != 200) break;

        final data = json.decode(response.body);
        final results = data['results'];
        if (results is! List || results.isEmpty) break;

        for (final item in results) {
          final title = (item['title'] ?? item['name'] ?? '').toString();
          if (title.isEmpty || !vistos.add(title.toLowerCase())) continue;
          final date =
              (item['release_date'] ?? item['first_air_date'] ?? '').toString();
          salida.add({
            'title': title,
            'year': date.length >= 4 ? date.substring(0, 4) : '',
          });
        }
      } catch (e) {
        print('Error fetching trending titles (pagina $pagina): $e');
        break;
      }
    }
    return salida;
  }

  static final Map<String, Map<int, Map<String, dynamic>>> _seasonCache = {};

  /// Obtiene los detalles y miniaturas de cada episodio de una temporada desde TMDB.
  Future<Map<int, Map<String, dynamic>>> getSeasonEpisodes(
    int seriesId,
    int seasonNumber,
  ) async {
    final cacheKey = '${seriesId}_$seasonNumber';
    if (_seasonCache.containsKey(cacheKey)) {
      return _seasonCache[cacheKey]!;
    }

    try {
      final url =
          '$_baseUrl/tv/$seriesId/season/$seasonNumber?api_key=$_apiKey&language=es-ES';
      final response = await http.get(Uri.parse(url));

      if (response.statusCode != 200) return {};

      final data = json.decode(response.body);
      final episodes = data['episodes'] as List?;
      if (episodes == null) return {};

      final Map<int, Map<String, dynamic>> result = {};
      for (final ep in episodes) {
        if (ep is Map) {
          final epNum = ep['episode_number'];
          final stillPath = ep['still_path'];
          if (epNum is int) {
            result[epNum] = {
              'name': ep['name']?.toString(),
              'still_url':
                  (stillPath != null && stillPath.toString().isNotEmpty)
                      ? 'https://image.tmdb.org/t/p/w300$stillPath'
                      : null,
              'overview': ep['overview']?.toString(),
              'vote_average': ep['vote_average'],
            };
          }
        }
      }
      if (result.isNotEmpty) {
        _seasonCache[cacheKey] = result;
      }
      return result;
    } catch (e) {
      print('Error fetching TMDB season episodes: $e');
      return {};
    }
  }
}
