// Pulse on a phone: off by default per night; on reads the watch and
// uploads in 15-second batches; off stops and deletes (retried while
// offline); a new night starts off again.

import 'dart:async';

import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/pulse/pulse_board.dart';
import 'package:felt_notes/pulse/pulse_cloud.dart';
import 'package:felt_notes/pulse/pulse_firestore.dart';
import 'package:felt_notes/pulse/pulse_profile.dart';
import 'package:felt_notes/pulse/pulse_protocol.dart';
import 'package:felt_notes/pulse/pulse_service.dart';
import 'package:felt_notes/pulse/pulse_source.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A watch the test drives by hand.
class ManualWatch implements PulseSource {
  final out = StreamController<PulseMessage>.broadcast(sync: true);
  int starts = 0, stops = 0;
  @override
  Stream<PulseMessage> get messages => out.stream;
  @override
  Future<WatchStatus> status() async =>
      const WatchStatus(supported: true, paired: true, appInstalled: false, reachable: false);
  @override
  Future<bool> start() async {
    starts++;
    return true;
  }

  @override
  Future<bool> stop() async {
    stops++;
    return true;
  }

  @override
  Future<bool> openWatchStore() async => true;
  @override
  void dispose() {}
}

void main() {
  late int now;
  late FakeCloudLogs logs;
  late FakePulseCloud pulse;
  late ManualWatch watch;
  late PulseService svc;
  late LocalTableSync host, amy;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PulseProfileStore.debugReset();
    now = DateTime.utc(2026, 11, 7, 20).millisecondsSinceEpoch;
    logs = FakeCloudLogs(clock: () => now);
    pulse = FakePulseCloud(logs: logs);
    debugPulseCloudFor = (c) => c == null ? null : pulse;
    watch = ManualWatch();
    svc = PulseService.forTest(source: () => watch, now: () => now, window: const Duration(hours: 1));
    host = await LocalTableSync.organize(MemoryStore(), organizerName: 'Sage', selfPid: 'host', now: () => now, cloud: logs);
    amy = await LocalTableSync.join(MemoryStore(), host.qrTicket(),
        name: 'Amy', scannedAtMs: now, sharing: false, now: () => now, cloud: logs);
    await PulseProfileStore.save(const PulseProfile(name: 'Amy'));
  });

  tearDown(() => debugPulseCloudFor = null);

  void beats(int n, int bpm) {
    watch.out.add(PulseHr([for (var i = 0; i < n; i++) PulseSample(now + i * 1000, bpm)]));
    now += n * 1000;
  }

  test('off by default: the watch is not read, nothing goes up', () async {
    await svc.follow(amy);
    expect(svc.on, isFalse);
    expect(watch.starts, 0);
    beats(5, 70);
    expect(await svc.flush(), isFalse);
    expect(pulse.writes, 0);
    expect(svc.statusLine(), contains('stays on this phone'));
  });

  test('on: reads, filters, uploads its identity and the batch', () async {
    await svc.follow(amy);
    await svc.setOn(true);
    expect(watch.starts, 1);
    expect(svc.status.paired, isTrue);
    beats(15, 72);
    watch.out.add(const PulseHr([PulseSample(0, 72), PulseSample(1, 300)])); // old + bad
    expect(svc.bpm, 72);
    expect(svc.mySamples.length, 15);
    expect(await svc.flush(), isTrue);
    final n = await pulse.fetch(amy.nightId);
    expect(n.members[amy.deviceId]!.name, 'Amy');
    expect(n.samples[amy.deviceId]!.length, 15);
    expect(logs.members[amy.nightId]!.containsKey(amy.deviceId), isTrue, reason: 'joined first');
    expect(svc.statusLine(), contains('Sharing with the table'));
  });

  test('off: stops the watch and deletes what was sent', () async {
    await svc.follow(amy);
    await svc.setOn(true);
    beats(15, 72);
    await svc.flush();
    await svc.setOn(false);
    await pumpEventQueue();
    expect(watch.stops, 1);
    expect(pulse.chunks[amy.nightId], isEmpty);
    expect(pulse.members[amy.nightId], isEmpty);
    expect(svc.cleanupPending, isFalse);
    beats(5, 80);
    expect(svc.bpm, 72, reason: 'no longer listening');
  });

  test('off while offline: the delete is owed and retried', () async {
    await svc.follow(amy);
    await svc.setOn(true);
    beats(15, 72);
    await svc.flush();
    pulse.online = false;
    await svc.setOn(false);
    await pumpEventQueue();
    expect(svc.cleanupPending, isTrue);
    expect(svc.statusLine(), contains('Deleting'));
    pulse.online = true;
    // A restart (or the 30 s retry) finishes it.
    final again = PulseService.forTest(source: () => watch, now: () => now);
    await again.follow(amy);
    await pumpEventQueue();
    expect(pulse.chunks[amy.nightId], isEmpty);
    expect(again.cleanupPending, isFalse);
  });

  test('per night: a new night starts off; the old one keeps its switch', () async {
    await svc.follow(amy);
    await svc.setOn(true);
    final other = await LocalTableSync.organize(MemoryStore(), organizerName: 'Joe', selfPid: 'host', now: () => now, cloud: logs);
    await svc.follow(other);
    expect(svc.on, isFalse);
    await svc.follow(amy);
    expect(svc.on, isTrue, reason: 'remembered in the night log');
  });

  test('host recap: hand spans from the session, the last runs 8 minutes', () {
    LoggedHand h(int n, int? start) => LoggedHand(number: n, cards: null, position: 'BTN', ts: 0, start: start);
    final s = HomeSession(
        id: 's', name: 'n', started: 0, players: const ['Sage'], heroSeat: 0, buttonSeat: 0,
        hands: [h(2, 5000), h(1, 1000), h(3, null)]);
    expect(sessionHandSpans(s), [(1, 1000, 5000), (2, 5000, 5000 + 8 * 60000)]);
    final at = handFinder(sessionHandSpans(s));
    expect((at(999), at(1000), at(4999), at(5000)), (null, 1, 1, 2));
  });
}
