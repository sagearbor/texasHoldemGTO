import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/screens/about_screen.dart';
import 'package:felt_notes/ui/screens/help_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  Future<(TrainerModel, HomeGameModel)> seeded() async {
    SharedPreferences.setMockInitialValues({'seen_welcome_v1': true});
    final t = TrainerModel(lib);
    final h = HomeGameModel(lib);
    await Future.wait([t.load(), h.load()]);
    for (var i = 0; i < 5; i++) {
      t.answer(0);
      t.next();
    }
    h.start(name: 'Fri', players: ['me', 'b', 'c'], heroSeat: 0, buttonSeat: 0);
    h.logHand(action: PreAction.fold);
    h.setDelay(0);
    return (t, h);
  }

  test('formatVersion', () {
    expect(formatVersion('0.1.2', '5'), '0.1.2 (5)');
    expect(formatVersion('0.1.2', ''), '0.1.2');
    expect(formatVersion('0.1.2', '0.1.2'), '0.1.2');
  });

  test('resetAllData wipes storage and in-memory models', () async {
    final (t, h) = await seeded();
    t.setMode(DrillMode.leaks);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isNotEmpty);

    await resetAllData(trainer: t, home: h);

    expect(prefs.getKeys(), isEmpty);
    expect(t.history, isEmpty);
    expect(t.mode, DrillMode.mixed);
    expect(t.current, isNotNull, reason: 'trainer deals a fresh hand');
    expect(h.sessions, isEmpty);
    expect(h.active, isNull);
    expect(h.dashboardDelayMinutes, 15);

    // A fresh launch sees nothing either.
    final t2 = TrainerModel(lib);
    final h2 = HomeGameModel(lib);
    await Future.wait([t2.load(), h2.load()]);
    expect(t2.history, isEmpty);
    expect(h2.sessions, isEmpty);
  });

  testWidgets('About shows version, privacy and resets after confirming',
      (tester) async {
    PackageInfo.setMockInitialValues(
        appName: 'Felt Notes',
        packageName: 'com.sagearbor.feltnotes.app',
        version: '0.1.2',
        buildNumber: '5',
        buildSignature: '');
    final (t, h) = await tester.runAsync(seeded) as (TrainerModel, HomeGameModel);
    await tester.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: Felt.dark(),
      builder: (_, child) => AppScope(trainer: t, home: h, child: child!),
      home: const HelpScreen(),
    ));
    await tester.tap(find.text('About & privacy'));
    await tester.pumpAndSettle();

    expect(find.text('Version 0.1.2 (5)'), findsOneWidget);
    expect(find.text(privacyStatement), findsOneWidget);
    expect(find.textContaining('approximate GTO baselines'), findsOneWidget);

    // Cancel keeps everything.
    await tester.tap(find.text('Reset all data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(t.history, isNotEmpty);
    expect(h.sessions, isNotEmpty);

    await tester.tap(find.text('Reset all data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete everything'));
    await tester.pumpAndSettle();
    expect(t.history, isEmpty);
    expect(h.sessions, isEmpty);
    expect(find.text('All data deleted'), findsOneWidget);
  });
}
