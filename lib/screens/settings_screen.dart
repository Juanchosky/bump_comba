import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shimmer/shimmer.dart';

import '../services/game_config_service.dart';
import '../utils/colors.dart';
import '../services/score_service.dart';
import '../services/localization_service.dart';
import '../services/m3u_service.dart';
import '../services/social_rewards_service.dart';
import '../services/premium_service.dart';
import 'stream_browser_screen.dart';
import 'subscription_screen.dart';
import '../utils/snack_bar_utils.dart';
import '../services/ad_service.dart';

import '../widgets/disclaimer_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  final GameConfigService _configService = GameConfigService();
  final ScoreService _scoreService = ScoreService();
  final LocalizationService _locService = LocalizationService();
  final M3UService _m3uService = M3UService();
  final SocialRewardsService _rewardsService = SocialRewardsService();
  final PremiumService _premiumService = PremiumService();
  bool _isLoading = false;
  @override
  void initState() {
    super.initState();

    _loadSettings();
  }

  Future<void> _loadSettings() async {
    // If services are already initialized (singleton), initializers should handle idempotency,
    // but we can skip heavy lifting.
    await _configService.init();
    await _scoreService.init();
    await _locService.init();
    await _m3uService.init();
    await _rewardsService.init();

    await _rewardsService.init();

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
      _checkDisclaimer();
    }
  }

  Future<void> _checkDisclaimer() async {
    final prefs = await SharedPreferences.getInstance();
    final accepted = prefs.getBool('disclaimer_accepted') ?? false;

    if (!accepted && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => DisclaimerDialog(
              onAccept: () {
                Navigator.pop(context); // Close dialog
              },
            ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isPC =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;

    return Scaffold(
      body: Stack(
        children: [
          // Background Flipped & Faded
          Positioned.fill(
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.rotationY(3.14159), // Flip horizontally
              child: Container(
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: const AssetImage('assets/images/background.png'),
                    fit: BoxFit.cover,
                    colorFilter: ColorFilter.mode(
                      const Color(
                        0xFF0a0a0a,
                      ).withOpacity(0.5), // More visible (was 0.8)
                      BlendMode.darken,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Content
          SafeArea(
            child:
                _isLoading
                    ? _buildShimmerLoading()
                    : Column(
                      children: [
                        _buildHeader(),
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              // Coins display (hidden when Stream Browser is active)
                              if (!isPC &&
                                  !(_configService.difficulty == 3 &&
                                      !_configService.vibrationEnabled))
                                _buildCoinsCard(),
                              if (!isPC) const SizedBox(height: 9),

                              // Stream Browser (hidden feature)
                              if (!isPC &&
                                  _configService.difficulty == 3 &&
                                  !_configService.vibrationEnabled)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 0),
                                  child: TweenAnimationBuilder<double>(
                                    tween: Tween(begin: 0.0, end: 1.0),
                                    duration: const Duration(milliseconds: 700),
                                    curve: Curves.easeOutCubic,
                                    builder: (context, value, child) {
                                      return Opacity(
                                        opacity: value,
                                        child: Transform.translate(
                                          offset: Offset(0, 20 * (1 - value)),
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(14),
                                        onTap: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder:
                                                  (context) =>
                                                      const StreamBrowserScreen(),
                                            ),
                                          );
                                        },
                                        child: Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 18,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFE53935),
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                            border: const Border(
                                              bottom: BorderSide(
                                                color: Color(0xFF9A1B1B),
                                                width: 5,
                                              ),
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              TweenAnimationBuilder<double>(
                                                tween: Tween(
                                                  begin: 0.4,
                                                  end: 1.0,
                                                ),
                                                duration: const Duration(
                                                  milliseconds: 1000,
                                                ),
                                                builder: (
                                                  context,
                                                  value,
                                                  child,
                                                ) {
                                                  return Opacity(
                                                    opacity: value,
                                                    child: child,
                                                  );
                                                },
                                                child: const Icon(
                                                  CupertinoIcons
                                                      .antenna_radiowaves_left_right,
                                                  color: Colors.white,
                                                  size: 24,
                                                  // No shadowing/glow
                                                ),
                                              ),
                                              const SizedBox(width: 14),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      'Stream Browser',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                      ),
                                                    ),
                                                    SizedBox(height: 3),
                                                    Text(
                                                      'Lector de listas de terceros',
                                                      style: TextStyle(
                                                        color: Colors.white
                                                            .withOpacity(0.7),
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              TweenAnimationBuilder<double>(
                                                tween: Tween(
                                                  begin: 0.0,
                                                  end: 1.0,
                                                ),
                                                duration: const Duration(
                                                  milliseconds: 1200,
                                                ),
                                                builder: (
                                                  context,
                                                  value,
                                                  child,
                                                ) {
                                                  // Continuous bounce using a sine wave
                                                  final offset =
                                                      3.0 *
                                                      (0.5 +
                                                          0.5 *
                                                              (1 -
                                                                  (2 * value -
                                                                          1)
                                                                      .abs()));
                                                  return Transform.translate(
                                                    offset: Offset(offset, 0),
                                                    child: child,
                                                  );
                                                },
                                                child: Icon(
                                                  Icons.chevron_right_rounded,
                                                  color: Colors.white
                                                      .withOpacity(0.5),
                                                  size: 22,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),

                              // Premium section
                              const SizedBox(height: 25),
                              _buildPremiumSection(),

                              if (!isPC) ...[
                                const SizedBox(height: 35),
                                _buildSectionTitle(
                                  _locService.tr('earn_coins_title'),
                                ),
                                _buildSocialRewardsSection(),
                              ],

                              const SizedBox(height: 20),
                              _buildSectionTitle(_locService.tr('settings')),
                              _buildLanguageTile(),
                              if (!isPC) ...[
                                const SizedBox(height: 8),
                                _buildVibrationTile(),
                                const SizedBox(height: 8),
                                _buildDifficultyTile(),
                              ],

                              const SizedBox(height: 20),
                              _buildSectionTitle(_locService.tr('legal')),
                              _buildPrivacyTile(),
                              const SizedBox(height: 8),
                              _buildPrivacyOptionsTile(),
                              const SizedBox(height: 8),
                              _buildDMCATile(),
                              const SizedBox(height: 8),
                              _buildLegalDisclaimerTile(),

                              const SizedBox(height: 20),
                              _buildSectionTitle(_locService.tr('options')),
                              _buildResetTile(),

                              const SizedBox(height: 40),
                            ],
                          ),
                        ),
                      ],
                    ),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: Colors.white.withOpacity(0.05),
      highlightColor: Colors.white.withOpacity(0.2),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header placeholder
            Container(
              height: 50,
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            // Coins card placeholder
            Container(
              height: 100,
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 30),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            // List items
            Expanded(
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 6,
                separatorBuilder: (_, _) => const SizedBox(height: 16),
                itemBuilder:
                    (_, _) => Container(
                      height: 60,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          ),
          Expanded(
            child: Text(
              _locService.tr('settings').substring(0, 1).toUpperCase() +
                  _locService.tr('settings').substring(1).toLowerCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5,
                shadows: [
                  Shadow(
                    color: Colors.black26,
                    offset: Offset(0, 2),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildCoinsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFF9600),
        borderRadius: BorderRadius.circular(16),
        border: const Border(
          bottom: BorderSide(color: Color(0xFFB25000), width: 8),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _locService.tr('your_coins'),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.black54,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  '${_configService.coins}',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_configService.dailyStreak > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0a0a0a).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Tu racha:',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${_configService.dailyStreak} ${_locService.tr('days')}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black87,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPremiumSection() {
    final isPremium = _premiumService.isPremium;

    return _SettingsTile(
      icon:
          isPremium
              ? CupertinoIcons.checkmark_seal
              : CupertinoIcons.checkmark_seal,
      iconColor: isPremium ? const Color(0xFFFFD700) : Colors.amber,
      title: isPremium ? '¡Ahora eres Premium!' : 'Hazte Premium',
      titleSize: 16,
      subtitle:
          isPremium
              ? 'Disfruta de tu estatus exclusivo sin límites'
              : 'Desbloquea una experiencia sin límites',
      customSubtitle:
          isPremium
              ? Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD700).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'ESTATUS PREMIUM',
                  style: TextStyle(
                    color: Color(0xFFFFD700),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
              )
              : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Sin anuncios  •  Contenido 4K  •  Soporte VIP',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
      trailing:
          isPremium
              ? const Icon(
                Icons.chevron_right_outlined,
                color: Colors.white54,
                size: 23,
              )
              : null,
      onTap: () async {
        if (!isPremium) {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const SubscriptionScreen()),
          );
          if (result == true && mounted) {
            setState(() {});
          }
        } else {
          _showSubscriptionDetails();
        }
      },
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color: Colors.white,
          letterSpacing: 2,
          shadows: [Shadow(color: Colors.black26, blurRadius: 4)],
        ),
      ),
    );
  }

  Widget _buildVibrationTile() {
    return _SettingsTile(
      icon: Icons.vibration,
      title: _locService.tr('vibration'),
      subtitle:
          _configService.vibrationEnabled
              ? _locService.tr('enabled')
              : _locService.tr('disabled'),
      trailing: Switch(
        value: _configService.vibrationEnabled,
        onChanged: (value) async {
          await _configService.setVibration(value);
          setState(() {});
        },
        activeThumbColor: const Color(0xFFFF6B6B),
      ),
    );
  }

  Widget _buildDifficultyTile() {
    final difficulties = [
      _locService.tr('easy'),
      _locService.tr('normal'),
      _locService.tr('hard'),
    ];
    final colors = [Colors.green, Colors.orange, Colors.red];
    final multipliers = ['0.8x', '1.0x', '1.3x'];

    return _SettingsTile(
      icon: Icons.speed,
      title: _locService.tr('difficulty'),
      subtitle:
          '${difficulties[_configService.difficulty - 1]} (${multipliers[_configService.difficulty - 1]})',
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: colors[_configService.difficulty - 1].withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors[_configService.difficulty - 1]),
          boxShadow: [
            BoxShadow(
              color: colors[_configService.difficulty - 1].withOpacity(0.5),
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: DropdownButton<int>(
          value: _configService.difficulty,
          dropdownColor: const Color(0xFF2d3436),
          underline: const SizedBox(),
          isDense: true,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
          icon: Icon(
            Icons.arrow_drop_down,
            color: colors[_configService.difficulty - 1],
          ),
          items:
              [1, 2, 3].map((d) {
                return DropdownMenuItem(
                  value: d,
                  child: Text(
                    difficulties[d - 1],
                    style: TextStyle(color: colors[d - 1]),
                  ),
                );
              }).toList(),
          onChanged: (value) async {
            if (value != null) {
              await _configService.setDifficulty(value);
              setState(() {});
            }
          },
        ),
      ),
    );
  }

  Widget _buildLanguageTile() {
    final currentLang = _locService.currentLanguageInfo;

    return _SettingsTile(
      icon: Icons.language,
      title: _locService.tr('language'),
      subtitle: currentLang.name,
      onTap: () => _showLanguageDialog(),
    );
  }

  void _showLanguageDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF2d3436),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFF0a0a0a), width: 3),
            ),
            title: Text(
              _locService.tr('select_language'),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
              textAlign: TextAlign.center,
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: LocalizationService.languages.length,
                itemBuilder: (context, index) {
                  final entry = LocalizationService.languages.entries.elementAt(
                    index,
                  );
                  final code = entry.key;
                  final lang = entry.value;
                  final isSelected = code == _locService.currentLanguage;

                  return Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color:
                          isSelected
                              ? const Color(0xFF58CC02).withOpacity(0.2)
                              : const Color(
                                0xFF636e72,
                              ), // Lighter grey for unselected
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color:
                            isSelected
                                ? const Color(0xFF58CC02)
                                : const Color(0xFF0a0a0a),
                        width: 2,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0xFF0a0a0a),
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ListTile(
                      title: Text(
                        lang.name,
                        style: TextStyle(
                          color:
                              isSelected
                                  ? const Color(0xFF58CC02)
                                  : Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      trailing:
                          isSelected
                              ? const Icon(
                                Icons.check_circle,
                                color: Color(0xFF58CC02),
                              )
                              : null,
                      onTap: () async {
                        Navigator.pop(context);

                        await _locService.setLanguage(code);
                        setState(() {});
                      },
                    ),
                  );
                },
              ),
            ),
          ),
    );
  }

  Widget _buildResetTile() {
    return _SettingsTile(
      icon: Icons.delete_forever,
      iconColor: Colors.red,
      title: _locService.tr('reset_progress'),
      subtitle: _locService.tr('reset_all'),
      onTap: () => _showResetDialog(),
    );
  }

  Widget _buildPrivacyTile() {
    return _SettingsTile(
      icon: Icons.privacy_tip_outlined,
      title: _locService.tr('privacy_policy'),
      onTap:
          () => _showTextDialog(
            _locService.tr('privacy_policy'),
            _locService.tr('privacy_text'),
          ),
    );
  }

  Widget _buildDMCATile() {
    return _SettingsTile(
      icon: Icons.copyright,
      title: _locService.tr('dmca'),
      onTap:
          () => _showTextDialog(
            _locService.tr('dmca'),
            _locService.tr('dmca_text'),
          ),
    );
  }

  Widget _buildLegalDisclaimerTile() {
    return _SettingsTile(
      icon: Icons.gavel,
      title: 'Aviso Legal',
      onTap:
          () => showDialog(
            context: context,
            builder:
                (context) =>
                    DisclaimerDialog(onAccept: () => Navigator.pop(context)),
          ),
    );
  }

  Widget _buildPrivacyOptionsTile() {
    return _SettingsTile(
      icon: Icons.manage_accounts_outlined,
      title: 'Opciones de Privacidad',
      subtitle: 'Configurar preferencias de anuncios',
      onTap: () => AdService().showPrivacyOptionsForm(),
    );
  }

  void _showTextDialog(String title, String content) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF2d3436),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFF0a0a0a), width: 3),
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 20,
              ),
              textAlign: TextAlign.center,
            ),
            content: SingleChildScrollView(
              child: Text(
                content,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
            actions: [
              Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2d3436),
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white, width: 1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 12,
                    ),
                  ),
                  child: Text(
                    _locService.tr('close'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
    );
  }

  void _showResetDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF2d3436),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFF0a0a0a), width: 3),
            ),
            title: Text(
              '⚠️ ${_locService.tr('reset_progress')}',
              style: const TextStyle(
                fontSize: 18,
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
              textAlign: TextAlign.left,
            ),
            content: Text(
              _locService.tr('reset_warning'),
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.bold,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  _locService.tr('cancel').toUpperCase(),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  await _configService.resetStats();
                  await _scoreService.resetHighScore();
                  if (mounted) {
                    Navigator.pop(context);
                    setState(() {});
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                child: Text(
                  _locService.tr('reset').toUpperCase(),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
    );
  }

  Widget _buildSocialRewardsSection() {
    return Column(
      children: [
        _SettingsTile(
          icon: Icons.telegram,
          iconColor: Colors.red,
          title: "Canal de Telegram",
          subtitle: "¿No sabes usar la app? Obtén instrucciones aquí",
          onTap: () {
            if (_configService.showExternalLinkWarning) {
              _showExternalLinkDialog("https://t.me/+0og3wmaKjkIwMzlh");
            } else {
              _launchURL("https://t.me/+0og3wmaKjkIwMzlh");
            }
          },
        ),
      ],
    );
  }

  void _showAppSnackBar(String message) {
    SnackBarUtils.showAppSnackBar(context, message);
  }

  void _showSubscriptionDetails() {
    final expirationDateStr = _premiumService.expirationDate;
    final managementUrl = _premiumService.managementUrl;

    String dateDisplay = "Renovación automática activa";
    if (expirationDateStr != null) {
      try {
        final date = DateTime.parse(expirationDateStr);
        dateDisplay = "Vence el: ${date.day}/${date.month}/${date.year}";
      } catch (e) {
        debugPrint("Error parsing date: $e");
      }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder:
          (context) => Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Color.fromARGB(255, 20, 20, 20),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              ),
              border: Border(
                top: BorderSide(color: Color(0xFFFFD700), width: 2),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 24),

                // Icon
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD700).withOpacity(0.1),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFFFD700).withOpacity(0.5),
                    ),
                  ),
                  child: const Icon(
                    CupertinoIcons.checkmark_seal,
                    color: Color(0xFFFFD700),
                    size: 37,
                  ),
                ),
                const SizedBox(height: 17),

                // Title with Check
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "Membresía Premium Activa",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.all(2),

                      child: const Icon(
                        Icons.check_circle_outline_rounded,
                        color: Color(0xFFFFD700),
                        size: 23,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 8),
                Text(
                  dateDisplay,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 14,
                  ),
                ),

                const SizedBox(height: 13),

                // Manage Button
                ElevatedButton(
                  onPressed: () {
                    final url =
                        managementUrl ??
                        (Theme.of(context).platform == TargetPlatform.android
                            ? 'https://play.google.com/store/account/subscriptions'
                            : 'https://apps.apple.com/account/subscriptions');
                    _launchURL(url);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Color.fromARGB(255, 20, 20, 20),
                    foregroundColor: const Color.fromARGB(255, 85, 85, 85),

                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 12,
                    ),
                    minimumSize: const Size(200, 48), // Standard button size
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    "Gestionar Suscripción",
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
                  ),
                ),

                Text(
                  "Puedes cancelar tu suscripción en cualquier momento desde la tienda de aplicaciones. La cancelación entrará en vigor al finalizar el periodo actual.",
                  style: TextStyle(
                    color: const Color.fromARGB(255, 80, 80, 80),
                    fontSize: 12,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
    );
  }

  Future<void> _launchURL(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        _showAppSnackBar("No se pudo abrir el enlace");
      }
    }
  }

  void _showExternalLinkDialog(String url) {
    bool dontShowAgain = true; // Default to true as requested

    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                backgroundColor: const Color(0xFF2d3436),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Color(0xFF0a0a0a), width: 3),
                ),
                titlePadding: const EdgeInsets.fromLTRB(25, 25, 25, 25),
                contentPadding: const EdgeInsets.fromLTRB(25, 0, 25, 25),
                title: const Text(
                  '🌐 Abrir enlace externo',
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                  textAlign: TextAlign.left,
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Estás a punto de salir de la aplicación para abrir un enlace externo. ¿Deseas continuar?',
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.left,
                    ),
                    const SizedBox(height: 22),
                    GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          dontShowAgain = !dontShowAgain;
                        });
                      },
                      child: Row(
                        children: [
                          SizedBox(
                            height: 23,
                            width: 23,
                            child: Theme(
                              data: ThemeData(
                                unselectedWidgetColor: Colors.white54,
                              ),
                              child: Checkbox(
                                value: dontShowAgain,
                                activeColor: Colors.red,
                                checkColor: Colors.white,
                                onChanged: (value) {
                                  setDialogState(() {
                                    dontShowAgain = value ?? false;
                                  });
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'No volver a mostrar',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'CANCELAR',
                      style: TextStyle(
                        color: Colors.white54,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      if (dontShowAgain) {
                        await _configService.setShowExternalLinkWarning(false);
                      }
                      if (mounted) {
                        Navigator.pop(context);
                        _launchURL(url);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                    child: const Text(
                      'ACEPTAR',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.customSubtitle,
    this.trailing,
    this.onTap,
    this.iconColor,
    this.titleSize,
  });

  final IconData icon;
  final String title;
  final double? titleSize;
  final String? subtitle;
  final Widget? customSubtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF2d3436),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF0a0a0a), width: 2),
          boxShadow: const [
            BoxShadow(color: Color(0xFF0a0a0a), offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? Colors.red, size: 26),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: titleSize ?? 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  if (subtitle != null) // Conditional rendering
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  if (customSubtitle != null) customSubtitle!,
                ],
              ),
            ),
            if (trailing != null) trailing!,
            if (onTap != null && trailing == null)
              Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.5)),
          ],
        ),
      ),
    );
  }
}
