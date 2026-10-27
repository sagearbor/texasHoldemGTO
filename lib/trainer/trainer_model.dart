/// Trainer state: picks drills, records answers, persists history locally.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gto/coach.dart';
import '../gto/hand_class.dart';
import '../gto/spots.dart';
import '../poker/cards.dart';
import 'daily.dart';

class Drill {
  final Spot spot;
  final List<int> cards;
  Drill(this.spot, this.cards);
  HandClass get hand => HandClass.fromCards(cards[0], cards[1]);
}

class Answer {
  final String spotId;
  final int hand;
  final int chosen;
  final double freq;
  final int ts;
  Answer(this.spotId, this.hand, this.chosen, this.freq, this.ts);

  Grade get grade => gradeFor(freq);
  bool get isMiss => freq < 0.25;

  Map<String, dynamic> toJson() =>
      {'s': spotId, 'h': hand, 'c': chosen, 'f': freq, 't': ts};
  static Answer fromJson(Map<String, dynamic> j) => Answer(j['s'] as String,
      j['h'] as int, j['c'] as int, (j['f'] as num).toDouble(), j['t'] as int);
}

enum DrillMode { mixed, cashOnly, pushFoldOnly, leaks }

/// Which hands the free-play trainer deals, and how strictly it grades.
/// Beginner: clear-cut hands only, the >= 50% action counts as right,
/// short coaching. Intermediate: the original mix. Expert: borderline hands
/// only. The Daily 10 and the spaced-repetition deck ignore this.
enum Difficulty { beginner, intermediate, expert }

const difficultyLabels = {
  Difficulty.beginner: 'Beginner',
  Difficulty.intermediate: 'Intermediate',
  Difficulty.expert: 'Expert',
};

/// Whether [h] is dealt in [spot] at difficulty [d].
bool handFitsDifficulty(Spot spot, HandClass h, Difficulty d) {
  switch (d) {
    case Difficulty.intermediate:
      return true;
    case Difficulty.beginner:
      return edginess(spot, h) <= 0.05 && spot.freqs(h).any((f) => f >= 0.8);
    case Difficulty.expert:
      return edginess(spot, h) >= 0.7;
  }
}

/// Injectable wall clock (tests pass a fake one).
typedef Clock = DateTime Function();

/// Leitner review intervals, indexed by the box a card is in when it is
/// answered correctly: a fresh miss (box 0) is re-checked 10 minutes later,
/// then after 1, 3, 7 and 21 days. A miss always drops the card to box 0,
/// due immediately.
const srIntervals = [
  Duration(minutes: 10),
  Duration(days: 1),
  Duration(days: 3),
  Duration(days: 7),
  Duration(days: 21),
];
const srMaxBox = 4;

/// One spaced-repetition card: a (spot, hand class) pair you have missed.
class SrCard {
  final String spotId;
  final int hand;
  int box;

  /// Epoch milliseconds when the card is next due.
  int due;
  SrCard(this.spotId, this.hand, this.box, this.due);

  String get key => '$spotId:$hand';
}

/// Spaced-repetition deck. Cards enter on a miss (in the trainer or from a
/// home-game hand) and climb boxes 0..4 on each correct answer.
///
/// The deck is NOT stored: it is replayed deterministically from the answer
/// history (plus a tiny list of home-game seeds) on load. That needs no
/// schema migration, gives existing users a deck straight away from their
/// past misses, and can never drift out of sync with the history it is
/// derived from. Replay of 3000 answers is a few hundred microseconds.
class SrDeck {
  final Map<String, SrCard> cards = {};

  /// A graded answer at [ts]. Hits only matter for cards already in the deck.
  void review(String spotId, int hand, bool hit, int ts) {
    final k = '$spotId:$hand';
    if (!hit) {
      final c = cards.putIfAbsent(k, () => SrCard(spotId, hand, 0, ts));
      c
        ..box = 0
        ..due = ts;
      return;
    }
    final c = cards[k];
    if (c == null) return;
    c.due = ts + srIntervals[c.box].inMilliseconds;
    if (c.box < srMaxBox) c.box++;
  }

  /// Cards due at [now], most overdue first (ties broken by key so the
  /// order is fully deterministic).
  List<SrCard> due(int now) {
    final l = cards.values.where((c) => c.due <= now).toList()
      ..sort((a, b) {
        final d = a.due.compareTo(b.due);
        return d != 0 ? d : a.key.compareTo(b.key);
      });
    return l;
  }

  void clear() => cards.clear();
}

class TrainerModel extends ChangeNotifier {
  static const _key = 'trainer_history_v1';
  static const _seedKey = 'trainer_sr_seeds_v1';
  static const _difficultyKey = 'trainer_difficulty_v1';
  static const _maxHistory = 3000;
  static const _maxSeeds = 500;

  final SpotLibrary library;
  final Random _rng;
  final Clock _clock;
  final List<Answer> history = [];

  /// Spaced-repetition deck, derived from [history] + [_seeds].
  final SrDeck deck = SrDeck();

  /// Home-game misses fed in via [addExternalMisses]: (spotId, hand, ts).
  final List<(String, int, int)> _seeds = [];

  /// Today's Daily 10 challenge (shares this model's clock).
  late final DailyModel daily = DailyModel(library, clock: _clock);

  /// Key of the card answered last, so a just-missed card (due "now") is not
  /// served again straight away.
  String? _lastKey;
  DrillMode mode = DrillMode.mixed;
  Difficulty difficulty = Difficulty.intermediate;

  /// Solver-dice roll (0..99) for the last answer, when the hand is mixed.
  int? lastRoll;

  /// When non-null, drills stay in this one spot.
  String? focusSpotId;

  Drill? current;
  Answer? lastAnswer;
  int streak = 0;
  int sessionCount = 0;
  int sessionGood = 0;

  TrainerModel(this.library, {Random? rng, Clock? clock})
      : _rng = rng ?? Random(),
        _clock = clock ?? DateTime.now;

  int get _now => _clock().millisecondsSinceEpoch;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        history.addAll([
          for (final j in jsonDecode(raw) as List)
            Answer.fromJson(j as Map<String, dynamic>)
        ]);
      }
      final diff = prefs.getString(_difficultyKey);
      for (final d in Difficulty.values) {
        if (d.name == diff) difficulty = d;
      }
      final seeds = prefs.getString(_seedKey);
      if (seeds != null) {
        _seeds.addAll([
          for (final j in jsonDecode(seeds) as List)
            (j['s'] as String, j['h'] as int, j['t'] as int)
        ]);
      }
    } catch (_) {
      // Storage unavailable (private window etc.): run without history.
    }
    _rebuildDeck();
    await daily.load();
    next();
  }

  /// Replays history and home-game seeds, in time order, into the deck.
  void _rebuildDeck() {
    deck.clear();
    final events = <(int, String, int, bool)>[
      for (final a in history) (a.ts, a.spotId, a.hand, !a.isMiss),
      for (final (s, h, t) in _seeds) (t, s, h, false),
    ];
    // List.sort is not guaranteed stable; sort by (ts, original index).
    final idx = List.generate(events.length, (i) => i)
      ..sort((a, b) {
        final d = events[a].$1.compareTo(events[b].$1);
        return d != 0 ? d : a.compareTo(b);
      });
    for (final i in idx) {
      final (t, s, h, hit) = events[i];
      deck.review(s, h, hit, t);
    }
  }

  Spot? _spotOrNull(String id) {
    for (final s in library.all) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Cards due now, most overdue first (only spots that still exist).
  List<SrCard> dueCards() =>
      [for (final c in deck.due(_now)) if (_spotOrNull(c.spotId) != null) c];

  int get dueCount => dueCards().length;

  /// Seeds home-game misses into the deck: box 0, due now. Each entry is
  /// (spotId, hand class index).
  Future<void> addExternalMisses(List<(String, int)> misses) async {
    if (misses.isEmpty) return;
    final t = _now;
    for (final (s, h) in misses) {
      _seeds.add((s, h, t));
      deck.review(s, h, false, t);
    }
    if (_seeds.length > _maxSeeds) {
      _seeds.removeRange(0, _seeds.length - _maxSeeds);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_seedKey,
          jsonEncode([for (final (s, h, t) in _seeds) {'s': s, 'h': h, 't': t}]));
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tail = history.length > _maxHistory
          ? history.sublist(history.length - _maxHistory)
          : history;
      await prefs.setString(_key, jsonEncode([for (final a in tail) a.toJson()]));
    } catch (_) {}
  }

  Future<void> clearHistory() async {
    history.clear();
    _seeds.clear();
    deck.clear();
    streak = sessionCount = sessionGood = 0;
    await _save();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_seedKey);
    } catch (_) {}
    notifyListeners();
  }

  /// Back to a fresh install: no history, default mode, no focus spot.
  Future<void> resetAll() async {
    history.clear();
    streak = sessionCount = sessionGood = 0;
    mode = DrillMode.mixed;
    focusSpotId = null;
    await _save();
    next();
  }

  List<Spot> get _pool {
    if (focusSpotId != null) return [library.byId(focusSpotId!)];
    switch (mode) {
      case DrillMode.cashOnly:
        return library.cash;
      case DrillMode.pushFoldOnly:
        return [...library.pushFold, ...library.pushFold3];
      case DrillMode.mixed:
      case DrillMode.leaks:
        return library.all;
    }
  }

  void setMode(DrillMode m) {
    mode = m;
    focusSpotId = null;
    next();
  }

  Future<void> setDifficulty(Difficulty d) async {
    difficulty = d;
    next();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_difficultyKey, d.name);
    } catch (_) {}
  }

  /// Grade shown for [a] at the current difficulty. The stored answer keeps
  /// the true frequency, so history and the deck are unaffected.
  Grade gradeOf(Answer a) =>
      difficulty == Difficulty.beginner ? beginnerGradeFor(a.freq) : a.grade;

  void focus(String? spotId) {
    focusSpotId = spotId;
    next();
  }

  void next() {
    lastAnswer = null;
    lastRoll = null;
    current = _pick();
    notifyListeners();
  }

  Drill _pick() {
    final pool = _pool;
    Spot spot;
    // Spaced repetition first: the most overdue card that isn't the one just
    // answered.
    if (mode == DrillMode.leaks && focusSpotId == null) {
      for (final c in dueCards()) {
        if (c.key == _lastKey) continue;
        final combos = HandClass.byIndex(c.hand).combos();
        return Drill(_spotOrNull(c.spotId)!, combos[_rng.nextInt(combos.length)]);
      }
    }
    if (mode == DrillMode.leaks && focusSpotId == null && history.isNotEmpty) {
      // Weight spots by recent misses (+1 smoothing so nothing starves).
      final misses = <String, double>{};
      for (final a in history.reversed.take(400)) {
        if (a.isMiss) misses[a.spotId] = (misses[a.spotId] ?? 0) + 1;
      }
      final weights = [for (final s in pool) 1 + 4 * (misses[s.id] ?? 0)];
      spot = pool[_weighted(weights)];
    } else {
      spot = pool[_rng.nextInt(pool.length)];
    }

    // Half the time deal a uniformly random hand; otherwise favour hands on
    // the edge of the range, which is where people actually make mistakes.
    HandClass hand;
    final filtered = difficulty == Difficulty.intermediate
        ? null
        : _pickForDifficulty(spot);
    if (filtered != null) {
      hand = filtered;
    } else if (_rng.nextBool()) {
      final cards = dealRandom(_rng, 2, {});
      hand = HandClass.fromCards(cards[0], cards[1]);
    } else {
      final weights = [
        for (final h in allHandClasses) h.comboCount * edginess(spot, h)
      ];
      hand = HandClass.byIndex(_weighted(weights));
    }
    if (mode == DrillMode.leaks && history.isNotEmpty && _rng.nextDouble() < 0.4) {
      final missed = history.reversed
          .take(400)
          .where((a) => a.isMiss && a.spotId == spot.id)
          .toList();
      if (missed.isNotEmpty) {
        hand = HandClass.byIndex(missed[_rng.nextInt(missed.length)].hand);
      }
    }
    final combos = hand.combos();
    return Drill(spot, combos[_rng.nextInt(combos.length)]);
  }

  /// A hand for Beginner / Expert, or null when no hand in [spot] fits.
  HandClass? _pickForDifficulty(Spot spot) {
    final fits = [
      for (final h in allHandClasses)
        if (handFitsDifficulty(spot, h, difficulty)) h
    ];
    if (fits.isEmpty) return null;
    var from = fits;
    if (difficulty == Difficulty.beginner) {
      // Clear-cut hands are mostly folds; deal played and folded hands
      // equally often so beginners learn what IS in the range.
      final passive = spot.passiveIndex;
      final play = fits.where((h) => spot.freqs(h)[passive] < 0.5).toList();
      final fold = fits.where((h) => spot.freqs(h)[passive] >= 0.5).toList();
      if (play.isNotEmpty && fold.isNotEmpty) {
        from = _rng.nextBool() ? play : fold;
      }
    }
    return from[_weighted([for (final h in from) h.comboCount])];
  }

  int _weighted(List<num> w) {
    final total = w.fold<double>(0, (a, b) => a + b);
    var x = _rng.nextDouble() * total;
    for (var i = 0; i < w.length; i++) {
      x -= w[i];
      if (x <= 0) return i;
    }
    return w.length - 1;
  }

  /// Grades and records one answer (history + spaced-repetition deck)
  /// without touching the current drill or session counters. Used by the
  /// Daily 10 as well as [answer].
  Answer record(Spot spot, HandClass hand, int actionIndex) {
    final f = spot.freqs(hand)[actionIndex];
    final a = Answer(spot.id, hand.index, actionIndex, f, _now);
    history.add(a);
    deck.review(a.spotId, a.hand, !a.isMiss, a.ts);
    _lastKey = '${a.spotId}:${a.hand}';
    _save();
    notifyListeners();
    return a;
  }

  Answer answer(int actionIndex) {
    final d = current!;
    final a = record(d.spot, d.hand, actionIndex);
    lastAnswer = a;
    lastRoll = isMixedHand(d.spot, d.hand) ? _rng.nextInt(100) : null;
    sessionCount++;
    final good = difficulty == Difficulty.beginner
        ? gradeOf(a) == Grade.correct
        : !a.isMiss;
    if (good) {
      sessionGood++;
      streak++;
    } else {
      streak = 0;
    }
    notifyListeners();
    return a;
  }

  // ---- Stats -------------------------------------------------------------

  /// Average frequency of the chosen action: 100% = always picked a GTO
  /// action, mixing counted at its weight.
  double accuracy(Iterable<Answer> answers) {
    final l = answers.toList();
    if (l.isEmpty) return 0;
    return l.fold<double>(0, (a, b) => a + (b.isMiss ? 0 : 1)) / l.length;
  }

  Map<String, List<Answer>> bySpot() {
    final m = <String, List<Answer>>{};
    for (final a in history) {
      (m[a.spotId] ??= []).add(a);
    }
    return m;
  }

  /// Per hand-class (count, misses) across all spots.
  Map<int, (int, int)> byHand() {
    final m = <int, (int, int)>{};
    for (final a in history) {
      final (n, miss) = m[a.hand] ?? (0, 0);
      m[a.hand] = (n + 1, miss + (a.isMiss ? 1 : 0));
    }
    return m;
  }

  /// Most teachable mistakes: misses, worst first, de-duplicated by
  /// (spot, hand), favouring hands that come up often in that spot.
  List<Answer> teachable({int limit = 10}) {
    final seen = <String>{};
    final misses = history.reversed.where((a) => a.isMiss).where((a) {
      final k = '${a.spotId}:${a.hand}';
      return seen.add(k);
    }).toList();
    double score(Answer a) {
      final spot = library.byId(a.spotId);
      final edge = spot.edge?[a.hand].abs() ?? 0.5;
      final repeats =
          history.where((b) => b.spotId == a.spotId && b.hand == a.hand && b.isMiss).length;
      return (1 - a.freq) * (0.5 + edge) * repeats;
    }

    misses.sort((a, b) => score(b).compareTo(score(a)));
    return misses.take(limit).toList();
  }
}

/// 0.05 for hands that are obviously in/out, up to 1 for borderline hands.
double edginess(Spot spot, HandClass h) {
  final p = playFreq(spot, h);
  if (p > 0.03 && p < 0.97) return 1;
  for (final (dr, dc) in [(0, 1), (0, -1), (1, 0), (-1, 0)]) {
    final r = h.row + dr, c = h.col + dc;
    if (r < 0 || r > 12 || c < 0 || c > 12) continue;
    if ((playFreq(spot, HandClass(r, c)) - p).abs() > 0.5) return 0.7;
  }
  return 0.05;
}
