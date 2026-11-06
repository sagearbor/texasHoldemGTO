import 'dart:async';
import 'dart:typed_data';

import 'package:felt_notes/camera/watch_wide.dart';
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

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeCamera cam;
  late int now;
  late List<(String, Map<String, Object?>)> events;

  WideExcursion make() {
    cam = FakeCamera();
    now = 0;
    events = [];
    return WideExcursion(
      setZoom: cam.setZoom,
      nowMs: () => now,
      wideZoom: 0.5,
      onEvent: (k, f) => events.add((k, f)),
    );
  }

  final flat = Uint8List(144)..fillRange(0, 144, 100);

  /// Frames every 67 ms until [until]; returns each frame's use.
  List<WideUse> run(WideExcursion w, int until, {int quietFrom = -100000, Uint8List? grid}) {
    final out = <WideUse>[];
    while (now < until) {
      now += 67;
      out.add(w.onFrame(now, quietMs: now - quietFrom, luma: w.wantsLuma ? 100 : null, grid: w.wantsGrid ? (grid ?? flat) : null));
    }
    return out;
  }

  test('idle -> ultra-wide still -> back to the normal lens; reader never sees a wide frame', () async {
    final w = make();
    // Hole cards read until t=1000: no excursion before 4000.
    expect(run(w, 3900, quietFrom: 1000).every((u) => u == WideUse.read), isTrue);
    expect(cam.calls, isEmpty);
    run(w, 4100, quietFrom: 1000);
    expect(cam.calls, [0.5]);
    expect(w.state, WideState.toWide);
    expect(w.away, isTrue);
    // Switching: frames dropped.
    expect(run(w, 4300, quietFrom: 1000), everyElement(WideUse.skip));
    cam.completeAll();
    await flush();
    expect(w.state, WideState.wideSettling);
    final uses = run(w, 4500, quietFrom: 1000);
    expect(uses.where((u) => u == WideUse.wideStill), hasLength(1));
    expect(uses.contains(WideUse.read), isFalse);
    expect(cam.calls, [0.5, 1.0]);
    expect(w.state, WideState.toNormal);
    expect(run(w, 4700, quietFrom: 1000), everyElement(WideUse.skip));
    cam.completeAll();
    await flush();
    // Settling on the normal lens, then reading again.
    final back = run(w, 5000, quietFrom: 1000);
    expect(back.first, WideUse.skip);
    expect(back.last, WideUse.read);
    expect(w.away, isFalse);
    expect(w.stills, 1);
    expect(events.map((e) => e.$1), contains('wide_still'));
    // Next one only after the interval (6 s from the end of this one).
    run(w, 10500, quietFrom: 1000);
    expect(cam.calls, hasLength(2));
    run(w, 11300, quietFrom: 1000);
    expect(cam.calls, hasLength(3));
  });

  test('no excursion while hole cards are being read', () {
    final w = make();
    for (var i = 0; i < 300; i++) {
      now += 67;
      expect(w.onFrame(now, quietMs: 0), WideUse.read);
    }
    expect(cam.calls, isEmpty);
  });

  test('a peek starting on the ultra-wide aborts straight back', () async {
    final w = make();
    run(w, 100);
    expect(cam.calls, [0.5]);
    cam.completeAll();
    await flush();
    // First wide frame flat, then a hand moves into a corner of the view.
    now += 67;
    expect(w.onFrame(now, quietMs: 99999, luma: 100, grid: flat), WideUse.skip);
    final moved = Uint8List.fromList(flat)..fillRange(0, 20, 200);
    now += 67;
    expect(w.onFrame(now, quietMs: 99999, luma: 140, grid: moved), WideUse.skip);
    expect(cam.calls, [0.5, 1.0]);
    expect(w.aborts, 1);
    expect(w.stills, 0);
    expect(events.map((e) => e.$1), contains('wide_abort'));
    cam.completeAll();
    await flush();
    run(w, now + 600);
    expect(w.state, WideState.normal);
  });

  test('abort() while switching to the ultra-wide goes back; a late wide apply is ignored', () async {
    final w = make();
    run(w, 100);
    final toWide = cam.pending.first;
    w.abort('peek');
    expect(cam.calls, [0.5, 1.0]);
    toWide.complete();
    await flush();
    expect(w.state, WideState.toNormal);
    cam.completeAll();
    await flush();
    expect(w.state, WideState.normalSettling);
  });

  test('exposure change alone (every cell shifts) is not motion', () {
    final a = Uint8List(144)..fillRange(0, 144, 80);
    final b = Uint8List(144)..fillRange(0, 144, 140);
    expect(gridMotionCells(a, b), 0);
    final c = Uint8List.fromList(a)..fillRange(0, 10, 200);
    expect(gridMotionCells(a, c), greaterThanOrEqualTo(10));
  });

  test('a failed switch turns wide shots off for the session and asks for 1.0', () async {
    final w = make();
    run(w, 100);
    cam.failAll();
    await flush();
    expect(w.off, isTrue);
    expect(w.offReason, 'lens switch failed');
    expect(cam.calls.last, 1.0);
    expect(events.map((e) => e.$1), contains('wide_off'));
    // Reads from now on, no more switching.
    expect(run(w, 20000), everyElement(WideUse.read));
    expect(cam.calls, hasLength(2));
  });

  test('a switch taking over 2 s turns wide shots off', () {
    final w = make();
    run(w, 100);
    expect(w.state, WideState.toWide);
    final uses = run(w, 2300);
    expect(w.off, isTrue);
    expect(w.offReason, contains('2 s'));
    expect(uses.last, WideUse.read);
    expect(cam.calls.last, 1.0);
  });

  test('a thrown setZoom turns wide shots off', () {
    final w = make();
    cam.throwSync = true;
    run(w, 100);
    expect(w.off, isTrue);
  });

  test('stop() ends it without touching the zoom', () {
    final w = make();
    w.stop('stopped');
    expect(run(w, 10000), everyElement(WideUse.read));
    expect(cam.calls, isEmpty);
  });

  /// One excursion from [WideState.normal]: switch, settle on the
  /// ultra-wide with [moving] frames, switch back. Returns the wide frames' uses.
  Future<List<WideUse>> excursion(WideExcursion w, {required bool moving}) async {
    final start = cam.calls.length;
    while (cam.calls.length == start) {
      now += 67;
      w.onFrame(now, quietMs: 99999);
      if (now > 600000) fail('no excursion');
    }
    cam.completeAll();
    await flush();
    final uses = <WideUse>[];
    var k = 0;
    while (w.state == WideState.wideSettling) {
      now += 67;
      final o = (k++ % 2) * 40;
      final g = moving ? (Uint8List.fromList(flat)..fillRange(o, o + 20, 220)) : flat;
      uses.add(w.onFrame(now, quietMs: 99999, luma: 100, grid: g));
    }
    cam.completeAll();
    await flush();
    while (w.state != WideState.normal) {
      now += 67;
      w.onFrame(now, quietMs: 99999, luma: 100);
    }
    return uses;
  }

  test('a motion abort is retried after the interval, not given up', () async {
    final w = make();
    expect(await excursion(w, moving: true), isNot(contains(WideUse.wideStill)));
    expect(w.aborts, 1);
    final end = now;
    expect(await excursion(w, moving: false), contains(WideUse.wideStill));
    // The retry came one interval after the abort ended.
    expect(now - end, inInclusiveRange(6000, 7000));
    expect(w.excursions, 2);
    expect(w.stills, 1);
  });

  test('a table that never stops moving still gets a wide still every third try', () async {
    final w = make();
    for (var i = 0; i < 9; i++) {
      await excursion(w, moving: true);
    }
    expect(w.excursions, 9);
    expect(w.stills, 3);
    expect(w.aborts, 6);
    expect(events.where((e) => e.$1 == 'wide_still').every((e) => e.$2['forced'] == true), isTrue);
  });

  test('hole cards being read keep the lens on the reader', () {
    final w = make();
    // A peek: hole cards read until t=5000, then put down.
    for (now = 0; now < 5000; now += 67) {
      expect(w.onFrame(now, quietMs: 0), WideUse.read);
    }
    expect(cam.calls, isEmpty);
    for (; now < 7900; now += 67) {
      w.onFrame(now, quietMs: now - 5000);
    }
    expect(cam.calls, isEmpty);
    for (; now < 8200; now += 67) {
      w.onFrame(now, quietMs: now - 5000);
    }
    expect(cam.calls, [0.5]);
  });
}
