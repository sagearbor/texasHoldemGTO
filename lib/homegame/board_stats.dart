/// Stats the board caller unlocks: flops seen, and, for hands with your
/// cards and a full board, the made hand you ended up with. Pure functions
/// of the logged hands; nothing new is recorded.
library;

import '../poker/evaluator.dart';
import 'home_game.dart';

class BoardStats {
  /// Hands with at least a flop recorded.
  final int boards;

  /// Hands with a recorded preflop action and a flop recorded.
  final int flopChances;

  /// ...of which you did not fold preflop (you saw the flop).
  final int flopsSeen;

  /// Made-hand category (0 = high card .. 8 = straight flush, see
  /// [handCategoryNames]) -> count, over hands you did not fold preflop that
  /// have your cards and all five board cards.
  final Map<int, int> categories;

  /// Hands counted in [categories].
  final int showdowns;

  /// Strongest made hand among those, with its evaluator score.
  final LoggedHand? best;
  final int bestScore;

  const BoardStats({
    required this.boards,
    required this.flopChances,
    required this.flopsSeen,
    required this.categories,
    required this.showdowns,
    required this.best,
    required this.bestScore,
  });

  double get flopSeenPct => flopChances == 0 ? 0 : flopsSeen / flopChances;

  bool get isEmpty => boards == 0;

  /// "Full house" etc. for [best].
  String? get bestName => best == null ? null : handCategoryNames[handCategory(bestScore)];

  /// Categories with at least one hand, strongest first.
  List<(String, int)> get categoryRows => [
        for (var c = handCategoryNames.length - 1; c >= 0; c--)
          if ((categories[c] ?? 0) > 0) (handCategoryNames[c], categories[c]!)
      ];
}

/// True when you didn't fold preflop and a flop was recorded.
bool sawFlop(LoggedHand h) =>
    h.action != null && h.action != PreAction.fold && (h.board?.length ?? 0) >= 3;

/// Your final 7-card hand score, when your cards and a full board exist.
int? finalHandScore(LoggedHand h) {
  final c = h.cards, b = h.board;
  if (c == null || b == null || b.length != 5) return null;
  return evaluate([...c, ...b]);
}

/// Board stats over [hands]. Hands you folded preflop are left out of the
/// made-hand numbers (you never held that hand), but hands where you only
/// saved your cards (no action) count: you may well have played them.
BoardStats boardStats(Iterable<LoggedHand> hands) {
  var boards = 0, chances = 0, seen = 0, showdowns = 0, bestScore = -1;
  LoggedHand? best;
  final cats = <int, int>{};
  for (final h in hands) {
    final flop = (h.board?.length ?? 0) >= 3;
    if (!flop) continue;
    boards++;
    if (h.action != null) {
      chances++;
      if (sawFlop(h)) seen++;
    }
    if (h.action == PreAction.fold) continue;
    final score = finalHandScore(h);
    if (score == null) continue;
    showdowns++;
    final cat = handCategory(score);
    cats[cat] = (cats[cat] ?? 0) + 1;
    if (score > bestScore) {
      bestScore = score;
      best = h;
    }
  }
  return BoardStats(
    boards: boards,
    flopChances: chances,
    flopsSeen: seen,
    categories: cats,
    showdowns: showdowns,
    best: best,
    bestScore: bestScore,
  );
}
