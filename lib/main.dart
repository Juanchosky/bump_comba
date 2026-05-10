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
        if (msg.contains('font') ||
            msg.contains('gstatic') ||
            msg.contains('GoogleFonts')) {
          debugPrint('Font load error (ignorado): ${details.exception}');
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
          });
        });
      }
    },
    (error, stack) {
      debugPrint('Global unhandled error caught: $error');
      if (error is! SocketException) {
        debugPrint('$stack');
      }
    },
  );
}

class BumpCombaApp extends StatelessWidget {
  const BumpCombaApp({super.key});

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
