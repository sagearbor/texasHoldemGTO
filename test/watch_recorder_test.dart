import 'package:felt_notes/camera/watch_recorder.dart';
import 'package:felt_notes/record/record_log.dart';
import 'package:felt_notes/record/record_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WatchStillPacer', () {
    test('about one still a second at 15 fps', () {
      final p = WatchStillPacer();
      var taken = 0;
      for (var t = 0; t < 10000; t += 67) {
        if (p.due(t)) {
          taken++;
          p.claim();
          p.done();
        }
      }
      expect(taken, inInclusiveRange(10, 11));
    });

    test('a busy encoder skips the still instead of queueing it', () {
      final p = WatchStillPacer();
      expect(p.due(0), isTrue);
      p.claim(); // encoding takes long
      var taken = 0;
      for (var t = 67; t < 3000; t += 67) {
        if (p.due(t)) taken++;
      }
      expect(taken, 0);
      expect(p.skippedBusy, 2);
      p.done();
      // Back on the cadence at the next slot, not a burst of catch-up.
      final after = [for (var t = 3015; t < 5000; t += 67) if (p.due(t)) t];
      expect(after, hasLength(2));
    });

    test('a wide still in flight holds the normal still back', () {
      final p = WatchStillPacer();
      p.claim(); // wide still encoding
      expect(p.due(0), isFalse);
      p.done();
      expect(p.due(1000), isTrue);
    });
  });

  test('warnings: storage low and hot, never unplugged; "no photo" only when recording', () {
    final c = WatchConditions()
      ..free = 500 << 20
      ..thermal = 'serious'
      ..charging = false;
    expect(watchWarnings(c, bytesPerHour: 0), [RecordWarning.hot, RecordWarning.storageLow]);
    c
      ..free = 20 << 30
      ..thermal = 'nominal';
    expect(watchWarnings(c, bytesPerHour: 1 << 30), isEmpty);
    expect(watchWarnings(c, bytesPerHour: 1 << 30, msSincePhoto: 12000), [RecordWarning.stalled]);
  });

  test('a Watch recording log reads back like a Record session', () {
    final sink = MemoryLineSink();
    var ms = 0;
    final w = RecordLogWriter(sink, wallMs: () => 1762300000000 + ms, elapsedMs: () => ms);
    w.write('session_start', {'session': 'x', 'mode': 'watch'});
    ms = 1000;
    w.write('photo', {'bytes': 300000});
    w.write('watch_decision', {'action': 'fill'});
    final open = summarizeRecordLog(sink.lines);
    expect(open.interrupted, isTrue);
    expect(open.start?['mode'], 'watch');
    expect(open.photos, 1);
    w.write('stop', {});
    expect(summarizeRecordLog(sink.lines).closed, isTrue);
  });
}
