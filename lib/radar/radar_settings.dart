/// The organizer's radar setup, one for the app: table shape and size,
/// player count, the per-end seat choice, where the camera is, the
/// organizer's seat. Remembered on the phone; every change also goes into
/// the night's log as a `radar` event (the TV draws the same table, the
/// offline analysis knows the seat count over time) and, through the
/// nearby service, into a running recording's log. Record the table and
/// the Radar screen share the player count both ways through [config].
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../nearby/nearby_service.dart';
import '../sync/night_events.dart';
import '../sync/table_night_service.dart';
import 'radar_model.dart';

class RadarSettings {
  RadarSettings._();

  static const _key = 'radar_config_v1';
  static const _askedKey = 'radar_asked_playing_v1';

  static final config = ValueNotifier<RadarConfig>(const RadarConfig());
  static bool _loaded = false;

  /// A setup was saved on this phone before (else Record the table's own
  /// older player count seeds it).
  static bool saved = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      final c = raw == null ? null : RadarConfig.fromJson(jsonDecode(raw));
      if (c != null) {
        config.value = c;
        saved = true;
      }
    } catch (_) {}
  }

  /// Asked once: "Are you playing? which seat?".
  static Future<bool> askedPlaying() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_askedKey) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setAskedPlaying() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_askedKey, true);
    } catch (_) {}
  }

  /// Applies [c] now (re-layout at once) and logs it with the time.
  static Future<void> set(RadarConfig c, {String why = 'setup'}) async {
    if (c.toJson().toString() == config.value.toJson().toString()) return;
    config.value = c;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(c.toJson()));
      saved = true;
    } catch (_) {}
    final data = {...c.toJson(), 'why': why};
    NearbyService.instance.note('radar_config', data);
    final n = TableNightService.instance.night;
    if (n != null && n.isOrganizer) {
      try {
        await n.appendEvent(EventKind.radar, data);
      } catch (_) {}
    }
  }

  static Future<void> setSeats(int n, {String why = 'players'}) =>
      set(config.value.copyWith(seats: n.clamp(2, 12)), why: why);
}
