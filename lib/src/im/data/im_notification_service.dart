import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Shows local notifications when new messages arrive.
///
/// Setup:
///   - iOS AppDelegate must call `setPluginRegistrantCallback` BEFORE init.
///   - Permissions are requested manually after init so the user sees the
///     dialog at a natural time, not at app startup.
class ImNotificationService {
  ImNotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Must be called once at app startup (before any `show` call).
  static Future<void> init() async {
    if (_initialized) return;
    try {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwinSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        InitializationSettings(
          android: androidSettings,
          iOS: darwinSettings,
          macOS: darwinSettings,
        ),
        onDidReceiveNotificationResponse: _onNotificationTap,
        onDidReceiveBackgroundNotificationResponse: _onBackgroundTap,
      );
      _initialized = true;
      debugPrint('[Notify] plugin initialized OK');
    } catch (e) {
      debugPrint('[Notify] init failed: $e');
    }
  }

  /// Request notification permissions (call after first message arrives).
  static Future<void> requestPermission() async {
    if (!_initialized) await init();
    try {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      debugPrint('[Notify] iOS permission requested');
    } catch (_) {}
    try {
      final mac = _plugin.resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin>();
      await mac?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      debugPrint('[Notify] macOS permission requested');
    } catch (_) {}
  }

  static Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_initialized) await init();
    try {
      await _plugin.show(
        id,
        title,
        body,
        const NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
          android: AndroidNotificationDetails(
            'im_messages',
            'Messages',
            channelDescription: 'Incoming IM messages',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
      debugPrint('[Notify] show OK: $title');
    } catch (e) {
      debugPrint('[Notify] show failed: $e');
    }
  }

  @pragma('vm:entry-point')
  static void _onNotificationTap(NotificationResponse response) {
    debugPrint('[Notify] tapped: ${response.payload}');
  }

  @pragma('vm:entry-point')
  static void _onBackgroundTap(NotificationResponse response) {
    debugPrint('[Notify] bg tap: ${response.payload}');
  }
}
