import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cash spots are well-formed and sized sensibly', () {
    final spots = buildCashSpots();
    expect(spots.length, 27);
    expect(spots.where((s) => s.group == limperGroup), hasLength(8));
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
