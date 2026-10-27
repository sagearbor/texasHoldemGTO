/// Hold'em hand evaluator for 5–7 cards.
///
/// [evaluate] returns an int where higher is better. The top bits hold the
/// category (0 = high card .. 8 = straight flush) and the low 20 bits hold up
/// to five 4-bit kickers, so two scores compare directly.
library;

import 'cards.dart';

const handCategoryNames = [
  'High card',
  'Pair',
  'Two pair',
  'Three of a kind',
  'Straight',
  'Flush',
  'Full house',
  'Four of a kind',
  'Straight flush',
];

int handCategory(int score) => score >> 20;

int _pack(int category, List<int> kickers) {
  var v = category;
  for (var i = 0; i < 5; i++) {
    v = (v << 4) | (i < kickers.length ? kickers[i] : 0);
  }
  return v;
}

/// Highest straight top-rank in a 13-bit rank mask, or -1. Handles the wheel.
int _straightTop(int mask) {
  // Ace also plays low: add it as bit "-1" by shifting the mask up one.
  final m = (mask << 1) | ((mask >> 12) & 1);
  for (var top = 13; top >= 4; top--) {
    if ((m >> (top - 4)) & 0x1F == 0x1F) return top - 1;
  }
  return -1;
}

List<int> _topBits(int mask, int n) {
  final out = <int>[];
  for (var r = 12; r >= 0 && out.length < n; r--) {
    if (mask & (1 << r) != 0) out.add(r);
  }
  return out;
}

int evaluate(List<int> cards) {
  final counts = List<int>.filled(13, 0);
  final suitMasks = List<int>.filled(4, 0);
  final suitCounts = List<int>.filled(4, 0);
  var rankMask = 0;
  for (final c in cards) {
    final r = c >> 2, s = c & 3;
    counts[r]++;
    suitMasks[s] |= 1 << r;
    suitCounts[s]++;
    rankMask |= 1 << r;
  }

  // Flush / straight flush.
  for (var s = 0; s < 4; s++) {
    if (suitCounts[s] >= 5) {
      final sf = _straightTop(suitMasks[s]);
      if (sf >= 0) return _pack(8, [sf]);
      return _pack(5, _topBits(suitMasks[s], 5));
    }
  }

  var quad = -1, trips1 = -1, trips2 = -1, pair1 = -1, pair2 = -1;
  for (var r = 12; r >= 0; r--) {
    final n = counts[r];
    if (n == 4) {
      quad = r;
    } else if (n == 3) {
      if (trips1 < 0) {
        trips1 = r;
      } else if (trips2 < 0) {
        trips2 = r;
      }
    } else if (n == 2) {
      if (pair1 < 0) {
        pair1 = r;
      } else if (pair2 < 0) {
        pair2 = r;
      }
    }
  }

  if (quad >= 0) {
    return _pack(7, [quad, ..._topBits(rankMask & ~(1 << quad), 1)]);
  }
  if (trips1 >= 0 && (trips2 >= 0 || pair1 >= 0)) {
    final pairPart = trips2 > pair1 ? trips2 : pair1;
    return _pack(6, [trips1, pairPart]);
  }
  final st = _straightTop(rankMask);
  if (st >= 0) return _pack(4, [st]);
  if (trips1 >= 0) {
    return _pack(3, [trips1, ..._topBits(rankMask & ~(1 << trips1), 2)]);
  }
  if (pair1 >= 0 && pair2 >= 0) {
    final rest = rankMask & ~(1 << pair1) & ~(1 << pair2);
    return _pack(2, [pair1, pair2, ..._topBits(rest, 1)]);
  }
  if (pair1 >= 0) {
    return _pack(1, [pair1, ..._topBits(rankMask & ~(1 << pair1), 3)]);
  }
  return _pack(0, _topBits(rankMask, 5));
}

String describeHand(List<int> cards) =>
    handCategoryNames[handCategory(evaluate(cards))];

/// Convenience for tests: evaluate("AsKsQsJsTs").
int evaluateString(String s) => evaluate(parseCards(s));
