import 'dart:io';
import 'dart:math';

import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/river.dart';
import 'package:felt_notes/poker/evaluator.dart';
import 'package:felt_notes/ui/screens/review_sheet.dart';
import 'package:felt_notes/ui/screens/river_drill_screen.dart';
import 'package:felt_notes/ui/screens/river_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib =
      RiverLibrary.parse(File('assets/data/rivers.json').readAsStringSync());

  const facing = [
    'ipVsBet',
    'oopVsBet33',
    'oopVsBet75',
    'oopVsRaise',
    'ipVsRaise33',
    'ipVsRaise75',
  ];

  int strength(RiverBoard b, int p, int i) {
    final s = b.sides[p];
    return evaluate([s.c1[i], s.c2[i], ...b.cards]);
  }

  test('river JSON loads with a sensible number of boards', () {
    expect(lib.boards.length, greaterThanOrEqualTo(30));
    expect(File('assets/data/rivers.json').lengthSync(), lessThan(2 << 20));
    for (final b in lib.boards) {
      expect(b.cards.length, 5);
      expect(b.nodes.keys, containsAll(['root', 'ipVsCheck', ...facing]));
      expect(b.sides[0].n, greaterThan(200));
      expect(b.sides[1].n, greaterThan(200));
      // No combo shares a card with the board.
      for (final s in b.sides) {
        for (var i = 0; i < s.n; i++) {
          expect(
              b.cards.contains(s.c1[i]) || b.cards.contains(s.c2[i]), isFalse);
        }
      }
    }
  });

  test('every per-combo strategy is a probability distribution', () {
    for (final b in lib.boards) {
      for (final n in b.nodes.values) {
        final side = b.sides[n.player];
        expect(n.s.length, side.n * n.actions.length, reason: n.id);
        for (var i = 0; i < side.n; i++) {
          final f = n.freqs(i);
          expect(f.every((x) => x >= 0 && x <= 1), isTrue);
          expect(f.reduce((a, c) => a + c), closeTo(1, 1e-9));
        }
        for (final row in b.classStrategy(n)) {
          if (row == null) continue;
          expect(row.reduce((a, c) => a + c), closeTo(1, 1e-6));
        }
      }
    }
  });

  test('the nuts never fold to a bet', () {
    for (final b in lib.boards) {
      for (final id in facing) {
        final n = b.nodes[id]!;
        final side = b.sides[n.player];
        var top = -1;
        for (var i = 0; i < side.n; i++) {
          top = max(top, strength(b, n.player, i));
        }
        for (var i = 0; i < side.n; i++) {
          if (strength(b, n.player, i) != top) continue;
          expect(n.freqs(i)[n.actions.indexOf('Fold')], lessThanOrEqualTo(0.01),
              reason: '${b.boardStr} $id ${side.comboName(i)}');
        }
      }
    }
  });

  test('the worst air never calls', () {
    for (final b in lib.boards) {
      for (final id in facing) {
        final n = b.nodes[id]!;
        final side = b.sides[n.player];
        var low = 1 << 40;
        for (var i = 0; i < side.n; i++) {
          low = min(low, strength(b, n.player, i));
        }
        for (var i = 0; i < side.n; i++) {
          if (strength(b, n.player, i) != low) continue;
          // A sliver of calling is possible when the weakest hand chops
          // with identical-strength bluffs (e.g. 4-high on a 4-flush
          // board), so allow up to 3%.
          expect(n.freqs(i)[n.actions.indexOf('Call')], lessThanOrEqualTo(0.03),
              reason: '${b.boardStr} $id ${side.comboName(i)}');
        }
      }
    }
  });

  test('exploitability is reported and small', () {
    for (final b in lib.boards) {
      expect(b.exploitabilityPctPot, greaterThanOrEqualTo(0));
      expect(b.exploitabilityPctPot, lessThan(1.0), reason: b.boardStr);
    }
    expect(lib.maxExploitability, lessThan(1.0));
  });

  test('summary text and drill coaching are generated from the data', () {
    final rng = Random(7);
    for (final b in lib.boards) {
      final s = b.summary();
      expect(s, isNotEmpty);
      expect(s.first, startsWith('BB'));
    }
    for (var k = 0; k < 200; k++) {
      final q = randomRiverQuestion(lib, rng);
      expect(_reached(q.board.reach(q.node)[q.combo]), isTrue);
      final best = q.freqs.indexOf(q.freqs.reduce(max));
      expect(gradeRiver(q, best), isNot(Grade.mistake));
      final notes =
          riverCoach(q, rng.nextInt(q.node.actions.length), lib.stack);
      expect(notes.length, greaterThanOrEqualTo(2));
    }
  });

  testWidgets('river screens render and the drill grades an answer',
      (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(theme: Felt.dark(), home: RiverDrillScreen(library: lib)));
    expect(find.text('River drill'), findsOneWidget);
    await tester.tap(find.byType(FilledButton).first);
    await tester.pump();
    expect(find.byType(GradeBadge), findsOneWidget);
    expect(find.textContaining('Solver:'), findsOneWidget);

    await tester.pumpWidget(
        MaterialApp(theme: Felt.light(), home: RiverScreen(library: lib)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BTN vs check'));
    await tester.pumpAndSettle();
    expect(find.textContaining('BB checks to you'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Range summary'), 300);
    expect(find.textContaining('BTN bets'), findsWidgets);
  });

  test('pot odds templates match the bet sizes', () {
    expect(potOddsNeeded('oopVsBet75', 3), closeTo(0.75 / 2.5, 1e-9));
    expect(potOddsNeeded('ipVsBet', 3), closeTo(0.66 / 2.32, 1e-9));
    expect(potOddsNeeded('oopVsRaise', 3), closeTo((3 - 0.66) / 7, 1e-9));
    expect(potOddsNeeded('root', 3), 0);
  });
}

bool _reached(double reach) => reach > 0;
