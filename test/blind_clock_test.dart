import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:felt_notes/homegame/blind_clock.dart';
import 'package:felt_notes/homegame/blind_clock_controller.dart';
import 'package:felt_notes/ui/screens/blind_clock_screen.dart';
import 'package:felt_notes/ui/widgets/blind_clock_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';

const min = 60000;
const t0 = 1700000000000; // arbitrary wall-clock start

void main() {
  group('default schedule', () {
    test('ten 15-minute levels with a 10-minute break after level 4', () {
      final blinds = defaultSchedule.where((l) => !l.isBreak).toList();
      expect(blinds.length, 10);
      expect(blinds.every((l) => l.minutes == 15), isTrue);
      expect(blinds.first.label, '25 / 50');
      expect(blinds.last.label, '1000 / 2000');
      expect(defaultSchedule[4].isBreak, isTrue);
      expect(defaultSchedule[4].minutes, 10);
    });
  });

  group('time math', () {
    test('not started: full first level, nothing moves', () {
      final c = BlindClock();
      final p = c.positionAt(t0 + 99 * min);
      expect(p.index, 0);
      expect(p.remainingMs, 15 * min);
      expect(c.started, isFalse);
    });

    test('counts down from wall-clock time, not ticks', () {
      final c = BlindClock()..start(t0);
      final p = c.positionAt(t0 + 5 * min + 30000);
      expect(p.index, 0);
      expect(p.elapsedMs, 5 * min + 30000);
      expect(p.remainingMs, 9 * min + 30000);
    });

    test('rolls through several levels in one jump (app was asleep)', () {
      final c = BlindClock()..start(t0);
      // 40 min = levels 1, 2 done (30) + 10 into level 3.
      final p = c.positionAt(t0 + 40 * min);
      expect(p.index, 2);
      expect(c.schedule[p.index].bigBlind, 150);
      expect(p.remainingMs, 5 * min);
    });

    test('break after level 4, then level 5', () {
      final c = BlindClock()..start(t0);
      final brk = c.positionAt(t0 + 60 * min + 1000);
      expect(c.schedule[brk.index].isBreak, isTrue);
      expect(brk.remainingMs, 10 * min - 1000);
      final after = c.positionAt(t0 + 70 * min);
      expect(c.schedule[after.index].label, '150 / 300');
      expect(c.levelNumber(after.index), 5);
      expect(c.levelNumber(brk.index), 4); // breaks don't count
    });

    test('exact boundary belongs to the next level', () {
      final c = BlindClock()..start(t0);
      expect(c.positionAt(t0 + 15 * min).index, 1);
      expect(c.positionAt(t0 + 15 * min - 1).index, 0);
    });

    test('last level runs out and stays', () {
      final c = BlindClock()..start(t0);
      final p = c.positionAt(t0 + 1000 * min);
      expect(p.index, c.schedule.length - 1);
      expect(p.remainingMs, 0);
      expect(p.finished, isTrue);
    });

    test('clock set backwards does not give negative elapsed', () {
      final c = BlindClock()..start(t0);
      expect(c.positionAt(t0 - 5 * min).elapsedMs, 0);
    });
  });

  group('pause / resume', () {
    test('paused time does not count', () {
      final c = BlindClock()..start(t0);
      c.pause(t0 + 5 * min);
      expect(c.paused, isTrue);
      // An hour on pause.
      expect(c.positionAt(t0 + 65 * min).elapsedMs, 5 * min);
      c.resume(t0 + 65 * min);
      final p = c.positionAt(t0 + 67 * min);
      expect(p.index, 0);
      expect(p.elapsedMs, 7 * min);
    });

    test('pause after a rollover commits the new level', () {
      final c = BlindClock()..start(t0);
      c.pause(t0 + 20 * min);
      expect(c.levelIndex, 1);
      expect(c.elapsedBeforeMs, 5 * min);
      c.resume(t0 + 100 * min);
      expect(c.positionAt(t0 + 110 * min).index, 2);
    });

    test('several pause/resume cycles add up', () {
      final c = BlindClock();
      var now = t0;
      for (var k = 0; k < 4; k++) {
        c.start(now);
        now += 3 * min; // running
        c.pause(now);
        now += 7 * min; // paused
      }
      expect(c.positionAt(now).elapsedMs, 12 * min);
    });

    test('start twice does not reset the anchor', () {
      final c = BlindClock()..start(t0);
      c.start(t0 + 5 * min);
      expect(c.positionAt(t0 + 6 * min).elapsedMs, 6 * min);
    });
  });

  group('skipping levels', () {
    test('next goes to the start of the following entry and keeps running', () {
      final c = BlindClock()..start(t0);
      c.next(t0 + 4 * min);
      expect(c.levelIndex, 1);
      final p = c.positionAt(t0 + 5 * min);
      expect(p.index, 1);
      expect(p.elapsedMs, 1 * min);
    });

    test('next while paused stays paused at 0', () {
      final c = BlindClock()..start(t0);
      c.pause(t0 + 4 * min);
      c.next(t0 + 9 * min);
      expect(c.running, isFalse);
      expect(c.positionAt(t0 + 99 * min).elapsedMs, 0);
      expect(c.positionAt(t0 + 99 * min).index, 1);
    });

    test('next can skip a break', () {
      final c = BlindClock()..start(t0);
      final brk = c.positionAt(t0 + 61 * min);
      expect(c.schedule[brk.index].isBreak, isTrue);
      c.next(t0 + 61 * min);
      expect(c.schedule[c.levelIndex].label, '150 / 300');
    });

    test('next on the last level runs it out', () {
      final c = BlindClock(levelIndex: defaultSchedule.length - 1)..start(t0);
      c.next(t0 + min);
      expect(c.positionAt(t0 + min).finished, isTrue);
      expect(c.levelIndex, defaultSchedule.length - 1);
    });

    test('previous restarts the level, or goes back if just started', () {
      final c = BlindClock()..start(t0);
      c.next(t0); // level 2
      c.previous(t0 + 2 * min); // 2 min in: restart level 2
      expect(c.levelIndex, 1);
      expect(c.positionAt(t0 + 2 * min).elapsedMs, 0);
      c.previous(t0 + 2 * min + 3000); // 3 s in: back to level 1
      expect(c.levelIndex, 0);
      c.previous(t0 + 2 * min + 4000); // already first
      expect(c.levelIndex, 0);
    });

    test('reset goes back to level 1 stopped', () {
      final c = BlindClock()..start(t0);
      c.next(t0 + min);
      c.reset();
      expect(c.started, isFalse);
      expect(c.running, isFalse);
      expect(c.positionAt(t0 + 50 * min).index, 0);
      expect(c.positionAt(t0 + 50 * min).elapsedMs, 0);
    });
  });

  group('edit schedule', () {
    test('keeps the live level and clamps elapsed', () {
      final c = BlindClock()..start(t0);
      const now = t0 + 25 * min; // level 2, 10 min in
      c.setSchedule([
        const BlindLevel(10, 20, minutes: 5),
        const BlindLevel(20, 40, minutes: 5),
        const BlindLevel(40, 80, minutes: 5),
      ], now);
      expect(c.levelIndex, 1);
      expect(c.elapsedBeforeMs, 5 * min);
      // Still running: the full new level is used up, so we roll to level 3.
      expect(c.positionAt(now + 1).index, 2);
    });

    test('shorter schedule clamps the index; empty restores default', () {
      final c = BlindClock(levelIndex: 8);
      c.setSchedule([const BlindLevel(1, 2)], t0);
      expect(c.levelIndex, 0);
      c.setSchedule([], t0);
      expect(c.schedule, defaultSchedule);
    });
  });

  group('cash mode', () {
    test('no countdown, stakes move only by hand, breaks skipped', () {
      final c = BlindClock(mode: ClockMode.cash)..start(t0);
      expect(c.positionAt(t0 + 500 * min).index, 0);
      for (var k = 0; k < 4; k++) {
        c.next(t0);
      }
      // From 100/200 the next entry is a break; cash mode skips it.
      expect(c.schedule[c.levelIndex].label, '150 / 300');
      c.previous(t0);
      expect(c.schedule[c.levelIndex].label, '100 / 200');
      expect(c.nextLevelAt(t0)!.label, '150 / 300');
    });

    test('switching to cash on a break lands on a blind level', () {
      final c = BlindClock()..start(t0);
      c.pause(t0 + 62 * min); // on the break
      c.setMode(ClockMode.cash, t0 + 62 * min);
      expect(c.schedule[c.levelIndex].isBreak, isFalse);
      expect(c.elapsedBeforeMs, 0);
    });
  });

  group('persistence', () {
    test('JSON round-trip of a running clock resumes on wall-clock time', () {
      final c = BlindClock(schedule: [
        const BlindLevel(25, 50, ante: 5, minutes: 20),
        const BlindLevel.breakOf(5),
        const BlindLevel(50, 100, minutes: 20),
      ])
        ..start(t0);
      c.pause(t0 + 3 * min);
      c.resume(t0 + 10 * min);
      final saved = jsonEncode(c.toJson());
      // App killed; reopened 30 minutes later.
      final r = BlindClock.fromJson(jsonDecode(saved) as Map<String, dynamic>);
      expect(r.schedule, c.schedule);
      expect(r.running, isTrue);
      final p = r.positionAt(t0 + 40 * min);
      // 3 + 30 = 33 running minutes: level 1 (20) + break (5) + 8 into level 2.
      expect(p.index, 2);
      expect(p.elapsedMs, 8 * min);
      expect(r.schedule[0].ante, 5);
    });

    test('paused state restores paused', () {
      final c = BlindClock()..start(t0);
      c.pause(t0 + 7 * min);
      final r = BlindClock.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      expect(r.paused, isTrue);
      expect(r.positionAt(t0 + 900 * min).elapsedMs, 7 * min);
    });

    test('bad JSON falls back to sane defaults', () {
      final r = BlindClock.fromJson({'idx': 99, 'mode': 'nope'});
      expect(r.schedule, defaultSchedule);
      expect(r.levelIndex, defaultSchedule.length - 1);
      expect(r.mode, ClockMode.tournament);
    });

    test('controller saves to and restores from shared_preferences', () async {
      SharedPreferences.setMockInitialValues({});
      var now = t0;
      final a = BlindClockController(now: () => now);
      await a.ensureLoaded();
      a.start();
      now += 2 * min;
      a.next();
      await Future<void>.delayed(Duration.zero);

      now += 4 * min; // "restart" the app 4 minutes later
      final b = BlindClockController(now: () => now);
      await b.ensureLoaded();
      expect(b.clock.running, isTrue);
      expect(b.position.index, 1);
      expect(b.position.elapsedMs, 4 * min);
    });

    test('level-change alert fires once per automatic rollover', () async {
      SharedPreferences.setMockInitialValues({});
      var now = t0;
      final c = BlindClockController(now: () => now);
      await c.ensureLoaded();
      c.start();
      expect(c.takeLevelChange(), isFalse);
      now += 15 * min;
      expect(c.takeLevelChange(), isTrue);
      expect(c.takeLevelChange(), isFalse); // second display, same tick
      c.next(); // manual: no alert
      expect(c.takeLevelChange(), isFalse);
    });
  });

  test('formatClock', () {
    expect(formatClock(15 * min), '15:00');
    expect(formatClock(61000), '1:01');
    expect(formatClock(500), '0:01'); // rounds up: never shows 0:00 early
    expect(formatClock(0), '0:00');
    expect(formatClock(75 * min), '1:15:00');
  });

  testWidgets('clock screen and strip render', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var now = t0;
    final c = BlindClockController(now: () => now);
    await c.ensureLoaded();
    await tester.pumpWidget(MaterialApp(home: BlindClockScreen(controller: c)));
    await tester.pump();
    expect(find.text('LEVEL 1'), findsOneWidget);
    expect(find.text('25 / 50'), findsOneWidget);
    expect(find.text('15:00'), findsOneWidget);
    await tester.tap(find.text('Start'));
    now += 90 * 1000;
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('13:30'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ListView(children: [BlindClockStrip(controller: c)]))));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('LVL 1'), findsOneWidget);
    expect(find.text('13:30'), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // dispose timers
  });

  for (final size in const [Size(360, 640), Size(640, 360), Size(1920, 1080), Size(1080, 1920)]) {
    for (final cash in [false, true]) {
      testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()} '
          '${cash ? 'cash' : 'tournament'}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final c = BlindClockController(now: () => t0 + 61 * min); // on the break
        await c.ensureLoaded();
        c.clock.schedule[0] = const BlindLevel(1000, 2000, ante: 2000);
        if (cash) c.setMode(ClockMode.cash);
        await tester.pumpWidget(MaterialApp(home: BlindClockScreen(controller: c)));
        await tester.pump();
        c.start();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(body: ListView(children: [BlindClockStrip(controller: c)]))));
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
