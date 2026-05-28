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

    String overview = details['overview'] ?? '';
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
    };
  }

  Future<List<Map<String, String>>> getTrendingTitles() async {
    try {
      final response = await http.get(
        Uri.parse(
          '$_baseUrl/trending/all/week?api_key=$_apiKey&language=es-ES',
        ),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = data['results'] as List;
        return results.map((item) {
          final title = item['title'] ?? item['name'] ?? '';
          final date = item['release_date'] ?? item['first_air_date'] ?? '';
          String year = '';
          if (date.toString().length >= 4) {
            year = date.toString().substring(0, 4);
          }
          return {'title': title.toString(), 'year': year};
        }).toList();
      }
    } catch (e) {
      print('Error fetching trending titles: $e');
    }
    return [];
  }
}
