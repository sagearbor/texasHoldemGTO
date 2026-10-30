/// Agreeing on the board across phones. Pure Dart, no I/O.
///
/// Every propped phone reads the community cards for itself
/// (lib/camera/board_watch.dart) and logs each street it saw as a
/// `boardRead` event: partial cards ("7d", "Fr" = red face card, "9?" =
/// a nine of unknown suit) with a confidence for the rank and one for the
/// suit, on its own clock. The merge (night_merge.dart) puts those reads
/// on the organizer's clock, files them under a hand, and calls
/// [agreeBoard] with everything known about that hand's board:
///
///   * the organizer's called board (voice or typed) wins outright
///     ([BoardSource.called]): a human said it;
///   * else a one-tap fix or confirmation from any phone
///     ([BoardSource.fixed]);
///   * else the cameras vote ([BoardSource.camera]).
///
/// The camera vote is card by card, not board by board: phones on opposite
/// sides of the table see the board in opposite order, and a phone that
/// could tell the pips but not their shape still knows the rank. Reads are
/// matched into card slots by compatibility (a "red face card" matches a
/// "Kh"), each slot then votes rank, colour and suit separately, weighted
/// by the phone's confidence and by how much of the street it saw.
///
///   1 phone       its read, confidence capped at [BoardVoteOptions.soloCap]
///                 (nobody checked it).
///   2 phones      an attribute they agree on is agreed; one they disagree
///                 on is unknown and [AgreedCard.contested] unless one side
///                 is far surer ([twoPhoneMargin]).
///   3+ phones     weighted majority; below [majorityShare] of the weight
///                 the attribute is contested.
///
/// A card someone is known to hold (shared hole cards) cannot be on the
/// board: such a slot is dropped with a note. Board cards are public, so
/// the agreed board may be shown live; hole cards follow their own rules.
library;

import 'dart:math' as math;

const _rankChars = '23456789TJQKA';
const _suitChars = 'cdhs';

/// A card as far as it is known: rank and suit may be missing; a face card
/// may be known only as a face card; the colour may be all there is.
class PartialCard {
  final int? rank;
  final int? suit;
  final bool? red;
  final bool face;
  final double rankConf, suitConf;

  const PartialCard({
    this.rank,
    this.suit,
    this.red,
    this.face = false,
    this.rankConf = 1,
    this.suitConf = 1,
  });

  PartialCard.exact(int card, {double conf = 1})
      : rank = card ~/ 4,
        suit = card % 4,
        red = card % 4 == 1 || card % 4 == 2,
        face = false,
        rankConf = conf,
        suitConf = conf;

  /// "7d", "Fr" (red face), "9?" (nine, suit unknown), "??" (nothing).
  /// Rank: 2..9 T J Q K A, F = face card, ? = unknown. Suit: c d h s,
  /// r = red, b = black, ? = unknown. Null for anything else.
  static PartialCard? parse(String token, {double rankConf = 1, double suitConf = 1}) {
    if (token.length != 2) return null;
    final r = token[0], s = token[1];
    int? rank;
    var face = false;
    if (r == 'F') {
      face = true;
    } else if (r != '?') {
      rank = _rankChars.indexOf(r);
      if (rank < 0) return null;
    }
    int? suit;
    bool? red;
    if (s == 'r') {
      red = true;
    } else if (s == 'b') {
      red = false;
    } else if (s != '?') {
      suit = _suitChars.indexOf(s);
      if (suit < 0) return null;
      red = suit == 1 || suit == 2;
    }
    return PartialCard(rank: rank, suit: suit, red: red, face: face, rankConf: rankConf, suitConf: suitConf);
  }

  String get token => '${rank == null ? (face ? 'F' : '?') : _rankChars[rank!]}'
      '${suit == null ? (red == null ? '?' : (red! ? 'r' : 'b')) : _suitChars[suit!]}';

  bool get exact => rank != null && suit != null;
  int? get card => exact ? rank! * 4 + suit! : null;

  /// True when the rank is J, Q or K or a face card.
  bool get isFaceRank => face || (rank != null && rank! >= 9 && rank! <= 11);

  /// Nothing known contradicts [o].
  bool compatible(PartialCard o) => rankCompatible(o) && suitCompatible(o);

  bool rankCompatible(PartialCard o) {
    if (rank != null && o.rank != null && rank != o.rank) return false;
    if (face && o.rank != null && !o.isFaceRank) return false;
    if (o.face && rank != null && !isFaceRank) return false;
    return true;
  }

  bool suitCompatible(PartialCard o) {
    if (suit != null && o.suit != null && suit != o.suit) return false;
    return colourCompatible(o);
  }

  bool colourCompatible(PartialCard o) => red == null || o.red == null || red == o.red;

  /// Could be the same card misread in ONE attribute: the colour agrees
  /// (ink colour is the surest read) and either the rank agrees (a suit
  /// misread, "7d" vs "7h") or both suits are known and agree (a rank
  /// misread, "7d" vs "8d"). Such reads share a slot and vote; a "Kh" and
  /// a "2s" never do.
  bool sameCardLoosely(PartialCard o) =>
      colourCompatible(o) && (rankCompatible(o) || (suit != null && o.suit != null && suit == o.suit));

  /// How much two compatible cards have in common (exact rank > face rank,
  /// exact suit > colour): for matching reads to slots.
  int affinity(PartialCard o) {
    var a = 0;
    if (rank != null && rank == o.rank) a += 4;
    if ((face || o.face) && isFaceRank && o.isFaceRank) a += 2;
    if (suit != null && suit == o.suit) a += 3;
    if (red != null && red == o.red) a += 1;
    return a;
  }

  @override
  String toString() => token;
}

/// One phone's read of one street, on the organizer's clock.
class BoardObservation {
  final String deviceId;
  final int ms;
  final List<PartialCard> cards;
  const BoardObservation(this.deviceId, this.ms, this.cards);
  int get count => cards.length;
}

enum BoardSource { called, fixed, camera, none }

class AgreedCard {
  final int? rank;
  final int? suit;
  final bool? red;
  final bool face;

  /// Confidence in the rank and in the suit (0..1).
  final double rankConf, suitConf;

  /// Phones disagreed on the rank or the suit.
  final bool contested;

  /// Phones whose reads went into this card.
  final int phones;

  const AgreedCard({
    this.rank,
    this.suit,
    this.red,
    this.face = false,
    this.rankConf = 0,
    this.suitConf = 0,
    this.contested = false,
    this.phones = 0,
  });

  bool get exact => rank != null && suit != null;
  int? get card => exact ? rank! * 4 + suit! : null;
  PartialCard get partial =>
      PartialCard(rank: rank, suit: suit, red: red, face: face, rankConf: rankConf, suitConf: suitConf);
  String get token => partial.token;

  @override
  String toString() => token;
}

class AgreedBoard {
  final List<AgreedCard> cards;
  final BoardSource source;

  /// Phones that contributed camera reads (0 for called / fixed).
  final int phones;

  /// Why something is missing or doubtful, in plain words.
  final List<String> notes;

  const AgreedBoard({required this.cards, required this.source, this.phones = 0, this.notes = const []});

  static const none = AgreedBoard(cards: [], source: BoardSource.none);

  /// The board as exact cards when every card is exact, else null (the
  /// equity code needs real cards).
  List<int>? get exact => cards.isEmpty || cards.any((c) => !c.exact) ? null : [for (final c in cards) c.card!];

  /// Lowest rank confidence over the cards (1 for a human board).
  double get confidence => cards.isEmpty ? 0 : cards.map((c) => c.rankConf).reduce(math.min);

  /// A human should glance at it: a camera board with a doubtful, face-only
  /// or contested card.
  bool get needsConfirm =>
      source == BoardSource.camera && cards.any((c) => !c.exact || c.contested || c.rankConf < 0.6);

  String get tokens => cards.map((c) => c.token).join(' ');

  @override
  String toString() => '$tokens [${source.name}${phones > 0 ? ' x$phones' : ''}]';
}

class BoardVoteOptions {
  /// Confidence cap when only one phone read the board.
  final double soloCap;

  /// Two phones: the surer side wins an attribute only by this margin of
  /// weight share (0.5 + margin); otherwise it is contested.
  final double twoPhoneMargin;

  /// Three or more phones: share of weight an attribute needs.
  final double majorityShare;

  /// A read of fewer cards than the longest street weighs less: weight =
  /// [shortReadFloor] + (1 - floor) * count / longest.
  final double shortReadFloor;

  const BoardVoteOptions({this.soloCap = 0.8, this.twoPhoneMargin = 0.25, this.majorityShare = 0.6, this.shortReadFloor = 0.6});
}

/// The board of one hand from everything known about it. [called] is the
/// organizer's board (voice / typed), [fixed] a one-tap fix from any
/// phone, [holeCards] every hole card known to be in someone's hand.
AgreedBoard agreeBoard({
  List<BoardObservation> observations = const [],
  List<int>? called,
  List<int>? fixed,
  Set<int> holeCards = const {},
  BoardVoteOptions opts = const BoardVoteOptions(),
}) {
  for (final (src, human) in [(BoardSource.called, called), (BoardSource.fixed, fixed)]) {
    if (human == null || human.isEmpty) continue;
    final clash = human.where(holeCards.contains).toList();
    return AgreedBoard(
      cards: [for (final c in human) AgreedCard(rank: c ~/ 4, suit: c % 4, red: c % 4 == 1 || c % 4 == 2, rankConf: 1, suitConf: 1)],
      source: src,
      notes: [if (clash.isNotEmpty) 'Board card ${clash.map(_name).join(', ')} is also in a player\'s hand.'],
    );
  }
  if (observations.isEmpty) return AgreedBoard.none;
  return _vote(observations, holeCards, opts);
}

String _name(int c) => '${_rankChars[c ~/ 4]}${_suitChars[c % 4]}';

class _Entry {
  final String device;
  final PartialCard card;
  final double w;
  final int count;
  const _Entry(this.device, this.card, this.w, this.count);
}

class _Slot {
  final List<_Entry> entries = [];

  /// Smallest street this slot appeared in (3 flop, 4 turn, 5 river).
  int firstCount = 99;
  int order;
  _Slot(this.order);

  Set<String> get devices => {for (final e in entries) e.device};

  /// Best weight per device (one phone's many reads of a street count once).
  double get support {
    final best = <String, double>{};
    for (final e in entries) {
      best[e.device] = math.max(best[e.device] ?? 0, e.w);
    }
    return best.values.fold(0.0, (s, v) => s + v);
  }

  bool accepts(PartialCard c) => entries.every((e) => e.card.sameCardLoosely(c));
  int affinity(PartialCard c) => entries.fold(0, (m, e) => math.max(m, e.card.affinity(c)));
}

AgreedBoard _vote(List<BoardObservation> obs, Set<int> holeCards, BoardVoteOptions opts) {
  final longest = obs.map((o) => o.count).reduce(math.max);
  // Most informative first: longer streets, then exact cards, then the
  // earliest (its left-to-right order becomes the board's).
  final sorted = [...obs]..sort((a, b) {
      if (a.count != b.count) return b.count.compareTo(a.count);
      final ea = a.cards.where((c) => c.exact).length, eb = b.cards.where((c) => c.exact).length;
      if (ea != eb) return eb.compareTo(ea);
      return a.ms.compareTo(b.ms);
    });
  final slots = <_Slot>[];
  for (final o in sorted) {
    final w = opts.shortReadFloor + (1 - opts.shortReadFloor) * o.count / longest;
    final taken = <_Slot>{};
    // Most specific cards of this read first, so a "red face" does not
    // steal the slot a "Kh" wanted.
    final cards = [...o.cards]..sort((a, b) => _specificity(b).compareTo(_specificity(a)));
    for (final c in cards) {
      _Slot? best;
      var bestA = -1;
      for (final s in slots) {
        if (taken.contains(s) || !s.accepts(c)) continue;
        final a = s.affinity(c);
        if (a > bestA) {
          bestA = a;
          best = s;
        }
      }
      if (best == null) {
        best = _Slot(slots.length);
        slots.add(best);
      }
      taken.add(best);
      best.entries.add(_Entry(o.deviceId, c, w, o.count));
      best.firstCount = math.min(best.firstCount, o.count);
    }
  }
  final phones = {for (final o in obs) o.deviceId}.length;
  final notes = <String>[];
  // Keep the best-supported [longest] slots, in street order.
  final ranked = [...slots]..sort((a, b) => b.support.compareTo(a.support));
  final kept = ranked.take(longest).toList();
  // A dropped slot nearly as well supported as the weakest kept one: the
  // phones disagree about that card altogether ("Kh" vs "2s"), so it is
  // reported as unknown and contested rather than as whichever came first.
  final disputed = <_Slot>{};
  for (final d in ranked.skip(longest)) {
    final rival = kept.lastWhere((k) => d.support >= (1 - 2 * opts.twoPhoneMargin) * k.support, orElse: () => kept.first);
    if (d.support >= (1 - 2 * opts.twoPhoneMargin) * rival.support) {
      disputed.add(rival);
      notes.add('Phones disagree about a card: ${rival.entries.first.card} vs ${d.entries.first.card}.');
    }
  }
  kept.sort((a, b) => a.firstCount != b.firstCount ? a.firstCount.compareTo(b.firstCount) : a.order.compareTo(b.order));
  final out = <AgreedCard>[];
  for (final s in kept) {
    final c = disputed.contains(s) ? AgreedCard(contested: true, phones: s.devices.length) : _voteSlot(s, phones, opts);
    final card = c.card;
    if (card != null && holeCards.contains(card)) {
      notes.add('Dropped ${_name(card)}: it is in a player\'s hand.');
      continue;
    }
    out.add(c);
  }
  return AgreedBoard(cards: out, source: BoardSource.camera, phones: phones, notes: notes);
}

AgreedCard _voteSlot(_Slot s, int phones, BoardVoteOptions opts) {
  // Per device, the surest entry for each attribute.
  final rankW = <int, double>{}, suitW = <int, double>{};
  var redW = 0.0, blackW = 0.0;
  final byDev = <String, List<_Entry>>{};
  for (final e in s.entries) {
    byDev.putIfAbsent(e.device, () => []).add(e);
  }
  for (final es in byDev.values) {
    final bestRank = <int, double>{}, bestSuit = <int, double>{};
    var r = 0.0, b = 0.0;
    for (final e in es) {
      final key = e.card.face ? -1 : e.card.rank;
      if (key != null) bestRank[key] = math.max(bestRank[key] ?? 0, e.w * math.max(0.05, e.card.rankConf));
      if (e.card.suit != null) bestSuit[e.card.suit!] = math.max(bestSuit[e.card.suit!] ?? 0, e.w * math.max(0.05, e.card.suitConf));
      if (e.card.red == true) r = math.max(r, e.w);
      if (e.card.red == false) b = math.max(b, e.w);
    }
    bestRank.forEach((k, v) => rankW[k] = (rankW[k] ?? 0) + v);
    bestSuit.forEach((k, v) => suitW[k] = (suitW[k] ?? 0) + v);
    redW += r;
    blackW += b;
  }
  final n = byDev.length;
  // "Face card" beside an exact J / Q / K is a vote for that rank.
  final exactFaces = rankW.keys.where((k) => k >= 9 && k <= 11).toList();
  if (rankW.containsKey(-1) && exactFaces.length == 1) {
    rankW[exactFaces.single] = rankW[exactFaces.single]! + rankW.remove(-1)!;
  }
  final (rank, rankShare, rankContested) = _decide(rankW, n, opts);
  final (suit, suitShare, suitContested) = _decide(suitW, n, opts);
  bool? red;
  if (redW != blackW) red = redW > blackW;
  final colourContested = redW > 0 && blackW > 0 && (redW - blackW).abs() < opts.twoPhoneMargin * (redW + blackW);
  if (colourContested) red = null;
  final int? finalRank = rank == null || rank < 0 ? null : rank;
  final face = rank == -1;
  int? finalSuit = suit;
  if (suit != null && red != null && (suit == 1 || suit == 2) != red) finalSuit = null;
  final cap = n == 1 ? opts.soloCap : 1.0;
  final rankConf = finalRank == null && !face ? 0.0 : math.min(cap, rankShare * _meanConf(s, (c) => c.rankConf, finalRank, face));
  final suitConf = finalSuit == null ? 0.0 : math.min(cap, suitShare * _meanConf(s, (c) => c.suitConf, null, false, suit: finalSuit));
  return AgreedCard(
    rank: finalRank,
    suit: finalSuit,
    red: finalSuit == null ? red : (finalSuit == 1 || finalSuit == 2),
    face: face,
    rankConf: rankConf,
    suitConf: suitConf,
    contested: rankContested || suitContested || colourContested,
    phones: n,
  );
}

double _meanConf(_Slot s, double Function(PartialCard) f, int? rank, bool face, {int? suit}) {
  var sum = 0.0, k = 0;
  for (final e in s.entries) {
    final c = e.card;
    final match = suit != null ? c.suit == suit : (face ? c.isFaceRank : c.rank == rank);
    if (!match) continue;
    sum += f(c);
    k++;
  }
  return k == 0 ? 0 : sum / k;
}

/// Winner, its share of the weight, and whether that share is too thin
/// for the number of phones that voted.
(int?, double, bool) _decide(Map<int, double> w, int phones, BoardVoteOptions opts) {
  if (w.isEmpty) return (null, 0, false);
  final total = w.values.fold(0.0, (s, v) => s + v);
  int? best;
  var bw = 0.0;
  w.forEach((k, v) {
    if (v > bw) {
      bw = v;
      best = k;
    }
  });
  final share = bw / total;
  if (w.length == 1) return (best, share, false);
  if (phones <= 2) {
    if (share < 0.5 + opts.twoPhoneMargin) return (null, share, true);
    return (best, share, false);
  }
  if (share < opts.majorityShare) return (null, share, true);
  return (best, share, false);
}

/// Exact rank and suit first, then face / colour only, then nothing.
int _specificity(PartialCard c) => (c.rank != null ? 4 : (c.face ? 2 : 0)) + (c.suit != null ? 3 : (c.red != null ? 1 : 0));
