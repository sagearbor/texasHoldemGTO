/// Entry points for building quiz questions, deterministic for a seed.
library;

import 'dart:math';

import '../gto/spots.dart';
import 'pot_odds.dart';
import 'quiz_models.dart';
import 'range_reading.dart';

export 'pot_odds.dart';
export 'quiz_models.dart';
export 'range_reading.dart';

enum QuizFocus { mixed, potOdds, ranges }

const quizFocusLabels = {
  QuizFocus.mixed: 'Mixed',
  QuizFocus.potOdds: 'Pot odds',
  QuizFocus.ranges: 'Ranges',
};

QuizQuestion generateQuestion(QuizKind kind, Random rng, List<Spot> spots) =>
    switch (kind) {
      QuizKind.potOdds => potOddsQuestion(rng, spots),
      QuizKind.notInRange => notInRangeQuestion(rng, spots),
      QuizKind.frequency => frequencyQuestion(rng, spots),
      QuizKind.rangeWidth => rangeWidthQuestion(rng, spots),
    };

/// The kinds for a session of [length] questions, shuffled by [rng].
/// Mixed: 3 pot odds, 3 not-in-range, 2 frequency, 2 range width per 10.
List<QuizKind> sessionKinds(Random rng, QuizFocus focus, {int length = 10}) {
  final List<QuizKind> base = switch (focus) {
    QuizFocus.potOdds => [QuizKind.potOdds],
    QuizFocus.ranges => [
        QuizKind.notInRange,
        QuizKind.frequency,
        QuizKind.rangeWidth
      ],
    QuizFocus.mixed => [
        QuizKind.potOdds,
        QuizKind.notInRange,
        QuizKind.frequency,
        QuizKind.potOdds,
        QuizKind.rangeWidth,
        QuizKind.notInRange,
        QuizKind.potOdds,
        QuizKind.frequency,
        QuizKind.rangeWidth,
        QuizKind.notInRange,
      ],
  };
  return [for (var i = 0; i < length; i++) base[i % base.length]]
    ..shuffle(rng);
}

/// A plan for a session: kinds plus one seed per question, so each question
/// can be generated independently (e.g. on a background isolate).
class SessionPlan {
  final List<QuizKind> kinds;
  final List<int> seeds;
  const SessionPlan(this.kinds, this.seeds);

  factory SessionPlan.create(Random rng, QuizFocus focus, {int length = 10}) {
    final kinds = sessionKinds(rng, focus, length: length);
    return SessionPlan(kinds, [for (final _ in kinds) rng.nextInt(1 << 30)]);
  }

  int get length => kinds.length;

  /// Message for [generateFromSeed].
  List<int> message(int i) => [kinds[i].index, seeds[i]];
}

List<Spot>? _cash;

/// Isolate-friendly entry: [msg] is [kindIndex, seed]. Uses the 6-max cash
/// spots, which are built in code (no asset loading needed).
QuizQuestion generateFromSeed(List<int> msg) {
  final spots = _cash ??= buildCashSpots();
  return generateQuestion(QuizKind.values[msg[0]], Random(msg[1]), spots);
}
