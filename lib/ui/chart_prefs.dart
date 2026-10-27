/// Chart display preferences, persisted on device.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChartPrefs {
  ChartPrefs._();

  static const colorBlindKey = 'charts_color_blind_v1';

  /// Colour-blind friendly charts: a blue / vermillion palette plus a
  /// pattern per action (hatching = raise, dots = call, plain = fold), so
  /// the grid reads without telling red from green.
  static final colorBlind = ValueNotifier<bool>(false);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      colorBlind.value = prefs.getBool(colorBlindKey) ?? false;
    } catch (_) {
      // Storage unavailable (private window etc.): keep the default.
    }
  }

  static Future<void> setColorBlind(bool on) async {
    colorBlind.value = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(colorBlindKey, on);
    } catch (_) {}
  }
}
