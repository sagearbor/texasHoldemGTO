// The table-night screens and the app-wide service, without a network
// (Firebase cannot start in a widget test, so the night is local-only):
// starting a game night with the switch on makes it a table night whose log
// follows the hand logger; the organizer sheet shows the QR and the sharing
// switch; a player joins with sharing on by default and gets the pad.

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/table_night_service.dart';
import 'package:felt_notes/ui/screens/table_night_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  testWidgets('organizer: the hand logger feeds the night; sheet shows QR, TV link, sharing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final m = HomeGameModel(lib);
    final svc = TableNightService.instance;
    await tester.runAsync(() async {
      await m.load();
      await svc.init(m, store: MemoryStore());
      m.start(name: 'x', players: const ['Sage', 'Ann', 'Bob'], heroSeat: 0, buttonSeat: 0);
      await svc.organize(m.active!);
    });
    expect(svc.isOrganizer, isTrue);
    expect(svc.linkedTo(m.active!), isTrue);
    await tester.runAsync(() async {
      m.setPending(PreAction.raise);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      m.nextHand();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    final kinds = [for (final e in svc.night!.localEvents) e.kind];
    expect(kinds, containsAll([EventKind.seats, EventKind.hand, EventKind.play, EventKind.clock]));
    expect(svc.night!.merged().hands.length, 2);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => showTableNightSheet(context, m.active!), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(svc.night!.ticket.code), findsOneWidget);
    expect(find.textContaining('/#/tv?c='), findsOneWidget);
    expect(find.text('Share my game with the table (TV)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Ending the game night ends the table night.
    await tester.runAsync(() async {
      m.end();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(svc.active, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('player: join screen has sharing on by default; the pad taps', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: JoinTableNightScreen()));
    final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(sw.value, isTrue, reason: 'sharing defaults to on');
    expect(find.textContaining('only after the hand'), findsOneWidget, reason: 'one honest line');
    await tester.enterText(find.byType(TextField).first, 'abcd2345-wxyz6789');
    await tester.enterText(find.byType(TextField).last, 'Ann');
    await tester.runAsync(() async {
      await tester.tap(find.text('Join'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final svc = TableNightService.instance;
    expect(svc.night?.isOrganizer, isFalse);
    expect(svc.night!.sharing, isTrue);
    expect(find.text('Raise'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Raise'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(svc.night!.localEvents.where((e) => e.kind == EventKind.play).length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
