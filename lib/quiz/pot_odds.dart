/// Pot-odds questions: the required-equity formula, then a concrete
/// call-or-fold decision against a villain's preflop opening range.
library;

import 'dart:math';

import '../gto/coach.dart';
import '../gto/hand_class.dart';
import '../gto/spots.dart';
import '../poker/cards.dart';
import '../poker/equity.dart';
import '../poker/evaluator.dart';
import 'quiz_models.dart';

/// Equity needed to break even on a call: bet / (pot + 2 × bet).
/// [pot] is the pot before villain's bet.
double requiredEquity(num pot, num bet) => bet / (pot + 2 * bet);

/// The classic slip: bet / (pot + bet), which leaves hero's call out.
double mistakenEquity(num pot, num bet) => bet / (pot + bet);

/// Rounds an equity (0..1) to the nearest 5 percentage points.
double roundTo5(double e) => (e * 20).round() / 20;

/// Bet sizes as (numerator, denominator) fractions of the pot.
const betFractions = [(1, 4), (1, 3), (1, 2), (2, 3), (3, 4), (1, 1), (3, 2), (2, 1)];

/// Pots divisible by 12, so every fraction above gives a whole-bb bet.
const potSizes = [12, 24, 36, 48, 60, 72, 96, 120];

String fractionName((int, int) f) => switch (f) {
      (1, 1) => 'pot',
      (3, 2) => '1.5× pot',
      (2, 1) => '2× pot',
      _ => '${f.$1}/${f.$2} pot',
    };

/// Villains whose opening range is used for the follow-up. Each has a
/// matching "BB vs X" spot that supplies hero's (defending) hand.
const potOddsVillains = ['UTG', 'HJ', 'CO', 'BTN', 'SB'];

/// Villain range as hand-class index -> weight (its open frequency).
Map<int, double> openRange(Spot rfi) => {
      for (final h in allHandClasses)
        if (playFreq(rfi, h) > 0) h.index: playFreq(rfi, h)
    };

class EquityCalc {
  final double equity;
  final bool exact;
  final int combos;
  final int samples;
  const EquityCalc(this.equity, this.exact, this.combos, this.samples);
}

/// Hero's equity vs a weighted range. Exact enumeration on the turn and
/// river (every villain combo × every runout); seeded Monte Carlo on the
/// flop with [flopSamples] samples.
EquityCalc equityVsRange(
    List<int> hero, Map<int, double> range, List<int> board,
    {int flopSamples = 1500, int seed = 1}) {
  final dead = {...hero, ...board};
  var combos = 0;
  range.forEach((cls, w) {
    for (final c in HandClass.byIndex(cls).combos()) {
      if (!dead.contains(c[0]) && !dead.contains(c[1])) combos++;
    }
  });
  if (board.length < 4) {
    final e = handVsRangeEquity(hero, range, board,
        samples: flopSamples, rng: Random(seed));
    return EquityCalc(e, false, combos, flopSamples);
  }
  // Same result as handsEquity([hero, v], board) per combo, but hero's
  // score for each runout card is computed once and shared by every combo.
  final runouts = board.length == 5
      ? const <int?>[null]
      : [for (var c = 0; c < 52; c++) if (!dead.contains(c)) c];
  final heroScore = {
    for (final r in runouts) r: evaluate([...hero, ...board, if (r != null) r])
  };
  var sum = 0.0, wsum = 0.0;
  range.forEach((cls, w) {
    if (w <= 0) return;
    for (final v in HandClass.byIndex(cls).combos()) {
      if (dead.contains(v[0]) || dead.contains(v[1])) continue;
      var share = 0.0, n = 0;
      for (final r in runouts) {
        if (r == v[0] || r == v[1]) continue;
        final h = heroScore[r]!;
        final vs = evaluate([...v, ...board, if (r != null) r]);
        share += h > vs ? 1 : (h == vs ? 0.5 : 0);
        n++;
      }
      sum += w * share / n;
      wsum += w;
    }
  });
  return EquityCalc(wsum == 0 ? 0.5 : sum / wsum, true, combos, 0);
}

String _cards(List<int> cs) => prettyCards(cs);

int _pctInt(double f) => (f * 100).round();

/// Picks a hand class from [spot]'s non-fold range, weighted by combos ×
/// frequency, then a concrete combo avoiding [dead].
List<int> _handFromRange(Random rng, Spot spot, Set<int> dead) {
  final classes = <HandClass>[];
  final cum = <double>[];
  var acc = 0.0;
  for (final h in allHandClasses) {
    final w = playFreq(spot, h) * h.comboCount;
    if (w <= 0) continue;
    acc += w;
    classes.add(h);
    cum.add(acc);
  }
  while (true) {
    final x = rng.nextDouble() * acc;
    var i = cum.indexWhere((c) => c >= x);
    if (i < 0) i = cum.length - 1;
    final combos = classes[i]
        .combos()
        .where((c) => !dead.contains(c[0]) && !dead.contains(c[1]))
        .toList();
    if (combos.isNotEmpty) return combos[rng.nextInt(combos.length)];
  }
}

/// Builds a two-part pot-odds question. Deterministic for a given [rng]
/// state. Bet size is chosen after the equity is known so that equity and
/// requirement differ by at least 5 points (no coin-flip verdicts).
QuizQuestion potOddsQuestion(Random rng, List<Spot> spots,
    {int flopSamples = 1500}) {
  final villain = potOddsVillains[rng.nextInt(potOddsVillains.length)];
  final rfi = spots.firstWhere((s) => s.id == 'cash-rfi-$villain');
  final defend = spots.firstWhere((s) => s.id == 'cash-BB-vs-$villain');
  final hero = _handFromRange(rng, defend, {});
  final street = 3 + rng.nextInt(3); // 3 flop, 4 turn, 5 river
  final board = dealRandom(rng, street, hero.toSet());
  final range = openRange(rfi);
  final calc = equityVsRange(hero, range, board,
      flopSamples: flopSamples, seed: rng.nextInt(1 << 30));
  final eq = calc.equity;

  final pot = potSizes[rng.nextInt(potSizes.length)];
  final ok = [
    for (final f in betFractions)
      if ((requiredEquity(pot, pot * f.$1 ~/ f.$2) - eq).abs() >= 0.05) f
  ];
  final frac = ok.isNotEmpty
      ? ok[rng.nextInt(ok.length)]
      : (betFractions.toList()
            ..sort((a, b) => (requiredEquity(pot, pot * b.$1 ~/ b.$2) - eq)
                .abs()
                .compareTo((requiredEquity(pot, pot * a.$1 ~/ a.$2) - eq).abs())))
          .first;
  final bet = pot * frac.$1 ~/ frac.$2;
  final req = requiredEquity(pot, bet);
  final reqPct = _pctInt(req);
  final total = pot + 2 * bet;

  // Part 1: required equity, 4 options at least 3 points apart.
  final opts = <int>[reqPct];
  bool fits(int v) => v > 0 && v < 100 && opts.every((o) => (o - v).abs() >= 3);
  final wrongPct = _pctInt(mistakenEquity(pot, bet));
  if (fits(wrongPct)) opts.add(wrongPct);
  final pool = [
    for (final f in betFractions) _pctInt(requiredEquity(12, 12 * f.$1 / f.$2)),
    _pctInt(bet / pot),
  ]..shuffle(rng);
  for (final v in pool) {
    if (opts.length == 4) break;
    if (fits(v)) opts.add(v);
  }
  var filler = 5;
  while (opts.length < 4) {
    if (fits(filler)) opts.add(filler);
    filler += 5;
  }
  opts.shuffle(rng);

  final part1 = QuizPart(
    prompt: 'The pot is $pot bb and villain bets $bet bb '
        '(${fractionName(frac)}). What equity do you need to call?',
    options: [for (final o in opts) '$o%'],
    answer: opts.indexOf(reqPct),
    explanation: [
      'You call $bet bb to win the $pot bb pot plus villain\'s $bet bb.',
      'After your call the pot is $pot + $bet + $bet = $total bb.',
      'Required equity = bet ÷ (pot + 2 × bet) = $bet ÷ $total = $reqPct%.',
      if (wrongPct != reqPct)
        '$wrongPct% (bet ÷ (pot + bet)) is the classic slip: it leaves your '
            'own call out of the final pot.',
    ],
  );

  final streetName = const {3: 'flop', 4: 'turn', 5: 'river'}[street]!;
  final shown = roundTo5(eq);
  final call = eq >= req;
  final method = calc.exact
      ? 'exact: every one of villain\'s ${calc.combos} combos × every runout'
      : 'Monte Carlo, ${calc.samples} samples over ${calc.combos} combos';
  final part2 = QuizPart(
    prompt: 'You hold ${_cards(hero)} on the $streetName. '
        'Villain\'s range is the $villain opening range. Call or fold?',
    options: const ['Call', 'Fold'],
    answer: call ? 0 : 1,
    explanation: [
      'You need $reqPct% equity (from part 1).',
      'Your equity vs the $villain open range here: about ${_pctInt(shown)}% '
          '($method).',
      call
          ? 'About ${_pctInt(shown)}% ≥ $reqPct% needed, so calling is '
              'profitable: Call.'
          : 'About ${_pctInt(shown)}% < $reqPct% needed, so calling loses '
              'money in the long run: Fold.',
      'Margin: ${call ? '+' : '−'}${((eq - req).abs() * 100).round()} points. '
          'This treats villain\'s bet range as their whole opening range.',
    ],
  );

  return QuizQuestion(
    kind: QuizKind.potOdds,
    situation: '$villain opened, you defended in the BB. '
        'Board: ${_cards(board)}.',
    parts: [part1, part2],
    heroCards: hero,
    board: board,
  );
}
