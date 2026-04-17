import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'game_config_service.dart';

class SocialRewardsService {
  static const String _ratedKey = 'reward_rated';
  static const String _sharedKey = 'reward_shared';
  static const String _launchCountKey = 'launch_count';
  static const String _playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.juanchosky.bumpcomba';

  static final SocialRewardsService _instance =
      SocialRewardsService._internal();
  factory SocialRewardsService() => _instance;
  SocialRewardsService._internal();

  SharedPreferences? _prefs;
  final GameConfigService _configService = GameConfigService();

  bool _isRated = false;
  bool _isShared = false;

  bool get isRated => _isRated;
  bool get isShared => _isShared;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _isRated = _prefs?.getBool(_ratedKey) ?? false;
    _isShared = _prefs?.getBool(_sharedKey) ?? false;
  }

  Future<bool> rateApp() async {
    if (_isRated) return false;

    final Uri url = Uri.parse(_playStoreUrl);
    try {
      // Try to launch directly. canLaunchUrl can sometimes be false negative.
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) {
        _isRated = true;
        await _prefs?.setBool(_ratedKey, true);
        await _configService.addCoins(20);
        return true;
      }
    } catch (e) {
      // If launch fails, we don't award coins because they couldn't rate.
      // But we prevent the app from crashing.
      print('Error launching rate URL: $e');
    }
    return false;
  }

  Future<void> shareApp() async {
    final String text =
        '¡Mira esta app increíble para ver pelis y jugar con sushi! Descarga Bump Comba aquí: $_playStoreUrl';

    // On Android, ShareResultStatus is not always reliable.
    // We award coins for the attempt to share.
    await Share.share(text);

    if (!_isShared) {
      _isShared = true;
      await _prefs?.setBool(_sharedKey, true);
      await _configService.addCoins(10);
    }
  }

  Future<void> incrementLaunchCount() async {
    _prefs ??= await SharedPreferences.getInstance();
    int count = _prefs?.getInt(_launchCountKey) ?? 0;
    count++;
    await _prefs?.setInt(_launchCountKey, count);
  }

  bool shouldShowRateDialog() {
    if (_isRated) return false;
    int count = _prefs?.getInt(_launchCountKey) ?? 0;
    // Show every 3 launches (3, 6, 9...)
    return count > 0 && count % 3 == 0;
  }
}
