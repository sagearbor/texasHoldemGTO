import 'dart:convert';
import 'dart:math';

import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpotLibrary lib;
  late DateTime now;
  DateTime clock() => now;

  setUp(() {
    lib = SpotLibrary(buildCashSpots(), const []);
    now = DateTime(2026, 10, 27, 9);
    SharedPreferences.setMockInitialValues({});
  });

  Future<TrainerModel> make() async {
    final m = TrainerModel(lib, rng: Random(7), clock: clock);
    await m.load();
    return m;
  }

  final spot = buildCashSpots().firstWhere((s) => s.id == 'cash-rfi-UTG');
  final trash = HandClass.parse('72o'); // UTG folds 72o 100%.
  int raise = spot.actions.indexOf('Raise');
  int fold = spot.actions.indexOf('Fold');
  if (raise < 0) raise = 0;
  String key(HandClass h) => '${spot.id}:${h.index}';

  group('SrDeck', () {
    test('miss enters box 0 due now; hits climb with Leitner intervals', () {
      final d = SrDeck();
      final t0 = DateTime(2026, 10, 27).millisecondsSinceEpoch;
      d.review('s', 1, true, t0);
      expect(d.cards, isEmpty, reason: 'hits alone do not create cards');
      d.review('s', 1, false, t0);
      final c = d.cards['s:1']!;
      expect((c.box, c.due), (0, t0));
      var t = t0;
      final expected = [
        (1, const Duration(minutes: 10)),
        (2, const Duration(days: 1)),
        (3, const Duration(days: 3)),
        (4, const Duration(days: 7)),
        (4, const Duration(days: 21)),
        (4, const Duration(days: 21)),
      ];
      for (final (box, gap) in expected) {
        d.review('s', 1, true, t);
        expect(c.box, box);
        expect(c.due, t + gap.inMilliseconds);
        t = c.due;
      }
      d.review('s', 1, false, t);
      expect((c.box, c.due), (0, t), reason: 'a miss demotes to box 0');
    });

    test('due() sorts most overdue first and skips future cards', () {
      final d = SrDeck()
        ..review('a', 1, false, 300)
        ..review('b', 2, false, 100)
        ..review('c', 3, false, 200)
        ..review('c', 3, true, 200); // due 200 + 10 min
      expect([for (final c in d.due(1000)) c.spotId], ['b', 'a']);
      expect(d.due(50), isEmpty);
    });
  });

  group('TrainerModel spaced repetition', () {
    test('trainer answers drive the deck through the clock', () async {
      final m = await make();
      m.record(spot, trash, raise); // miss
      expect(m.deck.cards[key(trash)]!.box, 0);
      expect(m.dueCount, 1);

      m.record(spot, trash, fold); // hit -> box 1, due in 10 min
      expect(m.deck.cards[key(trash)]!.box, 1);
      expect(m.dueCount, 0);
      now = now.add(const Duration(minutes: 11));
      expect(m.dueCount, 1);
    });

    test('leaks mode serves due cards, most overdue first', () async {
      final a = HandClass.parse('72o'), b = HandClass.parse('83o');
      final m = await make();
      m.record(spot, a, raise);
      now = now.add(const Duration(minutes: 1));
      m.record(spot, b, raise);
      now = now.add(const Duration(minutes: 1));
      // Answer something unrelated so neither card is the "just answered" one.
      m.record(spot, HandClass.parse('AA'), raise);
      m.setMode(DrillMode.leaks);
      expect(m.current!.spot.id, spot.id);
      expect(m.current!.hand, a);
      m.answer(fold); // hit: a leaves the due queue
      m.next();
      expect(m.current!.hand, b);
    });

    test('a just-missed card is not served again immediately', () async {
      final m = await make();
      m.setMode(DrillMode.leaks);
      m.record(spot, trash, raise);
      m.next();
      final firstPick = m.current!;
      expect(firstPick.spot.id == spot.id && firstPick.hand == trash, isFalse);
    });

    test('falls back to edge-weighted picks when nothing is due', () async {
      final m = await make();
      m.setMode(DrillMode.leaks);
      expect(m.dueCount, 0);
      expect(m.current, isNotNull);
    });

    test('deck is rebuilt deterministically from persisted history', () async {
      final m = await make();
      m.record(spot, trash, raise);
      m.record(spot, trash, fold);
      m.record(spot, HandClass.parse('83o'), raise);
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('trainer_history_v1')!;
      SharedPreferences.setMockInitialValues({'trainer_history_v1': raw});
      final m2 = await make();
      expect(m2.deck.cards.keys.toSet(), m.deck.cards.keys.toSet());
      for (final k in m.deck.cards.keys) {
        expect(m2.deck.cards[k]!.box, m.deck.cards[k]!.box);
        expect(m2.deck.cards[k]!.due, m.deck.cards[k]!.due);
      }
      expect(jsonDecode(raw), hasLength(3));
    });

    test('home-game misses seed box-0 cards that survive a reload', () async {
      final m = await make();
      final h = HandClass.parse('K9o');
      await m.addExternalMisses([(spot.id, h.index)]);
      expect(m.deck.cards[key(h)]!.box, 0);
      expect(m.dueCount, 1);
      m.setMode(DrillMode.leaks);
      expect(m.current!.hand, h);

      final prefs = await SharedPreferences.getInstance();
      SharedPreferences.setMockInitialValues({
        'trainer_sr_seeds_v1': prefs.getString('trainer_sr_seeds_v1')!,
      });
      final m2 = await make();
      expect(m2.deck.cards[key(h)]!.box, 0);
      expect(m2.dueCount, 1);
      // A later correct trainer answer promotes the seeded card.
      now = now.add(const Duration(minutes: 1));
      m2.record(spot, h, spot.freqs(h)[raise] >= 0.5 ? raise : fold);
      expect(m2.deck.cards[key(h)]!.box, 1);
    });

    test('clearHistory empties the deck', () async {
      final m = await make();
      m.record(spot, trash, raise);
      await m.addExternalMisses([(spot.id, 5)]);
      await m.clearHistory();
      expect(m.deck.cards, isEmpty);
      expect(m.dueCount, 0);
    });
  });
}
