import 'dart:math';

import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/learn/glossary.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/trainer/daily.dart';
import 'package:felt_notes/trainer/mistakes.dart';
import 'package:felt_notes/trainer/progress.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/chart_prefs.dart';
import 'package:felt_notes/ui/screens/charts_screen.dart';
import 'package:felt_notes/ui/screens/glossary_screen.dart';
import 'package:felt_notes/ui/screens/progress_screen.dart';
import 'package:felt_notes/ui/screens/train_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:felt_notes/ui/widgets/range_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const day = Duration(days: 1);
  final now = DateTime(2026, 10, 27, 9); // a Tuesday
  final nowMs = now.millisecondsSinceEpoch;
  int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;
  int hand(String name) => HandClass.parse(name).index;

  // A hit has freq 1, a miss freq 0 (isMiss is freq < 0.25).
  Answer hit(String spot, String h, int ts) => Answer(spot, hand(h), 0, 1, ts);
  Answer miss(String spot, String h, int ts) => Answer(spot, hand(h), 0, 0, ts);

  late SpotLibrary lib;
  setUp(() {
    lib = SpotLibrary(buildCashSpots(), const []);
    SharedPreferences.setMockInitialValues({});
    ChartPrefs.colorBlind.value = false;
  });

  group('recency weighting', () {
    test('halves every 14 days; future answers count as now', () {
      expect(recencyWeight(nowMs, nowMs), 1);
      expect(recencyWeight(ago(const Duration(days: 14)), nowMs), closeTo(0.5, 1e-9));
      expect(recencyWeight(ago(const Duration(days: 28)), nowMs), closeTo(0.25, 1e-9));
      expect(recencyWeight(ago(const Duration(days: 7)), nowMs), closeTo(sqrt1_2, 1e-9));
      expect(recencyWeight(nowMs + 1000, nowMs), 1);
    });

    test('a recent miss outweighs an old hit', () {
      final s = cellScores([
        hit('cash-rfi-UTG', 'A9s', ago(const Duration(days: 28))),
        miss('cash-rfi-UTG', 'A9s', nowMs),
      ], {'cash-rfi-UTG'}, nowMs);
      final c = s[hand('A9s')]!;
      expect(c.attempts, 2);
      expect(c.accuracy, closeTo(0.25 / 1.25, 1e-9));
      expect(mistakeBand(c.accuracy), MistakeBand.leak);
    });
  });

  group('heatmap cell mapping', () {
    final history = [
      hit('cash-rfi-UTG', 'AKs', nowMs),
      hit('cash-rfi-UTG', 'AKs', nowMs),
      miss('cash-rfi-UTG', 'KJo', nowMs),
      miss('cash-rfi-HJ', 'KJo', nowMs),
      hit('cash-rfi-HJ', 'KJo', nowMs),
      miss('pf-sb-10', '72o', nowMs),
    ];

    test('one spot: only its answers, each on its own hand class', () {
      final s = cellScores(history, {'cash-rfi-UTG'}, nowMs);
      expect(s.keys.toSet(), {hand('AKs'), hand('KJo')});
      expect(s[hand('AKs')]!.accuracy, 1);
      expect(s[hand('AKs')]!.attempts, 2);
      expect(s[hand('KJo')]!.accuracy, 0);
      expect(s[hand('72o')], isNull, reason: 'never drilled -> neutral');
      // Suited above the diagonal, offsuit below.
      final aks = HandClass.byIndex(hand('AKs')), kjo = HandClass.byIndex(hand('KJo'));
      expect(aks.row < aks.col, isTrue);
      expect(kjo.row > kjo.col, isTrue);
    });

    test('group aggregate pools every spot in the group', () {
      final ids = {for (final x in lib.all) if (x.group == 'Open (RFI)') x.id};
      final s = cellScores(history, ids, nowMs);
      expect(s[hand('KJo')]!.attempts, 3);
      expect(s[hand('KJo')]!.accuracy, closeTo(1 / 3, 1e-9));
      expect(s[hand('72o')], isNull, reason: 'push/fold is another group');
    });

    test('bands and colour-blind patterns', () {
      expect(mistakeBand(0.49), MistakeBand.leak);
      expect(mistakeBand(0.5), MistakeBand.shaky);
      expect(mistakeBand(0.8), MistakeBand.solid);
      expect(mistakePattern(MistakeBand.leak), ActionKind.aggressive);
      expect(mistakePattern(MistakeBand.shaky), ActionKind.call);
      expect(mistakePattern(MistakeBand.solid), ActionKind.fold);
      expect(mistakeColor(0, colorBlind: true), cbAggressive);
      expect(mistakeColor(1, colorBlind: true), cbCall);
      expect(mistakeColor(0), Felt.bad);
      expect(mistakeColor(1), Felt.good);
    });

    test('weak targets: below 80%, worst first, deterministic', () {
      final t = weakTargets([
        ...history,
        hit('cash-rfi-UTG', 'QJs', nowMs),
        miss('cash-rfi-UTG', 'QJs', ago(const Duration(days: 30))),
        miss('cash-rfi-UTG', 'T9s', ago(const Duration(days: 60))),
      ], {'cash-rfi-UTG', 'cash-rfi-HJ'}, nowMs);
      // KJo in UTG (0%, fresh) and T9s (0%, stale) are the worst; the fresh
      // one wins the tie. HJ KJo is 50%. AKs (100%) and QJs (~81%) are fine.
      expect(t, [
        ('cash-rfi-UTG', hand('KJo')),
        ('cash-rfi-UTG', hand('T9s')),
        ('cash-rfi-HJ', hand('KJo')),
      ]);
    });
  });

  group('weak-hand drill', () {
    Future<TrainerModel> make() async {
      final m = TrainerModel(lib, rng: Random(3), clock: () => now);
      await m.load();
      return m;
    }

    test('deals mostly the weak cells, worst most often', () async {
      final m = await make();
      final targets = [
        ('cash-rfi-UTG', hand('KJo')),
        ('cash-rfi-UTG', hand('A8s')),
        ('cash-rfi-HJ', hand('K8s')),
      ];
      m.drillWeakHands('cash-rfi-UTG', targets);
      expect(m.focusSpotId, 'cash-rfi-UTG');
      final counts = <(String, int), int>{};
      const n = 600;
      for (var i = 0; i < n; i++) {
        final d = m.current!;
        final k = (d.spot.id, d.hand.index);
        counts[k] = (counts[k] ?? 0) + 1;
        m.answer(0);
        m.next();
      }
      final weak = targets.fold<int>(0, (a, t) => a + (counts[t] ?? 0));
      expect(weak / n, greaterThan(0.65));
      expect(counts[targets[0]]!, greaterThan(counts[targets[2]]!));
      // The other quarter stays in the focus spot.
      expect(counts.keys.every((k) => k.$1 == 'cash-rfi-UTG' || k.$1 == 'cash-rfi-HJ'), isTrue);
    });

    test('focus / mode changes end it; missing spots are dropped', () async {
      final m = await make();
      m.drillWeakHands('cash-rfi-UTG', [('gone', 3), ('cash-rfi-UTG', 5)]);
      expect(m.weakTargets, [('cash-rfi-UTG', 5)]);
      m.focus('cash-rfi-HJ');
      expect(m.weakTargets, isEmpty);
      m.drillWeakHands('cash-rfi-UTG', [('cash-rfi-UTG', 5)]);
      m.setMode(DrillMode.cashOnly);
      expect(m.weakTargets, isEmpty);
      expect(m.focusSpotId, isNull);
    });

    test('Daily 10 set is unchanged by a weak drill', () async {
      final full = SpotLibrary(buildCashSpots(), await loadPushFoldSpots());
      final m = TrainerModel(full, rng: Random(3), clock: () => now);
      await m.load();
      String ids(List<DailyDrill> l) =>
          l.map((d) => '${d.spot.id}:${d.cards.join(',')}').join(' ');
      final before = ids(dailySet(full, now));
      m.drillWeakHands('cash-rfi-UTG', [('cash-rfi-UTG', hand('KJo'))]);
      for (var i = 0; i < 20; i++) {
        m.answer(1);
        m.next();
      }
      expect(ids(m.daily.drills), before);
    });
  });

  group('glossary', () {
    test('size, unique headwords, short definitions', () {
      expect(glossary.length, greaterThanOrEqualTo(60));
      expect(glossary.map((e) => e.term).toSet().length, glossary.length);
      // Names are unique ignoring case, except the deliberate bb / BB pair.
      final names = <String>{};
      for (final e in glossary) {
        expect(e.definition.length, lessThan(240), reason: e.term);
        for (final n in e.names) {
          if (n == 'bb') continue;
          expect(names.add(n), isTrue, reason: 'duplicate name "$n" (${e.term})');
        }
      }
      expect(lookupTerm('bb')!.category, GlossaryCategory.stacks);
      expect(lookupTerm('BB')!.category, GlossaryCategory.positions);
      expect(searchGlossary('bb').first.term, 'bb');
    });

    test('covers every requested term', () {
      for (final q in [
        'UTG', 'UTG+1', 'LJ', 'HJ', 'CO', 'BTN', 'SB', 'BB', 'early position',
        'late position', 'open', 'limp', 'complete', 'iso', 'isolate', '3-bet',
        '4-bet', 'squeeze', 'jam', 'shove', 'call', 'fold', 'check', 'c-bet',
        'donk', 'overbet', 'all-in', 'bb', '5bb', 'effective stack', 'push/fold',
        'VPIP', 'PFR', '3-bet %', 'AF', 'WTSD', 'fold to c-bet', 'GTO', 'range',
        'equity', 'pot odds', 'EV', 'exploitability', 'Nash', 'solver', 'blocker',
        'suited', 'offsuit', 'broadway', 'suited connector', 'dry board',
        'wet board', 'nut', 'cooler', 'bad beat', 'suckout', 'Daily 10',
        'card luck', 'Golden Arm', 'Dealer of Doom', 'solver dice',
        'spaced repetition',
      ]) {
        expect(lookupTerm(q), isNotNull, reason: q);
      }
    });

    test('search ranks exact names, then prefixes, then definitions', () {
      expect(searchGlossary('vpip').first.term, 'VPIP');
      expect(searchGlossary('  Shove ').first.term, 'Jam');
      expect(searchGlossary('UTG').first.term, 'UTG');
      expect(searchGlossary('UTG')[1].term, 'UTG+1');
      expect(searchGlossary('cutoff').first.term, 'CO');
      // Only in definitions: "squeezed".
      expect(searchGlossary('squeezed').map((e) => e.term), contains('Squeeze'));
      expect(searchGlossary(''), hasLength(glossary.length));
      expect(searchGlossary('zzzz'), isEmpty);
      // A single letter matches whole names only, not every definition.
      expect(searchGlossary('s').map((e) => e.term), ['Suited']);
    });

    test('seat labels map onto entries', () {
      expect(lookupTerm('UTG+2')!.term, 'UTG+1');
      expect(lookupTerm('BTN/SB')!.term, 'BTN');
      expect(lookupTerm('lj')!.term, 'LJ');
      expect(lookupTerm('Seat 9'), isNull);
    });
  });

  group('chart data bucketing', () {
    test('weeks start on Monday at local midnight', () {
      expect(weekStart(now), DateTime(2026, 10, 26));
      expect(weekStart(DateTime(2026, 11, 1, 23)), DateTime(2026, 10, 26));
      expect(weekStart(DateTime(2026, 11, 2)), DateTime(2026, 11, 2));
    });

    test('per week: gaps kept, old answers dropped', () {
      final b = bucketAnswers([
        hit('s', 'AA', nowMs),
        miss('s', 'AA', ago(day)), // Monday: same week
        hit('s', 'AA', ago(const Duration(days: 8))), // last week
        hit('s', 'AA', ago(const Duration(days: 200))), // out of range
      ], now, byDay: false, count: 4);
      expect(b.map((x) => x.start), [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
      ]);
      expect(b.map((x) => x.count), [0, 0, 1, 2]);
      expect(b.map((x) => x.accuracy), [null, null, 1.0, 0.5]);
    });

    test('per day', () {
      final b = bucketAnswers([
        hit('s', 'AA', nowMs),
        hit('s', 'AA', ago(const Duration(hours: 8))), // 1am today
        miss('s', 'AA', ago(const Duration(hours: 10))), // 11pm yesterday
      ], now, byDay: true, count: 3);
      expect(b.map((x) => x.start),
          [DateTime(2026, 10, 25), DateTime(2026, 10, 26), DateTime(2026, 10, 27)]);
      expect(b.map((x) => x.accuracy), [null, 0.0, 1.0]);
    });

    test('per-night GTO grade from logged hands', () {
      LoggedHand h(String cards, PreAction a, Facing f) => LoggedHand(
          number: 1, cards: parseCards(cards), position: 'CO', action: a, facing: f, ts: 0);
      HomeSession night(String id, int started, List<LoggedHand> hands) => HomeSession(
          id: id, name: id, started: started, players: ['me', 'a', 'b', 'c', 'd', 'e'],
          heroSeat: 0, buttonSeat: 1, hands: hands);
      final g = nightGrades([
        night('second', ago(day), [
          h('AsAh', PreAction.raise, Facing.unopened),
          h('7c2d', PreAction.raise, Facing.unopened),
        ]),
        night('first', ago(const Duration(days: 8)),
            [h('AsKs', PreAction.raise, Facing.unopened)]),
        night('ungraded', ago(day), [h('AsKs', PreAction.call, Facing.raised)]),
      ], lib);
      expect(g.map((n) => n.name), ['first', 'second']);
      expect(g.map((n) => n.score), [1.0, 0.5]);
      expect(g.map((n) => n.graded), [1, 2]);
    });
  });

  group('widgets at 360px', () {
    Future<TrainerModel> withHistory() async {
      final m = TrainerModel(lib, rng: Random(1), clock: () => now);
      await m.load();
      m.history.addAll([
        miss('cash-rfi-UTG', 'KJo', nowMs),
        hit('cash-rfi-UTG', 'AKs', ago(const Duration(days: 9))),
        hit('cash-rfi-HJ', 'A5s', ago(const Duration(days: 20))),
      ]);
      return m;
    }

    Future<void> pump(WidgetTester tester, ThemeData theme, Widget home,
        {TrainerModel? m}) async {
      tester.view.physicalSize = const Size(360 * 3, 760 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        builder: (_, child) => AppScope(trainer: m, child: child!),
        home: home,
      ));
      await tester.pump();
    }

    for (final (name, theme) in [('dark', Felt.dark()), ('light', Felt.light())]) {
      testWidgets('glossary, mistakes, progress and train ($name)', (tester) async {
        final m = await withHistory();

        await pump(tester, theme, const GlossaryScreen(initialQuery: 'CO'));
        expect(find.textContaining('Cutoff'), findsWidgets);
        await tester.enterText(find.byKey(const Key('glossary-search')), 'squeeze');
        await tester.pump();
        expect(find.textContaining('Squeeze'), findsWidgets);
        expect(tester.takeException(), isNull);

        String? weakSpot;
        List<(String, int)>? weak;
        await pump(
            tester,
            theme,
            ChartsScreen(
              library: lib,
              onDrill: (_) {},
              model: m,
              onDrillWeak: (s, t) {
                weakSpot = s;
                weak = t;
              },
            ),
            m: m);
        await tester.scrollUntilVisible(
            find.byKey(const Key('chart-mistakes-toggle')), 200,
            scrollable: find.byType(Scrollable).first);
        expect(find.byType(RangeGrid), findsOneWidget);
        await tester.ensureVisible(find.text('My mistakes'));
        await tester.pump();
        await tester.tap(find.text('My mistakes'));
        await tester.pump();
        expect(find.byType(MistakeGrid), findsOneWidget);
        expect(find.byType(RangeGrid), findsNothing);
        await tester.ensureVisible(find.byKey(const Key('drill-weak-hands')));
        await tester.tap(find.byKey(const Key('drill-weak-hands')));
        expect(weakSpot, 'cash-rfi-UTG');
        expect(weak, [('cash-rfi-UTG', hand('KJo'))]);
        ChartPrefs.colorBlind.value = true;
        await tester.pump();
        expect(
            tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((c) => c.foregroundPainter)
                .whereType<ActionPatternPainter>(),
            isNotEmpty);
        ChartPrefs.colorBlind.value = false;
        expect(tester.takeException(), isNull);

        await pump(tester, theme, ProgressScreen(trainer: m), m: m);
        expect(find.byType(ScoreChart), findsOneWidget);
        expect(find.textContaining('No graded home-game nights'), findsOneWidget);
        await tester.tap(find.text('Per day'));
        await tester.pump();
        expect(find.byType(ScoreChart), findsOneWidget);
        expect(tester.takeException(), isNull);

        final empty = TrainerModel(lib, rng: Random(1), clock: () => now);
        await empty.load();
        await pump(tester, theme, ProgressScreen(trainer: empty), m: empty);
        expect(find.byType(ScoreChart), findsNothing);
        expect(find.textContaining('No drills in the last'), findsOneWidget);

        // Train: glossary button fits in the app bar; a seat chip opens it.
        await pump(tester, theme, TrainScreen(model: m), m: m);
        expect(find.byTooltip('Glossary'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final seat = find.text(m.current!.spot.hero).first;
        await tester.tap(seat);
        await tester.pumpAndSettle();
        expect(find.byType(GlossaryScreen), findsOneWidget);
      });
    }
  });
}
