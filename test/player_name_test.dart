// The player's name: required at onboarding, asked once by Play when an
// older install has none, and loud in Settings while empty.
import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/main.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/app_settings.dart';
import 'package:felt_notes/ui/dev_mode.dart';
import 'package:felt_notes/ui/player_name.dart';
import 'package:felt_notes/ui/screens/leak_test_screen.dart';
import 'package:felt_notes/ui/screens/settings_screen.dart';
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

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  FilledButton button(WidgetTester tester, String key) => tester.widget<FilledButton>(find.byKey(Key(key)));

  testWidgets('onboarding: Continue stays disabled until a name is typed', (tester) async {
    phone(tester);
    final m = TrainerModel(lib);
    await tester.runAsync(m.load);
    await tester.pumpWidget(MaterialApp(theme: Felt.dark(), home: OnboardingFlow(model: m)));
    await tester.pumpAndSettle();
    expect(find.text(playerNameQuestion), findsOneWidget);
    expect(find.byTooltip('Close'), findsNothing, reason: 'no way around the name');
    expect(button(tester, 'onboarding-continue').onPressed, isNull);

    await tester.enterText(find.byKey(const Key('onboarding-name')), '   ');
    await tester.pump();
    expect(button(tester, 'onboarding-continue').onPressed, isNull, reason: 'blank is not a name');

    await tester.enterText(find.byKey(const Key('onboarding-name')), '  Robin ');
    await tester.pump();
    expect(button(tester, 'onboarding-continue').onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('onboarding-continue')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(AppSettings.playerName.value, 'Robin');
    expect(find.text('Take the 60-second leak test'), findsWidgets);
  });

  testWidgets('Settings: an empty name is flagged; typing saves it and clears the flag', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(theme: Felt.dark(), home: const SettingsScreen()));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('settings-player-name'));
    // First thing on the screen, in the error colour.
    expect(tester.getTopLeft(field).dy, lessThan(300));
    expect(find.text(playerNameNeeded), findsOneWidget);
    final deco = tester.widget<TextField>(find.descendant(of: field, matching: find.byType(TextField))).decoration!;
    expect(deco.errorText, playerNameNeeded);

    await tester.enterText(find.descendant(of: field, matching: find.byType(TextField)), 'Robin');
    await tester.pumpAndSettle();
    expect(find.text(playerNameNeeded), findsNothing);
    expect(AppSettings.playerName.value, 'Robin');
    expect(tester.takeException(), isNull);
  });

  Future<(TrainerModel, HomeGameModel)> models(WidgetTester tester) async {
    final t = TrainerModel(lib);
    final h = HomeGameModel(lib);
    await tester.runAsync(() => Future.wait([t.load(), h.load()]));
    return (t, h);
  }

  Future<void> openPlay(WidgetTester tester, TrainerModel t, HomeGameModel h) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      theme: Felt.dark(),
      builder: (_, child) => AppScope(trainer: t, home: h, child: child!),
      home: Shell(model: t, home: h),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Play')));
    await tester.pumpAndSettle();
  }

  testWidgets('Play: no name, a loud banner; Host a game asks once, then never again', (tester) async {
    final (t, h) = await models(tester);
    await openPlay(tester, t, h);
    expect(find.byKey(const Key('play-name-missing')), findsOneWidget);

    await tester.tap(find.byKey(const Key('play-host')));
    await tester.pumpAndSettle();
    expect(find.text(playerNameQuestion), findsOneWidget);
    expect(button(tester, 'name-prompt-continue').onPressed, isNull);
    // Not now: stays on Play.
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Start a game night'), findsNothing);

    await tester.tap(find.byKey(const Key('play-host')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('name-prompt-field')), 'Robin');
    await tester.pump();
    await tester.tap(find.byKey(const Key('name-prompt-continue')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(AppSettings.playerName.value, 'Robin');
    expect(find.text('Start a game night'), findsOneWidget);
    expect(find.textContaining('Robin'), findsWidgets, reason: 'the host is named on the seat list');

    // Back and again: no prompt, no banner.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('play-name-missing')), findsNothing);
    await tester.tap(find.byKey(const Key('play-host')));
    await tester.pumpAndSettle();
    expect(find.text(playerNameQuestion), findsNothing);
    expect(find.text('Start a game night'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
