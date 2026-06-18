import 'dart:io';

void main() {
  final files = [
    'lib/screens/stream_browser_screen.dart',
    'lib/screens/video_player_screen.dart',
    'lib/services/m3u_service.dart',
    'lib/services/ad_service.dart',
    'lib/screens/content_detail_screen.dart'
  ];
  
  final badWords = <String>{};
  for (final path in files) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final content = file.readAsStringSync();
    
    final words = content.split(RegExp(r'[^a-zA-Z\uFFFD\u00C0-\u017F]+'));
    for (final word in words) {
      if (word.contains('\uFFFD')) {
        badWords.add(word);
      }
    }
  }
  
  print('Corrupted words found:');
  for (final w in badWords) {
    print(w);
  }
}
