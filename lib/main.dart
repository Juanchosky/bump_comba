import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/splash_screen.dart';
import 'services/ad_service.dart';
import 'services/m3u_service.dart';
import 'services/onesignal_service.dart';
import 'services/performance_service.dart';
import 'services/premium_service.dart';
import 'services/smart_notification_service.dart';

import 'utils/colors.dart';
import 'services/cast_audio_handler.dart';

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..maxConnectionsPerHost = 5
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 10);
  }
}

void main() {
  if (!kIsWeb) {
    HttpOverrides.global = MyHttpOverrides();
  }
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await initAudioService();
      await dotenv.load(fileName: ".env");

      // ── 1. SINCRNICO  antes del primer frame ───────────
      GoogleFonts.config.allowRuntimeFetching = false;

      final originalOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        final msg = details.exception.toString();

        // Silenciar errores de fuentes de Google
        if (msg.contains('font') ||
            msg.contains('gstatic') ||
            msg.contains('GoogleFonts')) {
          debugPrint('Font load error (ignorado): ${details.exception}');
          return;
        }

        // Silenciar el error de contexto desmontado que ya se maneja
        // defensivamente en fast_image_service.dart y content_detail_screen.dart.
        // Llega aquí solo cuando algún precacheImage interno de Flutter lo atrapa
        // antes de que nuestro guard pueda bloquearlo.
        if (msg.contains('unmounted') ||
            msg.contains('no longer has a context') ||
            msg.contains('considered defunct')) {
          debugPrint('Unmounted-context error ignorado (manejado): $msg');
          return;
        }

        originalOnError?.call(details);
      };

      MediaKit.ensureInitialized();

      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);

        // Configuración Edge-to-Edge para Android 15+
        // Para SDK 35 (Android 15), el sistema ignora statusBarColor si es
        // forzado. Usamos una configuración mínima que no active las
        // alertas de APIs deprecadas.
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        SystemChrome.setSystemUIOverlayStyle(
          const SystemUiOverlayStyle(
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarIconBrightness: Brightness.light,
          ),
        );
      }

      // ── 2. BACKGROUND — solo Supabase y Premium aquí ───────────────────
      // PerformanceService NO va aquí: device_info_plus en Android 10 con
      // GPU PowerVR bloquea el platform channel ~3-6s aunque sea unawaited.
      // Se mueve al post-frame para que el splash sea visible primero.

      // a) Supabase — necesario para M3UService y PremiumService
      unawaited(
        M3UService.initializeSupabase().catchError((e) {
          debugPrint('Supabase init error (no crítico): $e');
        }),
      );

      // b) PremiumService — usa cache local si Supabase no está listo aún
      unawaited(
        Future.delayed(const Duration(milliseconds: 200)).then((_) {
          return PremiumService().initialize().catchError((e) {
            debugPrint('PremiumService init error (no crítico): $e');
          });
        }),
      );

      // ── 3. RENDER INMEDIATO ─────────────────────────────────────────────
      runApp(const BumpCombaApp());

      // ── 4. POST-FRAME — todo lo que usa platform channels pesados ───────
      // En dispositivos lentos (Android 10, PowerVR SGX), cualquier llamada
      // a platform channels durante el arranque bloquea el main thread.
      // Al ponerlos post-frame, el splash ya es visible antes de que empiecen.
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // PerformanceService a 1s — device_info_plus era el culpable del
          // "doFrame is 6461ms late" en los logs anteriores.
          Future.delayed(const Duration(seconds: 1), () {
            unawaited(
              PerformanceService()
                  .init()
                  .timeout(
                    const Duration(seconds: 5),
                    onTimeout:
                        () => debugPrint(
                          'PerformanceService timeout — usando defaults',
                        ),
                  )
                  .then((_) {
                    // PerformanceService init already applies cache limits
                  })
                  .catchError((e) {
                    debugPrint('PerformanceService error (no crítico): $e');
                  }),
            );
          });

          // AdMob y OneSignal a 3s — los más pesados, van al final.
          // AdMob carga WebView internamente, muy costoso en hardware viejo.
          Future.delayed(const Duration(seconds: 3), () {
            unawaited(
              AdService().initialize().catchError((e) {
                debugPrint('AdService init error (no crítico): $e');
              }),
            );
            unawaited(
              OneSignalService().initialize().catchError((e) {
                debugPrint('OneSignal init error (no crítico): $e');
              }),
            );
            // Notificaciones locales inteligentes: tras inicializar, programa
            // un único recordatorio personalizado según lo último que vio el
            // usuario. refreshReminders se vuelve a llamar en cada cambio de
            // ciclo de vida para no acumular notificaciones.
            unawaited(
              SmartNotificationService().initialize().then((_) {
                return SmartNotificationService().refreshReminders();
              }).catchError((e) {
                debugPrint('SmartNotifications init error (no crítico): $e');
              }),
            );
          });
        });
      }
    },
    (error, stack) {
      final msg = error.toString();

      // Errores esperados y ya manejados defensivamente — solo logear sin stack
      if (error is SocketException ||
          msg.contains('unmounted') ||
          msg.contains('no longer has a context') ||
          msg.contains('considered defunct')) {
        debugPrint('Global error ignorado (esperado): $msg');
        return;
      }

      debugPrint('Global unhandled error caught: $error');
      debugPrint('$stack');
    },
  );
}

class BumpCombaApp extends StatefulWidget {
  const BumpCombaApp({super.key});

  @override
  State<BumpCombaApp> createState() => _BumpCombaAppState();
}

class _BumpCombaAppState extends State<BumpCombaApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Cuando la app pasa a segundo plano, reprogramamos el recordatorio con el
    // progreso de visionado más reciente. Como refreshReminders cancela antes
    // de programar, nunca se acumulan notificaciones y un usuario activo no
    // recibe ninguna mientras usa la app.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(SmartNotificationService().refreshReminders());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bump Comba',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.dark,
          surface: AppColors.background,
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.background,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.background,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
        ),
      ),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.noScaling),
          child: child!,
        );
      },
      home: const SplashScreen(),
    );
  }
}
