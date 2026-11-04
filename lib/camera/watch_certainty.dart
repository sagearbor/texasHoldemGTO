/// Watch my cards: how sure the camera is of a logged pair (0..1), shown on
/// the watch buzz ("Felt Notes: cards read · 87%") and written to the watch
/// log with its raw parts, so it can be calibrated against labelled nights.
///
/// UNCALIBRATED: the number is a monotone heuristic, not a probability. A
/// hand logged at 80 % is not known to be right 4 times in 5; it is only
/// known to be at least as sure as one logged at 60 %. Calibrate it from
/// logs (decision records: certainty vs. the true cards) before trusting
/// the scale. Pure Dart, unit-tested in test/watch_certainty_test.dart.
library;

import 'dart:math' as math;

/// The evidence behind one agreed pair (from PeekVoter / WatchPipeline):
/// the raw parts of [watchCertainty], logged as they are.
class PairEvidence {
  /// Mean reader score (CNN: P(rank) * P(suit)) of each card of the pair
  /// (high card first) over the frames that voted for it; null when the
  /// scores were not passed in.
  final double? scoreHigh, scoreLow;

  /// Frames supporting the pair: within the vote window, the frames that
  /// read the less-seen of the two cards; across peeks, the remembered
  /// two-card frames that read this exact pair; 1 for a single-frame read.
  final int agree;

  /// Support of the strongest rival: a third card's frames (vote window) or
  /// another remembered pair's frames (across peeks). Always < [agree] for an
  /// agreed pair (a tie produces no pair).
  final int rival;

  /// Which voter path agreed the pair: 'window', 'memory' or 'single'.
  final String via;

  const PairEvidence({this.scoreHigh, this.scoreLow, required this.agree, this.rival = 0, required this.via});

  double? get certainty => watchCertainty(scoreHigh, scoreLow, agree: agree, rival: rival);

  Map<String, Object?> toJson() => {
        'certainty': _r3(certainty),
        'scoreHigh': _r3(scoreHigh),
        'scoreLow': _r3(scoreLow),
        'agree': agree,
        'rival': rival,
        'via': via,
      };

  @override
  String toString() => '${certainty == null ? '-' : '${(certainty! * 100).round()}%'} '
      '(${scoreHigh?.toStringAsFixed(2)}/${scoreLow?.toStringAsFixed(2)} agree $agree rival $rival $via)';
}

double? _r3(double? v) => v == null ? null : double.parse(v.toStringAsFixed(3));

/// Certainty (0..1, UNCALIBRATED, see the library comment) of a pair:
///
///     certainty = min(scoreHigh, scoreLow)       weaker card's mean score
///               * (1 - 0.3 * 0.5^(agree - 1))    agreement: 1 frame 0.70,
///                                                2: 0.85, 3: 0.925, ...
///               * (1 - 0.5 * rival / agree)      a rival close to the
///                                                pair's support: ~0.5
///
/// Non-decreasing in each score and in [agree], non-increasing in [rival].
/// Null when either score is unknown.
double? watchCertainty(double? scoreHigh, double? scoreLow, {required int agree, int rival = 0}) {
  if (scoreHigh == null || scoreLow == null) return null;
  final a = math.max(1, agree);
  final base = math.min(scoreHigh, scoreLow).clamp(0.0, 1.0);
  final agreement = 1 - 0.3 * math.pow(0.5, a - 1);
  final contest = 1 - 0.5 * (rival.clamp(0, a) / a);
  return (base * agreement * contest).clamp(0.0, 1.0);
}

/// Mean of [xs] ignoring nulls; null when none is known.
double? meanScore(Iterable<double?> xs) {
  var n = 0;
  var s = 0.0;
  for (final x in xs) {
    if (x == null) continue;
    s += x;
    n++;
  }
  return n == 0 ? null : s / n;
}
