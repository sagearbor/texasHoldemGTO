/// The cloud side of Pulse mode, as an interface (Firestore:
/// pulse_firestore.dart), and an in-memory fake for tests.
///
/// Layout (firestore.rules):
///   nights/{nightId}/pulse/{deviceId}               {uid, deviceId, name, face?, song?, updatedAt, expireAt}
///   nights/{nightId}/pulseData/{deviceId}_{chunk}   {uid, deviceId, chunk, s, updatedAt, expireAt}
/// `pulse`: once per player per night, written when they turn Pulse on
/// (selfie as base64 JPEG, song as {trackId, title, artist, previewUrl,
/// artworkUrl, trackViewUrl}). `pulseData`: one document per player per
/// [chunkMs] of heart rate, rewritten whole by the 15-second upload (one
/// write per window; a window that straddles two chunks writes both).
/// `s` is flat: [ms into the chunk, bpm, ms, bpm, ...].
///
/// Everything has `expireAt` and lives under the night, so it goes with
/// the night (tool/sweep_expired_nights.sh deletes nights recursively).
/// Turning Pulse off deletes that player's documents at once.
library;

import 'dart:async';
import 'dart:math';

import '../sync/cloud_logs.dart';
import 'pulse_profile.dart';
import 'pulse_protocol.dart';

/// One `pulseData` document covers this much time (10 minutes).
const chunkMs = 10 * 60000;

/// firestore.rules: at most this many numbers in `s` (two per sample: 20
/// minutes' worth at one sample a second, room for 2 a second).
const chunkMaxNumbers = 2400;

int chunkOf(int tMs) => tMs ~/ chunkMs;

String pulseDataId(String deviceId, int chunk) => '${deviceId}_$chunk';

List<int> encodeChunk(int chunk, Iterable<PulseSample> samples) {
  final t0 = chunk * chunkMs;
  return [
    for (final s in samples) ...[s.tMs - t0, s.bpm]
  ];
}

List<PulseSample> decodeChunk(int chunk, List<Object?> s) {
  final t0 = chunk * chunkMs;
  return [
    for (var i = 0; i + 1 < s.length; i += 2)
      if (s[i] is int && s[i + 1] is int) PulseSample(t0 + (s[i] as int), s[i + 1] as int)
  ];
}

/// One player's Pulse identity in a night, as the TV reads it.
class PulseMember {
  final String deviceId;
  final String name;
  final String? faceB64;
  final PulseSong? song;
  const PulseMember({required this.deviceId, required this.name, this.faceB64, this.song});
}

class PulseChunk {
  final String deviceId;
  final int chunk;
  final List<PulseSample> samples;
  const PulseChunk(this.deviceId, this.chunk, this.samples);
}

/// Everything Pulse in a night.
class PulseNight {
  final Map<String, PulseMember> members;

  /// deviceId -> samples, oldest first, only for [members].
  final Map<String, List<PulseSample>> samples;

  const PulseNight({this.members = const {}, this.samples = const {}});

  static const empty = PulseNight();

  bool get hasData => samples.values.any((s) => s.isNotEmpty);

  factory PulseNight.from(Iterable<PulseMember> members, Iterable<PulseChunk> chunks) {
    final m = {for (final x in members) x.deviceId: x};
    final s = <String, List<PulseSample>>{};
    for (final c in chunks) {
      // Data without a member doc is a player who turned Pulse off while
      // a delete was in flight: not shown.
      if (!m.containsKey(c.deviceId)) continue;
      s.putIfAbsent(c.deviceId, () => []).addAll(c.samples);
    }
    for (final l in s.values) {
      l.sort((a, b) => a.tMs.compareTo(b.tMs));
    }
    return PulseNight(members: m, samples: s);
  }
}

abstract class PulseCloud {
  /// This phone's Pulse identity in the night (name, selfie, song).
  Future<void> putMember(String nightId, String deviceId, PulseProfile p);

  /// One chunk of this phone's samples, whole.
  Future<void> putChunk(String nightId, PulseChunk c);

  /// This phone's Pulse identity and every chunk (Pulse turned off).
  Future<void> deleteMine(String nightId, String deviceId);

  Future<PulseNight> fetch(String nightId);

  /// Live: the TV listens.
  Stream<PulseNight> watch(String nightId);
}

/// In-memory [PulseCloud] for tests. Membership comes from [logs] (the
/// night's [FakeCloudLogs]) when given, as the rules check it; counts
/// billed operations.
class FakePulseCloud implements PulseCloud {
  final FakeCloudLogs? logs;
  bool online = true;
  final Map<String, Map<String, PulseMember>> members = {};
  final Map<String, Map<String, PulseChunk>> chunks = {};
  int reads = 0, writes = 0, deletes = 0;
  final _changes = StreamController<String>.broadcast(sync: true);

  FakePulseCloud({this.logs});

  void _check(String nightId, String deviceId) {
    if (!online) throw StateError('offline');
    final l = logs;
    if (l != null && !(l.members[nightId]?.containsKey(deviceId) ?? false)) throw StateError('not a member');
  }

  @override
  Future<void> putMember(String nightId, String deviceId, PulseProfile p) async {
    _check(nightId, deviceId);
    if ((p.faceB64?.length ?? 0) > faceMaxChars) throw StateError('face too big');
    writes++;
    members.putIfAbsent(nightId, () => {})[deviceId] =
        PulseMember(deviceId: deviceId, name: p.name, faceB64: p.faceB64, song: p.song);
    _changes.add(nightId);
  }

  @override
  Future<void> putChunk(String nightId, PulseChunk c) async {
    _check(nightId, c.deviceId);
    if (c.samples.length * 2 > chunkMaxNumbers) throw StateError('chunk too big');
    if (c.samples.any((s) => chunkOf(s.tMs) != c.chunk)) throw StateError('sample outside its chunk');
    writes++;
    chunks.putIfAbsent(nightId, () => {})[pulseDataId(c.deviceId, c.chunk)] = c;
    _changes.add(nightId);
  }

  @override
  Future<void> deleteMine(String nightId, String deviceId) async {
    _check(nightId, deviceId);
    final mine = chunks[nightId]?.values.where((c) => c.deviceId == deviceId).toList() ?? const [];
    reads += max(1, mine.length);
    for (final c in mine) {
      chunks[nightId]!.remove(pulseDataId(deviceId, c.chunk));
      deletes++;
    }
    if (members[nightId]?.remove(deviceId) != null) deletes++;
    _changes.add(nightId);
  }

  PulseNight _night(String nightId) =>
      PulseNight.from(members[nightId]?.values ?? const [], chunks[nightId]?.values ?? const []);

  @override
  Future<PulseNight> fetch(String nightId) async {
    if (!online) throw StateError('offline');
    reads += max(1, (members[nightId]?.length ?? 0) + (chunks[nightId]?.length ?? 0));
    return _night(nightId);
  }

  @override
  Stream<PulseNight> watch(String nightId) async* {
    yield await fetch(nightId);
    await for (final n in _changes.stream) {
      if (n == nightId && online) {
        reads++;
        yield _night(nightId);
      }
    }
  }
}
