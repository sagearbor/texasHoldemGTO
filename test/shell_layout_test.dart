import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/main.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/app_settings.dart';
import 'package:felt_notes/ui/dev_mode.dart';
import 'package:felt_notes/ui/screens/history_screen.dart';
import 'package:felt_notes/ui/screens/play_screen.dart';
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
  setUp(() async {
    SharedPreferences.setMockInitialValues({'seen_welcome_v1': true});
    AppSettings.resetMemory();
    await DevMode.load();
  });

  Future<(TrainerModel, HomeGameModel)> models(WidgetTester tester) async {
    final t = TrainerModel(lib);
    final h = HomeGameModel(lib);
    await tester.runAsync(() => Future.wait([t.load(), h.load()]));
    return (t, h);
  }

  Future<void> pumpShell(WidgetTester tester, TrainerModel t, HomeGameModel h) async {
    tester.view.physicalSize = const Size(360 * 3, 760 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: Felt.light(),
      builder: (_, child) => AppScope(trainer: t, home: h, child: child!),
      home: Shell(model: t, home: h),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on Learn (Train first), three tabs, Play shows Host a game', (tester) async {
    final (t, h) = await models(tester);
    await pumpShell(tester, t, h);

    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 0);
    expect(bar.destinations, hasLength(3));
    for (final l in ['Learn', 'Play', 'History']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(l)), findsOneWidget);
    }
    expect(find.byKey(const Key('learn-tabs')), findsOneWidget);
    expect(find.textContaining('Daily 10'), findsWidgets);
    expect(tester.takeException(), isNull);

    // Learn's sections: Charts swaps in its screen.
    await tester.tap(find.byKey(const Key('learn-tab-1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Play')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayScreen), findsOneWidget);
    expect(find.text('Host a game'), findsOneWidget);
    expect(find.text("Scan the host's code"), findsOneWidget);
    expect(find.text('This device is the TV'), findsOneWidget);
    // Never asked to sit anywhere, no recording for players.
    expect(find.text('Record the table'), findsNothing);

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('History')));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);
    expect(find.textContaining('No game nights yet'), findsOneWidget);
  });

  testWidgets('Host a game: names prefilled, back returns to Play, Start opens the logger', (tester) async {
    final (t, h) = await models(tester);
    await pumpShell(tester, t, h);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Play')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('play-host')));
    await tester.pumpAndSettle();
    expect(find.text('Start a game night'), findsOneWidget);
    expect(find.textContaining('Player 2'), findsWidgets);
    expect(find.text('Record the table'), findsNothing);
    // Join / TV / history moved off the host form.
    expect(find.text('Join a table night'), findsNothing);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('play-host')), findsOneWidget);

    await tester.tap(find.byKey(const Key('play-host')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Start'), 100, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(h.active, isNotNull);
    expect(find.textContaining('Game night '), findsWidgets);
    expect(find.byKey(const Key('play-host')), findsNothing);

    // Ended: History lists it, Play is back to its one screen.
    h.end();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('play-host')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('History')));
    await tester.pumpAndSettle();
    expect(find.text('Past game nights'), findsOneWidget);
    expect(find.text('Recap'), findsOneWidget);
  });

  testWidgets('developer mode shows Record the table on the host form', (tester) async {
    await DevMode.set(true);
    addTearDown(() => DevMode.set(false));
    final (t, h) = await models(tester);
    await pumpShell(tester, t, h);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('play-host')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Record the table'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Record the table'), findsOneWidget);
  });
}
