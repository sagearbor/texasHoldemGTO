// Watch my cards against the REAL hand logger (home_game_screen.dart's
// WatchHost), not a fake host: the owner's Nov 4 field report (build 40)
// was "it recorded one hand and then no more", "Next hand never worked"
// and a recap of "0 hands logged". The night had been started from the
// setup form, whose default is "Learn the seats from the deal" (first
// orbit: the organizer taps each dealer), and the black screen cannot tap
// a dealer, so every hand boundary Watch made was dropped.
import 'package:felt_notes/camera/watch_screen.dart';
import 'package:felt_notes/camera/watch_tracker.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/homegame/recap.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/ui/screens/home_game_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  Future<HomeGameModel> fresh({bool learn = false, int button = 0}) async {
    SharedPreferences.setMockInitialValues({});
    final m = HomeGameModel(lib);
    await m.load();
    m.start(
        name: 'Game night 11/4',
        players: ['Me', 'Ann', 'Bob', 'Cat', 'Dan', 'Eve'],
        heroSeat: 0,
        buttonSeat: button,
        learnSeats: learn);
    return m;
  }

  Future<void> pump(WidgetTester tester, HomeGameModel m) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: Felt.dark(), home: HomeGameScreen(model: m)));
    await tester.pump();
  }

  /// Opens Camera (Watch my cards) from the logger and returns the host the
  /// Watch screen was given: the logger itself. There is no camera in
  /// tests, so the screen stays on its setup page.
  Future<WatchHost> openWatch(WidgetTester tester) async {
    final camera = find.byKey(const Key('watch-my-cards'));
    await tester.scrollUntilVisible(camera, 200, scrollable: find.byType(Scrollable).first);
    // The action pad sits under the list: press the button itself.
    tester.widget<TextButton>(camera).onPressed!();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    return tester.widget<WatchScreen>(find.byType(WatchScreen)).host;
  }

  Future<void> closeWatch(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(WatchScreen))).pop();
    await tester.pumpAndSettle();
  }

  // What the black screen does with an agreed pair (watch_screen.dart
  // _onPair/_apply): the logger's own tracker decides, the host applies.
  var clock = 1000000;
  WatchAction read(WatchHost h, String pair, int episode) {
    clock += 20000;
    final d = h.watchTracker.onRead(pair.split(' ').map(parseCard).toList(), clock, episode: episode, scene: episode);
    switch (d.action) {
      case WatchAction.fill:
      case WatchAction.correct:
        h.watchSetCards(d.cards);
      case WatchAction.newHand:
      case WatchAction.newHandUnread:
        expect(h.watchNewHand(d.cards, episode: episode, scene: episode), isTrue,
            reason: 'the logger moved on by itself');
      case WatchAction.confirm:
      case WatchAction.ignore:
        break;
    }
    return d.action;
  }

  List<int> cards(String s) => canonicalPair(s.split(' ').map(parseCard).toList());

  testWidgets('first orbit (learn the seats, nobody tapped as dealer): every hand Watch reads is logged',
      (tester) async {
    final m = (await tester.runAsync(() => fresh(learn: true, button: -1)))!;
    await pump(tester, m);
    expect(find.text('Who deals the first hand?'), findsOneWidget);
    final h = await openWatch(tester);

    expect(read(h, 'As Kd', 1), WatchAction.fill);
    expect(h.watchHandNumber, 1);
    h.watchSetAction(PreAction.raise); // the dim pad: swipe up
    expect(h.watchPendingAction, PreAction.raise);
    expect(read(h, 'Qh Jh', 2), WatchAction.newHand);
    expect(m.active!.hands, hasLength(1), reason: 'the first hand closed with its cards and the raise');
    expect(m.active!.hands[0].cards, cards('As Kd'));
    expect(m.active!.hands[0].action, PreAction.raise);
    expect(h.watchHandNumber, 2);
    expect(h.watchPendingAction, isNull, reason: 'a fresh hand starts with no tap');

    expect(read(h, '7c 2d', 3), WatchAction.newHand);
    expect(m.active!.hands, hasLength(2));
    expect(m.active!.hands[1].cards, cards('Qh Jh'));
    expect(m.active!.hands[1].action, isNull, reason: 'Watch: no tap = not recorded (unknown), not a fold');

    // Next hand on the black screen (top button or sideways swipe).
    h.watchSetAction(PreAction.call);
    h.watchNextHand();
    expect(m.active!.hands, hasLength(3));
    expect(m.active!.hands[2].cards, cards('7c 2d'));
    expect(m.active!.hands[2].action, PreAction.call);
    // Dealers were taken in the typed order (the dealer chip fixes them).
    expect([for (final x in m.active!.hands) x.dealer], ['Me', 'Ann', 'Bob']);
    expect(m.active!.learning, isTrue, reason: 'still learning: the logger can go on tapping dealers');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Watch: tap = call, hold = fold, nothing = not recorded (unknown, not a fold)', (tester) async {
    final m = (await tester.runAsync(() => fresh(learn: true, button: -1)))!;
    await pump(tester, m);
    final h = await openWatch(tester);
    expect(read(h, 'As Kd', 1), WatchAction.fill);
    h.watchSetAction(PreAction.call); // tap
    expect(read(h, 'Qh Jh', 2), WatchAction.newHand);
    h.watchSetAction(PreAction.fold); // long press
    expect(read(h, '7c 2d', 3), WatchAction.newHand);
    // nothing on this one
    h.watchNextHand();
    final hands = m.active!.hands;
    expect(hands, hasLength(3));
    expect([for (final x in hands) x.action], [PreAction.call, PreAction.fold, null]);
    expect(hands[2].cards, cards('7c 2d'), reason: 'the cards are kept; only the action is unknown');
    expect(tester.takeException(), isNull);
  });

  testWidgets('first orbit with the first dealer known: Next hand on the black screen moves on', (tester) async {
    final m = (await tester.runAsync(() => fresh(learn: true, button: 2)))!;
    await pump(tester, m);
    final h = await openWatch(tester);
    expect(read(h, 'As Kd', 1), WatchAction.fill);
    h.watchNextHand();
    expect(m.active!.hands, hasLength(1));
    expect(m.active!.hands.single.dealer, 'Bob');
    expect(m.active!.hands.single.cards, cards('As Kd'));
    expect(h.watchTracker.cards, isNull, reason: 'the tracker starts the next hand empty');
    expect(read(h, 'Th 9h', 2), WatchAction.fill, reason: 'the next read fills the new hand');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second game night: the pad and Watch act on the new night, and its recap counts them',
      (tester) async {
    final m = (await tester.runAsync(() => fresh()))!;
    await pump(tester, m);
    var h = await openWatch(tester);
    expect(read(h, 'As Kd', 1), WatchAction.fill);
    h.watchSetAction(PreAction.call);
    h.watchNextHand();
    expect(m.active!.hands, hasLength(1));
    await closeWatch(tester);
    final first = m.active!;
    m.end();
    await tester.pump();

    // A new night from the setup form, its defaults untouched (learn the
    // seats, no first dealer).
    await tester.scrollUntilVisible(find.text('Start'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    final second = m.active!;
    expect(second, isNot(same(first)));
    expect(second.learning, isTrue);

    h = await openWatch(tester);
    expect(h.watchHandNumber, 1);
    expect(h.watchTracker.cards, isNull, reason: 'nothing left over from the first night');
    expect(read(h, '8s 8d', 1), WatchAction.fill);
    h.watchSetAction(PreAction.raise);
    expect(second.pendingAction, PreAction.raise, reason: 'the pad acts on the new night');
    expect(h.watchPendingAction, PreAction.raise, reason: 'and shows it');
    expect(read(h, 'Kc Qc', 2), WatchAction.newHand);
    expect(read(h, '5h 4h', 3), WatchAction.newHand);
    expect(second.hands, hasLength(2));
    expect(first.hands, hasLength(1), reason: 'the ended night is left alone');
    await closeWatch(tester);

    // End game night with a hand being played whose cards were read: it
    // counts (the owner saw it logged).
    m.end();
    expect(second.hands, hasLength(3));
    expect(second.hands.last.cards, cards('5h 4h'));
    final text = recapText(nightRecap(second, lib));
    expect(text, contains('3 hands logged'));
    expect(tester.takeException(), isNull);
  });

  test('End game night: an untouched hand being played is not logged', () async {
    final m = await fresh();
    m.nextHand();
    m.end();
    expect(m.sessions.last.hands, hasLength(1));
  });
}
