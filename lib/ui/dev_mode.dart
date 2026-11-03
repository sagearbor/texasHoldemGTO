/// Developer mode: hides testing and diagnostic tools from normal users.
/// Tap the version in About 7 times to switch it on or off. Device-only
/// (not in backups); "Reset all data" switches it off.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DevMode {
  DevMode._();

  static const key = 'developer_mode_v1';

  static final on = ValueNotifier<bool>(false);

  static Future<void> load() async {
    on.value = false;
    try {
      on.value = (await SharedPreferences.getInstance()).getBool(key) ?? false;
    } catch (_) {}
  }

  static Future<void> set(bool v) async {
    on.value = v;
    try {
      await (await SharedPreferences.getInstance()).setBool(key, v);
    } catch (_) {}
  }

  /// Flips it; returns the new state.
  static Future<bool> toggle() async {
    await set(!on.value);
    return on.value;
  }
}

/// Counts taps toward [needed] in a row, each within [gap] of the last
/// (the "tap the version 7 times" gesture). [tap] is true on the tap that
/// completes the run, which starts the count again.
class TapCounter {
  final int needed;
  final Duration gap;
  TapCounter({this.needed = 7, this.gap = const Duration(seconds: 2)});

  int _count = 0;
  DateTime? _last;

  int get count => _count;

  bool tap(DateTime now) {
    final last = _last;
    _count = last != null && now.difference(last) <= gap ? _count + 1 : 1;
    _last = now;
    if (_count < needed) return false;
    _count = 0;
    _last = null;
    return true;
  }
}
