// The main thing on each Learn section is on screen without scrolling on
// a Pixel-sized phone (412x915 dp), at normal and large (1.3x) text.
import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/main.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/app_settings.dart';
import 'package:felt_notes/ui/dev_mode.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:felt_notes/ui/widgets/range_grid.dart';
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
    AppSettings.playerName.value = 'Host';
    await DevMode.load();
  });

  late TrainerModel trainer;

  Future<void> pumpShell(WidgetTester tester, {double textScale = 1}) async {
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final t = trainer = TrainerModel(lib);
    final h = HomeGameModel(lib);
    await tester.runAsync(() => Future.wait([t.load(), h.load()]));
    await tester.pumpWidget(MaterialApp(
      theme: Felt.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: AppScope(trainer: t, home: h, child: child!),
      ),
      home: Shell(model: t, home: h),
    ));
    await tester.pumpAndSettle();
  }

  /// The bottom of [f] is above the navigation bar.
  void expectAboveFold(WidgetTester tester, Finder f, String why) {
    final bar = tester.getTopLeft(find.byType(NavigationBar)).dy;
    expect(f, findsOneWidget, reason: why);
    expect(tester.getBottomLeft(f).dy, lessThanOrEqualTo(bar), reason: '$why: bottom above the tab bar');
  }

  for (final scale in [1.0, 1.3]) {
    testWidgets('Charts: the whole range grid is visible without scrolling (text x$scale)', (tester) async {
      await pumpShell(tester, textScale: scale);
      await tester.tap(find.byKey(const Key('learn-tab-1')));
      await tester.pumpAndSettle();
      expectAboveFold(tester, find.byType(RangeGrid), 'range grid');
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 1.3]) {
    testWidgets('Train: the cards and the action buttons are on screen at once (text x$scale)', (tester) async {
      await pumpShell(tester, textScale: scale);
      // The wordiest spots (longest situation, longest title) are the worst
      // case for the fold.
      final all = lib.all.toList();
      final worst = {
        ...(all..sort((x, y) => y.situation.length.compareTo(x.situation.length))).take(3).map((x) => x.id),
        ...(all..sort((x, y) => y.title.length.compareTo(x.title.length))).take(3).map((x) => x.id),
      };
      for (final id in worst) {
        trainer.focus(id);
        await tester.pumpAndSettle();
        final spot = trainer.current!.spot;
        for (final a in spot.actions) {
          expectAboveFold(tester, find.widgetWithText(FilledButton, a), '${spot.id} action $a');
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}
