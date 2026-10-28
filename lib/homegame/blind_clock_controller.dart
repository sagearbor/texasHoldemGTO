/// App-wide owner of the one blind clock: wraps [BlindClock] with
/// persistence (shared_preferences) and change notification. One shared
/// instance so the clock screen and the dashboard strip see the same clock.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'blind_clock.dart';

class BlindClockController extends ChangeNotifier {
  static const prefsKey = 'blind_clock_v1';

  static BlindClockController? _shared;
  static BlindClockController get shared => _shared ??= BlindClockController();

  /// Wall-clock source; tests can swap it.
  final int Function() now;

  BlindClockController({int Function()? now})
      : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// A fresh install starts in cash mode (the monthly game); the tournament
  /// clock is one menu tap away. A saved clock keeps the mode it had.
  BlindClock clock = BlindClock(mode: ClockMode.cash);
  bool loaded = false;
  Future<void>? _loading;

  /// Load once; later calls return the same future.
  Future<void> ensureLoaded() => _loading ??= _load();

  /// Re-reads the clock from storage (after a restore).
  Future<void> reload() {
    clock = BlindClock(mode: ClockMode.cash);
    _seen = null;
    return _loading = _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) {
        clock = BlindClock.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
      }
    } catch (_) {
      // Corrupt or unavailable storage: start from the default schedule.
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(clock.toJson()));
    } catch (_) {}
  }

  int? _seen;

  /// True once each time the running clock rolls into a new level by itself
  /// (call it from a display tick). Manual skips and restores don't count,
  /// and several displays calling it still only alert once.
  bool takeLevelChange() {
    final i = position.index;
    final changed = _seen != null && _seen != i && clock.running;
    _seen = i;
    return changed;
  }

  void _changed() {
    _seen = position.index;
    notifyListeners();
    unawaited(_save());
  }

  ClockPosition get position => clock.positionAt(now());

  void toggle() {
    clock.toggle(now());
    _changed();
  }

  void start() {
    clock.start(now());
    _changed();
  }

  void pause() {
    clock.pause(now());
    _changed();
  }

  void next() {
    clock.next(now());
    _changed();
  }

  void previous() {
    clock.previous(now());
    _changed();
  }

  void reset() {
    clock.reset();
    _changed();
  }

  void setSchedule(List<BlindLevel> levels) {
    clock.setSchedule(levels, now());
    _changed();
  }

  void setMode(ClockMode m) {
    clock.setMode(m, now());
    _changed();
  }

  @visibleForTesting
  static void resetShared() => _shared = null;
}
