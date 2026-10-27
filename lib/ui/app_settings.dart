/// App-wide display settings, persisted on device (see SettingsScreen).
///
/// Difficulty lives on TrainerModel, the dashboard delay on HomeGameModel and
/// colour-blind charts on ChartPrefs; this holds everything else. Every key
/// here is also listed in backupKeys (lib/data/backup.dart).
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Theme choice. Dark is the default (the original felt look).
enum ThemeChoice { system, light, dark }

/// Deck colours: four-colour (clubs green, diamonds blue) or the classic
/// red / black deck.
enum CardStyle { fourColor, twoColor }

const themeChoiceLabels = {
  ThemeChoice.system: 'System',
  ThemeChoice.light: 'Light',
  ThemeChoice.dark: 'Dark',
};

const cardStyleLabels = {
  CardStyle.fourColor: '4-colour',
  CardStyle.twoColor: 'Classic',
};

/// Quick picks for the "My result" currency symbol.
const currencyPresets = ['\$', '€', '£', '¥', '₹', 'kr'];

const defaultCurrency = '\$';

class AppSettings {
  AppSettings._();

  static const themeKey = 'settings_theme_v1';
  static const cardStyleKey = 'settings_card_style_v1';
  static const solverDiceKey = 'settings_solver_dice_v1';
  static const currencyKey = 'settings_currency_v1';

  static final theme = ValueNotifier<ThemeChoice>(ThemeChoice.dark);
  static final cardStyle = ValueNotifier<CardStyle>(CardStyle.fourColor);

  /// Show the "solver dice" roll after answering a mixed hand.
  static final solverDice = ValueNotifier<bool>(true);

  /// Symbol for My result amounts ("$40").
  static final currency = ValueNotifier<String>(defaultCurrency);

  /// Fires when any setting here changes.
  static final Listenable all =
      Listenable.merge([theme, cardStyle, solverDice, currency]);

  /// [name] as a [ThemeChoice], or null if it is not one.
  static ThemeChoice? parseTheme(Object? name) {
    for (final c in ThemeChoice.values) {
      if (c.name == name) return c;
    }
    return null;
  }

  static CardStyle? parseCardStyle(Object? name) {
    for (final c in CardStyle.values) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// A usable currency symbol: trimmed, 1–3 characters, no digits, signs,
  /// separators or line breaks. Null if [s] is not one.
  static String? normalizeCurrency(Object? s) {
    if (s is! String) return null;
    final t = s.trim();
    final n = t.runes.length;
    if (n < 1 || n > 3) return null;
    if (RegExp(r'[0-9+\-.,\s]').hasMatch(t)) return null;
    return t;
  }

  /// Back to defaults in memory only (after "Reset all data").
  static void resetMemory() {
    theme.value = ThemeChoice.dark;
    cardStyle.value = CardStyle.fourColor;
    solverDice.value = true;
    currency.value = defaultCurrency;
  }

  static Future<void> load() async {
    resetMemory();
    try {
      final prefs = await SharedPreferences.getInstance();
      theme.value = parseTheme(prefs.getString(themeKey)) ?? ThemeChoice.dark;
      cardStyle.value =
          parseCardStyle(prefs.getString(cardStyleKey)) ?? CardStyle.fourColor;
      solverDice.value = prefs.getBool(solverDiceKey) ?? true;
      currency.value =
          normalizeCurrency(prefs.getString(currencyKey)) ?? defaultCurrency;
    } catch (_) {
      // Storage unavailable (private window etc.): keep the defaults.
    }
  }

  static Future<void> _write(Future<void> Function(SharedPreferences) f) async {
    try {
      await f(await SharedPreferences.getInstance());
    } catch (_) {}
  }

  static Future<void> setTheme(ThemeChoice c) async {
    theme.value = c;
    await _write((p) => p.setString(themeKey, c.name));
  }

  static Future<void> setCardStyle(CardStyle c) async {
    cardStyle.value = c;
    await _write((p) => p.setString(cardStyleKey, c.name));
  }

  static Future<void> setSolverDice(bool on) async {
    solverDice.value = on;
    await _write((p) => p.setBool(solverDiceKey, on));
  }

  /// Ignores an invalid symbol (see [normalizeCurrency]); returns whether it
  /// was saved.
  static Future<bool> setCurrency(String s) async {
    final c = normalizeCurrency(s);
    if (c == null) return false;
    currency.value = c;
    await _write((p) => p.setString(currencyKey, c));
    return true;
  }
}
