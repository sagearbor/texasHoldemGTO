import 'dart:convert';
import 'dart:io';

import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/daily.dart';
import 'package:felt_notes/ui/screens/charts_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final data = jsonDecode(File('assets/data/rejam.json').readAsStringSync())
      as Map<String, dynamic>;
  final spots = rejamSpotsFrom(data);
  Spot bb(String p, int s) => spots.firstWhere((x) => x.id == rejamBbId(p, s));
  Spot op(String p, int s) =>
      spots.firstWhere((x) => x.id == rejamOpenerId(p, s));
  double f(Spot s, String h) => s.freqs(HandClass.parse(h))[0];

  test('30 solved short-stack spots, one BB and one opener side each', () {
    expect(spots, hasLength(rejamOpeners.length * rejamStacks.length * 2));
    expect(spots.every((s) => s.solved && s.format == SpotFormat.rejam),
        isTrue);
    expect(spots.map((s) => s.id).toSet(), hasLength(spots.length));
    for (final s in spots) {
      expect(s.edge, hasLength(169));
      for (final row in s.strategy) {
        expect(row.reduce((a, b) => a + b), closeTo(1, 1e-9));
      }
    }
    // Opener spots only deal hands from the opening chart.
    expect(op('UTG', 20).reach![HandClass.parse('72o').index], 0);
    expect(bb('UTG', 20).reach, isNull);
    expect(bb('BTN', 20).solverNote, contains('exploitable for'));
  });

  test('every spot is solved to a tiny exploitability', () {
    for (final e in (data['spots'] as Map<String, dynamic>).values) {
      expect((e as Map)['exploitabilityBb'] as num, lessThan(1e-4));
    }
  });

  test('benchmark: premiums always go in, trash never does', () {
    for (final p in rejamOpeners) {
      for (final s in rejamStacks) {
        for (final h in ['AA', 'KK', 'QQ', 'AKs', 'AKo']) {
          expect(f(bb(p, s), h), greaterThan(0.99), reason: '$p $s $h jam');
        }
        for (final h in ['AA', 'KK', 'QQ', 'AKs']) {
          expect(f(op(p, s), h), greaterThan(0.99), reason: '$p $s $h call');
        }
        for (final h in ['72o', '32o', '83o']) {
          expect(f(bb(p, s), h), lessThan(0.01), reason: '$p $s $h jam');
        }
      }
    }
  });

  test('benchmark: ranges widen vs later openers and tighten when deeper',
      () {
    for (final s in rejamStacks) {
      final w = [for (final p in ['UTG', 'HJ', 'CO', 'BTN']) bb(p, s).playPercent];
      for (var k = 1; k < w.length; k++) {
        expect(w[k], greaterThan(w[k - 1]), reason: '${s}bb $w');
      }
    }
    for (final p in rejamOpeners) {
      final jam = [for (final s in rejamStacks) bb(p, s).playPercent];
      final call = [for (final s in rejamStacks) op(p, s).continueShare];
      for (var k = 1; k < rejamStacks.length; k++) {
        // Deeper stacks risk more per steal: the jam range does not grow
        // (1 point of slack for the opener's shifting call range).
        expect(jam[k], lessThan(jam[k - 1] + 0.01), reason: '$p $jam');
        // And the opener needs a stronger hand to call off more chips.
        expect(call[k], lessThan(call[k - 1]), reason: '$p $call');
      }
    }
  });

  test('benchmark: mixed hands are indifferent, pure hands are not', () {
    for (final s in spots) {
      for (final h in allHandClasses) {
        if ((s.reach?[h.index] ?? 1) == 0) continue;
        final p = s.freqs(h)[0], e = s.edge![h.index];
        if (p > 0.02 && p < 0.98) {
          expect(e.abs(), lessThan(0.05), reason: '${s.id} ${h.name}');
        }
        if (p >= 0.999) expect(e, greaterThan(-0.01), reason: s.id);
        if (p <= 0.001) expect(e, lessThan(0.01), reason: s.id);
      }
    }
  });

  test('coaching labels the model and gives the price to call', () {
    final n = coachNotes(op('CO', 20), HandClass.parse('ATo'), 0);
    expect(n.join(' '), contains('jam-or-fold'));
    expect(n.join(' '), contains('you need'));
    final m = coachNotes(op('UTG', 20), HandClass.parse('72o'), 1);
    expect(m.join(' '), contains('not in the UTG opening range'));
  });

  test('the Daily 10 never sees the new spots', () async {
    final full = await SpotLibrary.load();
    expect(full.rejam, hasLength(spots.length));
    final base = SpotLibrary(buildCashSpots(), await loadPushFoldSpots());
    String sig(List<DailyDrill> s) =>
        [for (final d in s) '${d.spot.id}/${d.cards.join(',')}'].join(' ');
    for (var d = 0; d < 60; d++) {
      final day = DateTime(2026, 10, 27 + d);
      expect(sig(dailySet(full, day)), sig(dailySet(base, day)));
    }
  });

  testWidgets('Charts has a Short stack tab for both sides of the jam',
      (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final lib = SpotLibrary(buildCashSpots(), const [], const [], const [], spots);
    String? drilled;
    await tester.pumpWidget(MaterialApp(
        theme: Felt.dark(),
        home: ChartsScreen(library: lib, onDrill: (id) => drilled = id)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Short stack'));
    await tester.pumpAndSettle();
    expect(find.text('BB jam vs BTN open (20bb)'), findsOneWidget);
    await tester.tap(find.text('CO'));
    await tester.tap(find.text('Opener: call?'));
    await tester.tap(find.text('15bb'));
    await tester.pumpAndSettle();
    expect(find.text('CO vs BB jam (15bb)'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Drill CO vs BB'), 200);
    await tester.tap(find.textContaining('Drill CO vs BB'));
    expect(drilled, rejamOpenerId('CO', 15));
  });
}
