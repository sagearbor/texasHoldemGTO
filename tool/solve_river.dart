// Heads-up RIVER solver: BB (out of position) vs BTN (in position) in a
// single-raised pot, solved with CFR+ (regret-matching+, alternating
// updates, linear strategy averaging), vectorised over hole-card combos.
//
// Game (pot normalised to 1 at the start of the river, each player has
// 0.5 of it invested; effective stack behind = [stack] pots, default 3):
//
//   OOP: Check | Bet 66%
//     vs Bet 66%:  IP Fold | Call | All-in
//        vs All-in: OOP Fold | Call
//     vs Check:    IP Check (showdown) | Bet 33% | Bet 75%
//        vs bet:   OOP Fold | Call | All-in
//          vs All-in: IP Fold | Call
//
// SIMPLIFIED RANGES: the ranges are the full preflop ranges (BTN open from
// the 6-max chart; BB's flat-call part of the BB-vs-BTN defence), weighted by
// their preflop frequency, with only the combos blocked by the river board
// removed. Real river ranges are narrowed by flop/turn play, so absolute
// frequencies here are illustrative; the structure (value vs bluff, blockers,
// polarisation) is what the feature teaches.
//
// Showdowns use the exact combo-vs-combo payoff with card removal via the
// sorted-strength sweep (O(n) per showdown after one sort per board).
// Exploitability = (BR value of OOP + BR value of IP) / 2, averaged over all
// non-conflicting hand pairs, reported in % of the river pot.
//
// Output: assets/data/rivers.json (per-combo strategies, quantised to 1%).
//
// Run: dart compile exe tool/solve_river.dart -o /tmp/solve_river
//      /tmp/solve_river [iterations=3000] [maxBoards]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/range_parser.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/poker/evaluator.dart';

// Copied from lib/gto/spots.dart (that file imports Flutter, so a pure Dart
// tool cannot import it). Keep in sync if the charts change.
const _btnOpen = '22+, A2s+, K2s+, Q4s+, Q3s:0.5, J6s+, J5s:0.5, T6s+, 96s+, '
    '85s+, 74s+, 64s+, 53s+, 43s:0.6, A2o+, K8o+, K7o:0.5, Q9o+, Q8o:0.4, '
    'J9o+, J8o:0.3, T9o, T8o:0.4, 98o:0.5, 87o:0.25';
const _bb3bet = 'QQ+, JJ:0.6, TT:0.3, AKs, AQs:0.6, A5s-A2s:0.5, KQs:0.4, '
    'K9s-K6s:0.25, Q9s:0.3, J9s:0.3, T8s:0.3, 97s:0.3, 86s:0.3, 75s:0.3, '
    '64s:0.3, 54s:0.3, AKo, AQo:0.4, A5o:0.3, KJo:0.3';
const _bbDefend = '22+, A2s+, K2s+, Q2s+, J4s+, T5s+, 95s+, 85s+, 74s+, '
    '63s+, 53s+, 42s+, A2o+, K5o+, K4o:0.5, Q7o+, Q6o:0.4, J7o+, T7o+, 97o+, '
    '87o, 76o:0.6, 65o:0.4';

/// Representative river boards, grouped by texture.
const boardsByTexture = {
  'Dry high': [
    'AsKd7c4h2s',
    'KhQd6c3s2h',
    'AdJc8s5h2d',
    'KcTd7h3s2c',
    'QsKd8h4d2c',
    'AhTc7d4s2h',
    'KdJs7c4h2d',
    'AcQd9h5s3c',
  ],
  'Paired': [
    'KsKd7c4h2s',
    '8h8d3cAsJd',
    'QcQh6d4s9c',
    '5s5dKh9c2d',
    'AhAd9c6s3h',
    'TdTc4h2sKc',
    '7c7hJd3s2d',
    'JsJcAd8h4s',
  ],
  'Flush complete': [
    'AsJs7s4d2h',
    'Kh9h5h3c2d',
    'QdTd4d8c2s',
    '9c6c3cKdAh',
    'Js8s3sTh2s',
    'AhKh6h2h9c',
    'Td7d2dKs5h',
    '8s5s2sQhJd',
  ],
  'Straight complete': [
    '9h8d7c6s2h',
    'JsTd9c8h3s',
    'KdQsJhTc5d',
    '6c5d4h3sKh',
    '7s6d5h4cAd',
    'AdKcQhJs4d',
    'Tc9h8d6s2c',
    '5h4d3c2sKs',
  ],
  'Low connected': [
    '7h6d4c2sKh',
    '6h5d3c2sTh',
    '8c7d5h2sQd',
    '9d7c6h3s2d',
    '5c4h3d9sJc',
    '8h6d5c2sKs',
    '7d5s4c2hJh',
    '9s8c6d3h2c',
  ],
};

const stack = 3.0; // pots behind at the start of the river

// ---------------------------------------------------------------- tree ----

const oop = 0, ip = 1;

class Node {
  final String? id; // stored decision nodes have an id
  final int kind; // 0 decision, 1 fold, 2 showdown
  final int player; // decision: who acts; fold: who folded
  final List<String> actions;
  final List<Node> children;
  final double invO, invI; // river money put in so far
  late List<Float64List> regret, stratSum;
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
}

Node buildTree() {
  const b = 0.66;
  Node vsIpBet(String id, String raiseId, double size) => Node.decision(
        id,
        oop,
        ['Fold', 'Call', 'All-in'],
        [
          Node.fold(oop, 0, size),
          Node.showdown(size),
          Node.decision(raiseId, ip, ['Fold', 'Call'],
              [Node.fold(ip, stack, size), Node.showdown(stack)]),
        ],
      );
  return Node.decision('root', oop, [
    'Check',
    'Bet 66%'
  ], [
    Node.decision('ipVsCheck', ip, [
      'Check',
      'Bet 33%',
      'Bet 75%'
    ], [
      Node.showdown(0),
      vsIpBet('oopVsBet33', 'ipVsRaise33', 0.33),
      vsIpBet('oopVsBet75', 'ipVsRaise75', 0.75),
    ]),
    Node.decision('ipVsBet', ip, [
      'Fold',
      'Call',
      'All-in'
    ], [
      Node.fold(ip, b, 0),
      Node.showdown(b),
      Node.decision('oopVsRaise', oop, ['Fold', 'Call'],
          [Node.fold(oop, b, stack), Node.showdown(stack)]),
    ]),
  ]);
}

void visit(Node n, void Function(Node) f) {
  f(n);
  for (final c in n.children) {
    visit(c, f);
  }
}

/// Owner's action path from the root to each stored node (for reach).
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

// --------------------------------------------------------------- game -----

class Side {
  final List<int> c1 = [], c2 = [], cls = [];
  final List<double> w = [];
  late Int32List str, order; // strength; indices sorted by strength asc
  late Int32List same; // index of identical combo in the other side, or -1
  int get n => c1.length;
}

Side buildSide(RangeMap range, Set<int> board) {
  final s = Side();
  for (final e in range.entries) {
    if (e.value <= 0) continue;
    final h = HandClass.byIndex(e.key);
    for (final c in h.combos()) {
      if (board.contains(c[0]) || board.contains(c[1])) continue;
      s.c1.add(c[0]);
      s.c2.add(c[1]);
      s.cls.add(e.key);
      s.w.add(e.value);
    }
  }
  final b = board.toList();
  s.str = Int32List.fromList([
    for (var i = 0; i < s.n; i++) evaluate([s.c1[i], s.c2[i], ...b])
  ]);
  final idx = List<int>.generate(s.n, (i) => i)
    ..sort((a, c) => s.str[a].compareTo(s.str[c]));
  s.order = Int32List.fromList(idx);
  return s;
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

double r3(double v) => (v * 1000).round() / 1000;

Map<String, dynamic> solveBoard(
    String boardStr, String texture, RangeMap oopR, RangeMap ipR, int iters) {
  final board = parseCards(boardStr);
  final bset = board.toSet();
  final so = buildSide(oopR, bset), si = buildSide(ipR, bset);
  linkSides(so, si);
  final root = buildTree();
  final g = Game([so, si], root)..init();
  final wO = Float64List.fromList(so.w), wI = Float64List.fromList(si.w);

  final pairs = dot(g.oppMass(oop, wI), so.w);
  double expl() {
    final bo = dot(g.evalAvg(root, oop, wI, true), so.w);
    final bi = dot(g.evalAvg(root, ip, wO, true), si.w);
    return (bo + bi) / 2 / pairs;
  }

  final explTrace = <List<num>>[];
  for (var t = 1; t <= iters; t++) {
    g.cfr(root, oop, wO, wI, t.toDouble());
    g.cfr(root, ip, wI, wO, t.toDouble());
    if (t == 100 || t == 500 || t % 1000 == 0 || t == iters) {
      explTrace.add([t, r3(expl() * 100)]);
    }
  }
  final exploit = expl();
  final evO = dot(g.evalAvg(root, oop, wI, false), so.w) / pairs;

  // Average strategies of every stored node.
  final nodes = <String, Node>{};
  visit(root, (n) {
    if (n.kind == 0) nodes[n.id!] = n;
  });
  final avg = {for (final e in nodes.entries) e.key: g.average(e.value)};

  // Raw equity of each combo vs the opponent's whole range.
  List<int> rawEq(int p, Float64List oppR) {
    final (lo, hi) = g.beatMass(p, oppR);
    final m = g.oppMass(p, oppR);
    return [
      for (var i = 0; i < lo.length; i++)
        m[i] > 0
            ? ((lo[i] + 0.5 * (m[i] - lo[i] - hi[i])) / m[i] * 100).round()
            : 0
    ];
  }

  // ---- range-level summary (all numbers from the solution) ----
  Float64List mul(List<double> a, List<double> b) =>
      Float64List.fromList([for (var i = 0; i < a.length; i++) a[i] * b[i]]);
  Float64List add(List<double> a, List<double> b) =>
      Float64List.fromList([for (var i = 0; i < a.length; i++) a[i] + b[i]]);
  double sum(List<double> a) => a.fold(0.0, (x, y) => x + y);

  /// Equity vs [oppR] per combo (0..1).
  Float64List eqVs(int p, Float64List oppR) {
    final (lo, hi) = g.beatMass(p, oppR);
    final m = g.oppMass(p, oppR);
    return Float64List.fromList([
      for (var i = 0; i < lo.length; i++)
        m[i] > 0 ? (lo[i] + 0.5 * (m[i] - lo[i] - hi[i])) / m[i] : 0
    ]);
  }

  /// Share of [oppR] mass each combo removes by blocking.
  Float64List blockShare(int p, Float64List oppR) {
    final m = g.oppMass(p, oppR);
    final tot = sum(oppR);
    return Float64List.fromList([for (final x in m) tot > 0 ? 1 - x / tot : 0]);
  }

  /// Bet stats for player [p] betting with [bet] (per-combo reach into the
  /// bet), versus the opponent's continuing range [cont].
  Map<String, num> betStats(int p, Float64List reach, Float64List bet,
      Float64List notBet, Float64List cont) {
    final eq = eqVs(p, cont);
    final blk = blockShare(p, cont);
    var betW = 0.0, valW = 0.0, bluffBlk = 0.0, bluffW = 0.0;
    var giveBlk = 0.0, giveW = 0.0;
    for (var i = 0; i < reach.length; i++) {
      final b = reach[i] * bet[i];
      betW += b;
      if (eq[i] >= 0.5) {
        valW += b;
      } else {
        bluffW += b;
        bluffBlk += b * blk[i];
        final nb = reach[i] * notBet[i];
        giveW += nb;
        giveBlk += nb * blk[i];
      }
    }
    return {
      'betPct': r3(betW / sum(reach)),
      'valuePct': betW > 0 ? r3(valW / betW) : 0,
      'bluffPct': betW > 0 ? r3(bluffW / betW) : 0,
      // Avg share of the opponent's continuing range blocked by bluffs vs
      // by weak hands that gave up.
      'bluffBlock': bluffW > 0 ? r3(bluffBlk / bluffW) : 0,
      'giveUpBlock': giveW > 0 ? r3(giveBlk / giveW) : 0,
    };
  }

  final root0 = avg['root']!;
  final ipBet = avg['ipVsBet']!;
  final ipChk = avg['ipVsCheck']!;
  final o33 = avg['oopVsBet33']!, o75 = avg['oopVsBet75']!;
  final oopStats = betStats(
      oop, wO, root0[1], root0[0], add(mul(wI, ipBet[1]), mul(wI, ipBet[2])));
  final oopCheckR = mul(wO, root0[0]);
  final ip33 = betStats(ip, wI, ipChk[1], ipChk[0],
      add(mul(oopCheckR, o33[1]), mul(oopCheckR, o33[2])));
  final ip75 = betStats(ip, wI, ipChk[2], ipChk[0],
      add(mul(oopCheckR, o75[1]), mul(oopCheckR, o75[2])));
  Map<String, num> freqs(
      Float64List reach, List<Float64List> s, List<String> acts) {
    final tot = sum(reach);
    return {
      for (var a = 0; a < acts.length; a++) acts[a]: r3(dot(reach, s[a]) / tot)
    };
  }

  final betR = mul(wO, root0[1]);
  final stats = {
    'oopBet': oopStats,
    'ipVsCheck': freqs(wI, ipChk, nodes['ipVsCheck']!.actions),
    'ipBet33': ip33,
    'ipBet75': ip75,
    'ipVsBet': freqs(wI, ipBet, nodes['ipVsBet']!.actions),
    'oopVsBet33': freqs(oopCheckR, o33, nodes['oopVsBet33']!.actions),
    'oopVsBet75': freqs(oopCheckR, o75, nodes['oopVsBet75']!.actions),
    'oopVsRaise': freqs(betR, avg['oopVsRaise']!, nodes['oopVsRaise']!.actions),
    'oopEquity': r3(dot(eqVs(oop, wI), so.w) / sum(so.w)),
    'oopEvShare': r3(0.5 + evO),
  };

  String combos(Side s) => [
        for (var i = 0; i < s.n; i++)
          cardToString(s.c1[i]) + cardToString(s.c2[i])
      ].join();

  final paths = ownerPaths(root);
  return {
    'board': boardStr,
    'texture': texture,
    'oop': {
      'combos': combos(so),
      'w': [for (final x in so.w) (x * 100).round()],
      'eq': rawEq(oop, wI),
    },
    'ip': {
      'combos': combos(si),
      'w': [for (final x in si.w) (x * 100).round()],
      'eq': rawEq(ip, wO),
    },
    'nodes': {
      for (final e in nodes.entries)
        e.key: {
          'player': e.value.player == oop ? 'oop' : 'ip',
          'actions': e.value.actions,
          'reach': paths[e.key],
          // Per combo, the first k-1 action percentages (last = remainder).
          's': [
            for (var i = 0; i < g.sides[e.value.player].n; i++)
              ...pctRound([for (final a in avg[e.key]!) a[i]])
                  .sublist(0, e.value.actions.length - 1)
          ],
        }
    },
    'stats': stats,
    'exploitabilityPctPot': r3(exploit * 100),
    'explTrace': explTrace,
  };
}

void main(List<String> args) {
  final iters = args.isNotEmpty ? int.parse(args[0]) : 3000;
  final maxBoards = args.length > 1 ? int.parse(args[1]) : 1000;
  final ipR = parseRange(_btnOpen);
  final three = parseRange(_bb3bet), def = parseRange(_bbDefend);
  final oopR = <int, double>{};
  def.forEach((k, v) {
    final c = v - (three[k] ?? 0);
    if (c > 0.001) oopR[k] = c;
  });

  final sw = Stopwatch()..start();
  final out = <Map<String, dynamic>>[];
  var count = 0;
  for (final e in boardsByTexture.entries) {
    for (final b in e.value) {
      if (count++ >= maxBoards) break;
      final cards = parseCards(b);
      if (cards.toSet().length != 5) throw StateError('bad board $b');
      final t0 = sw.elapsedMilliseconds;
      final r = solveBoard(b, e.key, oopR, ipR, iters);
      final st = r['stats'] as Map;
      stderr.writeln('$b (${e.key}): expl ${r['exploitabilityPctPot']}% pot, '
          'BB bets ${st['oopBet']['betPct']}, EV share ${st['oopEvShare']} '
          '[${(sw.elapsedMilliseconds - t0) / 1000}s] trace ${r['explTrace']}');
      out.add(r);
    }
  }
  final expl = [for (final r in out) r['exploitabilityPctPot'] as num];
  final f = File('assets/data/rivers.json');
  f.writeAsStringSync(jsonEncode({
    'format': 'HU river, BB (OOP) vs BTN (IP), single-raised pot. Pot = 1, '
        'stack behind = $stack pots. Simplified ranges: full preflop ranges '
        '(BTN open, BB flat call vs BTN) minus board blockers.',
    'solver': 'CFR+ (regret-matching+, alternating updates, linear averaging), '
        '$iters iterations, exact card removal',
    'stack': stack,
    'iterations': iters,
    'solveSeconds': sw.elapsed.inSeconds,
    'maxExploitabilityPctPot': expl.reduce((a, b) => a > b ? a : b),
    'boards': out,
  }));
  stderr.writeln('wrote ${f.path} (${f.lengthSync()} bytes) '
      '${out.length} boards in ${sw.elapsed.inSeconds}s');
}
