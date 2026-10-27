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

class TrainerModel extends ChangeNotifier {
  static const _key = 'trainer_history_v1';
  static const _maxHistory = 3000;

  final SpotLibrary library;
  final Random _rng;
  final List<Answer> history = [];
  DrillMode mode = DrillMode.mixed;

  /// When non-null, drills stay in this one spot.
  String? focusSpotId;

  Drill? current;
  Answer? lastAnswer;
  int streak = 0;
  int sessionCount = 0;
  int sessionGood = 0;

  TrainerModel(this.library, {Random? rng}) : _rng = rng ?? Random();

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
    } catch (_) {
      // Storage unavailable (private window etc.): run without history.
    }
    next();
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
    streak = sessionCount = sessionGood = 0;
    await _save();
    notifyListeners();
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

  void focus(String? spotId) {
    focusSpotId = spotId;
    next();
  }

  void next() {
    lastAnswer = null;
    current = _pick();
    notifyListeners();
  }

  Drill _pick() {
    final pool = _pool;
    Spot spot;
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
    if (_rng.nextBool()) {
      final cards = dealRandom(_rng, 2, {});
      hand = HandClass.fromCards(cards[0], cards[1]);
    } else {
      final weights = [
        for (final h in allHandClasses) h.comboCount * _edginess(spot, h)
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

  /// 0.05 for hands that are obviously in/out, up to 1 for borderline hands.
  double _edginess(Spot spot, HandClass h) {
    final p = playFreq(spot, h);
    if (p > 0.03 && p < 0.97) return 1;
    for (final (dr, dc) in [(0, 1), (0, -1), (1, 0), (-1, 0)]) {
      final r = h.row + dr, c = h.col + dc;
      if (r < 0 || r > 12 || c < 0 || c > 12) continue;
      if ((playFreq(spot, HandClass(r, c)) - p).abs() > 0.5) return 0.7;
    }
    return 0.05;
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

  Answer answer(int actionIndex) {
    final d = current!;
    final f = d.spot.freqs(d.hand)[actionIndex];
    final a = Answer(d.spot.id, d.hand.index, actionIndex, f,
        DateTime.now().millisecondsSinceEpoch);
    history.add(a);
    lastAnswer = a;
    sessionCount++;
    if (!a.isMiss) {
      sessionGood++;
      streak++;
    } else {
      streak = 0;
    }
    _save();
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
