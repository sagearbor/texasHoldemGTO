import 'dart:io';
import 'dart:math';

import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/river.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/poker/evaluator.dart';
import 'package:felt_notes/ui/screens/review_sheet.dart';
import 'package:felt_notes/ui/screens/river_drill_screen.dart';
import 'package:felt_notes/ui/screens/river_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/river_cfr.dart' as cfr;

void main() {
  final lib = RiverLibrary.parse(File(riverAsset).readAsBytesSync());

  int strength(RiverBoard b, int p, int i) {
    final s = b.sides[p];
    return evaluate([s.c1[i], s.c2[i], ...b.cards]);
  }

  double mean(Iterable<double> l) =>
      l.fold<double>(0, (a, x) => a + x) / l.length;

  /// Nodes where the player to act faces a bet.
  Iterable<RiverNode> facingNodes(RiverBoard b) =>
      b.nodes.values.where((n) => potOddsNeeded(n.spec) > 0);

  test('river library: ~250 boards, both lines, every texture', () {
    expect(lib.boards.length, greaterThanOrEqualTo(250));
    expect(File(riverAsset).lengthSync(), lessThan(5 << 19)); // 2.5 MB
    expect(lib.presets.map((p) => p.id), ['srp', '3bp']);
    for (final p in lib.presets) {
      final textures = <String, int>{};
      for (final b in lib.boardsOf(p.id)) {
        textures[b.texture] = (textures[b.texture] ?? 0) + 1;
      }
      expect(textures.length, 6, reason: p.id);
      expect(textures.values.every((n) => n >= 12), isTrue, reason: p.id);
    }
    // Boards are distinct within a line.
    for (final p in lib.presets) {
      final keys = {
        for (final b in lib.boardsOf(p.id)) (List.of(b.cards)..sort()).join()
      };
      expect(keys.length, lib.boardsOf(p.id).length);
    }
    // More bet sizes than the first library, and the check-raise exists.
    final srp = lib.presets.first;
    expect(srp.nodes.map((n) => n.id),
        containsAll(['root', 'ipVsCheck', 'oopVsBet150', 'ipVsRaise150']));
    expect(srp.nodes.firstWhere((n) => n.id == 'ipVsCheck').actions,
        ['Check', 'Bet 33%', 'Bet 75%', 'Bet 150%']);
    for (final b in lib.boards) {
      expect(b.cards.length, 5);
      expect(b.sides[0].n, greaterThan(50));
      expect(b.sides[1].n, greaterThan(50));
      for (final s in b.sides) {
        for (var i = 0; i < s.n; i++) {
          expect(
              b.cards.contains(s.c1[i]) || b.cards.contains(s.c2[i]), isFalse);
        }
      }
    }
  });

  test('every reached per-combo strategy is a probability distribution', () {
    for (final b in lib.boards) {
      for (final n in b.nodes.values) {
        final side = b.sides[n.player];
        final r = b.reach(n);
        expect(n.s.length, side.n * n.actions.length, reason: n.id);
        for (var i = 0; i < side.n; i++) {
          final f = n.freqs(i);
          expect(f.every((x) => x >= 0 && x <= 1), isTrue);
          expect(f.reduce((a, c) => a + c), closeTo(1, 1e-9));
          expect(r[i], greaterThanOrEqualTo(0));
        }
        for (final row in b.classStrategy(n)) {
          if (row == null) continue;
          expect(row.reduce((a, c) => a + c), closeTo(1, 1e-6));
        }
      }
      expect(b.arrival['root'], closeTo(1, 1e-3));
    }
  });

  test('the nuts never fold to a bet', () {
    for (final b in lib.boards) {
      for (final n in facingNodes(b)) {
        final side = b.sides[n.player];
        final r = b.reach(n);
        var top = -1;
        for (var i = 0; i < side.n; i++) {
          top = max(top, strength(b, n.player, i));
        }
        for (var i = 0; i < side.n; i++) {
          if (r[i] <= 0 || strength(b, n.player, i) != top) continue;
          expect(n.freqs(i)[n.actions.indexOf('Fold')], lessThanOrEqualTo(0.01),
              reason: '${b.boardStr} ${n.id} ${side.comboName(i)}');
        }
      }
    }
  });

  test('a hand that beats nothing in the betting range never calls', () {
    var checked = 0;
    for (final b in lib.boards) {
      for (final n in facingNodes(b)) {
        // Below this the bet is (almost) never made, so the response does
        // not matter to the equilibrium and is not drilled.
        if (b.arrival[n.id]! < riverMinArrival) continue;
        final side = b.sides[n.player];
        final r = b.reach(n);
        final w = bettorRange(b, n)!;
        // The weakest hands are the candidates (cheap to check).
        var low = 1 << 40;
        for (var i = 0; i < side.n; i++) {
          if (r[i] > 0) low = min(low, strength(b, n.player, i));
        }
        for (var i = 0; i < side.n; i++) {
          if (r[i] <= 0 || strength(b, n.player, i) != low) continue;
          final e = comboEquityVs(b, n.player, i, w);
          if (e == null || e > 0.001) continue;
          checked++;
          expect(n.freqs(i)[n.actions.indexOf('Call')], lessThanOrEqualTo(0.02),
              reason: '${b.boardStr} ${n.id} ${side.comboName(i)}');
        }
      }
    }
    expect(checked, greaterThan(1000));
  });

  test('exploitability is recorded per board and within the old bound', () {
    for (final b in lib.boards) {
      // The first library's worst board was 0.003% of the pot.
      expect(b.exploitabilityPctPot, inInclusiveRange(0, 0.003),
          reason: b.boardStr);
      // Rounding to whole percents costs a little; it stays tiny.
      expect(b.storedExploitabilityPctPot, inInclusiveRange(0, 0.05),
          reason: b.boardStr);
      expect(b.iterations, greaterThanOrEqualTo(1000));
      expect(b.solverLine, contains('exploitable for'));
    }
    expect(lib.maxExploitability, lessThanOrEqualTo(0.003));
  });

  test('benchmark: bluff-catchers that mix are indifferent at the pot odds',
      () {
    // At equilibrium a hand that both calls and folds must have exactly the
    // equity the price demands against the betting range.
    final devs = <double>[];
    for (final b in lib.boards) {
      for (final n in facingNodes(b)) {
        if (b.arrival[n.id]! < riverMinArrival) continue;
        final need = potOddsNeeded(n.spec);
        final w = bettorRange(b, n)!;
        final r = b.reach(n);
        final call = n.actions.indexOf('Call');
        for (var i = 0; i < r.length; i++) {
          if (r[i] <= 0) continue;
          final f = n.freqs(i);
          if (f[call] < 0.15 || f[call] > 0.85 || f[0] < 0.1) continue;
          devs.add((comboEquityVs(b, n.player, i, w)! - need).abs());
        }
      }
    }
    devs.sort();
    expect(devs.length, greaterThan(10000));
    expect(mean(devs), lessThan(0.003));
    expect(devs[(devs.length * 0.95).floor()], lessThan(0.006));
  });

  test('benchmark: bluff share of each bet size matches the pot odds', () {
    // A bet of b pots offers the caller b / (1 + 2b): the betting range must
    // hold about that share of bluffs, so bigger bets carry more bluffs.
    for (final p in lib.presets) {
      final ivc = p.nodes.firstWhere((n) => n.id == 'ipVsCheck');
      final shares = <double>[];
      for (final a in ivc.actions.skip(1)) {
        final key = 'ipBet${a.replaceAll(RegExp(r'[^0-9]'), '')}';
        final size = int.parse(key.substring(5)) / 100;
        final l = [
          for (final b in lib.boardsOf(p.id))
            if (((b.stats[key] as Map)['betPct'] as num) >= 0.05)
              ((b.stats[key] as Map)['bluffPct'] as num).toDouble()
        ];
        if (l.length < 10) continue;
        final theory = size / (1 + 2 * size);
        expect(mean(l), closeTo(theory, 0.05), reason: '${p.id} $key');
        shares.add(mean(l));
      }
      expect(shares.length, greaterThanOrEqualTo(2), reason: p.id);
      for (var k = 1; k < shares.length; k++) {
        expect(shares[k], greaterThan(shares[k - 1]), reason: p.id);
      }
    }
  });

  test('benchmark: BTN\'s betting range is polarised', () {
    for (final p in lib.presets) {
      final q = List.generate(5, (_) => [0.0, 0.0]);
      final middle = <double>[];
      for (final b in lib.boardsOf(p.id)) {
        final n = b.nodes['ipVsCheck']!, root = b.nodes['root']!;
        final rr = b.reach(root);
        final checked = [
          for (var j = 0; j < rr.length; j++) rr[j] * root.freqs(j)[0]
        ];
        final side = b.sides[riverIp];
        final r = b.reach(n);
        var mid = 0.0, bet = 0.0;
        for (var i = 0; i < side.n; i++) {
          final e = comboEquityVs(b, riverIp, i, checked) ?? 0;
          final x = r[i] * (1 - n.freqs(i)[0]);
          q[min(4, (e * 5).floor())][0] += x;
          q[min(4, (e * 5).floor())][1] += r[i];
          bet += x;
          if (e > 0.35 && e < 0.65) mid += x;
        }
        if (bet > 0) middle.add(mid / bet);
      }
      final f = [for (final x in q) x[0] / x[1]];
      // Strong hands bet for value, the weakest bluff, the middle checks.
      expect(f[0], greaterThan(5 * f[2]), reason: '${p.id} $f');
      expect(f[4], greaterThan(5 * f[2]), reason: '${p.id} $f');
      expect(mean(middle), lessThan(0.05), reason: p.id);
    }
  });

  test('benchmark: air that blocks flushes bluffs more on 3-flush boards', () {
    for (final p in lib.presets) {
      var bw = 0.0, bt = 0.0, nw = 0.0, nt = 0.0;
      for (final b in lib.boardsOf(p.id)) {
        final sc = List<int>.filled(4, 0);
        for (final c in b.cards) {
          sc[cardSuit(c)]++;
        }
        final fs = sc.indexOf(sc.reduce(max));
        if (sc[fs] != 3 || b.texture != 'Flush possible') continue;
        final n = b.nodes['ipVsCheck']!;
        final side = b.sides[riverIp];
        final r = b.reach(n);
        for (var i = 0; i < side.n; i++) {
          if (side.eq[i] > 0.15) continue; // air only
          final s1 = cardSuit(side.c1[i]) == fs, s2 = cardSuit(side.c2[i]) == fs;
          if (s1 && s2) continue;
          final bet = r[i] * (1 - n.freqs(i)[0]);
          if (s1 != s2) {
            bw += bet;
            bt += r[i];
          } else {
            nw += bet;
            nt += r[i];
          }
        }
      }
      expect(bt, greaterThan(0));
      expect(bw / bt, greaterThan(nw / nt), reason: p.id);
    }
  });

  test('summary text and drill coaching are generated from the data', () {
    final rng = Random(7);
    for (final b in lib.boards) {
      final s = b.summary();
      expect(s, isNotEmpty);
      expect(s.first, startsWith('BB'));
    }
    for (var k = 0; k < 300; k++) {
      final q = randomRiverQuestion(lib, rng);
      expect(q.board.reach(q.node)[q.combo], greaterThan(0));
      expect(q.board.arrival[q.node.id], greaterThanOrEqualTo(riverMinArrival));
      final best = q.freqs.indexOf(q.freqs.reduce(max));
      expect(gradeRiver(q, best), isNot(Grade.mistake));
      final notes = riverCoach(q, rng.nextInt(q.node.actions.length));
      expect(notes.length, greaterThanOrEqualTo(2));
    }
  });

  test('drill picks lines and textures evenly, and can filter a line', () {
    final rng = Random(3);
    final counts = <String, int>{};
    const n = 6000;
    for (var k = 0; k < n; k++) {
      final b = randomRiverQuestion(lib, rng).board;
      final key = '${b.preset.id}/${b.texture}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    expect(counts.length, 12);
    for (final c in counts.values) {
      expect(c / n, closeTo(1 / 12, 0.025));
    }
    for (var k = 0; k < 50; k++) {
      expect(randomRiverQuestion(lib, rng, preset: '3bp').board.preset.id,
          '3bp');
    }
  });

  test('pot odds follow the node\'s bet sizes', () {
    RiverNodeSpec spec(String id) =>
        lib.presets.first.nodes.firstWhere((n) => n.id == id);
    expect(potOddsNeeded(spec('oopVsBet75')), closeTo(0.75 / 2.5, 1e-9));
    expect(potOddsNeeded(spec('oopVsBet150')), closeTo(1.5 / 4, 1e-9));
    expect(potOddsNeeded(spec('ipVsBet33')), closeTo(0.33 / 1.66, 1e-9));
    expect(potOddsNeeded(spec('oopVsRaise33')), closeTo((3 - 0.33) / 7, 1e-9));
    expect(potOddsNeeded(spec('root')), 0);
    expect(spec('ipVsRaise75').src, ('oopVsBet75', 2));
    expect(spec('ipVsCheck').resp[3], 'oopVsBet150');
  });

  test('solver benchmark: clairvoyance toy game matches the analytic answer',
      () {
    // IP holds the nuts or air (equally often), OOP a single bluff-catcher
    // and can only check. Theory for a bet of b pots: IP bets every nut and
    // bluffs b / (1 + b) of its air; OOP calls 1 / (1 + b).
    for (final b in [0.33, 0.75, 1.5]) {
      final o = cfr.Side(), i = cfr.Side();
      void add(cfr.Side s, int c1, int c2) {
        s.c1.add(c1);
        s.c2.add(c2);
        s.cls.add(0);
        s.w.add(1);
      }

      add(o, 40, 41);
      add(i, 0, 1); // nuts
      add(i, 2, 3); // air
      o.finish([2]);
      i.finish([3, 1]);
      cfr.linkSides(o, i);
      final root = cfr.buildTree(
          cfr.TreeSpec(stack: 10, leads: [], ipBets: [b], raises: false));
      final g = cfr.Game([o, i], root)..init();
      g.solve(maxIters: 20000, minIters: 1000, target: 1e-3);
      expect(g.exploitability() * 100, lessThan(0.01));
      final ivc = root.children[0];
      final bet = g.average(ivc)[1];
      expect(bet[0], closeTo(1, 1e-3), reason: 'nuts always bet');
      expect(bet[1], closeTo(b / (1 + b), 0.01), reason: 'bluff frequency');
      final call = g.average(ivc.children[1])[1];
      expect(call[0], closeTo(1 / (1 + b), 0.01), reason: 'calling frequency');
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
    expect(find.text('3-bet pot'), findsOneWidget);
    await tester.tap(find.byType(FilledButton).first);
    await tester.pump();
    expect(find.byType(GradeBadge), findsOneWidget);
    expect(find.textContaining('Solver:'), findsOneWidget);
    expect(find.textContaining('exploitable for'), findsOneWidget);

    await tester.pumpWidget(
        MaterialApp(theme: Felt.light(), home: RiverScreen(library: lib)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BTN vs check'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('BB checks to you'), 200);
    expect(find.textContaining('BB checks to you'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('3-bet pot ('), -200);
    await tester.tap(find.textContaining('3-bet pot ('));
    await tester.pumpAndSettle();
    expect(find.textContaining('BB 3-bet'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Range summary'), 300);
    expect(find.textContaining('BTN bets'), findsWidgets);
    expect(find.textContaining('exploitable for'), findsOneWidget);
  });
}
