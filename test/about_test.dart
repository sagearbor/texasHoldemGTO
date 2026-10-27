import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/screens/about_screen.dart';
import 'package:felt_notes/ui/screens/help_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    await tester.binding.setSurfaceSize(const Size(400, 1600));
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

  testWidgets('About backup buttons: copy, paste-restore, reject bad text',
      (tester) async {
    PackageInfo.setMockInitialValues(
        appName: 'Felt Notes',
        packageName: 'com.sagearbor.feltnotes.app',
        version: '0.1.2',
        buildNumber: '5',
        buildSignature: '');
    final (t, h) = await tester.runAsync(() async {
      final r = await seeded();
      // Let the models' fire-and-forget saves land.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return r;
    }) as (TrainerModel, HomeGameModel);
    String? clip;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clip = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.binding.setSurfaceSize(const Size(400, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: Felt.dark(),
      builder: (_, child) => AppScope(trainer: t, home: h, child: child!),
      home: const AboutScreen(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Back up my data'), findsOneWidget);
    expect(find.text('Restore from backup'), findsOneWidget);
    expect(find.text('Export hands (CSV)'), findsOneWidget);
    expect(find.text(backupStatement), findsOneWidget);

    // Copy the backup as text.
    await tester.tap(find.text('Copy backup as text'));
    await tester.pumpAndSettle();
    expect(clip, isNotNull);
    expect(clip, contains('"app": "felt_notes"'));
    expect(find.textContaining('Backup copied (1 game night, 5 drills)'),
        findsOneWidget);
    final backup = clip!;

    // Wipe, then restore by pasting the text back.
    await tester.runAsync(() => resetAllData(trainer: t, home: h));
    expect(h.sessions, isEmpty);
    expect(t.history, isEmpty);

    Future<void> pasteRestore(String text) async {
      await tester.tap(find.text('Restore from backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste backup text'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('backup-paste-field')), text);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }

    await pasteRestore('definitely not a backup');
    expect(find.text("Can't restore this"), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(h.sessions, isEmpty);

    await pasteRestore(backup);
    expect(find.text('Restore backup?'), findsOneWidget);
    expect(
        tester.widget<Text>(find.byKey(const Key('restore-summary'))).data,
        allOf(contains('1 game night, 5 drills'),
            contains('On this device now: 0 game nights, 0 drills')));
    // Cancel changes nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.sessions, isEmpty);

    await pasteRestore(backup);
    await tester.tap(find.text('Replace'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(h.sessions.length, 1);
    expect(h.sessions.single.hands.length, 1);
    expect(t.history.length, 5);
    expect(find.textContaining('Restored.'), findsOneWidget);
  });
}
