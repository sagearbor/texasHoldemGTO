// The app-wide service with a cloud behind it (FakeCloudLogs through the
// openCloud seam): hosting creates the night in the cloud and the host's
// table bookkeeping goes up; a private joiner still becomes a member and
// its Bluetooth seat readings go up while its taps and cards stay home; a
// cloud that fails to start is picked up later instead of never.

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/sync/cloud_config.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/table_night_service.dart';
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
}
