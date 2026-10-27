import 'dart:math';

import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/range_parser.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/poker/equity.dart';
import 'package:felt_notes/poker/evaluator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('evaluator', () {
    int cat(String s) => handCategory(evaluateString(s));

    test('categories', () {
      expect(cat('AsKsQsJsTs2d3c'), 8);
      expect(cat('As2s3s4s5s9d9c'), 8); // steel wheel
      expect(cat('AsAdAhAc2d'), 7);
      expect(cat('KsKdKh2c2d'), 6);
      expect(cat('2s7s9sJsQs'), 5);
      expect(cat('As2d3h4c5s'), 4); // wheel
      expect(cat('Ts9d8h7c6s'), 4);
      expect(cat('QsQdQh2c7d'), 3);
      expect(cat('QsQd7h7c2d'), 2);
      expect(cat('QsQd7h8c2d'), 1);
      expect(cat('As9d7h8c2d'), 0);
    });

    test('ordering and kickers', () {
      expect(evaluateString('AsAd' 'KhQc2d'), greaterThan(evaluateString('AsAd' 'KhJc2d')));
      expect(evaluateString('6s5s4s3s2s'), greaterThan(evaluateString('5s4s3s2sAs')));
      expect(evaluateString('Ts9d8h7c6s'), greaterThan(evaluateString('As2d3h4c5s')));
      // Two trips make a full house with the higher trips.
      expect(handCategory(evaluateString('KsKdKh2c2d2h9s')), 6);
      expect(evaluateString('AhKd' 'QsJsTs2c3c'),
          equals(evaluateString('AcKs' 'QsJsTs2c3c')));
    });
  });

  group('hand classes', () {
    test('grid layout', () {
      expect(HandClass.byIndex(0).name, 'AA');
      expect(HandClass.byIndex(1).name, 'AKs');
      expect(HandClass.byIndex(13).name, 'AKo');
      expect(HandClass.byIndex(168).name, '22');
      expect(HandClass.parse('T9s').combos().length, 4);
      expect(HandClass.parse('T9o').combos().length, 12);
      expect(HandClass.parse('77').combos().length, 6);
      expect(HandClass.fromCards(parseCard('9h'), parseCard('Th')).name, 'T9s');
      expect(HandClass.fromCards(parseCard('9h'), parseCard('Td')).name, 'T9o');
      final total = allHandClasses.fold<int>(0, (a, h) => a + h.comboCount);
      expect(total, 1326);
    });
  });

  group('range parser', () {
    test('expansions', () {
      expect(parseRange('22+').length, 13);
      expect(parseRange('A2s+').length, 12);
      expect(parseRange('K9s+').length, 4); // K9s KTs KJs KQs
      expect(parseRange('A5s-A2s').length, 4);
      expect(parseRange('99-66').length, 4);
      expect(parseRange('AK').length, 2);
      final r = parseRange('A2s+, A3s:0.5');
      expect(r[HandClass.parse('A3s').index], 0.5);
      expect(rangePercent(parseRange('22+, A2s+, K2s+, Q2s+, J2s+, T2s+, 92s+, 82s+, 72s+, 62s+, 52s+, 42s+, 32s, A2o+, K2o+, Q2o+, J2o+, T2o+, 92o+, 82o+, 72o+, 62o+, 52o+, 42o+, 32o')),
          closeTo(1.0, 1e-9));
    });
  });

  group('equity', () {
    test('AA vs KK preflop ~82%', () {
      final r = handsEquity([parseCards('AsAh'), parseCards('KsKh')], [],
          samples: 40000, rng: Random(1));
      expect(r.equity[0], closeTo(0.82, 0.015));
    });
    test('exact on turn', () {
      final r = handsEquity(
          [parseCards('AsAh'), parseCards('KsKh')], parseCards('2c7d9cKd'));
      // AA needs an ace (2 outs) of 44.
      expect(r.equity[0], closeTo(2 / 44, 1e-9));
      expect(r.samples, 44);
    });
    test('hand vs range', () {
      final eq = handVsRangeEquity(
          parseCards('AsAh'), parseRange('22+, AK'), [],
          samples: 20000, rng: Random(2));
      expect(eq, inInclusiveRange(0.78, 0.88));
    });
  });
}
