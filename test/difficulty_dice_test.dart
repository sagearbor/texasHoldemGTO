import 'dart:math';

import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/daily.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/screens/review_sheet.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:felt_notes/ui/widgets/solver_dice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots());
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<TrainerModel> make({int seed = 3}) async {
    final m = TrainerModel(lib, rng: Random(seed),
        clock: () => DateTime(2026, 10, 27, 9));
    await m.load();
    return m;
  }

  group('difficulty', () {
    test('beginner deals only clear-cut hands', () async {
      final m = await make();
      await m.setDifficulty(Difficulty.beginner);
      var played = 0;
      for (var i = 0; i < 300; i++) {
        final d = m.current!;
        expect(edginess(d.spot, d.hand), lessThanOrEqualTo(0.05),
            reason: '${d.spot.id} ${d.hand.name}');
        expect(d.spot.freqs(d.hand).reduce(max), greaterThanOrEqualTo(0.8));
        if (playFreq(d.spot, d.hand) > 0.5) played++;
        m.next();
      }
      // Played and folded hands are dealt about equally.
      expect(played, inInclusiveRange(90, 210));
    });

    test('expert deals only borderline hands', () async {
      final m = await make();
      await m.setDifficulty(Difficulty.expert);
      for (var i = 0; i < 300; i++) {
        final d = m.current!;
        expect(edginess(d.spot, d.hand), greaterThanOrEqualTo(0.7),
            reason: '${d.spot.id} ${d.hand.name}');
        m.next();
      }
    });

    test('intermediate still mixes clear and borderline hands', () async {
      final m = await make();
      var clear = 0;
      for (var i = 0; i < 300; i++) {
        final d = m.current!;
        if (edginess(d.spot, d.hand) <= 0.05) clear++;
        m.next();
      }
      expect(clear, inInclusiveRange(30, 270));
    });

    test('persists across loads', () async {
      final m = await make();
      expect(m.difficulty, Difficulty.intermediate);
      await m.setDifficulty(Difficulty.expert);
      final again = await make();
      expect(again.difficulty, Difficulty.expert);
    });

    test('beginner grading: >= 50% is right; stored answer keeps true freq',
        () async {
      final m = await make();
      await m.setDifficulty(Difficulty.beginner);
      final spot = lib.byId('cash-limp1-CO');
      // 77 iso-raises 60% vs one limper: "mixed" normally, right for beginners.
      final h = HandClass.parse('77');
      final a = m.record(spot, h, 0);
      expect(a.freq, closeTo(0.6, 1e-9));
      expect(a.grade, Grade.mixed);
      expect(m.gradeOf(a), Grade.correct);
      expect(beginnerGradeFor(0.4), Grade.mistake);
      // Hand-authored spot: the 40% overlimp is "mixed", not a mistake.
      expect(m.gradeOf(m.record(spot, h, 1)), Grade.mixed);
      final notes = simpleCoachNotes(spot, h, 1);
      expect(notes.first, contains('Iso 4bb is the more common play'));
      expect(simpleCoachNotes(spot, HandClass.parse('72o'), 0).first,
          contains('The right play is Fold'));
      expect(notes.length, lessThanOrEqualTo(3));
    });

    test('difficulty does not touch the Daily 10 or the deck', () async {
      final m = await make();
      final date = DateTime(2026, 10, 27, 9);
      String sig() => [
            for (final d in dailySet(lib, date)) '${d.spot.id}/${d.cards}'
          ].join(' ');
      final before = sig();
      await m.setDifficulty(Difficulty.expert);
      expect(sig(), before);
      // Leitner: a miss still enters the deck and is served in leaks mode.
      final spot = lib.byId('cash-rfi-UTG');
      final trash = HandClass.parse('72o');
      m.record(spot, trash, 0);
      expect(m.deck.cards.containsKey('${spot.id}:${trash.index}'), isTrue);
    });

    test(
        'Daily 10 never uses facing-limper or facing-a-3-bet spots '
        '(stable across versions)', () {
      final noLimp = SpotLibrary([
        for (final s in lib.cash)
          if (s.group != limperGroup && s.group != threeBetGroup) s
      ], lib.pushFold);
      for (var d = 0; d < 20; d++) {
        final date = DateTime(2026, 11, 1 + d);
        final a = dailySet(lib, date), b = dailySet(noLimp, date);
        expect([for (final x in a) '${x.spot.id}/${x.cards}'],
            [for (final x in b) '${x.spot.id}/${x.cards}']);
      }
    });
  });

  group('solver dice', () {
    final spot = buildCashSpots().firstWhere((s) => s.id == 'cash-limp1-CO');
    final h77 = HandClass.parse('77'); // Iso 60%, Overlimp 40%.

    test('bands, roll mapping and template text', () {
      final f = spot.freqs(h77);
      expect(diceBands(f), [(0, 0, 60), (1, 60, 100)]);
      expect(actionForRoll(f, 0), 0);
      expect(actionForRoll(f, 59), 0);
      expect(actionForRoll(f, 60), 1);
      expect(actionForRoll(f, 99), 1);
      expect(
          diceText(spot, h77, 37),
          'This approximate chart plays this hand both ways: Iso 4bb 60%, '
          'Overlimp 40%. '
          'Rolling 37 → Iso 4bb. Either choice is fine; mixing keeps you '
          'unexploitable.');
      expect(isMixedHand(spot, h77), isTrue);
      expect(isMixedHand(spot, HandClass.parse('AA')), isFalse);
      // Three-way mix.
      expect(diceBands([0.2, 0.3, 0.5]), [(0, 0, 20), (1, 20, 50), (2, 50, 100)]);
    });

    test('trainer rolls only for mixed hands', () async {
      final m = await make(seed: 11);
      var rolled = 0;
      for (var i = 0; i < 200; i++) {
        final d = m.current!;
        m.answer(0);
        if (isMixedHand(d.spot, d.hand)) {
          expect(m.lastRoll, inInclusiveRange(0, 99));
          rolled++;
        } else {
          expect(m.lastRoll, isNull);
        }
        m.next();
        expect(m.lastRoll, isNull);
      }
      expect(rolled, greaterThan(0));
    });

    Widget wrap(Widget w) => MaterialApp(
        theme: Felt.dark(),
        home: Scaffold(body: SingleChildScrollView(child: w)));

    testWidgets('widget shows bands, marker and text', (tester) async {
      await tester.pumpWidget(
          wrap(SolverDice(spot: spot, hand: h77, roll: 37)));
      expect(find.text('Roll 37'), findsOneWidget);
      expect(find.textContaining('Rolling 37 → Iso 4bb'), findsOneWidget);
      expect(find.byKey(const ValueKey('dice-marker')), findsOneWidget);
    });

    testWidgets('CoachPanel shows dice only for mixed hands with a roll',
        (tester) async {
      await tester.pumpWidget(wrap(
          CoachPanel(spot: spot, hand: h77, chosen: 1, roll: 80, showGrid: false)));
      expect(find.byType(SolverDice), findsOneWidget);
      expect(find.textContaining('Rolling 80 → Overlimp'), findsOneWidget);

      await tester.pumpWidget(wrap(CoachPanel(
          spot: spot,
          hand: HandClass.parse('AA'),
          chosen: 0,
          roll: 80,
          showGrid: false)));
      expect(find.byType(SolverDice), findsNothing);

      await tester.pumpWidget(wrap(
          CoachPanel(spot: spot, hand: h77, chosen: 1, showGrid: false)));
      expect(find.byType(SolverDice), findsNothing);
    });
  });
}
