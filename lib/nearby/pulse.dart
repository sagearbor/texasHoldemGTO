/// Radar pulse: every phone in the night takes a short dense burst of
/// Bluetooth readings at about the same moment, so the seat radar gets
/// fresh, many-sample data at once instead of waiting a minute for the
/// slow 15-second windows. No internet needed.
///
/// The host starts a pulse (the radar's Pulse button, the radar opening, a
/// new phone joining) by bumping a counter in its game advert
/// (ble_payload.dart, byte 15; older builds ignore it). It then scans
/// without a break for [pulseMs]. Every joined phone that hears a counter
/// it has not seen does the same on its next scan round. Each phone keeps
/// every RSSI reading of the burst and writes one compact `sense` event
/// (`pulse`: the counter; per peer the count, median and MAD) that it
/// uploads at once. The host fetches the night 5 s and 15 s after its own
/// burst. At most one pulse per [pulseGapMs]. Pure Dart.
///
/// Android already advertises (ADVERTISE_MODE_LOW_LATENCY) and scans
/// (SCAN_MODE_LOW_LATENCY, every advert) at the fastest settings all the
/// time in a game; what a pulse changes is a 5-second scan with no gap,
/// right away, and an immediate upload. iPhones scan with duplicates.
library;

import 'sense.dart';

/// One burst: this long a scan.
const pulseMs = 5000;

/// At most one pulse per this long (host and joiners alike).
const pulseGapMs = 20000;

/// The host's side: when a pulse may start, and its counter.
class PulseHost {
  final int gapMs;
  PulseHost({this.gapMs = pulseGapMs});

  /// The counter in the advert (0 until the first pulse).
  int counter = 0;

  /// When the last pulse started (this phone's clock), or null.
  int? lastMs;

  /// A pulse was asked for during the gap: it starts when the gap ends.
  String? pendingWhy;

  /// Asks for a pulse at [nowMs] for [why] ("button", "radar", "join").
  /// Returns true when it starts now (the counter has moved on); false
  /// when it waits for the gap ([dueInMs] says how long).
  bool request(int nowMs, String why) {
    if (lastMs != null && nowMs - lastMs! < gapMs) {
      pendingWhy ??= why;
      return false;
    }
    _start(nowMs);
    return true;
  }

  /// Milliseconds until a pulse may start (0: now).
  int dueInMs(int nowMs) => lastMs == null ? 0 : (lastMs! + gapMs - nowMs).clamp(0, gapMs);

  /// The gap is over and one was asked for meanwhile: start it. Returns
  /// the reason, or null when nothing was waiting (or it is too early).
  String? takePending(int nowMs) {
    final w = pendingWhy;
    if (w == null || dueInMs(nowMs) > 0) return null;
    pendingWhy = null;
    _start(nowMs);
    return w;
  }

  void _start(int nowMs) {
    lastMs = nowMs;
    counter = counter >= 255 ? 1 : counter + 1;
  }
}

/// A joined phone's side: which host counter it last answered.
class PulseFollower {
  final int gapMs;
  PulseFollower({this.gapMs = pulseGapMs});

  int? _seen;
  int? _lastMs;

  /// The host's advert says [counter] at [nowMs]: true when this phone
  /// should take a burst now (a new, non-zero counter, and not within the
  /// gap of its last burst). The first counter heard after joining counts
  /// as new: the joining phone is the one the radar wants to hear.
  bool heard(int counter, int nowMs) {
    if (counter == 0 || counter == _seen) return false;
    _seen = counter;
    if (_lastMs != null && nowMs - _lastMs! < gapMs) return false;
    _lastMs = nowMs;
    return true;
  }

  /// A new night: forget the old counter.
  void reset() {
    _seen = null;
    _lastMs = null;
  }
}

/// Median absolute deviation of [xs] (not empty), in the same units.
double mad(List<num> xs) {
  final m = median(xs);
  return median([for (final x in xs) (x - m).abs()]);
}

/// Every reading of one burst, peer key -> RSSI values.
class PulseBurst {
  final int counter;
  final String why;
  final int startMs;
  final Map<String, List<int>> _rssi = {};
  final Map<String, int> _tx = {};
  PulseBurst(this.counter, this.startMs, {this.why = 'heard'});

  void add(Map<String, (List<int>, int?)> peers) {
    for (final e in peers.entries) {
      (_rssi[e.key] ??= []).addAll(e.value.$1);
      if (e.value.$2 != null) _tx[e.key] = e.value.$2!;
    }
  }

  int get readings => _rssi.values.fold(0, (a, l) => a + l.length);

  /// The `sense` event's data: the usual `p: [[peer, median dBm, count,
  /// tx?]]` (so the radar reads it like any window, weighted by its many
  /// readings) plus `pulse` (the counter), `why`, and `mad: [[peer, MAD
  /// dB x10]]`.
  Map<String, Object?> summary(int nowMs, {Map<String, Object?> extra = const {}}) => {
        'w': nowMs - startMs,
        'n': 1,
        'pulse': counter,
        'why': why,
        'p': [
          for (final e in _rssi.entries)
            [e.key, median(e.value).round(), e.value.length, if (_tx[e.key] != null) _tx[e.key]],
        ],
        'mad': [
          for (final e in _rssi.entries) [e.key, (mad(e.value) * 10).round()],
        ],
        ...extra,
      };
}
