import 'dart:math';

import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/leak_test.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/screens/help_screen.dart';
import 'package:felt_notes/ui/screens/leak_test_screen.dart';
import 'package:felt_notes/ui/theme.dart';
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

  /// The action index GTO plays most / least for [i].
  int best(LeakTestItem i) {
    final f = i.spot.freqs(i.hand);
    var b = 0;
    for (var k = 1; k < f.length; k++) {
      if (f[k] > f[b]) b = k;
    }
    return b;
  }

  int fold(LeakTestItem i) => i.spot.passiveIndex;
  /// The most-played non-fold action (3-bet vs call matters in the BB).
  int play(LeakTestItem i) {
    final f = i.spot.freqs(i.hand);
    var b = -1;
    for (var k = 0; k < f.length; k++) {
      if (k == i.spot.passiveIndex) continue;
      if (b < 0 || f[k] > f[b]) b = k;
    }
    return b;
  }

  group('hand set', () {
    test('every family has both a play and a fold pool', () {
      for (final f in LeakFamily.values) {
        expect(leakPool(lib, f, play: true), isNotEmpty, reason: '$f play');
        expect(leakPool(lib, f, play: false), isNotEmpty, reason: '$f fold');
      }
    });

    test('10 hands, 2 per family, balanced, no duplicate hands', () {
      for (var seed = 0; seed < 50; seed++) {
        final set = leakTestSet(lib, Random(seed));
        expect(set, hasLength(leakTestLength));
        expect(set.map((i) => i.hand.index).toSet(), hasLength(10),
            reason: 'seed $seed: distinct hand classes');
        for (final f in LeakFamily.values) {
          final fam = set.where((i) => i.family == f).toList();
          expect(fam, hasLength(2), reason: '$f');
          expect(fam.where((i) => i.shouldPlay), hasLength(1));
          expect(fam.map((i) => i.spot.id), everyElement(isIn(leakFamilySpots[f]!)));
        }
        for (final i in set) {
          expect(HandClass.fromCards(i.cards[0], i.cards[1]), i.hand);
          expect(edginess(i.spot, i.hand), greaterThanOrEqualTo(0.7));
          final p = playFreq(i.spot, i.hand);
          expect(i.shouldPlay ? p >= 0.8 : p <= 0.2, isTrue);
        }
      }
    });

    test('injected Random gives variety but is reproducible', () {
      String sig(List<LeakTestItem> s) =>
          [for (final i in s) '${i.spot.id}/${i.hand.name}'].join(' ');
      expect(sig(leakTestSet(lib, Random(7))), sig(leakTestSet(lib, Random(7))));
      final sigs = {for (var s = 0; s < 10; s++) sig(leakTestSet(lib, Random(s)))};
      expect(sigs.length, greaterThan(5));
    });
  });

  group('verdict', () {
    test('perfect run: no leaks, full score, nothing to seed', () {
      final set = leakTestSet(lib, Random(1));
      final v = leakVerdict([for (final i in set) LeakTestAnswer(i, best(i))]);
      expect(v.correct, 10);
      expect(v.leaks, isEmpty);
      expect(v.misses, isEmpty);
      expect(v.sentences, hasLength(1));
    });

    test('folding everything reads as too tight', () {
      final set = leakTestSet(lib, Random(2));
      final v = leakVerdict([for (final i in set) LeakTestAnswer(i, fold(i))]);
      expect(v.correct, 5);
      expect(v.misses, hasLength(5));
      expect(v.leaks, hasLength(3));
      expect(v.leaks.every((l) => l.direction == LeakDirection.tooTight), isTrue);
      expect(v.sentences.join(' '), isNot(contains('loose')));
    });

    test('playing everything reads as too loose', () {
      final set = leakTestSet(lib, Random(3));
      final v = leakVerdict([for (final i in set) LeakTestAnswer(i, play(i))]);
      final missed = [for (final i in set) if (!i.shouldPlay) i];
      expect(v.misses, hasLength(missed.length));
      expect(v.leaks.every((l) => l.direction == LeakDirection.tooLoose), isTrue);
    });

    test('specific templates: BB too tight, BTN too tight, short jam too tight', () {
      final bb = lib.byId('cash-BB-vs-BTN');
      final btn = lib.byId('cash-rfi-BTN');
      final sb = lib.byId('pf-sb-10');
      LeakTestItem mk(LeakFamily f, Spot s) {
        final h = leakPool(lib, f, play: true).firstWhere((p) => p.$1 == s).$2;
        return LeakTestItem(f, s, h, h.combos().first, true);
      }

      final answers = [
        LeakTestAnswer(mk(LeakFamily.bbDefend, bb), bb.passiveIndex),
        LeakTestAnswer(mk(LeakFamily.lateOpen, btn), btn.passiveIndex),
        LeakTestAnswer(mk(LeakFamily.pushFold, sb), sb.passiveIndex),
      ];
      final s = leakVerdict(answers).sentences;
      expect(s, contains(startsWith('You defend too little from the big blind')));
      expect(s, contains(startsWith('You fold too often on the button')));
      expect(s, contains(startsWith('You jam too tight when short')));
    });

    test('loose BB defence and wrong-play direction', () {
      final bb = lib.byId('cash-BB-vs-BTN');
      final h = leakPool(lib, LeakFamily.bbDefend, play: false)
          .firstWhere((p) => p.$1 == bb)
          .$2;
      expect(missDirection(bb, h, bb.actions.indexOf('Call')), LeakDirection.tooLoose);
      expect(missDirection(bb, h, bb.passiveIndex), isNull);
      // A pure call hand 3-bet is a wrong play, not "too loose".
      final pureCall = allHandClasses.firstWhere((x) => bb.freqs(x)[1] >= 0.95);
      expect(missDirection(bb, pureCall, 0), LeakDirection.wrongPlay);
      expect(leakSentence(LeakFamily.bbDefend, LeakDirection.tooLoose, {'BB'}),
          startsWith('You defend too wide'));
    });

    test('leaks are ranked by count and capped at 3', () {
      final set = leakTestSet(lib, Random(4));
      // Miss every hand: one leak per (family, direction), capped at 3.
      final answers = [
        for (final i in set)
          LeakTestAnswer(i, i.shouldPlay ? fold(i) : play(i))
      ];
      final v = leakVerdict(answers);
      expect(v.correct, 0);
      expect(v.leaks, hasLength(3));
      expect(v.misses, hasLength(10));
    });
  });

  group('seeding', () {
    test('answers go into history; Drill my leaks seeds misses and switches mode',
        () async {
      final m = TrainerModel(lib, rng: Random(1));
      await m.load();
      final set = leakTestSet(lib, Random(5));
      final answers = [for (final i in set) LeakTestAnswer(i, fold(i))];
      for (final a in answers) {
        recordLeakAnswer(m, a);
      }
      expect(m.history, hasLength(10));
      final v = leakVerdict(answers);
      await drillLeaks(m, v);
      expect(m.mode, DrillMode.leaks);
      final keys = m.deck.cards.keys.toSet();
      for (final (s, h) in v.misses) {
        expect(keys, contains('$s:$h'));
      }
      expect(m.dueCount, greaterThanOrEqualTo(v.misses.length));
      // Seeds persist across a reload.
      final m2 = TrainerModel(lib);
      await m2.load();
      for (final (s, h) in v.misses) {
        expect(m2.deck.cards.keys, contains('$s:$h'));
      }
    });
  });

  group('widgets', () {
    Future<void> phone(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3; // 360 x 640 logical
      addTearDown(tester.view.reset);
    }

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Widget app(Widget home) =>
        MaterialApp(theme: Felt.light(), darkTheme: Felt.dark(),
            themeMode: ThemeMode.dark, home: home);

    testWidgets('whole flow on a 360px phone, then Drill my leaks',
        (tester) async {
      await phone(tester);
      final m = TrainerModel(lib, rng: Random(1));
      await tester.runAsync(m.load);
      await tester.pumpWidget(app(Builder(
          builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => OnboardingFlow(model: m, rng: Random(9)))),
                    child: const Text('open'),
                  ),
                ),
              ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Welcome to Felt Notes'), findsOneWidget);
      expect(find.textContaining('stays on your phone'), findsOneWidget);
      await tap(tester, find.text('Continue'));
      await tap(tester, find.widgetWithText(FilledButton, 'Take the 60-second leak test'));

      for (var i = 0; i < 10; i++) {
        expect(find.text('Hand ${i + 1} of 10'), findsOneWidget);
        // No coaching during the test.
        expect(find.textContaining('GTO'), findsNothing);
        // Always fold: whichever button is Fold.
        final foldBtn = find.widgetWithText(FilledButton, 'Fold');
        await tap(tester, foldBtn.evaluate().isNotEmpty
            ? foldBtn
            : find.byKey(const ValueKey('leak-action-1')));
      }
      expect(m.history, hasLength(10));
      expect(find.text('5 / 10'), findsOneWidget);
      expect(find.textContaining('too'), findsWidgets);
      await tap(tester, find.textContaining('Hands you missed'));
      await tester.ensureVisible(find.text('Drill my leaks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drill my leaks'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(m.mode, DrillMode.leaks);
      expect(find.text('open'), findsOneWidget, reason: 'flow closed');
      expect(tester.takeException(), isNull);
    });

    Future<void> launch(WidgetTester tester, TrainerModel m) async {
      await tester.pumpWidget(app(Builder(builder: (context) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => maybeShowWelcome(context, m));
        return const Scaffold(body: Text('home'));
      })));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    testWidgets('first launch shows the onboarding flow', (tester) async {
      await phone(tester);
      final m = TrainerModel(lib);
      await tester.runAsync(m.load);
      await launch(tester, m);
      expect(find.text('Welcome to Felt Notes'), findsOneWidget);
      await tap(tester, find.text('Skip intro'));
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('existing users (seen_welcome_v1) do not get it', (tester) async {
      SharedPreferences.setMockInitialValues({'seen_welcome_v1': true});
      await phone(tester);
      final m = TrainerModel(lib);
      await tester.runAsync(m.load);
      await launch(tester, m);
      expect(find.text('Welcome to Felt Notes'), findsNothing);
      expect(find.text('Take the 60-second leak test'), findsNothing);
    });

    testWidgets('retake from Help opens at the offer', (tester) async {
      await phone(tester);
      final m = TrainerModel(lib);
      await tester.runAsync(m.load);
      await tester.pumpWidget(app(Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => openLeakTest(context, m),
                    child: const Text('retake')),
              ))));
      await tester.tap(find.text('retake'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Felt Notes'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Take the 60-second leak test'),
          findsOneWidget);
      await tap(tester, find.text('Skip'));
      expect(find.text('retake'), findsOneWidget);
    });
  });
}
