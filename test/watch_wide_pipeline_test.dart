// Wide shots between peeks must never stall Watch my cards' reader: the
// pipeline (gate, voter, tracker) runs over a synthetic two-minute night
// with peeks, routed exactly as watch_screen.dart _recordFrame does (the
// excursion decides each frame's use; only `read` frames reach the
// pipeline), with a camera whose zoom takes a while, a peek that starts
// while on the ultra-wide, and a zoom that never answers.
import 'dart:async';
import 'dart:typed_data';

import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:felt_notes/camera/watch_frame.dart';
import 'package:felt_notes/camera/watch_pipeline.dart';
import 'package:felt_notes/camera/watch_tracker.dart';
import 'package:felt_notes/camera/watch_wide.dart';
import 'package:felt_notes/record/lens_alternator.dart' show sampledMeanLuma;
import 'package:flutter_test/flutter_test.dart';

const _w = 320, _h = 180;

/// A Y plane (Android full range) plus flat chroma.
WatchFrame _frame(int Function(int x, int y) luma) {
  final y = Uint8List(_w * _h);
  for (var j = 0; j < _h; j++) {
    for (var i = 0; i < _w; i++) {
      y[j * _w + i] = luma(i, j);
    }
  }
  final uv = Uint8List((_w ~/ 2) * (_h ~/ 2))..fillRange(0, (_w ~/ 2) * (_h ~/ 2), 128);
  return WatchFrame(_w, _h, WatchPixelFormat.yuv420,
      [WatchPlane(y, _w, 1), WatchPlane(uv, _w ~/ 2, 1), WatchPlane(Uint8List.fromList(uv), _w ~/ 2, 1)]);
}

final _table = _frame((x, y) => 60);
final _cards = _frame((x, y) => x >= 140 && x < 180 && y >= 70 && y < 110 ? 235 : 60);
final _wideTable = _frame((x, y) => 70);

/// The ultra-wide view while a hand moves in it (a peek starting).
WatchFrame _wideMoving(int t) {
  final x0 = 20 + (t ~/ 67 * 37) % 200;
  return _frame((x, y) => x >= x0 && x < x0 + 30 && y >= 60 && y < 100 ? 220 : 70);
}

GlyphReadResult _read(List<int> pair) => GlyphReadResult(
      hero: [for (final c in pair) GlyphCard(c, 0.9, 3, confident: true)],
      reads: const [],
      boardCount: 0,
      cardsInView: 2,
      heroSizes: const [0.05, 0.05],
      heroAspects: const [1.2, 1.2],
    );

class _Zoom {
  /// Applied zoom ratio (what the frames show).
  double applied = 1.0;
  final int latencyMs;
  final bool answers;
  final List<(int, double, Completer<void>)> _pending = [];
  int calls = 0;
  int Function() now = () => 0;
  _Zoom({this.latencyMs = 300, this.answers = true});

  Future<void> set(double z) {
    calls++;
    final c = Completer<void>();
    if (answers) _pending.add((now() + latencyMs, z, c));
    return c.future;
  }

  void tick(int t) {
    for (final p in [..._pending]) {
      if (t < p.$1) continue;
      _pending.remove(p);
      applied = p.$2;
      p.$3.complete();
    }
  }
}

class _Run {
  final List<WatchDecision> decisions = [];
  WideExcursion? wide;
  int framesRead = 0;
}

/// [peeks]: (start ms, length ms, the pair held up). [wide] null: no wide
/// shots (the reader-only path). [readMs]: the reader's latency.
Future<_Run> _simulate(List<(int, int, List<int>)> peeks, {_Zoom? zoom, int untilMs = 120000, int readMs = 180}) async {
  final pipe = WatchPipeline(const WatchConfig(whiteBalance: false));
  final tracker = WatchHandTracker();
  final run = _Run();
  var t = 0;
  if (zoom != null) {
    zoom.now = () => t;
    run.wide = WideExcursion(setZoom: zoom.set, nowMs: () => t, wideZoom: 0.55);
  }
  (ReadJob, int, List<int>?)? job;
  void apply(WatchDecision d) {
    run.decisions.add(d);
    pipe.noteDecision(d);
    pipe.votesAfter(d);
  }

  for (; t < untilMs; t += 67) {
    zoom?.tick(t);
    await Future<void>.delayed(Duration.zero); // zoom futures complete
    final j = job;
    if (j != null && t >= j.$2) {
      job = null;
      final pair = pipe.onRead(j.$1, j.$3 == null ? GlyphReadResult.empty : _read(j.$3!));
      if (pair != null) apply(tracker.onRead(pair, t, episode: pipe.cardEpisode, scene: pipe.sceneEpoch));
    }
    List<int>? held;
    for (final p in peeks) {
      if (t >= p.$1 && t < p.$1 + p.$2) held = p.$3;
    }
    final ultra = zoom != null && zoom.applied < 1.0;
    final f = ultra ? (held != null ? _wideMoving(t) : _wideTable) : (held != null ? _cards : _table);
    // watch_screen.dart _recordFrame:
    final ex = run.wide;
    if (ex != null) {
      final quiet = pipe.status(t) == WatchStatus.idle ? t - pipe.lastCardLikeMs : 0;
      final use = ex.onFrame(t,
          quietMs: quiet,
          luma: ex.wantsLuma ? sampledMeanLuma(f.planes.first.bytes) : null,
          grid: ex.wantsGrid ? f.lumaGrid(16, 9) : null);
      if (use != WideUse.read) continue;
    }
    run.framesRead++;
    final next = pipe.onFrame(f, t);
    for (final (_, seen) in pipe.lookEnds) {
      final d = tracker.onLookEnd(seen, t, scene: pipe.sceneEpoch);
      if (d.action == WatchAction.newHandUnread) apply(d);
    }
    pipe.lookEnds.clear();
    if (next != null) job = (next, t + readMs, ultra ? null : held);
  }
  return run;
}

void main() {
  List<int> pair(int i) => canonicalPair([2 * i, 2 * i + 1]);

  /// A peek every 10 s (2.5 s long): the table is quiet long enough in
  /// between for the scheduler to go wide at least once each time.
  final peeks = [for (var i = 0; i < 12; i++) (4000 + i * 10000, 2500, pair(i))];

  List<String> logged(_Run r) => [
        for (final d in r.decisions)
          if (d.action == WatchAction.fill || d.action == WatchAction.newHand) d.cards.join(',')
      ];

  test('no wide shots: every peek is a hand (the baseline)', () async {
    final r = await _simulate(peeks);
    expect(logged(r), [for (final p in peeks) p.$3.join(',')]);
    expect(r.decisions.first.action, WatchAction.fill);
    expect(r.decisions.where((d) => d.action == WatchAction.newHand), hasLength(peeks.length - 1));
    expect(r.decisions.where((d) => d.action == WatchAction.newHandUnread), isEmpty);
  });

  test('wide shots between every peek: the same hands, nothing stalls', () async {
    final zoom = _Zoom();
    final r = await _simulate(peeks, zoom: zoom);
    final ex = r.wide!;
    expect(ex.off, isFalse, reason: ex.offReason);
    expect(ex.stills, greaterThanOrEqualTo(12), reason: 'went wide between the peeks');
    expect(zoom.applied, 1.0, reason: 'back on the normal lens');
    expect(logged(r), [for (final p in peeks) p.$3.join(',')]);
  });

  test('a peek starting while on the ultra-wide aborts back and is still read', () async {
    // Peeks timed to start just after the scheduler went wide (quiet 3 s,
    // so ~3.1 s after the last card-like frame, and 300 ms to switch).
    final late = [for (var i = 0; i < 8; i++) (4000 + i * 7600, 2500, pair(i))];
    final zoom = _Zoom();
    final r = await _simulate(late, zoom: zoom, untilMs: 70000);
    final ex = r.wide!;
    expect(ex.aborts, greaterThan(0), reason: "stills ${ex.stills} excursions ${ex.excursions}");
    expect(ex.off, isFalse);
    expect(logged(r), [for (final p in late) p.$3.join(',')]);
  });

  test('a zoom that never answers turns wide shots off and the reader goes on', () async {
    final zoom = _Zoom(answers: false);
    final r = await _simulate(peeks, zoom: zoom);
    final ex = r.wide!;
    expect(ex.off, isTrue);
    expect(ex.offReason, contains('took over'));
    expect(logged(r), [for (final p in peeks) p.$3.join(',')]);
  });

  test('slow reader (400 ms) with wide shots: the same hands', () async {
    final r = await _simulate(peeks, zoom: _Zoom(latencyMs: 600), readMs: 400);
    expect(r.wide!.off, isFalse);
    expect(logged(r), [for (final p in peeks) p.$3.join(',')]);
  });
}
