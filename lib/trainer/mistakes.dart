/// Mistake heatmap maths: recency-weighted accuracy per hand class, and the
/// weakest (spot, hand) pairs for the "Drill my weak hands" button. Pure
/// functions over the trainer history, so they are cheap to test.
library;

import 'dart:math';

import 'trainer_model.dart';

/// An answer this old counts half as much as one from today.
const mistakeHalfLife = Duration(days: 14);

/// Cells below this recency-weighted accuracy are "weak" and get drilled.
const weakThreshold = 0.8;

/// Weight of an answer given at [ts] when it is [now] (both epoch ms):
/// 1 for now, halving every [halfLife]. Future timestamps (a clock that
/// went backwards) count as now.
double recencyWeight(int ts, int now, {Duration halfLife = mistakeHalfLife}) {
  final age = max(0, now - ts) / halfLife.inMilliseconds;
  return pow(0.5, age).toDouble();
}

/// Recency-weighted score of one heatmap cell.
class CellScore {
  /// Weighted share of non-miss answers, 0..1.
  final double accuracy;

  /// Raw number of answers behind it.
  final int attempts;

  /// Sum of recency weights (how much recent evidence there is).
  final double weight;
  const CellScore(this.accuracy, this.attempts, this.weight);
}

class _Acc {
  double good = 0, total = 0;
  int n = 0;
  void add(Answer a, int now) {
    final w = recencyWeight(a.ts, now);
    total += w;
    if (!a.isMiss) good += w;
    n++;
  }

  CellScore get score => CellScore(total == 0 ? 0 : good / total, n, total);
}

/// Hand-class index -> score, over answers in any of [spotIds]. Hands with
/// no answers are absent (the grid draws them neutral). Passing several
/// spot ids gives the "all spots in this group" aggregate.
Map<int, CellScore> cellScores(
    Iterable<Answer> history, Set<String> spotIds, int now) {
  final acc = <int, _Acc>{};
  for (final a in history) {
    if (!spotIds.contains(a.spotId)) continue;
    (acc[a.hand] ??= _Acc()).add(a, now);
  }
  return {for (final e in acc.entries) e.key: e.value.score};
}

/// Weakest (spotId, hand) pairs in [spotIds], worst first: recency-weighted
/// accuracy below [threshold], ties broken by more recent evidence, then
/// spot id and hand index so the order is deterministic.
List<(String, int)> weakTargets(
    Iterable<Answer> history, Set<String> spotIds, int now,
    {int limit = 12, double threshold = weakThreshold}) {
  final acc = <(String, int), _Acc>{};
  for (final a in history) {
    if (!spotIds.contains(a.spotId)) continue;
    (acc[(a.spotId, a.hand)] ??= _Acc()).add(a, now);
  }
  final weak = [
    for (final e in acc.entries)
      if (e.value.score.accuracy < threshold) (e.key, e.value.score)
  ]..sort((a, b) {
      var d = a.$2.accuracy.compareTo(b.$2.accuracy);
      if (d != 0) return d;
      d = b.$2.weight.compareTo(a.$2.weight);
      if (d != 0) return d;
      d = a.$1.$1.compareTo(b.$1.$1);
      return d != 0 ? d : a.$1.$2.compareTo(b.$1.$2);
    });
  return [for (final w in weak.take(limit)) w.$1];
}

/// Heatmap band for a cell, which also picks its colour-blind pattern.
enum MistakeBand { leak, shaky, solid }

MistakeBand mistakeBand(double accuracy) => accuracy < 0.5
    ? MistakeBand.leak
    : accuracy < weakThreshold
        ? MistakeBand.shaky
        : MistakeBand.solid;
