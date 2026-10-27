/// "Draw for the button": one card to each seat, high card deals first.
library;

import 'dart:math';

class ButtonDraw {
  /// One distinct card per seat, in seat order.
  final List<int> cards;

  /// Seat that won the draw.
  final int winner;
  ButtonDraw(this.cards, this.winner);
}

/// Higher rank wins; equal ranks are broken by suit, spades > hearts >
/// diamonds > clubs. With cards encoded as rank * 4 + suit (clubs 0 ..
/// spades 3) that is simply the larger number.
int compareDraw(int a, int b) => a.compareTo(b);

/// Winning seat for already-dealt [cards].
int drawWinner(List<int> cards) {
  var w = 0;
  for (var i = 1; i < cards.length; i++) {
    if (compareDraw(cards[i], cards[w]) > 0) w = i;
  }
  return w;
}

ButtonDraw drawForButton(int seats, Random rng) {
  assert(seats >= 1 && seats <= 52);
  final deck = List<int>.generate(52, (i) => i)..shuffle(rng);
  final cards = deck.sublist(0, seats);
  return ButtonDraw(cards, drawWinner(cards));
}
