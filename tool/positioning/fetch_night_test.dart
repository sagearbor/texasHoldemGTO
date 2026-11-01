// Seating experiment: download one night's uploaded logs (every phone's
// minute summaries: sense / device / seat events) for positioning.py.
// Joins the night as a read-only member with the code from the QR, like
// the TV does (one member document), and writes nothing else.
//
//   FELT_NIGHT=ABCD2345-WXYZ6789 FELT_OUT=tmp/night.json \
//     flutter test tool/positioning/fetch_night_test.dart
//   python3 tool/positioning/positioning.py tmp/night.json -o tmp/seating.html
//
// The phones' own local sense/<night>.jsonl files have every reading (not
// just the minute medians); positioning.py takes those too.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:felt_notes/sync/night_events.dart';
import 'package:flutter_test/flutter_test.dart';

import '../e2e/rest_cloud_logs.dart';

void main() {
  final code = Platform.environment['FELT_NIGHT'] ?? '';
  final out = Platform.environment['FELT_OUT'] ?? 'night.json';
  test('fetch a night', () async {
    final t = JoinTicket.parse(code);
    if (t == null) {
      markTestSkipped('set FELT_NIGHT to the night code (ABCD2345-WXYZ6789)');
      return;
    }
    final cloud = RestCloudLogs('analysis');
    await cloud.join(t, deviceId: randomCode(Random.secure(), deviceIdLength), name: 'Analysis', create: false);
    final logs = await cloud.fetch(t.nightId);
    await File(out).writeAsString(const JsonEncoder.withIndent(' ').convert({
      'night': t.nightId,
      'logs': [
        for (final l in logs) {'deviceId': l.deviceId, 'events': [for (final e in l.events) e.toJson()]},
      ],
    }));
    // ignore: avoid_print
    print('${logs.length} phones -> $out');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
