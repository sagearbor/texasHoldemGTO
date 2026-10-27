/// Pre-solved FLOP c-bet spots (BTN opens, BB calls, BB checks the flop)
/// computed offline by tool/solve_flop.dart with CFR+ and stored in
/// assets/data/flops.json.
///
/// SIMPLIFIED MODEL: one street only. Check-check and called bets are settled
/// by each combo's exact flop equity (all turn+river runouts) times an equity
/// realisation factor (BB realises 90%, BTN the rest). No turn or river play.
/// Every number and sentence here comes from that solution: the coaching is
/// templated text filled from frequencies and equities.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

import '../poker/cards.dart';
import '../poker/evaluator.dart';
import 'coach.dart' show Grade, gradeFor, pct;
import 'hand_class.dart';

const flopBb = 0, flopBtn = 1;
const flopSeatName = ['BB', 'BTN'];

/// Label shown wherever flop data is used.
const flopModelLabel = 'Simplified: one street, equity realisation';

class FlopSide {
  final List<int> c1, c2;

  /// Preflop range weight 0..1 of each combo.
  final List<double> w;

  /// Flop equity 0..1 vs the opponent's whole range (all runouts).
  final List<double> eq;
  FlopSide(this.c1, this.c2, this.w, this.eq);

  int get n => c1.length;

  HandClass cls(int i) => HandClass.fromCards(c1[i], c2[i]);
  String comboName(int i) => cardToString(c1[i]) + cardToString(c2[i]);

  int indexOf(int a, int b) {
    for (var i = 0; i < n; i++) {
      if ((c1[i] == a && c2[i] == b) || (c1[i] == b && c2[i] == a)) return i;
    }
    return -1;
  }

  static FlopSide fromJson(Map<String, dynamic> j) {
    final s = j['combos'] as String;
    final c1 = <int>[], c2 = <int>[];
    for (var k = 0; k < s.length; k += 4) {
      c1.add(parseCard(s.substring(k, k + 2)));
      c2.add(parseCard(s.substring(k + 2, k + 4)));
    }
    return FlopSide(
      c1,
      c2,
      [for (final v in j['w'] as List) (v as num) / 100],
      [for (final v in j['eq'] as List) (v as num) / 100],
    );
  }
}

class FlopNode {
  final String id;
  final int player;
  final List<String> actions;
  final List<(String, int)> path;

  /// Flat per-combo frequencies, combo-major: s[i * k + a].
  final List<double> s;
  FlopNode(this.id, this.player, this.actions, this.path, this.s);

  List<double> freqs(int combo) {
    final k = actions.length;
    return s.sublist(combo * k, combo * k + k);
  }

  static FlopNode fromJson(String id, Map<String, dynamic> j) {
    final actions = (j['actions'] as List).cast<String>();
    final k = actions.length;
    final raw = (j['s'] as List).cast<num>();
    final s = <double>[];
    for (var i = 0; i < raw.length; i += k - 1) {
      var rest = 100.0;
      for (var a = 0; a < k - 1; a++) {
        final v = raw[i + a].toDouble();
        s.add(v / 100);
        rest -= v;
      }
      s.add(max(0, rest) / 100);
    }
    return FlopNode(
      id,
      j['player'] == 'bb' ? flopBb : flopBtn,
      actions,
      [
        for (final p in j['reach'] as List)
          ((p as List)[0] as String, (p[1] as num).toInt())
      ],
      s,
    );
  }
}

/// Short and long description of each decision node.
const flopNodeInfo = {
  'root': ('BTN c-bet', 'BB checks to you on the BTN.'),
  'bbVs33': ('BB vs 33%', 'You check, BTN bets 33% of the pot.'),
  'bbVs75': ('BB vs 75%', 'You check, BTN bets 75% of the pot.'),
  'btnVsRaise33': ('BTN vs raise (33%)', 'You bet 33%, BB check-raises 3x.'),
  'btnVsRaise75': ('BTN vs raise (75%)', 'You bet 75%, BB check-raises 3x.'),
};

/// "A72r", "987ss" (two-tone), "A83m" (monotone).
String shortFlop(List<int> cards) {
  final sorted = [...cards]..sort((a, b) => cardRank(b) - cardRank(a));
  final ranks = sorted.map((c) => rankChars[cardRank(c)]).join();
  final suits = cards.map(cardSuit).toSet().length;
  return ranks +
      (suits == 3
          ? 'r'
          : suits == 2
              ? 'ss'
              : 'm');
}

/// Flush draw / straight draw on the flop (none when already made).
String? drawName(List<int> hole, List<int> flop) {
  final all = [...hole, ...flop];
  final cat = handCategory(evaluate(all));
  final out = <String>[];
  if (cat < 5) {
    for (var s = 0; s < 4; s++) {
      final n = all.where((c) => cardSuit(c) == s).length;
      if (n == 4 && hole.any((c) => cardSuit(c) == s)) {
        out.add(hole.any((c) => cardSuit(c) == s && cardRank(c) == 12)
            ? 'a nut flush draw'
            : 'a flush draw');
      }
    }
  }
  if (cat < 4) {
    // Count ranks (ace also low) that would complete a straight.
    var mask = 0;
    for (final c in all) {
      mask |= 1 << cardRank(c);
    }
    var outs = 0;
    for (var r = 0; r < 13; r++) {
      if (mask & (1 << r) != 0) continue;
      final m = mask | (1 << r);
      final ext = (m << 1) | ((m >> 12) & 1);
      for (var top = 13; top >= 4; top--) {
        if ((ext >> (top - 4)) & 0x1F == 0x1F) {
          // The hole cards must contribute.
          final boardOnly =
              flop.fold<int>(0, (a, c) => a | (1 << cardRank(c))) | (1 << r);
          final be = (boardOnly << 1) | ((boardOnly >> 12) & 1);
          if ((be >> (top - 4)) & 0x1F != 0x1F) outs++;
          break;
        }
      }
    }
    if (outs >= 2) {
      out.add('an open-ended straight draw');
    } else if (outs == 1) {
      out.add('a gutshot');
    }
  }
  if (out.isEmpty) return null;
  return out.join(' and ');
}

class FlopBoard {
  final String boardStr;
  final List<int> cards;
  final String texture;
  final List<FlopSide> sides;
  final Map<String, FlopNode> nodes;
  final Map<String, dynamic> stats;
  final double exploitabilityPctPot;
  final int iterations;
  FlopBoard(this.boardStr, this.cards, this.texture, this.sides, this.nodes,
      this.stats, this.exploitabilityPctPot, this.iterations);

  static FlopBoard fromJson(Map<String, dynamic> j) {
    final b = j['board'] as String;
    return FlopBoard(
      b,
      parseCards(b),
      j['texture'] as String,
      [
        FlopSide.fromJson(j['bb'] as Map<String, dynamic>),
        FlopSide.fromJson(j['btn'] as Map<String, dynamic>),
      ],
      {
        for (final e in (j['nodes'] as Map<String, dynamic>).entries)
          e.key: FlopNode.fromJson(e.key, e.value as Map<String, dynamic>)
      },
      j['stats'] as Map<String, dynamic>,
      (j['exploitabilityPctPot'] as num).toDouble(),
      (j['iterations'] as num).toInt(),
    );
  }

  String get shortName => shortFlop(cards);

  double stat(String k) => (stats[k] as num).toDouble();
  double btnFreq(String action) =>
      ((stats['btn'] as Map<String, dynamic>)[action] as num).toDouble();

  /// BTN's total c-bet frequency (both sizes).
  double get cbet => 1 - btnFreq('Check');

  List<double> reach(FlopNode n) {
    final side = sides[n.player];
    final r = List<double>.of(side.w);
    for (final (id, a) in n.path) {
      final p = nodes[id]!;
      for (var i = 0; i < r.length; i++) {
        r[i] *= p.freqs(i)[a];
      }
    }
    return r;
  }

  /// Reach-weighted strategy per hand class (null = class not in range).
  List<List<double>?> classStrategy(FlopNode n) {
    final side = sides[n.player];
    final r = reach(n);
    final k = n.actions.length;
    final sum = List<List<double>?>.filled(169, null);
    final wt = List<double>.filled(169, 0);
    for (var i = 0; i < side.n; i++) {
      final c = side.cls(i).index;
      final f = n.freqs(i);
      final acc = sum[c] ??= List<double>.filled(k, 0);
      final w = r[i] > 0 ? r[i] : 1e-9;
      for (var a = 0; a < k; a++) {
        acc[a] += w * f[a];
      }
      wt[c] += w;
    }
    for (var c = 0; c < 169; c++) {
      final acc = sum[c];
      if (acc == null) continue;
      for (var a = 0; a < k; a++) {
        acc[a] /= wt[c];
      }
    }
    return sum;
  }

  List<double> rangeFreqs(FlopNode n) {
    final r = reach(n);
    final k = n.actions.length;
    final out = List<double>.filled(k, 0);
    var tot = 0.0;
    for (var i = 0; i < r.length; i++) {
      final f = n.freqs(i);
      for (var a = 0; a < k; a++) {
        out[a] += r[i] * f[a];
      }
      tot += r[i];
    }
    return [for (final x in out) tot > 0 ? x / tot : 0];
  }

  String handName(int player, int i) {
    final s = sides[player];
    return describeHand([s.c1[i], s.c2[i], ...cards]);
  }

  /// One-line c-bet summary, e.g. "BTN bets 33% with 15% and 75% with 45%
  /// of its range on A72r and checks 40%."
  String headline() {
    final s = btnFreq('Bet 33%'), b = btnFreq('Bet 75%');
    final main = s >= b ? ('33%', s, '75%', b) : ('75%', b, '33%', s);
    return 'BTN bets ${main.$1} with ${pct(main.$2)} of its range on '
        '$shortName${main.$4 >= 0.03 ? ' (${main.$3} with ${pct(main.$4)})' : ''}'
        ' and checks ${pct(btnFreq('Check'))}.';
  }

  /// Template sentences describing the solved strategy, from numbers only.
  List<String> summary() {
    final out = <String>[headline()];
    final eb = stat('btnEquity'), eo = stat('bbEquity');
    out.add(eb > eo + 0.04
        ? 'Range advantage BTN: its range has ${pct(eb)} equity vs BB\'s '
            '${pct(eo)}.'
        : eo > eb + 0.04
            ? 'Range advantage BB: ${pct(eo)} equity vs BTN\'s ${pct(eb)}, so '
                'BTN checks more.'
            : 'Ranges are close: BTN ${pct(eb)} equity vs BB ${pct(eo)}.');
    final nb = stat('btnNuts'), no = stat('bbNuts');
    out.add('Two pair or better: ${pct(nb)} of BTN\'s range vs ${pct(no)} of '
        'BB\'s${nb > no * 1.25 && nb - no > 0.01 ? ' (nut advantage BTN)' : no > nb * 1.25 && no - nb > 0.01 ? ' (nut advantage BB)' : ''}.');
    final sb = stat('btnStrong'), so = stat('bbStrong');
    out.add('Hands with over 75% equity: BTN ${pct(sb)}, BB ${pct(so)}.');
    for (final (id, size) in [('bbVs33', '33%'), ('bbVs75', '75%')]) {
      final m = stats[id] as Map<String, dynamic>;
      out.add('Vs a $size bet BB folds ${pct((m['Fold'] as num).toDouble())}, '
          'calls ${pct((m['Call'] as num).toDouble())} and check-raises '
          '${pct((m['Raise'] as num).toDouble())}.');
    }
    out.add(
        'BTN realises ${pct(stat('btnEvShare'))} of the pot in this model.');
    return out;
  }
}

class FlopLibrary {
  final List<FlopBoard> boards;
  final String format;
  final double realiseOop;
  final int solveSeconds;
  FlopLibrary(this.boards, this.format, this.realiseOop, this.solveSeconds);

  static FlopLibrary parse(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    return FlopLibrary(
      [
        for (final b in j['boards'] as List)
          FlopBoard.fromJson(b as Map<String, dynamic>)
      ],
      j['format'] as String,
      (j['realiseOop'] as num).toDouble(),
      (j['solveSeconds'] as num).toInt(),
    );
  }

  static Future<FlopLibrary>? _cache;
  static Future<FlopLibrary> load() => _cache ??=
      rootBundle.loadString('assets/data/flops.json').then(FlopLibrary.parse);

  double get maxExploitability =>
      boards.map((b) => b.exploitabilityPctPot).reduce(max);

  /// Textures in data order.
  List<String> get textures {
    final out = <String>[];
    for (final b in boards) {
      if (!out.contains(b.texture)) out.add(b.texture);
    }
    return out;
  }

  /// Average BTN frequencies per texture: (bet 33%, bet 75%, check).
  Map<String, (double, double, double)> textureAverages() {
    final out = <String, (double, double, double)>{};
    for (final t in textures) {
      final bs = boards.where((b) => b.texture == t).toList();
      double avg(String a) =>
          bs.fold<double>(0, (s, b) => s + b.btnFreq(a)) / bs.length;
      out[t] = (avg('Bet 33%'), avg('Bet 75%'), avg('Check'));
    }
    return out;
  }
}

// ---------------------------------------------------------------- drill ----

/// Drill answers, in the order of the root node's actions.
const flopDrillLabels = ['Check', 'Bet small', 'Bet big'];

class FlopQuestion {
  final FlopBoard board;
  final int combo; // BTN combo index
  FlopQuestion(this.board, this.combo);

  FlopNode get node => board.nodes['root']!;
  FlopSide get side => board.sides[flopBtn];
  List<double> get freqs => node.freqs(combo);
  List<int> get holeCards => [side.c1[combo], side.c2[combo]];
}

/// Random flop and BTN combo (sampled by preflop weight).
FlopQuestion randomFlopQuestion(FlopLibrary lib, Random rng) {
  final b = lib.boards[rng.nextInt(lib.boards.length)];
  final w = b.sides[flopBtn].w;
  final tot = w.fold<double>(0, (a, x) => a + x);
  var x = rng.nextDouble() * tot;
  for (var i = 0; i < w.length; i++) {
    x -= w[i];
    if (x <= 0 && w[i] > 0) return FlopQuestion(b, i);
  }
  return FlopQuestion(b, w.length - 1);
}

Grade gradeFlop(FlopQuestion q, int chosen) => gradeFor(q.freqs[chosen]);

String flopStrategyLine(List<String> actions, List<double> f) => [
      for (var a = 0; a < actions.length; a++)
        if (f[a] > 0.005) '${actions[a]} ${pct(f[a])}'
    ].join(' · ');

String _handPhrase(String category) => switch (category) {
      'High card' => 'no pair',
      'Pair' => 'a pair',
      'Two pair' => 'two pair',
      'Three of a kind' => 'three of a kind',
      'Straight' => 'a straight',
      'Flush' => 'a flush',
      'Full house' => 'a full house',
      'Four of a kind' => 'quads',
      _ => 'a straight flush',
    };

/// Templated coaching for a flop drill answer (numbers from the solution).
List<String> flopCoach(FlopQuestion q, int chosen) {
  final b = q.board;
  final f = q.freqs;
  final notes = <String>[];
  var best = 0;
  for (var a = 1; a < f.length; a++) {
    if (f[a] > f[best]) best = a;
  }
  if (chosen != best && f[chosen] < 0.25) {
    notes.add('The solver prefers ${q.node.actions[best]} (${pct(f[best])}).');
  }
  final eq = q.side.eq[q.combo];
  final draw = drawName(q.holeCards, b.cards);
  notes.add('You have ${_handPhrase(b.handName(flopBtn, q.combo))}'
      '${draw == null ? '' : ' with $draw'}: ${pct(eq)} equity vs BB\'s '
      'whole range.');
  final w = q.side.w;
  var weaker = 0.0, tot = 0.0;
  for (var i = 0; i < w.length; i++) {
    tot += w[i];
    if (q.side.eq[i] < eq) weaker += w[i];
  }
  final rank = weaker / tot;
  notes.add('That is stronger than ${pct(rank)} of BTN\'s range here.');

  final eb = b.stat('btnEquity'), eo = b.stat('bbEquity');
  final nb = b.stat('btnNuts'), no = b.stat('bbNuts');
  notes.add('Range: BTN ${pct(eb)} equity vs BB ${pct(eo)}; two pair or '
      'better BTN ${pct(nb)} vs BB ${pct(no)}. '
      '${b.headline()}');

  final bet = f[1] + f[2];
  final big = f[2] >= f[1];
  final vs = b.stats[big ? 'bbVs75' : 'bbVs33'] as Map<String, dynamic>;
  final fold = (vs['Fold'] as num).toDouble();
  if (bet >= 0.6) {
    if (rank >= 0.6) {
      notes.add('Value: you are ahead of most of BB\'s range and BB calls '
          '${pct(1 - fold - (vs['Raise'] as num).toDouble())} of the time '
          'vs a ${big ? '75%' : '33%'} bet.');
    } else {
      notes.add('Bet for fold equity${draw != null ? ' and your draw' : ''}: '
          'BB folds ${pct(fold)} to a ${big ? '75%' : '33%'} bet.');
    }
    if (big && f[2] > 0.5) {
      notes.add('Big size: the hand is near the top or bottom of BTN\'s range '
          '(polarised), where a bigger bet gains the most.');
    } else if (!big && f[1] > 0.5) {
      notes.add('Small size: a cheap bet with a hand that wants to fold out '
          'BB\'s weakest hands or charge many hands a little.');
    }
  } else if (f[0] >= 0.6) {
    notes.add(rank >= 0.4
        ? 'Check: a medium hand that wins at showdown often; betting mostly '
            'folds out worse hands and gets called by better ones.'
        : 'Check: too weak to bet profitably here; BB only folds '
            '${pct(fold)} to a ${big ? '75%' : '33%'} bet and you have '
            '${pct(eq)} equity when it calls.');
  } else {
    notes.add('A mixed hand: betting and checking are worth about the same, '
        'so the solver plays both.');
  }
  return notes;
}
