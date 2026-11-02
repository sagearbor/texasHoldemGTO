import 'dart:convert';

import 'package:felt_notes/nearby/distance_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('metres: 0.25 m steps, 0.25 to 5 m', () {
    const m = DistanceUnit.metres;
    expect(stepValue(m, 1.0, 1), 1.25);
    expect(stepValue(m, 1.0, -1), 0.75);
    expect(stepValue(m, 0.25, -1), 0.25);
    expect(stepValue(m, 5.0, 1), 5.0);
    expect(distanceLabel(m, 1.25), '1.25 m');
    expect(metresOf(m, 2.5), 2.5);
  });

  test('feet: 6-inch steps, 1 ft to 16 ft, logged in metres', () {
    const f = DistanceUnit.feet;
    expect(defaultOf(f), 36);
    expect(stepValue(f, 36, 1), 42);
    expect(distanceLabel(f, 42), '3 ft 6 in');
    expect(distanceLabel(f, 48), '4 ft');
    expect(stepValue(f, 12, -1), 12);
    var v = 12.0;
    for (var i = 0; i < 40; i++) {
      v = stepValue(f, v, 1);
    }
    expect(v, 192);
    expect(distanceLabel(f, 192), '16 ft');
    expect(metresOf(f, 42), closeTo(1.0668, 1e-9));
    // Switching units snaps to the other stepper.
    expect(convertValue(DistanceUnit.metres, f, 1.0), 42); // 39.4 in -> 3 ft 6 in
    expect(convertValue(f, DistanceUnit.metres, 42), 1.0);
    expect(convertValue(f, DistanceUnit.metres, 192), 5.0);
    expect(unitFromName('feet'), f);
    expect(unitFromName('x'), isNull);
  });

  test('export file name from the phone label', () {
    final d = DateTime(2026, 11, 1);
    expect(exportFileName("Asher's phone", d), 'bt-distance-ashers-phone-2026-11-01.jsonl');
    expect(exportFileName('  Pixel 10!! ', d), 'bt-distance-pixel-10-2026-11-01.jsonl');
    expect(exportFileName('???', d), 'bt-distance-phone-2026-11-01.jsonl');
  });

  group('runs', () {
    String line(Map<String, Object?> m) => jsonEncode(m);
    List<String> log() => [
          line({'k': 'open'}),
          line({'k': 'run_start', 'run': 1, 'd_m': 1.0668, 'unit': 'feet', 'entered': 42, 'place': 'tableUp'}),
          line({'k': 'sample', 'run': 1, 'peer': 'D:B', 'rssi': -60}),
          line({'k': 'sample', 'run': 1, 'peer': 'D:B', 'rssi': -62}),
          line({'k': 'sample', 'run': 1, 'peer': 'D:C', 'rssi': -70}),
          line({'k': 'run_end', 'run': 1, 'complete': true}),
          line({'k': 'run_start', 'run': 2, 'd_m': 2.0, 'place': 'pocket'}),
          line({'k': 'sample', 'run': 2, 'peer': 'D:B', 'rssi': -75}),
          '{"k": "sam', // killed mid-write: run 2 never ended
        ];

    test('read back, newest first; a run without an end is incomplete', () {
      final r = runsFromLog(log());
      expect([for (final x in r) x.id], [2, 1]);
      expect(r[0].complete, isFalse);
      expect(r[0].unit, DistanceUnit.metres);
      expect(r[0].samples, 1);
      expect(r[1].complete, isTrue);
      expect(r[1].unit, DistanceUnit.feet);
      expect(r[1].entered, 42);
      expect(r[1].stats['D:B']!.median, -61);
      expect(r[1].samples, 3);
      expect(r[1].overall!.n, 3);
    });

    test('delete, undo, clear all; the export leaves deleted runs out', () {
      var l = [...log(), line({'k': 'deleted', 'runs': [1]})];
      expect(runsFromLog(l).firstWhere((x) => x.id == 1).deleted, isTrue);
      final ex = exportLines(l);
      expect(ex.any((x) => x.contains('"run":1')), isFalse);
      expect(ex.any((x) => x.contains('deleted')), isFalse);
      expect(ex.where((x) => x.contains('"run":2')), hasLength(2));
      expect(ex.any((x) => x.startsWith('{"k": "sam')), isFalse); // torn line dropped

      l = [...l, line({'k': 'undeleted', 'runs': [1]})];
      expect(runsFromLog(l).every((x) => !x.deleted), isTrue);
      expect(exportLines(l).where((x) => x.contains('"run":1')), hasLength(5));

      l = [...l, line({'k': 'deleted', 'runs': [1, 2]})];
      expect(runsFromLog(l).every((x) => x.deleted), isTrue);
      expect(exportLines(l), [line({'k': 'open'})]);
    });
  });

  test('rolling RSSI: latest, 10 s median, rate', () {
    final r = RollingRssi();
    for (var i = 0; i < 20; i++) {
      r.add(i * 500, -60 - (i % 3)); // 2 a second
    }
    expect(r.latest, -60 - (19 % 3));
    expect(r.total, 20);
    expect(r.rate, closeTo(2.0, 0.11));
    expect(r.median10, -61);
    r.trim(30000);
    expect(r.median10, isNull);
    expect(r.rate, 0);
  });

  test('run stats', () {
    final s = RunStats.of([-60, -62, -64])!;
    expect(s.n, 3);
    expect(s.median, -62);
    expect(s.std, closeTo(2.0, 1e-9));
    expect(RunStats.of([]), isNull);
    expect(RunStats.of([-50])!.std, 0);
  });

  test('sample line', () {
    final l = sampleLine(
        run: 7,
        heardMs: 123,
        observer: 'AAAAAAAAAAAA',
        observerModel: 'Pixel 10',
        peer: 'D:BBBBBBBBBBBB',
        peerModel: null,
        rssi: -61,
        txPower: -7,
        distanceM: 1.5,
        placement: Placement.pocket);
    expect(l, {
      'run': 7,
      'heard_ms': 123,
      'obs': 'AAAAAAAAAAAA',
      'obs_model': 'Pixel 10',
      'peer': 'D:BBBBBBBBBBBB',
      'rssi': -61,
      'tx': -7,
      'd_m': 1.5,
      'unit': 'metres',
      'entered': 1.5,
      'place': 'pocket',
    });
    expect(shortPeer('D:BBBBBBBBWXYZ'), 'WXYZ');
  });

  group('radio health', () {
    Map<String, Object?> st({bool scan = true, bool advert = true, String adapter = 'on', int all = 0, int felt = 0}) =>
        {'scan': scan, 'advert': advert, 'adapter': adapter, 'heard_all': all, 'heard_felt': felt};

    test('heard in the last 5 s from cumulative counters', () {
      final h = RadioHealth();
      expect(h.heard(st(all: 100, felt: 10)), (0, 0)); // first reading: no baseline
      expect(h.heard(st(all: 160, felt: 25)), (60, 15));
      expect(h.heard(st(all: 7, felt: 2)), (7, 2)); // native counters reset
    });

    test('restart a stopped scan or advert, at most once per cooldown', () {
      final h = RadioHealth(cooldownMs: 30000);
      expect(h.check(st(), nowMs: 0, heardAll: 5), isEmpty);
      expect(h.check(st(scan: false), nowMs: 5000, heardAll: 0), [(HealAction.scan, 'scan_not_running')]);
      expect(h.check(st(scan: false), nowMs: 10000, heardAll: 0), isEmpty); // cooling down
      expect(h.check(st(scan: false, advert: false), nowMs: 36000, heardAll: 0),
          [(HealAction.scan, 'scan_not_running'), (HealAction.advert, 'advert_not_running')]);
      // Bluetooth off: nothing to restart.
      expect(h.check(st(scan: false, advert: false, adapter: 'off'), nowMs: 90000, heardAll: 0), isEmpty);
    });

    test('a running scan that hears nothing for 30 s is restarted', () {
      final h = RadioHealth(cooldownMs: 30000, silenceMs: 30000);
      expect(h.check(st(), nowMs: 0, heardAll: 0), isEmpty);
      expect(h.check(st(), nowMs: 25000, heardAll: 0), isEmpty);
      expect(h.check(st(), nowMs: 30000, heardAll: 0), [(HealAction.scan, 'no_adverts_30s')]);
      expect(h.check(st(), nowMs: 35000, heardAll: 0), isEmpty); // quiet clock restarted
      expect(h.check(st(), nowMs: 40000, heardAll: 3), isEmpty);
      expect(h.check(st(), nowMs: 69000, heardAll: 0), isEmpty);
    });

    test('status lines stay in the export, run filtering untouched', () {
      final lines = [
        jsonEncode({'k': 'status', 'scan': true, 'recording_run': 5}),
        jsonEncode({'k': 'run_start', 'run': 5, 'd_m': 1.0, 'place': 'held'}),
        jsonEncode({'k': 'deleted', 'runs': [5]}),
      ];
      expect(exportLines(lines), [lines.first]);
      expect(runsFromLog(lines).single.deleted, isTrue);
    });
  });
}
