/// Watch my cards + recording, "Wide shots between peeks": while the peek
/// gate is idle, now and then switch the one logical back camera to the
/// ultra-wide (zoom ratio under 1.0, as lens_alternator.dart does), keep
/// one settled frame as a still of the whole table and switch straight
/// back. The card reader never sees an ultra-wide frame: [WideExcursion.onFrame]
/// says what each frame is for.
///
/// Cycle: normal --(idle for [WideExcursion.idleMs] and [WideExcursion.intervalMs]
/// since the last one)--> toWide --(zoom applied)--> wideSettling --(settled:
/// still)--> toNormal --(applied)--> normalSettling --(settled)--> normal.
/// Motion on the ultra-wide (a peek starting) aborts straight back. A switch
/// that throws or takes over [WideExcursion.switchTimeoutMs] turns wide shots
/// off for the session (logged) and asks for the normal zoom once more.
///
/// Pure Dart: camera and clock are injected (test/watch_wide_test.dart).
library;

import 'dart:typed_data';

import '../record/lens_alternator.dart' show SetZoom;

/// What a frame is for.
enum WideUse {
  /// The normal lens, settled: the card reader (and normal stills).
  read,

  /// Switching or settling: drop it.
  skip,

  /// The settled ultra-wide frame: save it as the wide still.
  wideStill,
}

enum WideState { normal, toWide, wideSettling, toNormal, normalSettling, off }

/// Grid cells that changed by more than [delta] grey levels between two
/// coarse luma grids, after removing the mean shift (auto exposure moves
/// every cell at once; a hand moves some).
int gridMotionCells(Uint8List a, Uint8List b, {int delta = 24}) {
  if (a.length != b.length || a.isEmpty) return 0;
  var sa = 0, sb = 0;
  for (var i = 0; i < a.length; i++) {
    sa += a[i];
    sb += b[i];
  }
  final shift = (sb - sa) / a.length;
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    if ((b[i] - a[i] - shift).abs() > delta) n++;
  }
  return n;
}

class WideExcursion {
  final SetZoom setZoom;
  final int Function() nowMs;
  final double wideZoom;
  final double normalZoom;

  /// At most one excursion per [intervalMs] (from the end of the last one).
  final int intervalMs;

  /// The gate must have been quiet (no card-like change) this long.
  final int idleMs;
  final int switchTimeoutMs;
  final int minSettleFrames;
  final int maxSettleMs;
  final double stableLuma;

  /// Grid cells moving between two ultra-wide frames that count as a peek
  /// starting (see [gridMotionCells]).
  final int motionCells;

  /// `wide_*` lines for the session log.
  final void Function(String kind, Map<String, Object?> fields)? onEvent;

  WideExcursion({
    required this.setZoom,
    required this.nowMs,
    required this.wideZoom,
    this.normalZoom = 1.0,
    this.intervalMs = 6000,
    this.idleMs = 3000,
    this.switchTimeoutMs = 2000,
    this.minSettleFrames = 2,
    this.maxSettleMs = 800,
    this.stableLuma = 3,
    this.motionCells = 6,
    this.onEvent,
  });

  WideState _state = WideState.normal;
  int _gen = 0;
  int? _lastEndMs;
  int? _swMs, _appliedMs, _exStartMs;
  int _frames = 0;
  double? _lastLuma;
  Uint8List? _lastGrid;
  String? _offReason;
  int excursions = 0, stills = 0, aborts = 0;

  WideState get state => _state;

  /// Off for the rest of the session, and why.
  bool get off => _state == WideState.off;
  String? get offReason => _offReason;

  /// The camera is away from the normal lens (or on its way back): the
  /// little "wide" dot on the black screen.
  bool get away => _state != WideState.normal && _state != WideState.off;

  /// The caller should pass the frame's mean luma (settling).
  bool get wantsLuma => _state == WideState.wideSettling || _state == WideState.normalSettling;

  /// The caller should pass a coarse luma grid (motion on the ultra-wide).
  bool get wantsGrid => _state == WideState.wideSettling;

  /// A frame arrived at [now]. [quietMs]: how long the peek gate has been
  /// idle (0 while a burst or a read is going on). [luma] / [grid] when
  /// [wantsLuma] / [wantsGrid].
  WideUse onFrame(int now, {required int quietMs, double? luma, Uint8List? grid}) {
    switch (_state) {
      case WideState.off:
        return WideUse.read;
      case WideState.normal:
        final last = _lastEndMs;
        if (quietMs >= idleMs && (last == null || now - last >= intervalMs)) {
          excursions++;
          _exStartMs = now;
          _switch(WideState.toWide, wideZoom, now);
          // This frame is still the normal lens.
        }
        return WideUse.read;
      case WideState.toWide:
      case WideState.toNormal:
        if (now - _swMs! > switchTimeoutMs) _fail('timeout', null);
        return _state == WideState.off ? WideUse.read : WideUse.skip;
      case WideState.wideSettling:
        final g = _lastGrid;
        _lastGrid = grid;
        if (_frames >= 1 && g != null && grid != null && gridMotionCells(g, grid) >= motionCells) {
          abort('motion');
          return WideUse.skip;
        }
        if (!_settled(now, luma)) return WideUse.skip;
        stills++;
        onEvent?.call('wide_still', {
          'switch_ms': _appliedMs! - _swMs!,
          'settle_ms': now - _appliedMs!,
          'away_ms': now - _exStartMs!,
        });
        _switch(WideState.toNormal, normalZoom, now);
        return WideUse.wideStill;
      case WideState.normalSettling:
        if (!_settled(now, luma)) return WideUse.skip;
        _state = WideState.normal;
        _lastEndMs = now;
        return WideUse.read;
    }
  }

  bool _settled(int now, double? luma) {
    _frames++;
    final last = _lastLuma;
    _lastLuma = luma;
    final stable = luma == null || (last != null && (luma - last).abs() <= stableLuma);
    return (_frames >= minSettleFrames && stable) || now - _appliedMs! >= maxSettleMs;
  }

  /// A peek is starting (or anything else needs the normal lens): back now.
  /// No-op unless on (or going to) the ultra-wide.
  void abort(String why) {
    if (_state != WideState.toWide && _state != WideState.wideSettling) return;
    aborts++;
    onEvent?.call('wide_abort', {'why': why, 'away_ms': nowMs() - (_exStartMs ?? nowMs())});
    _switch(WideState.toNormal, normalZoom, nowMs());
  }

  /// Turn wide shots off (the camera is going away, the switch was turned
  /// off). Does not touch the zoom.
  void stop(String why) {
    if (_state == WideState.off) return;
    _gen++;
    _state = WideState.off;
    _offReason = why;
  }

  void _switch(WideState to, double zoom, int now) {
    final gen = ++_gen;
    _state = to;
    _swMs = now;
    _appliedMs = null;
    _frames = 0;
    _lastLuma = null;
    _lastGrid = null;
    Future<void> f;
    try {
      f = setZoom(zoom);
    } catch (e) {
      _fail('error', e);
      return;
    }
    f.then((_) {
      if (gen != _gen) return;
      _appliedMs = nowMs();
      _state = to == WideState.toWide ? WideState.wideSettling : WideState.normalSettling;
    }, onError: (Object e) {
      if (gen == _gen) _fail('error', e);
    });
  }

  void _fail(String why, Object? error) {
    final during = _state.name;
    _gen++;
    _state = WideState.off;
    _offReason = why == 'timeout' ? 'lens switch took over ${switchTimeoutMs ~/ 1000} s' : 'lens switch failed';
    onEvent?.call('wide_off', {'reason': why, 'during': during, if (error != null) 'error': '$error'});
    // Best effort back to the normal lens (the reader needs it).
    try {
      setZoom(normalZoom).then((_) {}, onError: (Object e) => onEvent?.call('wide_restore_fail', {'error': '$e'}));
    } catch (e) {
      onEvent?.call('wide_restore_fail', {'error': '$e'});
    }
  }
}
