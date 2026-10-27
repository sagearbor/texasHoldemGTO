/// Blind clock for a home game. Pure Dart: every operation takes the current
/// wall-clock time in milliseconds, so nothing here depends on a ticking
/// timer. Elapsed time is `elapsedBeforeMs + (now - anchorMs)` while running,
/// which means the clock stays right through backgrounding, screen sleep and
/// app restarts (the state round-trips through JSON).
library;

import 'dart:math' as math;

/// One entry in the schedule: either a blind level or a break.
class BlindLevel {
  final int smallBlind;
  final int bigBlind;
  final int ante;
  final int minutes;
  final bool isBreak;

  const BlindLevel(this.smallBlind, this.bigBlind,
      {this.ante = 0, this.minutes = 15})
      : isBreak = false;

  const BlindLevel.breakOf(this.minutes)
      : smallBlind = 0,
        bigBlind = 0,
        ante = 0,
        isBreak = true;

  int get durationMs => minutes * 60000;

  BlindLevel copyWith({int? smallBlind, int? bigBlind, int? ante, int? minutes}) =>
      isBreak
          ? BlindLevel.breakOf(minutes ?? this.minutes)
          : BlindLevel(smallBlind ?? this.smallBlind, bigBlind ?? this.bigBlind,
              ante: ante ?? this.ante, minutes: minutes ?? this.minutes);

  /// "100 / 200" or "100 / 200 · ante 25".
  String get label => isBreak
      ? 'Break'
      : '${_fmt(smallBlind)} / ${_fmt(bigBlind)}${ante > 0 ? ' · ante ${_fmt(ante)}' : ''}';

  Map<String, dynamic> toJson() => isBreak
      ? {'brk': true, 'm': minutes}
      : {'sb': smallBlind, 'bb': bigBlind, 'a': ante, 'm': minutes};

  static BlindLevel fromJson(Map<String, dynamic> j) => j['brk'] == true
      ? BlindLevel.breakOf(j['m'] as int)
      : BlindLevel(j['sb'] as int, j['bb'] as int,
          ante: (j['a'] as int?) ?? 0, minutes: j['m'] as int);

  @override
  bool operator ==(Object other) =>
      other is BlindLevel &&
      other.smallBlind == smallBlind &&
      other.bigBlind == bigBlind &&
      other.ante == ante &&
      other.minutes == minutes &&
      other.isBreak == isBreak;

  @override
  int get hashCode => Object.hash(smallBlind, bigBlind, ante, minutes, isBreak);
}

String _fmt(int n) {
  if (n >= 10000 && n % 1000 == 0) return '${n ~/ 1000}k';
  return '$n';
}

/// 15-minute levels with a 10-minute break after level 4.
const List<BlindLevel> defaultSchedule = [
  BlindLevel(25, 50),
  BlindLevel(50, 100),
  BlindLevel(75, 150),
  BlindLevel(100, 200),
  BlindLevel.breakOf(10),
  BlindLevel(150, 300),
  BlindLevel(200, 400),
  BlindLevel(300, 600),
  BlindLevel(400, 800),
  BlindLevel(500, 1000),
  BlindLevel(1000, 2000),
];

enum ClockMode {
  /// Levels count down and advance on their own.
  tournament,

  /// Just shows the stakes; the host changes them by hand. No countdown.
  cash,
}

/// Where the clock is at a given moment.
class ClockPosition {
  /// Index into the schedule.
  final int index;

  /// Time spent in this level so far.
  final int elapsedMs;

  /// Time left in this level (0 on the last level once it has run out).
  final int remainingMs;

  /// True when the last level has run out (it keeps showing).
  final bool finished;

  const ClockPosition(this.index, this.elapsedMs, this.remainingMs, this.finished);
}

class BlindClock {
  List<BlindLevel> schedule;
  ClockMode mode;

  /// Level the clock was on at the last commit (pause, skip, edit...). The
  /// live level can be later than this if time has run on since.
  int levelIndex;

  /// Time already spent in [levelIndex] before [anchorMs].
  int elapsedBeforeMs;

  /// Wall-clock ms when the clock last started running; null while paused.
  int? anchorMs;

  /// Whether the clock has been started at all since the last reset.
  bool started;

  BlindClock({
    List<BlindLevel>? schedule,
    this.mode = ClockMode.tournament,
    this.levelIndex = 0,
    this.elapsedBeforeMs = 0,
    this.anchorMs,
    this.started = false,
  }) : schedule = List.of(schedule ?? defaultSchedule) {
    if (this.schedule.isEmpty) this.schedule = List.of(defaultSchedule);
    levelIndex = levelIndex.clamp(0, this.schedule.length - 1);
  }

  bool get running => anchorMs != null;
  bool get paused => started && !running;

  /// Where the clock is at [nowMs], rolling through as many levels as the
  /// elapsed time covers.
  ClockPosition positionAt(int nowMs) {
    if (mode == ClockMode.cash) {
      return ClockPosition(levelIndex, 0, schedule[levelIndex].durationMs, false);
    }
    var i = levelIndex;
    int e = elapsedBeforeMs + (anchorMs == null ? 0 : math.max<int>(0, nowMs - anchorMs!));
    while (e >= schedule[i].durationMs && i < schedule.length - 1) {
      e -= schedule[i].durationMs;
      i++;
    }
    final d = schedule[i].durationMs;
    if (e >= d) return ClockPosition(i, d, 0, true);
    return ClockPosition(i, e, d - e, false);
  }

  BlindLevel levelAt(int nowMs) => schedule[positionAt(nowMs).index];

  /// The next blind level (skipping breaks) after the one live at [nowMs].
  BlindLevel? nextLevelAt(int nowMs) => _nextBlind(positionAt(nowMs).index);

  /// The next schedule entry (blind level or break) after the live one.
  BlindLevel? upcomingAt(int nowMs) {
    final i = positionAt(nowMs).index;
    return i + 1 < schedule.length ? schedule[i + 1] : null;
  }

  BlindLevel? _nextBlind(int i) {
    for (var j = i + 1; j < schedule.length; j++) {
      if (!schedule[j].isBreak) return schedule[j];
    }
    return null;
  }

  /// 1-based number of the blind level at [index], not counting breaks.
  int levelNumber(int index) {
    var n = 0;
    for (var j = 0; j <= index && j < schedule.length; j++) {
      if (!schedule[j].isBreak) n++;
    }
    return n;
  }

  /// Fold the time that has run since [anchorMs] into [levelIndex] /
  /// [elapsedBeforeMs] so the stored state matches the live position.
  void _commit(int nowMs) {
    final p = positionAt(nowMs);
    levelIndex = p.index;
    elapsedBeforeMs = mode == ClockMode.cash ? 0 : p.elapsedMs;
    if (anchorMs != null) anchorMs = nowMs;
  }

  void start(int nowMs) {
    if (running) return;
    started = true;
    anchorMs = nowMs;
  }

  void pause(int nowMs) {
    if (!running) return;
    _commit(nowMs);
    anchorMs = null;
  }

  void resume(int nowMs) => start(nowMs);

  void toggle(int nowMs) => running ? pause(nowMs) : start(nowMs);

  /// Jump to the start of the next entry. In cash mode breaks are skipped.
  void next(int nowMs) {
    _commit(nowMs);
    var i = levelIndex + 1;
    if (mode == ClockMode.cash) {
      while (i < schedule.length && schedule[i].isBreak) {
        i++;
      }
    }
    if (i >= schedule.length) {
      // Already on the last level: run it out instead.
      if (mode == ClockMode.tournament) elapsedBeforeMs = schedule[levelIndex].durationMs;
      return;
    }
    levelIndex = i;
    elapsedBeforeMs = 0;
  }

  /// Back to the start of this level; if it has only just begun (under 10 s),
  /// back to the start of the previous one. In cash mode breaks are skipped.
  void previous(int nowMs) {
    _commit(nowMs);
    if (mode == ClockMode.tournament && elapsedBeforeMs >= 10000) {
      elapsedBeforeMs = 0;
      return;
    }
    var i = levelIndex - 1;
    if (mode == ClockMode.cash) {
      while (i >= 0 && schedule[i].isBreak) {
        i--;
      }
    }
    if (i >= 0) levelIndex = i;
    elapsedBeforeMs = 0;
  }

  /// Back to level 1, stopped.
  void reset() {
    levelIndex = mode == ClockMode.cash ? _firstBlind() : 0;
    elapsedBeforeMs = 0;
    anchorMs = null;
    started = false;
  }

  int _firstBlind() {
    final i = schedule.indexWhere((l) => !l.isBreak);
    return i < 0 ? 0 : i;
  }

  /// Replace the schedule, keeping the current level and the time spent in it
  /// (clamped to fit the new schedule).
  void setSchedule(List<BlindLevel> levels, int nowMs) {
    _commit(nowMs);
    schedule = levels.isEmpty ? List.of(defaultSchedule) : List.of(levels);
    levelIndex = levelIndex.clamp(0, schedule.length - 1);
    if (mode == ClockMode.cash && schedule[levelIndex].isBreak) {
      levelIndex = _firstBlind();
    }
    final d = schedule[levelIndex].durationMs;
    if (elapsedBeforeMs > d) elapsedBeforeMs = d;
  }

  void setMode(ClockMode m, int nowMs) {
    if (m == mode) return;
    _commit(nowMs);
    mode = m;
    if (m == ClockMode.cash) {
      elapsedBeforeMs = 0;
      if (schedule[levelIndex].isBreak) {
        // Land on the next blind level (or the previous one at the end).
        var i = levelIndex;
        while (i < schedule.length && schedule[i].isBreak) {
          i++;
        }
        if (i >= schedule.length) {
          i = levelIndex;
          while (i > 0 && schedule[i].isBreak) {
            i--;
          }
        }
        levelIndex = i;
      }
    }
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'schedule': [for (final l in schedule) l.toJson()],
        'mode': mode.name,
        'idx': levelIndex,
        'el': elapsedBeforeMs,
        'anchor': anchorMs,
        'started': started,
      };

  static BlindClock fromJson(Map<String, dynamic> j) => BlindClock(
        schedule: [
          for (final l in (j['schedule'] as List? ?? const []))
            BlindLevel.fromJson((l as Map).cast<String, dynamic>())
        ],
        mode: ClockMode.values.firstWhere((m) => m.name == j['mode'],
            orElse: () => ClockMode.tournament),
        levelIndex: (j['idx'] as int?) ?? 0,
        elapsedBeforeMs: (j['el'] as int?) ?? 0,
        anchorMs: j['anchor'] as int?,
        started: (j['started'] as bool?) ?? false,
      );
}

/// "12:05" or "1:02:05".
String formatClock(int ms) {
  final s = (ms / 1000).ceil();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}
