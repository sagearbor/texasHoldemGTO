/// Watch my cards: what a confident camera read MEANS for the hand being
/// logged. Pure Dart (no Flutter), unit-tested in test/watch_tracker_test.dart.
///
/// The camera reports a pair only after several frames agree (see
/// [PeekVoter] in watch_pipeline.dart). Each such pair goes through
/// [WatchHandTracker.onRead]:
///
///  * no cards yet this hand        -> [WatchAction.fill]
///  * the same two cards again      -> [WatchAction.confirm] (silent: players
///                                     look at their cards many times a hand)
///  * different cards, within
///    [WatchHandTracker.correctionMs] of when the current cards were set
///                                  -> [WatchAction.correct] (a re-peek fixes
///                                     a misread)
///  * different cards, later        -> [WatchAction.newHand] (the caller closes
///                                     the hand the normal way, as Next hand
///                                     would, then logs these cards)
///
/// Known limits, by design:
///  * The same two cards in two hands in a row (about 1 in 1326 hands)
///    look like a re-peek and merge into one hand unless Next hand is
///    tapped in between.
///  * A misread that repeats on every peek is not fixed by re-peeking; the
///    player fixes it once by hand, and that misread is then ignored for the
///    rest of the hand ([manualCards] vetoes it). Different reads within
///    the correction window after a manual pick are ignored too.
library;

import '../poker/cards.dart';

enum WatchAction { fill, confirm, correct, newHand, ignore }

class WatchDecision {
  final WatchAction action;

  /// The two cards now logged for the hand (high card first).
  final List<int> cards;

  /// What [cards] replaced (correct) or closed (newHand); else null.
  final List<int>? previous;
  const WatchDecision(this.action, this.cards, {this.previous});

  /// True when the player should hear something.
  bool get speaks => action == WatchAction.fill || action == WatchAction.correct || action == WatchAction.newHand;

  @override
  String toString() => '${action.name} ${prettyCards(cards)}';
}

/// High card first, so a pair compares equal whatever order it was read in.
List<int> canonicalPair(List<int> pair) {
  assert(pair.length == 2);
  final a = pair[0], b = pair[1];
  return a >= b ? [a, b] : [b, a];
}

bool _same(List<int>? a, List<int>? b) => a != null && b != null && a[0] == b[0] && a[1] == b[1];

class WatchHandTracker {
  /// A different pair this soon after the current one was set replaces it.
  final int correctionMs;

  WatchHandTracker({this.correctionMs = 12000});

  List<int>? _cards;
  int _setAtMs = 0;

  /// The current cards were picked by hand at this time (null: by camera).
  int? _manualAtMs;

  /// Pairs the player overrode by hand this hand: never re-applied.
  final List<List<int>> _vetoed = [];

  /// The cards logged for the current hand (high card first), or null.
  List<int>? get cards => _cards;

  WatchDecision onRead(List<int> pair, int tMs) {
    final p = canonicalPair(pair);
    if (p[0] == p[1]) return WatchDecision(WatchAction.ignore, p);
    if (_vetoed.any((v) => _same(v, p))) return WatchDecision(WatchAction.ignore, p);
    final cur = _cards;
    if (cur == null) {
      _set(p, tMs);
      return WatchDecision(WatchAction.fill, p);
    }
    if (_same(cur, p)) return WatchDecision(WatchAction.confirm, p);
    final manual = _manualAtMs;
    if (manual != null) {
      // Never "correct" a manual pick: shortly after one, a different read
      // is far likelier a misread than a new hand.
      if (tMs - manual <= correctionMs) return WatchDecision(WatchAction.ignore, p);
    } else if (tMs - _setAtMs <= correctionMs) {
      _set(p, tMs);
      return WatchDecision(WatchAction.correct, p, previous: cur);
    }
    _vetoed.clear();
    _set(p, tMs);
    return WatchDecision(WatchAction.newHand, p, previous: cur);
  }

  /// The player picked or fixed the cards by hand ([cards] null = cleared).
  /// A camera pair they replaced is vetoed for the rest of this hand, and a
  /// manual pick is never "corrected" by the camera.
  void manualCards(List<int>? cards, int tMs) {
    final cur = _cards;
    final next = cards == null || cards.length != 2 ? null : canonicalPair(cards);
    if (cur != null && !_same(cur, next)) _vetoed.add(cur);
    _cards = next;
    _manualAtMs = next == null ? null : tMs;
  }

  /// The hand was closed (Next hand, a dealer tap, or undo).
  void handClosed() {
    _cards = null;
    _manualAtMs = null;
    _vetoed.clear();
  }

  void _set(List<int> p, int tMs) {
    _cards = p;
    _manualAtMs = null;
    _setAtMs = tMs;
  }
}

// ---------------------------------------------------------------- speech

const _rankWords = [
  'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', //
  'jack', 'queen', 'king', 'ace',
];
const _suitWords = ['clubs', 'diamonds', 'hearts', 'spades'];

String spokenCard(int c) => '${_rankWords[cardRank(c)]} of ${_suitWords[cardSuit(c)]}';

/// "Ace of spades, king of diamonds": both suits, so a wrong suit is
/// audible (a shorthand like "ace king suited" would hide it).
String spokenPair(List<int> cards) {
  final p = canonicalPair(cards);
  final s = '${spokenCard(p[0])}, ${spokenCard(p[1])}';
  return s[0].toUpperCase() + s.substring(1);
}

/// What to say for [d], or null for silence.
String? spokenDecision(WatchDecision d) => switch (d.action) {
      WatchAction.fill || WatchAction.newHand => spokenPair(d.cards),
      WatchAction.correct => 'Corrected. ${spokenPair(d.cards)}',
      _ => null,
    };
