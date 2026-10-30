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
///  * different cards before the cards
///    were put down (same card episode, see WatchPipeline.cardEpisode)
///                                  -> [WatchAction.correct] (a misread fixed
///                                     by more frames)
///  * different cards in a later episode
///                                  -> [WatchAction.newHand] (the caller closes
///                                     the hand the normal way, as Next hand
///                                     would, then logs these cards)
/// Time alone was the first design (a 12 s correction window,
/// [WatchHandTracker.correctionMs], still used when no episode is given);
/// the owner's test footage deals a new hand every ~5 s, so the cards going
/// down is the hand boundary now.
///
/// Known limits, by design:
///  * The same two cards in two hands in a row (about 1 in 1326 hands)
///    look like a re-peek and merge into one hand unless Next hand is
///    tapped in between.
///  * A misread agreed on in one peek and fixed only on a later peek splits
///    the hand in two (the fix looks like a new hand). Agreement voting
///    makes such misreads rare; the chip on the black screen fixes it.
///  * A misread that repeats on every peek is not fixed by re-peeking; the
///    player fixes it once by hand, and that misread is then ignored for the
///    rest of the hand ([manualCards] vetoes it). Different reads within
///    the correction window after a manual pick are ignored too.
library;

import '../poker/cards.dart';

enum WatchAction {
  fill,
  confirm,
  correct,
  newHand,

  /// The cards changed but were never agreed on: close the hand being played
  /// (default fold, as Next hand) and start one with no cards ("not read").
  /// [WatchDecision.cards] holds what was seen of the new hand (0-2 cards).
  newHandUnread,
  ignore,
}

class WatchDecision {
  final WatchAction action;

  /// The two cards now logged for the hand (high card first).
  final List<int> cards;

  /// What [cards] replaced (correct) or closed (newHand); else null.
  final List<int>? previous;
  const WatchDecision(this.action, this.cards, {this.previous});

  /// True when the player should hear something.
  bool get speaks => action == WatchAction.fill || action == WatchAction.correct || action == WatchAction.newHand;

  /// Starts a new hand (the caller closes the current one first).
  bool get startsHand => action == WatchAction.newHand || action == WatchAction.newHandUnread;

  @override
  String toString() => '${action.name} ${prettyCards(cards)}';
}

/// [b] could be [a] with one card misread: one card in common, and the
/// other two share their rank (a suit misread: the reader only confuses
/// suits of one colour) or their suit (a rank misread). A new hand that
/// happens to keep a card (about 8 % of hands) rarely also matches like this.
bool looksLikeMisread(List<int> a, List<int> b) {
  final common = a.where(b.contains).toList();
  if (common.length != 1) return false;
  final x = a.firstWhere((c) => c != common.first), y = b.firstWhere((c) => c != common.first);
  return cardRank(x) == cardRank(y) || cardSuit(x) == cardSuit(y);
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

  /// Card episode (cards up .. put down) in which [_cards] were set, when
  /// the caller tracks episodes.
  int? _setEpisode;

  /// Scene epoch (see WatchPipeline.sceneEpoch) of the last time the
  /// current hand's cards were seen.
  int? _scene;

  /// The current cards were picked by hand at this time (null: by camera).
  int? _manualAtMs;

  /// Pairs the player overrode by hand this hand: never re-applied.
  final List<List<int>> _vetoed = [];

  /// Cards seen (but never agreed as a pair) in the hand being played while
  /// it has no cards: at most two. A look with a card outside them (or
  /// outside [_cards]) means the cards changed: a hand was dealt that the
  /// reader missed.
  final Set<int> _partial = {};

  /// Cards seen of the current hand, for the chip ("cards not read").
  Set<int> get partial => Set.unmodifiable(_partial);

  /// The cards logged for the current hand (high card first), or null.
  List<int>? get cards => _cards;

  /// [episode]: the camera's card episode (WatchPipeline.cardEpisode). With
  /// it, a different pair is a correction in the same episode (before the
  /// cards were put down), or in a later episode of the same [scene] when
  /// it keeps one of the two cards (a misread fixed on a re-peek, the hands
  /// never left the view); otherwise it is the next hand, whatever the time.
  /// Without an episode, [correctionMs] decides.
  WatchDecision onRead(List<int> pair, int tMs, {int? episode, int? scene}) {
    final p = canonicalPair(pair);
    if (p[0] == p[1]) return WatchDecision(WatchAction.ignore, p);
    if (_vetoed.any((v) => _same(v, p))) return WatchDecision(WatchAction.ignore, p);
    final cur = _cards;
    if (cur == null) {
      // Seen cards that do not fit this pair belonged to a hand the reader
      // missed: that hand ends here, unread.
      final missed = _partial.any((c) => !p.contains(c));
      _set(p, tMs, episode, scene);
      return WatchDecision(missed ? WatchAction.newHand : WatchAction.fill, p);
    }
    if (_same(cur, p)) {
      _scene = scene ?? _scene;
      return WatchDecision(WatchAction.confirm, p);
    }
    final manual = _manualAtMs;
    if (manual != null) {
      // Never "correct" a manual pick: shortly after one, a different read
      // is far likelier a misread than a new hand.
      if (tMs - manual <= correctionMs) return WatchDecision(WatchAction.ignore, p);
    } else if (episode != null && _setEpisode != null
        ? episode == _setEpisode || (scene != null && scene == _scene && looksLikeMisread(cur, p))
        : tMs - _setAtMs <= correctionMs) {
      _set(p, tMs, episode, scene);
      return WatchDecision(WatchAction.correct, p, previous: cur);
    }
    _vetoed.clear();
    _set(p, tMs, episode, scene);
    return WatchDecision(WatchAction.newHand, p, previous: cur);
  }

  /// A look ended (the cards went down, or out of view) without an agreed
  /// pair. [seen] = cards read confidently in at least two of its frames.
  /// Cards that are not the current hand's mean a new hand was dealt that
  /// the reader missed: it is still counted (hand drift would otherwise move
  /// the button wrongly), as a hand with no cards.
  /// In the same [scene] (the hands never left the view), a look that still
  /// shows one of the current cards is a re-peek with a misread, not a hand.
  WatchDecision onLookEnd(Set<int> seen, int tMs, {int? scene}) {
    final s = {
      for (final c in seen)
        if (!_vetoed.any((v) => v.contains(c))) c
    };
    if (s.isEmpty) return const WatchDecision(WatchAction.ignore, []);
    final cur = _cards;
    if (cur != null) {
      if (s.every(cur.contains)) return WatchDecision(WatchAction.confirm, cur);
      // One stray card with the rank of a current card is likelier a suit
      // misread of it (T♦ read as T♣ on the owner's footage) than a new hand.
      if (s.length == 1 && cur.any((c) => cardRank(c) == cardRank(s.first))) {
        return WatchDecision(WatchAction.ignore, cur);
      }
      if (scene != null && scene == _scene && s.length == 1 && s.any(cur.contains)) {
        return WatchDecision(WatchAction.ignore, cur);
      }
    } else if ({..._partial, ...s}.length <= 2) {
      _partial.addAll(s);
      return const WatchDecision(WatchAction.ignore, []);
    }
    // The cards changed and were not read: a new hand.
    final prev = cur;
    handClosed();
    _partial.addAll(s.take(2));
    _setAtMs = tMs;
    return WatchDecision(WatchAction.newHandUnread, s.take(2).toList(), previous: prev);
  }

  /// The player picked or fixed the cards by hand ([cards] null = cleared).
  /// A camera pair they replaced is vetoed for the rest of this hand, and a
  /// manual pick is never "corrected" by the camera.
  void manualCards(List<int>? cards, int tMs) {
    final cur = _cards;
    final next = cards == null || cards.length != 2 ? null : canonicalPair(cards);
    if (cur != null && !_same(cur, next)) _vetoed.add(cur);
    _cards = next;
    _setEpisode = null;
    _manualAtMs = next == null ? null : tMs;
  }

  /// The hand was closed (Next hand, a dealer tap, or undo).
  void handClosed() {
    _cards = null;
    _partial.clear();
    _setEpisode = null;
    _manualAtMs = null;
    _vetoed.clear();
  }

  void _set(List<int> p, int tMs, int? episode, [int? scene]) {
    _cards = p;
    _scene = scene;
    _partial.clear();
    _setEpisode = episode;
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
