/// Watch my cards: "Buzz my watch" (off by default). A short local
/// notification that the phone mirrors to a paired smartwatch (Wear OS,
/// Galaxy, Garmin, Fitbit...), so the player feels a read without looking.
///
///  * PRIVACY: the propped phone faces the table, so the notification never
///    says which cards: only "Felt Notes: cards read" / "cards corrected".
///  * One buzz = cards logged (or a new hand's cards), two buzzes (two
///    notifications a second apart) = corrected, nothing for re-peeks.
///  * Quiet on the phone: no sound, no heads-up banner (default importance
///    on Android; iOS: not shown while the app is open), removed after
///    [visibleMs]. The watch still buzzes because the notification posts.
///  * Apple Watch only shows iPhone notifications while the iPhone is
///    locked; Watch mode keeps the iPhone awake, so no buzz there.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'watch_tracker.dart';

/// How many buzzes a decision gets (0 = none). Pure; unit-tested.
int buzzCount(WatchAction a) => switch (a) {
      WatchAction.fill || WatchAction.newHand => 1,
      WatchAction.correct => 2,
      _ => 0,
    };

/// Notification text for [a]: never the cards.
String buzzTitle(WatchAction a) => a == WatchAction.correct ? 'Felt Notes: cards corrected' : 'Felt Notes: cards read';

class WatchBuzz {
  static const _channel = 'watch_buzz';
  static const visibleMs = 4000;
  static const gapMs = 1000;

  final FlutterLocalNotificationsPlugin _n = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _id = 7100;

  Future<bool> _init() async {
    if (_ready) return true;
    try {
      _ready = await _n.initialize(const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
            iOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestBadgePermission: false,
              requestSoundPermission: false,
            ),
          )) ??
          false;
    } catch (e) {
      debugPrint('watch buzz init: $e');
    }
    return _ready;
  }

  /// Asks for notification permission (Android 13+, iOS). Call when the
  /// player turns the setting on. Returns whether notifications may show.
  Future<bool> requestPermission() async {
    if (!await _init()) return false;
    try {
      final android = _n.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) return await android.requestNotificationsPermission() ?? false;
      final ios = _n.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) return await ios.requestPermissions(alert: true, sound: false, badge: false) ?? false;
    } catch (e) {
      debugPrint('watch buzz permission: $e');
    }
    return false;
  }

  /// Buzzes for [a] (nothing for confirmations).
  Future<void> buzz(WatchAction a) async {
    final n = buzzCount(a);
    if (n == 0 || !await _init()) return;
    for (var i = 0; i < n; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: gapMs));
      final id = _id++;
      try {
        await _n.show(
          id,
          buzzTitle(a),
          null,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _channel,
              'Watch my cards buzz',
              channelDescription: 'A short buzz on your watch when Watch my cards reads your cards. Never shows the cards.',
              // Default importance: no heads-up banner over the black screen.
              importance: Importance.defaultImportance,
              priority: Priority.defaultPriority,
              playSound: false,
              enableVibration: true,
              timeoutAfter: visibleMs,
              category: AndroidNotificationCategory.status,
              visibility: NotificationVisibility.secret,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: false,
              presentBanner: false,
              presentList: false,
              presentSound: false,
              presentBadge: false,
            ),
          ),
        );
        Future<void>.delayed(const Duration(milliseconds: visibleMs), () => _n.cancel(id).ignore()).ignore();
      } catch (e) {
        debugPrint('watch buzz: $e');
      }
    }
  }
}
