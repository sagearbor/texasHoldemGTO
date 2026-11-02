/// Bluetooth distance test (Settings → Diagnostics): the pure parts. Two or
/// more phones with the screen open advertise and scan without pause; the
/// owner puts them a known distance apart, picks how they lie, and records
/// 60 seconds. Every raw advert becomes one JSONL line, and
/// tool/positioning/calibrate.py fits the path-loss model per phone pair
/// from those files. Nothing here is shown during a game.
library;

import 'dart:convert';
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

// ---------------------------------------------------------------- units

/// The distance as the owner enters it. Logs always carry metres too.
enum DistanceUnit { metres, feet }

/// The stepper works in whole units of [stepOf]: metres in 0.25 m steps
/// (0.25 to 5 m), feet in 6-inch steps (1 ft to 16 ft). The entered value
/// is metres for [DistanceUnit.metres] and inches for [DistanceUnit.feet].
double stepOf(DistanceUnit u) => u == DistanceUnit.metres ? 0.25 : 6;
double minOf(DistanceUnit u) => u == DistanceUnit.metres ? 0.25 : 12;
double maxOf(DistanceUnit u) => u == DistanceUnit.metres ? 5.0 : 192;
double defaultOf(DistanceUnit u) => u == DistanceUnit.metres ? 1.0 : 36;

double stepValue(DistanceUnit u, double v, int dir) {
  final st = stepOf(u);
  return (((v + dir * st) / st).round() * st).clamp(minOf(u), maxOf(u)).toDouble();
}

const metresPerInch = 0.0254;

double metresOf(DistanceUnit u, double v) => u == DistanceUnit.metres ? v : v * metresPerInch;

/// `1.25 m`, `3 ft 6 in`, `4 ft`.
String distanceLabel(DistanceUnit u, double v) {
  if (u == DistanceUnit.metres) return '${v.toStringAsFixed(2)} m';
  final inches = v.round();
  final ft = inches ~/ 12, inch = inches % 12;
  return inch == 0 ? '$ft ft' : '$ft ft $inch in';
}

/// The same distance in the other unit, snapped to its stepper.
double convertValue(DistanceUnit from, DistanceUnit to, double v) {
  if (from == to) return v;
  final m = metresOf(from, v);
  final raw = to == DistanceUnit.metres ? m : m / metresPerInch;
  final st = stepOf(to);
  return ((raw / st).round() * st).clamp(minOf(to), maxOf(to)).toDouble();
}

DistanceUnit? unitFromName(Object? n) {
  for (final u in DistanceUnit.values) {
    if (u.name == n) return u;
  }
  return null;
}

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

/// The sender's advert power from the transmit level its advert carries.
/// Pixels report about +1 dBm (high), -7 (medium), -15 (low), -21 (ultra
/// low); the cut points sit between them. Null when the advert had none
/// (iPhones).
String? txLevelOf(int? txDbm) {
  if (txDbm == null) return null;
  if (txDbm >= -3) return 'high';
  if (txDbm >= -11) return 'medium';
  if (txDbm >= -18) return 'low';
  return 'ultra_low';
}

/// The distance test alternates its own advert between these every 5 s.
const testPowers = ['high', 'low'];

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
  DistanceUnit unit = DistanceUnit.metres,
  double? entered,
}) =>
    {
      'run': run,
      'heard_ms': heardMs,
      'obs': observer,
      if (observerModel != null) 'obs_model': observerModel,
      'peer': peer,
      if (peerModel != null) 'peer_label': peerModel,
      'rssi': rssi,
      if (txPower != null) 'tx': txPower,
      if (txLevelOf(txPower) != null) 'tx_level': txLevelOf(txPower),
      'd_m': distanceM,
      'unit': unit.name,
      'entered': entered ?? distanceM,
      'place': placement.name,
    };

/// `bt-distance-ashers-phone-2026-11-01.jsonl` for "Asher's phone".
String exportFileName(String label, DateTime day) {
  var slug = label.toLowerCase().replaceAll("'", '').replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 32) slug = slug.substring(0, 32).replaceAll(RegExp(r'-+$'), '');
  if (slug.isEmpty) slug = 'phone';
  String two(int v) => v.toString().padLeft(2, '0');
  return 'bt-distance-$slug-${day.year}-${two(day.month)}-${two(day.day)}.jsonl';
}

/// Short id for the list: the last 4 of an install id.
String shortPeer(String key) => key.length <= 4 ? key : key.substring(key.length - 4);

// ----------------------------------------------------------------- runs

/// One recorded run of this device, read back from its log.
class RunRecord {
  final int id;
  final double metres;
  final DistanceUnit unit;
  final double entered;
  final String place;

  /// A `run_end` with complete true was logged (left mid-run, or the app
  /// was killed: incomplete).
  final bool complete;
  final bool deleted;

  /// Per peer.
  final Map<String, RunStats> stats;

  /// All peers, per sender advert level (`high`, `low`, `unknown`).
  final Map<String, RunStats> byLevel;
  const RunRecord(this.id, this.metres, this.unit, this.entered, this.place,
      {this.complete = false, this.deleted = false, this.stats = const {}, this.byLevel = const {}});

  int get samples => stats.values.fold(0, (a, s) => a + s.n);

  /// All peers together (the list shows one line per run).
  RunStats? get overall {
    if (stats.isEmpty) return null;
    if (stats.length == 1) return stats.values.single;
    // Pooled: medians weighted by count, sd as the pooled sd.
    final n = samples;
    final med = stats.values.fold(0.0, (a, s) => a + s.median * s.n) / n;
    final v = stats.values.fold(0.0, (a, s) => a + s.std * s.std * s.n) / n;
    return RunStats(n, med, math.sqrt(v));
  }
}

Map<String, Object?>? _decode(String line) {
  try {
    final j = jsonDecode(line);
    return j is Map ? j.cast<String, Object?>() : null;
  } catch (_) {
    return null; // a torn last line
  }
}

/// Deleted run ids per the `deleted` / `undeleted` markers, in order.
Set<int> deletedRuns(Iterable<String> lines) {
  final out = <int>{};
  for (final l in lines) {
    final j = _decode(l);
    if (j == null) continue;
    final runs = [if (j['run'] is int) j['run'] as int, ...((j['runs'] as List?) ?? const []).whereType<int>()];
    if (j['k'] == 'deleted') out.addAll(runs);
    if (j['k'] == 'undeleted') out.removeAll(runs);
  }
  return out;
}

/// This device's runs, newest first, from its log lines. Per-peer stats
/// come from the samples themselves (so a killed run still has numbers).
List<RunRecord> runsFromLog(Iterable<String> lines) {
  final ls = lines.toList();
  final del = deletedRuns(ls);
  final starts = <int, Map<String, Object?>>{};
  final ended = <int, bool>{};
  final samples = <int, Map<String, List<int>>>{};
  final levels = <int, Map<String, List<int>>>{};
  for (final l in ls) {
    final j = _decode(l);
    final run = j?['run'];
    if (j == null || run is! int) continue;
    switch (j['k']) {
      case 'run_start':
        starts[run] = j;
      case 'run_end':
        ended[run] = j['complete'] == true;
      case 'sample':
        final r = j['rssi'];
        if (r is int) {
          ((samples[run] ??= {})['${j['peer']}'] ??= []).add(r);
          final lv = j['tx_level'] ?? txLevelOf((j['tx'] as num?)?.toInt()) ?? 'unknown';
          ((levels[run] ??= {})['$lv'] ??= []).add(r);
        }
    }
  }
  final out = <RunRecord>[];
  for (final e in starts.entries) {
    final j = e.value;
    final unit = unitFromName(j['unit']) ?? DistanceUnit.metres;
    final m = (j['d_m'] as num?)?.toDouble() ?? 0;
    out.add(RunRecord(
      e.key,
      m,
      unit,
      (j['entered'] as num?)?.toDouble() ?? m,
      '${j['place']}',
      complete: ended[e.key] ?? false,
      deleted: del.contains(e.key),
      stats: {
        for (final p in (samples[e.key] ?? const <String, List<int>>{}).entries)
          if (RunStats.of(p.value) != null) p.key: RunStats.of(p.value)!,
      },
      byLevel: {
        for (final p in (levels[e.key] ?? const <String, List<int>>{}).entries)
          if (RunStats.of(p.value) != null) p.key: RunStats.of(p.value)!,
      },
    ));
  }
  out.sort((a, b) => b.id.compareTo(a.id));
  return out;
}

/// The export: every line except the deleted runs' and the delete
/// markers themselves.
List<String> exportLines(Iterable<String> lines) {
  final ls = lines.toList();
  final del = deletedRuns(ls);
  return [
    for (final l in ls)
      if (_decode(l) case final j?)
        if (j['k'] != 'deleted' && j['k'] != 'undeleted' && !(j['run'] is int && del.contains(j['run']))) l,
  ];
}

// ------------------------------------------------------- radio health

/// What to restart, and why, from one 5-second status reading.
enum HealAction { scan, advert }

/// Turns the native side's cumulative counters into "heard in the last 5
/// seconds" and decides when to restart our scan or advert while the
/// screen is open (field data: whole minutes of silence mid-run). At most
/// one restart of each per [cooldownMs].
class RadioHealth {
  final int cooldownMs;
  final int silenceMs;
  RadioHealth({this.cooldownMs = 30000, this.silenceMs = 30000});

  int? _all, _felt;
  int? _quietSince;
  final Map<HealAction, int> _lastHeal = {};

  /// Adverts heard since the previous reading: (all devices, Felt Notes).
  /// A counter that went back (native side restarted) counts from zero.
  (int, int) heard(Map<String, Object?> st) {
    final all = (st['heard_all'] as num?)?.toInt() ?? 0, felt = (st['heard_felt'] as num?)?.toInt() ?? 0;
    final pa = _all, pf = _felt;
    _all = all;
    _felt = felt;
    if (pa == null || pf == null) return (0, 0);
    return (all >= pa ? all - pa : all, felt >= pf ? felt - pf : felt);
  }

  /// Restarts due now, with their reasons. [heardAll] is this reading's
  /// [heard] count; nothing is restarted while Bluetooth is off.
  List<(HealAction, String)> check(Map<String, Object?> st, {required int nowMs, required int heardAll}) {
    final out = <(HealAction, String)>[];
    final on = st['adapter'] == 'on';
    if (heardAll > 0 || !on) {
      _quietSince = null;
    } else {
      _quietSince ??= nowMs;
    }
    if (!on) return out;
    bool may(HealAction a) => nowMs - (_lastHeal[a] ?? -cooldownMs) >= cooldownMs;
    if (st['scan'] != true && may(HealAction.scan)) {
      out.add((HealAction.scan, 'scan_not_running'));
    } else if (_quietSince != null && nowMs - _quietSince! >= silenceMs && may(HealAction.scan)) {
      // Running by our books, yet not one advert from any device.
      out.add((HealAction.scan, 'no_adverts_${silenceMs ~/ 1000}s'));
    }
    if (st['advert'] != true && may(HealAction.advert)) out.add((HealAction.advert, 'advert_not_running'));
    for (final (a, _) in out) {
      _lastHeal[a] = nowMs;
      if (a == HealAction.scan) _quietSince = null;
    }
    return out;
  }
}
