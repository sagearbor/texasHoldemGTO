// Pulse mode protocol: the shared vectors (the Wear OS and Apple Watch
// tests read the same file) and the Dart sample filter.

import 'dart:convert';
import 'dart:io';

import 'package:felt_notes/pulse/pulse_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final vectors = jsonDecode(File('test/pulse/protocol_vectors.json').readAsStringSync()) as Map<String, dynamic>;

  test('vectors are v1', () => expect(vectors['v'], 1));

  for (final v in vectors['valid'] as List) {
    test('valid: ${v['path']} ${v['json']}', () {
      final m = parsePulseMessage(v['path'] as String, v['json'] as String);
      expect(m, isNotNull);
      expect(m!.toMap(), v['expect']);
    });
  }

  for (final v in vectors['invalid'] as List) {
    test('invalid (${v['why']}): ${v['path']}', () {
      expect(parsePulseMessage(v['path'] as String, v['json'] as String), isNull);
    });
  }

  test('ctl encodes to what the watch parses', () {
    for (final c in PulseCmd.values) {
      expect(parsePulseMessage(pulsePathCtl, encodeCtl(c))!.toMap(), {'type': 'ctl', 'cmd': c.name});
    }
  });

  test('dartFilter vector: bpm 30..230, strictly newer than the last kept', () {
    final f = vectors['dartFilter'] as Map<String, dynamic>;
    final input = [for (final p in f['in'] as List) PulseSample(p[0] as int, p[1] as int)];
    final out = PulseFilter().keep(input);
    expect([for (final s in out) s.toPair()], f['out']);
  });

  test('filter keeps its place across sends', () {
    final f = PulseFilter();
    expect(f.keep(const [PulseSample(1000, 70), PulseSample(2000, 71)]).length, 2);
    // A resend of the second batch's overlap is dropped.
    expect(f.keep(const [PulseSample(2000, 71), PulseSample(3000, 72)]), const [PulseSample(3000, 72)]);
    expect(f.keep(const [PulseSample(4000, 29), PulseSample(4000, 231)]), isEmpty);
    expect(f.lastMs, 3000);
  });

  test('channel events (native forwards the watch payload)', () {
    expect(parsePulseEvent({'type': 'hr', 's': [[1, 70], [2, 71.0]]})!.toMap(), {
      'type': 'hr',
      's': [[1, 70], [2, 71]]
    });
    expect(parsePulseEvent({'type': 'state', 'running': false, 'err': 'no_permission'})!.toMap(),
        {'type': 'state', 'running': false, 'err': 'no_permission'});
    expect(parsePulseEvent({'type': 'what'}), isNull);
    expect(parsePulseEvent('nope'), isNull);
    // A broken pair is skipped, the rest kept.
    expect((parsePulseEvent({'type': 'hr', 's': [[1], [2, 70], 'x']}) as PulseHr).samples, const [PulseSample(2, 70)]);
  });
}
