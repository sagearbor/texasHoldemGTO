import 'dart:math';

import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/screens/charts_screen.dart';
import 'package:felt_notes/ui/screens/train_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cash spots are well-formed and sized sensibly', () {
    final spots = buildCashSpots();
    expect(spots.length, 34);
    expect(spots.where((s) => s.group == limperGroup), hasLength(8));
    expect(spots.where((s) => s.group == threeBetGroup), hasLength(7));
    for (final s in spots) {
      for (final row in s.strategy) {
        expect(row.length, s.actions.length);
        expect(row.fold<double>(0, (a, b) => a + b), closeTo(1, 1e-9));
        expect(row.every((f) => f >= 0), isTrue, reason: s.id);
      }
    }
    double p(String id) => spots.firstWhere((s) => s.id == id).playPercent;
    expect(p('cash-rfi-UTG'), inInclusiveRange(0.14, 0.20));
    expect(p('cash-rfi-HJ'), inInclusiveRange(0.17, 0.24));
    expect(p('cash-rfi-CO'), inInclusiveRange(0.24, 0.32));
    expect(p('cash-rfi-BTN'), inInclusiveRange(0.40, 0.52));
    expect(p('cash-BB-vs-BTN'), inInclusiveRange(0.55, 0.75));
    expect(p('cash-rfi-UTG') < p('cash-rfi-HJ'), isTrue);
  });

  group('facing limpers', () {
    final spots = buildCashSpots();
    final limp = spots.where((s) => s.group == limperGroup).toList();
    Spot byId(String id) => spots.firstWhere((s) => s.id == id);
    final aa = HandClass.parse('AA'), trash = HandClass.parse('72o');

    test('CO/BTN/SB/BB vs one and two limpers, labelled and sized', () {
      for (final n in [1, 2]) {
        for (final hero in ['CO', 'BTN', 'SB', 'BB']) {
          final s = byId('cash-limp$n-$hero');
          expect(s.solved, isFalse);
          expect(s.situation, contains('limp'));
          if (hero == 'BB') {
            expect(s.actions, [n == 1 ? 'Raise 5bb' : 'Raise 6bb', 'Check']);
          } else {
            expect(s.actions.last, 'Fold');
            expect(s.actions[1], hero == 'SB' ? 'Complete' : 'Overlimp');
            expect(s.actions[0], startsWith('Iso '));
          }
        }
      }
      expect(byId('cash-limp1-CO').actions[0], 'Iso 4bb');
      expect(byId('cash-limp2-BTN').actions[0], 'Iso 5bb');
      expect(byId('cash-limp1-CO').situation,
          'UTG limps, HJ folds. Action is on you on the CO.');
    });

    test('AA always raises; 72o never overlimps or raises', () {
      for (final s in limp) {
        expect(s.freqs(aa)[0], 1, reason: s.id);
        expect(s.freqs(trash)[0], 0, reason: s.id);
        if (s.hero != 'BB' && s.hero != 'SB') {
          expect(s.freqs(trash)[1], 0, reason: s.id);
        }
      }
    });

    test('iso range is narrower than the RFI range from the same seat', () {
      for (final s in limp.where((s) => s.hero != 'BB')) {
        final rfi = byId('cash-rfi-${s.hero}');
        var iso = 0.0;
        for (final h in allHandClasses) {
          iso += h.comboCount * s.freqs(h)[0];
        }
        expect(iso / 1326, lessThan(rfi.playPercent), reason: s.id);
        // Value-heavy: every iso hand is also opened at least sometimes.
        for (final h in allHandClasses) {
          if (s.freqs(h)[0] > 0) {
            expect(playFreq(rfi, h), greaterThan(0), reason: '${s.id} ${h.name}');
          }
        }
      }
    });

    test('two limpers: tighter iso, more overlimps', () {
      double iso(Spot s) => allHandClasses.fold(
          0.0, (a, h) => a + h.comboCount * s.freqs(h)[0]);
      double limpPct(Spot s) => allHandClasses.fold(
          0.0, (a, h) => a + h.comboCount * s.freqs(h)[1]);
      for (final hero in ['CO', 'BTN', 'SB', 'BB']) {
        final one = byId('cash-limp1-$hero'), two = byId('cash-limp2-$hero');
        expect(iso(two), lessThan(iso(one)), reason: hero);
        if (hero == 'CO' || hero == 'BTN') {
          expect(limpPct(two), greaterThan(limpPct(one)), reason: hero);
          // Small pairs and suited connectors overlimp in position.
          for (final h in ['22', '55', '76s', 'T9s']) {
            expect(two.freqs(HandClass.parse(h))[1], greaterThan(0.5),
                reason: '$hero $h');
          }
        }
      }
      // BB checks everything it does not raise.
      final bb = byId('cash-limp1-BB');
      expect(bb.passiveIndex, 1);
      expect(bb.freqs(HandClass.parse('T9s')), [0, 1]);
      expect(bb.playPercent, inInclusiveRange(0.05, 0.12));
    });
  });

  group('facing a 3-bet', () {
    final spots = buildCashSpots();
    final vs3 = spots.where((s) => s.group == threeBetGroup).toList();
    Spot byId(String id) => spots.firstWhere((s) => s.id == id);
    double cont(String id) => byId(id).continueShare;
    double abs(String id) => byId(id).playPercent;

    test('labelled, sized and approximate', () {
      expect(vs3.map((s) => s.id), [
        'cash-3b-UTG-ip',
        'cash-3b-UTG-blinds',
        'cash-3b-CO-BTN',
        'cash-3b-CO-blinds',
        'cash-3b-BTN-SB',
        'cash-3b-BTN-BB',
        'cash-3b-SB-BB',
      ]);
      for (final s in vs3) {
        expect(s.solved, isFalse);
        expect(s.format, SpotFormat.cash100);
        expect(s.situation, contains('3-bets'));
        expect(s.situation, contains('Approximate'));
        expect(s.actions.sublist(1), ['Call', 'Fold']);
        expect(s.passiveIndex, 2);
        expect(s.villain, isNotNull);
        expect(s.reach, isNotNull);
      }
      // 22bb in position, 25bb out of position.
      expect(byId('cash-3b-UTG-ip').actions[0], '4-bet 25bb');
      expect(byId('cash-3b-UTG-blinds').actions[0], '4-bet 22bb');
      expect(byId('cash-3b-CO-BTN').actions[0], '4-bet 25bb');
      expect(byId('cash-3b-BTN-BB').actions[0], '4-bet 22bb');
      expect(byId('cash-3b-SB-BB').actions[0], '4-bet 25bb');
      expect(byId('cash-3b-UTG-ip').otherVillains, ['HJ', 'CO']);
    });

    test('every continuing hand is in the opener\'s RFI range', () {
      for (final s in vs3) {
        final rfi = byId('cash-rfi-${s.hero}');
        for (final h in allHandClasses) {
          expect(s.reach![h.index], rfi.freqs(h)[0], reason: s.id);
          if (playFreq(s, h) > 0) {
            expect(rfi.freqs(h)[0], greaterThan(0), reason: '${s.id} ${h.name}');
          }
        }
      }
    });

    test('AA always 4-bets, 72o never continues, polarised 4-bets', () {
      final aa = HandClass.parse('AA'), trash = HandClass.parse('72o');
      for (final s in vs3) {
        expect(s.freqs(aa)[0], 1, reason: s.id);
        expect(s.freqs(trash), [0, 0, 1], reason: s.id);
        // Value: KK and AK; bluffs: A5s; never 4-bet middling hands.
        expect(s.freqs(HandClass.parse('KK'))[0], 1, reason: s.id);
        expect(s.freqs(HandClass.parse('AKs'))[0], greaterThan(0.5));
        expect(s.freqs(HandClass.parse('A5s'))[0], greaterThan(0), reason: s.id);
        for (final h in ['88', 'KQo', 'AJo', 'T9s', 'KJs']) {
          expect(s.freqs(HandClass.parse(h))[0], 0, reason: '${s.id} $h');
        }
        // Offsuit broadways mostly fold.
        expect(s.freqs(HandClass.parse('KJo'))[2], greaterThanOrEqualTo(0.5),
            reason: s.id);
      }
    });

    test('continue ranges: wider for later openers, tighter vs blinds', () {
      expect(abs('cash-3b-UTG-ip'), lessThan(abs('cash-3b-CO-BTN')));
      expect(abs('cash-3b-CO-BTN'), lessThan(abs('cash-3b-BTN-SB')));
      expect(cont('cash-3b-UTG-blinds'), lessThan(cont('cash-3b-UTG-ip')));
      expect(cont('cash-3b-CO-blinds'), lessThan(cont('cash-3b-CO-BTN')));
      expect(cont('cash-3b-BTN-BB'), lessThan(cont('cash-3b-BTN-SB')));
      for (final s in vs3) {
        expect(s.continueShare, inInclusiveRange(0.25, 0.5), reason: s.id);
        // A 3-bet narrows the range: continue is a fraction of the open.
        expect(s.playPercent,
            lessThan(byId('cash-rfi-${s.hero}').playPercent * 0.5));
      }
      // In position, suited connectors call; UTG OOP folds them (as
      // authored; 87s sits at a range edge, so it is shown softened).
      final c87 = HandClass.parse('87s').index;
      expect(byId('cash-3b-BTN-BB').authoredStrategy![c87][1], 1);
      expect(byId('cash-3b-BTN-BB').strategy[c87], [0, 0.75, 0.25]);
      expect(byId('cash-3b-UTG-ip').freqs(HandClass.parse('87s'))[2], 1);
    });

    test('coach notes: ace-blocker bluffs, IP vs OOP calls, offsuit folds', () {
      String all(String id, String h) =>
          coachNotes(byId(id), HandClass.parse(h), 0).join(' ');
      expect(all('cash-3b-CO-BTN', 'A5s'), contains('blocks AA and AK'));
      expect(all('cash-3b-BTN-BB', '87s'), contains('in position works'));
      expect(all('cash-3b-UTG-ip', 'JJ'), contains('out of position is harder'));
      expect(all('cash-3b-BTN-SB', 'KJo'), contains('offsuit broadways'));
      expect(all('cash-3b-UTG-ip', '72o'), contains('not in the UTG opening'));
      expect(all('cash-3b-UTG-ip', 'AA'), contains('4-bet for value'));
      expect(all('cash-3b-SB-BB', '22'), contains('hand-authored'));
      expect(all('cash-3b-SB-BB', '22'), contains('Of the hands SB opens'));
    });

    test('trainer only deals hands the opener could hold', () async {
      SharedPreferences.setMockInitialValues({});
      final lib = SpotLibrary(spots, await loadPushFoldSpots());
      for (final d in Difficulty.values) {
        final m = TrainerModel(lib, rng: Random(7));
        await m.load();
        await m.setDifficulty(d);
        m.focus('cash-3b-UTG-ip');
        for (var i = 0; i < 150; i++) {
          final x = m.current!;
          expect(x.spot.reach![x.hand.index], greaterThan(0),
              reason: '$d ${x.hand.name}');
          m.next();
        }
      }
    });

    test('6-max and All spots modes serve facing-a-3-bet spots', () async {
      SharedPreferences.setMockInitialValues({});
      final lib = SpotLibrary(spots, await loadPushFoldSpots());
      final m = TrainerModel(lib, rng: Random(3));
      await m.load();
      for (final mode in [DrillMode.cashOnly, DrillMode.mixed]) {
        m.setMode(mode);
        var seen = 0;
        for (var i = 0; i < 600; i++) {
          final x = m.current!;
          if (x.spot.group == threeBetGroup) {
            seen++;
            expect(x.spot.reach![x.hand.index], greaterThan(0));
          }
          m.next();
        }
        expect(seen, greaterThan(10), reason: '$mode');
      }
    });
  });

  testWidgets('Charts shows the Facing a 3-bet chips on a 360px phone',
      (tester) async {
    // 360px wide; tall enough that the whole chip list is built.
    tester.view.physicalSize = const Size(1080, 7200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final lib = SpotLibrary(buildCashSpots(), const []);
    await tester.pumpWidget(MaterialApp(
        theme: Felt.dark(),
        home: ChartsScreen(library: lib, onDrill: (_) {})));
    await tester.pumpAndSettle();
    expect(find.text(threeBetGroup), findsOneWidget);
    for (final label in [
      'UTG v IP',
      'UTG v blind',
      'CO v BTN',
      'CO v blind',
      'BTN v SB',
      'BTN v BB',
      'SB v BB',
    ]) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget,
          reason: label);
    }
    final chip = find.widgetWithText(ChoiceChip, 'CO v BTN');
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.text('CO vs BTN 3-bet'), findsOneWidget);
    expect(find.textContaining('Continues'), findsOneWidget);
    expect(find.text('4-bet 25bb'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a facing-a-3-bet drill renders on a 360px phone',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final m = TrainerModel(SpotLibrary(buildCashSpots(), const []));
    await tester.runAsync(m.load);
    for (final id in ['cash-3b-UTG-ip', 'cash-3b-SB-BB']) {
      m.focus(id);
      await tester.pumpWidget(MaterialApp(
          key: UniqueKey(), theme: Felt.light(), home: TrainScreen(model: m)));
      await tester.pumpAndSettle();
      expect(find.text(m.current!.spot.title), findsWidgets);
      final btn = find.widgetWithText(FilledButton, m.current!.spot.actions[0]);
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: id);
    }
  });

  test('push/fold data loads and is monotone-ish in stack', () async {
    final spots = await loadPushFoldSpots();
    expect(spots.length, 46);
    final sb10 = spots.firstWhere((s) => s.id == 'pf-sb-10');
    expect(sb10.playPercent, closeTo(0.58, 0.03));
    expect(sb10.freqs(HandClass.parse('AA'))[0], 1);
    expect(sb10.freqs(HandClass.parse('72o'))[0], 0);
  });

  test('coach notes for every hand in every spot', () async {
    final lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots());
    for (final s in lib.all) {
      for (final h in allHandClasses) {
        for (var a = 0; a < s.actions.length; a++) {
          final notes = coachNotes(s, h, a);
          expect(notes, isNotEmpty);
        }
      }
    }
  });

  test('trainer records answers and finds teachable mistakes', () async {
    SharedPreferences.setMockInitialValues({});
    final lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots());
    final m = TrainerModel(lib);
    await m.load();
    for (var i = 0; i < 200; i++) {
      final d = m.current!;
      // Always pick Fold (or Check) to generate misses.
      m.answer(d.spot.passiveIndex);
      m.next();
    }
    expect(m.history.length, 200);
    expect(m.teachable(), isNotEmpty);
    expect(m.teachable().every((a) => a.isMiss), isTrue);
    m.setMode(DrillMode.leaks);
    expect(m.current, isNotNull);
  });
}
