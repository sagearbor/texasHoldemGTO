/// The seat radar's shapes: one region per person on the band of chairs
/// around the table, drawn by radar_view.dart. Pure Dart.
///
/// Puzzle (the default): the regions tile the band and never overlap. The
/// band is [bandCells] cells around the chair line; each person has a
/// probability per cell (RadarEstimate.cells). A dynamic programme picks,
/// for the people in the cyclic order the model's likeliest seating gives,
/// one contiguous arc each (at least [minCells] cells, never overlapping)
/// that maximises the total log-probability, where a cell left to nobody
/// scores log([emptyLevel]). So two neighbours meet where their
/// probabilities cross, and a cell nobody is likely in stays grey. A sure
/// person's probability is high on few cells, so their arc is narrow; an
/// unsure one's is spread, so it is wide (and drawn fainter).
///
/// Overlap: each person on their own, the smallest run of cells around
/// their peak that holds [overlapMass] of their probability. Regions may
/// overlap.
///
/// Both tween (lerp) between updates, and [CellSmoother] keeps a short
/// memory of the cells (half-life 30 s) so one noisy reading does not make
/// them jump; a pulse resets it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'radar_model.dart';

/// The organizer's own seat with no phone of theirs on it: a pinned
/// region with this id.
const organizerRegionId = '__organizer__';

/// A cell nobody is drawn on scores this probability (60% of an even
/// spread over the band).
const emptyLevel = 0.6 / bandCells;

/// Every person's arc is at least this many cells (15 degrees).
const minCells = 3;

/// Overlap mode: each shape holds this much of its person's probability.
const overlapMass = 0.6;

/// One person's region on the band: from cell [start] (may be fractional,
/// 0 .. [bandCells)) for [len] cells clockwise.
class SeatRegion {
  final String id;
  final double start, len;

  /// How sure: the probability of [seat] (0..1).
  final double conf;

  /// The seat slot whose centre falls in the region (most likely one if
  /// several), or the nearest one; null without slots.
  final int? seat;
  const SeatRegion(this.id, this.start, this.len, {this.conf = 0, this.seat});

  double get mid => (start + len / 2) % bandCells;

  /// Contains cell position [x] (circular).
  bool contains(double x) => ((x - start) % bandCells + bandCells) % bandCells < len;

  /// The cells it covers (whole cells whose centre is inside).
  List<int> get cells => [
        for (var c = 0; c < bandCells; c++)
          if (contains(c + 0.5)) c
      ];

  /// Between [a] and [b] at [t] (0..1), the middle along the short way
  /// round. Either may be null (a person arriving or leaving: from or to
  /// nothing at the same place).
  static SeatRegion? lerp(SeatRegion? a, SeatRegion? b, double t) {
    if (a == null && b == null) return null;
    a ??= SeatRegion(b!.id, b.mid, 0, conf: 0, seat: b.seat);
    b ??= SeatRegion(a.id, a.mid, 0, conf: 0, seat: a.seat);
    var d = (b.mid - a.mid) % bandCells;
    if (d > bandCells / 2) d -= bandCells;
    if (d < -bandCells / 2) d += bandCells;
    final mid = a.mid + d * t;
    final len = a.len + (b.len - a.len) * t;
    return SeatRegion(b.id, ((mid - len / 2) % bandCells + bandCells) % bandCells, len,
        conf: a.conf + (b.conf - a.conf) * t, seat: t < 0.5 ? a.seat : b.seat);
  }

  @override
  bool operator ==(Object other) =>
      other is SeatRegion &&
      other.id == id &&
      other.start == start &&
      other.len == len &&
      other.conf == conf &&
      other.seat == seat;

  @override
  int get hashCode => Object.hash(id, start, len, conf, seat);

  @override
  String toString() => 'SeatRegion($id ${start.toStringAsFixed(1)}+${len.toStringAsFixed(1)} seat $seat ${(conf * 100).round()}%)';
}

/// Lerps two region lists by id (people arriving grow from nothing,
/// people leaving shrink away).
List<SeatRegion> lerpRegions(List<SeatRegion> a, List<SeatRegion> b, double t) {
  final byA = {for (final r in a) r.id: r}, byB = {for (final r in b) r.id: r};
  return [
    for (final id in {...byA.keys, ...byB.keys})
      if (SeatRegion.lerp(byA[id], byB[id], t) case final r? when r.len > 0.01) r,
  ];
}

/// The puzzle partition. [cells]: person -> probability per cell (each
/// [bandCells] long); [order]: the people clockwise (the cyclic order
/// kept). Returns one region per person, non-overlapping.
List<SeatRegion> puzzlePartition(Map<String, List<double>> cells, List<String> order,
    {double empty = emptyLevel, int minLen = minCells}) {
  final people = [for (final p in order) if (cells.containsKey(p)) p];
  final k = people.length;
  if (k == 0) return const [];
  const n = bandCells;
  final m = math.max(1, math.min(minLen, n ~/ k));
  final sc = [
    for (final p in people) [for (var c = 0; c < n; c++) math.log(math.max(cells[p]![c], 1e-12))]
  ];
  final e = math.log(empty);
  // State: person j, phase 1..m (in j's arc, length capped at m) or 0 (in
  // the gap after j). Index j * (m + 1) + phase.
  final ns = k * (m + 1);
  const neg = -1e300;
  var bestScore = neg;
  int? bestStart;
  Int32List? bestBack;
  int? bestEnd;
  for (var c0 = 0; c0 < n; c0++) {
    final back = Int32List(n * ns)..fillRange(0, n * ns, -1);
    var cur = List<double>.filled(ns, neg);
    cur[0 * (m + 1) + 1] = sc[0][c0];
    for (var i = 1; i < n; i++) {
      final c = (c0 + i) % n;
      final next = List<double>.filled(ns, neg);
      void relax(int to, double v, int from) {
        if (v > next[to]) {
          next[to] = v;
          back[i * ns + to] = from;
        }
      }

      for (var j = 0; j < k; j++) {
        for (var ph = 0; ph <= m; ph++) {
          final st = j * (m + 1) + ph;
          final v = cur[st];
          if (v <= neg) continue;
          final done = ph == 0 || ph == m; // j's arc is long enough
          if (ph >= 1) relax(j * (m + 1) + math.min(ph + 1, m), v + sc[j][c], st);
          if (done) relax(j * (m + 1), v + e, st);
          if (done && j + 1 < k) relax((j + 1) * (m + 1) + 1, v + sc[j + 1][c], st);
        }
      }
      cur = next;
    }
    for (final ph in [0, m]) {
      final st = (k - 1) * (m + 1) + ph;
      if (cur[st] > bestScore) {
        bestScore = cur[st];
        bestStart = c0;
        bestBack = back;
        bestEnd = st;
      }
    }
  }
  if (bestBack == null) return const [];
  // Walk back: the person (or gap) of every cell.
  final who = List<int>.filled(n, -1);
  var st = bestEnd!;
  for (var i = n - 1; i >= 0; i--) {
    final j = st ~/ (m + 1), ph = st % (m + 1);
    who[i] = ph == 0 ? -1 : j;
    if (i > 0) st = bestBack[i * ns + st];
  }
  final out = <SeatRegion>[];
  for (var j = 0; j < k; j++) {
    final first = who.indexOf(j), last = who.lastIndexOf(j);
    if (first < 0) continue;
    out.add(SeatRegion(people[j], ((bestStart! + first) % n).toDouble(), (last - first + 1).toDouble()));
  }
  return out;
}

/// Overlap mode: per person, the run of cells around the peak holding
/// [mass] of the probability (grown toward the likelier side each step).
List<SeatRegion> overlapRegions(Map<String, List<double>> cells, {double mass = overlapMass}) {
  const n = bandCells;
  final out = <SeatRegion>[];
  for (final e in cells.entries) {
    final p = e.value;
    var peak = 0;
    for (var c = 1; c < n; c++) {
      if (p[c] > p[peak]) peak = c;
    }
    var lo = peak, hi = peak, got = p[peak];
    while (got < mass && hi - lo + 1 < n) {
      final l = p[(lo - 1 + n) % n], r = p[(hi + 1) % n];
      if (l > r) {
        lo--;
        got += l;
      } else {
        hi++;
        got += r;
      }
    }
    out.add(SeatRegion(e.key, ((lo % n) + n) % n * 1.0, (hi - lo + 1).toDouble()));
  }
  return out;
}

/// Each region's seat (the slot centre inside it, the likeliest if
/// several, else the nearest slot) and confidence (that seat's
/// probability in [slotProbs]; the organizer's pinned seat is 1).
List<SeatRegion> withSeats(List<SeatRegion> regions, TableLayout lay, Map<String, List<double>> slotProbs,
    {int? organizerSlot}) {
  final n = lay.slots.length;
  if (n == 0) return regions;
  final centres = [for (var s = 0; s < n; s++) slotCell(lay, s)];
  return [
    for (final r in regions)
      () {
        if (r.id == organizerRegionId && organizerSlot != null) {
          return SeatRegion(r.id, r.start, r.len, conf: 1, seat: organizerSlot);
        }
        final p = slotProbs[r.id] ?? List<double>.filled(n, 0);
        int? seat;
        for (var s = 0; s < n; s++) {
          if (r.contains(centres[s]) && (seat == null || p[s] > p[seat])) seat = s;
        }
        if (seat == null) {
          var bd = double.infinity;
          for (var s = 0; s < n; s++) {
            final d = cellDist(centres[s], r.mid);
            if (d < bd) {
              bd = d;
              seat = s;
            }
          }
        }
        return SeatRegion(r.id, r.start, r.len, conf: seat == null || seat >= p.length ? 0 : p[seat], seat: seat);
      }()
  ];
}

/// The cells to draw from: the estimate's own (or derived from its slot
/// probabilities), plus the organizer's pinned seat when [organizer].
Map<String, List<double>> estimateCells(RadarEstimate e, {bool organizer = false}) {
  final cells = {...(e.cells.isNotEmpty ? e.cells : bandProbs(e.layout, e.probs))};
  final org = e.organizerSlot;
  if (organizer && org != null) {
    final one = List<double>.filled(e.layout.slots.length, 0)..[org] = 1;
    cells[organizerRegionId] = bandProbs(e.layout, {organizerRegionId: one}, width: 0.16)[organizerRegionId]!;
  }
  return cells;
}

/// The regions for [e] (Puzzle, or Overlap when [overlap]) from [cells]
/// (default: [estimateCells]). The organizer's seat, when [organizer], is
/// a pinned region.
List<SeatRegion> radarRegions(RadarEstimate e,
    {bool overlap = false, Map<String, List<double>>? cells, bool organizer = false}) {
  final all = {...(cells ?? estimateCells(e, organizer: organizer))};
  final org = e.organizerSlot;
  if (organizer && org != null && !all.containsKey(organizerRegionId)) {
    all[organizerRegionId] = estimateCells(e, organizer: true)[organizerRegionId]!;
  }
  all.removeWhere((k, v) => v.length != bandCells || (k != organizerRegionId && !e.probs.containsKey(k)));
  if (all.isEmpty) return const [];
  final List<SeatRegion> raw;
  if (overlap) {
    raw = overlapRegions(all);
  } else {
    // Clockwise order of the likeliest seating; the organizer at its seat.
    double at(String p) {
      if (p == organizerRegionId) return slotCell(e.layout, org!);
      final s = e.joint[p] ?? e.bestSlot(p);
      return s == null ? 0 : slotCell(e.layout, s);
    }

    final order = all.keys.toList()..sort((a, b) => at(a).compareTo(at(b)));
    raw = puzzlePartition(all, order);
  }
  final probs = {...e.probs};
  return withSeats(raw, e.layout, probs, organizerSlot: org);
}

/// Exponential smoothing of per-person cell probabilities: half-life
/// [halfLifeMs] between updates, so the shapes move as data comes in but
/// one noisy window does not throw them around. [reset] (after a pulse)
/// starts again from the newest.
class CellSmoother {
  final int halfLifeMs;
  CellSmoother({this.halfLifeMs = 30000});

  Map<String, List<double>> _cells = const {};
  int? _atMs;

  Map<String, List<double>> get cells => _cells;

  Map<String, List<double>> update(Map<String, List<double>> fresh, int nowMs, {bool reset = false}) {
    final old = _cells;
    final dt = _atMs == null ? 0 : math.max(0, nowMs - _atMs!);
    _atMs = nowMs;
    final alpha = reset || _atMs == null ? 1.0 : 1 - math.pow(0.5, dt / halfLifeMs).toDouble();
    _cells = {
      for (final e in fresh.entries)
        e.key: () {
          final o = old[e.key];
          if (o == null || o.length != e.value.length || reset) return [...e.value];
          final m = [for (var c = 0; c < e.value.length; c++) o[c] + (e.value[c] - o[c]) * alpha];
          final z = m.fold(0.0, (a, x) => a + x);
          return z <= 0 ? [...e.value] : [for (final x in m) x / z];
        }()
    };
    return _cells;
  }
}
