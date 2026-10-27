/// Your own money, and only yours: optional buy-in / cash-out per night.
library;

import 'home_game.dart';

const myResultNote = 'Just you — nobody else\'s money is tracked';

/// "$40", "$12.50", or with [signed] "+$40" / "-$12.50".
String moneyLabel(double v, {bool signed = false}) {
  final cents = (v.abs() * 100).round();
  final body = cents % 100 == 0 ? '${cents ~/ 100}' : (cents / 100).toStringAsFixed(2);
  final sign = cents == 0 ? '' : (v < 0 ? '-' : (signed ? '+' : ''));
  return '$sign\$$body';
}

/// Parses "40", "$40", "12.5", "1,200"; blank or invalid gives null.
double? parseMoney(String s) {
  final t = s.replaceAll(RegExp(r'[\s,$]'), '');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  return v == null || v < 0 || v.isNaN || v.isInfinite ? null : v;
}

class SeasonResult {
  /// Nights with both numbers entered, oldest first, with their net.
  final List<(HomeSession, double)> nights;
  SeasonResult(this.nights);

  double get total => nights.fold(0.0, (a, n) => a + n.$2);
  int get winning => nights.where((n) => n.$2 > 0).length;
}

SeasonResult seasonResult(List<HomeSession> sessions) {
  final out = [
    for (final s in sessions)
      if (s.net != null) (s, s.net!)
  ]..sort((a, b) => a.$1.started.compareTo(b.$1.started));
  return SeasonResult(out);
}
