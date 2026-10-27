/// Range-reading questions built straight from Spot.strategy.
library;

import 'dart:math';

import '../gto/coach.dart';
import '../gto/hand_class.dart';
import '../gto/spots.dart';
import 'quiz_models.dart';

List<Spot> rfiSpots(List<Spot> spots) =>
    [for (final s in spots) if (s.id.startsWith('cash-rfi-')) s];

/// Facing-an-open spots (have a villain and a 3-bet action). Facing-limper
/// and facing-a-3-bet spots are hand-authored and the question wording
/// ("Facing the X open, does Y 3-bet...") does not fit them, so they stay
/// out.
List<Spot> vsOpenSpots(List<Spot> spots) => [
      for (final s in spots)
        if (s.format == SpotFormat.cash100 &&
            s.villain != null &&
            s.group != limperGroup &&
            s.group != threeBetGroup)
          s
    ];

/// True when a grid neighbour (up/down/left/right) of [h] is played at
/// least [minFreq]: the hand sits on the edge of the range.
bool _onEdge(Spot spot, HandClass h, double minFreq) {
  for (final (dr, dc) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
    final r = h.row + dr, c = h.col + dc;
    if (r < 0 || r > 12 || c < 0 || c > 12) continue;
    if (playFreq(spot, HandClass(r, c)) >= minFreq) return true;
  }
  return false;
}

T _pick<T>(Random rng, List<T> xs) => xs[rng.nextInt(xs.length)];

const notInRangeMinDistractorFreq = 0.7;

/// "Which hand is NOT in the X opening range?" Answer is never played
/// (freq 0), preferring hands on the edge of the range; the three
/// distractors are each played at least 70%.
QuizQuestion notInRangeQuestion(Random rng, List<Spot> spots) {
  final spot = _pick(rng, rfiSpots(spots));
  final never = [
    for (final h in allHandClasses)
      if (playFreq(spot, h) <= 1e-9) h
  ];
  final edge = never.where((h) => _onEdge(spot, h, 0.5)).toList();
  final answer = _pick(rng, edge.isNotEmpty ? edge : never);
  final played = [
    for (final h in allHandClasses)
      if (playFreq(spot, h) >= notInRangeMinDistractorFreq) h
  ]..shuffle(rng);
  final options = [answer, ...played.take(3)]..shuffle(rng);
  return QuizQuestion(
    kind: QuizKind.notInRange,
    situation: spot.situation,
    parts: [
      QuizPart(
        prompt: 'Which hand is NOT in the ${spot.hero} opening range?',
        options: [for (final h in options) h.name],
        answer: options.indexOf(answer),
        explanation: [
          '${answer.name} is never opened from ${spot.hero} (Fold 100%).',
          for (final h in options)
            if (h != answer) '${h.name}: ${strategyLine(spot, h)}.',
          '${spot.hero} opens about ${pct(spot.playPercent)} of hands.',
        ],
      ),
    ],
    spotId: spot.id,
    highlight: answer.index,
  );
}

const frequencyOptions = ['Always', 'Sometimes', 'Never'];
const alwaysThreshold = 0.9;
const neverThreshold = 0.1;

/// 0 = always (≥ 90%), 1 = sometimes, 2 = never (≤ 10%).
int frequencyBucket(double f) {
  if (f >= alwaysThreshold) return 0;
  if (f <= neverThreshold) return 2;
  return 1;
}

/// "Does CO 3-bet A5s vs UTG: always / sometimes / never?" The answer
/// bucket is picked uniformly first so all three answers are common.
QuizQuestion frequencyQuestion(Random rng, List<Spot> spots) {
  final spot = _pick(rng, vsOpenSpots(spots));
  final action = spot.actions[0];
  final buckets = <int, List<HandClass>>{0: [], 1: [], 2: []};
  for (final h in allHandClasses) {
    buckets[frequencyBucket(spot.freqs(h)[0])]!.add(h);
  }
  // "Never" is only interesting for hands near the range: ones that are
  // played some other way (calls) or that border the 3-bet range.
  final nearNever = buckets[2]!
      .where((h) => playFreq(spot, h) > 0 || _onEdge3bet(spot, h))
      .toList();
  if (nearNever.isNotEmpty) buckets[2] = nearNever;
  final avail = [for (final e in buckets.entries) if (e.value.isNotEmpty) e.key];
  final bucket = _pick(rng, avail);
  final h = _pick(rng, buckets[bucket]!);
  final f = spot.freqs(h)[0];
  final verb = action.toLowerCase();
  return QuizQuestion(
    kind: QuizKind.frequency,
    situation: spot.situation,
    parts: [
      QuizPart(
        prompt: 'Facing the ${spot.villain} open, does ${spot.hero} $verb '
            '${h.name}?',
        options: frequencyOptions,
        answer: bucket,
        explanation: [
          '${h.name} in ${spot.title}: ${strategyLine(spot, h)}.',
          switch (bucket) {
            0 => '$action ${pct(f)} is at least ${pct(alwaysThreshold)}: Always.',
            2 => '$action ${pct(f)} is at most ${pct(neverThreshold)}: Never.',
            _ => '$action ${pct(f)} is between ${pct(neverThreshold)} and '
                '${pct(alwaysThreshold)}: a mixed hand, Sometimes.',
          },
        ],
      ),
    ],
    spotId: spot.id,
    highlight: h.index,
  );
}

bool _onEdge3bet(Spot spot, HandClass h) {
  for (final (dr, dc) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
    final r = h.row + dr, c = h.col + dc;
    if (r < 0 || r > 12 || c < 0 || c > 12) continue;
    if (spot.freqs(HandClass(r, c))[0] > neverThreshold) return true;
  }
  return false;
}

/// Options for a range-width question: four values 15 points apart, one
/// of which is [correct], all within 5..95. [rng] picks the window.
List<int> widthOptions(Random rng, int correct) {
  final starts = [
    for (var s = -3; s <= 0; s++)
      if (correct + s * 15 >= 5 && correct + (s + 3) * 15 <= 95) s
  ];
  final s = starts.isEmpty ? 0 : _pick(rng, starts);
  return [for (var k = s; k < s + 4; k++) correct + k * 15];
}

/// "About how wide does SB open?" from Spot.playPercent, rounded to 5.
QuizQuestion rangeWidthQuestion(Random rng, List<Spot> spots) {
  final pool = [...rfiSpots(spots), ...vsOpenSpots(spots)];
  final spot = _pick(rng, pool);
  final p = spot.playPercent;
  final correct = ((p * 100) / 5).round() * 5;
  final opts = widthOptions(rng, correct);
  final combos = (p * 1326).round();
  final rfi = spot.villain == null;
  return QuizQuestion(
    kind: QuizKind.rangeWidth,
    situation: spot.situation,
    parts: [
      QuizPart(
        prompt: rfi
            ? 'About how wide does ${spot.hero} open?'
            : 'About what share of hands does ${spot.hero} play '
                '(${spot.actions.where((a) => a != 'Fold').join(' or ').toLowerCase()}) '
                'vs a ${spot.villain} open?',
        options: [for (final o in opts) '$o%'],
        answer: opts.indexOf(correct),
        explanation: [
          '${spot.hero} plays about $combos of 1326 combos = '
              '${(p * 100).toStringAsFixed(1)}%, so about $correct%.',
          if (rfi)
            'Later seats open wider: fewer players are left to act behind.'
          else if (spot.hero == 'BB')
            'The big blind has 1bb invested and closes the action, so it '
                'defends wider than any other seat.'
          else
            'Facing a raise you need a stronger range than the opener: '
                'their range is already filtered.',
        ],
      ),
    ],
    spotId: spot.id,
  );
}
