/// Record the table, developer experiment "Alternate lenses": one phone
/// takes stills from the ultra-wide (who is dealt in, who folds) and the
/// normal lens (peeks, community cards) in turn: W, N, W, N...
///
/// Method: zoom-ratio switching on the one logical back camera (Android,
/// CameraX). A ratio under 1.0 makes the camera HAL stream from the
/// ultra-wide sensor, 1.0 from the main one, inside the same session, so a
/// switch costs a few frames instead of a camera re-open (~0.5 to 1 s).
/// lens_camera.dart already opens the ultra-wide this way.
///
/// Per still: the switch to the next lens is issued right after the frame
/// is taken (the switch overlaps the wait for the next slot), then frames
/// are skipped until one is "settled": at least [LensAlternator.minSettleFrames]
/// frames after the zoom was applied with mean brightness steady between
/// two frames (auto exposure converged), or [LensAlternator.maxSettleMs]
/// after it was applied, whichever comes first. A switch that throws or
/// takes over [LensAlternator.switchTimeoutMs] ends the experiment for the
/// segment: recording goes on with the lens it was on (logged as
/// `alt_fallback`), never stalls.
///
/// Pure Dart: the camera is a [SetZoom] function and the clock is
/// injected, so the scheduler is unit tested with a fake camera.
library;

import 'dart:async';

/// The two lenses taken in turn.
enum AltLens { ultraWide, normal }

/// The lens kind as the record log names it (as [LensInfo.kind]).
String altLensKind(AltLens l) => l == AltLens.ultraWide ? 'ultra_wide' : 'wide';

AltLens otherLens(AltLens l) => l == AltLens.ultraWide ? AltLens.normal : AltLens.ultraWide;

/// Asks the camera for a zoom ratio; completes when the camera applied it
/// (CameraX: when a capture result shows the new ratio).
typedef SetZoom = Future<void> Function(double zoom);

/// One still the scheduler wants saved, with its timings in the caller's
/// clock (ms). [switchMs]..[settledMs] are null for a still taken on the
/// lens the camera was already on (the first one, or after a fallback).
class AltStill {
  final AltLens lens;
  final double zoom;

  /// False after a fallback: a single-lens still.
  final bool alternating;

  /// After a switch timed out the lens is not known for sure until the
  /// camera confirmed the way back.
  final bool lensSure;

  /// The slot this still was due at, and when the frame was taken.
  final int requestedMs;
  final int capturedMs;

  /// Switch to this lens: issued, applied by the camera, first frame after
  /// that, and the settled frame.
  final int? switchMs;
  final int? appliedMs;
  final int? firstFrameMs;
  final int? settledMs;

  /// `stable` (brightness steady) or `timeout` ([LensAlternator.maxSettleMs]).
  final String? settle;

  /// Running count of switches in this alternator.
  final int switchN;

  const AltStill({
    required this.lens,
    required this.zoom,
    required this.alternating,
    required this.lensSure,
    required this.requestedMs,
    required this.capturedMs,
    this.switchMs,
    this.appliedMs,
    this.firstFrameMs,
    this.settledMs,
    this.settle,
    this.switchN = 0,
  });

  /// The photo line's `alt` object. [toM] maps the scheduler's clock to the
  /// log's monotonic `m` (the photo line's own `m` is the saved time).
  Map<String, Object?> toJson(int Function(int) toM) {
    int? m(int? v) => v == null ? null : toM(v);
    int? d(int? v) => v == null || switchMs == null ? null : v - switchMs!;
    return {
      'on': alternating,
      if (!lensSure) 'lens_sure': false,
      'zoom': zoom,
      'req_m': toM(requestedMs),
      'cap_m': toM(capturedMs),
      'wait_ms': capturedMs - requestedMs,
      if (switchMs != null) ...{
        'sw_n': switchN,
        'sw_m': m(switchMs),
        'applied_m': m(appliedMs),
        'ff_m': m(firstFrameMs),
        'set_m': m(settledMs),
        // From the switch being issued.
        'applied_ms': d(appliedMs),
        'ff_ms': d(firstFrameMs),
        'settle_ms': d(settledMs),
        'settle': settle,
      },
    };
  }
}

enum _State { steady, switching, settling }

class LensAlternator {
  final SetZoom setZoom;
  final int Function() nowMs;

  /// Zoom ratios: the camera's minimum for the ultra-wide, 1.0 for normal.
  final double wideZoom;
  final double normalZoom;

  /// Time between stills (all lenses together): at 1.5 a second each lens
  /// gets about 0.75 a second.
  int intervalMs;

  final int switchTimeoutMs;
  final int minSettleFrames;
  final int maxSettleMs;

  /// Mean luma (0..255) change between two frames that counts as steady.
  final double stableLuma;

  /// `alt_*` lines for the session log (switch failures, fallback).
  final void Function(String kind, Map<String, Object?> fields)? onEvent;

  LensAlternator({
    required this.setZoom,
    required this.nowMs,
    required this.wideZoom,
    this.normalZoom = 1.0,
    required this.intervalMs,
    AltLens startLens = AltLens.ultraWide,
    this.switchTimeoutMs = 2000,
    this.minSettleFrames = 2,
    this.maxSettleMs = 800,
    this.stableLuma = 3,
    this.onEvent,
  }) : _lens = startLens;

  AltLens _lens;
  bool _lensSure = true;
  bool _alternating = false;
  String? _fallback;
  _State _state = _State.steady;
  bool _busy = false;
  bool _disposed = false;
  int? _due;
  int _gen = 0;
  int? _startedMs;

  /// The lens the switch in flight came from (where a failure goes back to).
  AltLens? _from;
  int _switches = 0;

  // The switch in flight (or just settled) for the next still.
  int? _swMs, _appliedMs, _ffMs, _setMs;
  String? _settle;
  int _framesSince = 0;
  double? _lastLuma;

  // Live numbers for the screen.
  final List<int> _recentSwitch = [];
  final Map<AltLens, List<int>> _savedAt = {AltLens.ultraWide: [], AltLens.normal: []};

  /// The lens the camera is on, or switching to.
  AltLens get lens => _lens;
  bool get alternating => _alternating;

  /// Why alternating stopped (null while it runs or before [start]).
  String? get fallbackReason => _fallback;
  bool get switching => _state != _State.steady;
  int get switches => _switches;

  double zoomFor(AltLens l) => l == AltLens.ultraWide ? wideZoom : normalZoom;

  /// The lens a frame arriving now is known to show, settled; null while
  /// switching or settling. The "table in view" check only compares frames
  /// from the lens of its reference.
  AltLens? get steadyLens => _state == _State.steady && _lensSure ? _lens : null;

  /// Median switch cost (issued to settled) over the last 10 switches.
  int? get switchMsMedian {
    if (_recentSwitch.isEmpty) return null;
    final s = [..._recentSwitch]..sort();
    return s[s.length ~/ 2];
  }

  /// Stills saved per second for [l] over the last [windowMs].
  double perSecond(AltLens l, {int windowMs = 30000}) {
    final now = nowMs();
    final list = _savedAt[l]!..removeWhere((t) => now - t > windowMs);
    final since = _startedMs == null ? 0 : now - _startedMs!;
    final span = since < windowMs ? since : windowMs;
    if (list.isEmpty || span < 3000) return 0;
    return list.length / (span / 1000);
  }

  /// Start (or restart, after a framing check or a fallback) taking turns,
  /// from the lens the camera is on.
  void start() {
    if (_disposed) return;
    _alternating = true;
    _fallback = null;
    _due = null;
    _startedMs = nowMs();
    onEvent?.call('alt_start', {
      'lens': altLensKind(_lens),
      'wide_zoom': wideZoom,
      'normal_zoom': normalZoom,
      'interval_ms': intervalMs,
      'settle_frames': minSettleFrames,
      'settle_max_ms': maxSettleMs,
      'stable_luma': stableLuma,
      'switch_timeout_ms': switchTimeoutMs,
    });
  }

  /// Stop taking turns and go to [l] (the framing check is always on the
  /// ultra-wide). Completes when the camera is there (or failed to go).
  Future<void> hold(AltLens l) async {
    _alternating = false;
    _due = null;
    if (_lens == l && _state == _State.steady && _lensSure) return;
    final gen = ++_gen;
    _state = _State.switching;
    _from = _lens;
    _lens = l;
    _swMs = nowMs();
    try {
      await setZoom(zoomFor(l));
      if (gen != _gen || _disposed) return;
      _lensSure = true;
    } catch (e) {
      if (gen != _gen || _disposed) return;
      _lensSure = false;
      onEvent?.call('alt_fail', {'to': altLensKind(l), 'error': '$e', 'during': 'hold'});
    }
    _state = _State.steady;
    _swMs = null;
  }

  /// Pause / resume: the cadence starts again, the lens stays.
  void reset() {
    _due = null;
    _busy = false;
  }

  /// The camera is going away (background, dispose): late callbacks from
  /// a switch in flight are ignored.
  void dispose() {
    _disposed = true;
    _gen++;
  }

  /// A frame arrived at [now] with mean luma [luma] (null: not measured,
  /// settle by frame count and time only). Returns the still to save from
  /// this frame, or null to skip it. Call [done] once it is on disk.
  /// With [take] false (not recording: framing, paused) a switch still
  /// settles but no still is taken.
  AltStill? onFrame(int now, {double? luma, bool take = true}) {
    if (_disposed) return null;
    if (_state == _State.switching) {
      if (_swMs != null && now - _swMs! > switchTimeoutMs) {
        _fail('timeout', null, now);
      } else {
        return null;
      }
    }
    if (_state == _State.settling) {
      _ffMs ??= now;
      _framesSince++;
      final last = _lastLuma;
      _lastLuma = luma;
      final enough = _framesSince >= minSettleFrames;
      final stable = luma == null || (last != null && (luma - last).abs() <= stableLuma);
      if (enough && stable) {
        _settled(now, 'stable');
      } else if (now - _appliedMs! >= maxSettleMs) {
        _settled(now, 'timeout');
      } else {
        return null;
      }
    }
    // Steady: is a still due?
    if (!take || _busy) return null;
    final due = _due;
    if (due != null && now < due) return null;
    final req = due ?? now;
    _due = now - req > 2 * intervalMs ? now + intervalMs : req + intervalMs;
    _busy = true;
    final still = AltStill(
      lens: _lens,
      zoom: zoomFor(_lens),
      alternating: _alternating,
      lensSure: _lensSure,
      requestedMs: req,
      capturedMs: now,
      switchMs: _swMs,
      appliedMs: _appliedMs,
      firstFrameMs: _ffMs,
      settledMs: _setMs,
      settle: _settle,
      switchN: _switches,
    );
    _swMs = _appliedMs = _ffMs = _setMs = null;
    _settle = null;
    // The frame is ours: switch now, so the switch overlaps the wait for
    // the next slot.
    if (_alternating) _switchTo(otherLens(_lens), now);
    return still;
  }

  /// The still is on disk (or failed): the next one may be taken. Pass
  /// [still] when it was saved, for the live per-lens rate.
  void done([AltStill? still]) {
    _busy = false;
    if (still != null) _savedAt[still.lens]!.add(nowMs());
  }

  void _settled(int now, String why) {
    _state = _State.steady;
    _setMs = now;
    _settle = why;
    _recentSwitch.add(now - _swMs!);
    if (_recentSwitch.length > 10) _recentSwitch.removeAt(0);
  }

  void _switchTo(AltLens to, int now) {
    _from = _lens;
    final gen = ++_gen;
    _switches++;
    _state = _State.switching;
    _lens = to;
    _swMs = now;
    _appliedMs = _ffMs = _setMs = null;
    _framesSince = 0;
    _lastLuma = null;
    Future<void> f;
    try {
      f = setZoom(zoomFor(to));
    } catch (e) {
      _fail('error', e, now);
      return;
    }
    f.then((_) {
      if (gen != _gen || _disposed) return;
      _appliedMs = nowMs();
      _state = _State.settling;
    }, onError: (Object e) {
      if (gen != _gen || _disposed) return;
      _fail('error', e, nowMs());
    });
  }

  /// A switch failed: alternating stops, the camera goes back to the lens
  /// it came from (best effort) and stills go on from there.
  void _fail(String why, Object? error, int now) {
    final to = _lens;
    final from = _from ?? otherLens(to);
    final gen = ++_gen;
    _alternating = false;
    _fallback = why == 'timeout' ? 'switch timed out' : 'switch failed';
    _state = _State.steady;
    _lens = from;
    // A thrown setZoom leaves the zoom where it was; after a timeout the
    // camera may have gone either way until it confirms the way back.
    _lensSure = why != 'timeout';
    _swMs = _appliedMs = _ffMs = _setMs = null;
    _settle = null;
    onEvent?.call('alt_fallback', {
      'reason': why,
      if (error != null) 'error': '$error',
      'to': altLensKind(to),
      'stay': altLensKind(from),
      'switches': _switches,
    });
    if (why == 'timeout') {
      setZoom(zoomFor(from)).then((_) {
        if (gen == _gen && !_disposed) _lensSure = true;
      }, onError: (Object e) {
        if (gen == _gen && !_disposed) onEvent?.call('alt_fail', {'to': altLensKind(from), 'error': '$e', 'during': 'restore'});
      });
    }
  }
}

/// Mean luma of a Y plane, sampled (every [step]th byte): enough to see
/// auto exposure still moving after a lens switch, cheap at 15 frames a
/// second.
double sampledMeanLuma(List<int> y, {int step = 97}) {
  if (y.isEmpty) return 0;
  var sum = 0, n = 0;
  for (var i = 0; i < y.length; i += step) {
    sum += y[i];
    n++;
  }
  return sum / n;
}

/// "Alternating: ultra-wide / normal · switch ~NNN ms", or why not.
String altStatusLine(LensAlternator a) {
  if (!a.alternating) {
    return a.fallbackReason == null
        ? 'Alternating: waiting (framing check)'
        : 'Alternating off (${a.fallbackReason}): ${a.lens == AltLens.ultraWide ? 'ultra-wide' : 'normal'} only';
  }
  final ms = a.switchMsMedian;
  return 'Alternating: ultra-wide / normal · switch ${ms == null ? '…' : '~$ms ms'}';
}

/// "ultra-wide 0.7/s · normal 0.7/s" over the last 30 s.
String altRateLine(LensAlternator a) => 'ultra-wide ${a.perSecond(AltLens.ultraWide).toStringAsFixed(1)}/s · '
    'normal ${a.perSecond(AltLens.normal).toStringAsFixed(1)}/s';
