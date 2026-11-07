// Pulse on the TV page: the chart with a face per player and a crown on
// the leader at TV and phone sizes, the leader's song after 10 s (and the
// "Tap to enable sound" button when the player is blocked), and the
// summary after the End.

import 'dart:convert';

import 'package:felt_notes/pulse/pulse_cloud.dart';
import 'package:felt_notes/pulse/pulse_firestore.dart';
import 'package:felt_notes/pulse/pulse_profile.dart';
import 'package:felt_notes/pulse/pulse_protocol.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:felt_notes/ui/pulse/song_player.dart';
import 'package:felt_notes/ui/tv/tv_controller.dart';
import 'package:felt_notes/ui/tv/tv_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

const song = PulseSong(
  trackId: 1440833098,
  title: 'Eye of the Tiger',
  artist: 'Survivor',
  previewUrl: 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview/x.m4a',
  artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/x/200x200bb.jpg',
  trackViewUrl: 'https://music.apple.com/us/album/x?i=1440833098',
);

class FakePlayer implements SongPlayer {
  bool allow = true;
  final played = <String>[];
  @override
  Future<bool> play(String url) async {
    if (!allow) return false;
    played.add(url);
    return true;
  }

  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
}

class Night {
  int ms = DateTime.utc(2026, 11, 7, 21).millisecondsSinceEpoch;
  late final FakeCloudLogs cloud = FakeCloudLogs(clock: () => ms);
  late final FakePulseCloud pulse = FakePulseCloud(logs: cloud);
  late LocalTableSync host;
  final players = <LocalTableSync>[];

  Future<void> setUp({int n = 3}) async {
    host = await LocalTableSync.organize(MemoryStore(), organizerName: 'Sage', selfPid: 'host', now: () => ms, cloud: cloud);
    await host.setSeats(const [Seat('host', 'Sage')]); // as startPulseNight does
    await Uploader(log: host.log, cloud: cloud, ticket: host.ticket, name: 'Sage', now: () => ms).drainOnce();
    final face = squareFace(img.encodeJpg(img.Image(width: 200, height: 150)..clear(img.ColorRgb8(200, 120, 80))))!;
    for (var i = 0; i < n; i++) {
      final name = ['Amy', 'Bob', 'Cy', 'Di'][i];
      final p = await LocalTableSync.join(MemoryStore(), host.qrTicket(),
          name: name, scannedAtMs: ms, sharing: false, now: () => ms, cloud: cloud);
      await cloud.join(p.ticket, deviceId: p.deviceId, name: name);
      await pulse.putMember(p.nightId, p.deviceId,
          PulseProfile(name: name, face: i == 0 ? face : null, song: i == 1 ? song : null));
      players.add(p);
    }
  }

  /// Ten minutes of heart rate up to now: Bob runs highest.
  Future<void> beats() async {
    for (var i = 0; i < players.length; i++) {
      final base = [70, 95, 80, 60][i];
      final s = [for (var t = ms - 600000; t <= ms; t += 1000) PulseSample(t, base + (t ~/ 1000) % 7)];
      final byChunk = <int, List<PulseSample>>{};
      for (final x in s) {
        byChunk.putIfAbsent(chunkOf(x.tMs), () => []).add(x);
      }
      for (final c in byChunk.entries) {
        await pulse.putChunk(players[i].nightId, PulseChunk(players[i].deviceId, c.key, c.value));
      }
    }
  }
}

void main() {
  setUp(() => debugPulseCloudFor = null);
  tearDown(() => debugPulseCloudFor = null);

  Future<(Night, TvController, FakePlayer)> live(WidgetTester tester, Size size, {bool allow = true}) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final n = Night();
    await tester.runAsync(() async {
      await n.setUp();
      await n.beats();
    });
    debugPulseCloudFor = (_) => n.pulse;
    final c = TvController(n.host.ticket, now: () => n.ms, open: () async => n.cloud);
    final player = FakePlayer()..allow = allow;
    await tester.pumpWidget(MaterialApp(home: TvScreen(ticket: n.host.ticket, controller: c, songPlayer: player)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return (n, c, player);
  }

  for (final size in const [Size(1920, 1080), Size(1280, 720), Size(390, 844)]) {
    testWidgets('chart at ${size.width.toInt()}x${size.height.toInt()}: faces, crown, bpm, no overflow', (tester) async {
      final (n, c, _) = await live(tester, size);
      expect(c.pulse.hasData, isTrue);
      expect(find.byKey(const Key('pulse-chart')), findsOneWidget);
      for (final p in n.players) {
        expect(find.byKey(ValueKey('pulse-face-${p.deviceId}')), findsOneWidget);
      }
      expect(find.byKey(const Key('pulse-crown')), findsOneWidget, reason: 'Bob leads');
      expect(find.text('Bob'), findsWidgets, reason: 'legend');
      expect(find.text('SA'), findsNothing);
      expect(find.text('B'), findsOneWidget, reason: "Bob's initials (no selfie)");
      final chart = tester.getRect(find.byKey(const Key('pulse-chart')));
      expect(chart.right, lessThanOrEqualTo(size.width));
      expect(chart.height, greaterThan(250));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets("the leader's song after 10 s, with the chip and the Apple Music link", (tester) async {
    final (n, c, player) = await live(tester, const Size(1920, 1080));
    for (var i = 0; i < 9; i++) {
      n.ms += 1000;
      await tester.pump(const Duration(seconds: 1));
    }
    expect(player.played, isEmpty, reason: 'not 10 s yet');
    for (var i = 0; i < 3; i++) {
      n.ms += 1000;
      await tester.pump(const Duration(seconds: 1));
    }
    expect(player.played, [song.previewUrl]);
    expect(find.byKey(const Key('pulse-now-playing')), findsOneWidget);
    expect(find.text('Listen on Apple Music'), findsOneWidget);
    expect(find.textContaining('Eye of the Tiger'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('blocked sound: "Tap to enable sound" plays it from the tap', (tester) async {
    final (n, c, player) = await live(tester, const Size(1280, 720), allow: false);
    for (var i = 0; i < 12; i++) {
      n.ms += 1000;
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byKey(const Key('pulse-enable-sound')), findsOneWidget);
    player.allow = true;
    await tester.tap(find.byKey(const Key('pulse-enable-sound')));
    await tester.pump();
    expect(player.played, [song.previewUrl]);
    expect(find.byKey(const Key('pulse-enable-sound')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  for (final size in const [Size(1920, 1080), Size(390, 844)]) {
    testWidgets('after the End: the summary at ${size.width.toInt()}', (tester) async {
      final (n, c, _) = await live(tester, size);
      await tester.runAsync(() async {
        await n.host.endNight();
        await Uploader(log: n.host.log, cloud: n.cloud, ticket: n.host.ticket, name: 'Sage', now: () => n.ms).drainOnce();
      });
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(c.board!.ended, isTrue);
      expect(find.byKey(const Key('pulse-summary')), findsOneWidget);
      expect(find.text('Highest heart rate'), findsOneWidget);
      expect(find.text('Calmest player'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  test('song URLs from the cloud are checked again before playing', () async {
    expect(await AudioSongPlayer().play('https://evil.example.com/a.m4a'), isFalse);
    expect(jsonEncode(song.toJson()), contains('itunes.apple.com'));
  });
}
