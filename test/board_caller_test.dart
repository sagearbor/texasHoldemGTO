import 'dart:convert';

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/board_speech.dart';
import 'package:felt_notes/homegame/board_stats.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/homegame/recap.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/ui/screens/home_game_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

LoggedHand hand(int n, {String? cards, String? board, PreAction? action, String dealer = 'Alex'}) =>
    LoggedHand(
      number: n,
      cards: cards == null ? null : parseCards(cards),
      position: 'CO',
      dealer: dealer,
      action: action,
      facing: action == null ? null : Facing.unopened,
      ts: 1000 + n,
      board: board == null ? null : parseCards(board),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  Future<HomeGameModel> fresh() async {
    SharedPreferences.setMockInitialValues({});
    final m = HomeGameModel(lib);
    await m.load();
    m.start(name: 'x', players: ['me', 'Alex', 'Sam', 'Jo'], heroSeat: 0, buttonSeat: 1);
    return m;
  }

  group('data', () {
    test('board round-trips under key "b"', () {
      final h = hand(3, cards: 'AsKd', board: 'Kh7s4cJdTh', action: PreAction.raise);
      final j = h.toJson();
      expect(j['b'], parseCards('Kh7s4cJdTh'));
      final back = LoggedHand.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(back.board, parseCards('Kh7s4cJdTh'));
      expect(back.cards, parseCards('AsKd'));
    });

    test('no board -> no "b" key', () {
      expect(hand(1, cards: 'AsKd').toJson().containsKey('b'), isFalse);
    });

    test('migration: hands and sessions saved before boards still load', () {
      final old = {
        'id': '1',
        'name': 'old night',
        'started': 1,
        'players': ['me', 'a', 'b'],
        'hero': 0,
        'btnNext': 1,
        'hands': [
          {'n': 1, 'c': [0, 5], 'p': 'BTN', 'd': 'a', 'a': 0, 'f': 0, 't': 5},
          {'n': 2, 'c': null, 'p': 'SB', 't': 6},
        ],
        'closed': true,
      };
      final s = HomeSession.fromJson(jsonDecode(jsonEncode(old)) as Map<String, dynamic>);
      expect(s.hands.map((h) => h.board), [null, null]);
      expect(s.currentBoard, isEmpty);
      expect(s.toJson().containsKey('cb'), isFalse);
      expect(boardStats(s.hands).isEmpty, isTrue);
    });

    test('current board persists with the session', () async {
      final m = await fresh();
      m.setCurrentBoard(parseCards('Kh7s4c'));
      final raw = (await SharedPreferences.getInstance()).getString('home_sessions_v1')!;
      final m2 = HomeGameModel(lib);
      await m2.load();
      expect(m2.active!.currentBoard, parseCards('Kh7s4c'));
      expect(raw, contains('"cb"'));
    });
  });

  group('logging with a board', () {
    test('board is saved with the hand being logged, then cleared', () async {
      final m = await fresh();
      m.setCurrentBoard(parseCards('Kh7s4c'));
      m.setCurrentBoard(parseCardsBoard('Kh7s4c', 'Jd'));
      m.logHand(cards: parseCards('AsAd'), action: PreAction.raise, facing: Facing.unopened);
      final s = m.active!;
      expect(s.hands.single.board, parseCards('Kh7s4cJd'));
      expect(s.currentBoard, isEmpty);
      m.logHand(action: PreAction.fold);
      expect(s.hands.last.board, isNull);
    });

    test('undo board card and board caps at five', () async {
      final m = await fresh();
      m.setCurrentBoard(parseCards('Kh7s4cJdTh2c'));
      expect(m.active!.currentBoard.length, 5);
      m.undoBoardCard();
      expect(m.active!.currentBoard, parseCards('Kh7s4cJd'));
    });

    test('undoing a hand brings its board back', () async {
      final m = await fresh();
      m.setCurrentBoard(parseCards('Kh7s4c'));
      m.logHand();
      m.undo();
      expect(m.active!.currentBoard, parseCards('Kh7s4c'));
    });

    test('parser output feeds the model', () async {
      final m = await fresh();
      final r = parseBoardSpeech('flop king of hearts seven of spades four of clubs',
          board: m.active!.currentBoard);
      m.setCurrentBoard(r.board);
      final r2 = parseBoardSpeech('turn jack diamonds', board: m.active!.currentBoard);
      m.setCurrentBoard(r2.board);
      expect(boardLabel(m.active!.currentBoard), 'K♥ 7♠ 4♣ J♦');
    });
  });

  group('attachToHand (late logging, match by board)', () {
    test('puts your cards and action on an earlier hand without moving the button', () async {
      final m = await fresh();
      m.setCurrentBoard(parseCards('Kh7s4cJdTh'));
      m.logHand(); // board caller logs hand 1 with no cards
      m.setCurrentBoard(parseCards('2c3d4h'));
      m.logHand(); // hand 2
      final button = m.active!.buttonSeat;
      final pos1 = m.active!.hands[0].position;
      final dealer1 = m.active!.hands[0].dealer;

      final choices = m.handsWithBoards();
      expect(choices.map((h) => h.number), [2, 1]);

      expect(
          m.attachToHand(1,
              cards: parseCards('KsKd'), action: PreAction.raise, facing: Facing.raised),
          isTrue);
      final h1 = m.active!.hands[0];
      expect(h1.cards, parseCards('KsKd'));
      expect(h1.action, PreAction.raise);
      expect(h1.facing, Facing.raised);
      expect(h1.board, parseCards('Kh7s4cJdTh'));
      expect(h1.position, pos1);
      expect(h1.dealer, dealer1);
      expect(m.active!.hands.length, 2);
      expect(m.active!.buttonSeat, button);
    });

    test('keeps what was there when only cards are attached', () async {
      final m = await fresh();
      m.setCurrentBoard(parseCards('Kh7s4c'));
      m.logHand(action: PreAction.call, facing: Facing.raised);
      m.attachToHand(1, cards: parseCards('9s9c'));
      final h = m.active!.hands.single;
      expect(h.cards, parseCards('9s9c'));
      expect(h.action, PreAction.call);
      expect(h.facing, Facing.raised);
    });

    test('unknown hand number is a no-op', () async {
      final m = await fresh();
      m.logHand();
      expect(m.attachToHand(9, cards: parseCards('AsAd')), isFalse);
      expect(m.active!.hands.single.cards, isNull);
    });

    test('attached hand survives save/load', () async {
      final m = await fresh();
      m.setCurrentBoard(parseCards('Kh7s4c'));
      m.logHand();
      m.attachToHand(1, cards: parseCards('AhAc'), action: PreAction.raise);
      final m2 = HomeGameModel(lib);
      await m2.load();
      expect(m2.active!.hands.single.cards, parseCards('AhAc'));
      expect(m2.active!.hands.single.board, parseCards('Kh7s4c'));
    });
  });

  group('board stats', () {
    test('saw the flop: not folded preflop and a flop was recorded', () {
      expect(sawFlop(hand(1, board: 'Kh7s4c', action: PreAction.call)), isTrue);
      expect(sawFlop(hand(1, board: 'Kh7s4c', action: PreAction.fold)), isFalse);
      expect(sawFlop(hand(1, action: PreAction.call)), isFalse);
      expect(sawFlop(hand(1, board: 'Kh7s4c')), isFalse);
    });

    test('flops seen, categories and best made hand', () {
      final hands = [
        hand(1, cards: 'AsAd', board: 'AhKd2c7s9h', action: PreAction.raise), // trips
        hand(2, cards: '7c8c', board: '9cTcJc2d3h', action: PreAction.call), // straight flush
        hand(3, cards: '2s3s', board: 'AhKdQc7s9h', action: PreAction.fold), // folded: no category
        hand(4, cards: 'KsQs', board: 'KhQd2c', action: PreAction.raise), // flop only
        hand(5, cards: '5s5d', board: 'Kh7d2c3sJh'), // cards only: pair
        hand(6, action: PreAction.fold), // no board
        hand(7, board: 'Kh7d2c', action: PreAction.call), // no cards
      ];
      final b = boardStats(hands);
      expect(b.boards, 6);
      expect(b.flopChances, 5);
      expect(b.flopsSeen, 4);
      expect(b.flopSeenPct, closeTo(0.8, 1e-9));
      expect(b.showdowns, 3);
      expect(b.categories, {3: 1, 8: 1, 1: 1});
      expect(b.best!.number, 2);
      expect(b.bestName, 'Straight flush');
      expect(b.categoryRows.map((r) => r.$1), ['Straight flush', 'Three of a kind', 'Pair']);
    });

    test('final hand needs cards and all five board cards', () {
      expect(finalHandScore(hand(1, cards: 'AsAd', board: 'AhKd2c')), isNull);
      expect(finalHandScore(hand(1, board: 'AhKd2c7s9h')), isNull);
      expect(finalHandScore(hand(1, cards: 'AsAd', board: 'AhKd2c7s9h')), isNotNull);
    });

    test('recap text mentions boards only when there are some', () async {
      final m = await fresh();
      for (var i = 0; i < 3; i++) {
        m.logHand(action: PreAction.fold);
      }
      expect(recapText(nightRecap(m.active!, lib)), isNot(contains('Flops seen')));
      m.setCurrentBoard(parseCards('AhKd2c7s9h'));
      m.logHand(cards: parseCards('AsAd'), action: PreAction.raise, facing: Facing.unopened);
      m.setCurrentBoard(parseCards('3h4h5h'));
      m.logHand(action: PreAction.fold);
      m.setCurrentBoard(parseCards('3c4c5c'));
      m.logHand(action: PreAction.call, facing: Facing.raised);
      final text = recapText(nightRecap(m.active!, lib));
      expect(text, contains('Flops seen: 67% (2 of 3)'));
      expect(text, contains('Best made hand: Three of a kind (hand #4'));
    });
  });

  group('logger UI', () {
    testWidgets('type the board, log the hand, attach cards later', (tester) async {
      tester.view.physicalSize = const Size(1080, 4400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final m = await tester.runAsync(fresh);
      await tester.pumpWidget(MaterialApp(theme: Felt.light(), home: HomeGameScreen(model: m!)));
      await tester.pumpAndSettle();
      expect(find.text('Board'), findsOneWidget);
      // Widget tests run as Android: the mic is shown, never started here.
      expect(find.text('Hold to talk'), findsOneWidget);
      expect(find.textContaining('Recognised on this phone'), findsOneWidget);

      await tester.tap(find.byTooltip('Type the board'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'flop king of hearts seven of spades for of clubs');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(m.active!.currentBoard, parseCards('Kh7s4c'));
      expect(find.textContaining('Flop K♥ 7♠ 4♣'), findsOneWidget);

      await tester.tap(find.text('Fold'));
      await tester.pumpAndSettle();
      expect(m.active!.hands.single.board, parseCards('Kh7s4c'));
      expect(m.active!.currentBoard, isEmpty);
      expect(find.text('Board K♥ 7♠ 4♣'), findsOneWidget);

      await tester.tap(find.text('That was hand…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Raise').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hand 1 · K♥ 7♠ 4♣'));
      await tester.pumpAndSettle();
      expect(m.active!.hands.single.action, PreAction.raise);
      expect(m.active!.hands.length, 1);
    });
  });
}

List<int> parseCardsBoard(String flop, String more) => parseCards('$flop$more');
