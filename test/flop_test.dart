import 'dart:io';
import 'dart:math';

import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/flop.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/poker/evaluator.dart';
import 'package:felt_notes/ui/screens/charts_screen.dart';
import 'package:felt_notes/ui/screens/flop_drill_screen.dart';
import 'package:felt_notes/ui/screens/flop_screen.dart';
import 'package:felt_notes/ui/screens/review_sheet.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final file = File('assets/data/flops.json');
  final lib = FlopLibrary.parse(file.readAsStringSync());

  test('flop JSON loads: ~40 flops over 8 textures, < 2 MB', () {
    expect(file.lengthSync(), lessThan(2 << 20));
    expect(lib.boards.length, greaterThanOrEqualTo(30));
    expect(lib.textures.length, 8);
    expect(lib.format, startsWith('Simplified: one street'));
    for (final b in lib.boards) {
      expect(b.cards.toSet().length, 3);
      expect(b.nodes.keys,
          containsAll(['root', 'bbVs33', 'bbVs75', 'btnVsRaise33']));
      for (final s in b.sides) {
        expect(s.n, greaterThan(300));
        for (var i = 0; i < s.n; i++) {
          expect(
              b.cards.contains(s.c1[i]) || b.cards.contains(s.c2[i]), isFalse);
        }
      }
    }
  });

  test('every strategy sums to 1, range frequencies too', () {
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
          if (row != null)
            expect(row.reduce((a, c) => a + c), closeTo(1, 1e-6));
        }
        expect(b.rangeFreqs(n).reduce((a, c) => a + c), closeTo(1, 1e-6));
      }
      final st = b.stats['btn'] as Map<String, dynamic>;
      expect(st.values.fold<double>(0, (a, v) => a + (v as num)),
          closeTo(1, 0.005));
    }
  });

  test('sets bet more than air on dry boards', () {
    for (final b in lib.boards.where((b) => b.texture.endsWith('dry'))) {
      final side = b.sides[flopBtn];
      final root = b.nodes['root']!;
      var setBet = 0.0, setW = 0.0, airBet = 0.0, airW = 0.0;
      for (var i = 0; i < side.n; i++) {
        final hole = [side.c1[i], side.c2[i]];
        final cat = handCategory(evaluate([...hole, ...b.cards]));
        final bet = 1 - root.freqs(i)[0];
        final isSet = cat == 3 && cardRank(hole[0]) == cardRank(hole[1]);
        final isAir = cat == 0 && drawName(hole, b.cards) == null;
        if (isSet) {
          setBet += side.w[i] * bet;
          setW += side.w[i];
        } else if (isAir) {
          airBet += side.w[i] * bet;
          airW += side.w[i];
        }
      }
      expect(setW, greaterThan(0), reason: b.boardStr);
      expect(setBet / setW, greaterThan(airBet / airW), reason: b.boardStr);
    }
  });

  test('exploitability is present and below 0.5% of the pot', () {
    for (final b in lib.boards) {
      expect(b.exploitabilityPctPot, greaterThanOrEqualTo(0));
      expect(b.exploitabilityPctPot, lessThan(0.5), reason: b.boardStr);
      expect(b.iterations, greaterThan(0));
    }
    expect(lib.maxExploitability, lessThan(0.5));
  });

  test('summaries, short names and drill coaching come from the data', () {
    expect(shortFlop(parseCards('As7d2c')), 'A72r');
    expect(shortFlop(parseCards('9s8s7d')), '987ss');
    expect(shortFlop(parseCards('Ah8h3h')), 'A83m');
    expect(
        drawName(parseCards('AhKh'), parseCards('9h8h5c')), 'a nut flush draw');
    expect(drawName(parseCards('JcTd'), parseCards('9h8s2c')),
        'an open-ended straight draw');
    for (final b in lib.boards) {
      expect(b.headline(), startsWith('BTN bets'));
      expect(b.summary().length, greaterThanOrEqualTo(5));
    }
    final avg = lib.textureAverages();
    expect(avg.length, 8);
    for (final v in avg.values) {
      expect(v.$1 + v.$2 + v.$3, closeTo(1, 0.01));
    }
    final rng = Random(3);
    for (var k = 0; k < 200; k++) {
      final q = randomFlopQuestion(lib, rng);
      expect(q.side.w[q.combo], greaterThan(0));
      final best = q.freqs.indexOf(q.freqs.reduce(max));
      expect(gradeFlop(q, best), isNot(Grade.mistake));
      expect(flopCoach(q, rng.nextInt(3)).length, greaterThanOrEqualTo(3));
    }
  });

  testWidgets('Charts shows the flop entry on a 360px phone', (tester) async {
    tester.view.physicalSize = const Size(1080, 7200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final spots = SpotLibrary(buildCashSpots(), const []);
    await tester.pumpWidget(MaterialApp(
        theme: Felt.dark(),
        home: ChartsScreen(library: spots, onDrill: (_) {})));
    await tester.pumpAndSettle();
    final entry = find.text('Flop c-bets (simplified)');
    expect(entry, findsOneWidget);
    expect(find.text('River spots (solved)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flop screen and drill render at 360px', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(theme: Felt.light(), home: FlopScreen(library: lib)));
    await tester.pumpAndSettle();
    expect(find.textContaining('BTN bets'), findsWidgets);
    expect(find.byType(FlopGrid), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'BB vs 33%'));
    await tester.pumpAndSettle();
    expect(find.textContaining('BTN bets 33% of the pot'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Call'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Call'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('C-bet % by texture'), 300);
    expect(find.text('Monotone'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
        MaterialApp(theme: Felt.dark(), home: FlopDrillScreen(library: lib)));
    expect(find.text('Flop c-bet drill'), findsOneWidget);
    await tester.tap(find.byType(FilledButton).first);
    await tester.pump();
    expect(find.byType(GradeBadge), findsOneWidget);
    expect(find.textContaining('Solver:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
