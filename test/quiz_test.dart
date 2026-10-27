import 'dart:math';

import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/poker/equity.dart';
import 'package:felt_notes/quiz/quiz_generator.dart';
import 'package:felt_notes/ui/screens/quiz_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final spots = buildCashSpots();

  for (final dark in [false, true]) {
    testWidgets('quiz screen plays a full session on a phone (dark: $dark)',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: dark ? Felt.dark() : Felt.light(),
        home: QuizScreen(rng: Random(3), useIsolate: false),
      ));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      var answered = 0;
      for (var step = 0; step < 40; step++) {
        if (find.text('See score').evaluate().isNotEmpty) {
          await tester.ensureVisible(find.text('See score'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('See score'));
          await tester.pumpAndSettle();
          break;
        }
        final next = find.textContaining(RegExp(r'^Next (part|question)$'));
        if (next.evaluate().isNotEmpty) {
          await tester.ensureVisible(next);
          await tester.pumpAndSettle();
          await tester.tap(next);
          await tester.pumpAndSettle();
          continue;
        }
        final enabled = find.byWidgetPredicate(
            (w) => w is FilledButton && w.onPressed != null);
        expect(enabled, findsWidgets);
        await tester.ensureVisible(enabled.first);
        await tester.pumpAndSettle();
        await tester.tap(enabled.first);
        await tester.pumpAndSettle();
        answered++;
      }
      expect(answered, greaterThanOrEqualTo(10));
      expect(find.textContaining(RegExp(r'^\d+ / 10$')), findsWidgets);
      expect(
          find.text('Review mistakes').evaluate().isNotEmpty ||
              find.text('No mistakes').evaluate().isNotEmpty,
          isTrue);
      expect(tester.takeException(), isNull);
    });
  }
  Spot byId(String id) => spots.firstWhere((s) => s.id == id);

  group('pot-odds math', () {
    test('required equity = bet / (pot + 2 bet)', () {
      expect(requiredEquity(100, 50), closeTo(0.25, 1e-12));
      expect(requiredEquity(100, 100), closeTo(1 / 3, 1e-12));
      expect(requiredEquity(60, 20), closeTo(0.2, 1e-12));
      expect(requiredEquity(12, 24), closeTo(0.4, 1e-12));
      expect(requiredEquity(48, 36), closeTo(36 / 120, 1e-12));
    });

    test('mistaken formula is always larger than the correct one', () {
      for (final f in betFractions) {
        final bet = 120 * f.$1 ~/ f.$2;
        expect(mistakenEquity(120, bet), greaterThan(requiredEquity(120, bet)));
      }
    });

    test('roundTo5', () {
      expect(roundTo5(0.326), closeTo(0.35, 1e-12));
      expect(roundTo5(0.324), closeTo(0.30, 1e-12));
      expect(roundTo5(0.0), 0);
      expect(roundTo5(0.99), closeTo(1.0, 1e-12));
    });

    test('every pot × fraction gives a whole-bb bet', () {
      for (final p in potSizes) {
        for (final f in betFractions) {
          expect((p * f.$1) % f.$2, 0, reason: '$p ${f.$1}/${f.$2}');
        }
      }
    });

    test('exact equity vs range matches a direct enumeration', () {
      final hero = parseCards('AhKh');
      final board = parseCards('Qh7h2c9d');
      final range = {
        HandClass.parse('QQ').index: 1.0,
        HandClass.parse('76s').index: 0.5,
      };
      final calc = equityVsRange(hero, range, board);
      expect(calc.exact, isTrue);
      // Direct: weighted average of handsEquity over legal combos.
      var sum = 0.0, w = 0.0, n = 0;
      range.forEach((cls, wt) {
        for (final v in HandClass.byIndex(cls).combos()) {
          if ({...hero, ...board}.contains(v[0]) ||
              {...hero, ...board}.contains(v[1])) {
            continue;
          }
          sum += wt * handsEquity([hero, v], board).equity[0];
          w += wt;
          n++;
        }
      });
      expect(calc.combos, n);
      expect(calc.equity, closeTo(sum / w, 1e-12));
      // QQ: 3 combos left (Qh on board); 76s: 3 combos (7h on board).
      expect(n, 6);
    });

    test('river equity is 0, 0.5 or 1 per combo and in range', () {
      final calc = equityVsRange(parseCards('AsAd'),
          openRange(byId('cash-rfi-UTG')), parseCards('Ac7d2h9sKc'));
      expect(calc.exact, isTrue);
      expect(calc.equity, inInclusiveRange(0.9, 1.0));
    });

    test('flop equity is seeded and reproducible', () {
      final r = openRange(byId('cash-rfi-BTN'));
      final a = equityVsRange(parseCards('JdTd'), r, parseCards('9d8c2s'),
          seed: 7);
      final b = equityVsRange(parseCards('JdTd'), r, parseCards('9d8c2s'),
          seed: 7);
      expect(a.exact, isFalse);
      expect(a.equity, b.equity);
      expect(a.equity, inInclusiveRange(0.45, 0.8));
    });
  });

  group('pot-odds questions', () {
    test('parts are well-formed and verdict matches the numbers', () {
      final rng = Random(42);
      for (var i = 0; i < 25; i++) {
        final q = potOddsQuestion(rng, spots);
        expect(q.kind, QuizKind.potOdds);
        expect(q.parts.length, 2);
        expect(q.heroCards.length, 2);
        expect(q.board.length, inInclusiveRange(3, 5));
        expect({...q.heroCards, ...q.board}.length, q.board.length + 2);

        final p1 = q.parts[0];
        expect(p1.options.length, 4);
        expect(p1.options.toSet().length, 4);
        final m = RegExp(r'pot is (\d+) bb and villain bets (\d+) bb')
            .firstMatch(p1.prompt)!;
        final pot = int.parse(m[1]!), bet = int.parse(m[2]!);
        final req = requiredEquity(pot, bet);
        expect(p1.options[p1.answer], '${(req * 100).round()}%');
        final vals = [for (final o in p1.options) int.parse(o.replaceAll('%', ''))]
          ..sort();
        for (var k = 1; k < vals.length; k++) {
          expect(vals[k] - vals[k - 1], greaterThanOrEqualTo(3));
        }

        final p2 = q.parts[1];
        expect(p2.options, ['Call', 'Fold']);
        // Recompute the equity independently and check the verdict.
        final villain = RegExp(r'^(\w+) opened').firstMatch(q.situation)![1]!;
        final calc = equityVsRange(
            q.heroCards, openRange(byId('cash-rfi-$villain')), q.board,
            flopSamples: 4000, seed: 99);
        if ((calc.equity - req).abs() > 0.04) {
          expect(p2.answer, calc.equity >= req ? 0 : 1,
              reason: '${q.situation} eq ${calc.equity} req $req');
        }
        expect(p2.explanation.join(' '), contains('${(req * 100).round()}%'));
      }
    });

    test('hero hand comes from BB defend range vs that villain', () {
      final rng = Random(3);
      for (var i = 0; i < 20; i++) {
        final q = potOddsQuestion(rng, spots);
        final villain = RegExp(r'^(\w+) opened').firstMatch(q.situation)![1]!;
        final h = HandClass.fromCards(q.heroCards[0], q.heroCards[1]);
        expect(playFreq(byId('cash-BB-vs-$villain'), h), greaterThan(0));
      }
    });

    test('generation is responsive (well under 300 ms typical)', () {
      final rng = Random(5);
      final sw = Stopwatch()..start();
      final times = <int>[];
      for (var i = 0; i < 21; i++) {
        final t0 = sw.elapsedMilliseconds;
        potOddsQuestion(rng, spots);
        times.add(sw.elapsedMilliseconds - t0);
      }
      times.sort();
      // Median, not max: occasional GC / JIT pauses in the test VM spike.
      expect(times[times.length ~/ 2], lessThan(60), reason: '$times');
      expect(times.reduce((a, b) => a + b), lessThan(21 * 300),
          reason: '$times');
    });
  });

  group('range reading', () {
    test('not-in-range: answer never played, distractors >= 70%', () {
      final rng = Random(1);
      for (var i = 0; i < 60; i++) {
        final q = notInRangeQuestion(rng, spots);
        final spot = byId(q.spotId!);
        final p = q.parts.single;
        expect(p.options.length, 4);
        expect(p.options.toSet().length, 4);
        for (var k = 0; k < 4; k++) {
          final f = playFreq(spot, HandClass.parse(p.options[k]));
          if (k == p.answer) {
            expect(f, 0, reason: p.options[k]);
          } else {
            expect(f, greaterThanOrEqualTo(0.7), reason: p.options[k]);
          }
        }
        expect(q.highlight, HandClass.parse(p.options[p.answer]).index);
      }
    });

    test('frequency buckets', () {
      expect(frequencyBucket(1), 0);
      expect(frequencyBucket(0.9), 0);
      expect(frequencyBucket(0.89), 1);
      expect(frequencyBucket(0.11), 1);
      expect(frequencyBucket(0.1), 2);
      expect(frequencyBucket(0), 2);
    });

    test('frequency question answer matches the 3-bet frequency', () {
      final rng = Random(2);
      final seen = <int>{};
      for (var i = 0; i < 80; i++) {
        final q = frequencyQuestion(rng, spots);
        final spot = byId(q.spotId!);
        final p = q.parts.single;
        expect(p.options, frequencyOptions);
        final h = HandClass.byIndex(q.highlight!);
        expect(p.prompt, contains(h.name));
        expect(p.prompt, contains(spot.hero));
        expect(p.answer, frequencyBucket(spot.freqs(h)[0]));
        seen.add(p.answer);
      }
      expect(seen, {0, 1, 2});
    });

    test('width options: 4 distinct, 15 apart, contain the answer', () {
      final rng = Random(4);
      for (final c in [5, 15, 20, 35, 50, 65, 80, 95]) {
        final o = widthOptions(rng, c);
        expect(o.length, 4);
        expect(o, contains(c));
        for (var k = 1; k < 4; k++) {
          expect(o[k] - o[k - 1], 15);
        }
      }
      // Fully in-bounds when the answer allows it.
      for (var i = 0; i < 20; i++) {
        final o = widthOptions(rng, 35);
        expect(o.every((v) => v >= 5 && v <= 95), isTrue);
      }
    });

    test('range width answer is playPercent rounded to 5', () {
      final rng = Random(8);
      for (var i = 0; i < 40; i++) {
        final q = rangeWidthQuestion(rng, spots);
        final spot = byId(q.spotId!);
        final p = q.parts.single;
        final want = ((spot.playPercent * 100) / 5).round() * 5;
        expect(p.options[p.answer], '$want%');
        // The answer is the closest option to the true width.
        final truth = spot.playPercent * 100;
        final vals = [for (final o in p.options) int.parse(o.replaceAll('%', ''))];
        final closest =
            vals.reduce((a, b) => (a - truth).abs() <= (b - truth).abs() ? a : b);
        expect(closest, want);
      }
    });
  });

  group('determinism and sessions', () {
    String fingerprint(QuizQuestion q) => [
          q.kind,
          q.situation,
          q.heroCards,
          q.board,
          for (final p in q.parts) ...[p.prompt, p.options, p.answer],
        ].join('|');

    test('same seed gives identical questions', () {
      for (final k in QuizKind.values) {
        for (final seed in [1, 17, 123456]) {
          final a = generateQuestion(k, Random(seed), spots);
          final b = generateQuestion(k, Random(seed), spots);
          expect(fingerprint(a), fingerprint(b));
          expect(fingerprint(generateFromSeed([k.index, seed])),
              fingerprint(a));
        }
      }
    });

    test('different seeds vary', () {
      final fps = {
        for (var s = 0; s < 10; s++)
          fingerprint(generateQuestion(QuizKind.notInRange, Random(s), spots))
      };
      expect(fps.length, greaterThan(5));
    });

    test('session plan is deterministic and mixes kinds', () {
      final a = SessionPlan.create(Random(9), QuizFocus.mixed);
      final b = SessionPlan.create(Random(9), QuizFocus.mixed);
      expect(a.kinds, b.kinds);
      expect(a.seeds, b.seeds);
      expect(a.length, 10);
      expect(a.kinds.where((k) => k == QuizKind.potOdds).length, 3);
      expect(a.kinds.toSet().length, 4);
      final r = SessionPlan.create(Random(9), QuizFocus.ranges);
      expect(r.kinds.contains(QuizKind.potOdds), isFalse);
      final p = SessionPlan.create(Random(9), QuizFocus.potOdds);
      expect(p.kinds.every((k) => k == QuizKind.potOdds), isTrue);
    });

    test('session scoring and mistakes', () {
      final s = QuizSession(length: 3);
      final plan = SessionPlan.create(Random(11), QuizFocus.mixed, length: 3);
      for (var i = 0; i < 3; i++) {
        s.add(generateFromSeed(plan.message(i)));
      }
      expect(s.finished, isFalse);
      // Q0 all right.
      for (var p = 0; p < s.questions[0].parts.length; p++) {
        s.answer(0, p, s.questions[0].parts[p].answer);
      }
      // Q1 first part wrong.
      final q1 = s.questions[1];
      s.answer(1, 0, (q1.parts[0].answer + 1) % q1.parts[0].options.length);
      for (var p = 1; p < q1.parts.length; p++) {
        s.answer(1, p, q1.parts[p].answer);
      }
      expect(s.score, 1);
      expect(s.mistakes, [1]);
      expect(s.finished, isFalse);
      // Re-answering is ignored.
      s.answer(0, 0, 99);
      expect(s.isCorrect(0), isTrue);
      for (var p = 0; p < s.questions[2].parts.length; p++) {
        s.answer(2, p, s.questions[2].parts[p].answer);
      }
      expect(s.finished, isTrue);
      expect(s.score, 2);
    });

    test('explanations are non-empty and numeric templates are filled', () {
      final rng = Random(21);
      for (final k in QuizKind.values) {
        for (var i = 0; i < 5; i++) {
          final q = generateQuestion(k, rng, spots);
          for (final p in q.parts) {
            expect(p.explanation, isNotEmpty);
            expect(p.answer, inInclusiveRange(0, p.options.length - 1));
            for (final line in p.explanation) {
              expect(line.contains(r'$'), isFalse, reason: line);
              expect(line.contains('null'), isFalse, reason: line);
            }
          }
        }
      }
    });
  });
}
