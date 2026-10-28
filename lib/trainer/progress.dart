/// "GTO score over time": trainer accuracy bucketed per day or week, and
/// the per-night GTO grade of home-game nights. Local data only.
library;

import '../gto/spots.dart';
import '../homegame/home_game.dart';
import 'trainer_model.dart';

/// One day or week of trainer answers.
class ScoreBucket {
  /// Local midnight the bucket starts (a Monday for weeks).
  final DateTime start;
  final int count;

  /// Answers that were not misses (same rule as TrainerModel.accuracy).
  final int good;
  const ScoreBucket(this.start, this.count, this.good);

  /// Null when nothing was answered in this bucket.
  double? get accuracy => count == 0 ? null : good / count;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Local midnight of the Monday of [d]'s week.
DateTime weekStart(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - DateTime.monday));

/// The last [count] days (or weeks, when [byDay] is false) up to and
/// including the one holding [now], oldest first. Empty periods are kept
/// (accuracy null) so the chart shows gaps; older answers are dropped.
List<ScoreBucket> bucketAnswers(Iterable<Answer> answers, DateTime now,
    {required bool byDay, int count = 12}) {
  final last = byDay ? _day(now) : weekStart(now);
  // Calendar arithmetic (not Duration) so DST changes don't shift buckets.
  DateTime startOf(int i) {
    final back = (count - 1 - i) * (byDay ? 1 : 7);
    return DateTime(last.year, last.month, last.day - back);
  }

  final starts = [for (var i = 0; i < count; i++) startOf(i)];
  final n = List.filled(count, 0), good = List.filled(count, 0);
  for (final a in answers) {
    final d = DateTime.fromMillisecondsSinceEpoch(a.ts);
    final key = byDay ? _day(d) : weekStart(d);
    final i = starts.indexOf(key);
    if (i < 0) continue;
    n[i]++;
    if (!a.isMiss) good[i]++;
  }
  return [for (var i = 0; i < count; i++) ScoreBucket(starts[i], n[i], good[i])];
}

/// One home-game night's GTO grade.
class NightGrade {
  final String name;
  final DateTime date;

  /// Share of graded decisions that matched the chart, 0..1.
  final double score;
  final int graded;
  const NightGrade(this.name, this.date, this.score, this.graded);
}

/// Nights with at least one graded decision, oldest first.
List<NightGrade> nightGrades(Iterable<HomeSession> sessions, SpotLibrary lib) {
  final out = <NightGrade>[];
  for (final s in sessions) {
    final st = computeStats(s.hands, lib);
    if (st.graded == 0) continue;
    out.add(NightGrade(s.name, DateTime.fromMillisecondsSinceEpoch(s.started),
        st.gtoScore, st.graded));
  }
  out.sort((a, b) => a.date.compareTo(b.date));
  return out;
}
