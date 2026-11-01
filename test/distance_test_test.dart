import 'package:felt_notes/nearby/distance_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('distance stepper: 0.25 m steps, 0.25 to 5 m', () {
    expect(stepDistance(1.0, 1), 1.25);
    expect(stepDistance(1.0, -1), 0.75);
    expect(stepDistance(0.25, -1), 0.25);
    expect(stepDistance(5.0, 1), 5.0);
    var d = 0.25;
    for (var i = 0; i < 30; i++) {
      d = stepDistance(d, 1);
    }
    expect(d, 5.0);
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
      'place': 'pocket',
    });
    expect(shortPeer('D:BBBBBBBBWXYZ'), 'WXYZ');
  });
}
