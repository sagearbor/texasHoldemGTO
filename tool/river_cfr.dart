// Heads-up river CFR+ core used by tool/solve_river.dart (and by the solver
// benchmark test, which solves a toy game with a known analytic answer).
//
// Pot is normalised to 1 at the start of the river, each player has 0.5 of
// it invested, effective stack behind = [TreeSpec.stack] pots. OOP acts
// first. The tree is built from bet-size lists:
//
//   root (OOP):          Check | Bet x% for x in leads
//     ipVsBet{x} (IP):   Fold | Call | All-in        (All-in only if raises)
//       oopVsRaise{x}:   Fold | Call
//   ipVsCheck (IP):      Check | Bet x% for x in ipBets
//     oopVsBet{x} (OOP): Fold | Call | All-in        (the check-raise)
//       ipVsRaise{x}:    Fold | Call
//
// Regret-matching+, alternating updates, linear strategy averaging,
// vectorised over hole-card combos with exact card removal; showdowns use a
// sorted-strength sweep (O(n) per terminal after one sort per board).
// Exploitability = (BR value of OOP + BR value of IP) / 2 per
// non-conflicting hand pair, in pots.
import 'dart:typed_data';

const oop = 0, ip = 1;

class TreeSpec {
  final double stack;
  final List<double> leads;
  final List<double> ipBets;

  /// Whether the player facing a bet may raise all-in.
  final bool raises;
  const TreeSpec(
      {required this.stack,
      required this.leads,
      required this.ipBets,
      this.raises = true});
}

String sizeKey(double s) => '${(s * 100).round()}';

class Node {
  final String? id; // decision nodes have an id
  final int kind; // 0 decision, 1 fold, 2 showdown
  final int player; // decision: who acts; fold: who folded
  final List<String> actions;
  final List<Node> children;
  final double invO, invI; // river money put in so far (pots)
  late List<Float64List> regret, stratSum;

  /// Fixed strategy (e.g. the quantised one) used by evaluation if set.
  List<Float64List>? fixed;
  Node.decision(this.id, this.player, this.actions, this.children,
      {this.invO = 0, this.invI = 0})
      : kind = 0;
  Node.fold(this.player, this.invO, this.invI)
      : id = null,
        kind = 1,
        actions = const [],
        children = const [];
  Node.showdown(double inv)
      : id = null,
        kind = 2,
        player = -1,
        actions = const [],
        children = const [],
        invO = inv,
        invI = inv;

  /// Bet the player to act must match (pots), and what it already put in.
  double get facing => player == oop ? invI : invO;
  double get heroIn => player == oop ? invO : invI;
}

Node buildTree(TreeSpec t) {
  final stack = t.stack;
  Node vsBet(int p, String id, String raiseId, double size) {
    final o = p == oop;
    return Node.decision(
      id,
      p,
      ['Fold', 'Call', if (t.raises) 'All-in'],
      [
        Node.fold(p, o ? 0 : size, o ? size : 0),
        Node.showdown(size),
        if (t.raises)
          Node.decision(raiseId, 1 - p, ['Fold', 'Call'], [
            Node.fold(1 - p, o ? stack : size, o ? size : stack),
            Node.showdown(stack),
          ],
              invO: o ? stack : size, invI: o ? size : stack),
      ],
      invO: o ? 0 : size,
      invI: o ? size : 0,
    );
  }

  String bet(double s) => 'Bet ${sizeKey(s)}%';
  return Node.decision('root', oop, [
    'Check',
    for (final s in t.leads) bet(s)
  ], [
    Node.decision('ipVsCheck', ip, [
      'Check',
      for (final s in t.ipBets) bet(s)
    ], [
      Node.showdown(0),
      for (final s in t.ipBets)
        vsBet(oop, 'oopVsBet${sizeKey(s)}', 'ipVsRaise${sizeKey(s)}', s),
    ]),
    for (final s in t.leads)
      vsBet(ip, 'ipVsBet${sizeKey(s)}', 'oopVsRaise${sizeKey(s)}', s),
  ]);
}

void visit(Node n, void Function(Node) f) {
  f(n);
  for (final c in n.children) {
    visit(c, f);
  }
}

/// Decision nodes in pre-order (every node after the nodes on its path).
List<Node> decisionNodes(Node root) {
  final out = <Node>[];
  visit(root, (n) {
    if (n.kind == 0) out.add(n);
  });
  return out;
}

/// Owner's action path from the root to each decision node (for reach).
Map<String, List<List<Object>>> ownerPaths(Node root) {
  final out = <String, List<List<Object>>>{};
  void go(Node n, List<List<Object>> path) {
    if (n.kind != 0) return;
    out[n.id!] = [
      for (final p in path)
        if (p[2] == n.player) [p[0], p[1]]
    ];
    for (var a = 0; a < n.children.length; a++) {
      go(n.children[a], [
        ...path,
        [n.id!, a, n.player]
      ]);
    }
  }

  go(root, []);
  return out;
}

/// For each decision node reached by a bet: (bettor node id, action index);
/// and for each (node, bet action): the response node id.
(Map<String, List<Object>>, Map<String, Map<int, String>>) betLinks(Node root) {
  final src = <String, List<Object>>{};
  final resp = <String, Map<int, String>>{};
  visit(root, (n) {
    if (n.kind != 0) return;
    for (var a = 0; a < n.children.length; a++) {
      final c = n.children[a];
      if (c.kind != 0 || c.player == n.player) continue;
      final act = n.actions[a];
      if (act == 'Check') continue;
      src[c.id!] = [n.id!, a];
      (resp[n.id!] ??= {})[a] = c.id!;
    }
  });
  return (src, resp);
}

// --------------------------------------------------------------- game -----

class Side {
  final List<int> c1 = [], c2 = [], cls = [];
  final List<double> w = [];
  late Int32List str, order; // strength; indices sorted by strength asc
  late Int32List same; // index of identical combo in the other side, or -1
  int get n => c1.length;

  void finish(List<int> strengths) {
    str = Int32List.fromList(strengths);
    final idx = List<int>.generate(n, (i) => i)
      ..sort((a, c) => str[a].compareTo(str[c]));
    order = Int32List.fromList(idx);
  }
}

void linkSides(Side a, Side b) {
  int key(int x, int y) => x < y ? x * 52 + y : y * 52 + x;
  final mb = <int, int>{for (var i = 0; i < b.n; i++) key(b.c1[i], b.c2[i]): i};
  final ma = <int, int>{for (var i = 0; i < a.n; i++) key(a.c1[i], a.c2[i]): i};
  a.same = Int32List.fromList(
      [for (var i = 0; i < a.n; i++) mb[key(a.c1[i], a.c2[i])] ?? -1]);
  b.same = Int32List.fromList(
      [for (var i = 0; i < b.n; i++) ma[key(b.c1[i], b.c2[i])] ?? -1]);
}

class Game {
  final List<Side> sides;
  final Node root;
  Game(this.sides, this.root);

  final _cs = Float64List(52);

  /// Sum of non-conflicting opponent reach for each of [p]'s combos.
  Float64List oppMass(int p, Float64List oppR) {
    final me = sides[p], op = sides[1 - p];
    _cs.fillRange(0, 52, 0);
    var tot = 0.0;
    for (var j = 0; j < op.n; j++) {
      final r = oppR[j];
      tot += r;
      _cs[op.c1[j]] += r;
      _cs[op.c2[j]] += r;
    }
    final out = Float64List(me.n);
    for (var i = 0; i < me.n; i++) {
      final s = me.same[i];
      out[i] = tot - _cs[me.c1[i]] - _cs[me.c2[i]] + (s >= 0 ? oppR[s] : 0);
    }
    return out;
  }

  /// For each of [p]'s combos: (weaker, stronger) opponent reach mass.
  (Float64List, Float64List) beatMass(int p, Float64List oppR) {
    final me = sides[p], op = sides[1 - p];
    final below = Float64List(me.n), above = Float64List(me.n);
    _cs.fillRange(0, 52, 0);
    var tot = 0.0, j = 0;
    for (var k = 0; k < me.n; k++) {
      final i = me.order[k];
      final s = me.str[i];
      while (j < op.n && op.str[op.order[j]] < s) {
        final o = op.order[j];
        final r = oppR[o];
        tot += r;
        _cs[op.c1[o]] += r;
        _cs[op.c2[o]] += r;
        j++;
      }
      below[i] = tot - _cs[me.c1[i]] - _cs[me.c2[i]];
    }
    _cs.fillRange(0, 52, 0);
    tot = 0;
    j = op.n - 1;
    for (var k = me.n - 1; k >= 0; k--) {
      final i = me.order[k];
      final s = me.str[i];
      while (j >= 0 && op.str[op.order[j]] > s) {
        final o = op.order[j];
        final r = oppR[o];
        tot += r;
        _cs[op.c1[o]] += r;
        _cs[op.c2[o]] += r;
        j--;
      }
      above[i] = tot - _cs[me.c1[i]] - _cs[me.c2[i]];
    }
    return (below, above);
  }

  Float64List terminal(Node n, int p, Float64List oppR) {
    if (n.kind == 1) {
      final lost = 0.5 + (n.player == oop ? n.invO : n.invI);
      final u = n.player == p ? -lost : lost;
      final m = oppMass(p, oppR);
      for (var i = 0; i < m.length; i++) {
        m[i] *= u;
      }
      return m;
    }
    final stake = 0.5 + n.invO;
    final (lo, hi) = beatMass(p, oppR);
    for (var i = 0; i < lo.length; i++) {
      lo[i] = stake * (lo[i] - hi[i]);
    }
    return lo;
  }

  void init() {
    visit(root, (n) {
      if (n.kind != 0) return;
      final m = sides[n.player].n;
      n.regret = [for (final _ in n.actions) Float64List(m)];
      n.stratSum = [for (final _ in n.actions) Float64List(m)];
    });
  }

  List<Float64List> current(Node n) {
    final k = n.actions.length, m = sides[n.player].n;
    final out = [for (var a = 0; a < k; a++) Float64List(m)];
    for (var i = 0; i < m; i++) {
      var s = 0.0;
      for (var a = 0; a < k; a++) {
        s += n.regret[a][i];
      }
      for (var a = 0; a < k; a++) {
        out[a][i] = s > 0 ? n.regret[a][i] / s : 1 / k;
      }
    }
    return out;
  }

  List<Float64List> average(Node n) {
    final fx = n.fixed;
    if (fx != null) return fx;
    final k = n.actions.length, m = sides[n.player].n;
    final cur = current(n);
    final out = [for (var a = 0; a < k; a++) Float64List(m)];
    for (var i = 0; i < m; i++) {
      var s = 0.0;
      for (var a = 0; a < k; a++) {
        s += n.stratSum[a][i];
      }
      for (var a = 0; a < k; a++) {
        out[a][i] = s > 1e-12 ? n.stratSum[a][i] / s : cur[a][i];
      }
    }
    return out;
  }

  Float64List cfr(
      Node n, int p, Float64List selfR, Float64List oppR, double t) {
    if (n.kind != 0) return terminal(n, p, oppR);
    final sigma = current(n);
    final k = n.actions.length;
    if (n.player == p) {
      final m = selfR.length;
      final v = Float64List(m);
      final vs = <Float64List>[];
      for (var a = 0; a < k; a++) {
        final r = Float64List(m);
        for (var i = 0; i < m; i++) {
          r[i] = selfR[i] * sigma[a][i];
        }
        final va = cfr(n.children[a], p, r, oppR, t);
        vs.add(va);
        for (var i = 0; i < m; i++) {
          v[i] += sigma[a][i] * va[i];
        }
      }
      for (var a = 0; a < k; a++) {
        final reg = n.regret[a], ss = n.stratSum[a], va = vs[a], sg = sigma[a];
        for (var i = 0; i < m; i++) {
          final x = reg[i] + va[i] - v[i];
          reg[i] = x > 0 ? x : 0;
          ss[i] += t * selfR[i] * sg[i];
        }
      }
      return v;
    }
    Float64List? v;
    for (var a = 0; a < k; a++) {
      final r = Float64List(oppR.length);
      for (var j = 0; j < r.length; j++) {
        r[j] = oppR[j] * sigma[a][j];
      }
      final va = cfr(n.children[a], p, selfR, r, t);
      if (v == null) {
        v = va;
      } else {
        for (var i = 0; i < v.length; i++) {
          v[i] += va[i];
        }
      }
    }
    return v!;
  }

  /// Counterfactual values for [p] when both play the average strategy
  /// ([br] = false) or [p] best-responds to the opponent's average ([br]).
  Float64List evalAvg(Node n, int p, Float64List oppR, bool br) {
    if (n.kind != 0) return terminal(n, p, oppR);
    final sigma = average(n);
    final k = n.actions.length;
    if (n.player == p) {
      final m = sides[p].n;
      final v = Float64List(m);
      if (br) v.fillRange(0, m, double.negativeInfinity);
      for (var a = 0; a < k; a++) {
        final va = evalAvg(n.children[a], p, oppR, br);
        for (var i = 0; i < m; i++) {
          if (br) {
            if (va[i] > v[i]) v[i] = va[i];
          } else {
            v[i] += sigma[a][i] * va[i];
          }
        }
      }
      return v;
    }
    Float64List? v;
    for (var a = 0; a < k; a++) {
      final r = Float64List(oppR.length);
      for (var j = 0; j < r.length; j++) {
        r[j] = oppR[j] * sigma[a][j];
      }
      final va = evalAvg(n.children[a], p, r, br);
      if (v == null) {
        v = va;
      } else {
        for (var i = 0; i < v.length; i++) {
          v[i] += va[i];
        }
      }
    }
    return v!;
  }

  Float64List get wO => Float64List.fromList(sides[oop].w);
  Float64List get wI => Float64List.fromList(sides[ip].w);

  double get pairs => dot(oppMass(oop, wI), sides[oop].w);

  /// Exploitability of the current average (or fixed) profile, in pots.
  double exploitability() {
    final bo = dot(evalAvg(root, oop, wI, true), sides[oop].w);
    final bi = dot(evalAvg(root, ip, wO, true), sides[ip].w);
    return (bo + bi) / 2 / pairs;
  }

  /// OOP's expected value (pots, relative to its 0.5 stake) under the
  /// average profile.
  double oopValue() => dot(evalAvg(root, oop, wI, false), sides[oop].w) / pairs;

  /// Runs CFR+ until exploitability (in % of the pot) is at most [target]
  /// (checked every [checkEvery] iterations after [minIters]) or [maxIters].
  /// Returns (iterations, trace of [iteration, exploitability %]).
  (int, List<List<num>>) solve(
      {required int maxIters,
      int minIters = 500,
      int checkEvery = 250,
      double target = 0}) {
    final wo = wO, wi = wI;
    final trace = <List<num>>[];
    var t = 0;
    while (t < maxIters) {
      t++;
      cfr(root, oop, wo, wi, t.toDouble());
      cfr(root, ip, wi, wo, t.toDouble());
      if (t >= minIters && (t - minIters) % checkEvery == 0) {
        final e = exploitability() * 100;
        trace.add([t, (e * 10000).round() / 10000]);
        if (e <= target) break;
      }
    }
    return (t, trace);
  }
}

double dot(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

/// Largest-remainder rounding of a probability vector to integer percents.
List<int> pctRound(List<double> f) {
  final raw = [for (final x in f) x * 100];
  final out = [for (final x in raw) x.floor()];
  var left = 100 - out.fold<int>(0, (a, b) => a + b);
  final order = List<int>.generate(f.length, (i) => i)
    ..sort((a, b) => (raw[b] - out[b]).compareTo(raw[a] - out[a]));
  for (var k = 0; left > 0; k = (k + 1) % f.length, left--) {
    out[order[k]]++;
  }
  return out;
}
