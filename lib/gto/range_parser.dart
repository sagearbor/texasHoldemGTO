/// Parses range strings like "22+, A2s+, KTo+, A5s-A2s, 99-66, AK, 65s:0.5"
/// into a map of hand-class index -> frequency (0..1).
/// Later tokens override earlier ones, so "A2s+, A3s:0.5" works.
library;

import '../poker/cards.dart';
import 'hand_class.dart';

typedef RangeMap = Map<int, double>;

RangeMap parseRange(String text) {
  final out = <int, double>{};
  for (var raw in text.split(',')) {
    raw = raw.trim();
    if (raw.isEmpty) continue;
    var freq = 1.0;
    final colon = raw.indexOf(':');
    if (colon >= 0) {
      freq = double.parse(raw.substring(colon + 1));
      raw = raw.substring(0, colon).trim();
    }
    for (final h in _expand(raw)) {
      out[h.index] = freq;
    }
  }
  return out;
}

int _r(String c) {
  final r = rankChars.indexOf(c.toUpperCase());
  if (r < 0) throw FormatException('Bad rank: $c');
  return r;
}

List<HandClass> _expand(String tok) {
  if (tok.contains('-')) {
    final parts = tok.split('-');
    final a = parts[0].trim(), b = parts[1].trim();
    final hiA = _r(a[0]), loA = _r(a[1]), loB = _r(b[1]);
    if (hiA == loA) {
      // Pair span "99-22".
      final top = hiA > _r(b[0]) ? hiA : _r(b[0]);
      final bot = hiA > _r(b[0]) ? _r(b[0]) : hiA;
      return [for (var r = bot; r <= top; r++) _cls(r, r, '')];
    }
    final suffix = a.length > 2 ? a.substring(2) : '';
    final top = loA > loB ? loA : loB, bot = loA > loB ? loB : loA;
    return [for (var r = bot; r <= top; r++) ..._clsAll(hiA, r, suffix)];
  }
  final plus = tok.endsWith('+');
  final t = plus ? tok.substring(0, tok.length - 1) : tok;
  final hi = _r(t[0]), lo = _r(t[1]);
  final suffix = t.length > 2 ? t.substring(2) : '';
  if (hi == lo) {
    if (!plus) return [_cls(hi, hi, '')];
    return [for (var r = hi; r <= 12; r++) _cls(r, r, '')];
  }
  if (!plus) return _clsAll(hi, lo, suffix);
  return [for (var r = lo; r < hi; r++) ..._clsAll(hi, r, suffix)];
}

List<HandClass> _clsAll(int hi, int lo, String suffix) {
  if (suffix.isEmpty) return [_cls(hi, lo, 's'), _cls(hi, lo, 'o')];
  return [_cls(hi, lo, suffix)];
}

HandClass _cls(int hi, int lo, String suffix) =>
    HandClass.parse('${rankChars[hi]}${rankChars[lo]}$suffix');

/// Fraction of all 1326 combos covered by a range (weighted).
double rangePercent(RangeMap range) {
  var combos = 0.0;
  range.forEach((i, f) => combos += HandClass.byIndex(i).comboCount * f);
  return combos / 1326;
}
