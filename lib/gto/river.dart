/// Pre-solved river spots (BB vs BTN, single-raised pot) computed offline by
/// tool/solve_river.dart with CFR+ and stored in assets/data/rivers.json.
///
/// Every number and sentence here comes from the solver output: the coaching
/// is templated text filled from frequencies, equities and pot odds.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

import '../poker/cards.dart';
import '../poker/evaluator.dart';
import 'coach.dart' show Grade, gradeFor, pct;
import 'hand_class.dart';

const riverOop = 0, riverIp = 1;
const riverSeatName = ['BB', 'BTN'];

class RiverSide {
  final List<int> c1, c2;

  /// Preflop range weight 0..1 of each combo.
  final List<double> w;

  /// Raw showdown equity 0..1 vs the opponent's whole river range.
  final List<double> eq;
  RiverSide(this.c1, this.c2, this.w, this.eq);

  int get n => c1.length;

  HandClass cls(int i) => HandClass.fromCards(c1[i], c2[i]);
  String comboName(int i) => cardToString(c1[i]) + cardToString(c2[i]);

  int indexOf(int a, int b) {
    for (var i = 0; i < n; i++) {
      if ((c1[i] == a && c2[i] == b) || (c1[i] == b && c2[i] == a)) return i;
    }
    return -1;
  }

  static RiverSide fromJson(Map<String, dynamic> j) {
    final s = j['combos'] as String;
    final c1 = <int>[], c2 = <int>[];
    for (var k = 0; k < s.length; k += 4) {
      c1.add(parseCard(s.substring(k, k + 2)));
      c2.add(parseCard(s.substring(k + 2, k + 4)));
    }
    return RiverSide(
      c1,
      c2,
      [for (final v in j['w'] as List) (v as num) / 100],
      [for (final v in j['eq'] as List) (v as num) / 100],
    );
  }
}

class RiverNode {
  final String id;
  final int player;
  final List<String> actions;

  /// Owner's earlier decisions on the path: (nodeId, actionIndex).
  final List<(String, int)> path;

  /// Flat per-combo frequencies, combo-major: s[i * k + a].
  final List<double> s;
  RiverNode(this.id, this.player, this.actions, this.path, this.s);

  List<double> freqs(int combo) {
    final k = actions.length;
    return s.sublist(combo * k, combo * k + k);
  }

  static RiverNode fromJson(String id, Map<String, dynamic> j) {
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
    return RiverNode(
      id,
      j['player'] == 'oop' ? riverOop : riverIp,
      actions,
      [
        for (final p in j['reach'] as List)
          ((p as List)[0] as String, (p[1] as num).toInt())
      ],
      s,
    );
  }
}

/// Short description of the betting before each decision node.
const riverNodeInfo = {
  'root': ('BB first to act', 'BB acts first on the river.'),
  'ipVsCheck': ('BTN vs check', 'BB checks to you on the BTN.'),
  'ipVsBet': ('BTN vs 66% bet', 'BB bets 66% of the pot.'),
  'oopVsBet33': ('BB vs 33% bet', 'You check, BTN bets 33% of the pot.'),
  'oopVsBet75': ('BB vs 75% bet', 'You check, BTN bets 75% of the pot.'),
  'oopVsRaise': ('BB vs all-in', 'You bet 66%, BTN moves all-in.'),
  'ipVsRaise33': ('BTN vs check-raise', 'You bet 33%, BB check-raises all-in.'),
  'ipVsRaise75': ('BTN vs check-raise', 'You bet 75%, BB check-raises all-in.'),
};

/// Size (fraction of the pot) the hero faces at a node, or null.
double? facingBet(String nodeId, double stack) => switch (nodeId) {
      'ipVsBet' => 0.66,
      'oopVsBet33' => 0.33,
      'oopVsBet75' => 0.75,
      // All-in: the caller already put in the bet, owes stack - bet more.
      'oopVsRaise' => stack,
      'ipVsRaise33' => stack,
      'ipVsRaise75' => stack,
      _ => null,
    };

/// Amount the hero already has in at a node (pot fractions).
double heroIn(String nodeId) => switch (nodeId) {
      'oopVsRaise' => 0.66,
      'ipVsRaise33' => 0.33,
      'ipVsRaise75' => 0.75,
      _ => 0,
    };

/// Equity needed to call: price / (final pot).
double potOddsNeeded(String nodeId, double stack) {
  final b = facingBet(nodeId, stack);
  if (b == null) return 0;
  final mine = heroIn(nodeId);
  final toCall = b - mine;
  return toCall / (1 + b + b);
}

class RiverBoard {
  final String boardStr;
  final List<int> cards;
  final String texture;
  final List<RiverSide> sides;
  final Map<String, RiverNode> nodes;
  final Map<String, dynamic> stats;
  final double exploitabilityPctPot;
  RiverBoard(this.boardStr, this.cards, this.texture, this.sides, this.nodes,
      this.stats, this.exploitabilityPctPot);

  static RiverBoard fromJson(Map<String, dynamic> j) {
    final b = j['board'] as String;
    return RiverBoard(
      b,
      parseCards(b),
      j['texture'] as String,
      [
        RiverSide.fromJson(j['oop'] as Map<String, dynamic>),
        RiverSide.fromJson(j['ip'] as Map<String, dynamic>),
      ],
      {
        for (final e in (j['nodes'] as Map<String, dynamic>).entries)
          e.key: RiverNode.fromJson(e.key, e.value as Map<String, dynamic>)
      },
      j['stats'] as Map<String, dynamic>,
      (j['exploitabilityPctPot'] as num).toDouble(),
    );
  }

  /// Probability-weighted presence of each of the owner's combos at [n].
  List<double> reach(RiverNode n) {
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
  List<List<double>?> classStrategy(RiverNode n) {
    final side = sides[n.player];
    final r = reach(n);
    final k = n.actions.length;
    final sum = List<List<double>?>.filled(169, null);
    final wt = List<double>.filled(169, 0);
    for (var i = 0; i < side.n; i++) {
      final c = side.cls(i).index;
      final f = n.freqs(i);
      final acc = sum[c] ??= List<double>.filled(k, 0);
      final w = r[i] > 0 ? r[i] : 1e-9; // keep unreached combos visible
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

  /// Range-level action frequencies at [n] (weighted by reach).
  List<double> rangeFreqs(RiverNode n) {
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

  /// Template sentences describing the solved strategy, from numbers only.
  List<String> summary() {
    final out = <String>[];
    final ob = stats['oopBet'] as Map<String, dynamic>;
    final betPct = (ob['betPct'] as num).toDouble();
    if (betPct < 0.03) {
      out.add('BB almost never leads (${pct(betPct)}): it checks its whole '
          'range and lets BTN act.');
    } else {
      out.add(
          'BB bets ${pct(betPct)}: ${pct((ob['valuePct'] as num).toDouble())}'
          ' value, ${pct((ob['bluffPct'] as num).toDouble())} bluffs.');
      out.addAll(_blockerLine('BB', 'BTN', ob));
    }
    final ivc = stats['ipVsCheck'] as Map<String, dynamic>;
    final chk = (ivc['Check'] as num).toDouble();
    final b33 = stats['ipBet33'] as Map<String, dynamic>;
    final b75 = stats['ipBet75'] as Map<String, dynamic>;
    out.add('When checked to, BTN bets ${pct(1 - chk)} '
        '(33%: ${pct((ivc['Bet 33%'] as num).toDouble())}, '
        '75%: ${pct((ivc['Bet 75%'] as num).toDouble())}).');
    final big = (ivc['Bet 75%'] as num) >= (ivc['Bet 33%'] as num) ? b75 : b33;
    final bigName = identical(big, b75) ? '75%' : '33%';
    if ((big['betPct'] as num) > 0.03) {
      out.add(
          'BTN\'s $bigName bets are ${pct((big['valuePct'] as num).toDouble())}'
          ' value and ${pct((big['bluffPct'] as num).toDouble())} bluffs.');
      out.addAll(_blockerLine('BTN', 'BB', big));
    }
    if (betPct >= 0.03) {
      final vb = stats['ipVsBet'] as Map<String, dynamic>;
      out.add(
          'Facing BB\'s 66% bet, BTN folds ${pct((vb['Fold'] as num).toDouble())}, '
          'calls ${pct((vb['Call'] as num).toDouble())} and raises all-in '
          '${pct((vb['All-in'] as num).toDouble())}.');
    }
    final v75 = stats['oopVsBet75'] as Map<String, dynamic>;
    final def75 = 1 - (v75['Fold'] as num).toDouble();
    const mdf75 = 1 / 1.75;
    out.add('After checking, BB defends ${pct(def75)} vs a 75% bet '
        '(minimum defence to stop any-two-card bluffs: ${pct(mdf75)})'
        '${def75 < mdf75 - 0.03 ? ': it can fold more because only '
            '${pct((b75['bluffPct'] as num).toDouble())} of those bets are '
            'bluffs' : ''}.');
    final eq = (stats['oopEquity'] as num).toDouble();
    final ev = (stats['oopEvShare'] as num).toDouble();
    out.add('BB\'s range has ${pct(eq)} raw equity and realises ${pct(ev)} '
        'of the pot${ev < eq ? ' (being out of position costs it ${pct(eq - ev)})' : ''}.');
    return out;
  }

  List<String> _blockerLine(
      String hero, String villain, Map<String, dynamic> m) {
    final bb = (m['bluffBlock'] as num).toDouble();
    final gb = (m['giveUpBlock'] as num).toDouble();
    if ((m['bluffPct'] as num) < 0.05 || gb <= 0) return const [];
    if (bb > gb * 1.1) {
      return [
        '$hero\'s bluffs block ${pct(bb)} of $villain\'s calling hands on '
            'average, vs ${pct(gb)} for the weak hands that give up: bluffs '
            'are hands that block $villain\'s calls.'
      ];
    }
    if (gb > bb * 1.1) {
      return [
        '$hero\'s bluffs block only ${pct(bb)} of $villain\'s calls (weak '
            'hands that give up block ${pct(gb)}): bluffs are chosen to unblock '
            '$villain\'s folds.'
      ];
    }
    return const [];
  }
}

class RiverLibrary {
  final List<RiverBoard> boards;
  final double stack;
  final int iterations;
  final String format;
  RiverLibrary(this.boards, this.stack, this.iterations, this.format);

  static RiverLibrary parse(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    return RiverLibrary(
      [
        for (final b in j['boards'] as List)
          RiverBoard.fromJson(b as Map<String, dynamic>)
      ],
      (j['stack'] as num).toDouble(),
      (j['iterations'] as num).toInt(),
      j['format'] as String,
    );
  }

  static Future<RiverLibrary>? _cache;
  static Future<RiverLibrary> load() => _cache ??=
      rootBundle.loadString('assets/data/rivers.json').then(RiverLibrary.parse);

  double get maxExploitability =>
      boards.map((b) => b.exploitabilityPctPot).reduce(max);
}

// ---------------------------------------------------------------- drill ----

const riverDrillNodes = [
  'root',
  'ipVsCheck',
  'ipVsBet',
  'oopVsBet33',
  'oopVsBet75',
];

class RiverQuestion {
  final RiverBoard board;
  final RiverNode node;
  final int combo;
  RiverQuestion(this.board, this.node, this.combo);

  RiverSide get side => board.sides[node.player];
  String get hero => riverSeatName[node.player];
  List<double> get freqs => node.freqs(combo);
  List<int> get holeCards => [side.c1[combo], side.c2[combo]];
}

/// Random board, node and hero combo (sampled by how often the hand
/// actually reaches that node).
RiverQuestion randomRiverQuestion(RiverLibrary lib, Random rng) {
  for (;;) {
    final b = lib.boards[rng.nextInt(lib.boards.length)];
    final n = b.nodes[riverDrillNodes[rng.nextInt(riverDrillNodes.length)]]!;
    final r = b.reach(n);
    final tot = r.fold<double>(0, (a, x) => a + x);
    if (tot <= 0) continue;
    var x = rng.nextDouble() * tot;
    for (var i = 0; i < r.length; i++) {
      x -= r[i];
      if (x <= 0 && r[i] > 0) return RiverQuestion(b, n, i);
    }
  }
}

Grade gradeRiver(RiverQuestion q, int chosen) => gradeFor(q.freqs[chosen]);

String riverStrategyLine(List<String> actions, List<double> f) => [
      for (var a = 0; a < actions.length; a++)
        if (f[a] > 0.005) '${actions[a]} ${pct(f[a])}'
    ].join(' · ');

/// "a flush", "two pair", ... for coaching sentences.
String handPhrase(String category) => switch (category) {
      'High card' => 'no pair',
      'Pair' => 'a pair',
      'Two pair' => 'two pair',
      'Three of a kind' => 'three of a kind',
      'Straight' => 'a straight',
      'Flush' => 'a flush',
      'Full house' => 'a full house',
      'Four of a kind' => 'four of a kind',
      _ => 'a straight flush',
    };

/// The opponent's node and action that produced the bet the hero faces.
const _betSource = {
  'ipVsBet': ('root', 1),
  'oopVsBet33': ('ipVsCheck', 1),
  'oopVsBet75': ('ipVsCheck', 2),
  'oopVsRaise': ('ipVsBet', 2),
  'ipVsRaise33': ('oopVsBet33', 2),
  'ipVsRaise75': ('oopVsBet75', 2),
};

/// The opponent's response node after the hero's bet action.
const _betResponse = {
  ('root', 1): 'ipVsBet',
  ('ipVsCheck', 1): 'oopVsBet33',
  ('ipVsCheck', 2): 'oopVsBet75',
};

/// Showdown equity of the hero's combo vs opponent combos weighted by [w]
/// (card removal applied). Null when the weights are empty.
double? equityVsWeights(RiverQuestion q, List<double> w) {
  final opp = q.board.sides[1 - q.node.player];
  final h = q.holeCards;
  final mine = evaluate([...h, ...q.board.cards]);
  var win = 0.0, tot = 0.0;
  for (var j = 0; j < opp.n; j++) {
    if (w[j] <= 0) continue;
    if (h.contains(opp.c1[j]) || h.contains(opp.c2[j])) continue;
    final s = evaluate([opp.c1[j], opp.c2[j], ...q.board.cards]);
    tot += w[j];
    if (mine > s) {
      win += w[j];
    } else if (mine == s) {
      win += w[j] / 2;
    }
  }
  return tot > 1e-9 ? win / tot : null;
}

/// Equity vs the range that made the bet the hero is facing.
double? equityVsBettor(RiverQuestion q) {
  final src = _betSource[q.node.id];
  if (src == null) return null;
  final n = q.board.nodes[src.$1]!;
  final r = q.board.reach(n);
  return equityVsWeights(
      q, [for (var j = 0; j < r.length; j++) r[j] * n.freqs(j)[src.$2]]);
}

/// (opponent fold %, hero equity vs the continuing range) after the hero
/// bets with action [a] at the current node.
(double, double?)? afterBet(RiverQuestion q, int a) {
  final id = _betResponse[(q.node.id, a)];
  if (id == null) return null;
  final n = q.board.nodes[id]!;
  final r = q.board.reach(n);
  final fold = n.actions.indexOf('Fold');
  final cont = [
    for (var j = 0; j < r.length; j++) r[j] * (1 - n.freqs(j)[fold])
  ];
  return (q.board.rangeFreqs(n)[fold], equityVsWeights(q, cont));
}

/// Templated coaching for a drill answer (numbers from the solution only).
List<String> riverCoach(RiverQuestion q, int chosen, double stack) {
  final notes = <String>[];
  final f = q.freqs;
  var best = 0;
  for (var a = 1; a < f.length; a++) {
    if (f[a] > f[best]) best = a;
  }
  if (chosen != best && f[chosen] < 0.25) {
    notes.add('GTO prefers ${q.node.actions[best]} (${pct(f[best])}).');
  }
  final villain = riverSeatName[1 - q.node.player];
  final eq = q.side.eq[q.combo];
  notes.add('You have ${handPhrase(q.board.handName(q.node.player, q.combo))}'
      ', which beats about ${pct(eq)} of $villain\'s whole river range.');

  // Where the hand sits in the hero's own range at this node.
  final r = q.board.reach(q.node);
  var weaker = 0.0, tot = 0.0;
  for (var i = 0; i < r.length; i++) {
    tot += r[i];
    if (q.side.eq[i] < eq) weaker += r[i];
  }
  if (tot > 0) {
    notes.add('It is stronger than ${pct(weaker / tot)} of the hands you '
        'reach this spot with.');
  }

  final rf = q.board.rangeFreqs(q.node);
  final need = potOddsNeeded(q.node.id, stack);
  if (need > 0) {
    final b = facingBet(q.node.id, stack)!;
    final foldIdx = q.node.actions.indexOf('Fold');
    final ev = equityVsBettor(q);
    final sizeName = b >= stack ? 'an all-in' : 'a ${(b * 100).round()}% bet';
    if (ev != null) {
      notes.add('Against the hands $villain bets like this you win '
          '${pct(ev)} of showdowns; calling $sizeName needs ${pct(need)}.');
    }
    notes.add('${q.hero} defends ${pct(1 - rf[foldIdx])} of its range here '
        '(folds ${pct(rf[foldIdx])}).');
    if (f[foldIdx] > 0.9 && ev != null && ev < need) {
      notes.add('You are below the price, so this hand folds.');
    } else if (f[foldIdx] < 0.05 && ev != null && ev > 0.7) {
      notes.add('You are well ahead of the betting range: folding would '
          'hand $villain the pot.');
    } else if (f[foldIdx] > 0.05 && f[foldIdx] < 0.95) {
      notes.add('A bluff-catcher at the edge of the defending range: calling '
          'and folding are worth about the same, so the solver mixes.');
    }
    final raise = q.node.actions.indexOf('All-in');
    if (raise >= 0 && f[raise] > 0.3) {
      notes.add('Raises all-in ${pct(f[raise])} of the time: '
          '${ev != null && ev > 0.6 ? 'for value, worse hands still call' : 'as a bluff that folds out better hands'}.');
    }
    return notes;
  }

  // The hero may bet: show what the most-used bet size achieves.
  var bi = 1;
  for (var a = 2; a < q.node.actions.length; a++) {
    if (f[a] > f[bi] || (f[a] == f[bi] && rf[a] > rf[bi])) bi = a;
  }
  final betF = 1 - f[0];
  notes.add('${q.hero} bets ${pct(1 - rf[0])} of its range here.');
  final ab = afterBet(q, bi);
  if (ab != null) {
    final (fold, e) = ab;
    notes.add('If you ${q.node.actions[bi].toLowerCase()}, $villain folds '
        '${pct(fold)}${e == null ? '' : ' and you win ${pct(e)} of '
            'showdowns against the hands that continue'}.');
    if (betF > 0.5 && e != null && e >= 0.5) {
      notes.add('Value bet: you are ahead of the hands that call.');
    } else if (betF > 0.3 && e != null && e < 0.5) {
      notes.add('Bluff: you rarely win when called, but the bet makes '
          'better hands fold often enough.');
    } else if (betF < 0.2 && eq >= 0.65 && q.node.id == 'root') {
      final ipBets = 1 - q.board.rangeFreqs(q.board.nodes['ipVsCheck']!)[0];
      notes.add('Strong but checks: BTN bets ${pct(ipBets)} when checked to, '
          'so the hand still wins chips by calling or check-raising, and it '
          'keeps BB\'s checking range from being all weak hands.');
    } else if (betF < 0.2 && e != null && e < 0.5 && eq >= 0.35) {
      notes.add('Check: betting is called mostly by better hands, while '
          'checking still wins ${pct(eq)} at showdown.');
    } else if (betF < 0.2 && eq < 0.35) {
      notes.add('Gives up: other weak hands make better bluffs.');
    }
  }
  return notes;
}
