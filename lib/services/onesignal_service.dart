import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class OneSignalService {
  static final OneSignalService _instance = OneSignalService._internal();
  factory OneSignalService() => _instance;
  OneSignalService._internal();

  static String get appId =>
      dotenv.env['ONESIGNAL_APP_ID'] ?? "9c7ffe17-59fe-4e76-9c9e-3e1b8046a125";

  Future<void> initialize() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      debugPrint("OneSignal: Disabled on this platform");
      return;
    }

    try {
      // Remove this method to stop OneSignal from automatically showing notifications while the app is in focus.
      OneSignal.Debug.setLogLevel(kDebugMode ? OSLogLevel.error : OSLogLevel.none);

      OneSignal.initialize(appId);

      // Registrar los listeners ANTES de pedir permiso, para no perder ningún
      // evento temprano.

      // Handle notification opened
      OneSignal.Notifications.addClickListener((event) {
        debugPrint('NOTIFICATION CLICK LISTENER CALLED WITH EVENT: $event');
      });

      // Handle notification received in foreground
      OneSignal.Notifications.addForegroundWillDisplayListener((event) {
        debugPrint(
          'NOTIFICATION WILL DISPLAY LISTENER CALLED WITH EVENT: $event',
        );
        // Display Notification, can also call preventDefault() to not display the notification
        event.notification.display();
      });

      // Diagnóstico: registrar cuándo cambia la suscripción push. Si tras
      // conceder permiso el `id` sigue null, el dispositivo NO se registró en
      // OneSignal (típicamente falta configurar las credenciales FCM en el
      // panel de OneSignal → Settings → Google Android (FCM)).
      OneSignal.User.pushSubscription.addObserver((state) {
        debugPrint(
          'OneSignal push subscription changed: '
          'id=${OneSignal.User.pushSubscription.id}, '
          'optedIn=${OneSignal.User.pushSubscription.optedIn}',
        );
      });

      // This will request permission on both Android 13+ and iOS.
      final granted = await OneSignal.Notifications.requestPermission(true);
      debugPrint('OneSignal notification permission granted=$granted');

      // Note: The icon 'ic_stat_onesignal_default' in 'android/app/src/main/res/drawable'
      // will be used automatically by OneSignal as the notification icon.

      // Asegurar que el dispositivo quede opted-in para recibir push.
      OneSignal.User.pushSubscription.optIn();

      // Dar tiempo a que el SDK obtenga el token FCM y registre la suscripción,
      // luego volcar el estado para diagnóstico.
      Future.delayed(const Duration(seconds: 5), () {
        debugPrint(
          'OneSignal status → permission=${OneSignal.Notifications.permission}, '
          'subscriptionId=${OneSignal.User.pushSubscription.id}, '
          'optedIn=${OneSignal.User.pushSubscription.optedIn}',
        );
      });

      debugPrint("OneSignal initialized successfully");
    } catch (e) {
      debugPrint("Error initializing OneSignal: $e");
    }
  }
}
