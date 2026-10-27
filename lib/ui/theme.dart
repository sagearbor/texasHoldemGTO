import 'package:flutter/material.dart';

class Felt {
  static const gold = Color(0xFFE2B857);
  static const feltDark = Color(0xFF0D1A13);
  static const feltSurface = Color(0xFF15281D);
  static const feltCard = Color(0xFF1C3427);
  static const cream = Color(0xFFF6F1E4);

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
    if (a.startsWith('call')) return call;
    return aggressive;
  }

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

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2F7D55),
      brightness: Brightness.light,
      surface: cream,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFFBF8F0),
      cardTheme: const CardTheme(color: Colors.white, elevation: 0),
    );
  }
}
