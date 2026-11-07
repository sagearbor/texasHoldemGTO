/// Pulse mode, the watch <-> phone protocol (docs/PULSE.md, v1) and the
/// sample filter. Pure Dart: the watch apps' own tests and the Dart test
/// read the same vectors (test/pulse/protocol_vectors.json).
///
/// Native code (Wear OS MessageClient, Apple WCSession) forwards the
/// watch's JSON unchanged; everything is validated here: bpm 30..230, and
/// a sample counts only when it is strictly newer than the last one kept.
library;

import 'dart:convert';

const pulsePathHr = '/feltnotes/pulse/v1/hr';
const pulsePathCtl = '/feltnotes/pulse/v1/ctl';
const pulsePathState = '/feltnotes/pulse/v1/state';

/// The bpm a sample may have; anything else is a sensor glitch.
const pulseMinBpm = 30, pulseMaxBpm = 230;

bool validBpm(int bpm) => bpm >= pulseMinBpm && bpm <= pulseMaxBpm;

/// One heart-rate reading: epoch ms on the watch clock, beats per minute.
class PulseSample {
  final int tMs;
  final int bpm;
  const PulseSample(this.tMs, this.bpm);

  List<int> toPair() => [tMs, bpm];

  @override
  bool operator ==(Object other) => other is PulseSample && other.tMs == tMs && other.bpm == bpm;
  @override
  int get hashCode => Object.hash(tMs, bpm);
  @override
  String toString() => '[$tMs, $bpm]';
}

sealed class PulseMessage {
  const PulseMessage();

  /// The shape the test vectors' `expect` uses.
  Map<String, Object?> toMap();
}

/// Samples since the watch's last send.
class PulseHr extends PulseMessage {
  final List<PulseSample> samples;
  const PulseHr(this.samples);
  @override
  Map<String, Object?> toMap() => {'type': 'hr', 's': [for (final s in samples) s.toPair()]};
}

/// The watch app is (not) measuring; [err] says why it cannot ("no_permission").
class PulseState extends PulseMessage {
  final bool running;
  final String? err;
  const PulseState(this.running, [this.err]);
  @override
  Map<String, Object?> toMap() => {'type': 'state', 'running': running, 'err': err};
}

enum PulseCmd { start, stop }

/// Phone -> watch.
class PulseCtl extends PulseMessage {
  final PulseCmd cmd;
  const PulseCtl(this.cmd);
  @override
  Map<String, Object?> toMap() => {'type': 'ctl', 'cmd': cmd.name};
}

String encodeCtl(PulseCmd cmd) => jsonEncode({'v': 1, 'cmd': cmd.name});

int? _int(Object? x) => x is int ? x : (x is double && x == x.roundToDouble() ? x.toInt() : null);

/// `[[tMs, bpm], ...]`; null when it is not that shape at all. Malformed
/// pairs are dropped one by one (the filter would drop them anyway).
List<PulseSample>? _samples(Object? s) {
  if (s is! List) return null;
  return [
    for (final p in s)
      if (p is List && p.length == 2 && _int(p[0]) != null && _int(p[1]) != null) PulseSample(_int(p[0])!, _int(p[1])!)
  ];
}

/// A watch payload on [path]; null for an unknown path or version, bad
/// JSON or an unknown command.
PulseMessage? parsePulseMessage(String path, String json) {
  Object? d;
  try {
    d = jsonDecode(json);
  } catch (_) {
    return null;
  }
  if (d is! Map || d['v'] != 1) return null;
  switch (path) {
    case pulsePathHr:
      final s = _samples(d['s']);
      return s == null ? null : PulseHr(s);
    case pulsePathState:
      final r = d['running'], e = d['err'];
      if (r is! bool || (e != null && e is! String)) return null;
      return PulseState(r, e as String?);
    case pulsePathCtl:
      final c = d['cmd'];
      for (final v in PulseCmd.values) {
        if (v.name == c) return PulseCtl(v);
      }
      return null;
  }
  return null;
}

/// One event from `EventChannel("feltnotes/pulse/events")`:
/// `{"type":"hr","s":[[tMs,bpm],...]}` or `{"type":"state","running":bool,"err":String?}`.
PulseMessage? parsePulseEvent(Object? e) {
  if (e is! Map) return null;
  switch (e['type']) {
    case 'hr':
      final s = _samples(e['s']);
      return s == null ? null : PulseHr(s);
    case 'state':
      final r = e['running'], err = e['err'];
      if (r is! bool) return null;
      return PulseState(r, err is String ? err : null);
  }
  return null;
}

/// Keeps samples with a plausible bpm that are strictly newer than the
/// last one kept (a watch resend or a clock step back is dropped).
class PulseFilter {
  int? lastMs;
  PulseFilter([this.lastMs]);

  List<PulseSample> keep(Iterable<PulseSample> samples) {
    final out = <PulseSample>[];
    for (final s in samples) {
      if (!validBpm(s.bpm)) continue;
      final last = lastMs;
      if (last != null && s.tMs <= last) continue;
      lastMs = s.tMs;
      out.add(s);
    }
    return out;
  }
}
