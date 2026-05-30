import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'm3u_service.dart';

class VideoPrewarmService {
  static final VideoPrewarmService _instance = VideoPrewarmService._internal();
  factory VideoPrewarmService() => _instance;
  VideoPrewarmService._internal();

  final Map<String, Player> _prewarmedPlayers = {};

  Future<void> prewarm(M3UItem item, String userAgent) async {
    final url = item.url;
    if (_prewarmedPlayers.containsKey(url)) return;

    // Limit to 1 prewarmed player to save resources (Critical for Android 15/Motorola)
    if (_prewarmedPlayers.isNotEmpty) {
      final firstKey = _prewarmedPlayers.keys.first;
      final oldPlayer = _prewarmedPlayers.remove(firstKey);

      // Forced shutdown pattern
      try {
        final mpv = oldPlayer?.platform as dynamic;
        mpv?.setProperty('vid', 'no');
        mpv?.setProperty('vo', 'null');
      } catch (_) {}
      oldPlayer?.stop();
      Future.delayed(
        const Duration(milliseconds: 500),
        () => oldPlayer?.dispose(),
      );
    }

    try {
      final player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 64 * 1024 * 1024, // 64 MB buffer for pre-warming
          title: 'Bump Comba Prewarmer',
          logLevel: MPVLogLevel.error,
          libass: false,
        ),
      );

      // -- CRITICAL SILENCING --
      // Mute native engine IMMEDIATELY to prevent orphan threads
      // from firing callbacks during/after a Hot Restart.
      try {
        final mpvPlatform = player.platform as dynamic;
        mpvPlatform?.setProperty('terminal', 'no');
        mpvPlatform?.setProperty('msg-level', 'all=no');
      } catch (_) {}

      final mpv = player.platform as dynamic;
      if (mpv != null) {
        // Apply basic reliable settings
        await mpv.setProperty('user-agent', userAgent);
        await mpv.setProperty('cache', 'yes');
        await mpv.setProperty(
          'pause',
          'yes',
        ); // Start paused or pause immediately
        await mpv.setProperty('hwdec', 'auto-safe');
      }

      _prewarmedPlayers[url] = player;

      // Extract domain for Referer (matching VideoPlayerScreen logic)
      String referer = '';
      try {
        final uri = Uri.parse(url);
        referer = '${uri.scheme}://${uri.host}/';
      } catch (_) {}

      final headers = {
        'User-Agent': userAgent,
        'Accept': '*/*',
        'Accept-Encoding': 'gzip, deflate',
        'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        'Connection': 'keep-alive',
        if (referer.isNotEmpty) 'Referer': referer,
        if (referer.isNotEmpty) 'Origin': referer.replaceAll(RegExp(r'/$'), ''),
      };

      // Open the media. It might start buffering immediately even if play: false
      await player.open(Media(url, httpHeaders: headers), play: false);

      debugPrint('VideoPrewarmService: Pre-warmed ${item.name}');
    } catch (e) {
      debugPrint('VideoPrewarmService: Error pre-warming ${item.name}: $e');
      _prewarmedPlayers.remove(url)?.dispose();
    }
  }

  Player? getPlayer(M3UItem item) {
    final player = _prewarmedPlayers.remove(item.url);
    if (player != null) {
      debugPrint(
        'VideoPrewarmService: Consumed pre-warmed player for ${item.name}',
      );
    }
    return player;
  }

  void disposeAll() {
    for (final player in _prewarmedPlayers.values) {
      player.dispose();
    }
    _prewarmedPlayers.clear();
  }
}
