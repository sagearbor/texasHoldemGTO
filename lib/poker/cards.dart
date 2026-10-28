/// Cards are ints 0..51: rank = card ~/ 4 (0 = deuce .. 12 = ace),
/// suit = card % 4 (0 = clubs, 1 = diamonds, 2 = hearts, 3 = spades).
library;

import 'dart:math';

const rankChars = '23456789TJQKA';
const suitChars = 'cdhs';
const suitSymbols = ['♣', '♦', '♥', '♠'];

int cardRank(int card) => card ~/ 4;
int cardSuit(int card) => card % 4;
int makeCard(int rank, int suit) => rank * 4 + suit;

String cardToString(int card) =>
    '${rankChars[cardRank(card)]}${suitChars[cardSuit(card)]}';

/// Display form with a suit symbol, e.g. "A♠". Use [cardToString] for
/// clipboard / CSV exports that must stay plain ASCII.
String prettyCard(int card) => '${rankChars[cardRank(card)]}${suitSymbols[cardSuit(card)]}';

/// Display form of several cards, space-separated: "A♠ K♥".
String prettyCards(Iterable<int> cards) => cards.map(prettyCard).join(' ');

/// Parses "As", "Td", "9h". Throws [FormatException] on bad input.
int parseCard(String s) {
  if (s.length != 2) throw FormatException('Bad card: $s');
  final r = rankChars.indexOf(s[0].toUpperCase());
  final su = suitChars.indexOf(s[1].toLowerCase());
  if (r < 0 || su < 0) throw FormatException('Bad card: $s');
  return makeCard(r, su);
}

/// Parses "AsKd" or "As Kd" into a list of cards.
List<int> parseCards(String s) {
  final clean = s.replaceAll(RegExp(r'[\s,]'), '');
  if (clean.length.isOdd) throw FormatException('Bad cards: $s');
  return [
    for (var i = 0; i < clean.length; i += 2) parseCard(clean.substring(i, i + 2))
  ];
}

List<int> fullDeck() => List<int>.generate(52, (i) => i);

/// Returns [count] distinct cards from the deck excluding [dead].
List<int> dealRandom(Random rng, int count, Set<int> dead) {
  final out = <int>[];
  while (out.length < count) {
    final c = rng.nextInt(52);
    if (dead.contains(c) || out.contains(c)) continue;
    out.add(c);
  }
  return out;
}
