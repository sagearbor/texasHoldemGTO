// The table-night screens and the app-wide service, without a network
// (Firebase cannot start in a widget test, so the night is local-only):
// starting a game night with the switch on makes it a table night whose log
// follows the hand logger; the organizer sheet shows the QR and the sharing
// switch; a player joins private by default (sharing under Advanced) and gets the pad.

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/sync/cloud_logs.dart' show cloudEvents;
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/organizer_bridge.dart' show rosterOf;
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
    expect(find.byKey(const Key('show-on-tv')), findsOneWidget, reason: 'a clear way onto the TV');
    // The QR does not change by itself (it used to carry a clock reading
    // and redrew every second).
    String qr() => stableQrTicket(svc.night!.qrTicket(roster: rosterOf(m.active!))).encode();
    final first = qr();
    expect(first, isNot(contains('&c=')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1100)));
    await tester.pump(const Duration(seconds: 3));
    expect(qr(), first);
    expect(JoinTicket.parse(first)!.code, svc.night!.ticket.code, reason: 'still a valid join QR');
    // Sharing lives in a compact row.
    await tester.ensureVisible(find.byKey(const Key('sheet-sharing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sheet-sharing')));
    await tester.pumpAndSettle();
    expect(find.text('Share my game with the table (TV)'), findsOneWidget);
    // The obvious next step closes the sheet.
    await tester.ensureVisible(find.byKey(const Key('sheet-start-playing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sheet-start-playing')));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Ending the game night ends the table night.
    await tester.runAsync(() async {
      m.end();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(svc.active, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('player: joining is private by default (sharing under Advanced); the pad taps', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: JoinTableNightScreen()));
    // The join confirmation says it plainly, before Join.
    expect(find.text(TableNightService.joinerPrivateLine), findsOneWidget);
    // The switch is tucked under Advanced, off.
    expect(find.byKey(const Key('joiner-share')), findsNothing);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    final sw = tester.widget<SwitchListTile>(find.byKey(const Key('joiner-share')));
    expect(sw.value, isFalse, reason: 'a joiner shares nothing unless they turn it on');
    expect(find.text('Share my hands with the table (for stats)'), findsOneWidget);
    expect(find.textContaining('only after the hand'), findsOneWidget, reason: 'one honest line');
    // Seat-finding signals: their own switch, on by default.
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('share-seat-signals'))).value, isTrue);
    await tester.enterText(find.byType(TextField).first, 'abcd2345-wxyz6789');
    await tester.enterText(find.byType(TextField).last, 'Ann');
    await tester.scrollUntilVisible(find.text('Join'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Join'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final svc = TableNightService.instance;
    expect(svc.night?.isOrganizer, isFalse);
    expect(svc.night!.sharing, isFalse);
    expect(find.text(TableNightService.joinerPrivateLine), findsOneWidget, reason: 'the pad says it too');
    // Hands-off by default: the table button first, the taps tucked away.
    expect(find.text('Leave it on the table'), findsOneWidget);
    expect(find.text('Raise'), findsNothing, reason: 'Edit a hand is closed by default');
    expect(find.textContaining('counts as a fold'), findsNothing);
    await tester.ensureVisible(find.text('Edit a hand (optional)'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Edit a hand (optional)'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(padOptionalLine), findsOneWidget);
    await tester.ensureVisible(find.text('Raise'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Raise'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Raise'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    final local = svc.night!.localEvents;
    expect(local.where((e) => e.kind == EventKind.play).length, 1, reason: 'kept on the phone');
    // Nothing of the player's own goes up: only the join and the switch.
    final up = cloudEvents(local, sharing: svc.night!.sharing);
    expect(up.where((e) => e.kind == EventKind.play || e.kind == EventKind.cards), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
