// Start a game → QR sheet → Start playing (or swipe the sheet away) goes
// straight into Watch my cards, set to start watching; the setting off
// keeps the hand logger. (No camera plugin in tests: Watch shows its setup
// page with "Camera unavailable", which is also what a phone without
// camera permission gets.)

import 'package:felt_notes/camera/watch_screen.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/sync/cloud_config.dart' show debugOpenCloud;
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/table_night_service.dart';
import 'package:felt_notes/ui/screens/home_game_screen.dart';
import 'package:felt_notes/ui/screens/table_night_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  Future<HomeGameModel> startNight(WidgetTester tester, {required bool dismiss}) async {
    debugOpenCloud = () async => null; // local-only night: no Firebase in tests
    addTearDown(() => debugOpenCloud = null);
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final m = HomeGameModel(lib);
    final svc = TableNightService.instance;
    await tester.runAsync(() async {
      await m.load();
      await svc.init(m, store: MemoryStore());
    });
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: HomeGameScreen(model: m)));
    m.start(name: 'x', players: const ['Sage', 'Ann', 'Bob'], heroSeat: 0, buttonSeat: 0);
    await tester.pump();
    late Future<void> done;
    await tester.runAsync(() async {
      done = afterGameNightStart(nav.currentState!, m);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 20 && find.byKey(const Key('sheet-start-playing')).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    expect(find.byKey(const Key('sheet-start-playing')), findsOneWidget);
    if (dismiss) {
      await tester.tapAt(const Offset(10, 10)); // outside the sheet
    } else {
      await tester.ensureVisible(find.byKey(const Key('sheet-start-playing')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('sheet-start-playing')));
    }
    var finished = false;
    done.whenComplete(() => finished = true);
    for (var i = 0; i < 40 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(finished, isTrue, reason: 'the sheet closed and the start flow finished');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    return m;
  }

  Future<void> cleanUp(WidgetTester tester, HomeGameModel m) async {
    await tester.runAsync(() async {
      m.end();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('Start → Start playing opens Watch, set to start watching', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final m = await startNight(tester, dismiss: false);
    final w = tester.widget<WatchScreen>(find.byType(WatchScreen));
    expect(w.autoStart, isTrue);
    expect(autoWatchRequest.value, isFalse, reason: 'taken once');
    await cleanUp(tester, m);
  });

  testWidgets('swiping the QR sheet away also goes to Watch', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final m = await startNight(tester, dismiss: true);
    expect(find.byType(WatchScreen), findsOneWidget);
    await cleanUp(tester, m);
  });

  testWidgets('setting off: the hand logger, as before', (tester) async {
    SharedPreferences.setMockInitialValues({WatchSettings.autoStartKey: false});
    final m = await startNight(tester, dismiss: false);
    expect(find.byType(WatchScreen), findsNothing);
    await cleanUp(tester, m);
  });
}
