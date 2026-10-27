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
    expect(spots.length, 19);
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
      // Always pick Fold to generate misses.
      m.answer(d.spot.actions.indexOf('Fold'));
      m.next();
    }
    expect(m.history.length, 200);
    expect(m.teachable(), isNotEmpty);
    expect(m.teachable().every((a) => a.isMiss), isTrue);
    m.setMode(DrillMode.leaks);
    expect(m.current, isNotNull);
  });
}
