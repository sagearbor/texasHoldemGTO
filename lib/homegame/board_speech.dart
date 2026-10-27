/// Turns what the board caller says ("flop king of hearts seven of spades
/// four of clubs", "turn jack diamonds", "the river is a deuce of clubs")
/// into board cards. Pure Dart, no plugin: the same parser backs the
/// push-to-talk mic and the "type the board" box.
///
/// Parsing is suit-anchored: a card is a rank word followed by an optional
/// "of" and a suit word. Rank words that are only homophones ("for", "to",
/// "ate", "tin", "a") count only when a suit follows straight away, so
/// ordinary words in a sentence are never turned into cards. Two forms also
/// share a rank or suit: "seven seven hearts spades" (ranks queue up until
/// suits arrive) and "seven of hearts and spades" (a bare suit reuses the
/// previous card's rank).
library;

import '../poker/cards.dart';

enum Street { flop, turn, river }

const streetNames = {Street.flop: 'Flop', Street.turn: 'Turn', Street.river: 'River'};

/// Which street the next card(s) belong to on a board of [length] cards.
Street streetForLength(int length) => length < 3
    ? Street.flop
    : length == 3
        ? Street.turn
        : Street.river;

class BoardParse {
  /// Street spoken last (or inferred from the board when none was spoken).
  final Street? street;
  final bool streetSpoken;

  /// Cards recognised in this utterance, in the order spoken.
  final List<int> cards;

  /// The board after applying this utterance; the input board when [ok] is
  /// false.
  final List<int> board;

  /// 0..1. Drops for homophones, guessed streets and leftover words.
  final double confidence;

  /// Words that were not understood (fillers like "the" or "is" removed).
  final String remainder;

  /// Why the utterance was rejected; null when it can be applied.
  final String? problem;

  const BoardParse({
    required this.street,
    required this.streetSpoken,
    required this.cards,
    required this.board,
    required this.confidence,
    required this.remainder,
    this.problem,
  });

  bool get ok => problem == null && cards.isNotEmpty;

  @override
  String toString() => 'BoardParse(${cards.map(cardToString).join(' ')} -> '
      '${board.map(cardToString).join(' ')}, street: $street, '
      'conf: ${confidence.toStringAsFixed(2)}, rest: "$remainder", problem: $problem)';
}

/// Short "K♥ 7♠ 4♣" label.
String cardLabel(int c) {
  final r = rankChars[cardRank(c)];
  return '${r == 'T' ? '10' : r}${suitSymbols[cardSuit(c)]}';
}

String boardLabel(Iterable<int> cards) => cards.map(cardLabel).join(' ');

// ------------------------------------------------------------------ lexicon

/// Rank words that are unambiguous on their own.
const _strongRanks = <String, int>{
  'two': 0, 'twos': 0, 'deuce': 0, 'deuces': 0, 'duce': 0, 'duece': 0, '2': 0,
  'three': 1, 'threes': 1, 'trey': 1, 'tray': 1, '3': 1,
  'four': 2, 'fours': 2, '4': 2,
  'five': 3, 'fives': 3, '5': 3,
  'six': 4, 'sixes': 4, '6': 4,
  'seven': 5, 'sevens': 5, '7': 5,
  'eight': 6, 'eights': 6, '8': 6,
  'nine': 7, 'nines': 7, '9': 7,
  'ten': 8, 'tens': 8, '10': 8,
  'jack': 9, 'jacks': 9, 'j': 9,
  'queen': 10, 'queens': 10, 'q': 10,
  'king': 11, 'kings': 11, 'k': 11,
  'ace': 12, 'aces': 12,
};

/// Homophones / mishearings: only a rank when a suit follows directly.
const _weakRanks = <String, int>{
  'to': 0, 'too': 0, 'tu': 0,
  'tree': 1, 'free': 1,
  'for': 2, 'fore': 2, 'far': 2,
  'fife': 3, 'hive': 3,
  'sicks': 4, 'sex': 4, 'sticks': 4,
  'ate': 6,
  'nein': 7,
  'tin': 8, 'tim': 8, 't': 8,
  'jak': 9,
  'king\'s': 11,
  'a': 12, 'ase': 12, 'ice': 12, 'eighth': 6,
};

/// Suit words that are unambiguous on their own.
const _strongSuits = <String, int>{
  'club': 0, 'clubs': 0, 'clover': 0, 'clovers': 0, 'klubs': 0,
  'diamond': 1, 'diamonds': 1, 'dimonds': 1, 'diamons': 1, 'diamante': 1,
  'heart': 2, 'hearts': 2, 'harts': 2, 'hart': 2,
  'spade': 3, 'spades': 3, 'spayed': 3, 'spaids': 3, 'spays': 3,
  '♣': 0, '♦': 1, '♥': 2, '♠': 3,
};

/// Single letters / near-misses: only a suit right after a rank.
const _weakSuits = <String, int>{
  'c': 0, 'cloves': 0, 'clove': 0, 'clump': 0, 'clumps': 0,
  'd': 1,
  'h': 2, 'hard': 2, 'hearth': 2, 'arts': 2,
  's': 3, 'spaid': 3, 'spaced': 3,
};

const _streetWords = <String, Street>{
  'flop': Street.flop, 'flops': Street.flop, 'flopped': Street.flop,
  'flap': Street.flop, 'flock': Street.flop, 'plop': Street.flop,
  'turn': Street.turn, 'turns': Street.turn, 'turned': Street.turn,
  'tern': Street.turn, 'term': Street.turn,
  'river': Street.river, 'rivers': Street.river, 'rivered': Street.river,
  'liver': Street.river, 'rivah': Street.river,
};

/// Fillers: dropped from the remainder and never break a rank/suit pair.
const _fillers = {
  'the', 'is', 'an', 'and', 'of', 'uh', 'um', 'umm', 'er', 'card', 'cards',
  'comes', 'come', 'came', 'its', 'it', 'on', 'then', 'off', 'ok', 'okay',
  'so', 'here', 'we', 'go', 'with', 'oh', 'was', 'be', 'that', 'has',
  'brings', 'gives', 'board', 'reads', 'next', 'now', 'there', 'a', 'pair',
};

const _symbols = {'♣': ' ♣ ', '♦': ' ♦ ', '♥': ' ♥ ', '♠': ' ♠ ', '♧': ' ♣ ', '♢': ' ♦ ', '♡': ' ♥ ', '♤': ' ♠ '};

/// Lower-cases, splits suit symbols off, and turns compact cards ("Kh",
/// "10s", "7♠") into "k h" style pairs. "As"/"Ah"/"Ad"/"Ac" only count as
/// ace-of when typed with a capital A (ASR writes the word "as").
List<String> _tokenize(String text) {
  var s = text;
  _symbols.forEach((k, v) => s = s.replaceAll(k, v));
  s = s.replaceAll('’', "'").replaceAll(RegExp(r"[^A-Za-z0-9'♣♦♥♠]+"), ' ');
  final out = <String>[];
  for (final raw in s.split(' ')) {
    if (raw.isEmpty) continue;
    final m = RegExp(r'^(10|[2-9TJQKAtjqka])([cdhsCDHS])$').firstMatch(raw);
    if (m != null) {
      final r = m.group(1)!;
      if (r.toLowerCase() != 'a' || r == 'A') {
        out.add(r.toLowerCase() == 'a' ? 'ace' : r.toLowerCase());
        out.add(m.group(2)!.toLowerCase());
        continue;
      }
    }
    var w = raw.toLowerCase();
    // "queen's", "it's" -> "queens", "its".
    if (w.endsWith("'s")) w = '${w.substring(0, w.length - 2)}s';
    w = w.replaceAll("'", '');
    if (w.isNotEmpty) out.add(w);
  }
  return out;
}

class _Card {
  final int card;
  final bool fuzzy;
  _Card(this.card, this.fuzzy);
}

class _Segment {
  final Street? street;
  final List<_Card> cards = [];
  _Segment(this.street);
}

/// Parses one utterance against the current [board] (cards already called
/// this hand) and [dead] cards (e.g. your hole cards).
BoardParse parseBoardSpeech(String text,
    {List<int> board = const [], Iterable<int> dead = const []}) {
  final tokens = _tokenize(text);
  final segments = <_Segment>[_Segment(null)];
  final leftover = <String>[];
  final pending = <(int, bool, String)>[]; // rank, fuzzy, word
  var fuzzyHits = 0;
  int? lastRank;
  var lastWasSuit = false;

  int? suitAt(int i, {required bool afterRank}) {
    if (i >= tokens.length) return null;
    final w = tokens[i];
    return _strongSuits[w] ?? (afterRank ? _weakSuits[w] : null);
  }

  /// Index of the suit token following a rank at [i], skipping one "of".
  int? suitIndexAfter(int i) {
    var j = i + 1;
    if (j < tokens.length && tokens[j] == 'of') j++;
    return suitAt(j, afterRank: true) == null ? null : j;
  }

  void flushPending() {
    for (final p in pending) {
      leftover.add(p.$3);
    }
    pending.clear();
  }

  var i = 0;
  while (i < tokens.length) {
    final w = tokens[i];
    final street = _streetWords[w];
    if (street != null) {
      flushPending();
      segments.add(_Segment(street));
      lastWasSuit = false;
      i++;
      continue;
    }

    // A suit: pair it with the oldest waiting rank, or reuse the last rank
    // for "seven of hearts and spades".
    final suit = suitAt(i, afterRank: pending.isNotEmpty);
    if (suit != null) {
      if (pending.isNotEmpty) {
        final (r, fz, _) = pending.removeAt(0);
        final weakSuit = !_strongSuits.containsKey(w);
        segments.last.cards.add(_Card(makeCard(r, suit), fz || weakSuit));
        if (fz || weakSuit) fuzzyHits++;
        lastRank = r;
        lastWasSuit = true;
      } else if (lastWasSuit && lastRank != null && _strongSuits.containsKey(w)) {
        segments.last.cards.add(_Card(makeCard(lastRank, suit), true));
        fuzzyHits++;
      } else {
        leftover.add(w);
        lastWasSuit = false;
      }
      i++;
      continue;
    }

    final strong = _strongRanks[w];
    if (strong != null) {
      pending.add((strong, false, w));
      lastWasSuit = false;
      i++;
      continue;
    }
    final weak = _weakRanks[w];
    if (weak != null && suitIndexAfter(i) != null) {
      pending.add((weak, true, w));
      lastWasSuit = false;
      i++;
      continue;
    }

    if (_fillers.contains(w)) {
      // "and" keeps "hearts and spades" together; other fillers end it.
      if (w != 'and') lastWasSuit = false;
      i++;
      continue;
    }
    flushPending();
    leftover.add(w);
    lastWasSuit = false;
    i++;
  }
  flushPending();

  final spoken = [for (final s in segments) if (s.cards.isNotEmpty || s.street != null) s];
  final all = [for (final s in segments) ...s.cards.map((c) => c.card)];
  final remainder = leftover.join(' ');
  Street? lastStreet;
  for (final s in segments) {
    if (s.street != null) lastStreet = s.street;
  }

  BoardParse fail(String why, {Street? street}) => BoardParse(
        street: street ?? lastStreet,
        streetSpoken: lastStreet != null,
        cards: all,
        board: List.of(board),
        confidence: 0,
        remainder: remainder,
        problem: why,
      );

  if (all.isEmpty) {
    return fail(tokens.isEmpty ? 'Nothing heard' : 'No cards heard');
  }

  // Duplicates within the utterance.
  final seen = <int>{};
  for (final c in all) {
    if (!seen.add(c)) return fail('${cardLabel(c)} was said twice');
  }

  var b = List.of(board);
  Street? applied;
  var inferred = false;
  for (final seg in spoken) {
    final cs = [for (final c in seg.cards) c.card];
    if (cs.isEmpty) continue;
    switch (seg.street) {
      case Street.flop:
        if (cs.length > 3) return fail('A flop is three cards, heard ${cs.length}');
        if (cs.length == 3) {
          b = [...cs, ...b.length > 3 ? b.sublist(3) : const <int>[]];
        } else if (b.length + cs.length <= 3) {
          b = [...b, ...cs];
        } else {
          return fail('A flop is three cards, heard ${cs.length}');
        }
        applied = Street.flop;
      case Street.turn:
      case Street.river:
        final st = seg.street!;
        final idx = st == Street.turn ? 3 : 4;
        if (cs.length != 1) {
          return fail('The ${streetNames[st]!.toLowerCase()} is one card, heard ${cs.length}');
        }
        if (b.length < idx) {
          return fail(st == Street.turn ? 'Call the flop first' : 'Call the turn first');
        }
        if (b.length == idx) {
          b = [...b, cs.first];
        } else {
          b = List.of(b)..[idx] = cs.first;
        }
        applied = st;
      case null:
        if (b.length + cs.length > 5) {
          return fail(b.length >= 5
              ? 'The board is full: say "turn …" or "river …" to correct a card'
              : 'Only ${5 - b.length} more card${5 - b.length == 1 ? '' : 's'} fit on the board');
        }
        applied = streetForLength(b.length + cs.length - 1);
        b = [...b, ...cs];
        inferred = true;
    }
  }

  // Cards already used: your hand, or board cards that are staying.
  final deadSet = dead.toSet();
  final counts = <int, int>{};
  for (final c in b) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  for (final c in all) {
    if (deadSet.contains(c)) return fail('${cardLabel(c)} is in your hand', street: applied);
    if ((counts[c] ?? 0) > 1) return fail('${cardLabel(c)} is already on the board', street: applied);
  }

  var conf = 1.0;
  for (var k = 0; k < fuzzyHits; k++) {
    conf *= 0.85;
  }
  if (inferred) conf *= 0.9;
  if (leftover.isNotEmpty) conf *= leftover.length == 1 ? 0.8 : 0.6;
  return BoardParse(
    street: applied,
    streetSpoken: !inferred,
    cards: all,
    board: b,
    confidence: conf,
    remainder: remainder,
  );
}
