/// What the TV shows for Pulse mode, from a [PulseNight] (pure Dart, no
/// I/O): one line per player for the last [chartSpanMs], who leads, when a
/// song plays ([SongDj]) and the end-of-night awards ([pulseSummary]).
library;

import 'dart:collection';
import 'dart:math';

import 'pulse_cloud.dart';
import 'pulse_profile.dart';
import 'pulse_protocol.dart';

/// The chart shows this much (10 minutes).
const chartSpanMs = 10 * 60000;

/// A player whose newest sample is older than this is not live (no bpm
/// label, cannot lead).
const pulseLiveMs = 30000;

/// Leading means: strictly above every other live player, by the average
/// of the last [leadSmoothMs] (one noisy beat does not flip the lead).
const leadSmoothMs = 5000;

/// A song plays once its player has led this long ...
const songLeadMs = 10000;

/// ... and then no song plays for this long (counted from its start).
const songCooldownMs = 2 * 60000;

/// Line colours in fixed order (validated for the dark TV background and
/// colour-blind viewers; the face circle and name carry identity too).
const pulseColours = [
  0xFF3987E5, // blue
  0xFFD95926, // orange
  0xFF199E70, // aqua
  0xFFC98500, // yellow
  0xFFD55181, // magenta
  0xFF008300, // green
  0xFF9085E9, // violet
  0xFFE66767, // red
];

class PulseLine {
  final PulseMember member;

  /// Index into [pulseColours].
  final int colour;

  /// Samples inside the chart window, oldest first.
  final List<PulseSample> visible;

  /// The current bpm (smoothed), or null when the player is not live.
  final int? bpm;
  final bool leader;

  const PulseLine({required this.member, required this.colour, required this.visible, this.bpm, this.leader = false});

  String get deviceId => member.deviceId;
  bool get live => bpm != null;
}

class PulseBoard {
  final List<PulseLine> lines;
  final String? leader;
  final int fromMs, toMs;

  /// The y range to draw (data range with a margin, at least 30 bpm tall).
  final int minBpm, maxBpm;

  const PulseBoard(
      {required this.lines, this.leader, required this.fromMs, required this.toMs, this.minBpm = 50, this.maxBpm = 110});

  bool get isEmpty => lines.isEmpty;
  PulseLine? get leaderLine => lines.where((l) => l.leader).firstOrNull;
}

/// The average bpm of [s] over the [ms] before its newest sample.
int _recent(List<PulseSample> s, int ms) {
  final last = s.last.tMs;
  var sum = 0, n = 0;
  for (var i = s.length - 1; i >= 0 && s[i].tMs > last - ms; i--) {
    sum += s[i].bpm;
    n++;
  }
  return (sum / n).round();
}

/// The live player strictly above everyone else live (a lone live player
/// leads too), or null on a tie or when nobody is live.
String? leaderOf(Map<String, int> liveBpm) {
  String? best;
  var top = -1, second = -1;
  for (final e in liveBpm.entries) {
    if (e.value > top) {
      second = top;
      top = e.value;
      best = e.key;
    } else if (e.value > second) {
      second = e.value;
    }
  }
  return best != null && top > second ? best : null;
}

PulseBoard buildPulseBoard(PulseNight n, {required int nowMs, int spanMs = chartSpanMs}) {
  final from = nowMs - spanMs;
  // Colour by order of first heart rate, so a colour stays with its player.
  final order = n.members.values.toList()
    ..sort((a, b) {
      final fa = n.samples[a.deviceId]?.firstOrNull?.tMs ?? 1 << 52;
      final fb = n.samples[b.deviceId]?.firstOrNull?.tMs ?? 1 << 52;
      return fa != fb ? fa.compareTo(fb) : a.deviceId.compareTo(b.deviceId);
    });
  final live = <String, int>{};
  for (final m in order) {
    final s = n.samples[m.deviceId];
    if (s == null || s.isEmpty || nowMs - s.last.tMs > pulseLiveMs) continue;
    live[m.deviceId] = _recent(s, leadSmoothMs);
  }
  final leader = leaderOf(live);
  var lo = 1000, hi = 0;
  final lines = <PulseLine>[];
  for (var i = 0; i < order.length; i++) {
    final m = order[i];
    final vis = [for (final x in n.samples[m.deviceId] ?? const <PulseSample>[]) if (x.tMs >= from && x.tMs <= nowMs) x];
    for (final x in vis) {
      lo = min(lo, x.bpm);
      hi = max(hi, x.bpm);
    }
    if (vis.isEmpty && !live.containsKey(m.deviceId)) continue;
    lines.add(PulseLine(
        member: m, colour: i % pulseColours.length, visible: vis, bpm: live[m.deviceId], leader: m.deviceId == leader));
  }
  if (hi == 0) {
    lo = 60;
    hi = 90;
  }
  var a = (lo - 5) ~/ 5 * 5, b = ((hi + 5) / 5).ceil() * 5;
  if (b - a < 30) {
    final mid = (a + b) ~/ 2;
    a = mid - 15;
    b = mid + 15;
  }
  return PulseBoard(lines: lines, leader: leader, fromMs: from, toMs: nowMs, minBpm: max(30, a), maxBpm: min(230, b));
}

// ------------------------------------------------------------------ songs

/// The TV's song rule: a player's song starts once they have led for
/// [songLeadMs]; after a song starts, none plays for [songCooldownMs].
/// A leader without a song plays nothing (and starts no cooldown).
class SongDj {
  final int leadMs, cooldownMs;
  SongDj({this.leadMs = songLeadMs, this.cooldownMs = songCooldownMs});

  String? _leader;
  int _since = 0;
  int? lastStartMs;

  /// The player whose song should start now, at most once per lead.
  PulseMember? tick(int nowMs, PulseBoard board) {
    final l = board.leader;
    if (l != _leader) {
      _leader = l;
      _since = nowMs;
    }
    if (l == null || nowMs - _since < leadMs) return null;
    final last = lastStartMs;
    if (last != null && nowMs - last < cooldownMs) return null;
    final m = board.leaderLine?.member;
    if (m?.song == null) return null;
    lastStartMs = nowMs;
    return m;
  }
}

// ---------------------------------------------------------------- summary

/// One award line.
class PulseAward {
  final PulseMember member;

  /// calmest: average bpm above their own resting; spike: the jump;
  /// highest: the bpm.
  final num value;

  /// spike: the bpm it jumped from.
  final int? from;
  final int? atMs;

  /// The hand being played then, when the night had hands.
  final int? hand;
  const PulseAward(this.member, this.value, {this.from, this.atMs, this.hand});
}

class PulseSummary {
  final PulseAward? calmest, spike, highest;
  const PulseSummary({this.calmest, this.spike, this.highest});
  bool get isEmpty => calmest == null && spike == null && highest == null;
}

/// A player needs this many samples to be "calmest" (a few minutes).
const calmMinSamples = 120;

/// A spike is the rise from the lowest bpm of the minute before.
const spikeWindowMs = 60000;

/// A player's resting rate: their 10th percentile over the night.
int restingOf(List<PulseSample> s) {
  final b = [for (final x in s) x.bpm]..sort();
  return b[(b.length - 1) * 10 ~/ 100];
}

/// The hand number at [ms], from (n, startMs, endMs) spans.
int? Function(int ms) handFinder(Iterable<(int, int, int)> hands) => (ms) {
      for (final (n, a, b) in hands) {
        if (ms >= a && ms < b) return n;
      }
      return null;
    };

PulseSummary pulseSummary(PulseNight n, {int? Function(int ms)? handAt}) {
  PulseAward? calm, spike, high;
  double? calmV;
  for (final m in n.members.values) {
    final s = n.samples[m.deviceId] ?? const <PulseSample>[];
    if (s.isEmpty) continue;
    // Highest.
    var top = s.first;
    for (final x in s) {
      if (x.bpm > top.bpm) top = x;
    }
    if (high == null || top.bpm > (high.value as int)) {
      high = PulseAward(m, top.bpm, atMs: top.tMs, hand: handAt?.call(top.tMs));
    }
    // Biggest spike: a sliding minimum over the minute before each sample.
    final q = Queue<PulseSample>(); // increasing bpm, front = minimum
    var best = 0;
    PulseSample? at;
    int? fromBpm;
    var lo = 0;
    for (var i = 0; i < s.length; i++) {
      final x = s[i];
      while (lo < i && s[lo].tMs < x.tMs - spikeWindowMs) {
        if (q.isNotEmpty && identical(q.first, s[lo])) q.removeFirst();
        lo++;
      }
      if (q.isNotEmpty && x.bpm - q.first.bpm > best) {
        best = x.bpm - q.first.bpm;
        at = x;
        fromBpm = q.first.bpm;
      }
      while (q.isNotEmpty && q.last.bpm >= x.bpm) {
        q.removeLast();
      }
      q.addLast(x);
    }
    if (at != null && (spike == null || best > (spike.value as int))) {
      spike = PulseAward(m, best, from: fromBpm, atMs: at.tMs, hand: handAt?.call(at.tMs));
    }
    // Calmest.
    if (s.length >= calmMinSamples) {
      final rest = restingOf(s);
      final avg = s.fold<int>(0, (a, x) => a + x.bpm) / s.length;
      final above = avg - rest;
      if (calmV == null || above < calmV) {
        calmV = above;
        calm = PulseAward(m, (above * 10).round() / 10);
      }
    }
  }
  return PulseSummary(calmest: calm, spike: spike, highest: high);
}

/// The song to show as "now playing" text.
String songLine(PulseSong s) => '${s.title} · ${s.artist}';
