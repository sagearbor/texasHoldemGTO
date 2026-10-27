/// Daily 10: the same ten drills for every player on a given local date,
/// one counted attempt per day, day streaks and a shareable result.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gto/hand_class.dart';
import '../gto/spots.dart';
import 'trainer_model.dart' show Clock, edginess;

const dailyLength = 10;
const dailyUrl = 'https://sagearbor.github.io/texasHoldemGTO/';

/// Day #1 of the Daily 10.
final _epoch = DateTime.utc(2026, 10, 27);

/// yyyymmdd of the local calendar date of [d].
int dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

DateTime dayFromKey(int k) => DateTime(k ~/ 10000, k ~/ 100 % 100, k % 100);

/// Daily number: days since 2026-10-27, plus one. Computed on UTC midnights
/// so daylight-saving shifts never skew it.
int dayNumber(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).difference(_epoch).inDays + 1;

int _prevDay(int k) {
  final d = dayFromKey(k);
  return dayKey(DateTime(d.year, d.month, d.day - 1));
}

/// Mulberry32: tiny seeded PRNG written with operations that stay exact in
/// both the Dart VM and JavaScript (dart:math's seeded Random is not
/// guaranteed to match across platforms, and every player must get the same
/// set — web and phones alike).
class DailyRng {
  static const _m = 0xffffffff;
  int _a;
  DailyRng(int seed) : _a = seed & _m;

  /// 32-bit multiply mod 2^32 without exceeding 2^53 (JS-safe).
  static int _imul(int a, int b) {
    final ah = (a >> 16) & 0xffff, al = a & 0xffff;
    return ((((ah * b) & 0xffff) * 65536) + al * b) & _m;
  }

  /// Uniform in [0, 1).
  double nextDouble() {
    _a = (_a + 0x6D2B79F5) & _m;
    var t = _imul(_a ^ (_a >> 15), _a | 1);
    t = t ^ ((t + _imul(t ^ (t >> 7), t | 61)) & _m);
    return ((t ^ (t >> 14)) & _m) / 4294967296;
  }

  int nextInt(int n) => (nextDouble() * n).floor();

  int weighted(List<num> w) {
    final total = w.fold<double>(0, (a, b) => a + b);
    var x = nextDouble() * total;
    for (var i = 0; i < w.length; i++) {
      x -= w[i];
      if (x < 0) return i;
    }
    return w.length - 1;
  }
}

class DailyDrill {
  final Spot spot;
  final List<int> cards;
  DailyDrill(this.spot, this.cards);
  HandClass get hand => HandClass.fromCards(cards[0], cards[1]);
}

/// Ten drills for [date]: 6 cash + 4 push/fold spots (distinct), hands
/// weighted toward the edge of each range. Pure function of the date and the
/// spot library.
List<DailyDrill> dailySet(SpotLibrary lib, DateTime date) {
  final rng = DailyRng(dayKey(date));
  List<Spot> take(List<Spot> from, int n) {
    final l = [...from];
    final out = <Spot>[];
    while (out.length < n && l.isNotEmpty) {
      out.add(l.removeAt(rng.nextInt(l.length)));
    }
    return out;
  }

  // Facing-limper spots are left out so the set for a date stays identical
  // across app versions (web updates before the phone apps do).
  final cash = [for (final s in lib.cash) if (s.group != limperGroup) s];
  final spots = lib.pushFold.isEmpty
      ? take([...cash, ...lib.pushFold], dailyLength)
      : [...take(cash, 6), ...take(lib.pushFold, dailyLength - 6)];
  // Shuffle so formats are interleaved.
  for (var i = spots.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final t = spots[i];
    spots[i] = spots[j];
    spots[j] = t;
  }
  return [
    for (final s in spots)
      () {
        final h = HandClass.byIndex(rng.weighted(
            [for (final h in allHandClasses) h.comboCount * edginess(s, h)]));
        final combos = h.combos();
        return DailyDrill(s, combos[rng.nextInt(combos.length)]);
      }()
  ];
}

/// G = GTO play (>=70%), Y = mixed / fine (>=25%), R = miss.
String markFor(double freq) => freq >= 0.7
    ? 'G'
    : freq >= 0.25
        ? 'Y'
        : 'R';

const _emoji = {'G': '🟩', 'Y': '🟨', 'R': '🟥'};

/// GTO plays count 1, mixed plays 0.5.
double dailyScore(String marks) {
  var s = 0.0;
  for (final c in marks.split('')) {
    if (c == 'G') s += 1;
    if (c == 'Y') s += 0.5;
  }
  return s;
}

String scoreLabel(double s) =>
    s == s.roundToDouble() ? '${s.round()}' : s.toStringAsFixed(1);

String shareText(DateTime date, String marks) =>
    'Felt Notes Daily #${dayNumber(date)} · '
    '${scoreLabel(dailyScore(marks))}/$dailyLength '
    '${marks.split('').map((c) => _emoji[c] ?? '').join()}\n$dailyUrl';

class DailyModel extends ChangeNotifier {
  static const _key = 'daily_v1';

  final SpotLibrary library;
  final Clock _clock;

  /// dayKey -> marks string ('G'/'Y'/'R' per answered drill, up to 10).
  final Map<int, String> results = {};
  int _best = 0;

  int? _setDay;
  List<DailyDrill> _set = const [];

  DailyModel(this.library, {Clock? clock}) : _clock = clock ?? DateTime.now;

  DateTime get date => _clock();
  int get today => dayKey(date);
  int get number => dayNumber(date);

  List<DailyDrill> get drills {
    if (_setDay != today) {
      _setDay = today;
      _set = dailySet(library, date);
    }
    return _set;
  }

  String get marks => results[today] ?? '';
  int get answered => marks.length;
  bool get done => answered >= dailyLength;
  bool get started => answered > 0;
  DailyDrill? get currentDrill => done ? null : drills[answered];
  double get score => dailyScore(marks);
  String get share => shareText(date, marks);

  bool _complete(int k) => (results[k]?.length ?? 0) >= dailyLength;

  /// Consecutive completed days ending today (or yesterday, if today's
  /// challenge isn't finished yet — the streak is still alive).
  int get streak {
    var k = _complete(today) ? today : _prevDay(today);
    var n = 0;
    while (_complete(k)) {
      n++;
      k = _prevDay(k);
    }
    return n;
  }

  int get bestStreak {
    var best = _best, run = 0;
    int? prev;
    for (final k in results.keys.where(_complete).toList()..sort()) {
      run = (prev != null && _prevDay(k) == prev) ? run + 1 : 1;
      if (run > best) best = run;
      prev = k;
    }
    return best;
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        (j['r'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
          results[int.parse(k)] = v as String;
        });
        _best = j['best'] as int? ?? 0;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key,
          jsonEncode({
            'r': {for (final e in results.entries) '${e.key}': e.value},
            'best': _best,
          }));
    } catch (_) {}
  }

  /// Answers the next drill of today's set. Returns the chosen action's GTO
  /// frequency. Once answered a drill can't be replayed: one attempt a day.
  double answer(int actionIndex) {
    final d = currentDrill;
    if (d == null) throw StateError('Daily already finished');
    final f = d.spot.freqs(d.hand)[actionIndex];
    results[today] = marks + markFor(f);
    if (done) _best = bestStreak;
    _save();
    notifyListeners();
    return f;
  }
}
