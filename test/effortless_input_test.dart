import 'dart:convert';

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/ui/screens/home_game_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:felt_notes/ui/widgets/action_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  Future<HomeGameModel> fresh({
    List<String> players = const ['Me', 'Ann', 'Bob', 'Cat', 'Dan', 'Eve'],
    bool learn = false,
    int button = 0,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final m = HomeGameModel(lib);
    await m.load();
    m.start(
        name: 'x',
        players: players,
        heroSeat: 0,
        buttonSeat: button,
        learnSeats: learn);
    return m;
  }

  String dealer(HomeGameModel m) => m.active!.players[m.active!.buttonSeat];
  int seat(HomeGameModel m, String name) => m.active!.players.indexOf(name);

  group('default fold', () {
    test('untouched hands count as folds, taps as call/raise', () async {
      final m = await fresh();
      for (var i = 0; i < 6; i++) {
        m.nextHand(); // nothing tapped
      }
      m.setPending(PreAction.call);
      m.nextHand();
      m.setPending(PreAction.raise);
      m.nextHand();
      final hs = m.active!.hands;
      expect(hs.length, 8);
      expect(hs.take(6).every((h) => h.action == PreAction.fold && h.assumed), isTrue);
      expect(hs[6].action, PreAction.call);
      expect(hs[6].assumed, isFalse);
      expect(hs[7].action, PreAction.raise);
      // Gesture taps leave "facing" unknown, so they are not GTO-graded.
      expect(hs[7].facing, isNull);
      final st = computeStats(hs, lib);
      expect(st.logged, 8);
      expect(st.recorded, 8);
      expect(st.assumed, 6);
      expect(st.vpip, 2);
      expect(st.pfr, 1);
      expect(st.vpipPct, 0.25);
      expect(st.coverage, 1.0);
      expect(st.graded, 0);
    });

    test('skip stays unknown, distinct from a default fold', () async {
      final m = await fresh();
      m.setPendingSkip(true);
      m.nextHand();
      m.nextHand();
      final hs = m.active!.hands;
      expect(hs[0].skipped, isTrue);
      expect(hs[0].action, isNull);
      expect(hs[1].skipped, isFalse);
      expect(hs[1].assumed, isTrue);
      final st = computeStats(hs, lib);
      expect(st.recorded, 1);
      expect(st.coverage, 0.5);
    });

    test('a tap then undo-tap goes back to the default fold', () async {
      final m = await fresh();
      m.setPending(PreAction.raise);
      m.setPending(null);
      m.nextHand(cards: parseCards('7c2d'));
      final h = m.active!.hands.single;
      expect(h.action, PreAction.fold);
      expect(h.assumed, isTrue);
      expect(h.cards, parseCards('7c2d'));
    });

    test('a real tap on a logged hand clears assumed', () async {
      final m = await fresh();
      m.nextHand();
      m.attachToHand(1, action: PreAction.call, facing: Facing.raised);
      expect(m.active!.hands.single.assumed, isFalse);
      expect(m.active!.hands.single.action, PreAction.call);
    });

    test('undo reopens the hand with its tap and start time', () async {
      final m = await fresh();
      final start = m.active!.handStartedAt;
      m.setPending(PreAction.call);
      m.nextHand();
      m.undo();
      expect(m.active!.hands, isEmpty);
      expect(m.active!.pendingAction, PreAction.call);
      expect(m.active!.handStartedAt, start);
      expect(dealer(m), 'Me');
    });

    test('boundaries and handAt map a tap time to its hand', () async {
      final m = await fresh();
      m.nextHand();
      m.nextHand();
      final s = m.active!;
      final b = s.boundaries;
      expect(b.length, 3); // two logged hands + the one being played
      expect(b.first, s.hands[0].start);
      expect(s.hands[1].start, s.hands[0].ts);
      expect(b.last, s.handStartedAt);
      expect(s.handAt(s.hands[1].ts + 1), isNull); // the current hand
      expect(s.handAt(s.started - 1), isNull);
    });

    test('pending tap, seats and boundaries survive a save', () async {
      final m = await fresh(learn: true, button: -1);
      m.dealerTap(seat(m, 'Bob'));
      m.setPending(PreAction.raise);
      final j = jsonDecode(jsonEncode(m.active!.toJson())) as Map<String, dynamic>;
      final r = HomeSession.fromJson(j);
      expect(r.pendingAction, PreAction.raise);
      expect(r.learnedSeats, 1);
      expect(r.players.first, 'Bob');
      expect(r.handStartedAt, m.active!.handStartedAt);
      expect(r.rosterToJson()['ls'], 1);
    });

    test('old saves load: no assumed folds, current hand starts at last log', () {
      final r = HomeSession.fromJson({
        'id': '1',
        'name': 'old',
        'started': 1000,
        'players': ['Me', 'A', 'B'],
        'hero': 0,
        'btnNext': 1,
        'hands': [
          {'n': 1, 'c': null, 'p': 'BTN', 'd': 'Me', 'a': 0, 'f': null, 't': 5000},
          {'n': 2, 'c': null, 'p': 'BB', 'd': 'A', 'a': null, 'f': null, 't': 9000},
        ],
        'closed': false,
      });
      expect(r.hands.any((h) => h.assumed), isFalse);
      expect(r.hands[1].skipped, isTrue);
      expect(r.learning, isFalse);
      expect(r.handStartedAt, 9000);
      expect(r.boundaries, [1000, 5000, 9000]);
      expect(r.handAt(6000)?.number, 2);
      expect(r.bench, isEmpty);
      // Nothing new is written for an old hand.
      expect(r.hands[0].toJson().containsKey('af'), isFalse);
    });
  });

  group('seat order from first-orbit dealer taps', () {
    test('tap order is the seat order, then the button rotates', () async {
      // Typed in any order; the table is really Dan, Me, Eve, Ann, Cat, Bob.
      final m = await fresh(learn: true, button: -1);
      expect(m.active!.handInProgress, isFalse);
      for (final n in ['Dan', 'Me', 'Eve', 'Ann', 'Cat']) {
        expect(m.dealerTap(seat(m, n)), isTrue);
        expect(dealer(m), n);
        expect(m.active!.learning, isTrue);
      }
      expect(m.active!.hands.length, 4); // first tap only starts hand 1
      m.dealerTap(seat(m, 'Bob')); // last new name: order is known
      expect(m.active!.learning, isFalse);
      expect(m.active!.players, ['Dan', 'Me', 'Eve', 'Ann', 'Cat', 'Bob']);
      expect(m.active!.heroSeat, 1);
      m.nextHand();
      expect(dealer(m), 'Dan');
      m.nextHand();
      expect(dealer(m), 'Me');
      expect(m.active!.position, 'BTN');
      // Positions of the first-orbit hands were recomputed from the order.
      final hs = m.active!.hands;
      expect([for (final h in hs.take(6)) h.dealer], ['Dan', 'Me', 'Eve', 'Ann', 'Cat', 'Bob']);
      expect([for (final h in hs.take(6)) h.position], ['SB', 'BTN', 'CO', 'HJ', 'UTG', 'BB']);
    });

    test('the button draw winner is the first dealer', () async {
      final m = await fresh(learn: true, button: 3); // Cat won the draw
      expect(m.active!.handInProgress, isTrue);
      expect(dealer(m), 'Cat');
      expect(m.active!.players.first, 'Cat');
      expect(m.active!.learnedSeats, 1);
    });

    test('first dealer again ends the orbit; the untapped go to the bench', () async {
      final m = await fresh(learn: true, button: -1);
      for (final n in ['Ann', 'Me', 'Bob']) {
        m.dealerTap(seat(m, n));
      }
      expect(m.dealerTap(seat(m, 'Me')), isFalse); // already seated, not first
      expect(m.dealerTap(seat(m, 'Ann')), isTrue);
      final s = m.active!;
      expect(s.learning, isFalse);
      expect(s.players, ['Ann', 'Me', 'Bob']);
      expect(s.bench, ['Cat', 'Dan', 'Eve']);
      expect(dealer(m), 'Ann');
      expect(s.hands.length, 3);
      // A benched player deals later: seated where they deal.
      m.nextHand(); // Me deals
      m.nextHand();
      m.dealerArrives('Dan'); // Dan deals instead of Bob: Dan sits before Bob
      expect(dealer(m), 'Dan');
      expect(s.players, ['Ann', 'Me', 'Dan', 'Bob']);
      expect(s.bench, ['Cat', 'Eve']);
      m.nextHand();
      expect(dealer(m), 'Bob');
      m.nextHand();
      expect(dealer(m), 'Ann');
    });

    test('Next hand while learning confirms the next guessed dealer', () async {
      final m = await fresh(players: ['Me', 'Ann', 'Bob'], learn: true, button: 0);
      m.nextHand();
      expect(dealer(m), 'Ann');
      m.nextHand();
      expect(m.active!.learning, isFalse);
      expect(m.active!.players, ['Me', 'Ann', 'Bob']);
    });

    test('dealer override fixes a mis-tap while learning', () async {
      final m = await fresh(learn: true, button: -1);
      m.dealerTap(seat(m, 'Ann'));
      m.dealerTap(seat(m, 'Eve')); // oops, it was Bob
      m.setDealer(seat(m, 'Bob'));
      expect(dealer(m), 'Bob');
      expect(m.active!.players.take(2), ['Ann', 'Bob']);
      expect(m.active!.learnedSeats, 2);
    });

    test('undo un-learns the last dealer tap', () async {
      final m = await fresh(learn: true, button: -1);
      m.dealerTap(seat(m, 'Ann'));
      m.dealerTap(seat(m, 'Bob'));
      m.undo();
      expect(m.active!.learnedSeats, 1);
      expect(dealer(m), 'Ann');
      expect(m.active!.hands, isEmpty);
      m.dealerTap(seat(m, 'Cat'));
      expect(m.active!.players.take(2), ['Ann', 'Cat']);
    });
  });

  group('rotation after players join and leave', () {
    test('a leaver is skipped; a newcomer deals in turn', () async {
      final m = await fresh(players: ['Me', 'Ann', 'Bob', 'Cat']);
      m.nextHand(); // Me dealt, Ann next
      m.removePlayer(seat(m, 'Bob'));
      m.nextHand(); // Ann dealt
      expect(dealer(m), 'Cat');
      m.nextHand();
      expect(dealer(m), 'Me');
      m.addPlayer('Zed', seat(m, 'Ann')); // dropped in between Me and Ann
      m.nextHand();
      expect(dealer(m), 'Zed');
      m.nextHand();
      expect(dealer(m), 'Ann');
      expect(m.active!.players, ['Me', 'Zed', 'Ann', 'Cat']);
    });

    test('the dealer leaving passes the button on', () async {
      final m = await fresh(players: ['Me', 'Ann', 'Bob', 'Cat']);
      m.nextHand(); // Ann deals now
      m.removePlayer(seat(m, 'Ann'));
      expect(dealer(m), 'Bob');
    });

    test('a leaver during the first orbit shrinks the learned seats', () async {
      final m = await fresh(players: ['Me', 'Ann', 'Bob', 'Cat'], learn: true, button: -1);
      m.dealerTap(seat(m, 'Ann'));
      m.dealerTap(seat(m, 'Bob'));
      m.removePlayer(seat(m, 'Ann'));
      expect(m.active!.learnedSeats, 1);
      expect(dealer(m), 'Bob');
      m.dealerTap(seat(m, 'Me'));
      m.dealerTap(seat(m, 'Cat'));
      expect(m.active!.learning, isFalse);
      expect(m.active!.players, ['Bob', 'Me', 'Cat']);
    });
  });

  group('logger UI', () {
    Future<void> pump(WidgetTester tester, HomeGameModel m) async {
      tester.view.physicalSize = const Size(360 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: Felt.dark(), home: HomeGameScreen(model: m)));
      await tester.pump();
    }

    testWidgets('pad: tap = call, swipe up = raise, down = undo, sideways = next', (tester) async {
      final m = (await tester.runAsync(() => fresh(players: ['Me', 'Ann', 'Bob'])))!;
      await pump(tester, m);
      final pad = find.byType(ActionPad);
      expect(find.text('FOLD'), findsOneWidget); // the default
      await tester.tap(pad);
      await tester.pump();
      expect(m.active!.pendingAction, PreAction.call);
      await tester.drag(pad, const Offset(0, -80));
      await tester.pump();
      expect(m.active!.pendingAction, PreAction.raise);
      expect(find.text('RAISE'), findsOneWidget);
      await tester.drag(pad, const Offset(0, 80));
      await tester.pump();
      expect(m.active!.pendingAction, isNull);
      await tester.drag(pad, const Offset(0, -80));
      await tester.drag(pad, const Offset(-120, 0)); // next hand
      await tester.pump();
      expect(m.active!.hands.single.action, PreAction.raise);
      expect(m.active!.pendingAction, isNull);
      await tester.drag(pad, const Offset(120, 0)); // nothing tapped
      await tester.pump();
      expect(m.active!.hands.last.assumed, isTrue);
      await tester.scrollUntilVisible(find.text('Fold (auto)'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Fold (auto)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('organizer taps each dealer, then gets Next hand', (tester) async {
      final m = (await tester.runAsync(
          () => fresh(players: ['Me', 'Ann', 'Bob'], learn: true, button: -1)))!;
      await pump(tester, m);
      expect(find.text('Who deals the first hand?'), findsOneWidget);
      expect(find.text('Next hand'), findsNothing);
      await tester.tap(find.text('Bob'));
      await tester.pump();
      expect(find.text('Who is dealing now?'), findsOneWidget);
      await tester.tap(find.text('Me (you)'));
      await tester.pump();
      await tester.tap(find.text('Ann'));
      await tester.pump();
      expect(m.active!.players, ['Bob', 'Me', 'Ann']);
      expect(find.text('Next hand'), findsOneWidget);
      await tester.tap(find.text('Next hand'));
      await tester.pump();
      expect(m.active!.hands.length, 3);
      expect(m.active!.players[m.active!.buttonSeat], 'Bob');
      expect(tester.takeException(), isNull);
    });

    testWidgets('setup learns seats by default', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final m = HomeGameModel(lib);
      await pump(tester, m);
      expect(find.text("Who's playing (any order)"), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Start'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(find.text('Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(m.active!.learning, isTrue);
      expect(m.active!.handInProgress, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
