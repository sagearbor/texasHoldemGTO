/// Bluetooth distance test (Settings → Diagnostics): the pure parts. Two or
/// more phones with the screen open advertise and scan without pause; the
/// owner puts them a known distance apart, picks how they lie, and records
/// 60 seconds. Every raw advert becomes one JSONL line, and
/// tool/positioning/calibrate.py fits the path-loss model per phone pair
/// from those files. Nothing here is shown during a game.
library;

import 'dart:math' as math;

import 'sense.dart' as sense;

/// How the phones lay during a run.
enum Placement { tableUp, tableDown, pocket, held }

const placementLabels = {
  Placement.tableUp: 'On table, face up',
  Placement.tableDown: 'On table, face down',
  Placement.pocket: 'In pocket',
  Placement.held: 'Held in hand',
};

/// The distance stepper: 0.25 m steps from 0.25 to 5 m.
const distanceStep = 0.25, distanceMin = 0.25, distanceMax = 5.0;

double stepDistance(double d, int dir) =>
    (((d + dir * distanceStep) / distanceStep).round() * distanceStep).clamp(distanceMin, distanceMax).toDouble();

/// One peer's recent readings: the latest, a rolling median over the last
/// [windowMs], and readings per second over that window.
class RollingRssi {
  final int windowMs;
  final List<(int, int)> _s = [];
  int? latest;
  int? latestMs;
  int total = 0;
  RollingRssi({this.windowMs = 10000});

  void add(int ms, int rssi) {
    _s.add((ms, rssi));
    latest = rssi;
    latestMs = ms;
    total++;
    trim(ms);
  }

  void trim(int nowMs) => _s.removeWhere((x) => x.$1 < nowMs - windowMs);

  double? get median10 => _s.isEmpty ? null : sense.median([for (final x in _s) x.$2]);

  /// Readings per second over the window.
  double get rate => _s.length / (windowMs / 1000);
}

/// A run's numbers, per peer: count, median and standard deviation (dB).
class RunStats {
  final int n;
  final double median;
  final double std;
  const RunStats(this.n, this.median, this.std);

  static RunStats? of(List<int> xs) {
    if (xs.isEmpty) return null;
    final mean = xs.reduce((a, b) => a + b) / xs.length;
    final v = xs.length < 2 ? 0.0 : xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) / (xs.length - 1);
    return RunStats(xs.length, sense.median(xs), math.sqrt(v));
  }

  @override
  String toString() => '$n samples, median ${median.toStringAsFixed(1)} dBm, sd ${std.toStringAsFixed(1)} dB';
}

/// One raw advert of a recorded run (fields after `t`/`m`/`k`, which the
/// log writer adds).
Map<String, Object?> sampleLine({
  required int run,
  required int heardMs,
  required String observer,
  required String? observerModel,
  required String peer,
  required String? peerModel,
  required int rssi,
  required int? txPower,
  required double distanceM,
  required Placement placement,
}) =>
    {
      'run': run,
      'heard_ms': heardMs,
      'obs': observer,
      if (observerModel != null) 'obs_model': observerModel,
      'peer': peer,
      if (peerModel != null) 'peer_model': peerModel,
      'rssi': rssi,
      if (txPower != null) 'tx': txPower,
      'd_m': distanceM,
      'place': placement.name,
    };

/// Short id for the list: the last 4 of an install id.
String shortPeer(String key) => key.length <= 4 ? key : key.substring(key.length - 4);
