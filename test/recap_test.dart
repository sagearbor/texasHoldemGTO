import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/homegame/recap.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/ui/screens/crew_screen.dart';
import 'package:felt_notes/ui/screens/dashboard_screen.dart';
import 'package:felt_notes/ui/screens/recap_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  const minute = 60000;

  /// A fabricated hand. [cards] like 'AsAh', or null for no cards.
  LoggedHand hand(int n, String? cards,
          {String pos = 'UTG',
          String? dealer,
          PreAction? action,
          Facing? facing,
          int? ts}) =>
      LoggedHand(
        number: n,
        cards: cards == null ? null : parseCards(cards),
        position: pos,
        dealer: dealer,
        action: action,
        facing: action == null ? null : (facing ?? Facing.unopened),
        ts: ts ?? n * 2 * minute,
      );

  HomeSession session(List<LoggedHand> hands,
          {List<String> players = const ['Me', 'Alex', 'Sam', 'Jo'],
          int hero = 0,
          int started = 0,
          String name = 'Night'}) =>
      HomeSession(
        id: '$started',
        name: name,
        started: started,
        players: List.of(players),
        heroSeat: hero,
        buttonSeat: 0,
        hands: hands,
        closed: true,
      );

  double eq(String cards) {
    final c = parseCards(cards);
    return lib.vsRandom[LoggedHand(number: 0, cards: c, position: 'BTN', ts: 0).hand!.index];
  }

  group('nightRecap', () {
    test('empty night has nothing to show but does not throw', () {
      final r = nightRecap(session([]), lib);
      expect(r.stats.logged, 0);
      expect(r.duration, isNull);
      expect(r.best, isNull);
      expect(r.coldRun, isNull);
      expect(r.showPremiums, isFalse);
      expect(r.showStyle, isFalse);
      expect(r.showGto, isFalse);
      expect(r.showFoldStreak, isFalse);
      expect(r.showDealers, isFalse);
      expect(r.awards, isEmpty);
      expect(recapText(r), contains('0 hands logged'));
    });

    test('thin night: hands, duration and best hand only', () {
      final r = nightRecap(
          session([
            hand(1, '7c2d', pos: 'CO', ts: 1000),
            hand(2, 'KsKh', pos: 'BTN', ts: 1000 + 95 * minute),
            hand(3, null, action: PreAction.fold, ts: 1000 + 40 * minute),
          ]),
          lib);
      expect(r.stats.logged, 3);
      expect(r.duration, const Duration(minutes: 95));
      expect(durationLabel(r.duration!), '1h 35m');
      expect(r.best!.number, 2);
      expect(r.best!.position, 'BTN');
      expect(r.bestEquity, closeTo(eq('KsKh'), 1e-9));
      expect(r.coldRun, isNull); // needs 15 dealt
      expect(r.showPremiums, isFalse);
      expect(r.showGto, isFalse);
      final text = recapText(r);
      expect(text, contains('Best hand: KK (hand #2, BTN'));
      expect(text, isNot(contains('Coldest')));
      expect(text, isNot(contains('Premiums')));
    });

    test('coldest 10-hand run finds the weakest window', () {
      // 5 strong, 10 trash, 5 strong = 20 dealt.
      final hs = <LoggedHand>[
        for (var i = 1; i <= 5; i++) hand(i, 'AsKs'),
        for (var i = 6; i <= 15; i++) hand(i, '7c2d'),
        for (var i = 16; i <= 20; i++) hand(i, 'QhQd'),
      ];
      final r = nightRecap(session(hs), lib);
      expect(r.coldRun!.from, 6);
      expect(r.coldRun!.to, 15);
      expect(r.coldRun!.avg, closeTo(eq('7c2d'), 1e-9));
    });

    test('cold run skips hands without cards and needs 15 dealt', () {
      final hs = <LoggedHand>[
        for (var i = 1; i <= 14; i++) hand(i * 2, '7c2d'),
        for (var i = 1; i <= 14; i++) hand(i * 2 + 1, null, action: PreAction.fold),
      ]..sort((a, b) => a.number.compareTo(b.number));
      expect(nightRecap(session(hs), lib).coldRun, isNull);
      hs.add(hand(30, '7c2d'));
      final r = nightRecap(session(hs), lib);
      expect(r.coldRun, isNotNull);
      expect(r.coldRun!.from, 2);
      expect(r.coldRun!.to, 20); // 10 dealt hands spanning #2..#20
    });

    test('premiums vs expected and gating', () {
      final hs = [
        hand(1, 'AsAh'),
        hand(2, 'KsKh'),
        hand(3, 'AhKd'),
        for (var i = 4; i <= 12; i++) hand(i, '8c3d'),
      ];
      final r = nightRecap(session(hs), lib);
      expect(r.showPremiums, isTrue);
      expect(r.stats.premiums, 3);
      expect(r.expectedPremiums, closeTo(12 * 40 / 1326, 1e-9));
      expect(r.awards.map((a) => a.id), contains(AwardId.premiumMagnet));
    });

    test('longest fold streak ignores hands without an action', () {
      final hs = [
        hand(1, null, action: PreAction.fold),
        hand(2, null, action: PreAction.fold),
        hand(3, 'AsAh'), // cards only: neither breaks nor extends
        hand(4, null, action: PreAction.fold),
        hand(5, null, action: PreAction.raise),
        hand(6, null, action: PreAction.fold),
      ];
      final r = nightRecap(session(hs), lib);
      expect(r.foldStreak, 3);
      expect(r.showFoldStreak, isTrue);
    });

    test('Rock, Card Dead and Patience awards', () {
      final hs = [
        for (var i = 1; i <= 24; i++)
          hand(i, i.isEven ? '7c2d' : '8h3s', action: PreAction.fold),
        hand(25, 'AsAh', pos: 'UTG', action: PreAction.raise),
      ];
      final r = nightRecap(session(hs), lib);
      expect(r.stats.style, 'Rock');
      final ids = r.awards.map((a) => a.id).toSet();
      expect(ids, containsAll([AwardId.rock, AwardId.cardDead, AwardId.patience]));
      expect(ids, isNot(contains(AwardId.maniac)));
      expect(r.awards.firstWhere((a) => a.id == AwardId.cardDead).title, 'Card Dead');
      expect(r.foldStreak, 24);
    });

    test('Maniac, Button Bandit and On a Heater', () {
      final hs = [
        for (var i = 1; i <= 20; i++)
          hand(i, i.isEven ? 'AsKs' : 'QhQd',
              pos: i % 3 == 0 ? 'BTN' : (i % 3 == 1 ? 'CO' : 'SB'),
              action: PreAction.raise),
      ];
      final r = nightRecap(session(hs), lib);
      final ids = r.awards.map((a) => a.id).toSet();
      expect(ids, containsAll([AwardId.maniac, AwardId.buttonBandit, AwardId.heater]));
      expect(ids, isNot(contains(AwardId.cardDead)));
    });

    test('Button Bandit needs 5 late-position samples', () {
      final hs = [
        for (var i = 1; i <= 4; i++) hand(i, null, pos: 'BTN', action: PreAction.raise),
      ];
      expect(nightRecap(session(hs), lib).awards.map((a) => a.id),
          isNot(contains(AwardId.buttonBandit)));
      hs.add(hand(5, null, pos: 'CO', action: PreAction.fold));
      hs.add(hand(6, null, pos: 'CO', action: PreAction.raise));
      // 5 of 6 raised = 83%
      expect(nightRecap(session(hs), lib).awards.map((a) => a.id),
          contains(AwardId.buttonBandit));
    });

    test('GTO grade gate and letter', () {
      expect(letterGrade(0.95), 'A');
      expect(letterGrade(0.8), 'B');
      expect(letterGrade(0.71), 'C');
      expect(letterGrade(0.6), 'D');
      expect(letterGrade(0.2), 'F');
      final hs = [
        for (var i = 1; i <= 4; i++) hand(i, 'AsAh', pos: 'UTG', action: PreAction.raise),
      ];
      expect(nightRecap(session(hs), lib).showGto, isFalse);
      hs.add(hand(5, '7c2d', pos: 'UTG', action: PreAction.fold));
      final r = nightRecap(session(hs), lib);
      expect(r.showGto, isTrue);
      expect(r.gtoGrade, 'A');
      expect(recapText(r), contains('GTO preflop: A (100% of 5 spots)'));
    });

    test('dealer awards appear in the recap', () {
      final hs = [
        for (var i = 1; i <= 4; i++) hand(i, 'AsAh', dealer: 'Alex'),
        for (var i = 5; i <= 8; i++) hand(i, '7c2d', dealer: 'Sam'),
      ];
      final r = nightRecap(session(hs), lib);
      final golden = r.awards.firstWhere((a) => a.id == AwardId.goldenArm);
      final doom = r.awards.firstWhere((a) => a.id == AwardId.dealerOfDoom);
      expect(golden.title, 'Golden Arm');
      expect(golden.detail, startsWith('Alex'));
      expect(doom.title, 'Dealer of Doom');
      expect(doom.detail, startsWith('Sam'));
      expect(recapText(r), contains('Dealer luck:'));
    });

    test('works without equity data', () {
      final bare = SpotLibrary(lib.cash, lib.pushFold);
      final hs = [for (var i = 1; i <= 25; i++) hand(i, '7c2d', dealer: i.isEven ? 'A' : 'B')];
      final r = nightRecap(session(hs), bare);
      expect(r.best, isNull);
      expect(r.coldRun, isNull);
      expect(r.awards.map((a) => a.id), isNot(contains(AwardId.cardDead)));
    });
  });

  group('dealerLuck', () {
    test('groups by trimmed, case-insensitive name', () {
      final hs = [
        hand(1, 'AsAh', dealer: 'Alex'),
        hand(2, 'KsKh', dealer: ' alex '),
        hand(3, '7c2d', dealer: 'ALEX'),
        hand(4, '8c3d', dealer: 'Alex'),
        hand(5, '9c4d', dealer: 'Sam'),
        hand(6, null, dealer: 'Sam', action: PreAction.fold), // no cards: ignored
        hand(7, 'QsJs'), // no dealer: ignored
      ];
      final d = dealerLuck(hs, lib);
      expect(d.all.length, 2);
      final alex = d.all.first;
      expect(alex.name, 'Alex');
      expect(alex.hands, 4);
      expect(alex.premiums, 2);
      expect(alex.best!.name, 'AA');
      expect(alex.bestNumber, 1);
      expect(alex.avgEquity,
          closeTo((eq('AsAh') + eq('KsKh') + eq('7c2d') + eq('8c3d')) / 4, 1e-9));
      final sam = d.all.last;
      expect(sam.hands, 1);
      // Only Alex has 4+ hands: ranked, but no awards with one dealer.
      expect(d.ranked.map((r) => r.name), ['Alex']);
      expect(d.goldenArm, isNull);
      expect(d.dealerOfDoom, isNull);
    });

    test('ranks best to worst and names golden arm / doom', () {
      final hs = [
        for (var i = 0; i < 4; i++) hand(i, 'AsAh', dealer: 'Alex'),
        for (var i = 4; i < 9; i++) hand(i, 'Ts9s', dealer: 'Jo'),
        for (var i = 9; i < 13; i++) hand(i, '7c2d', dealer: 'Sam'),
        for (var i = 13; i < 16; i++) hand(i, '7c2d', dealer: 'Riley'), // 3: unranked
      ];
      final d = dealerLuck(hs, lib);
      expect(d.ranked.map((r) => r.name), ['Alex', 'Jo', 'Sam']);
      expect(d.goldenArm!.name, 'Alex');
      expect(d.dealerOfDoom!.name, 'Sam');
      expect(d.all.first.name, 'Jo'); // most hands first
    });
  });

  group('crewStats', () {
    test('names, nights, streaks and last seen; hero by seat', () {
      final n1 = session([hand(1, null, dealer: 'Alex', action: PreAction.fold)],
          players: ['Me', 'Alex', 'Sam'], started: 100);
      final n2 = session([
        hand(1, null, dealer: 'Kim', action: PreAction.fold), // Kim left mid-game
      ], players: ['alex ', 'Me', 'Jo'], hero: 1, started: 200);
      final n3 = session([hand(1, null, action: PreAction.fold)],
          players: ['Sage', 'ALEX', 'Jo', 'me'], hero: 0, started: 300);
      final empty = session([], players: ['Me', 'Ghost'], started: 400); // ignored
      // Pass out of order: sorting is by started.
      final c = crewStats([n3, empty, n1, n2]);
      expect(c.nights.map((s) => s.started), [100, 200, 300]);
      final by = {for (final m in c.members) m.name.toLowerCase(): m};
      // Night 3 hero is "Sage" (seat 0), so "me" there is a real other player.
      expect(by.keys.toSet(), {'alex', 'sam', 'jo', 'kim', 'me'});
      expect(by['alex']!.nights, 3);
      expect(by['alex']!.streak, 3);
      expect(by['alex']!.name, 'ALEX'); // most recent spelling
      expect(by['alex']!.lastSeen, 300);
      expect(by['jo']!.nights, 2);
      expect(by['jo']!.streak, 2);
      expect(by['sam']!.nights, 1);
      expect(by['sam']!.streak, 0);
      expect(by['sam']!.lastSeen, 100);
      expect(by['kim']!.nights, 1);
      expect(by['kim']!.lastSeen, 200);
      expect(by['me']!.nights, 1);
      expect(by['me']!.streak, 1);
      expect(c.members.first.name, 'ALEX');
      expect(by.containsKey('ghost'), isFalse);
    });

    test('a broken streak restarts at the latest night', () {
      final c = crewStats([
        session([hand(1, null)], players: ['Me', 'Alex'], started: 1),
        session([hand(1, null)], players: ['Me', 'Bo'], started: 2),
        session([hand(1, null)], players: ['Me', 'Alex', 'Bo'], started: 3),
      ]);
      final by = {for (final m in c.members) m.name: m};
      expect(by['Alex']!.nights, 2);
      expect(by['Alex']!.streak, 1);
      expect(by['Bo']!.streak, 2);
    });

    test('no sessions', () {
      final c = crewStats([]);
      expect(c.nights, isEmpty);
      expect(c.members, isEmpty);
      expect(heroTrend([], lib), isEmpty);
    });
  });

  group('heroTrend', () {
    test('per-night points with small samples left null', () {
      final big = session([
        for (var i = 1; i <= 6; i++)
          hand(i, i <= 3 ? 'AsAh' : '7c2d', pos: 'UTG',
              action: i <= 3 ? PreAction.raise : PreAction.fold),
      ], started: 10);
      final small = session([hand(1, 'AsAh', action: PreAction.call, facing: Facing.raised)],
          started: 5);
      final t = heroTrend([big, small], lib);
      expect(t.map((n) => n.session.started), [5, 10]);
      expect(t[0].vpip, isNull);
      expect(t[0].avgStrength, isNull);
      expect(t[0].gto, isNull);
      expect(t[1].vpip, closeTo(0.5, 1e-9));
      expect(t[1].pfr, closeTo(0.5, 1e-9));
      expect(t[1].gto, 1.0);
      expect(t[1].avgStrength, closeTo((eq('AsAh') + eq('7c2d')) / 2, 1e-9));
    });
  });

  group('screens render', () {
    HomeSession bigNight(int started) => session([
          for (var i = 1; i <= 40; i++)
            hand(i, ['AsAh', '7c2d', 'KsQs', '8h3s', 'Td9d'][i % 5],
                pos: ['BTN', 'CO', 'HJ', 'UTG', 'BB', 'SB'][i % 6],
                dealer: ['Me', 'Alexandria Longname', 'Sam', 'Jo'][i % 4],
                action: i % 3 == 0 ? PreAction.raise : PreAction.fold),
        ], started: started, name: 'Game night 10/$started');

    Future<void> pump(WidgetTester tester, Widget w) async {
      tester.view.physicalSize = const Size(390 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: Felt.dark(), home: w));
      await tester.pump();
    }

    testWidgets('recap pages through every card', (tester) async {
      final m = HomeGameModel(lib)..sessions.add(bigNight(1));
      await pump(tester, RecapScreen(model: m, session: m.sessions.first));
      final n = recapCards(nightRecap(m.sessions.first, lib)).length;
      expect(n, greaterThanOrEqualTo(8));
      for (var i = 0; i < n - 1; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('DEALER LUCK'), findsNothing); // awards card is last
      expect(tester.takeException(), isNull);
    });

    testWidgets('thin recap still renders', (tester) async {
      final m = HomeGameModel(lib)..sessions.add(session([hand(1, null)]));
      await pump(tester, RecapScreen(model: m, session: m.sessions.first));
      expect(find.text('1'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('crew screen and dashboard tile', (tester) async {
      final m = HomeGameModel(lib)..sessions.addAll([bigNight(1), bigNight(2), bigNight(3)]);
      await pump(tester, CrewScreen(model: m));
      expect(find.text('The crew'), findsOneWidget);
      expect(find.text('Alexandria Longname'), findsOneWidget);
      await pump(tester, DashboardScreen(model: m, session: m.sessions.first));
      await tester.scrollUntilVisible(find.text('DEALER LUCK'), 200);
      expect(find.text('Golden Arm'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
