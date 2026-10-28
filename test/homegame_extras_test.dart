import 'dart:convert';
import 'dart:math';

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/button_draw.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/homegame/milestones.dart';
import 'package:felt_notes/homegame/moments.dart';
import 'package:felt_notes/homegame/my_result.dart';
import 'package:felt_notes/homegame/recap.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/ui/screens/crew_screen.dart';
import 'package:felt_notes/ui/screens/dashboard_screen.dart';
import 'package:felt_notes/ui/screens/home_game_screen.dart';
import 'package:felt_notes/ui/screens/recap_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:felt_notes/ui/widgets/button_draw_dialog.dart';
import 'package:felt_notes/ui/widgets/moments_carousel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  const minute = 60000;
  const day = Duration.millisecondsPerDay;

  LoggedHand hand(int n, String? cards,
          {String pos = 'UTG',
          String? dealer,
          PreAction? action,
          Facing? facing,
          StoryTag? tag,
          int? ts}) =>
      LoggedHand(
        number: n,
        cards: cards == null ? null : parseCards(cards),
        position: pos,
        dealer: dealer,
        action: action,
        facing: action == null ? null : (facing ?? Facing.unopened),
        tag: tag,
        ts: ts ?? n * 2 * minute,
      );

  HomeSession session(List<LoggedHand> hands,
          {int started = 0, double? buyIn, double? cashOut, bool closed = true}) =>
      HomeSession(
        id: '$started',
        name: 'Night $started',
        started: started,
        players: ['Me', 'Alex', 'Sam', 'Jo'],
        heroSeat: 0,
        buttonSeat: 0,
        hands: hands,
        closed: closed,
        buyIn: buyIn,
        cashOut: cashOut,
      );

  List<LoggedHand> folds(int n, {int from = 1}) =>
      [for (var i = 0; i < n; i++) hand(from + i, null, action: PreAction.fold)];

  group('persistence (backward compatible)', () {
    test('old hands and sessions load with no tag and no result', () {
      final s = HomeSession.fromJson({
        'id': '1', 'name': 'old', 'started': 0,
        'players': ['a', 'b', 'c'], 'hero': 0, 'btnNext': 1,
        'hands': [
          {'n': 1, 'c': null, 'p': 'BTN', 'd': 'a', 'a': 0, 'f': 0, 't': 0},
        ],
        'closed': true,
      });
      expect(s.hands.single.tag, isNull);
      expect(s.buyIn, isNull);
      expect(s.cashOut, isNull);
      expect(s.net, isNull);
      // Untagged hands and result-less nights don't grow the stored JSON.
      expect(s.hands.single.toJson().containsKey('g'), isFalse);
      expect(s.toJson().containsKey('buyIn'), isFalse);
    });

    test('tag and result round-trip; unknown tag reads as none', () {
      final s = session([hand(1, 'AsAh', tag: StoryTag.cooler)], buyIn: 20, cashOut: 65.5);
      final back = HomeSession.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.hands.single.toJson()['g'], 'cooler');
      expect(back.hands.single.tag, StoryTag.cooler);
      expect(back.buyIn, 20);
      expect(back.cashOut, 65.5);
      expect(back.net, 45.5);
      final future = LoggedHand.fromJson({'n': 1, 'c': null, 'p': 'BB', 't': 0, 'g': 'tiltedRiver'});
      expect(future.tag, isNull);
      // Integer money from JSON still loads as double.
      final ints = HomeSession.fromJson({...s.toJson(), 'buyIn': 20, 'cashOut': 10});
      expect(ints.net, -10);
    });

    test('model migrates saved v1 data and persists tags, results and seen badges', () async {
      final old = {
        'id': '1', 'name': 'old', 'started': 0,
        'players': ['a', 'b', 'c'], 'hero': 0, 'btn': 0,
        'hands': [
          for (var i = 1; i <= 100; i++) {'n': i, 'c': null, 'p': 'BTN', 'a': 0, 'f': 0, 't': i},
        ],
      };
      SharedPreferences.setMockInitialValues({'home_sessions_v1': jsonEncode([old])});
      final m = HomeGameModel(lib);
      await m.load();
      expect(m.active!.hands.length, 100);
      expect(m.active!.hands.first.tag, isNull);
      // Badges earned before this version are not re-announced.
      expect(m.claimNewBadges(), isEmpty);
      m.setTag(m.active!.hands.last, StoryTag.heroFold);
      m.setResult(m.active!, buyIn: 40, cashOut: 100);
      expect(m.claimNewBadges().map((b) => b.id), [MilestoneId.winningNight]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final again = HomeGameModel(lib);
      await again.load();
      expect(again.active!.hands.last.tag, StoryTag.heroFold);
      expect(again.active!.net, 60);
      expect(again.claimNewBadges(), isEmpty);
    });
  });

  group('milestones', () {
    Milestone get(List<Milestone> ms, MilestoneId id) => ms.firstWhere((m) => m.id == id);

    test('nothing yet', () {
      final ms = milestones([], lib);
      expect(ms.length, greaterThanOrEqualTo(10));
      expect(ms.where((m) => m.unlocked), isEmpty);
      expect(ms.map((m) => m.id).toSet().length, ms.length);
    });

    test('hand counts across nights, aces, stories', () {
      final ms = milestones([
        session([...folds(60), hand(61, 'AdAc', tag: StoryTag.bigPot)], started: 0),
        session(folds(39), started: 30 * day),
      ], lib);
      expect(get(ms, MilestoneId.hands100).unlocked, isTrue);
      expect(get(ms, MilestoneId.hands500).progress, 100);
      expect(get(ms, MilestoneId.hands500).unlocked, isFalse);
      expect(get(ms, MilestoneId.pocketAces).unlocked, isTrue);
      expect(get(ms, MilestoneId.storyteller).progress, 1);
      // 60-fold run in night 1 counts; nights don't join runs.
      expect(get(ms, MilestoneId.foldStreak20).unlocked, isTrue);
      expect(get(ms, MilestoneId.nights5).progress, 2);
      expect(get(ms, MilestoneId.regular).progress, 1); // 30 days apart
    });

    test('fold streak resets on a call and is per night', () {
      final ms = milestones([
        session([...folds(15), hand(16, null, action: PreAction.call), ...folds(15, from: 17)]),
        session(folds(10), started: day),
      ], lib);
      expect(get(ms, MilestoneId.foldStreak20).progress, 15);
      expect(get(ms, MilestoneId.foldStreak20).unlocked, isFalse);
    });

    test('regular: three nights each within 8 days; empty nights ignored', () {
      final ms = milestones([
        session(folds(1), started: 0),
        session(folds(1), started: 7 * day),
        session([], started: 10 * day),
        session(folds(1), started: 15 * day),
      ], lib);
      expect(get(ms, MilestoneId.regular).unlocked, isTrue);
      final broken = milestones([
        session(folds(1), started: 0),
        session(folds(1), started: 7 * day),
        session(folds(1), started: 16 * day),
      ], lib);
      expect(get(broken, MilestoneId.regular).progress, 2);
    });

    test('GTO A night needs enough graded spots', () {
      // AA raised UTG unopened is in-chart every time.
      final good = [for (var i = 1; i <= 5; i++) hand(i, 'AsAh', action: PreAction.raise)];
      expect(get(milestones([session(good)], lib), MilestoneId.gtoA).unlocked, isTrue);
      expect(get(milestones([session(good.sublist(0, 4))], lib), MilestoneId.gtoA).unlocked,
          isFalse);
      final bad = [for (var i = 1; i <= 5; i++) hand(i, 'AsAh', action: PreAction.fold)];
      expect(get(milestones([session(bad)], lib), MilestoneId.gtoA).unlocked, isFalse);
    });

    test('winning night and 5 nights', () {
      final ms = milestones([
        for (var i = 0; i < 5; i++)
          session(folds(1), started: i * day, buyIn: 20, cashOut: i == 3 ? 21 : 0),
      ], lib);
      expect(get(ms, MilestoneId.winningNight).unlocked, isTrue);
      expect(get(ms, MilestoneId.nights5).unlocked, isTrue);
      expect(get(ms, MilestoneId.regular).progress, 5);
    });

    test('claimNewBadges announces each badge once', () {
      SharedPreferences.setMockInitialValues({});
      final m = HomeGameModel(lib);
      m.start(name: 'n', players: ['Me', 'A', 'B'], heroSeat: 0, buttonSeat: 0);
      for (var i = 0; i < 99; i++) {
        m.logHand(action: PreAction.fold);
      }
      expect(m.claimNewBadges().map((b) => b.id), [MilestoneId.foldStreak20]);
      m.logHand(action: PreAction.fold);
      expect(m.claimNewBadges().map((b) => b.id), [MilestoneId.hands100]);
      m.undo();
      m.logHand(action: PreAction.fold);
      expect(m.claimNewBadges(), isEmpty);
    });
  });

  group('moments', () {
    test('empty and thin nights say nothing', () {
      expect(dashboardMoments([], lib), isEmpty);
      expect(dashboardMoments(folds(2), lib), isEmpty);
      expect(dramaLine(folds(2)), isNull);
    });

    test('each moment from the hands given', () {
      final hands = [
        for (var i = 1; i <= 12; i++)
          hand(i, i == 3 ? 'KsKh' : (i == 5 ? 'AsKs' : '7c2d'),
              dealer: i.isEven ? 'Alex' : 'Sam',
              pos: 'BTN',
              action: i <= 8 ? PreAction.call : PreAction.fold,
              tag: i == 4 ? StoryTag.badBeat : (i == 6 ? StoryTag.suckout : null),
              ts: i * 5 * minute),
      ];
      final ms = {for (final m in dashboardMoments(hands, lib)) m.label: m};
      expect(ms['Newest premium']!.headline, 'AKs');
      expect(ms['Newest premium']!.detail, 'Hand #5 from BTN');
      expect(ms['Fold streak']!.headline, '4');
      expect(ms['Last 10 hands']!.headline, startsWith('-')); // mostly 72o
      expect(ms.containsKey('Golden Arm'), isTrue);
      expect(ms["Tonight's drama"]!.headline, 'Suckout');
      expect(ms["Tonight's drama"]!.detail, 'Me 72o · ${clockLabel(30 * minute)}');
      // 12 hands over 55 minutes.
      expect(ms['Hands per hour']!.headline, '13');
      expect(dramaLine(hands, hero: 'Sage'),
          'Suckout · Sage 72o · ${clockLabel(30 * minute)}  |  '
          'Bad beat · Sage 72o · ${clockLabel(20 * minute)}');
    });

    test('fold streak ignores unrecorded hands and stops at a non-fold', () {
      expect(
          currentFoldStreak([
            hand(1, null, action: PreAction.raise),
            ...folds(3, from: 2),
            hand(5, 'AsAh'),
            hand(6, null, action: PreAction.fold),
          ]),
          4);
      expect(currentFoldStreak([hand(1, null, action: PreAction.fold), hand(2, null, action: PreAction.call)]), 0);
    });

    test('drama line caps at three, newest first', () {
      final hands = [for (var i = 1; i <= 5; i++) hand(i, null, tag: StoryTag.values[i])];
      expect(dramaLine(hands)!.split('  |  ').map((l) => l.split(' · ').first),
          ['Big pot', 'Hero fold', 'Suckout']);
      expect(storyLine(hand(9, 'AsAh', tag: StoryTag.cooler)),
          'Cooler · Me AA · ${clockLabel(18 * minute)}');
    });
  });

  group('button draw', () {
    test('high card wins, suits break ties s > h > d > c', () {
      expect(compareDraw(parseCards('As')[0], parseCards('Ah')[0]), greaterThan(0));
      expect(compareDraw(parseCards('Kh')[0], parseCards('Kd')[0]), greaterThan(0));
      expect(compareDraw(parseCards('Kd')[0], parseCards('Kc')[0]), greaterThan(0));
      expect(compareDraw(parseCards('2s')[0], parseCards('3c')[0]), lessThan(0));
      expect(drawWinner(parseCards('9cKdKh2s')), 2);
      expect(drawWinner(parseCards('AcAd')), 1);
    });

    test('distinct cards, one per seat, seeded and repeatable', () {
      for (var seed = 0; seed < 50; seed++) {
        final d = drawForButton(10, Random(seed));
        expect(d.cards.length, 10);
        expect(d.cards.toSet().length, 10);
        expect(d.cards.every((c) => c >= 0 && c < 52), isTrue);
        expect(d.cards[d.winner], d.cards.reduce(max));
      }
      expect(drawForButton(6, Random(7)).cards, drawForButton(6, Random(7)).cards);
    });
  });

  group('my result', () {
    test('money labels and parsing', () {
      expect(moneyLabel(40), '\$40');
      expect(moneyLabel(12.5), '\$12.50');
      expect(moneyLabel(-12.5), '-\$12.50');
      expect(moneyLabel(45, signed: true), '+\$45');
      expect(moneyLabel(0, signed: true), '\$0');
      expect(parseMoney(' \$1,200.50 '), 1200.5);
      expect(parseMoney('40'), 40);
      expect(parseMoney(''), isNull);
      expect(parseMoney('abc'), isNull);
      expect(parseMoney('-5'), isNull);
    });

    test('season result only counts nights with both numbers', () {
      final r = seasonResult([
        session([], started: 3, buyIn: 20, cashOut: 50),
        session([], started: 1, buyIn: 40, cashOut: 0),
        session([], started: 2, buyIn: 20), // no cash-out yet
      ]);
      expect(r.nights.map((n) => n.$1.started), [1, 3]);
      expect(r.total, -10);
      expect(r.winning, 1);
      expect(seasonResult([]).total, 0);
    });
  });

  group('screens on a 360px phone', () {
    Future<void> pump(WidgetTester tester, Widget w, {ThemeData? theme}) async {
      tester.view.physicalSize = const Size(360 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: theme ?? Felt.dark(), home: w));
      await tester.pump();
    }

    HomeSession bigNight(int started, {bool closed = true}) => session([
          for (var i = 1; i <= 40; i++)
            hand(i, ['AsAh', '7c2d', 'KsQs', '8h3s', 'Td9d'][i % 5],
                pos: ['BTN', 'CO', 'HJ', 'UTG', 'BB', 'SB'][i % 6],
                dealer: ['Me', 'Alexandria Longname', 'Sam', 'Jo'][i % 4],
                action: i % 3 == 0 ? PreAction.raise : PreAction.fold,
                tag: i % 7 == 0 ? StoryTag.values[i % 6] : null),
        ], started: started, buyIn: 100, cashOut: 37.5, closed: closed);

    testWidgets('logger: story tags on the last hand and badge snackbar', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final m = HomeGameModel(lib);
      m.start(name: 'Tonight', players: ['Me', 'Alex', 'Sam'], heroSeat: 0, buttonSeat: 0);
      for (var i = 0; i < 99; i++) {
        m.logHand(action: PreAction.fold);
      }
      m.claimNewBadges(); // fold streak already announced
      await pump(tester, HomeGameScreen(model: m), theme: Felt.light());
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Hand #99 a story? (optional)'), 200,
          scrollable: list);
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Fold'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Fold'));
      await tester.pump();
      expect(m.active!.pendingAction, PreAction.fold);
      await tester.scrollUntilVisible(find.text('Next hand'), -200, scrollable: list);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next hand'));
      await tester.pump();
      expect(m.active!.hands.last.assumed, isFalse);
      await tester.scrollUntilVisible(find.text('Hand #100 a story? (optional)'), 200,
          scrollable: list);
      expect(find.text('Hand #100 a story? (optional)'), findsOneWidget);
      expect(find.text('Badge unlocked: Century'), findsOneWidget);
      await tester.ensureVisible(find.text('Cooler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cooler'));
      await tester.pump();
      expect(m.active!.hands.last.tag, StoryTag.cooler);
      await tester.tap(find.text('Cooler'));
      await tester.pump();
      expect(m.active!.hands.last.tag, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('logger: no story tags offered for a skipped hand', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final m = HomeGameModel(lib);
      m.start(name: 'Tonight', players: ['Me', 'Alex', 'Sam'], heroSeat: 0, buttonSeat: 0);
      m.logHand(action: PreAction.fold);
      m.logHand(); // skipped: no cards, no action
      expect(m.active!.hands.last.skipped, isTrue);
      await pump(tester, HomeGameScreen(model: m), theme: Felt.light());
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Recent hands'), 200, scrollable: list);
      expect(find.textContaining('a story? (optional)'), findsNothing);
      expect(find.text('Cooler'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('end game night asks for my result, then shows recap', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final m = HomeGameModel(lib);
      m.start(name: 'Tonight', players: ['Me', 'Alex', 'Sam'], heroSeat: 0, buttonSeat: 0);
      m.logHand(action: PreAction.fold);
      await pump(tester, HomeGameScreen(model: m));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('End game night'));
      await tester.pumpAndSettle();
      expect(find.text(myResultNote), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Buy-in'), '50');
      await tester.enterText(find.widgetWithText(TextField, 'Cash-out'), '80');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(m.sessions.single.closed, isTrue);
      expect(m.sessions.single.net, 30);
      expect(find.byType(RecapScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('setup: draw for the button deals and sets the dealer', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final m = HomeGameModel(lib);
      await pump(tester, HomeGameScreen(model: m));
      await tester.scrollUntilVisible(find.text('Draw for the button'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Draw for the button'));
      await tester.pump();
      expect(find.text('Dealing…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'deals first \(')), findsOneWidget);
      final winnerLine = tester.widget<Text>(find.textContaining(RegExp(r'deals first \('))).data!;
      final name = winnerLine.split(' deals first').first;
      await tester.tap(find.text('Use this'));
      await tester.pumpAndSettle();
      final chip = tester.widget<ChoiceChip>(find.ancestor(
          of: find.text(name), matching: find.byType(ChoiceChip)).last);
      expect(chip.selected, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('button draw dialog with ten long names fits', (tester) async {
      await pump(
          tester,
          Builder(
              builder: (c) => Scaffold(
                    body: TextButton(
                        onPressed: () => showButtonDraw(
                            c, [for (var i = 0; i < 10; i++) 'Player number $i'],
                            rng: Random(1)),
                        child: const Text('go')),
                  )));
      await tester.tap(find.text('go'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Use this'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('recap shows stories and my result', (tester) async {
      final m = HomeGameModel(lib)..sessions.add(bigNight(1));
      await pump(tester, RecapScreen(model: m, session: m.sessions.first));
      final cards = recapCards(nightRecap(m.sessions.first, lib));
      for (var i = 0; i < cards.length - 1; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      final text = recapText(nightRecap(m.sessions.first, lib));
      expect(text, contains('Stories:'));
      expect(text, contains('My result: -\$62.50'));
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('dashboard carousel and drama line, delayed hands hidden', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final live = session([
        for (var i = 1; i <= 12; i++)
          hand(i, i == 2 ? 'QsQh' : '7c2d',
              action: PreAction.fold,
              tag: i == 3 ? StoryTag.bluff : null,
              ts: now - (60 - i * 3) * minute),
        // Logged a minute ago: inside the 15 min delay, must not show.
        hand(13, 'AsAh', tag: StoryTag.cooler, ts: now - minute),
      ], closed: false);
      final m = HomeGameModel(lib)..sessions.add(live);
      await pump(tester, DashboardScreen(model: m));
      expect(find.textContaining('Bluff got through · Me 72o · ', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('Cooler', findRichText: true), findsNothing);
      expect(find.text('AA'), findsNothing);
      expect(find.byType(MomentsCarousel), findsOneWidget);
      expect(find.text('NEWEST PREMIUM'), findsOneWidget);
      expect(find.text('QQ'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('FOLD STREAK'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('crew screen shows my result and badges', (tester) async {
      final m = HomeGameModel(lib)..sessions.addAll([bigNight(1), bigNight(2)]);
      await pump(tester, CrewScreen(model: m));
      await tester.scrollUntilVisible(find.text(myResultNote), 300);
      expect(find.text('-\$125'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Pocket Rockets'), 300);
      expect(find.text('Badges'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('In the Black'), 300);
      expect(tester.takeException(), isNull);
    });
  });
}
