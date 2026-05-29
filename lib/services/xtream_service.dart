import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../models/m3u_item.dart';
import '../models/download_progress.dart';
import '../utils/normalization_utils.dart';
import '../utils/security_utils.dart';

class XtreamService {
  static final XtreamService _instance = XtreamService._internal();
  factory XtreamService() => _instance;
  XtreamService._internal();

  /// Verifica logos y aplica fallback si es necesario
  String _fixLogo(String? logo, String title, String host) {
    if (logo == null || logo.trim().isEmpty || logo.contains('placeholder')) {
      return '';
    }
    logo = logo.trim();

    if (logo.startsWith('/')) {
      return '$host$logo';
    }
    return logo;
  }

  /// Helper para peticiones GET con seguimiento de progreso (streaming)
  ///
  /// FIX: Valida que la respuesta sea JSON válido antes de devolverla.
  /// Servidores XUI.one/Xtream a veces devuelven páginas HTML de "Debug Mode"
  /// en lugar de JSON (credenciales inválidas, IP bloqueada, mantenimiento),
  /// lo que causaba FormatException al intentar parsear.
  Future<String?> _getWithProgress(
    Uri url, {
    void Function(DownloadProgress)? onProgress,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', url);
      // Forzar 'Connection: close' y agregar User-Agent estándar para evitar
      // el envenenamiento de sockets TCP en redes móviles.
      request.headers.addAll({
        'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
        'Accept': 'application/json, text/plain, */*',
        'Connection': 'close',
      });

      final response = await client.send(request).timeout(timeout);

      if (response.statusCode != 200) return null;

      final builder = BytesBuilder(copy: false);
      final int? total = response.contentLength;
      int received = 0;

      // Timeout de 15 segundos para evitar cuelgues indefinidos en redes inestables
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        builder.add(chunk);
        received += chunk.length;
        onProgress?.call(DownloadProgress(received, total));
      }

      final body = utf8.decode(builder.takeBytes(), allowMalformed: true);

      // FIX: Detectar respuestas HTML del servidor Xtream.
      // Cuando las credenciales son inválidas, la IP está bloqueada, o el
      // servidor está en mantenimiento, XUI.one devuelve una página HTML
      // en vez de JSON. Detectamos esto y devolvemos null para que el
      // fallback a caché se active correctamente.
      final trimmedBody = body.trimLeft();
      if (trimmedBody.startsWith('<') || trimmedBody.startsWith('<!')) {
        debugPrint(
          'Xtream API returned HTML instead of JSON (possible auth failure, '
          'IP block, or server maintenance). URL: ${url.host}${url.path}',
        );
        return null;
      }

      return body;
    } on TimeoutException catch (e) {
      debugPrint(
        'Xtream API GET TimeoutException: $e (URL: ${url.host}${url.path})',
      );
      return null;
    } catch (e) {
      debugPrint('Xtream API GET Error: $e (URL: ${url.host}${url.path})');
      return null;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>?> login(
    String host,
    String user,
    String pass,
  ) async {
    final cleanHost =
        host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    try {
      final url = Uri.parse(
        '$cleanHost/player_api.php?username=$user&password=$pass',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        // FIX: Validar que la respuesta sea JSON antes de parsear.
        final trimmed = response.body.trimLeft();
        if (trimmed.startsWith('<') || trimmed.startsWith('<!')) {
          debugPrint(
            'Xtream login: server returned HTML instead of JSON (auth/IP issue)',
          );
          return null;
        }
        return json.decode(response.body);
      }
    } catch (e) {
      print('Xtream login error: $e');
    }
    return null;
  }

  Future<List<M3UItem>?> fetchLiveStreams(
    String host,
    String user,
    String pass, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    final cleanHost =
        host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    try {
      // 1. Get categories
      final catUrl = Uri.parse(
        '$cleanHost/player_api.php?username=$user&password=$pass&action=get_live_categories',
      );
      final catResStr = await _getWithProgress(catUrl, onProgress: onProgress);
      final Map<String, String> categoryMap = {};
      if (catResStr != null) {
        try {
          final decodedCats = json.decode(catResStr);
          final List<dynamic> cats;
          if (decodedCats is List) {
            cats = decodedCats;
          } else if (decodedCats is Map) {
            cats = decodedCats.values.toList();
          } else {
            cats = [];
          }
          for (var c in cats) {
            final id = c['category_id'].toString();
            final name = NormalizationUtils.normalizeCategory(
              c['category_name'].toString(),
            );
            categoryMap[id] = name;
          }
        } catch (e) {
          debugPrint('Error parsing live categories: $e');
        }
      }

      // 2. Get streams
      final streamUrl = Uri.parse(
        '$cleanHost/player_api.php?username=$user&password=$pass&action=get_live_streams',
      );
      final streamResStr = await _getWithProgress(
        streamUrl,
        onProgress: onProgress,
      );
      if (streamResStr == null) return null;
      return await compute(parseLiveStreamsInBackground, {
        'json': streamResStr,
        'categoryMap': categoryMap,
        'host': cleanHost,
        'user': user,
        'pass': pass,
      });
    } catch (e) {
      print('Xtream fetchLiveStreams error: $e');
    }
    return null;
  }

  Future<List<M3UItem>?> fetchVodStreams(
    String host,
    String user,
    String pass, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    final cleanHost =
        host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    try {
      final catUrl = Uri.parse(
        '$cleanHost/player_api.php?username=$user&password=$pass&action=get_vod_categories',
      );
      final catResStr = await _getWithProgress(catUrl, onProgress: onProgress);
      final Map<String, String> categoryMap = {};
      if (catResStr != null) {
        try {
          final decodedCats = json.decode(catResStr);
          final List<dynamic> cats;
          if (decodedCats is List) {
            cats = decodedCats;
          } else if (decodedCats is Map) {
            cats = decodedCats.values.toList();
          } else {
            cats = [];
          }
          for (var c in cats) {
            final id = c['category_id'].toString();
            final name = NormalizationUtils.normalizeCategory(
              c['category_name'].toString(),
            );
            categoryMap[id] = name;
          }
        } catch (e) {
          debugPrint('Error parsing VOD categories: $e');
        }
      }

      final streamUrl = Uri.parse(
        '$cleanHost/player_api.php?username=$user&password=$pass&action=get_vod_streams',
      );
      final streamResStr = await _getWithProgress(
        streamUrl,
        onProgress: onProgress,
      );
      if (streamResStr == null) return null;
      return await compute(parseVodStreamsInBackground, {
        'json': streamResStr,
        'categoryMap': categoryMap,
        'host': cleanHost,
        'user': user,
        'pass': pass,
      });
    } catch (e) {
      print('Xtream fetchVodStreams error: $e');
    }
    return null;
  }

  Future<List<M3UItem>?> fetchSeries(
    String host,
    String user,
    String pass, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    final cleanHost =
        host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    try {
      final catUrl = Uri.parse(
        '$cleanHost/player_api.php?username=$user&password=$pass&action=get_series_categories',
      );
      final catResStr = await _getWithProgress(catUrl, onProgress: onProgress);
      final Map<String, String> categoryMap = {};
      if (catResStr != null) {
        try {
          final decodedCats = json.decode(catResStr);
          final List<dynamic> cats;
          if (decodedCats is List) {
            cats = decodedCats;
          } else if (decodedCats is Map) {
            cats = decodedCats.values.toList();
          } else {
            cats = [];
          }
          for (var c in cats) {
            final id = c['category_id'].toString();
            final name = NormalizationUtils.normalizeCategory(
              c['category_name'].toString(),
            );
            categoryMap[id] = name;
          }
        } catch (e) {
          debugPrint('Error parsing series categories: $e');
        }
      }

      final streamUrl = Uri.parse(
        '$cleanHost/player_api.php?username=$user&password=$pass&action=get_series',
      );
      final streamResStr = await _getWithProgress(
        streamUrl,
        onProgress: onProgress,
      );
      if (streamResStr == null) return null;
      return await compute(parseSeriesInBackground, {
        'json': streamResStr,
        'categoryMap': categoryMap,
        'host': cleanHost,
        'user': user,
        'pass': pass,
      });
    } catch (e) {
      print('Xtream fetchSeries error: $e');
    }
    return null;
  }

  Future<List<M3UItem>> fetchSeriesEpisodes(
    String host,
    String userRaw,
    String passRaw,
    String seriesId,
    String seriesName, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    final cleanHost =
        host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    final user = SecurityUtils.deobfuscate(userRaw);
    final pass = SecurityUtils.deobfuscate(passRaw);
    Uri? url;
    try {
      url = Uri.parse(
        '$cleanHost/player_api.php?username=$user&password=$pass&action=get_series_info&series_id=$seriesId',
      );
      final resStr = await _getWithProgress(url, onProgress: onProgress);
      if (resStr != null) {
        final allEpisodes = await compute(parseSeriesEpisodesInBackground, {
          'json': resStr,
          'host': cleanHost,
          'user': userRaw,
          'pass': passRaw,
          'seriesName': seriesName,
        });

        if (allEpisodes.isEmpty) {
          try {
            final data = json.decode(resStr);
            debugPrint(
              'Xtream fetchSeriesEpisodes: parsed 0 episodes. '
              'Keys in data: ${data is Map ? data.keys.toList() : 'not a Map'}. '
              'episodes type: ${data is Map ? data['episodes']?.runtimeType : 'N/A'}. '
              'seasons content: ${data is Map ? data['seasons'] : 'N/A'}. '
              'URL: $url',
            );
          } catch (_) {}
        }
        return allEpisodes;
      }
    } catch (e) {
      debugPrint('Xtream fetchSeriesEpisodes error: $e. URL: $url');
    }
    return [];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ISOLATE PARSERS — Para evitar ANRs en el hilo principal
// ─────────────────────────────────────────────────────────────────────────────

List<M3UItem> parseLiveStreamsInBackground(Map<String, dynamic> input) {
  final String jsonStr = input['json'];
  final Map<String, String> categoryMap = Map<String, String>.from(
    input['categoryMap'],
  );
  final String host = input['host'];
  final String user = SecurityUtils.deobfuscate(input['user'] ?? '');
  final String pass = SecurityUtils.deobfuscate(input['pass'] ?? '');

  final decoded = json.decode(jsonStr);
  final List<dynamic> streams;
  if (decoded is List) {
    streams = decoded;
  } else if (decoded is Map) {
    streams = decoded.values.toList();
  } else {
    streams = [];
  }

  return streams.map((s) {
    final streamId = s['stream_id'];
    final ext = s['container_extension'] ?? 'm3u8';
    final categoryId = s['category_id'].toString();
    final name = s['name']?.toString() ?? 'Sin nombre';
    final rawLogo = s['stream_icon']?.toString();

    return M3UItem(
      name: name,
      url: '$host/live/$user/$pass/$streamId.$ext',
      logo: XtreamService()._fixLogo(rawLogo, name, host),
      category: categoryMap[categoryId] ?? 'Live',
      isLive: true,
    );
  }).toList();
}

List<M3UItem> parseVodStreamsInBackground(Map<String, dynamic> input) {
  final String jsonStr = input['json'];
  final Map<String, String> categoryMap = Map<String, String>.from(
    input['categoryMap'],
  );
  final String host = input['host'];
  final String user = SecurityUtils.deobfuscate(input['user'] ?? '');
  final String pass = SecurityUtils.deobfuscate(input['pass'] ?? '');

  final decoded = json.decode(jsonStr);
  final List<dynamic> streams;
  if (decoded is List) {
    streams = decoded;
  } else if (decoded is Map) {
    streams = decoded.values.toList();
  } else {
    streams = [];
  }

  return streams.map((s) {
    final streamId = s['stream_id'];
    final ext = s['container_extension'] ?? 'mp4';
    final categoryId = s['category_id'].toString();
    final name = s['name']?.toString() ?? 'Sin nombre';
    final rawLogo = s['stream_icon']?.toString() ?? s['cover']?.toString();

    return M3UItem(
      name: name,
      url: '$host/movie/$user/$pass/$streamId.$ext',
      logo: XtreamService()._fixLogo(rawLogo, name, host),
      category: categoryMap[categoryId] ?? 'Películas',
      isLive: false,
      duration: s['duration']?.toString() ?? s['duration_secs']?.toString(),
    );
  }).toList();
}

List<M3UItem> parseSeriesInBackground(Map<String, dynamic> input) {
  final String jsonStr = input['json'];
  final Map<String, String> categoryMap = Map<String, String>.from(
    input['categoryMap'],
  );
  final String host = input['host'];

  final decoded = json.decode(jsonStr);
  final List<dynamic> series;
  if (decoded is List) {
    series = decoded;
  } else if (decoded is Map) {
    series = decoded.values.toList();
  } else {
    series = [];
  }

  return series.map((s) {
    final seriesId = s['series_id'];
    final categoryId = s['category_id'].toString();
    final name = s['name']?.toString() ?? 'Sin nombre';
    final rawLogo = s['cover']?.toString() ?? s['stream_icon']?.toString();

    return M3UItem(
      name: name,
      url: seriesId.toString(),
      logo: XtreamService()._fixLogo(rawLogo, name, host),
      category: categoryMap[categoryId] ?? 'Series',
      isLive: false,
      isSeries: true,
      seriesName: name,
      episodes: [],
    );
  }).toList();
}

String _fixLogoHelper(String? logo, String title, String host) {
  if (logo == null || logo.trim().isEmpty || logo.contains('placeholder')) {
    return '';
  }
  logo = logo.trim();

  if (logo.startsWith('/')) {
    return '$host$logo';
  }
  return logo;
}

List<M3UItem> parseSeriesEpisodesInBackground(Map<String, dynamic> input) {
  final String jsonStr = input['json'];
  final String cleanHost = input['host'];
  final String user = SecurityUtils.deobfuscate(input['user'] ?? '');
  final String pass = SecurityUtils.deobfuscate(input['pass'] ?? '');
  final String seriesName = input['seriesName'] ?? '';

  final data = json.decode(jsonStr);
  final List<M3UItem> allEpisodes = [];

  if (data is Map<String, dynamic>) {
    final rawEpisodes = data['episodes'];
    if (rawEpisodes is Map) {
      rawEpisodes.forEach((seasonNum, episodesList) {
        if (episodesList is List) {
          for (var ep in episodesList) {
            if (ep is Map) {
              final epId = ep['id'];
              if (epId == null) continue;
              final ext = ep['container_extension'] ?? 'mp4';
              final epName =
                  ep['title']?.toString() ?? 'Episodio ${ep['episode_num']}';
              final rawLogo = ep['info']?['movie_image']?.toString();

              allEpisodes.add(
                M3UItem(
                  name: epName,
                  url: '$cleanHost/series/$user/$pass/$epId.$ext',
                  category: 'Episodios',
                  seriesName: seriesName,
                  seasonNumber: int.tryParse(seasonNum.toString()) ?? 0,
                  episodeNumber:
                      int.tryParse(ep['episode_num']?.toString() ?? '0') ?? 0,
                  logo: _fixLogoHelper(rawLogo, epName, cleanHost),
                  duration:
                      ep['info']?['duration']?.toString() ??
                      ep['duration']?.toString(),
                ),
              );
            }
          }
        }
      });
    } else if (rawEpisodes is List) {
      for (var ep in rawEpisodes) {
        if (ep is Map) {
          final epId = ep['id'];
          if (epId == null) continue;
          final ext = ep['container_extension'] ?? 'mp4';
          final epName =
              ep['title']?.toString() ?? 'Episodio ${ep['episode_num']}';
          final rawLogo = ep['info']?['movie_image']?.toString();
          final seasonNum = ep['season']?.toString() ?? '1';

          allEpisodes.add(
            M3UItem(
              name: epName,
              url: '$cleanHost/series/$user/$pass/$epId.$ext',
              category: 'Episodios',
              seriesName: seriesName,
              seasonNumber: int.tryParse(seasonNum) ?? 1,
              episodeNumber:
                  int.tryParse(ep['episode_num']?.toString() ?? '0') ?? 0,
              logo: _fixLogoHelper(rawLogo, epName, cleanHost),
              duration:
                  ep['info']?['duration']?.toString() ??
                  ep['duration']?.toString(),
            ),
          );
        }
      }
    }

    // FALLBACK: Si no hay episodios en la clave "episodes", buscar si vienen anidados dentro de "seasons"
    if (allEpisodes.isEmpty) {
      final rawSeasons = data['seasons'];
      if (rawSeasons is List) {
        for (var season in rawSeasons) {
          if (season is Map) {
            final seasonEpisodes = season['episodes'];
            final seasonNum =
                season['season_number']?.toString() ??
                season['id']?.toString() ??
                '1';
            if (seasonEpisodes is List) {
              for (var ep in seasonEpisodes) {
                if (ep is Map) {
                  final epId = ep['id'];
                  if (epId == null) continue;
                  final ext = ep['container_extension'] ?? 'mp4';
                  final epName =
                      ep['title']?.toString() ??
                      'Episodio ${ep['episode_num']}';
                  final rawLogo = ep['info']?['movie_image']?.toString();

                  allEpisodes.add(
                    M3UItem(
                      name: epName,
                      url: '$cleanHost/series/$user/$pass/$epId.$ext',
                      category: 'Episodios',
                      seriesName: seriesName,
                      seasonNumber: int.tryParse(seasonNum) ?? 1,
                      episodeNumber:
                          int.tryParse(ep['episode_num']?.toString() ?? '0') ??
                          0,
                      logo: _fixLogoHelper(rawLogo, epName, cleanHost),
                      duration:
                          ep['info']?['duration']?.toString() ??
                          ep['duration']?.toString(),
                    ),
                  );
                }
              }
            }
          }
        }
      }
    }
  }
  return allEpisodes;
}
