import 'package:felt_notes/camera/watch_dark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dark for 20 s warns once; brighter clears; a short dip does nothing', () {
    final d = WatchDark();
    final got = <(int, DarkEvent)>[];
    void run(int from, int to, double luma) {
      for (var t = from; t < to; t += 1000) {
        final e = d.sample(t, luma);
        if (e != null) got.add((t, e));
      }
    }

    run(0, 10000, 80); // lit
    run(10000, 25000, 25); // a 15 s dip: no warning
    run(25000, 27000, 80);
    expect(got, isEmpty);
    run(27000, 60000, 25); // dark again for 33 s
    expect(got, [(47000, DarkEvent.warn)]);
    run(60000, 62000, 45); // a bit brighter, not clearly: still warned
    expect(d.warned, isTrue);
    run(62000, 63000, 80);
    expect(got.last, (62000, DarkEvent.clear));
    expect(d.warned, isFalse);
  });
}
