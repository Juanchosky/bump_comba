import 'dart:convert';
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
    if (logo == null || logo.isEmpty || logo.contains('placeholder')) {
      return '';
    }

    if (logo.startsWith('/')) {
      return '$host$logo';
    }
    return logo;
  }

  /// Helper para peticiones GET con seguimiento de progreso (streaming)
  Future<String?> _getWithProgress(
    Uri url, {
    void Function(DownloadProgress)? onProgress,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', url);
      final response = await client.send(request).timeout(timeout);

      if (response.statusCode != 200) return null;

      final List<int> bytes = [];
      final int? total = response.contentLength;
      int received = 0;

      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        onProgress?.call(DownloadProgress(received, total));
      }

      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>?> login(
    String host,
    String user,
    String pass,
  ) async {
    try {
      final url = Uri.parse(
        '$host/player_api.php?username=$user&password=$pass',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      print('Xtream login error: $e');
    }
    return null;
  }

  Future<List<M3UItem>> fetchLiveStreams(
    String host,
    String user,
    String pass, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    try {
      // 1. Get categories
      final catUrl = Uri.parse(
        '$host/player_api.php?username=$user&password=$pass&action=get_live_categories',
      );
      final catResStr = await _getWithProgress(catUrl, onProgress: onProgress);
      final Map<String, String> categoryMap = {};
      if (catResStr != null) {
        final List<dynamic> cats = json.decode(catResStr);
        for (var c in cats) {
          final id = c['category_id'].toString();
          final name = NormalizationUtils.normalizeCategory(
            c['category_name'].toString(),
          );
          categoryMap[id] = name;
        }
      }

      // 2. Get streams
      final streamUrl = Uri.parse(
        '$host/player_api.php?username=$user&password=$pass&action=get_live_streams',
      );
      final streamResStr = await _getWithProgress(
        streamUrl,
        onProgress: onProgress,
      );
      if (streamResStr != null) {
        return await compute(parseLiveStreamsInBackground, {
          'json': streamResStr,
          'categoryMap': categoryMap,
          'host': host,
          'user': user,
          'pass': pass,
        });
      }
    } catch (e) {
      print('Xtream fetchLiveStreams error: $e');
    }
    return [];
  }

  Future<List<M3UItem>> fetchVodStreams(
    String host,
    String user,
    String pass, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    try {
      final catUrl = Uri.parse(
        '$host/player_api.php?username=$user&password=$pass&action=get_vod_categories',
      );
      final catResStr = await _getWithProgress(catUrl, onProgress: onProgress);
      final Map<String, String> categoryMap = {};
      if (catResStr != null) {
        final List<dynamic> cats = json.decode(catResStr);
        for (var c in cats) {
          final id = c['category_id'].toString();
          final name = NormalizationUtils.normalizeCategory(
            c['category_name'].toString(),
          );
          categoryMap[id] = name;
        }
      }

      final streamUrl = Uri.parse(
        '$host/player_api.php?username=$user&password=$pass&action=get_vod_streams',
      );
      final streamResStr = await _getWithProgress(
        streamUrl,
        onProgress: onProgress,
      );
      if (streamResStr != null) {
        return await compute(parseVodStreamsInBackground, {
          'json': streamResStr,
          'categoryMap': categoryMap,
          'host': host,
          'user': user,
          'pass': pass,
        });
      }
    } catch (e) {
      print('Xtream fetchVodStreams error: $e');
    }
    return [];
  }

  Future<List<M3UItem>> fetchSeries(
    String host,
    String user,
    String pass, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    try {
      final catUrl = Uri.parse(
        '$host/player_api.php?username=$user&password=$pass&action=get_series_categories',
      );
      final catResStr = await _getWithProgress(catUrl, onProgress: onProgress);
      final Map<String, String> categoryMap = {};
      if (catResStr != null) {
        final List<dynamic> cats = json.decode(catResStr);
        for (var c in cats) {
          final id = c['category_id'].toString();
          final name = NormalizationUtils.normalizeCategory(
            c['category_name'].toString(),
          );
          categoryMap[id] = name;
        }
      }

      final streamUrl = Uri.parse(
        '$host/player_api.php?username=$user&password=$pass&action=get_series',
      );
      final streamResStr = await _getWithProgress(
        streamUrl,
        onProgress: onProgress,
      );
      if (streamResStr != null) {
        return await compute(parseSeriesInBackground, {
          'json': streamResStr,
          'categoryMap': categoryMap,
          'host': host,
          'user': user,
          'pass': pass,
        });
      }
    } catch (e) {
      print('Xtream fetchSeries error: $e');
    }
    return [];
  }

  Future<List<M3UItem>> fetchSeriesEpisodes(
    String host,
    String userRaw,
    String passRaw,
    String seriesId,
    String seriesName, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    final user = SecurityUtils.deobfuscate(userRaw);
    final pass = SecurityUtils.deobfuscate(passRaw);
    try {
      final url = Uri.parse(
        '$host/player_api.php?username=$user&password=$pass&action=get_series_info&series_id=$seriesId',
      );
      final resStr = await _getWithProgress(url, onProgress: onProgress);
      if (resStr != null) {
        final data = json.decode(resStr);
        final Map<String, dynamic> episodesData = data['episodes'] ?? {};
        final List<M3UItem> allEpisodes = [];

        episodesData.forEach((seasonNum, episodesList) {
          if (episodesList is List) {
            for (var ep in episodesList) {
              final epId = ep['id'];
              final ext = ep['container_extension'] ?? 'mp4';
              final epName =
                  ep['title']?.toString() ?? 'Episodio ${ep['episode_num']}';
              final rawLogo = ep['info']?['movie_image']?.toString();

              allEpisodes.add(
                M3UItem(
                  name: epName,
                  url: '$host/series/$user/$pass/$epId.$ext',
                  category: 'Episodios',
                  seriesName: seriesName,
                  seasonNumber: int.tryParse(seasonNum) ?? 0,
                  episodeNumber:
                      int.tryParse(ep['episode_num']?.toString() ?? '0') ?? 0,
                  logo: _fixLogo(rawLogo, epName, host),
                  duration:
                      ep['info']?['duration']?.toString() ??
                      ep['duration']?.toString(),
                ),
              );
            }
          }
        });
        return allEpisodes;
      }
    } catch (e) {
      print('Xtream fetchSeriesEpisodes error: $e');
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

  final List<dynamic> streams = json.decode(jsonStr);
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

  final List<dynamic> streams = json.decode(jsonStr);
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

  final List<dynamic> series = json.decode(jsonStr);
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
