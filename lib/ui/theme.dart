import 'package:flutter/material.dart';

import 'app_settings.dart';

/// [ThemeMode] for a saved [ThemeChoice].
ThemeMode themeModeFor(ThemeChoice c) => switch (c) {
      ThemeChoice.system => ThemeMode.system,
      ThemeChoice.light => ThemeMode.light,
      ThemeChoice.dark => ThemeMode.dark,
    };

/// Suit colour for [suit] (0 clubs, 1 diamonds, 2 hearts, 3 spades) in deck
/// [style]. Meant for a white card face.
Color suitColor(int suit, [CardStyle? style]) {
  final s = style ?? AppSettings.cardStyle.value;
  if (s == CardStyle.twoColor) {
    return suit == 1 || suit == 2 ? Felt.suitRed : Felt.suitBlack;
  }
  return Felt.fourColorSuits[suit];
}

class Felt {
  static const gold = Color(0xFFE2B857);
  static const feltDark = Color(0xFF0D1A13);
  static const feltSurface = Color(0xFF15281D);
  static const feltCard = Color(0xFF1C3427);
  static const cream = Color(0xFFF6F1E4);

  /// Gold that stays readable as text / icons on the light theme's cream.
  static const goldDeep = Color(0xFF7A5A0E);

  /// Light-theme scaffold and the felt green used for its primary colour.
  static const paper = Color(0xFFFBF8F0);
  static const feltGreen = Color(0xFF1E5C3A);

  static const suitRed = Color(0xFFD62839);
  static const suitBlack = Color(0xFF1B1B1B);
  static const fourColorSuits = [
    Color(0xFF1F7A3F), // clubs: green
    Color(0xFF2563EB), // diamonds: blue
    suitRed, // hearts
    suitBlack, // spades
  ];

  /// The gold accent for text and icons on the current theme's surfaces:
  /// [gold] on dark, [goldDeep] on light (plain gold is ~1.9:1 on cream).
  static Color accent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? gold : goldDeep;

  /// [mixed] (gold) as a text colour on the current theme.
  static Color mixedText(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? mixed : goldDeep;

  static const aggressive = Color(0xFFE5484D);
  static const call = Color(0xFF30A46C);
  static const foldDark = Color(0xFF2E3B33);
  static const foldLight = Color(0xFFD5D9D2);

  static const good = Color(0xFF30A46C);
  static const mixed = Color(0xFFE2B857);
  static const bad = Color(0xFFE5484D);

  static Color actionColor(String action, Brightness b) {
    final a = action.toLowerCase();
    if (a.startsWith('fold')) return b == Brightness.dark ? foldDark : foldLight;
    if (a.startsWith('call') ||
        a.startsWith('check') ||
        a.startsWith('overlimp') ||
        a.startsWith('complete')) {
      return call;
    }
    return aggressive;
  }

  static final ThemeData _darkOnly = dark();

  /// Forces the dark felt theme under [child] whatever the app theme. For
  /// the screens that are dark-only by design (TV dashboard, night recap,
  /// blind clock): they are read across a room or screenshotted and shared.
  static Widget darkOnly(Widget child) => Theme(data: _darkOnly, child: child);

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2F7D55),
      brightness: Brightness.dark,
      primary: gold,
      surface: feltSurface,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: feltDark,
      cardTheme: const CardTheme(color: feltCard, elevation: 0),
      appBarTheme: const AppBarTheme(backgroundColor: feltDark, elevation: 0),
      navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: feltSurface, indicatorColor: Color(0x33E2B857)),
    );
  }

  /// Daylight version of the felt look: paper background, felt-green
  /// primary, deep gold as the secondary accent.
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2F7D55),
      brightness: Brightness.light,
      primary: feltGreen,
      secondary: goldDeep,
      surface: cream,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: paper,
      cardTheme: CardTheme(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0x1A1E5C3A)),
        ),
      ),
      appBarTheme: const AppBarTheme(
          backgroundColor: paper, surfaceTintColor: Colors.transparent, elevation: 0),
      navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: cream, indicatorColor: Color(0x55E2B857)),
    );
  }
}
