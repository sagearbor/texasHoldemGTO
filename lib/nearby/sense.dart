/// Seating experiment (LOG ONLY: nothing here drives the UI). Every phone
/// in a game scans briefly about every 10 seconds and notes how loud each
/// other Felt Notes phone was (RSSI), plus UWB distances between iPhones.
/// The full detail goes to a local JSONL file; about every 15 s a compact
/// summary goes into the table-night log, which uploads with the rest when
/// a connection appears. tool/positioning/ turns it into a seat map
/// offline. Pure Dart.
library;

import 'dart:math' as math;

import 'ble_payload.dart';

/// Median of [xs] (not empty).
double median(List<num> xs) {
  final s = [for (final x in xs) x.toDouble()]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// Per-peer RSSI readings of one scan: peer key -> (readings, tx power).
Map<String, (List<int>, int?)> scanPeers(Iterable<BleSighting> sightings, {String? selfKey}) {
  final out = <String, (List<int>, int?)>{};
  for (final s in sightings) {
    final a = s.advert;
    if (a == null || a.peerKey == selfKey) continue;
    final old = out[a.peerKey];
    out[a.peerKey] = ([...?old?.$1, s.rssi], s.txPower ?? old?.$2);
  }
  return out;
}

/// One scan's line for the JSONL file: every reading per peer.
Map<String, Object?> scanLine(Map<String, (List<int>, int?)> peers, {required int scanMs}) => {
      'scan_ms': scanMs,
      'peers': [
        for (final e in peers.entries)
          {'p': e.key, 'rssi': e.value.$1, if (e.value.$2 != null) 'tx': e.value.$2},
      ],
    };

/// A UWB (Nearby Interaction) reading of one peer.
class UwbSample {
  final String peer;
  final double meters;

  /// Unit vector toward the peer in the phone's frame, when iOS gives one.
  final List<double>? direction;
  final int ms;
  const UwbSample(this.peer, this.meters, this.ms, {this.direction});
}

/// Collects a window of readings (about 15 s in a game) and turns them into one compact event.
class SenseWindow {
  final Map<String, List<int>> _rssi = {};
  final Map<String, int> _tx = {};
  final Map<String, List<double>> _uwb = {};
  final Map<String, List<double>> _dir = {};
  int scans = 0;
  int? startMs;

  bool get isEmpty => scans == 0 && _uwb.isEmpty;

  void addScan(Map<String, (List<int>, int?)> peers, int ms) {
    startMs ??= ms;
    scans++;
    for (final e in peers.entries) {
      (_rssi[e.key] ??= []).addAll(e.value.$1);
      if (e.value.$2 != null) _tx[e.key] = e.value.$2!;
    }
  }

  void addUwb(UwbSample s) {
    startMs ??= s.ms;
    (_uwb[s.peer] ??= []).add(s.meters);
    final d = s.direction;
    if (d != null && d.length == 3) {
      final acc = _dir[s.peer] ??= [0, 0, 0, 0];
      acc[0] += d[0];
      acc[1] += d[1];
      acc[2] += d[2];
      acc[3] += 1;
    }
  }

  /// The table-night `sense` event's data, then empties the window:
  /// `{w, n, p: [[peer, median dBm, readings, tx?]], u: [[peer, median cm,
  /// readings, mean direction x100?]]}` plus the [extra] phone state.
  Map<String, Object?> take(int nowMs, {Map<String, Object?> extra = const {}}) {
    final out = <String, Object?>{
      'w': startMs == null ? 0 : nowMs - startMs!,
      'n': scans,
      'p': [
        for (final e in _rssi.entries)
          [e.key, median(e.value).round(), e.value.length, if (_tx[e.key] != null) _tx[e.key]],
      ],
      if (_uwb.isNotEmpty)
        'u': [
          for (final e in _uwb.entries)
            [
              e.key,
              (median(e.value) * 100).round(),
              e.value.length,
              if (_dir[e.key] != null) _meanDir(_dir[e.key]!),
            ],
        ],
      ...extra,
    };
    _rssi.clear();
    _tx.clear();
    _uwb.clear();
    _dir.clear();
    scans = 0;
    startMs = null;
    return out;
  }

  static List<int> _meanDir(List<double> acc) {
    final n = acc[3];
    final x = acc[0] / n, y = acc[1] / n, z = acc[2] / n;
    final len = math.sqrt(x * x + y * y + z * z);
    if (len == 0) return const [0, 0, 0];
    return [(x / len * 100).round(), (y / len * 100).round(), (z / len * 100).round()];
  }
}

/// UWB readings come at up to 10 a second; the JSONL keeps at most one per
/// peer per [gapMs].
class UwbThrottle {
  final int gapMs;
  final Map<String, int> _last = {};
  UwbThrottle({this.gapMs = 1000});

  bool keep(UwbSample s) {
    final l = _last[s.peer];
    if (l != null && s.ms - l < gapMs) return false;
    _last[s.peer] = s.ms;
    return true;
  }
}
