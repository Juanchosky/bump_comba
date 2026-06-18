import 'dart:io';
import 'dart:convert';

void main() async {
  final dir = Directory('C:\\Users\\Juan Arrieta\\Downloads\\bump_comba\\lib');
  final files = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
  
  int fixedCount = 0;
  for (var file in files) {
    String content = await file.readAsString();
    if (content.contains('Ã') || content.contains('Â')) {
      // Try to fix double encoding
      try {
        List<int> bytes = latin1.encode(content);
        String fixed = utf8.decode(bytes);
        await file.writeAsString(fixed);
        print('Fixed double encoding in: \${file.path}');
        fixedCount++;
      } catch (e) {
        // Fallback: manual replacements
        String fixed = content
          .replaceAll('Ã¡', 'á')
          .replaceAll('Ã©', 'é')
          .replaceAll('Ã\xAD', 'í') // \xAD is soft hyphen
          .replaceAll('Ã³', 'ó')
          .replaceAll('Ãº', 'ú')
          .replaceAll('Ã±', 'ñ')
          .replaceAll('Ã‘', 'Ñ')
          .replaceAll('Â¿', '¿')
          .replaceAll('Â¡', '¡')
          .replaceAll('Ã ', 'À')
          .replaceAll('Ã\x8D', 'Í')
          .replaceAll('Ã“', 'Ó')
          .replaceAll('Ãš', 'Ú')
          .replaceAll('Ã¼', 'ü')
          .replaceAll('Ãœ', 'Ü')
          .replaceAll('Ã\x81', 'Á')
          .replaceAll('Ã‰', 'É');
        
        if (fixed != content) {
          await file.writeAsString(fixed);
          print('Fixed manually in: \${file.path}');
          fixedCount++;
        }
      }
    }
    
    // Also fix the specific mangle in m3u_service.dart
    if (file.path.endsWith('m3u_service.dart')) {
       String c = await file.readAsString();
       if (c.contains('ƆǏҡע坣')) {
         c = c.replaceAll('ƆǏҡע坣', 'áàäâãåæÁÀÄÂÃÅÆéèëêÉÈËÊíìïîÍÌÏÎóòöôõøÓÒÖÔÕØúùüûÚÙÜÛýÝñÑçÇ');
         await file.writeAsString(c);
         print('Fixed m3u_service.dart specific mangle');
       }
    }
  }
  print('Total files fixed: \$fixedCount');
}
