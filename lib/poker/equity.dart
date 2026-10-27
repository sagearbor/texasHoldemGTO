/// Monte Carlo equity for known hands (and ranges) on a partial board.
library;

import 'dart:math';

import '../gto/hand_class.dart';
import 'evaluator.dart';

class EquityResult {
  /// Per player share of the pot (wins + split shares), 0..1.
  final List<double> equity;
  final List<double> win;
  final List<double> tie;
  final int samples;
  const EquityResult(this.equity, this.win, this.tie, this.samples);
}

/// Equity for [hands] (each two cards) with [board] (0–5 cards).
/// When at most 2 board cards are missing the result is exact enumeration.
EquityResult handsEquity(List<List<int>> hands, List<int> board,
    {int samples = 20000, Random? rng}) {
  rng ??= Random();
  final n = hands.length;
  final dead = <int>{for (final h in hands) ...h, ...board};
  if (dead.length != hands.length * 2 + board.length) {
    throw ArgumentError('Duplicate cards');
  }
  final live = [for (var c = 0; c < 52; c++) if (!dead.contains(c)) c];
  final missing = 5 - board.length;
  final wins = List<double>.filled(n, 0);
  final ties = List<double>.filled(n, 0);
  final share = List<double>.filled(n, 0);
  var total = 0;

  void score(List<int> fullBoard) {
    var best = -1;
    final scores = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      scores[i] = evaluate([...hands[i], ...fullBoard]);
      if (scores[i] > best) best = scores[i];
    }
    final winners = [for (var i = 0; i < n; i++) if (scores[i] == best) i];
    for (final w in winners) {
      if (winners.length == 1) {
        wins[w]++;
      } else {
        ties[w]++;
      }
      share[w] += 1 / winners.length;
    }
    total++;
  }

  if (missing == 0) {
    score(board);
  } else if (missing == 1) {
    for (final a in live) {
      score([...board, a]);
    }
  } else if (missing == 2) {
    for (var i = 0; i < live.length; i++) {
      for (var j = i + 1; j < live.length; j++) {
        score([...board, live[i], live[j]]);
      }
    }
  } else {
    for (var s = 0; s < samples; s++) {
      // Partial Fisher–Yates over the live cards.
      for (var k = 0; k < missing; k++) {
        final r = k + rng.nextInt(live.length - k);
        final t = live[k];
        live[k] = live[r];
        live[r] = t;
      }
      score([...board, ...live.sublist(0, missing)]);
    }
  }
  return EquityResult(
    [for (final s in share) s / total],
    [for (final w in wins) w / total],
    [for (final t in ties) t / total],
    total,
  );
}

/// Equity of [hero] (two cards) against a weighted villain range.
/// [villainRange] maps hand-class index (0..168) to weight 0..1.
double handVsRangeEquity(List<int> hero, Map<int, double> villainRange,
    List<int> board,
    {int samples = 6000, Random? rng}) {
  rng ??= Random();
  final dead = {...hero, ...board};
  final combos = <List<int>>[];
  final weights = <double>[];
  villainRange.forEach((cls, w) {
    if (w <= 0) return;
    for (final combo in HandClass.byIndex(cls).combos()) {
      if (dead.contains(combo[0]) || dead.contains(combo[1])) continue;
      combos.add(combo);
      weights.add(w);
    }
  });
  if (combos.isEmpty) return 0.5;
  final cum = <double>[];
  var acc = 0.0;
  for (final w in weights) {
    acc += w;
    cum.add(acc);
  }
  var share = 0.0;
  for (var s = 0; s < samples; s++) {
    final x = rng.nextDouble() * acc;
    var lo = 0, hi = cum.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final v = combos[lo];
    final used = {...dead, ...v};
    final runout = <int>[];
    while (runout.length < 5 - board.length) {
      final c = rng.nextInt(52);
      if (!used.contains(c)) {
        used.add(c);
        runout.add(c);
      }
    }
    final b = [...board, ...runout];
    final h = evaluate([...hero, ...b]);
    final vv = evaluate([...v, ...b]);
    share += h > vv ? 1 : (h == vv ? 0.5 : 0);
  }
  return share / samples;
}
