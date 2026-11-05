import 'dart:math' as math;

import 'package:felt_notes/radar/radar_model.dart';
import 'package:felt_notes/radar/radar_shapes.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bump of probability around [centre] (cells), [sigma] wide.
List<double> bump(double centre, double sigma) {
  final b = [for (var c = 0; c < bandCells; c++) math.exp(-0.5 * math.pow(cellDist(c + 0.5, centre) / sigma, 2)) + 1e-9];
  final z = b.reduce((a, x) => a + x);
  return [for (final x in b) x / z];
}

void expectTiling(List<SeatRegion> rs) {
  final owner = <int, String>{};
  for (final r in rs) {
    expect(r.len, greaterThanOrEqualTo(minCells), reason: '$r');
    for (final c in r.cells) {
      expect(owner[c], isNull, reason: 'cell $c in ${owner[c]} and ${r.id}');
      owner[c] = r.id;
    }
    // Contiguous: exactly len cells, one run.
    expect(r.cells.length, r.len.round(), reason: '$r');
  }
}

void main() {
  test('puzzle: no overlap, one contiguous arc each, the cyclic order kept', () {
    final cells = {
      'a': bump(5, 2),
      'b': bump(17, 2),
      'c': bump(30, 6),
      'd': bump(50, 3),
      'e': bump(66, 2), // close to a across the wrap
    };
    final rs = puzzlePartition(cells, ['a', 'b', 'c', 'd', 'e']);
    expect(rs.map((r) => r.id).toList(), ['a', 'b', 'c', 'd', 'e']);
    expectTiling(rs);
    // Each arc holds its own peak.
    for (final (id, peak) in [('a', 5.0), ('b', 17.0), ('c', 30.0), ('d', 50.0), ('e', 66.0)]) {
      expect(rs.firstWhere((r) => r.id == id).contains(peak), isTrue, reason: id);
    }
    // Clockwise order of the mids is the given order (cyclically).
    final mids = [for (final r in rs) r.mid];
    var turns = 0;
    for (var i = 0; i < mids.length; i++) {
      if (mids[(i + 1) % mids.length] < mids[i]) turns++;
    }
    expect(turns, 1, reason: 'one wrap round the table: $mids');
  });

  test('puzzle: two people wanting the same spot are pushed apart, order as given', () {
    final cells = {'a': bump(20, 3), 'b': bump(21, 3)};
    final ab = puzzlePartition(cells, ['a', 'b']);
    expectTiling(ab);
    final a = ab.firstWhere((r) => r.id == 'a'), b = ab.firstWhere((r) => r.id == 'b');
    expect((a.start + a.len) % bandCells, closeTo(b.start, 1e-9), reason: 'they meet: $ab');
    expect(a.contains(19.5) || b.contains(19.5), isTrue);
    // The boundary sits at the crossover (between the peaks).
    expect(b.start, inInclusiveRange(19, 23));
  });

  test('puzzle: sure = narrow, unsure = wide; low-probability cells stay empty', () {
    final rs = puzzlePartition({'sure': bump(10, 1.2), 'unsure': bump(45, 9)}, ['sure', 'unsure']);
    expectTiling(rs);
    final sure = rs.firstWhere((r) => r.id == 'sure'), unsure = rs.firstWhere((r) => r.id == 'unsure');
    expect(sure.len, lessThan(10));
    expect(unsure.len, greaterThan(2 * sure.len));
    final used = sure.len + unsure.len;
    expect(used, lessThan(bandCells), reason: 'empty seats stay grey');
  });

  test('puzzle: one person, and many people (12 on 72 cells)', () {
    expect(puzzlePartition({'x': bump(30, 3)}, ['x']).single.contains(30), isTrue);
    final many = {for (var i = 0; i < 12; i++) 'p$i': bump(i * 6 + 3, 2.5)};
    final rs = puzzlePartition(many, [for (var i = 0; i < 12; i++) 'p$i']);
    expect(rs.length, 12);
    expectTiling(rs);
  });

  test('overlap: each holds 60% of its own probability, may overlap', () {
    final rs = overlapRegions({'a': bump(20, 3), 'b': bump(22, 3)});
    final a = rs.firstWhere((r) => r.id == 'a'), b = rs.firstWhere((r) => r.id == 'b');
    expect(a.cells.toSet().intersection(b.cells.toSet()), isNotEmpty);
    final pa = bump(20, 3);
    expect(a.cells.fold(0.0, (s, c) => s + pa[c]), greaterThanOrEqualTo(overlapMass));
  });

  test('regions get the seat whose centre is inside, with its probability', () {
    final lay = layoutTable(const RadarConfig(seats: 6));
    final est = RadarEstimate(lay, {
      'A': [0.8, 0.2, 0, 0, 0, 0],
      'B': [0, 0, 0, 0.5, 0.5, 0],
    }, joint: const {'A': 0, 'B': 3}, organizerSlot: 5);
    final rs = radarRegions(est, organizer: true);
    expectTiling(rs);
    final a = rs.firstWhere((r) => r.id == 'A');
    expect((a.seat, a.conf), (0, 0.8));
    expect(rs.firstWhere((r) => r.id == organizerRegionId).seat, 5);
    final over = radarRegions(est, overlap: true);
    expect(over.length, 2);
  });

  test('smoothing: half-life 30 s, reset on a pulse; tween between updates', () {
    final s = CellSmoother();
    s.update({'a': bump(10, 2)}, 0);
    final half = s.update({'a': bump(40, 2)}, 30000)['a']!;
    expect(half[10], closeTo(bump(10, 2)[10] / 2, 0.01));
    expect(half[40], closeTo(bump(40, 2)[40] / 2, 0.01));
    final reset = s.update({'a': bump(10, 2)}, 31000, reset: true)['a']!;
    expect(reset[10], closeTo(bump(10, 2)[10], 1e-9));

    const a = SeatRegion('a', 70, 4, conf: 0.2), b = SeatRegion('a', 2, 6, conf: 0.8);
    final m = SeatRegion.lerp(a, b, 0.5)!;
    expect(m.mid, closeTo(2.5, 1e-9), reason: 'the short way across the wrap');
    expect(m.len, 5);
    expect(lerpRegions([a], [], 1), isEmpty, reason: 'gone');
    expect(lerpRegions([], [b], 0.5).single.len, 3, reason: 'arriving grows');
  });

  test('a real estimate: band cells from the readings, regions tile', () {
    // 6 seats, camera at the end, phones at slots 0, 2, 4 (the synthetic
    // readings from the model itself).
    const cfg = RadarConfig(seats: 6);
    final lay = layoutTable(cfg);
    const m = RadioModel();
    final at = {'A': 0, 'B': 2, 'C': 4};
    final links = <RadarLink>[];
    for (final x in at.keys) {
      for (final y in [...at.keys, 'CAM']) {
        if (x == y) continue;
        final py = y == 'CAM' ? lay.camera : lay.slots[at[y]!];
        final r = -60 + m.shape(dist(lay.slots[at[x]!], py));
        links.add(RadarLink(x, y, r, 10));
        if (y == 'CAM') links.add(RadarLink(y, x, r, 10));
      }
    }
    final est = estimateSeats(cfg, RadarInput(links: links, cameras: const {'CAM'}));
    expect(est.cells.keys.toSet(), {'A', 'B', 'C'});
    for (final c in est.cells.values) {
      expect(c.length, bandCells);
      expect(c.reduce((a, b) => a + b), closeTo(1, 1e-6));
    }
    final rs = radarRegions(est);
    expectTiling(rs);
    for (final r in rs) {
      expect(r.seat, est.joint[r.id], reason: '$r');
    }
  });
}
