// The app-wide service with a cloud behind it (FakeCloudLogs through the
// openCloud seam): hosting creates the night in the cloud and the host's
// table bookkeeping goes up; a private joiner still becomes a member and
// its Bluetooth seat readings go up while its taps and cards stay home; a
// cloud that fails to start is picked up later instead of never; what a
// phone may share still goes up after it went offline, left, and restarted.

import 'dart:async';

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/sync/cloud_config.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/table_night_service.dart';
import 'package:felt_notes/sync/table_sync.dart';
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
  tearDown(() => debugOpenCloud = null);

  Future<void> settle(WidgetTester tester, [int ms = 200]) =>
      tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

  testWidgets('hosting (private by default) creates the night in the cloud', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cloud = FakeCloudLogs();
    debugOpenCloud = () async => cloud;
    final m = HomeGameModel(lib);
    final svc = TableNightService.instance;
    await tester.runAsync(() async {
      await m.load();
      await svc.init(m, store: MemoryStore());
      m.start(name: 'x', players: const ['Sage', 'Ann', 'Bob'], heroSeat: 0, buttonSeat: 0);
      await svc.organize(m.active!);
    });
    await settle(tester);
    final s = svc.night!;
    expect(s.sharing, isFalse);
    expect(cloud.nights.keys, contains(s.nightId), reason: 'the host creates the night');
    expect(cloud.members[s.nightId]!.keys, contains(s.deviceId));
    final up = cloud.parts[s.nightId]!.values.expand((p) => p.events).map((e) => e.kind).toSet();
    expect(up, containsAll([EventKind.join, EventKind.seats, EventKind.hand]));
    expect(svc.cloudStatus().connected, isTrue);
    expect(svc.cloudStatus().line, startsWith('Connected'));
    await tester.runAsync(() async {
      m.end();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });

  testWidgets('a private joiner is a member; seat readings go up, taps and cards do not', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cloud = FakeCloudLogs();
    debugOpenCloud = () async => cloud;
    final svc = TableNightService.instance;
    const t = JoinTicket(nightId: 'ABCDEFGH', secret: 'JKLMNPQR', organizerName: 'Sage');
    await tester.runAsync(() async {
      await svc.join(t, name: 'Kid', scannedAtMs: DateTime.now().millisecondsSinceEpoch, sharing: false);
      final s = svc.night!;
      await s.appendEvent(EventKind.sense, {'w': 55, 'p': {'D:XYZ': -60}});
      await s.tap(PreAction.raise);
      await s.setCards(const [0, 13]);
      s.uploader!.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final s = svc.night!;
    expect(s.sharing, isFalse);
    expect(s.sharingSeat, isTrue, reason: 'Bluetooth seat signals are on by default');
    expect(cloud.members['ABCDEFGH']!.keys, contains(s.deviceId));
    final up = cloud.parts['ABCDEFGH']!.values.expand((p) => p.events).map((e) => e.kind).toList();
    expect(up, containsAll([EventKind.join, EventKind.sense]));
    expect(up, isNot(contains(EventKind.play)));
    expect(up, isNot(contains(EventKind.cards)));
    expect(cloud.cards['ABCDEFGH'] ?? const {}, isEmpty);
    // Seat signals off: the readings come back down.
    await tester.runAsync(() async {
      await svc.setSharingSeat(false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final after = cloud.parts['ABCDEFGH']!.values.expand((p) => p.events).map((e) => e.kind).toList();
    expect(after, isNot(contains(EventKind.sense)));
    await tester.runAsync(() => svc.leave());
  });

  testWidgets('a cloud that failed to start is attached later and the night goes up', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cloud = FakeCloudLogs();
    CloudLogs? next;
    debugOpenCloud = () async => next;
    final svc = TableNightService.instance;
    const t = JoinTicket(nightId: 'BCDEFGHJ', secret: 'JKLMNPQR', organizerName: 'Sage');
    await tester.runAsync(() async {
      await svc.join(t, name: 'Kid', scannedAtMs: DateTime.now().millisecondsSinceEpoch, sharing: false);
    });
    expect(svc.night!.cloud, isNull);
    expect(svc.cloudStatus().connected, isFalse);
    expect(svc.cloudStatus().line, startsWith('Offline'));
    next = cloud;
    await tester.runAsync(() async {
      await svc.retryCloud();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(cloud.members['BCDEFGHJ']!.keys, contains(svc.night!.deviceId));
    expect(svc.cloudStatus().connected, isTrue);
    await tester.runAsync(() => svc.leave());
  });

  testWidgets('a failing cloud says why, in one line', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cloud = FakeCloudLogs()..online = false;
    debugOpenCloud = () async => cloud;
    final svc = TableNightService.instance;
    const t = JoinTicket(nightId: 'CDEFGHJK', secret: 'JKLMNPQR', organizerName: 'Sage');
    await tester.runAsync(() async {
      await svc.join(t, name: 'Kid', scannedAtMs: DateTime.now().millisecondsSinceEpoch, sharing: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final st = svc.cloudStatus();
    expect(st.connected, isFalse);
    expect(st.line, contains('offline'), reason: 'the error itself is shown: ${st.line}');
    await tester.runAsync(() async {
      cloud.online = true;
      svc.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(svc.cloudStatus().connected, isTrue);
    await tester.runAsync(() => svc.leave());
  });

  testWidgets('the host ends the game: the pad says so and goes back', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cloud = FakeCloudLogs();
    debugOpenCloud = () async => cloud;
    final svc = TableNightService.instance;
    late LocalTableSync host;
    await tester.runAsync(() async {
      host = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'Sage', selfPid: 'Sage', roster: const [Seat('Sage', 'Sage'), Seat('Kid', 'Kid')], cloud: cloud);
      await Uploader(log: host.log, cloud: cloud, ticket: host.ticket, name: 'Sage').drainOnce();
      await svc.join(host.ticket, name: 'Kid', scannedAtMs: DateTime.now().millisecondsSinceEpoch, sharing: false);
      await host.endNight();
      await Uploader(log: host.log, cloud: cloud, ticket: host.ticket, name: 'Sage').drainOnce();
    });
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlayerPadScreen())),
            child: const Text('pad'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('pad'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    expect(find.text('Sage ended the game'), findsOneWidget);
    expect(find.byType(PlayerPadScreen), findsNothing);
    expect(svc.night, isNull, reason: 'left the night');
    await tester.pumpWidget(const SizedBox());
    // The leave keeps uploading for a while (15 s timer): let it finish.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 16));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
  });

  testWidgets('End game night taken back: same table night, joined phones see it resumed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cloud = FakeCloudLogs();
    debugOpenCloud = () async => cloud;
    final m = HomeGameModel(lib);
    final svc = TableNightService.instance;
    late LocalTableSync kid;
    await tester.runAsync(() async {
      await m.load();
      await svc.init(m, store: MemoryStore());
      m.start(name: 'x', players: const ['Sage', 'Kid', 'Bob'], heroSeat: 0, buttonSeat: 0);
      await svc.organize(m.active!);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    final id = svc.night!.nightId;
    final session = m.active!;
    final hands = session.hands.length;
    await tester.runAsync(() async {
      kid = await LocalTableSync.join(MemoryStore(), svc.night!.ticket,
          name: 'Kid', scannedAtMs: DateTime.now().millisecondsSinceEpoch, sharing: false, cloud: cloud);
      m.end();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(svc.night, isNull);
    expect(m.resumable(), same(session));
    await tester.runAsync(() async {
      await kid.refresh();
    });
    expect(kid.organizerEnded, isTrue);
    await tester.runAsync(() async {
      m.resume(session);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      svc.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await kid.refresh();
    });
    expect(m.active, same(session));
    expect(session.hands.length, hands, reason: 'hand count as it was');
    expect(svc.night?.nightId, id, reason: 'the same table night (same QR)');
    expect(svc.linkedTo(session), isTrue);
    expect(kid.organizerEnded, isFalse, reason: 'a resume after the end');
    expect(m.resumable(), isNull, reason: 'nothing to resume while it is playing');
    await tester.runAsync(() async {
      m.end();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 16));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
  });

  testWidgets('offline joiner, host ends, app killed and restarted, back online: all it may share goes up',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cloud = FakeCloudLogs();
    debugOpenCloud = () async => cloud;
    final store = MemoryStore(); // the phone's storage, kept across the restart
    final m = HomeGameModel(lib);
    final first = TableNightService.restarted();
    late LocalTableSync host;
    late String dev;
    await tester.runAsync(() async {
      await m.load();
      await first.init(m, store: store);
      host = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'Sage', selfPid: 'Sage', roster: const [Seat('Sage', 'Sage'), Seat('Kid', 'Kid')], cloud: cloud);
      await Uploader(log: host.log, cloud: cloud, ticket: host.ticket, name: 'Sage').drainOnce();
      cloud.online = false; // the kid's phone has no signal from here on
      final s = await first.join(host.ticket, name: 'Kid', scannedAtMs: DateTime.now().millisecondsSinceEpoch, sharing: false);
      dev = s.deviceId;
      for (var i = 0; i < 3; i++) {
        await s.appendEvent(EventKind.sense, {'w': 15000, 'p': [['H:${host.nightId}', -60, 2]]});
      }
      await s.tap(PreAction.call);
      await s.setCards(const [0, 13]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(cloud.parts[host.nightId]?.keys.where((k) => k.startsWith(dev)) ?? const [], isEmpty,
        reason: 'nothing went up while offline');
    // The host ends the game (the host's phone is online).
    cloud.online = true;
    await tester.runAsync(() async {
      await host.endNight();
      await Uploader(log: host.log, cloud: cloud, ticket: host.ticket, name: 'Sage').drainOnce();
      cloud.online = false;
      // The kid taps Leave (the Bluetooth hint) while still offline, then
      // the app is killed.
      await first.leave();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await first.debugKill();
    });
    // Restart, back online: the outbox drains the left night.
    cloud.online = true;
    final second = TableNightService.restarted();
    // In the test's fake clock, so the 15 s drain timer runs with pump().
    unawaited(second.init(m, store: store));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 16));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    final up = [
      for (final p in cloud.parts[host.nightId]!.values)
        if (p.deviceId == dev) ...p.events
    ].map((e) => e.kind).toList();
    expect(cloud.members[host.nightId]!.keys, contains(dev));
    expect(up.where((k) => k == EventKind.sense), hasLength(3), reason: 'seat signals arrive after the restart');
    expect(up, containsAll([EventKind.join, EventKind.leave]));
    expect(up, isNot(contains(EventKind.play)), reason: 'hands stay private');
    expect(up, isNot(contains(EventKind.cards)));
    expect(cloud.cards[host.nightId] ?? const {}, isEmpty);
    expect(store.get('sync.outbox'), anyOf(isNull, isEmpty), reason: 'done: out of the outbox');
    await tester.runAsync(() => second.debugKill());
  });
}
