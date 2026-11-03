import 'package:felt_notes/camera/watch_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stalled camera is a problem once, cleared by the next frame', () {
    final h = WatchHealth(stallMs: 5000)..start(0);
    expect(h.check(4000), isNull);
    h.onFrame(4000);
    expect(h.check(8999), isNull);
    expect(h.check(9000), WatchHealth.stalled);
    expect(h.check(12000), isNull, reason: 'raised once');
    expect(h.problem, WatchHealth.stalled);
    h.onFrame(12100);
    expect(h.problem, isNull);
  });

  test('reader failures in a row, not scattered ones', () {
    final h = WatchHealth(readerFailures: 3)..start(0);
    expect(h.onReadError(), isNull);
    expect(h.onReadError(), isNull);
    h.onReadOk();
    expect(h.onReadError(), isNull);
    expect(h.onReadError(), isNull);
    expect(h.onReadError(), WatchHealth.readerBroken);
    expect(h.onReadError(), isNull);
    h.onReadOk();
    expect(h.problem, isNull);
  });

  test('outright failures are raised once each; start clears', () {
    final h = WatchHealth()..start(0);
    expect(h.onFailure('Camera error: x'), 'Camera error: x');
    expect(h.onFailure('Camera error: x'), isNull);
    h.start(100);
    expect(h.problem, isNull);
    expect(h.check(200), isNull);
  });

  test('not watching: no stall', () {
    expect(WatchHealth().check(1 << 30), isNull);
  });
}
