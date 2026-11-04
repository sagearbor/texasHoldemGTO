/// Watch my cards: "Buzz my watch" (off by default). A short local
/// notification that the phone mirrors to a paired smartwatch (Wear OS,
/// Galaxy, Garmin, Fitbit...), so the player feels a read without looking.
///
///  * PRIVACY: the propped phone faces the table, so the notification never
///    says which cards: only "Felt Notes: cards read" / "cards corrected",
///    plus how sure the camera is when known ("Felt Notes: cards read · 87%",
///    an UNCALIBRATED certainty from watch_certainty.dart; a low one is the
///    cue to peek again).
///  * One buzz = cards logged (or a new hand's cards), two buzzes (two
///    notifications a second apart) = corrected, nothing for re-peeks.
///  * Quiet on the phone: no sound, no heads-up banner (default importance
///    on Android; iOS: not shown while the app is open), removed after
///    [visibleMs]. The watch still buzzes because the notification posts.
///  * Only one shows at a time: a new buzz removes the previous one, and a
///    buzz's own removal timer never touches a newer one (see [BuzzSlots]).
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

/// Notification text for [a], with the [certainty] (0..1) as a percentage
/// when known: never the cards.
String buzzTitle(WatchAction a, [double? certainty]) {
  final base = a == WatchAction.correct ? 'Felt Notes: cards corrected' : 'Felt Notes: cards read';
  if (certainty == null || certainty.isNaN) return base;
  return '$base · ${(certainty.clamp(0.0, 1.0) * 100).round()}%';
}

/// Which buzz notification is showing. Pure; unit-tested.
///
/// Ids come from one counter for the whole app run, so a removal timer left
/// over from an earlier buzz (or an earlier Watch session) can never match
/// a newer notification. Reusing ids per session let a stale 4-second
/// timer remove a fresh "cards read" after a second or two.
class BuzzSlots {
  int _next;
  int? _showing;
  BuzzSlots([this._next = 7100]);

  int? get showing => _showing;

  /// A new buzz: its id, and the one to remove first (null if none).
  (int id, int? cancel) post() {
    final prev = _showing;
    final id = _next++;
    _showing = id;
    return (id, prev);
  }

  /// [id]'s timer ran out: true if it is still the one showing (remove it).
  bool expire(int id) {
    if (_showing != id) return false;
    _showing = null;
    return true;
  }
}

class WatchBuzz {
  static const _channel = 'watch_buzz';

  /// How long "cards read · NN%" stays (the owner missed it at 4 s).
  static const visibleMs = 6000;
  static const gapMs = 1000;

  /// Shared by every WatchBuzz (one per Watch session).
  static final slots = BuzzSlots();

  final FlutterLocalNotificationsPlugin _n = FlutterLocalNotificationsPlugin();
  bool _ready = false;

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

  /// Buzzes for [a] (nothing for confirmations), titled with [certainty].
  Future<void> buzz(WatchAction a, {double? certainty}) async {
    final n = buzzCount(a);
    if (n == 0 || !await _init()) return;
    for (var i = 0; i < n; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: gapMs));
      final (id, previous) = slots.post();
      try {
        // One at a time: the second of a "corrected" pair replaces the first.
        if (previous != null) await _n.cancel(previous);
        await _n.show(
          id,
          buzzTitle(a, certainty),
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
        // Android removes it after timeoutAfter; iOS needs this. Only if no
        // newer buzz has replaced it.
        Future<void>.delayed(const Duration(milliseconds: visibleMs), () {
          if (slots.expire(id)) _n.cancel(id).ignore();
        }).ignore();
      } catch (e) {
        debugPrint('watch buzz: $e');
      }
    }
  }
}
