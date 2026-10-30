// Board consensus across phones (lib/sync/board_consensus.dart).

import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/sync/board_consensus.dart';
import 'package:flutter_test/flutter_test.dart';

/// "7d 9c Fh" -> partial cards; `:0.4` after a token sets both confidences.
List<PartialCard> cards(String s, {double conf = 0.9, double suitConf = 0.5}) => [
      for (final t in s.split(' '))
        PartialCard.parse(t.split(':').first,
            rankConf: t.contains(':') ? double.parse(t.split(':')[1]) : conf,
            suitConf: t.contains(':') ? double.parse(t.split(':')[1]) : suitConf)!
    ];

BoardObservation obs(String dev, String s, {int ms = 1000, double conf = 0.9, double suitConf = 0.5}) =>
    BoardObservation(dev, ms, cards(s, conf: conf, suitConf: suitConf));

void main() {
  group('PartialCard', () {
    test('parses and prints every token form', () {
      for (final t in ['7d', 'Fr', '9?', '??', 'Ab', 'Kh', 'F?']) {
        expect(PartialCard.parse(t)!.token, t);
      }
      expect(PartialCard.parse('7x'), isNull);
      expect(PartialCard.parse('Zd'), isNull);
      expect(PartialCard.parse('7'), isNull);
      expect(PartialCard.parse('7d')!.card, parseCard('7d'));
      expect(PartialCard.parse('7?')!.card, isNull);
      expect(PartialCard.exact(parseCard('Qs')).token, 'Qs');
    });

    test('compatibility: a red face card is a Kh but not a 7d or a Ks', () {
      final f = PartialCard.parse('Fr')!;
      expect(f.compatible(PartialCard.parse('Kh')!), isTrue);
      expect(f.compatible(PartialCard.parse('7d')!), isFalse);
      expect(f.compatible(PartialCard.parse('Ks')!), isFalse);
      expect(PartialCard.parse('9?')!.compatible(PartialCard.parse('9c')!), isTrue);
      expect(PartialCard.parse('9?')!.compatible(PartialCard.parse('8c')!), isFalse);
      expect(PartialCard.parse('??')!.compatible(PartialCard.parse('As')!), isTrue);
    });
  });

  group('agreeBoard precedence', () {
    test('nothing known', () {
      final b = agreeBoard();
      expect(b.source, BoardSource.none);
      expect(b.exact, isNull);
      expect(b.needsConfirm, isFalse);
    });

    test('the called board beats every camera', () {
      final b = agreeBoard(called: parseCards('As Kd 2c'), observations: [obs('A', '7d 9c Fh'), obs('B', '7d 9c Kh')]);
      expect(b.source, BoardSource.called);
      expect(b.exact, parseCards('As Kd 2c'));
      expect(b.confidence, 1);
      expect(b.needsConfirm, isFalse);
    });

    test('a one-tap fix beats the camera but not the caller', () {
      final b = agreeBoard(fixed: parseCards('7d 9c Kh'), observations: [obs('A', '7d 9c Fh')]);
      expect(b.source, BoardSource.fixed);
      expect(b.exact, parseCards('7d 9c Kh'));
      final c = agreeBoard(called: parseCards('As Kd 2c'), fixed: parseCards('7d 9c Kh'));
      expect(c.source, BoardSource.called);
    });

    test('a human board that clashes with a shared hole card is kept, with a note', () {
      final b = agreeBoard(called: parseCards('As Kd 2c'), holeCards: {parseCard('As')});
      expect(b.exact, parseCards('As Kd 2c'));
      expect(b.notes.single, contains('As'));
    });
  });

  group('one phone', () {
    test('its read, confidence capped, face card needs a tap', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Fh')]);
      expect(b.source, BoardSource.camera);
      expect(b.phones, 1);
      expect(b.tokens, '7d 9c Fh');
      expect(b.exact, isNull);
      expect(b.needsConfirm, isTrue);
      expect(b.cards[0].rankConf, lessThanOrEqualTo(0.8));
      expect(b.cards[2].face, isTrue);
    });

    test('an exact read is usable but still unconfirmed', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh', conf: 0.95, suitConf: 0.9)]);
      expect(b.exact, parseCards('7d 9c Kh'));
      expect(b.confidence, lessThanOrEqualTo(0.8));
      expect(b.needsConfirm, isFalse);
    });

    test('flop, turn and river reads from one phone build the street in order', () {
      final b = agreeBoard(observations: [
        obs('A', '7d 9c Kh', ms: 1000),
        obs('A', '7d 9c Kh Kd', ms: 2000),
        obs('A', '7d 9c Kh Kd 2s', ms: 3000),
      ]);
      expect(b.tokens, '7d 9c Kh Kd 2s');
      expect(b.exact, parseCards('7d 9c Kh Kd 2s'));
    });

    test('a hole card someone is known to hold is dropped', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh')], holeCards: {parseCard('Kh')});
      expect(b.tokens, '7d 9c');
      expect(b.notes.single, contains('Kh'));
    });
  });

  group('two phones', () {
    test('agreeing phones confirm each other (no solo cap)', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh', conf: 0.9, suitConf: 0.8), obs('B', '7d 9c Kh', conf: 0.9, suitConf: 0.8)]);
      expect(b.exact, parseCards('7d 9c Kh'));
      expect(b.phones, 2);
      expect(b.confidence, greaterThan(0.8));
      expect(b.cards.every((c) => !c.contested), isTrue);
    });

    test('opposite sides of the table see the board reversed: still one board', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh'), obs('B', 'Kh 9c 7d')]);
      expect(b.exact, parseCards('7d 9c Kh'));
      expect(b.phones, 2);
    });

    test('a face-only read and an exact read of the same card agree on the exact one', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Fr'), obs('B', '7d 9c Kh')]);
      expect(b.tokens, '7d 9c Kh');
      expect(b.exact, parseCards('7d 9c Kh'));
    });

    test('a disagreement with equal confidence is contested, not guessed', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh'), obs('B', '7d 9c 2s')]);
      expect(b.phones, 2);
      expect(b.exact, isNull);
      expect(b.needsConfirm, isTrue);
      // The two disagreeing reads open two slots; the weaker one is dropped
      // and the board shows the agreed cards plus one unsure card.
      expect(b.cards.length, 3);
      expect(b.cards.take(2).map((c) => c.token), ['7d', '9c']);
      expect(b.cards[2].token, '??');
      expect(b.cards[2].contested, isTrue);
      expect(b.notes.single, contains('disagree'));
    });

    test('a disagreement on the suit only leaves the rank and the colour', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh', suitConf: 0.5), obs('B', '7h 9c Kh', suitConf: 0.5)]);
      expect(b.cards[0].rank, 5);
      expect(b.cards[0].red, isTrue);
      expect(b.cards[0].suit, isNull);
      expect(b.cards[0].contested, isTrue);
      expect(b.needsConfirm, isTrue);
    });

    test('a much surer phone wins a suit disagreement, with a lower confidence', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh', suitConf: 0.9), obs('B', '7h 9c Kh', suitConf: 0.15)]);
      expect(b.cards[0].token, '7d');
      expect(b.cards[0].suitConf, lessThan(0.9));
    });

    test('the phone that saw the river adds the river to the other phone\'s turn', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh Kd'), obs('B', '7d 9c Kh Kd 2s')]);
      expect(b.tokens, '7d 9c Kh Kd 2s');
      expect(b.cards.last.phones, 1);
      expect(b.cards.first.phones, 2);
    });
  });

  group('three or more phones', () {
    test('majority outvotes one misread', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh'), obs('B', '7d 9c Kh'), obs('C', '7d 8c Kh')]);
      expect(b.exact, parseCards('7d 9c Kh'));
      expect(b.cards[1].contested, isFalse);
      expect(b.cards[1].rankConf, greaterThan(0.5));
    });

    test('three different suits for one card: contested', () {
      final b = agreeBoard(observations: [obs('A', '7d 9c Kh'), obs('B', '7d 9s Kh'), obs('C', '7d 9?:0.9 Kh')]);
      expect(b.cards[1].rank, 7);
      expect(b.cards[1].suit, isNull);
      expect(b.cards[1].contested, isTrue);
    });

    test('a phone that saw only the flop weighs less on the turn card than the ones that saw it', () {
      final b = agreeBoard(observations: [
        obs('A', '7d 9c Kh Kd'),
        obs('B', '7d 9c Kh Kd'),
        obs('C', '7d 9c Kh'),
      ]);
      expect(b.tokens, '7d 9c Kh Kd');
      expect(b.cards[3].phones, 2);
      expect(b.cards[0].phones, 3);
    });

    test('a mistaken sixth card read by one phone does not make the board', () {
      final b = agreeBoard(observations: [
        obs('A', '7d 9c Kh Kd 2s'),
        obs('B', '7d 9c Kh Kd 2s'),
        obs('C', '7d 9c Kh Kd 3s'),
      ]);
      expect(b.exact, parseCards('7d 9c Kh Kd 2s'));
      expect(b.cards[4].phones, 3);
      expect(b.cards[4].contested, isFalse);
    });
  });
}
