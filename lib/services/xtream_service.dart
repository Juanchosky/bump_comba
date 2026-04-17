import 'dart:convert';
import 'package:http/http.dart' as http;
import 'm3u_service.dart';

class XtreamService {
  static final XtreamService _instance = XtreamService._internal();
  factory XtreamService() => _instance;
  XtreamService._internal();

  Future<Map<String, dynamic>?> login(String host, String user, String pass) async {
    try {
      final url = Uri.parse('$host/player_api.php?username=$user&password=$pass');
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      print('Xtream login error: $e');
    }
    return null;
  }

  Future<List<M3UItem>> fetchLiveStreams(String host, String user, String pass) async {
    try {
      // 1. Get categories
      final catUrl = Uri.parse('$host/player_api.php?username=$user&password=$pass&action=get_live_categories');
      final catRes = await http.get(catUrl).timeout(const Duration(seconds: 15));
      final Map<String, String> categoryMap = {};
      if (catRes.statusCode == 200) {
        final List<dynamic> cats = json.decode(catRes.body);
        for (var c in cats) {
          categoryMap[c['category_id'].toString()] = c['category_name'].toString();
        }
      }

      // 2. Get streams
      final streamUrl = Uri.parse('$host/player_api.php?username=$user&password=$pass&action=get_live_streams');
      final streamRes = await http.get(streamUrl).timeout(const Duration(seconds: 30));
      if (streamRes.statusCode == 200) {
        final List<dynamic> streams = json.decode(streamRes.body);
        return streams.map((s) {
          final streamId = s['stream_id'];
          final ext = s['container_extension'] ?? 'm3u8';
          final categoryId = s['category_id'].toString();
          return M3UItem(
            name: s['name']?.toString() ?? 'Sin nombre',
            url: '$host/live/$user/$pass/$streamId.$ext',
            logo: s['stream_icon']?.toString(),
            category: categoryMap[categoryId] ?? 'Live',
            isLive: true,
          );
        }).toList();
      }
    } catch (e) {
      print('Xtream fetchLiveStreams error: $e');
    }
    return [];
  }

  Future<List<M3UItem>> fetchVodStreams(String host, String user, String pass) async {
    try {
      final catUrl = Uri.parse('$host/player_api.php?username=$user&password=$pass&action=get_vod_categories');
      final catRes = await http.get(catUrl).timeout(const Duration(seconds: 15));
      final Map<String, String> categoryMap = {};
      if (catRes.statusCode == 200) {
        final List<dynamic> cats = json.decode(catRes.body);
        for (var c in cats) {
          categoryMap[c['category_id'].toString()] = c['category_name'].toString();
        }
      }

      final streamUrl = Uri.parse('$host/player_api.php?username=$user&password=$pass&action=get_vod_streams');
      final streamRes = await http.get(streamUrl).timeout(const Duration(seconds: 30));
      if (streamRes.statusCode == 200) {
        final List<dynamic> streams = json.decode(streamRes.body);
        return streams.map((s) {
          final streamId = s['stream_id'];
          final ext = s['container_extension'] ?? 'mp4';
          final categoryId = s['category_id'].toString();
          return M3UItem(
            name: s['name']?.toString() ?? 'Sin nombre',
            url: '$host/movie/$user/$pass/$streamId.$ext',
            logo: s['stream_icon']?.toString(),
            category: categoryMap[categoryId] ?? 'Películas',
            isLive: false,
          );
        }).toList();
      }
    } catch (e) {
      print('Xtream fetchVodStreams error: $e');
    }
    return [];
  }

  Future<List<M3UItem>> fetchSeries(String host, String user, String pass) async {
    try {
      final catUrl = Uri.parse('$host/player_api.php?username=$user&password=$pass&action=get_series_categories');
      final catRes = await http.get(catUrl).timeout(const Duration(seconds: 15));
      final Map<String, String> categoryMap = {};
      if (catRes.statusCode == 200) {
        final List<dynamic> cats = json.decode(catRes.body);
        for (var c in cats) {
          categoryMap[c['category_id'].toString()] = c['category_name'].toString();
        }
      }

      final streamUrl = Uri.parse('$host/player_api.php?username=$user&password=$pass&action=get_series');
      final streamRes = await http.get(streamUrl).timeout(const Duration(seconds: 30));
      if (streamRes.statusCode == 200) {
        final List<dynamic> series = json.decode(streamRes.body);
        return series.map((s) {
          final seriesId = s['series_id'];
          final categoryId = s['category_id'].toString();
          return M3UItem(
            name: s['name']?.toString() ?? 'Sin nombre',
            url: seriesId.toString(), // We'll need this ID to fetch episodes later
            logo: s['last_modified']?.toString(), // Placeholder or use cover
            category: categoryMap[categoryId] ?? 'Series',
            isLive: false,
            seriesName: s['name']?.toString(),
            episodes: [], // Need to fetch separately if lazy-loading is not used
          );
        }).toList();
      }
    } catch (e) {
      print('Xtream fetchSeries error: $e');
    }
    return [];
  }

  Future<List<M3UItem>> fetchSeriesEpisodes(String host, String user, String pass, String seriesId, String seriesName) async {
    try {
      final url = Uri.parse('$host/player_api.php?username=$user&password=$pass&action=get_series_info&series_id=$seriesId');
      final res = await http.get(url).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final Map<String, dynamic> episodesData = data['episodes'] ?? {};
        final List<M3UItem> allEpisodes = [];

        episodesData.forEach((seasonNum, episodesList) {
          if (episodesList is List) {
            for (var ep in episodesList) {
              final epId = ep['id'];
              final ext = ep['container_extension'] ?? 'mp4';
              allEpisodes.add(M3UItem(
                name: ep['title']?.toString() ?? 'Episodio ${ep['episode_num']}',
                url: '$host/series/$user/$pass/$epId.$ext',
                category: 'Episodios',
                seriesName: seriesName,
                seasonNumber: int.tryParse(seasonNum) ?? 0,
                episodeNumber: int.tryParse(ep['episode_num']?.toString() ?? '0') ?? 0,
                logo: ep['info']?['movie_image']?.toString(),
              ));
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
