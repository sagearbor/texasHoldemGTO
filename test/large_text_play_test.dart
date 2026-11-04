// Play and the hand logger at the owner's large text (1.3x) on a 412-dp
// phone: nothing overflows, the pad is on screen.
import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/app_settings.dart';
import 'package:felt_notes/ui/dev_mode.dart';
import 'package:felt_notes/ui/screens/home_game_screen.dart';
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

  Future<HomeGameModel> pump(WidgetTester tester, double scale, Widget Function(HomeGameModel h) home,
      {String name = ''}) async {
    AppSettings.playerName.value = name;
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final t = TrainerModel(lib);
    final h = HomeGameModel(lib);
    await tester.runAsync(() => Future.wait([t.load(), h.load()]));
    await tester.pumpWidget(MaterialApp(
      theme: Felt.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: AppScope(trainer: t, home: h, child: child!),
      ),
      home: home(h),
    ));
    await tester.pumpAndSettle();
    return h;
  }

  for (final scale in [1.0, 1.3]) {
    testWidgets('Play hub, no name yet, text x$scale', (tester) async {
      await pump(tester, scale, (h) => PlayScreen(model: h));
      expect(find.byKey(const Key('play-name-missing')), findsOneWidget);
      expect(find.byKey(const Key('play-host')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Host a game form and the logger, text x$scale', (tester) async {
      final h = await pump(tester, scale, (h) => HomeGameScreen(model: h), name: 'Host');
      expect(tester.takeException(), isNull, reason: 'setup form');
      h.start(name: 'Fri', players: ['Host', 'Player 2', 'Player 3', 'Player 4', 'Player 5', 'Player 6'],
          heroSeat: 0, buttonSeat: 2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'logger');
      // Scroll the whole logger: every part lays out without overflow.
      final list = find.byType(Scrollable).first;
      for (var i = 0; i < 12; i++) {
        await tester.drag(list, const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'logger scrolled $i');
      }
    });
  }
}
