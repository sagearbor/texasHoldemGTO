// Pulse mode, pure parts: the simulated player, profile / song parsing,
// the selfie square, chunk encoding, the 15-second batched upload against
// the fake cloud (membership, one write per window, wipe on off), the
// TV board (leader), the song rule with a fake clock, and the summary.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:felt_notes/pulse/pulse_board.dart';
import 'package:felt_notes/pulse/pulse_cloud.dart';
import 'package:felt_notes/pulse/pulse_profile.dart';
import 'package:felt_notes/pulse/pulse_protocol.dart';
import 'package:felt_notes/pulse/pulse_source.dart';
import 'package:felt_notes/pulse/pulse_uploader.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const song = PulseSong(
  trackId: 1440833098,
  title: 'Eye of the Tiger',
  artist: 'Survivor',
  previewUrl: 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview/x.m4a',
  artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/x/200x200bb.jpg',
  trackViewUrl: 'https://music.apple.com/us/album/eye-of-the-tiger/1440832818?i=1440833098',
);

PulseMember mem(String id, {PulseSong? s}) => PulseMember(deviceId: id, name: id, song: s);

/// [n] samples a second apart from [t], bpm from [f].
List<PulseSample> run(int t, int n, int Function(int i) f) => [for (var i = 0; i < n; i++) PulseSample(t + i * 1000, f(i))];

void main() {
  final t0 = DateTime.utc(2026, 11, 7, 20).millisecondsSinceEpoch;

  group('simulated player', () {
    test('about 70 at rest, plausible, one a second, spikes sometimes', () {
      var now = t0;
      final sim = SimulatedPulseSource(rng: Random(7), now: () => now, spikeChance: 1 / 60);
      final all = <PulseSample>[];
      for (var i = 0; i < 1800; i++) {
        now += 2000;
        all.addAll(sim.samplesUntil(now));
      }
      expect(all.length, closeTo(3600, 2));
      expect(PulseFilter().keep(all).length, all.length, reason: 'every sample passes the filter');
      final bpm = [for (final s in all) s.bpm]..sort();
      expect(bpm[bpm.length ~/ 2], inInclusiveRange(62, 80), reason: 'median near resting');
      expect(bpm.last, greaterThan(90), reason: 'at least one spike in an hour');
    });

    test('start sends state then samples every 2 s', () async {
      final sim = SimulatedPulseSource(rng: Random(1), every: const Duration(milliseconds: 10));
      final got = <PulseMessage>[];
      final sub = sim.messages.listen(got.add);
      await sim.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await sim.stop();
      await sub.cancel();
      expect(got.first, isA<PulseState>());
      expect((got.first as PulseState).running, isTrue);
      expect((got.last as PulseState).running, isFalse);
      expect((await sim.status()).reachable, isTrue);
      sim.dispose();
    });
  });

  group('profile and songs', () {
    test('iTunes results: Apple URLs only, with a preview', () {
      final body = jsonEncode({
        'resultCount': 3,
        'results': [
          {
            'trackId': 1440833098,
            'trackName': 'Eye of the Tiger',
            'artistName': 'Survivor',
            'previewUrl': 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview/x.m4a',
            'artworkUrl100': 'https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg',
            'trackViewUrl': 'https://music.apple.com/us/album/x?i=1',
          },
          {'trackId': 2, 'trackName': 'No preview', 'artistName': 'X'},
          {
            'trackId': 3,
            'trackName': 'Evil',
            'artistName': 'X',
            'previewUrl': 'https://evil.example.com/a.m4a',
            'artworkUrl100': 'https://is1-ssl.mzstatic.com/a.jpg',
            'trackViewUrl': 'https://music.apple.com/x',
          },
        ]
      });
      final r = parseItunes(body);
      expect(r.length, 1);
      expect(r.single.title, 'Eye of the Tiger');
      expect(r.single.artworkUrl, contains('200x200bb'));
      expect(parseItunes('garbage'), isEmpty);
      expect(itunesSearchUri('eye of the tiger').toString(),
          'https://itunes.apple.com/search?term=eye+of+the+tiger&entity=song&limit=10');
    });

    test('profile round trip, initials', () {
      final p = PulseProfile(name: 'Sage Arbor', face: Uint8List.fromList([1, 2, 3]), song: song);
      final q = PulseProfile.fromJson(jsonDecode(jsonEncode(p.toJson())))!;
      expect(q.name, 'Sage Arbor');
      expect(q.face, [1, 2, 3]);
      expect(q.song, song);
      expect(initialsOf('Sage Arbor'), 'SA');
      expect(initialsOf(' joe '), 'J');
      expect(initialsOf(''), '?');
      expect(PulseSong.fromJson({...song.toJson(), 'previewUrl': 'http://audio-ssl.itunes.apple.com/x'}), isNull);
    });

    test('selfie: centre square, 96x96 JPEG, a few KB', () {
      final photo = img.Image(width: 640, height: 480);
      for (final px in photo) {
        px
          ..r = px.x % 256
          ..g = px.y % 256
          ..b = (px.x * px.y) % 256;
      }
      final face = squareFace(img.encodeJpg(photo, quality: 90))!;
      final back = img.decodeJpg(face)!;
      expect((back.width, back.height), (96, 96));
      expect(face.length, lessThan(12000));
      expect(base64Encode(face).length, lessThanOrEqualTo(faceMaxChars));
      expect(squareFace(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  test('chunks: flat [ms into chunk, bpm] round trip', () {
    final c = chunkOf(t0 + 5000);
    final s = run(t0 + 5000, 3, (i) => 70 + i).where((x) => chunkOf(x.tMs) == c).toList();
    final enc = encodeChunk(c, s);
    expect(enc.length, s.length * 2);
    expect(enc.every((x) => x >= 0 && x < chunkMs || x < 300), isTrue);
    expect(decodeChunk(c, enc), s);
  });

  group('upload', () {
    late FakeCloudLogs logs;
    late FakePulseCloud cloud;
    late int now;
    const night = 'ABCD2345', dev = 'AMYPHNE23456';
    var joins = 0;

    PulseUploader up() => PulseUploader(
          cloud: cloud,
          nightId: night,
          deviceId: dev,
          now: () => now,
          profile: () => const PulseProfile(name: 'Amy', song: song),
          ensureJoined: () async {
            joins++;
            await logs.join(const JoinTicket(nightId: night, secret: 'WXYZ6789', organizerName: 'Sage'),
                deviceId: dev, name: 'Amy');
          },
        );

    setUp(() {
      now = t0;
      joins = 0;
      logs = FakeCloudLogs(clock: () => now);
      cloud = FakePulseCloud(logs: logs);
    });

    test('a non-member cannot write', () async {
      expect(() => cloud.putChunk(night, const PulseChunk(dev, 1, [])), throwsStateError);
    });

    test('one write per window; nothing new, nothing written', () async {
      final u = up();
      u.add(run(t0, 15, (i) => 70));
      expect(await u.flush(), isTrue);
      expect(joins, 1);
      expect(cloud.writes, 2, reason: 'identity once + one chunk');
      expect(await u.flush(), isTrue);
      expect(cloud.writes, 2, reason: 'nothing new');
      for (var w = 0; w < 8; w++) {
        u.add(run(t0 + 15000 * (w + 1), 15, (i) => 72));
        await u.flush();
      }
      // 2 minutes = 8 windows: 8 more writes (one is 2 if a 10-minute
      // boundary falls inside a window).
      expect(cloud.writes, inInclusiveRange(10, 11));
      final n = await cloud.fetch(night);
      expect(n.samples[dev]!.length, 15 * 9);
      expect(n.members[dev]!.song, song);
    });

    test('offline: kept, sent when back', () async {
      final u = up();
      cloud.online = false;
      u.add(run(t0, 15, (i) => 70));
      expect(await u.flush(), isFalse);
      expect(u.lastError, isNotNull);
      cloud.online = true;
      u.add(run(t0 + 15000, 15, (i) => 70));
      expect(await u.flush(), isTrue);
      expect((await cloud.fetch(night)).samples[dev]!.length, 30);
    });

    test('a window crossing a 10-minute boundary writes both chunks', () async {
      final u = up();
      final edge = (chunkOf(t0) + 1) * chunkMs;
      u.add(run(edge - 7000, 15, (i) => 80));
      await u.flush();
      expect(cloud.chunks[night]!.length, 2);
      expect((await cloud.fetch(night)).samples[dev]!.length, 15);
    });

    test('wipe: every chunk and the identity are gone; the TV shows nothing', () async {
      final u = up();
      u.start();
      u.add(run(t0, 700, (i) => 70)); // spans two chunks
      await u.flush();
      expect(cloud.chunks[night]!.length, greaterThanOrEqualTo(2));
      expect(await u.wipe(), isTrue);
      expect(u.running, isFalse);
      expect(cloud.chunks[night], isEmpty);
      expect(cloud.members[night], isEmpty);
      expect((await cloud.fetch(night)).hasData, isFalse);
    });

    test('data without an identity is not shown', () {
      final n = PulseNight.from([mem('A')], [PulseChunk('A', 1, run(chunkMs, 2, (_) => 70)), PulseChunk('B', 1, run(chunkMs, 2, (_) => 90))]);
      expect(n.samples.keys, ['A']);
    });
  });

  group('board', () {
    PulseNight night(Map<String, List<PulseSample>> s, {Map<String, PulseSong?> songs = const {}}) =>
        PulseNight(members: {for (final k in s.keys) k: mem(k, s: songs[k])}, samples: s);

    test('leader: strictly above every other live player', () {
      expect(leaderOf({'a': 80, 'b': 90}), 'b');
      expect(leaderOf({'a': 90, 'b': 90}), isNull);
      expect(leaderOf({'a': 75}), 'a');
      expect(leaderOf({}), isNull);
    });

    test('last 10 minutes, stale players are not live, colours by first beat', () {
      final now = t0 + 20 * 60000;
      final n = night({
        'late': run(now - 60000, 60, (_) => 100),
        'early': run(t0, 20 * 60, (_) => 70),
        'gone': run(t0, 5 * 60, (_) => 120), // stopped 15 min ago
      });
      final b = buildPulseBoard(n, nowMs: now);
      expect(b.lines.map((l) => l.deviceId), ['early', 'late'], reason: '"gone" has nothing in the window');
      expect(b.lines.first.colour, 0);
      expect(b.lines.first.visible.first.tMs, greaterThanOrEqualTo(now - chartSpanMs));
      expect(b.leader, 'late');
      expect(b.minBpm, lessThanOrEqualTo(65));
      expect(b.maxBpm, greaterThanOrEqualTo(105));
    });
  });

  group('songs: 10 s lead, then 2 minutes before any song', () {
    PulseBoard board(String? leader, {bool withSong = true}) => PulseBoard(
          fromMs: 0,
          toMs: 0,
          leader: leader,
          lines: [
            for (final id in ['a', 'b'])
              PulseLine(member: mem(id, s: withSong ? song : null), colour: 0, visible: const [], bpm: 80, leader: id == leader),
          ],
        );

    test('plays after 10 s of lead, once, then cooldown', () {
      final dj = SongDj();
      var t = 0;
      expect(dj.tick(t, board('a')), isNull);
      t += 9000;
      expect(dj.tick(t, board('a')), isNull, reason: '9 s is not 10');
      t += 1000;
      expect(dj.tick(t, board('a'))!.deviceId, 'a');
      t += 1000;
      expect(dj.tick(t, board('a')), isNull, reason: 'once per lead');
      // b takes over and leads 30 s: still in the cooldown.
      for (var i = 0; i < 30; i++) {
        t += 1000;
        expect(dj.tick(t, board('b')), isNull);
      }
      t = 10000 + songCooldownMs - 1000;
      expect(dj.tick(t, board('b')), isNull);
      t += 1000;
      expect(dj.tick(t, board('b'))!.deviceId, 'b');
    });

    test('a lead change restarts the 10 s; no song, no cooldown', () {
      final dj = SongDj();
      dj.tick(0, board('a'));
      dj.tick(6000, board('b'));
      expect(dj.tick(12000, board('b')), isNull, reason: 'b has led 6 s');
      expect(dj.tick(16000, board('b')), isNotNull);
      final quiet = SongDj();
      quiet.tick(0, board('a', withSong: false));
      expect(quiet.tick(20000, board('a', withSong: false)), isNull);
      expect(quiet.lastStartMs, isNull);
      expect(quiet.tick(21000, board('b')), isNull, reason: 'new lead');
      expect(quiet.tick(31000, board('b')), isNotNull);
    });

    test('a tie is nobody: the clock restarts', () {
      final dj = SongDj();
      dj.tick(0, board('a'));
      dj.tick(5000, board(null));
      dj.tick(6000, board('a'));
      expect(dj.tick(15000, board('a')), isNull);
      expect(dj.tick(16000, board('a')), isNotNull);
    });
  });

  group('summary', () {
    test('calmest above own resting, biggest spike with hand, highest', () {
      // Amy: resting 60, average about 61 -> very calm.
      final amy = run(t0, 600, (i) => i % 10 == 0 ? 65 : 60);
      // Bob: resting 80 but jumps from 80 to 130 in 20 s at minute 5.
      final bob = run(t0, 600, (i) => i >= 300 && i < 320 ? 80 + (i - 300) * 50 ~/ 19 : 80);
      // Cy: high but steady (resting 100).
      final cy = run(t0, 600, (i) => i < 300 ? 100 : 140);
      final n = PulseNight(members: {'amy': mem('amy'), 'bob': mem('bob'), 'cy': mem('cy')}, samples: {'amy': amy, 'bob': bob, 'cy': cy});
      final s = pulseSummary(n, handAt: handFinder([(22, t0, t0 + 290000), (23, t0 + 290000, t0 + 400000)]));
      expect(s.calmest!.member.deviceId, 'amy');
      expect(s.calmest!.value, closeTo(0.5, 0.01));
      expect(s.spike!.member.deviceId, 'bob');
      expect(s.spike!.value, 50);
      expect(s.spike!.from, 80);
      expect(s.spike!.hand, 23);
      expect(s.highest!.member.deviceId, 'cy');
      expect(s.highest!.value, 140);
      expect(s.highest!.hand, 23);
    });

    test('a spike is measured against the minute before, not the whole night', () {
      // Slowly from 60 to 120 over 30 minutes: no minute rises more than ~3.
      final s = run(t0, 1800, (i) => 60 + i ~/ 30);
      final r = pulseSummary(PulseNight(members: {'a': mem('a')}, samples: {'a': s}));
      expect(r.spike!.value, lessThanOrEqualTo(3));
      expect(r.calmest, isNotNull);
    });

    test('too little data: no calmest; nothing at all: empty', () {
      final r = pulseSummary(PulseNight(members: {'a': mem('a')}, samples: {'a': run(t0, 10, (_) => 70)}));
      expect(r.calmest, isNull);
      expect(r.highest!.value, 70);
      expect(pulseSummary(PulseNight.empty).isEmpty, isTrue);
    });
  });
}
