/// Watch my cards diagnostics: per-peek timings and a per-session summary,
/// so sampling rates and thresholds can be tuned from real nights. Pure
/// Dart: the app writes these records to a local file (watch_log_store.dart),
/// the desktop harness (tool/watch_lab.dart) prints the same summary.
///
/// Numbers only: no images, no pixels, nothing about other players. The
/// cards in a record are the player's own cards as read.
///
/// A "peek" opens on the first gated frame with a change and closes after
/// [WatchConfig.quietMs] without one. Only peeks where something card-like
/// was seen (the reader ran at least once) are recorded; plain motion is
/// only counted.
library;

import 'dart:math' as math;

import '../poker/cards.dart';

enum PeekOutcome {
  /// First cards of the hand.
  logged,

  /// Same cards again (silent).
  confirmed,
  corrected,
  newHand,

  /// A pair was agreed but the hand tracker ignored it (vetoed / a pair).
  ignored,

  /// The peek ended without an agreed pair.
  abandoned,
}

class PeekRecord {
  /// First gated frame with a change (ms on the frame clock).
  final int startMs;

  /// The gate check before [startMs]: the change happened somewhere in
  /// between, so `startMs - prevGateMs` bounds the detection lag.
  final int prevGateMs;

  /// First frame processed at the burst (high) rate.
  int? burstMs;

  /// First frame where the reader saw at least one confident card.
  int? firstReadableMs;

  /// When enough frames agreed on both cards.
  int? confidentMs;
  int endMs;

  int framesSeen = 0, framesGated = 0, framesCandidate = 0, framesRead = 0;

  /// Reads with at least one confident card.
  int framesReadable = 0;

  /// Agreeing frames for the best pair (at the confident read, or when the
  /// cards vanished).
  int agree = 0;

  /// Highest reader confidence seen (0..1).
  double bestScore = 0;
  List<int>? cards;
  PeekOutcome outcome = PeekOutcome.abandoned;

  /// The very first read of the peek already had confident cards, i.e. the
  /// cards were readable before the burst began; the gap they were visible
  /// unseen is at most [lateBurstGapMs].
  int? lateBurstGapMs;

  PeekRecord(this.startMs, this.prevGateMs) : endMs = startMs;

  bool get hit => confidentMs != null;

  /// Readable cards that vanished before enough frames agreed.
  bool get nearMiss => !hit && framesReadable > 0;

  /// Card-like change, the reader ran, never a confident card.
  bool get miss => !hit && framesReadable == 0;

  int? get msToReadable => firstReadableMs == null ? null : firstReadableMs! - startMs;
  int? get msToConfident => confidentMs == null ? null : confidentMs! - startMs;

  Map<String, Object?> toJson() => {
        'type': 'peek',
        'start': startMs,
        'detectLagMaxMs': startMs - prevGateMs,
        'burstMs': burstMs == null ? null : burstMs! - startMs,
        'readableMs': msToReadable,
        'confidentMs': msToConfident,
        'durationMs': endMs - startMs,
        'frames': {
          'seen': framesSeen,
          'gated': framesGated,
          'candidate': framesCandidate,
          'read': framesRead,
          'readable': framesReadable,
        },
        'agree': agree,
        'bestScore': double.parse(bestScore.toStringAsFixed(2)),
        'cards': cards?.map(cardToString).join(' '),
        'outcome': outcome.name,
        'nearMiss': nearMiss,
        'lateBurstGapMs': lateBurstGapMs,
      };

  @override
  String toString() {
    String ms(int? v) => v == null ? '-' : '${v}ms';
    return 'peek @${(startMs / 1000).toStringAsFixed(1)}s ${outcome.name.padRight(9)} '
        '${cards == null ? '-    ' : prettyCards(cards!)} readable ${ms(msToReadable)} '
        'confident ${ms(msToConfident)} agree $agree read $framesRead/$framesCandidate '
        'best ${bestScore.toStringAsFixed(2)}${nearMiss ? ' NEAR-MISS' : ''}'
        '${lateBurstGapMs != null ? ' late-burst<=${lateBurstGapMs}ms' : ''}';
  }
}

/// Frame counts per pipeline stage over a whole session.
class StageCounts {
  /// Every frame delivered by the camera.
  int seen = 0;

  /// Frames the cheap change gate looked at (idle or burst rate).
  int gated = 0;

  /// Gated frames with a card-like change.
  int candidate = 0;

  /// Frames sent to the expensive card reader.
  int read = 0;

  /// Reader time, summed (ms), when the caller measures it.
  int readMs = 0;

  /// Distinct motion events (peeks plus plain motion).
  int motionEvents = 0;
}

int? _pct(List<int> xs, double p) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  return s[math.min(s.length - 1, (p * (s.length - 1)).round())];
}

class WatchSessionSummary {
  final int durationMs;
  final StageCounts frames;
  final List<PeekRecord> peeks;

  /// (ms since start, battery %), when available.
  final List<(int, int)> battery;

  WatchSessionSummary(this.durationMs, this.frames, this.peeks, {this.battery = const []});

  int get hits => peeks.where((p) => p.hit).length;
  int get nearMisses => peeks.where((p) => p.nearMiss).length;
  int get misses => peeks.where((p) => p.miss).length;
  int get lateBursts => peeks.where((p) => p.lateBurstGapMs != null).length;
  int count(PeekOutcome o) => peeks.where((p) => p.outcome == o).length;

  List<int> get _toConfident => [for (final p in peeks) if (p.msToConfident != null) p.msToConfident!];
  List<int> get _toReadable => [for (final p in peeks) if (p.msToReadable != null) p.msToReadable!];

  double perMinute(int n) => durationMs <= 0 ? 0 : n * 60000 / durationMs;

  /// Battery drop per hour from the first and last sample, or null.
  double? get batteryPerHour {
    if (battery.length < 2) return null;
    final (t0, b0) = battery.first;
    final (t1, b1) = battery.last;
    if (t1 - t0 < 10 * 60000) return null;
    return (b0 - b1) * 3600000 / (t1 - t0);
  }

  Map<String, Object?> toJson() => {
        'type': 'summary',
        'durationMin': double.parse((durationMs / 60000).toStringAsFixed(1)),
        'peeks': peeks.length,
        'hits': hits,
        'nearMisses': nearMisses,
        'misses': misses,
        'lateBursts': lateBursts,
        'outcomes': {for (final o in PeekOutcome.values) o.name: count(o)},
        'msToReadable': {'median': _pct(_toReadable, 0.5), 'p90': _pct(_toReadable, 0.9)},
        'msToConfident': {'median': _pct(_toConfident, 0.5), 'p90': _pct(_toConfident, 0.9)},
        'framesPerMin': {
          'seen': perMinute(frames.seen).round(),
          'gated': perMinute(frames.gated).round(),
          'candidate': perMinute(frames.candidate).round(),
          'read': perMinute(frames.read).round(),
        },
        'readerMsPerMin': perMinute(frames.readMs).round(),
        'motionEvents': frames.motionEvents,
        'battery': [for (final (t, b) in battery) [t ~/ 60000, b]],
        'batteryPerHour': batteryPerHour == null ? null : double.parse(batteryPerHour!.toStringAsFixed(1)),
      };

  /// Human-readable block (harness output and the exported file's header).
  String describe() {
    final j = toJson();
    final fpm = j['framesPerMin'] as Map;
    final r = j['msToReadable'] as Map, c = j['msToConfident'] as Map;
    return [
      'duration ${j['durationMin']} min, motion events ${frames.motionEvents}, peeks ${peeks.length}',
      'hits $hits, near-misses $nearMisses, misses $misses, late bursts $lateBursts',
      'outcomes ${(j['outcomes'] as Map).entries.where((e) => e.value != 0).map((e) => '${e.key} ${e.value}').join(', ')}',
      'ms to first readable frame: median ${r['median']} p90 ${r['p90']}',
      'ms to confident read:       median ${c['median']} p90 ${c['p90']}',
      'frames/min: seen ${fpm['seen']}, gated ${fpm['gated']}, card-like ${fpm['candidate']}, '
          'read ${fpm['read']} (reader ${j['readerMsPerMin']} ms/min)',
      if (battery.isNotEmpty)
        'battery ${battery.map((e) => '${e.$1 ~/ 60000}min:${e.$2}%').join(' ')}'
            '${batteryPerHour == null ? '' : ' (${batteryPerHour!.toStringAsFixed(1)} %/h)'}',
    ].join('\n');
  }
}
