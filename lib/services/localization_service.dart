import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing app localization
class LocalizationService {
  static const String _languageKey = 'app_language';

  SharedPreferences? _prefs;
  String _currentLanguage = 'es';

  String get currentLanguage => _currentLanguage;

  // Available languages (Japanese hidden after Italian)
  static const Map<String, LanguageInfo> languages = {
    'es': LanguageInfo('Español', '🇪🇸', 'es'),
    'en': LanguageInfo('English', '🇺🇸', 'en'),
    'pt': LanguageInfo('Português', '🇧🇷', 'pt'),
    'fr': LanguageInfo('Français', '🇫🇷', 'fr'),
    'it': LanguageInfo('Italiano', '🇮🇹', 'it'),
    'ja': LanguageInfo('日本語', '🇯🇵', 'ja'), // Secret - after Italian
    'zh': LanguageInfo('中文', '🇨🇳', 'zh'),
    'ko': LanguageInfo('한국어', '🇰🇷', 'ko'),
  };

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _currentLanguage = _prefs?.getString(_languageKey) ?? 'es';
  }

  Future<void> setLanguage(String languageCode) async {
    _currentLanguage = languageCode;
    await _prefs?.setString(_languageKey, languageCode);
  }

  LanguageInfo get currentLanguageInfo =>
      languages[_currentLanguage] ?? languages['es']!;

  /// Get localized string
  String tr(String key) {
    return _translations[_currentLanguage]?[key] ??
        _translations['es']![key] ??
        key;
  }

  static final Map<String, Map<String, String>> _translations = {
    'es': {
      'settings': 'CONFIGURACIÓN',
      'your_coins': 'TUS MONEDAS',
      'daily_challenge': 'DESAFÍO DIARIO',
      'vibration': 'Vibración',
      'enabled': 'Activada',
      'disabled': 'Desactivada',
      'difficulty': 'Dificultad',
      'easy': 'Fácil',
      'normal': 'Normal',
      'hard': 'Difícil',
      'language': 'Idioma',
      'statistics': 'ESTADÍSTICAS',
      'games_played': 'Partidas jugadas',
      'total_merges': 'Fusiones totales',
      'max_level': 'Nivel máximo',
      'best_score': 'Mejor puntuación',
      'coins_earned': 'Monedas ganadas',
      'current_streak': 'Racha actual',
      'days': 'días',
      'achievements': 'LOGROS',
      'progress': 'Progreso',
      'prestige': 'PRESTIGIO',
      'shop': 'TIENDA',
      'options': 'OPCIONES',
      'reset_progress': 'Reiniciar Progreso',
      'reset_all': 'Borra todo (estadísticas, monedas, logros)',
      'play': 'JUGAR',
      'menu': 'MENÚ',
      'restart': 'REINICIAR',
      'game_over': 'GAME OVER',
      'new_record': '¡NUEVO RÉCORD!',
      'score': 'Puntuación',
      'level_reached': 'Nivel alcanzado',
      'merges': 'Fusiones',
      'coins_won': 'Monedas ganadas',
      'challenge_complete': '¡Completado! Vuelve mañana para un nuevo desafío.',
      'select_language': 'Seleccionar Idioma',
      'coins': 'monedas',
      'buy_powerups': 'Compra power-ups con monedas',
      'purchased': 'comprado! Disponible en tu próxima partida.',
      'prestige_level': 'Prestigio',
      'bonus_points': 'puntos',
      'bonus_coins': 'monedas',
      'bonus': 'Bonus',
      'can_prestige': '¡Puedes hacer prestigio!',
      'reach_level_50': 'Alcanza nivel 50 para hacer prestigio',
      'prestige_dialog_title': 'PRESTIGIO',
      'prestige_info': 'Al hacer prestigio:',
      'reset_max_level': 'Se reinicia tu nivel máximo',
      'reset_best_score': 'Se reinicia tu mejor puntuación',
      'earn_coins': 'Ganas',
      'permanent_points': 'puntos permanente',
      'permanent_coins': 'monedas permanente',
      'keep_achievements': 'Conservas logros y estadísticas',
      'cancel': 'CANCELAR',
      'do_prestige': 'HACER PRESTIGIO',
      'confirm_reset': '¿Estás seguro?',
      'reset_warning':
          'Esto borrará TODO: estadísticas, logros, monedas, prestigio. Esta acción no se puede deshacer.',
      'reset': 'REINICIAR',
      'continue_btn': 'CONTINUAR',
      'restricted_access': 'Acceso Restringido',
      'enter_code': 'Ingresa el código para continuar',
      'best': 'MEJOR',
      'combine_sushi': 'Combina sushi para crecer',
      'max_level_label': 'NIVEL MAX',
      'evolution': 'EVOLUCIÓN',
      'difficulty_levels': 'NIVELES DE DIFICULTAD',
      'unlock_sushi': '¡Sube de nivel para desbloquear nuevos sushis!',
      'reach_level_challenge': 'Alcanza nivel',
      'do_merges': 'Realiza fusiones',
      'get_points': 'Consigue puntos',
      'get_combo': 'Consigue combo x',
      'next': 'SIG',
      'use': 'USAR',
      'achievement_unlocked': '¡LOGRO DESBLOQUEADO!',
      // Social Rewards
      'earn_coins_title': 'SOPORTE Y CONTACTO',
      'rate_us': 'Valóranos en Google Play',
      'share_app': 'Comparte la app con amigos',
      'reward_claimed': '¡Recompensa reclamada!',
      'rate_desc': 'Consigue 20 monedas por tu valoración',
      'share_desc': 'Consigue 10 monedas por compartir',
      'thanks_for_rating': '¡Gracias por tu valoración!',
      'thanks_for_sharing': '¡Gracias por compartir!',
      // Legal
      'legal': 'LEGAL',
      'privacy_policy': 'Política de Privacidad',
      'dmca': 'DMCA',
      'close': 'CERRAR',
      'privacy_text': '''Política de Privacidad
Bienvenido a Bump Comba. Esta política de privacidad explica cómo recopilamos, utilizamos y protegemos su información personal al usar nuestra aplicación y sitio web. Su privacidad es nuestra prioridad, y estamos comprometidos con protegerla de acuerdo con las leyes aplicables. Al utilizar nuestros servicios, acepta los términos descritos a continuación.

1. Información Técnica y de Red
No recopilamos datos personales identificables (como nombres o correos). Solo recopilamos:
a. Información de dispositivo: Modelo, versión de sistema operativo y ubicación aproximada para personalizar contenido (como el Top 10 por país) y anuncios.
b. Estado de Red: Para la función de transmisión a TV (Cast), la aplicación necesita escanear su red Wi-Fi local en busca de dispositivos compatibles (Chromecast). Este proceso se realiza localmente y no enviamos mapas de su red a nuestros servidores.

2. Cuentas de Usuario y Datos Anónimos
Para facilitar el uso de Bump Comba sin necesidad de un registro completo, operamos con un sistema de identificación anónima.
a. Identificador de Usuario Anónimo: Al usar la aplicación por primera vez, se genera un identificador único y aleatorio que se almacena localmente en su dispositivo. Este identificador nos permite asociar su progreso, puntuaciones y balance de monedas con una cuenta anónima en nuestros servidores.
b. Persistencia de Datos: Los datos asociados a su identificador anónimo (como su nombre de usuario, puntuaciones y balance de monedas) se almacenan en nuestros servidores seguros para garantizar que su progreso se mantenga mientras usa la aplicación.
c. Eliminación de Datos: Puede eliminar su cuenta y todos los datos asociados en cualquier momento desde la sección de perfil/ajustes de la aplicación.

3. Uso de la Información
Utilizamos la información técnica para:
- Personalizar la experiencia, el contenido (Top 10 regional) y los anuncios.
- Permitir la conexión con dispositivos de TV cercanos.
- Mantener su progreso de juego guardado en la nube.
No compartiremos ni venderemos su información a terceros.

4. Permisos de la Aplicación
Para funcionar correctamente, Bump Comba puede solicitar:
a. Notificaciones (POST_NOTIFICATIONS): Para recordatorios y mejoras en la experiencia de juego.
b. Dispositivos Cercanos / Red Local: Requerido en versiones modernas de Android para detectar y conectarse a dispositivos Cast (Chromecast) en su red Wi-Fi.

5. Advertencia sobre Consumo de Datos
La función de reproducción de video (M3U) consume una cantidad significativa de datos. Recomendamos utilizar una conexión Wi-Fi para evitar cargos en su factura de telefonía móvil. Bump Comba no se hace responsable por el consumo de datos móviles.

6. Publicidad de Terceros
Podemos permitir que terceros publiquen anuncios en nuestra app. Estos terceros pueden recopilar información anónima, como:

ID de publicidad de Google.
Tipo y versión del dispositivo.
Datos técnicos de navegación.
Esta información se utiliza exclusivamente para mostrar anuncios personalizados según sus intereses.

7. Procesadores de Pago
Si decide adquirir nuestra suscripción "Bump Comba Premium", el pago será procesado por proveedores de servicios externos, como Google Play Store. No recopilamos, almacenamos ni tenemos acceso a su información financiera confidencial, como los datos de su tarjeta de crédito. La gestión de esta información se rige por las políticas de privacidad de dichos proveedores.

8. Cookies
Utilizamos cookies para:

Mejorar su experiencia de navegación.
Recopilar datos estadísticos sobre el uso de nuestra app.
Puede aceptar o rechazar las cookies en cualquier momento; sin embargo, algunas funciones pueden no operar de manera óptima si las desactiva.

9. Enlaces a Terceros
Nuestra app o sitio web puede contener enlaces a otros sitios de interés. No somos responsables de la privacidad o seguridad de esos sitios externos, por lo que le recomendamos leer sus políticas de privacidad antes de proporcionarles información personal.

10. Grupo de Telegram
Contamos con un grupo de Telegram opcional, administrado por nosotros o nuestro equipo. La participación en este grupo es voluntaria. Cualquier dato compartido, como capturas de pantalla o mensajes, será bajo su control y responsabilidad.

11. Control de su Información Personal
Puede gestionar su información personal en cualquier momento:
Cancelar la suscripción a correos electrónicos mediante los enlaces proporcionados.
Restringir o eliminar su información desde las configuraciones de su cuenta.

12. Contenido Prohibido
No permitimos la publicación de contenido que incluya:

Material explícito o sexual.
Representaciones de violencia extrema.
Esto garantiza un entorno seguro y adecuado para todos los usuarios.

13. Cambios en la Política de Privacidad
Bump Comba se reserva el derecho de actualizar esta política en cualquier momento. Le recomendamos revisarla periódicamente para estar al tanto de posibles cambios.

14. Contacto
Si tiene preguntas, inquietudes o desea ejercer sus derechos en relación con sus datos personales, puede contactarnos en perritodoblas@gmail.com.

Si está sujeto al Reglamento General de Protección de Datos (RGPD), puede encontrar más información sobre sus derechos en ec.europa.eu.''',
      'dmca_text': '''Aviso Legal y Política DMCA de Bump Comba

Conformidad con la DMCA

Bump Comba cumple con el Digital Millennium Copyright Act (DMCA), según el 17 USC § 512. Estamos comprometidos con la protección de los derechos de autor y responderemos a cualquier notificación de infracción válida en conformidad con la ley.

Si considera que algún contenido de nuestra plataforma infringe sus derechos de autor, puede enviarnos una notificación siguiendo el procedimiento descrito a continuación.

Procedimiento para Notificaciones de DMCA
Si usted es el propietario de los derechos de autor o está autorizado para actuar en su nombre, puede enviar un aviso DMCA proporcionando la siguiente información:

Identificación del material protegido: Proporcione detalles suficientes para identificar claramente el contenido en nuestra plataforma.

Ubicación del contenido en cuestión: Indique la URL específica u otra información que permita localizar el material.

Información de contacto del reclamante: Incluya su nombre completo, dirección, correo electrónico y número de teléfono.

Declaración de buena fe: Confirme que cree de buena fe que el uso del contenido no está autorizado por el propietario de los derechos de autor, su representante o la ley.

Declaración de veracidad: Afirme, bajo pena de perjurio, que la información proporcionada es precisa y que está autorizado para actuar en nombre del propietario de los derechos de autor.

Firma: Proporcione su firma electrónica o física.
Puede enviar esta notificación a través de nuestro correo oficial, disponible en la sección de soporte de la aplicación.

Responsabilidad del Usuario
Los usuarios son responsables de garantizar que el contenido que compartan o accedan en Bump Comba cumpla con las leyes aplicables.
Bump Comba no respalda ni aprueba ningún contenido generado por usuarios u obtenido de terceros.

Propiedad Intelectual
Todo contenido, marcas y logotipos pertenecen a sus respectivos propietarios y se utilizan únicamente con fines informativos o de referencia en cumplimiento de las leyes de propiedad intelectual.
Cualquier contenido considerado de libre distribución ha sido obtenido de fuentes públicas. Si alguna parte del contenido infringe derechos, trabajaremos para solucionarlo de manera inmediata.

Enlaces a Contenido Externo
Bump Comba puede incluir enlaces o información a contenido externo (por ejemplo, Youtube, Emojipedia.org, Telegram, Digiload.co, Mystream.to, Uqload.com, Fembed.com, Tu.tv, Openload.co, Bigfile.to, Streamcloud.eu, allmyvideos.net, 1fichier.com, streamin.to, hugefiles.net, powvideo.net, uptobox.com, flashx.tv, ul.to, hqq.tv, mp4upload.com, yourupload.com, nowvideo.sx, etc.). Estos enlaces se proporcionan para la conveniencia del usuario y no implican una relación directa con los sitios vinculados.

No alojamos contenido protegido por derechos de autor. Los enlaces redirigen a plataformas externas que son responsables del contenido que alojan.
No controlamos ni garantizamos la calidad, precisión o legalidad del contenido proporcionado por terceros.

Medidas Correctivas
Una vez recibida una notificación válida, investigaremos y tomaremos las medidas necesarias, como la eliminación del contenido señalado.
Colaboraremos con los propietarios de derechos para garantizar el cumplimiento de las leyes aplicables.
Exención de Responsabilidad

Bump Comba no se hace responsable por el mal uso de la plataforma o de los enlaces proporcionados.

La responsabilidad del contenido externo recae únicamente en las plataformas que lo alojan. Al usar Bump Comba, usted acepta estas condiciones.
Cambios en la Política

Nos reservamos el derecho de actualizar esta política en cualquier momento. Cualquier cambio será reflejado en esta sección. Se recomienda revisarla periódicamente.

Si tiene alguna pregunta, inquietud o queja con respecto a nuestro cumplimiento de este aviso y las leyes de protección de datos, o si desea ejercer sus derechos, le recomendamos que primero se comunique con nosotros a perritodoblas@gmail.com.

Si usted es una persona física sujeta al RGPD, puede leer más sobre sus derechos aquí: ec.europa.eu/info/law/law-topic/data-protection_en''',
    },
    'en': {
      'settings': 'SETTINGS',
      'your_coins': 'YOUR COINS',
      'daily_challenge': 'DAILY CHALLENGE',
      'vibration': 'Vibration',
      'enabled': 'Enabled',
      'disabled': 'Disabled',
      'difficulty': 'Difficulty',
      'easy': 'Easy',
      'normal': 'Normal',
      'hard': 'Hard',
      'language': 'Language',
      'statistics': 'STATISTICS',
      'games_played': 'Games played',
      'total_merges': 'Total merges',
      'max_level': 'Max level',
      'best_score': 'Best score',
      'coins_earned': 'Coins earned',
      'current_streak': 'Current streak',
      'days': 'days',
      'achievements': 'ACHIEVEMENTS',
      'progress': 'Progress',
      'prestige': 'PRESTIGE',
      'shop': 'SHOP',
      'options': 'OPTIONS',
      'reset_progress': 'Reset Progress',
      'reset_all': 'Delete all (stats, coins, achievements)',
      'play': 'PLAY',
      'menu': 'MENU',
      'restart': 'RESTART',
      'game_over': 'GAME OVER',
      'new_record': 'NEW RECORD!',
      'score': 'Score',
      'level_reached': 'Level reached',
      'merges': 'Merges',
      'coins_won': 'Coins won',
      'challenge_complete':
          'Completed! Come back tomorrow for a new challenge.',
      'select_language': 'Select Language',
      'coins': 'coins',
      'buy_powerups': 'Buy power-ups with coins',
      'purchased': 'purchased! Available on your next game.',
      'prestige_level': 'Prestige',
      'bonus_points': 'points',
      'bonus_coins': 'coins',
      'bonus': 'Bonus',
      'can_prestige': 'You can prestige!',
      'reach_level_50': 'Reach level 50 to prestige',
      'prestige_dialog_title': 'PRESTIGE',
      'prestige_info': 'When prestiging:',
      'reset_max_level': 'Your max level resets',
      'reset_best_score': 'Your best score resets',
      'earn_coins': 'You earn',
      'permanent_points': 'points permanent',
      'permanent_coins': 'coins permanent',
      'keep_achievements': 'Keep achievements and statistics',
      'cancel': 'CANCEL',
      'do_prestige': 'DO PRESTIGE',
      'confirm_reset': 'Are you sure?',
      'reset_warning':
          'This will erase EVERYTHING: statistics, achievements, coins, prestige. This action cannot be undone.',
      'reset': 'RESET',
      'continue_btn': 'CONTINUE',
      'restricted_access': 'Restricted Access',
      'enter_code': 'Enter the code to continue',
      'best': 'BEST',
      'combine_sushi': 'Combine sushi to grow',
      'max_level_label': 'MAX LEVEL',
      'evolution': 'EVOLUTION',
      'difficulty_levels': 'DIFFICULTY LEVELS',
      'unlock_sushi': 'Level up to unlock new sushi!',
      'reach_level_challenge': 'Reach level',
      'do_merges': 'Do merges',
      'get_points': 'Get points',
      'get_combo': 'Get combo x',
      'next': 'NEXT',
      'use': 'USE',
      'achievement_unlocked': 'ACHIEVEMENT UNLOCKED!',
      // Social Rewards
      'earn_coins_title': 'SUPPORT & CONTACT',
      'rate_us': 'Rate us on Google Play',
      'share_app': 'Share app with friends',
      'reward_claimed': 'Reward claimed!',
      'rate_desc': 'Get 20 coins for your rating',
      'share_desc': 'Get 10 coins for sharing',
      'thanks_for_rating': 'Thanks for your rating!',
      'thanks_for_sharing': 'Thanks for sharing!',
      // Legal
      'legal': 'LEGAL',
      'privacy_policy': 'Privacy Policy',
      'dmca': 'DMCA',
      'close': 'CLOSE',
      'privacy_text':
          'Privacy Policy\n\n1. Data Collection: We do not collect personal data.\n2. Data Usage: Only used for game operation and local statistics.\n3. Third Parties: We do not share data with third parties.\n4. Security: Your data is secure on your device.\n5. Contact: For questions, contact support.',
      'dmca_text':
          'DMCA (Digital Millennium Copyright Act)\n\nWe respect the intellectual property rights of others. If you believe your work has been copied in a way that constitutes copyright infringement, please notify us.\n\nThis game is a work of fiction and any resemblance to actual persons or events is purely coincidental.',
    },
    'pt': {
      'settings': 'CONFIGURAÇÕES',
      'your_coins': 'SUAS MOEDAS',
      'daily_challenge': 'DESAFIO DIÁRIO',
      'vibration': 'Vibração',
      'enabled': 'Ativado',
      'disabled': 'Desativado',
      'difficulty': 'Dificuldade',
      'easy': 'Fácil',
      'normal': 'Normal',
      'hard': 'Difícil',
      'language': 'Idioma',
      'statistics': 'ESTATÍSTICAS',
      'games_played': 'Jogos jogados',
      'total_merges': 'Fusões totais',
      'max_level': 'Nível máximo',
      'best_score': 'Melhor pontuação',
      'coins_earned': 'Moedas ganhas',
      'current_streak': 'Sequência atual',
      'days': 'dias',
      'achievements': 'CONQUISTAS',
      'progress': 'Progresso',
      'prestige': 'PRESTÍGIO',
      'shop': 'LOJA',
      'options': 'OPÇÕES',
      'reset_progress': 'Redefinir Progresso',
      'reset_all': 'Apagar tudo (estatísticas, moedas, conquistas)',
      'play': 'JOGAR',
      'menu': 'MENU',
      'restart': 'REINICIAR',
      'game_over': 'FIM DE JOGO',
      'new_record': 'NOVO RECORDE!',
      'score': 'Pontuação',
      'level_reached': 'Nível alcançado',
      'merges': 'Fusões',
      'coins_won': 'Moedas ganhas',
    },
    'fr': {
      'settings': 'PARAMÈTRES',
      'your_coins': 'VOS PIÈCES',
      'vibration': 'Vibration',
      'enabled': 'Activée',
      'disabled': 'Désactivée',
      'difficulty': 'Difficulté',
      'easy': 'Facile',
      'normal': 'Normal',
      'hard': 'Difficile',
      'language': 'Langue',
      'play': 'JOUER',
    },
    'it': {
      'settings': 'IMPOSTAZIONI',
      'your_coins': 'LE TUE MONETE',
      'vibration': 'Vibrazione',
      'enabled': 'Attivata',
      'disabled': 'Disattivata',
      'difficulty': 'Difficoltà',
      'easy': 'Facile',
      'normal': 'Normale',
      'hard': 'Difficile',
      'language': 'Lingua',
      'play': 'GIOCA',
    },
    'zh': {
      'settings': '设置',
      'your_coins': '你的金币',
      'vibration': '振动',
      'enabled': '已开启',
      'disabled': '已关闭',
      'difficulty': '难度',
      'easy': '简单',
      'normal': '普通',
      'hard': '困难',
      'language': '语言',
      'play': '开始游戏',
    },
    'ko': {
      'settings': '설정',
      'your_coins': '내 코인',
      'vibration': '진동',
      'enabled': '켜짐',
      'disabled': '꺼짐',
      'difficulty': '난이도',
      'easy': '쉬움',
      'normal': '보통',
      'hard': '어려움',
      'language': '언어',
      'play': '게임 시작',
    },
    'ja': {
      'settings': '設定',
      'your_coins': 'あなたのコイン',
      'vibration': 'バイブレーション',
      'enabled': 'オン',
      'disabled': 'オフ',
      'difficulty': '難易度',
      'easy': '簡単',
      'normal': '普通',
      'hard': '難しい',
      'language': '言語',
      'play': 'プレイ',
    },
  };
}

class LanguageInfo {
  final String name;
  final String flag;
  final String code;

  const LanguageInfo(this.name, this.flag, this.code);
}
