import 'dart:async';

import 'package:felt_notes/record/lens_alternator.dart';
import 'package:felt_notes/record/record_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// A camera whose zoom calls complete (or fail) when the test says.
class FakeCamera {
  final List<double> calls = [];
  final List<Completer<void>> pending = [];
  bool throwSync = false;

  Future<void> setZoom(double z) {
    if (throwSync) throw StateError('camera closed');
    calls.add(z);
    final c = Completer<void>();
    pending.add(c);
    return c.future;
  }

  void completeAll() {
    for (final c in pending) {
      if (!c.isCompleted) c.complete();
    }
    pending.clear();
  }

  void failAll() {
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(StateError('zoom refused'));
    }
    pending.clear();
  }
}

/// Lets the zoom futures' callbacks run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeCamera cam;
  late int now;
  late List<(String, Map<String, Object?>)> events;

  LensAlternator make({int intervalMs = 667}) {
    cam = FakeCamera();
    now = 0;
    events = [];
    return LensAlternator(
      setZoom: cam.setZoom,
      nowMs: () => now,
      wideZoom: 0.5,
      intervalMs: intervalMs,
      onEvent: (k, f) => events.add((k, f)),
    );
  }

  /// Feeds a frame every 67 ms (15 fps) from [now] up to [until]; returns
  /// the stills taken (each marked done right away).
  List<AltStill> run(LensAlternator a, int until, {double luma = 100, bool done = true}) {
    final out = <AltStill>[];
    while (now < until) {
      now += 67;
      final s = a.onFrame(now, luma: luma);
      if (s != null) {
        out.add(s);
        if (done) a.done(s);
      }
    }
    return out;
  }

  test('first still is on the starting lens, then a switch is issued right away', () {
    final a = make()..start();
    expect(events.single.$1, 'alt_start');
    now = 100;
    final s = a.onFrame(now, luma: 100)!;
    expect(s.lens, AltLens.ultraWide);
    expect(s.zoom, 0.5);
    expect(s.switchMs, isNull);
    expect(s.requestedMs, 100);
    expect(cam.calls, [1.0]);
    expect(a.lens, AltLens.normal);
    expect(a.switching, isTrue);
    expect(a.steadyLens, isNull);
  });

  test('alternates W, N, W, N with settled frames and full timings', () async {
    final a = make()..start();
    final stills = <AltStill>[];
    for (var i = 0; i < 6; i++) {
      // Frames until the next still; the camera applies each zoom ~2 frames
      // after it is asked.
      var guard = 0;
      while (true) {
        now += 67;
        if (cam.pending.isNotEmpty && guard++ >= 2) {
          cam.completeAll();
          await settle();
        }
        final s = a.onFrame(now, luma: 100);
        if (s != null) {
          stills.add(s);
          a.done(s);
          break;
        }
      }
    }
    expect([for (final s in stills) s.lens], [
      AltLens.ultraWide,
      AltLens.normal,
      AltLens.ultraWide,
      AltLens.normal,
      AltLens.ultraWide,
      AltLens.normal,
    ]);
    expect(cam.calls, [1.0, 0.5, 1.0, 0.5, 1.0, 0.5]);
    for (final s in stills.skip(1)) {
      expect(s.alternating, isTrue);
      expect(s.switchMs, isNotNull);
      expect(s.appliedMs! >= s.switchMs!, isTrue);
      expect(s.firstFrameMs! > s.appliedMs! - 1, isTrue);
      expect(s.settledMs! >= s.firstFrameMs!, isTrue);
      expect(s.capturedMs >= s.settledMs!, isTrue);
      expect(s.settle, 'stable');
      // Never before the slot.
      expect(s.capturedMs >= s.requestedMs, isTrue);
    }
    expect(a.switchMsMedian, isNotNull);
    expect(a.switchMsMedian! < 667, isTrue);
  });

  test('photo line alt object maps times to the log clock', () {
    const s = AltStill(
      lens: AltLens.normal,
      zoom: 1.0,
      alternating: true,
      lensSure: true,
      requestedMs: 1000,
      capturedMs: 1100,
      switchMs: 700,
      appliedMs: 900,
      firstFrameMs: 950,
      settledMs: 1030,
      settle: 'stable',
      switchN: 3,
    );
    final j = s.toJson((v) => v + 5000);
    expect(j['req_m'], 6000);
    expect(j['cap_m'], 6100);
    expect(j['sw_m'], 5700);
    expect(j['ff_m'], 5950);
    expect(j['set_m'], 6030);
    expect(j['applied_ms'], 200);
    expect(j['ff_ms'], 250);
    expect(j['settle_ms'], 330);
    expect(j['wait_ms'], 100);
    expect(j['sw_n'], 3);
    expect(j.containsKey('lens_sure'), isFalse);
  });

  test('settle waits for steady brightness, up to the max', () async {
    final a = make()..start();
    now = 67;
    a.done(a.onFrame(now, luma: 100));
    cam.completeAll();
    await settle();
    // Exposure still moving: 60, 90, 120... never steady.
    var luma = 60.0;
    AltStill? s;
    while (s == null) {
      now += 67;
      luma += 30;
      s = a.onFrame(now, luma: luma);
    }
    expect(s.settle, 'timeout');
    expect(s.settledMs! - s.appliedMs!, greaterThanOrEqualTo(a.maxSettleMs));
  });

  test('a zoom that throws falls back to the lens it was on; recording goes on', () async {
    final a = make()..start();
    now = 67;
    a.done(a.onFrame(now, luma: 100)); // ultra-wide, switch to normal issued
    cam.failAll();
    await settle();
    expect(a.alternating, isFalse);
    expect(a.lens, AltLens.ultraWide);
    expect(a.fallbackReason, 'switch failed');
    expect(events.last.$1, 'alt_fallback');
    expect(events.last.$2['stay'], 'ultra_wide');
    final later = run(a, now + 3000);
    expect(later, isNotEmpty);
    expect(later.every((s) => s.lens == AltLens.ultraWide && !s.alternating && s.lensSure), isTrue);
    // About one still per interval, as without the experiment.
    expect(later.length, inInclusiveRange(4, 5));
    expect(cam.calls, [1.0]); // no more switching
    expect(altStatusLine(a), contains('Alternating off'));
  });

  test('a zoom that throws synchronously also falls back', () {
    final a = make()..start();
    cam.throwSync = true;
    now = 67;
    final s = a.onFrame(now, luma: 100);
    expect(s, isNotNull);
    expect(a.alternating, isFalse);
    expect(a.lens, AltLens.ultraWide);
    expect(events.last.$1, 'alt_fallback');
  });

  test('a switch that never completes times out without stalling', () async {
    final a = make()..start();
    now = 67;
    a.done(a.onFrame(now, luma: 100));
    // The camera never answers: frames keep coming.
    final stills = run(a, now + a.switchTimeoutMs + 1500);
    expect(stills, isNotEmpty);
    expect(events.any((e) => e.$1 == 'alt_fallback' && e.$2['reason'] == 'timeout'), isTrue);
    expect(a.alternating, isFalse);
    // Unsure which lens until the way back is confirmed.
    expect(stills.first.lensSure, isFalse);
    expect(cam.calls, [1.0, 0.5]);
    cam.completeAll();
    await settle();
    final after = run(a, now + 1500);
    expect(after.every((s) => s.lensSure && s.lens == AltLens.ultraWide), isTrue);
    // The late completion of the first switch changed nothing.
    expect(a.alternating, isFalse);
  });

  test('a late completion after dispose is ignored', () async {
    final a = make()..start();
    now = 67;
    a.done(a.onFrame(now, luma: 100));
    a.dispose();
    cam.completeAll();
    await settle();
    expect(a.onFrame(now + 67, luma: 100), isNull);
  });

  test('never two stills in flight: a slow encode skips frames', () async {
    final a = make()..start();
    now = 67;
    final first = a.onFrame(now, luma: 100)!;
    cam.completeAll();
    await settle();
    final none = run(a, now + 2000, done: false);
    expect(none, isEmpty);
    a.done(first);
    final next = run(a, now + 200);
    expect(next.length, 1);
    expect(next.single.lens, AltLens.normal);
  });

  test('not recording (take false): switches settle but no still is taken', () async {
    final a = make()..start();
    now = 67;
    a.done(a.onFrame(now, luma: 100));
    cam.completeAll();
    await settle();
    for (var i = 0; i < 10; i++) {
      now += 67;
      expect(a.onFrame(now, luma: 100, take: false), isNull);
    }
    expect(a.steadyLens, AltLens.normal);
  });

  test('hold goes to the ultra-wide and stops taking turns until start', () async {
    final a = make()..start();
    now = 67;
    a.done(a.onFrame(now, luma: 100)); // now heading to normal
    cam.completeAll();
    await settle();
    final h = a.hold(AltLens.ultraWide);
    expect(cam.calls.last, 0.5);
    cam.completeAll();
    await h;
    expect(a.alternating, isFalse);
    expect(a.steadyLens, AltLens.ultraWide);
    a.start();
    now += 67;
    final s = a.onFrame(now, luma: 100)!;
    expect(s.lens, AltLens.ultraWide);
  });

  test('per-lens rate: each lens gets about half the chosen rate', () async {
    for (final rate in recordRates) {
      final a = make(intervalMs: intervalForRate(rate))..start();
      final stills = <AltStill>[];
      const end = 30000;
      var asked = -1;
      while (now < end) {
        now += 67;
        // Zoom applied ~200 ms after it is asked.
        if (cam.pending.isNotEmpty) {
          if (asked < 0) asked = now;
          if (now - asked >= 200) {
            cam.completeAll();
            asked = -1;
            await settle();
          }
        }
        final s = a.onFrame(now, luma: 100);
        if (s != null) {
          stills.add(s);
          a.done(s);
        }
      }
      final uw = stills.where((s) => s.lens == AltLens.ultraWide).length / 30;
      final n = stills.where((s) => s.lens == AltLens.normal).length / 30;
      expect(uw, closeTo(rate / 2, 0.1), reason: 'rate $rate');
      expect(n, closeTo(rate / 2, 0.1), reason: 'rate $rate');
      expect(a.perSecond(AltLens.normal), closeTo(rate / 2, 0.15), reason: 'rate $rate');
    }
  });

  test('status line', () {
    final a = make();
    expect(altStatusLine(a), 'Alternating: waiting (framing check)');
    a.start();
    expect(altStatusLine(a), 'Alternating: ultra-wide / normal · switch …');
  });

  test('sampled mean luma', () {
    expect(sampledMeanLuma(List.filled(1000, 80)), 80);
    expect(sampledMeanLuma(const []), 0);
  });

  test('photo line keeps old fields and adds lens / alt only when given', () {
    final s = RecordSession(PhonePosition.end, const LensInfo('ultra_wide', 'back0', zoom: 0.5, minZoom: 0.5));
    final plain = s.photoSaved('s01/a.jpg', 10, width: 1, height: 1);
    expect(plain.$2.containsKey('lens'), isFalse);
    expect(plain.$2.containsKey('alt'), isFalse);
    final alt = s.photoSaved('s01/b.jpg', 10, lens: 'wide', alt: {'on': true});
    expect(alt.$2['lens'], 'wide');
    expect(alt.$2['alt'], {'on': true});
    expect(alt.$2['n'], 2);
  });
}
