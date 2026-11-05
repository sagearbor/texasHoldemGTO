// Build 45 morning test: on the host's phone, Watch's dim action pad did
// nothing and the night logged 0 hands. A Pixel 10 is 412 x 915 dp; turned
// sideways (propped facing the table) it is 915 wide, past the shell's
// 900-dp switch to a side rail. The switch rebuilt the whole tab stack, so
// the hand logger under Watch was thrown away and recreated: Watch kept
// talking to the dead one (its `mounted` false), and every tap, Next hand
// and card read went nowhere.

import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/camera/watch_screen.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/main.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/app_settings.dart';
import 'package:felt_notes/ui/dev_mode.dart';
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
  setUp(() async {
    SharedPreferences.setMockInitialValues({'seen_welcome_v1': true, 'watch_auto_start_v1': false});
    AppSettings.resetMemory();
    AppSettings.playerName.value = 'Host';
    await DevMode.load();
  });

  Future<(TrainerModel, HomeGameModel)> pumpHost(WidgetTester tester) async {
    final t = TrainerModel(lib);
    final h = HomeGameModel(lib);
    await tester.runAsync(() => Future.wait([t.load(), h.load()]));
    tester.view.physicalSize = const Size(412, 915); // Pixel 10, portrait
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: Felt.light(),
      builder: (_, child) => AppScope(trainer: t, home: h, child: child!),
      home: Shell(model: t, home: h),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Play')));
    await tester.pumpAndSettle();
    h.start(name: 'x', players: const ['Host', 'Ann', 'Bob'], heroSeat: 0, buttonSeat: 0);
    await tester.pumpAndSettle();
    return (t, h);
  }

  Future<void> rotate(WidgetTester tester, Size s) async {
    tester.view.physicalSize = s;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('host: Watch still logs taps, Next hand and reads after the phone turns sideways', (tester) async {
    final (_, h) = await pumpHost(tester);
    await tester.tap(find.byKey(const Key('watch-my-cards')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    final host = tester.widget<WatchScreen>(find.byType(WatchScreen)).host;

    await rotate(tester, const Size(915, 412)); // propped sideways: rail layout
    await rotate(tester, const Size(412, 915));

    host.watchSetAction(PreAction.call);
    expect(h.active!.pendingAction, PreAction.call, reason: 'the pad tap reaches the night');
    host.watchSetAction(PreAction.raise);
    expect(host.watchPendingAction, PreAction.raise);
    host.watchNextHand();
    expect(h.active!.hands, hasLength(1), reason: 'Next hand logs the hand');
    expect(h.active!.hands.last.action, PreAction.raise);

    final moved = host.watchNewHand([parseCard('As'), parseCard('Kd')]);
    expect(moved, isTrue, reason: 'a card read moves the hand on');
    expect(h.active!.hands, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('host logger pad taps and swipes in both layouts',
      (tester) async {
    final (_, h) = await pumpHost(tester);
    final pad = find.byType(ActionPad);
    await tester.tap(pad);
    await tester.pump();
    expect(h.active!.pendingAction, PreAction.call);

    await rotate(tester, const Size(915, 412));
    await tester.drag(find.byType(ActionPad), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(h.active!.pendingAction, PreAction.raise, reason: 'swipe up = raise, sideways too');
    expect(tester.takeException(), isNull);
    await rotate(tester, const Size(412, 915));
    expect(h.active!.pendingAction, PreAction.raise);
  });

  testWidgets('Watch reaches the night even if the logger under it was rebuilt', (tester) async {
    final h = HomeGameModel(lib);
    await tester.runAsync(h.load);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var wrap = false;
    late StateSetter set;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, s) {
        set = s;
        final screen = HomeGameScreen(model: h);
        // A different parent type: the logger's state is thrown away.
        return wrap ? Padding(padding: EdgeInsets.zero, child: screen) : screen;
      }),
    ));
    h.start(name: 'x', players: const ['Host', 'Ann', 'Bob'], heroSeat: 0, buttonSeat: 0);
    await tester.pump();
    await tester.tap(find.byKey(const Key('watch-my-cards')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    final host = tester.widget<WatchScreen>(find.byType(WatchScreen)).host;
    set(() => wrap = true);
    await tester.pump();

    host.watchSetAction(PreAction.call);
    expect(h.active!.pendingAction, PreAction.call);
    host.watchNextHand();
    expect(h.active!.hands, hasLength(1));
    expect(h.active!.hands.last.action, PreAction.call);
    expect(host.watchNewHand([parseCard('As'), parseCard('Kd')]), isTrue);
    expect(h.active!.hands, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
  });
}
