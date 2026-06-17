import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'localization_service.dart';
import 'watch_progress_service.dart';

/// Background tap handler. Must be a top-level / static function for the
/// plugin to invoke it from a background isolate. We only persist the payload
/// so the UI isolate can pick it up when the app is next opened.
@pragma('vm:entry-point')
void _onBackgroundNotificationTap(NotificationResponse response) {
  // No navigation possible from the background isolate; the foreground
  // launch-details check in [SmartNotificationService.consumePendingPayload]
  // handles routing when the app opens.
}

/// Local, on-device "smart" notification engine.
///
/// Design goals:
///  * Personalised — copy is built from what the user was actually watching
///    (continue-watching) so it never feels generic.
///  * Gentle — at most ONE reminder is ever pending. Every time the app is
///    opened or backgrounded we cancel and reschedule, so an active user is
///    never reminded, and an absent user gets a single ping per absence.
///  * Universal — uses inexact alarms (no SCHEDULE_EXACT_ALARM permission), a
///    high-importance channel, and survives reboot via the manifest
///    receiver, so it works on every Android device without special grants.
class SmartNotificationService {
  static final SmartNotificationService _instance =
      SmartNotificationService._internal();
  factory SmartNotificationService() => _instance;
  SmartNotificationService._internal();

  static const String _channelId = 'smart_reminders';
  static const int _reminderId = 1001;
  static const String _enabledKey = 'smart_notifications_enabled';

  // Prime-time slot (local hour) and minimum lead so we never fire at night or
  // while the user is clearly still inside the app.
  static const int _primeHour = 19; // 7 PM
  static const int _minLeadHours = 2;
  static const int _comebackDays = 1;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final WatchProgressService _watch = WatchProgressService();
  final LocalizationService _loc = LocalizationService();

  bool _initialized = false;
  bool _enabled = true;
  String? _pendingPayload;

  bool get isEnabled => _enabled;

  /// Initialize the plugin, timezone database and notification channel.
  /// Safe to call multiple times.
  Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_enabledKey) ?? true;

      // Timezone is required for zonedSchedule to fire at the right wall-clock
      // time across DST and device timezone changes.
      tzdata.initializeTimeZones();
      try {
        final info = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
        debugPrint('SmartNotifications: timezone = ${info.identifier}');
      } catch (e) {
        debugPrint('SmartNotifications: timezone fallback (UTC): $e');
      }

      const androidInit = AndroidInitializationSettings(
        'ic_stat_onesignal_default',
      );
      // Request permissions on iOS so local notifications can be displayed.
      const darwinInit = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      await _plugin.initialize(
        settings: const InitializationSettings(
          android: androidInit,
          iOS: darwinInit,
        ),
        onDidReceiveNotificationResponse: (response) {
          _pendingPayload = response.payload;
        },
        onDidReceiveBackgroundNotificationResponse:
            _onBackgroundNotificationTap,
      );

      // Capture a tap that cold-launched the app from a terminated state.
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _pendingPayload = launch?.notificationResponse?.payload;
      }

      await _createChannel();

      // Request POST_NOTIFICATIONS permission on Android 13+.
      // This is a no-op if already granted or denied, and it's safe to call
      // even though OneSignal may have already requested this.
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android =
            _plugin
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >();
        final granted = await android?.requestNotificationsPermission();
        debugPrint('SmartNotifications: Android permission granted=$granted');
      }

      _initialized = true;
      debugPrint('SmartNotifications: initialized (enabled=$_enabled)');
    } catch (e, stack) {
      debugPrint('SmartNotifications: init error: $e');
      debugPrint('SmartNotifications: $stack');
    }
  }

  Future<void> _createChannel() async {
    final android =
        _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
    // High importance → shows as a heads-up popup so the user actually sees it.
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        'Recordatorios',
        description: 'Recordatorios para seguir viendo tu contenido',
        importance: Importance.high,
      ),
    );
  }

  /// Master on/off toggle exposed in settings.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    if (value) {
      await refreshReminders();
    } else {
      await cancelAll();
    }
  }

  /// Returns a payload from a notification the user tapped, if any, and clears
  /// it so it is only consumed once.
  String? consumePendingPayload() {
    final p = _pendingPayload;
    _pendingPayload = null;
    return p;
  }

  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancel(id: _reminderId);
  }

  /// Recompute and (re)schedule the single pending reminder based on the
  /// user's latest watch history. Cancelling first guarantees we never stack
  /// notifications. Call this on app start and whenever the app is backgrounded
  /// so the reminder always reflects the most recent activity.
  Future<void> refreshReminders() async {
    if (!_initialized || !_enabled) {
      debugPrint(
        'SmartNotifications: skip refresh (init=$_initialized, enabled=$_enabled)',
      );
      return;
    }

    try {
      await _plugin.cancel(id: _reminderId);

      // On Android, check if notifications are enabled in system settings.
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android =
            _plugin
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >();
        if ((await android?.areNotificationsEnabled()) == false) {
          debugPrint(
            'SmartNotifications: notifications disabled in system settings',
          );
          return;
        }
      }

      await _loc.init();
      final history = await _watch.getHistory();
      if (history.isEmpty) {
        debugPrint('SmartNotifications: no watch history, skip scheduling');
        return;
      }

      final inProgress = _pickResumeCandidate(history);

      String title;
      String body;
      String payload;
      tz.TZDateTime when;

      if (inProgress != null) {
        title = _loc.tr('notif_continue_title');
        if (inProgress.seriesName != null &&
            inProgress.seriesName!.isNotEmpty) {
          body = _loc
              .tr('notif_continue_series_body')
              .replaceAll('{series}', inProgress.seriesName!)
              .replaceAll('{s}', '${inProgress.seasonNumber ?? 1}')
              .replaceAll('{e}', '${inProgress.episodeNumber ?? 1}');
          payload = _payloadFor(inProgress.seriesName!, isSeries: true);
        } else {
          final name = inProgress.name ?? '';
          body = _loc.tr('notif_continue_body').replaceAll('{title}', name);
          payload = _payloadFor(name, isSeries: false);
        }
        when = _nextPrimeTime();
      } else {
        // Has history but nothing mid-watch → gentle re-engagement, further out.
        title = _loc.tr('notif_comeback_title');
        body = _loc.tr('notif_comeback_body');
        payload = '';
        when = _nextPrimeTime(minDays: _comebackDays);
      }

      await _plugin.zonedSchedule(
        id: _reminderId,
        title: title,
        body: body,
        scheduledDate: when,
        payload: payload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Recordatorios',
            channelDescription: 'Recordatorios para seguir viendo tu contenido',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat_onesignal_default',
            color: Color(0xFFFF6B6B),
            autoCancel: true,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        // Inexact → no SCHEDULE_EXACT_ALARM permission, works on all devices
        // and is friendlier to Doze / battery.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );

      debugPrint(
        'SmartNotifications: scheduled "$title" for $when (payload=$payload)',
      );
    } catch (e, stack) {
      debugPrint('SmartNotifications: schedule error: $e');
      debugPrint('SmartNotifications: $stack');
    }
  }

  /// Send an immediate test notification to verify the system is working.
  /// Call this from a debug button or during development to confirm setup.
  Future<void> sendTestNotification() async {
    if (!_initialized) {
      debugPrint('SmartNotifications: not initialized, cannot send test');
      return;
    }

    try {
      await _plugin.show(
        id: 9999,
        title: '🔔 Test Notification',
        body: 'Las notificaciones locales están funcionando correctamente.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Recordatorios',
            channelDescription: 'Recordatorios para seguir viendo tu contenido',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat_onesignal_default',
            color: Color(0xFFFF6B6B),
            autoCancel: true,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
      debugPrint('SmartNotifications: test notification sent');
    } catch (e, stack) {
      debugPrint('SmartNotifications: test notification error: $e');
      debugPrint('SmartNotifications: $stack');
    }
  }

  /// Most recent item that is partially watched (between 3% and 92%) and not
  /// completed — i.e. something the user would plausibly want to resume.
  WatchProgress? _pickResumeCandidate(List<WatchProgress> history) {
    for (final p in history) {
      if (p.isCompleted) continue;
      final pct = p.progressPercentage;
      if (pct >= 3 && pct <= 92) return p;
    }
    return null;
  }

  String _payloadFor(String name, {required bool isSeries}) {
    final encoded = Uri.encodeQueryComponent(name);
    return 'comba://details?n=$encoded&s=${isSeries ? 1 : 0}';
  }

  /// Next occurrence of the prime-time hour that is at least [minDays] days and
  /// [_minLeadHours] hours away, so reminders never fire at night or while the
  /// user is obviously still active.
  tz.TZDateTime _nextPrimeTime({int minDays = 0}) {
    final now = tz.TZDateTime.now(tz.local);
    var candidate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      _primeHour,
    ).add(Duration(days: minDays));

    final earliest = now.add(Duration(hours: _minLeadHours));
    while (candidate.isBefore(earliest)) {
      candidate = candidate.add(const Duration(days: 1));
    }
    debugPrint(
      'SmartNotifications: _nextPrimeTime → $candidate (now=$now, minDays=$minDays)',
    );
    return candidate;
  }
}
