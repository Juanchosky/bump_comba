import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/game_config_service.dart';
import '../services/m3u_service.dart';
import '../services/performance_service.dart';
import '../services/premium_service.dart';
import '../services/smart_notification_service.dart';
import 'subscription_screen.dart';

import '../utils/colors.dart';
import '../utils/snack_bar_utils.dart';

class StreamBrowserConfigScreen extends StatefulWidget {
  const StreamBrowserConfigScreen({super.key});

  @override
  State<StreamBrowserConfigScreen> createState() =>
      _StreamBrowserConfigScreenState();
}

class _StreamBrowserConfigScreenState extends State<StreamBrowserConfigScreen> {
  final M3UService _m3uService = M3UService();
  final GameConfigService _gameConfigService = GameConfigService();
  final PerformanceService _performanceService = PerformanceService();
  final PremiumService _premiumService = PremiumService();
  final SmartNotificationService _notificationService =
      SmartNotificationService();
  bool _isLoading = false;
  bool _wasDataChanged = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    // Ensure the notification service is ready so the toggle reflects the
    // stored on/off state.
    await _notificationService.initialize();
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = _m3uService.sources;
    final activeIndex = _m3uService.activeSourceIndex;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _wasDataChanged);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(CupertinoIcons.chevron_back, color: Colors.white),
            onPressed: () => Navigator.pop(context, _wasDataChanged),
          ),
          title: const Text(
            'Configuración',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(CupertinoIcons.add_circled, color: Colors.red),
              onPressed: _showAddSourceDialog,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              children: [
                // -- REPRODUCCIÓN ------------------------------------------
                _buildSectionHeader('Reproducción'),
                const SizedBox(height: 8),
                _buildCard([
                  _buildSwitchRow(
                    icon: CupertinoIcons.play_circle_fill,
                    title: 'Inicio Directo',
                    subtitle:
                        _gameConfigService.skipGameIntro
                            ? 'Salta el juego al iniciar'
                            : 'Va al juego primero',
                    value: _gameConfigService.skipGameIntro,
                    onChanged: (val) async {
                      await _gameConfigService.setSkipGameIntro(val);
                      setState(() {});
                    },
                    isLast: false,
                  ),
                  _buildDivider(),
                  _buildTapRow(
                    icon: CupertinoIcons.bolt_fill,
                    title: 'Efectos Visuales',
                    subtitle: _getPerformanceModeText(),
                    onTap: _showPerformanceConfigDialog,
                    isLast: false,
                  ),
                  _buildDivider(),
                  _buildSwitchRow(
                    icon: CupertinoIcons.bell_fill,
                    title: 'Recordatorios',
                    subtitle: 'Recordatorios para seguir viendo',
                    value: _notificationService.isEnabled,
                    onChanged: (val) async {
                      await _notificationService.setEnabled(val);
                      if (mounted) setState(() {});
                    },
                    isLast: true,
                  ),
                ]),

                const SizedBox(height: 24),

                // -- SUSCRIPCIÓN -------------------------------------------
                _buildSectionHeader('Suscripción'),
                const SizedBox(height: 8),
                _buildCard([
                  _buildPremiumRow(),
                ]),

                const SizedBox(height: 24),

                // -- COMUNIDAD ---------------------------------------------
                _buildSectionHeader('Comunidad'),
                const SizedBox(height: 8),
                _buildCard([
                  _buildTapRow(
                    icon: Icons.telegram,
                    iconColor: Colors.red,
                    title: 'Canal de Telegram',
                    subtitle: '¿No sabes usar la app? Obtén instrucciones aquí',
                    onTap: () => _launchURL('https://t.me/+0og3wmaKjkIwMzlh'),
                    isLast: true,
                  ),
                ]),

                const SizedBox(height: 24),

                // -- FUENTES -----------------------------------------------
                _buildSectionHeader('Fuentes de Contenido'),
                const SizedBox(height: 8),

                // Sources list
                if (sources.isEmpty)
                  _buildEmptySources()
                else
                  ...List.generate(sources.length, (index) {
                    final source = sources[index];
                    final isActive = index == activeIndex;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildSourceCard(index, source, isActive),
                    );
                  }),

                const SizedBox(height: 40),
              ],
            ),
            if (_isLoading)
              Container(
                color: Colors.black54,
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // -- SECTION HEADER ----------------------------------------------------------

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: Colors.red.withValues(alpha: 0.9),
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  // -- CARD CONTAINER ----------------------------------------------------------

  Widget _buildCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(
      height: 1,
      thickness: 0.5,
      color: Colors.white.withValues(alpha: 0.07),
      indent: 52,
    );
  }

  // -- ROW TYPES ---------------------------------------------------------------

  Widget _buildSwitchRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required bool isLast,
    bool isPro = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: Colors.white54, size: 17),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (isPro) ...[const SizedBox(width: 6), _buildProBadge()],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: Colors.red,
            trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildTapRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required bool isLast,
    Color? iconColor,
    EdgeInsets? padding,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding:
            padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: (iconColor ?? Colors.white).withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor ?? Colors.white54, size: 17),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              CupertinoIcons.chevron_right,
              color: Colors.white.withValues(alpha: 0.25),
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  // -- SOURCE CARD -------------------------------------------------------------

  Widget _buildSourceCard(int index, M3USource source, bool isActive) {
    return GestureDetector(
      onTap: () async {
        if (isActive) return;
        await _m3uService.setActiveSource(index);
        setState(() {});
        if (mounted) {
          SnackBarUtils.showAppSnackBar(
            context,
            'Fuente cambiada a ${source.name}',
          );
          Navigator.pop(
            context,
            true,
          ); // Return to main screen to trigger auto-refresh
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color:
              isActive
                  ? Colors.red.withValues(alpha: 0.08)
                  : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color:
                isActive
                    ? Colors.red.withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17.5),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color:
                    isActive
                        ? Colors.red.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isActive
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.link,
                color: isActive ? Colors.red : Colors.white30,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.name,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      source.isCode ? 'Mi fuente' : source.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            isActive
                                ? Colors.red.withValues(alpha: 0.8)
                                : Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Copy button - only show if NOT a code
            if (!source.isCode) ...[
              _buildIconAction(
                icon: CupertinoIcons.doc_on_clipboard,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: source.url));
                  SnackBarUtils.showAppSnackBar(context, 'URL copiada');
                },
              ),
              const SizedBox(width: 4),
            ],
            // Delete button
            _buildIconAction(
              icon: CupertinoIcons.trash,
              color: Colors.red.withValues(alpha: 0.7),
              onTap: () => _deleteSource(index),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIconAction({
    required IconData icon,
    Color? color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 15, color: color ?? Colors.white38),
      ),
    );
  }

  // -- EMPTY STATE -------------------------------------------------------------

  Widget _buildEmptySources() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Icon(
            CupertinoIcons.link_circle,
            size: 40,
            color: Colors.white.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 10),
          Text(
            'No hay fuentes guardadas',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Toca + para añadir una',
            style: TextStyle(
              color: Colors.red.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // -- HELPERS -----------------------------------------------------------------

  String _getPerformanceModeText() {
    switch (_performanceService.currentMode) {
      case PerformanceMode.auto:
        return 'Automático';
      case PerformanceMode.low:
        return 'Desactivado';
      case PerformanceMode.high:
        return 'Activado';
    }
  }

  Widget _buildProBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Colors.amber.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: const Text(
        'PRO',
        style: TextStyle(
          color: Colors.amber,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // -- DIALOGS -----------------------------------------------------------------

  void _showPerformanceConfigDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _AppBottomSheet(
          title: 'Efectos Visuales',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildBottomSheetOption(
                title: 'Automático',
                subtitle: 'El sistema decide según el dispositivo',
                isSelected:
                    _performanceService.currentMode == PerformanceMode.auto,
                onTap: () async {
                  await _performanceService.setPerformanceMode(
                    PerformanceMode.auto,
                  );
                  setState(() {});
                  if (context.mounted) Navigator.pop(context);
                },
              ),
              _buildBottomSheetOption(
                title: 'Desactivado',
                subtitle: 'Sin efectos — máxima fluidez',
                isSelected:
                    _performanceService.currentMode == PerformanceMode.low,
                onTap: () async {
                  await _performanceService.setPerformanceMode(
                    PerformanceMode.low,
                  );
                  setState(() {});
                  if (context.mounted) Navigator.pop(context);
                },
              ),
              _buildBottomSheetOption(
                title: 'Activado',
                subtitle: 'Efectos completos — mejor visual',
                isSelected:
                    _performanceService.currentMode == PerformanceMode.high,
                onTap: () async {
                  await _performanceService.setPerformanceMode(
                    PerformanceMode.high,
                  );
                  setState(() {});
                  if (context.mounted) Navigator.pop(context);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deleteSource(int index) async {
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _AppBottomSheet(
          title: '¿Eliminar fuente?',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Text(
                  'Esta acción no se puede deshacer. El contenido de esta fuente dejará de estar disponible.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 14,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildSheetButton(
                        label: 'Cancelar',
                        onTap: () => Navigator.pop(context, false),
                        isPrimary: false,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildSheetButton(
                        label: 'Eliminar',
                        onTap: () => Navigator.pop(context, true),
                        isPrimary: true,
                        isDanger: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (confirm == true) {
      await _m3uService.removeSource(index);
      _wasDataChanged = true;
      setState(() {});
    }
  }

  void _showAddSourceDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (dialogContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: _AppBottomSheet(
            title: 'Añadir Fuente',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSheetTextField(
                    controller: nameController,
                    label: 'Nombre de la fuente',
                    icon: CupertinoIcons.tag,
                    autofocus: true,
                  ),
                  const SizedBox(height: 12),

                  _buildSheetTextField(
                    controller: urlController,
                    label: 'URL M3U',
                    icon: CupertinoIcons.link,
                  ),

                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: _buildSheetButton(
                          label: 'Cancelar',
                          onTap: () => Navigator.pop(dialogContext),
                          isPrimary: false,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildSheetButton(
                          label: 'Guardar',
                          onTap: () async {
                            final name = nameController.text.trim();
                            final input = urlController.text.trim();
                            if (name.isEmpty || input.isEmpty) return;

                            Navigator.pop(dialogContext);
                            setState(() => _isLoading = true);

                            // Resolve input (Code or URL)
                            final result = await _m3uService.resolveM3UInput(
                              input,
                            );

                            if (result.url != null) {
                              await _m3uService.addSource(
                                name,
                                result.url!,
                                isCode: result.isCode,
                                originalInput: result.isCode ? input : null,
                                username: result.username,
                                password: result.password,
                                type: result.type,
                              );
                              await _m3uService.setActiveSource(
                                _m3uService.sources.length - 1,
                              );
                              setState(() => _isLoading = false);
                              if (mounted) {
                                Navigator.pop(context, true);
                              }
                            } else {
                              setState(() => _isLoading = false);
                              if (mounted) {
                                SnackBarUtils.showAppSnackBar(
                                  context,
                                  'URL no válidos',
                                );
                              }
                            }
                          },
                          isPrimary: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // -- SHEET HELPERS ------------------------------------------------------------

  Widget _buildBottomSheetOption({
    required String title,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected ? Colors.red : Colors.white,
                      fontSize: 16,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                CupertinoIcons.checkmark_circle_fill,
                color: Colors.red,
                size: 20,
              )
            else
              Icon(
                CupertinoIcons.circle,
                color: Colors.white.withValues(alpha: 0.2),
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool autofocus = false,
    bool isPassword = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        obscureText: isPassword,
        style: const TextStyle(color: Colors.white, fontSize: 15),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: Colors.white38, size: 18),
          hintText: label,
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 15,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _buildSheetButton({
    required String label,
    required VoidCallback onTap,
    required bool isPrimary,
    bool isDanger = false,
  }) {
    final bgColor =
        isPrimary
            ? isDanger
                ? Colors.red.withValues(alpha: 0.15)
                : Colors.red
            : Colors.white.withValues(alpha: 0.07);

    final textColor =
        isPrimary
            ? isDanger
                ? Colors.red
                : Colors.white
            : Colors.white.withValues(alpha: 0.6);

    final borderColor =
        isPrimary
            ? isDanger
                ? Colors.red.withValues(alpha: 0.4)
                : Colors.transparent
            : Colors.white.withValues(alpha: 0.1);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildPremiumRow() {
    final isPremium = _premiumService.isPremium;

    return InkWell(
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: (isPremium ? const Color(0xFFFFD700) : Colors.amber).withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                isPremium ? CupertinoIcons.checkmark_seal_fill : CupertinoIcons.checkmark_seal,
                color: isPremium ? const Color(0xFFFFD700) : Colors.amber,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        isPremium ? '¡Ahora eres Premium!' : 'Hazte Premium',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (isPremium) ...[
                        const SizedBox(width: 8),
                        _buildPremiumBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isPremium
                        ? 'Disfruta de tu estatus exclusivo sin límites'
                        : 'Sin anuncios  •  Contenido 4K  •  Soporte VIP',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              CupertinoIcons.chevron_right,
              color: Colors.white.withValues(alpha: 0.25),
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPremiumBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFD700).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xFFFFD700).withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: const Text(
        'PREMIUM',
        style: TextStyle(
          color: Color(0xFFFFD700),
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
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
                    backgroundColor: const Color.fromARGB(255, 20, 20, 20),
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

                const SizedBox(height: 16),

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
        SnackBarUtils.showAppSnackBar(context, "No se pudo abrir el enlace");
      }
    }
  }
}

// -- SHARED BOTTOM SHEET CONTAINER -------------------------------------------

class _AppBottomSheet extends StatelessWidget {
  final String title;
  final Widget child;

  const _AppBottomSheet({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          // Handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.07)),
          child,
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
