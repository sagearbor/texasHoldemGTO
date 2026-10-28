/// The first-session "60-second leak test": 10 borderline hands from a
/// fixed, balanced set of spot families, then a plain-language verdict.
///
/// No AI: the hands come from the strategy tables and every verdict
/// sentence is a template picked by which way the misses went (too tight =
/// folded a hand GTO plays, too loose = played a hand GTO folds).
library;

import 'dart:math';

import '../gto/coach.dart';
import '../gto/hand_class.dart';
import '../gto/spots.dart';
import 'trainer_model.dart';

/// The five spot families the test covers, two hands each.
enum LeakFamily { lateOpen, earlyOpen, bbDefend, smallBlind, pushFold }

/// Candidate spot ids per family (missing ids are skipped).
const leakFamilySpots = <LeakFamily, List<String>>{
  LeakFamily.lateOpen: ['cash-rfi-CO', 'cash-rfi-BTN'],
  LeakFamily.earlyOpen: ['cash-rfi-UTG', 'cash-rfi-HJ'],
  LeakFamily.bbDefend: ['cash-BB-vs-BTN', 'cash-BB-vs-CO', 'cash-BB-vs-SB'],
  LeakFamily.smallBlind: ['cash-rfi-SB', 'cash-SB-vs-BTN'],
  LeakFamily.pushFold: [
    'pf-sb-8', 'pf-sb-10', 'pf-sb-12', 'pf-sb-15', //
    'pf-bb-8', 'pf-bb-10', 'pf-bb-12', 'pf-bb-15',
  ],
};

const leakTestLength = 10;

/// How a missed answer went wrong.
enum LeakDirection {
  /// Folded (or checked) a hand GTO plays.
  tooTight,

  /// Played a hand GTO folds.
  tooLoose,

  /// Played the hand, but picked the wrong way to play it (call vs 3-bet).
  wrongPlay,
}

/// One hand of the test.
class LeakTestItem {
  final LeakFamily family;
  final Spot spot;
  final HandClass hand;
  final List<int> cards;

  /// True when GTO mostly plays the hand, false when it mostly folds it.
  final bool shouldPlay;
  const LeakTestItem(
      this.family, this.spot, this.hand, this.cards, this.shouldPlay);
}

/// A hand qualifies when it sits on the edge of the range (edginess >= 0.7)
/// but still has a clear answer: played at least 80% or at most 20%, so
/// the wrong side is always a miss.
bool _clearPlay(Spot s, HandClass h) =>
    edginess(s, h) >= 0.7 && playFreq(s, h) >= 0.8;
bool _clearFold(Spot s, HandClass h) =>
    edginess(s, h) >= 0.7 && playFreq(s, h) <= 0.2;

/// The curated pool for [family]: (spot, hand) pairs that should be played
/// ([play] true) or folded.
List<(Spot, HandClass)> leakPool(SpotLibrary lib, LeakFamily family,
    {required bool play}) {
  final byId = {for (final s in lib.all) s.id: s};
  return [
    for (final id in leakFamilySpots[family]!)
      if (byId[id] case final s?)
        for (final h in allHandClasses)
          if (play ? _clearPlay(s, h) : _clearFold(s, h)) (s, h)
  ];
}

/// Ten hands: per family one that should be played and one that should be
/// folded, so both "too tight" and "too loose" can show up. No hand class
/// repeats. [rng] picks among the pool and shuffles the order.
List<LeakTestItem> leakTestSet(SpotLibrary lib, Random rng) {
  final items = <LeakTestItem>[];
  final usedHands = <int>{};
  for (final f in LeakFamily.values) {
    for (final play in [true, false]) {
      final pool = leakPool(lib, f, play: play)
          .where((p) => !usedHands.contains(p.$2.index))
          .toList();
      if (pool.isEmpty) continue;
      final (spot, hand) = pool[rng.nextInt(pool.length)];
      usedHands.add(hand.index);
      final combos = hand.combos();
      items.add(LeakTestItem(
          f, spot, hand, combos[rng.nextInt(combos.length)], play));
    }
  }
  items.shuffle(rng);
  return items;
}

/// Same miss rule as the trainer ([Answer.isMiss]).
bool isLeakMiss(Spot spot, HandClass h, int chosen) =>
    spot.freqs(h)[chosen] < 0.25;

/// Which way [chosen] missed, or null when it is not a miss.
LeakDirection? missDirection(Spot spot, HandClass h, int chosen) {
  if (!isLeakMiss(spot, h, chosen)) return null;
  final passive = spot.passiveIndex;
  if (chosen == passive) return LeakDirection.tooTight;
  if (spot.freqs(h)[passive] >= 0.5) return LeakDirection.tooLoose;
  return LeakDirection.wrongPlay;
}

class LeakTestAnswer {
  final LeakTestItem item;
  final int chosen;
  const LeakTestAnswer(this.item, this.chosen);

  bool get isMiss => isLeakMiss(item.spot, item.hand, chosen);
  LeakDirection? get direction => missDirection(item.spot, item.hand, chosen);
}

/// One leak found by the test, with its sentence.
class Leak {
  final LeakFamily family;
  final LeakDirection direction;
  final int count;
  final String sentence;
  const Leak(this.family, this.direction, this.count, this.sentence);
}

class LeakVerdict {
  final int correct;
  final int total;

  /// Up to 3 leaks, biggest first.
  final List<Leak> leaks;

  /// Missed (spotId, hand index) pairs, in answer order, de-duplicated.
  final List<(String, int)> misses;
  const LeakVerdict(this.correct, this.total, this.leaks, this.misses);

  /// Short headline for the score.
  String get headline {
    if (total == 0) return 'No hands answered';
    final r = correct / total;
    if (r >= 0.9) return 'Sharp. Hardly a leak in sight.';
    if (r >= 0.7) return 'Solid, with a couple of leaks to fix.';
    if (r >= 0.5) return 'Some clear leaks. Very fixable.';
    return 'Lots to gain. Start with the leaks below.';
  }

  /// The sentences shown on the verdict page (always at least one).
  List<String> get sentences => leaks.isEmpty
      ? ['No clear leaks in these hands. Drill borderline spots to stay sharp.']
      : [for (final l in leaks) l.sentence];
}

const _seatNames = {
  'UTG': 'under the gun',
  'HJ': 'in the hijack',
  'CO': 'in the cutoff',
  'BTN': 'on the button',
};

/// The template sentence for a leak in [family] going [dir]. [heroes] are
/// the seats of the missed hands, used to name one seat when they agree.
String leakSentence(LeakFamily family, LeakDirection dir, Set<String> heroes,
    {Set<String> spotIds = const {}}) {
  String where(String fallback) =>
      heroes.length == 1 ? (_seatNames[heroes.first] ?? fallback) : fallback;
  final tight = dir == LeakDirection.tooTight;
  switch (family) {
    case LeakFamily.lateOpen:
      final w = where('from late position');
      return tight
          ? 'You fold too often $w. Late seats should open wide.'
          : 'You open too loose $w, even for a late seat.';
    case LeakFamily.earlyOpen:
      final w = where('from early position');
      return tight
          ? 'You fold too much $w. Strong hands like these are opens.'
          : 'You open too loose $w. Tighten up with many players still to act.';
    case LeakFamily.bbDefend:
      if (dir == LeakDirection.wrongPlay) {
        return 'In the big blind you mix up calling and 3-betting.';
      }
      return tight
          ? 'You defend too little from the big blind. You already have 1bb in, so the price is good.'
          : 'You defend too wide from the big blind. Some hands are still folds.';
    case LeakFamily.smallBlind:
      return tight
          ? 'You play too tight from the small blind.'
          : 'You play too loose from the small blind, out of position all hand.';
    case LeakFamily.pushFold:
      final calls = spotIds.isNotEmpty && spotIds.every((id) => id.startsWith('pf-bb'));
      final jams = spotIds.isNotEmpty && spotIds.every((id) => id.startsWith('pf-sb'));
      final verb = calls ? 'call jams' : (jams ? 'jam' : 'jam and call');
      return tight
          ? 'You $verb too tight when short. Short-stacked, more hands are good enough to get it in.'
          : 'You $verb too loose when short. Some of these hands lose too often.';
  }
}

/// Builds the verdict from [answers].
LeakVerdict leakVerdict(List<LeakTestAnswer> answers) {
  final groups = <(LeakFamily, LeakDirection), List<LeakTestAnswer>>{};
  final misses = <(String, int)>[];
  var correct = 0;
  for (final a in answers) {
    final d = a.direction;
    if (d == null) {
      correct++;
      continue;
    }
    (groups[(a.item.family, d)] ??= []).add(a);
    final m = (a.item.spot.id, a.item.hand.index);
    if (!misses.contains(m)) misses.add(m);
  }
  final keys = groups.keys.toList()
    ..sort((a, b) {
      final c = groups[b]!.length.compareTo(groups[a]!.length);
      if (c != 0) return c;
      final f = a.$1.index.compareTo(b.$1.index);
      return f != 0 ? f : a.$2.index.compareTo(b.$2.index);
    });
  final leaks = [
    for (final k in keys.take(3))
      Leak(
        k.$1,
        k.$2,
        groups[k]!.length,
        leakSentence(k.$1, k.$2, {for (final a in groups[k]!) a.item.spot.hero},
            spotIds: {for (final a in groups[k]!) a.item.spot.id}),
      )
  ];
  return LeakVerdict(correct, answers.length, leaks, misses);
}

/// Records every answer in the trainer history (stats + deck).
void recordLeakAnswer(TrainerModel model, LeakTestAnswer a) =>
    model.record(a.item.spot, a.item.hand, a.chosen);

/// "Drill my leaks": seeds the misses into the spaced-repetition deck and
/// switches the trainer to leaks mode.
Future<void> drillLeaks(TrainerModel model, LeakVerdict v) async {
  await model.addExternalMisses(v.misses);
  model.setMode(DrillMode.leaks);
}
