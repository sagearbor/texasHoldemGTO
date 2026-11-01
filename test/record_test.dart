import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

import 'package:felt_notes/record/record_log.dart';
import 'package:felt_notes/record/record_session.dart';
import 'package:felt_notes/record/record_storage.dart';
import 'package:felt_notes/record/seat_zones.dart';
import 'package:flutter_test/flutter_test.dart';

const _lens = LensInfo('ultra_wide', 'back0', zoom: 0.5, minZoom: 0.5);

void main() {
  group('RecordLogWriter', () {
    test('every line has UTC ms ISO time, monotonic m, run and kind', () {
      final sink = MemoryLineSink();
      var wall = DateTime.utc(2026, 11, 5, 23, 15, 2, 123).millisecondsSinceEpoch;
      var el = 0;
      final w = RecordLogWriter(sink, wallMs: () => wall, elapsedMs: () => el);
      w.write('session_start', {'session': 'X'});
      el = 667;
      wall += 667;
      w.write('photo', {'n': 1});
      final a = jsonDecode(sink.lines[0]) as Map, b = jsonDecode(sink.lines[1]) as Map;
      expect(a['t'], '2026-11-05T23:15:02.123Z');
      expect(b['t'], '2026-11-05T23:15:02.790Z');
      expect(a['m'], 0);
      expect(b['m'], 667);
      expect(a['r'], 1);
      expect(a['k'], 'session_start');
      expect(a['session'], 'X');
    });

    test('m never goes back, even if the sources do', () {
      final sink = MemoryLineSink();
      var el = 500;
      final w = RecordLogWriter(sink, wallMs: () => 0, elapsedMs: () => el, baseM: 1000);
      w.write('a');
      el = 400; // a broken clock source
      w.write('b');
      w.write('c');
      final ms = [for (final l in sink.lines) (jsonDecode(l) as Map)['m'] as int];
      expect(ms, [1500, 1501, 1502]);
    });

    test('resume base continues after the last line plus the time away', () {
      expect(resumeBaseMs(nowWallMs: 5), 0);
      expect(resumeBaseMs(lastM: 1000, lastWallMs: 10000, nowWallMs: 70000), 1000 + 60000 + 1);
      // Wall clock set back while the app was gone: never below lastM.
      expect(resumeBaseMs(lastM: 1000, lastWallMs: 10000, nowWallMs: 5000), 1001);
    });

    test('summary reads a log back and skips a torn last line', () {
      final sink = MemoryLineSink();
      var el = 0;
      final w = RecordLogWriter(sink, wallMs: () => 1730848502123 + el, elapsedMs: () => el);
      w.write('session_start', {'session': 'S1', 'players': 7});
      w.write('segment_start', {'seg': 1});
      el = 1000;
      w.write('photo', {'bytes': 400});
      el = 2000;
      w.write('photo', {'bytes': 600});
      w.write('mark', {'n': 1});
      final lines = [...sink.lines, '{"t":"2026-11-0'];
      final s = summarizeRecordLog(lines);
      expect(s.sessionId, 'S1');
      expect(s.photos, 2);
      expect(s.photoBytes, 1000);
      expect(s.segments, 1);
      expect(s.marks, 1);
      expect(s.closed, isFalse);
      expect(s.interrupted, isTrue);
      expect(s.lastM, 2001);
      expect(s.runs, 1);
      expect(s.durationMs, 2000);
      expect(s.start?['players'], 7);

      w.write('stop');
      expect(summarizeRecordLog(sink.lines).interrupted, isFalse);
    });

    test('a resumed run continues m and counts runs', () {
      final sink = MemoryLineSink();
      final w1 = RecordLogWriter(sink, wallMs: () => 1000, elapsedMs: () => 50);
      w1.write('session_start', {'session': 'S'});
      final s1 = summarizeRecordLog(sink.lines);
      final w2 = RecordLogWriter(sink,
          wallMs: () => 4000,
          elapsedMs: () => 0,
          baseM: resumeBaseMs(lastM: s1.lastM, lastWallMs: s1.lastWallMs, nowWallMs: 4000),
          run: s1.runs + 1);
      w2.write('resume_session');
      final s2 = summarizeRecordLog(sink.lines);
      expect(s2.runs, 2);
      expect(s2.lastM, 50 + 3000 + 1);
      expect(s2.interrupted, isTrue);
    });
  });

  group('RecordSession', () {
    test('framing, record, pause, mark, move, stop', () {
      final s = RecordSession(PhonePosition.end, _lens);
      expect(s.phase, RecordPhase.framing);
      expect(s.capturing, isFalse);
      final seg = s.segmentStart(width: 1920, height: 1080, rotation: 0);
      expect(seg.$1, 'segment_start');
      expect(seg.$2['position'], 'end');
      expect((seg.$2['lens'] as Map)['kind'], 'ultra_wide');
      expect(s.framingDone(skipped: true).$2['skipped'], isTrue);
      expect(s.capturing, isTrue);
      expect(s.photoSaved('s01/000001-1.jpg', 400).$2['n'], 1);
      expect(s.pause().$1, 'pause');
      expect(s.capturing, isFalse);
      expect(() => s.pause(), throwsStateError);
      expect(s.mark().$2['n'], 1);
      expect(s.resume().$1, 'resume');
      final moved = s.moved(PhonePosition.side, const LensInfo('wide', 'back0'));
      expect(moved.single.$1, 'segment_end');
      expect(moved.single.$2['photos'], 1);
      expect(s.phase, RecordPhase.framing);
      expect(s.segment.n, 2);
      expect(s.segment.folder, 's02');
      expect(s.segment.position, PhonePosition.side);
      s.framingDone();
      s.photoSaved('s02/000002-2.jpg', 600);
      final stop = s.stop(durationMs: 5000);
      expect(stop.map((e) => e.$1), ['segment_end', 'stop']);
      expect(stop.last.$2['photos'], 2);
      expect(stop.last.$2['bytes'], 1000);
      expect(stop.last.$2['segments'], 2);
      expect(s.phase, RecordPhase.stopped);
      expect(() => s.mark(), throwsStateError);
      expect(() => s.stop(durationMs: 1), throwsStateError);
    });

    test('no photos while in the background', () {
      final s = RecordSession(PhonePosition.end, _lens)..framingDone();
      expect(s.setBackground(true).$1, 'background');
      expect(s.capturing, isFalse);
      expect(s.setBackground(false).$1, 'foreground');
      expect(s.capturing, isTrue);
    });

    test('a resumed session continues segment, photo and mark numbers', () {
      final s = RecordSession(PhonePosition.other, _lens, firstSegment: 3, photos: 10, marks: 2);
      s.framingDone();
      expect(s.segment.n, 3);
      expect(s.photoSaved('s03/x.jpg', 1).$2['n'], 11);
      expect(s.mark().$2['n'], 3);
    });
  });

  group('CapturePacer', () {
    test('one frame per interval, none while busy, keeps cadence', () {
      final p = CapturePacer(500);
      expect(p.due(0), isTrue);
      expect(p.due(100), isFalse); // busy
      p.done();
      expect(p.due(400), isFalse); // too soon
      expect(p.due(520), isTrue); // slot 500
      p.done();
      expect(p.due(990), isFalse);
      expect(p.due(1001), isTrue); // slot 1000, not 1020
      p.done();
      // A long gap (paused) restarts the cadence instead of bursting.
      expect(p.due(5000), isTrue);
      p.done();
      expect(p.due(5200), isFalse);
      expect(p.due(5500), isTrue);
    });

    test('rates', () {
      expect(intervalForRate(1.5), 667);
      expect(intervalForRate(2), 500);
    });
  });

  group('warnings', () {
    test('each condition', () {
      List<RecordWarning> w({bool cap = true, bool? ch = true, int? since = 0, int? free = 10 << 30, String th = 'nominal'}) =>
          recordWarnings(capturing: cap, charging: ch, msSincePhoto: since, freeBytes: free, bytesPerHour: 3 << 30, thermal: th);
      expect(w(), isEmpty);
      expect(w(ch: false), [RecordWarning.unplugged]);
      expect(w(ch: null), isEmpty);
      expect(w(since: 10001), [RecordWarning.stalled]);
      expect(w(since: 10001, cap: false), isEmpty);
      expect(w(free: 900 << 20), [RecordWarning.storageLow]);
      // 1.2 GB free at 3 GB/h is under half an hour.
      expect(w(free: 1200 << 20), [RecordWarning.storageLow]);
      expect(w(th: 'serious'), [RecordWarning.hot]);
      expect(w(th: 'fair'), isEmpty);
    });
  });

  group('viewMatch', () {
    Uint8List grid(int Function(int) f) => Uint8List.fromList([for (var i = 0; i < 144; i++) f(i)]);
    test('same view high, other view low, flat null', () {
      final a = grid((i) => (i * 37) % 200 + 20);
      final noisy = grid((i) => ((i * 37) % 200 + 20 + (i % 3) * 4).clamp(0, 255));
      expect(viewMatch(a, a), closeTo(1, 1e-9));
      expect(viewMatch(a, noisy)!, greaterThan(0.95));
      final other = grid((i) => (i * 91 + 13) % 230);
      expect(viewMatch(a, other)!, lessThan(0.5));
      expect(viewMatch(a, grid((_) => 0)), isNull);
      expect(viewMatch(a, Uint8List(3)), isNull);
    });
  });

  group('seatZones', () {
    test('one box per other player, inside the picture, far seats smaller', () {
      for (final pos in PhonePosition.values) {
        for (var n = 2; n <= 10; n++) {
          final z = seatZones(n, pos);
          expect(z.length, n - 1);
          for (final r in z) {
            expect(r.left, greaterThanOrEqualTo(0));
            expect(r.top, greaterThanOrEqualTo(0));
            expect(r.right, lessThanOrEqualTo(1.0 + 1e-9));
            expect(r.bottom, lessThanOrEqualTo(1.0 + 1e-9));
          }
        }
      }
      final z = seatZones(9, PhonePosition.end);
      // Seat 1 is left-near, the last is right-near, the middle is far.
      expect(z.first.center.dx, lessThan(0.3));
      expect(z.last.center.dx, greaterThan(0.7));
      final mid = z[z.length ~/ 2];
      expect(mid.center.dy, lessThan(z.first.center.dy));
      expect(mid.width, lessThan(z.first.width));
      expect(seatZones(1, PhonePosition.end), isEmpty);
    });
  });

  test('zipFolder stores the session under its own name', () async {
    final tmp = await Directory.systemTemp.createTemp('rec');
    final src = Directory('${tmp.path}/20261105-231502-K7QX');
    await Directory('${src.path}/s01').create(recursive: true);
    await File('${src.path}/session.jsonl').writeAsString('{"k":"session_start"}\n');
    await File('${src.path}/s01/000001-1.jpg').writeAsBytes(List.filled(1000, 7));
    final out = '${tmp.path}/x.zip';
    await zipFolder(src.path, out);
    final z = ZipDecoder().decodeBytes(await File(out).readAsBytes());
    expect([for (final f in z.files) f.name],
        ['20261105-231502-K7QX/s01/000001-1.jpg', '20261105-231502-K7QX/session.jsonl']);
    expect(z.files.first.content as List<int>, List.filled(1000, 7));
    await zipFolder(src.path, '${tmp.path}/log.zip', logOnly: true);
    expect(ZipDecoder().decodeBytes(await File('${tmp.path}/log.zip').readAsBytes()).files.single.name,
        '20261105-231502-K7QX/session.jsonl');
    await tmp.delete(recursive: true);
  });

  test('session ids sort by time', () {
    final a = newSessionId(DateTime(2026, 11, 5, 23, 1, 2));
    expect(a, startsWith('20261105-230102-'));
    expect(a.length, 20);
  });

  test('labels', () {
    expect(elapsedLabel(65000), '01:05');
    expect(elapsedLabel(3723000), '1:02:03');
    expect(bytesLabel(3 << 30), '3.0 GB');
    expect(bytesLabel(5 << 20), '5 MB');
  });
}
