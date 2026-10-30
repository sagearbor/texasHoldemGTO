/// Street-by-street equity for the TV and the recap: what an agreed board
/// (board_consensus.dart) plus two sharers' hole cards unlock. Pure Dart.
///
/// Shown only for hands that are over (the TV's existing delay): the
/// numbers are results, not coaching, and never appear while a hand is
/// being played.
library;

import 'dart:math';

import '../gto/hand_class.dart';
import '../poker/equity.dart';
import 'night_merge.dart';

class StreetEquity {
  /// "preflop", "flop", "turn", "river".
  final String street;

  /// Board cards dealt by this street.
  final List<int> board;

  /// Per hand, in the order given, 0..1.
  final List<double> equity;
  const StreetEquity(this.street, this.board, this.equity);
}

const _streets = ['preflop', 'flop', 'turn', 'river'];

/// Equity of [hands] after each street of [board] (3 to 5 cards, or fewer
/// for a hand that ended early). Preflop always; then one entry per
/// street the board reached. Exact enumeration from the turn on, Monte
/// Carlo before (pass [rng] for repeatable numbers).
List<StreetEquity> equityByStreet(List<List<int>> hands, List<int> board, {int samples = 4000, Random? rng}) {
  rng ??= Random(1);
  final out = <StreetEquity>[];
  for (final n in [0, 3, 4, 5]) {
    if (n > board.length) break;
    final b = board.sublist(0, n);
    out.add(StreetEquity(_streets[out.length], b, handsEquity(hands, b, samples: samples, rng: rng).equity));
  }
  return out;
}

/// One hand's story in numbers, for the "hand of the night" and the recap.
class SwingLine {
  final int handNo;

  /// Sharers in the line, in order (two).
  final List<String> names;
  final List<HandClass> classes;
  final List<StreetEquity> streets;

  /// Organizer-clock start of the hand.
  final int startMs;
  const SwingLine(this.handNo, this.names, this.classes, this.streets, this.startMs);

  /// Largest street-to-street change in the first player's equity.
  double get swing {
    var s = 0.0;
    for (var i = 1; i < streets.length; i++) {
      s = max(s, (streets[i].equity[0] - streets[i - 1].equity[0]).abs());
    }
    return s;
  }

  /// "John KK 82% → 91% → 9% → 9% vs Joe 76s · 8:22pm"
  String get text {
    final pct = streets.map((s) => '${(s.equity[0] * 100).round()}%').join(' → ');
    return '${names[0]} ${classes[0].name} $pct vs ${names[1]} ${classes[1].name} · ${clockLabel(startMs)}';
  }

  @override
  String toString() => text;
}

/// Hands where two sharers played and the board has at least a flop,
/// biggest swing first. [maxHands] caps the work for a live TV.
List<SwingLine> swingLines(MergedNight night, {int maxHands = 200, int samples = 4000, Random? rng}) {
  rng ??= Random(1);
  final out = <SwingLine>[];
  for (final h in night.hands.reversed.take(maxHands)) {
    final board = h.board;
    if (board == null || board.length < 3) continue;
    final shown = [
      for (final p in h.players.values)
        if (p.voluntary && p.cards != null && p.cards!.length == 2) p
    ]..sort((a, b) => a.name.compareTo(b.name));
    if (shown.length < 2) continue;
    final a = shown[0], b = shown[1];
    if ({...a.cards!, ...b.cards!, ...board}.length != 4 + board.length) continue;
    final streets = equityByStreet([a.cards!, b.cards!], board, samples: samples, rng: rng);
    out.add(SwingLine(
      h.n,
      [a.name, b.name],
      [HandClass.fromCards(a.cards![0], a.cards![1]), HandClass.fromCards(b.cards![0], b.cards![1])],
      streets,
      h.hand.startMs,
    ));
  }
  out.sort((x, y) => y.swing.compareTo(x.swing));
  return out;
}

/// The biggest swing of the night so far, or null.
SwingLine? handOfTheNight(MergedNight night, {Random? rng}) {
  final lines = swingLines(night, rng: rng);
  return lines.isEmpty ? null : lines.first;
}
