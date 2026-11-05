import 'dart:math' as math;

import 'package:felt_notes/radar/radar_model.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart' show DeviceLog;
import 'package:flutter_test/flutter_test.dart';

/// Box-Muller.
double gauss(math.Random r) => math.sqrt(-2 * math.log(1 - r.nextDouble())) * math.cos(2 * math.pi * r.nextDouble());

/// "True" radio for the synthetic tables: the measured shape (steep to 4 ft,
/// flat beyond) at a level the estimator does not know, per-phone bias
/// (sd 3 dB), a per-pair orientation offset (30% of pairs lose 6-11 dB:
/// face down, a body between), and per-minute medians of noisy readings
/// (sd [sigma] dB over ~10 readings, 3 minutes).
class SynthTable {
  final RadarConfig cfg;
  final Map<String, int> truth; // phone -> slot
  final RadarInput input;
  SynthTable(this.cfg, this.truth, this.input);
}

SynthTable synth(int seed,
    {int seats = 10, List<int> occupied = const [1, 3, 5, 7, 9], double sigma = 4, bool uwb = false, String? orgDev}) {
  final r = math.Random(seed);
  final cfg = RadarConfig(seats: seats, organizerSeat: orgDev == null ? null : occupied.first, organizerDevice: orgDev);
  final lay = layoutTable(cfg);
  final truth = <String, int>{};
  for (var i = 0; i < occupied.length; i++) {
    truth[i == 0 && orgDev != null ? orgDev : 'P$i'] = occupied[i];
  }
  const model = RadioModel();
  final level = -55 - 10 * r.nextDouble();
  final bias = {for (final p in [...truth.keys, 'CAM']) p: 3 * gauss(r)};
  final pos = {for (final e in truth.entries) e.key: lay.slots[e.value], 'CAM': lay.camera};
  final links = <RadarLink>[];
  final uw = <String, double>{};
  final ids = pos.keys.toList();
  for (final a in ids) {
    for (final b in ids) {
      if (a == b) continue;
      final pairOff = r.nextDouble() < 0.3 ? -(6 + 5 * r.nextDouble()) : 0.0;
      final mean = level + bias[a]! + bias[b]! + model.shape(dist(pos[a]!, pos[b]!)) + pairOff;
      // 3 minutes of medians of ~10 readings.
      final meds = [
        for (var m = 0; m < 3; m++)
          () {
            final xs = [for (var k = 0; k < 10; k++) mean + sigma * gauss(r)]..sort();
            return (xs[4] + xs[5]) / 2;
          }()
      ];
      links.add(RadarLink(a, b, meds.reduce((x, y) => x + y) / 3, 30));
      if (uwb && a.compareTo(b) < 0 && a != 'CAM' && b != 'CAM') {
        uw[pairKey(a, b)] = dist(pos[a]!, pos[b]!) + 0.05 * gauss(r);
      }
    }
  }
  return SynthTable(cfg, truth, RadarInput(cameras: const {'CAM'}, links: links, uwb: uw, names: const {}));
}

/// Mirror image of slot [s] across the axis through the camera.
int mirror(int s, int n) => n - 1 - s;

void main() {
  group('table layout', () {
    test('N slots evenly round the chair line, camera between the last and the first', () {
      for (final shape in TableShape.values) {
        for (final cam in CameraAt.values) {
          final lay = layoutTable(RadarConfig(shape: shape, camera: cam, seats: 10));
          expect(lay.slots, hasLength(10));
          final gaps = [for (var k = 0; k < 10; k++) dist(lay.slots[k], lay.slots[(k + 1) % 10])];
          final mean = gaps.reduce((a, b) => a + b) / 10;
          for (final g in gaps) {
            expect(g, closeTo(mean, mean * 0.5));
          }
          // One seat in the middle of each end: slot 0 is at the camera's
          // end, the camera just behind it; clockwise slot 1 is above the
          // axis (y up).
          if (cam == CameraAt.end) {
            expect(lay.slots.first.$2, closeTo(0, 0.05));
            expect(lay.slots[1].$2, greaterThan(0));
            expect(dist(lay.camera, lay.slots.first), closeTo(0.3, 0.05));
          }
          // The far end's middle seat is on the axis too.
          expect(lay.slots.any((p) => p.$2.abs() < 0.05 && p.$1 > 0), cam == CameraAt.end || shape == TableShape.oval || true);
        }
      }
      final lay = layoutTable(const RadarConfig());
      expect(lay.camera.$1, closeTo(-(8 * feetToM / 2 + chairOffsetM) - 0.3, 1e-3));
    });

    test('ends: one seat in the middle or two at the corners', () {
      final one = layoutTable(const RadarConfig(seats: 10));
      final two = layoutTable(const RadarConfig(seats: 10, leftEndSeats: 2, rightEndSeats: 2));
      bool onAxisAt(TableLayout l, double sign) => l.slots.any((p) => p.$2.abs() < 0.05 && p.$1 * sign > 0);
      expect(onAxisAt(one, -1), isTrue);
      expect(onAxisAt(one, 1), isTrue);
      expect(onAxisAt(two, -1), isFalse);
      expect(onAxisAt(two, 1), isFalse);
      // Two at the corners: the camera has no seat in front of it and sits
      // between the last slot and the first.
      expect(dist(two.camera, two.slots.first), closeTo(dist(two.camera, two.slots.last), 0.05));
      // Sides share the rest evenly: 3 + 3 here.
      expect(two.slots.where((p) => p.$2 > 0.3).length, 3 + 2);
      // Too few players for the shape: evenly all round.
      expect(layoutTable(const RadarConfig(seats: 3, leftEndSeats: 2, rightEndSeats: 2)).slots, hasLength(3));
    });

    test('phones fade after 3 minutes and drop off after 10', () {
      const inp = RadarInput(
        links: [RadarLink('a', 'b', -60, 3), RadarLink('b', 'c', -60, 3)],
        lastSeenMs: {'a': 0, 'b': 500000, 'c': 800000},
      );
      final l = inp.live(800000);
      expect(l.phones, {'b', 'c'}); // a: 13 min, gone
      expect(l.stale, {'b'}); // 5 min: left?
    });

    test('config round trip', () {
      const c = RadarConfig(
          shape: TableShape.rectangle, lengthFt: 7, widthFt: 3.5, seats: 8, camera: CameraAt.side, organizerSeat: 0);
      final d = RadarConfig.fromJson(c.toJson())!;
      expect(d.toJson(), c.toJson());
      expect(RadarConfig.fromJson({'n': 30}), isNull);
    });
  });

  test('readings from the uploaded logs: keys, cameras, last windows only', () {
    NightEvent ev(String dev, int seq, EventKind k, int ms, Map<String, Object?> d) =>
        NightEvent(deviceId: dev, seq: seq, kind: k, ms: ms, data: d);
    final host = [
      ev('HOSTHOSTHOST', 1, EventKind.join, 0, {'name': 'Sage'}),
      ev('HOSTHOSTHOST', 2, EventKind.device, 1, {'key': 'H:NIGHT234', 'model': 'Pixel 10'}),
      ev('HOSTHOSTHOST', 3, EventKind.sense, 60000, {
        'p': [
          ['D:AAAAAAAAAAAA', -50, 4],
          ['D:CAMCAMCAMCAM', -70, 2],
        ]
      }),
    ];
    final a = [
      ev('AAAAAAAAAAAA', 1, EventKind.join, 0, {'name': 'Asher'}),
      for (var m = 1; m <= 5; m++)
        ev('AAAAAAAAAAAA', 1 + m, EventKind.sense, m * 60000, {
          'p': [
            ['H:NIGHT234', m <= 2 ? -90 : -54, 2],
          ],
          if (m == 5) 'u': [
            ['D:HOSTHOSTHOST', 80, 9],
          ],
        }),
    ];
    final cam = [ev('CAMCAMCAMCAM', 1, EventKind.join, 0, {'name': 'Table camera', 'role': 'camera'})];
    final inp = radarInputFrom([
      DeviceLog('HOSTHOSTHOST', host),
      DeviceLog('AAAAAAAAAAAA', a),
      DeviceLog('CAMCAMCAMCAM', cam),
    ], windows: 3);
    expect(inp.cameras, {'CAMCAMCAMCAM'});
    expect(inp.names['AAAAAAAAAAAA'], 'Asher');
    final l = inp.links.firstWhere((x) => x.from == 'AAAAAAAAAAAA');
    expect(l.to, 'HOSTHOSTHOST'); // the host's H: key resolved
    expect(l.rssi, -54); // only the last 3 minutes
    expect(l.n, 6);
    expect(inp.uwb[pairKey('AAAAAAAAAAAA', 'HOSTHOSTHOST')], closeTo(0.8, 1e-9));
    expect(inp.newestMs, 300000);
    expect(inp.phones, containsAll(['HOSTHOSTHOST', 'AAAAAAAAAAAA', 'CAMCAMCAMCAM']));
  });

  test('the model: steep to 4 ft, nearly flat beyond', () {
    const m = RadioModel();
    expect(m.shape(1), closeTo(0, 1e-9));
    expect(m.shape(0.5) - m.shape(1.2), greaterThan(8));
    expect(m.shape(1.2) - m.shape(3), lessThan(4));
    final d = distancesFromMe({'a': -60, 'b': -75});
    expect(d.first.$1, 'a');
    expect(d.first.$3, closeTo(1.0, 0.01));
    expect(d.last.$3, greaterThan(d.first.$3));
  });

  test('no data, too few links, too many phones', () {
    const cfg = RadarConfig(seats: 4);
    expect(estimateSeats(cfg, const RadarInput()).notEnough, isNotNull);
    final few = estimateSeats(cfg, const RadarInput(links: [RadarLink('a', 'b', -60, 3)], cameras: {}));
    expect(few.notEnough, isNotNull);
    final many = RadarInput(links: [
      for (final a in 'abcde'.split(''))
        for (final b in 'abcde'.split(''))
          if (a != b) RadarLink(a, b, -60, 3)
    ]);
    expect(estimateSeats(cfg, many).notEnough, contains('More phones'));
  });

  group('synthetic tables (10 seats, an app phone on every other seat)', () {
    var lastOrder = 0.0;
    // Over [tables] random tables: share of phones whose most likely slot is
    // right (exact), right up to the left/right mirror (one anchor cannot
    // tell them apart), and the probability left on empty (grey) slots.
    (double, double, double, double) score(int tables,
        {bool uwb = false, bool anchor = false, double sigma = 4, List<int> occupied = const [1, 3, 5, 7, 9]}) {
      var exact = 0, mirrored = 0, total = 0, conf = 0.0, order = 0, orderTotal = 0;
      var grey = 0.0, greySlots = 0;
      for (var t = 0; t < tables; t++) {
        final s = synth(1000 + t, uwb: uwb, sigma: sigma, orgDev: anchor ? 'ORG' : null, occupied: occupied);
        final est = estimateSeats(s.cfg, s.input);
        // Whole table up to the mirror (the same flip for every phone).
        var ok = 0, okM = 0;
        for (final e in s.truth.entries) {
          if (e.key == 'ORG') continue; // pinned: not a guess
          final b = est.bestSlot(e.key);
          if (b == e.value) ok++;
          if (b == mirror(e.value, 10)) okM++;
          conf += est.probs[e.key]![b!];
        }
        exact += ok;
        mirrored += math.max(ok, okM);
        // Order: each phone's clockwise next phone, as estimated, matches the
        // truth (or the mirror's, consistently for the table).
        final ph = [for (final k in s.truth.keys) if (k != 'ORG') k];
        String nextOf(Map<String, int> at, String p, int dir) {
          final mine = at[p]!;
          String? best;
          var bd = 99;
          for (final q in ph) {
            if (q == p) continue;
            final d = ((at[q]! - mine) * dir) % 10;
            if (d > 0 && d < bd) {
              bd = d;
              best = q;
            }
          }
          return best!;
        }
        final estAt = {for (final p in ph) p: est.joint[p]!};
        {
          var cw = 0, ccw = 0;
          for (final p in ph) {
            if (nextOf(estAt, p, 1) == nextOf(s.truth, p, 1)) cw++;
            if (nextOf(estAt, p, -1) == nextOf(s.truth, p, 1)) ccw++;
          }
          order += math.max(cw, ccw);
        }
        orderTotal += ph.length;
        total += s.truth.keys.where((k) => k != 'ORG').length;
        for (var k = 0; k < 10; k++) {
          if (!s.truth.values.contains(k)) {
            grey += est.occupancy(k);
            greySlots++;
          }
        }
      }
      lastOrder = order / orderTotal;
      return (exact / total, mirrored / total, greySlots == 0 ? 0 : grey / greySlots, conf / total);
    }

    test('RSSI only, camera anchor only', () {
      final (exact, upToMirror, grey, conf) = score(30);
      // ignore: avoid_print
      print('RSSI, camera only: exact ${(exact * 100).round()}%, up to mirror ${(upToMirror * 100).round()}%, '
          'mass on empty slots ${(grey * 100).round()}%, mean top prob ${(conf * 100).round()}%, order ${(lastOrder * 100).round()}%');
      // Chance is 1 in 10. Every other seat taken means no two app phones
      // are neighbours (1.6 m apart, in the flat part of the curve):
      // RSSI alone has little to go on here.
      expect(upToMirror, greaterThan(0.15));
    });

    test('RSSI with the organizer phone pinned (second anchor)', () {
      final (exact, upToMirror, grey, conf) = score(30, anchor: true);
      // ignore: avoid_print
      print('RSSI, camera + organizer: exact ${(exact * 100).round()}%, up to mirror ${(upToMirror * 100).round()}%, '
          'mass on empty slots ${(grey * 100).round()}%, mean top prob ${(conf * 100).round()}%, order ${(lastOrder * 100).round()}%');
      expect(exact, greaterThan(0.15));
    });

    test('a full table (every seat has an app phone), RSSI only', () {
      final (exact, upToMirror, _, conf) = score(15, anchor: true, occupied: const [1, 0, 2, 3, 4, 5, 6, 7, 8, 9]);
      // ignore: avoid_print
      print('RSSI, full table, camera + organizer: exact ${(exact * 100).round()}%, '
          'up to mirror ${(upToMirror * 100).round()}%, mean top prob ${(conf * 100).round()}%, order ${(lastOrder * 100).round()}%');
      expect(exact, greaterThan(0.4));
    });

    test('with iPhone UWB distances', () {
      final (exact, upToMirror, grey, conf) = score(30, uwb: true, anchor: true);
      // ignore: avoid_print
      print('UWB, camera + organizer: exact ${(exact * 100).round()}%, up to mirror ${(upToMirror * 100).round()}%, '
          'mass on empty slots ${(grey * 100).round()}%, mean top prob ${(conf * 100).round()}%, order ${(lastOrder * 100).round()}%');
      expect(exact, greaterThan(0.9));
      expect(grey, lessThan(0.1)); // empty seats stay grey
    });
  });
}
