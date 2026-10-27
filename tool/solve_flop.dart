// SIMPLIFIED heads-up FLOP c-bet solver: BTN (preflop raiser, in position)
// vs BB (caller, out of position), single-raised pot, ONE street only.
//
// Game (pot normalised to 1 at the start of the flop, each player has 0.5
// of it invested; stacks are deep enough that nobody is all-in):
//
//   BB checks (assumed: BB checks its whole range to the raiser).
//   BTN: Check | Bet 33% | Bet 75%
//     vs bet b:  BB Fold | Call | Raise 3x (to 3b)
//       vs raise: BTN Fold | Call
//
// Terminal values:
//   * fold: the bettor wins the pot.
//   * check-check, call, raise-call: the hand is NOT played out street by
//     street. Instead each player receives a share of the final pot from its
//     exact flop equity (all 990 turn+river runouts, combo vs combo, exact
//     card removal), adjusted by an EQUITY REALISATION factor:
//        BB (out of position) realises 90% of its equity,
//        BTN (in position) realises the rest (its equity + 10% of BB's).
//     This keeps the game zero-sum (so CFR+ and exploitability are well
//     defined) and models the positional edge in the crudest way. Real
//     solvers play the turn and river; this is a teaching model, labelled
//     "simplified: one street, equity realisation" in the app.
//
// Ranges: the full preflop ranges (BTN open from the 6-max chart; BB's
// flat-call part of the BB-vs-BTN defence), weighted by preflop frequency,
// minus combos blocked by the flop. Copied from lib/gto/spots.dart (the same
// strings as tool/solve_river.dart).
//
// Solve: CFR+ (regret-matching+, alternating updates, linear averaging),
// vectorised over combos; showdown terminals are a matrix-vector product
// with the precomputed equity matrix. Iterates until the exploitability of
// the average strategy is below [targetExpl] (% of the flop pot) or the cap.
//
// Output: assets/data/flops.json. Strategies are stored PER COMBO for every
// board (suits matter on two-tone and monotone flops: flush draws, the
// nut-flush blocker) and quantised to 1%; the app aggregates to 13x13 hand
// classes for the grids.
//
// Run: dart compile exe tool/solve_flop.dart -o tool/.cache/solve_flop
//      tool/.cache/solve_flop [maxIters=3000] [maxBoards]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/range_parser.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/poker/evaluator.dart';

// Copied from lib/gto/spots.dart (that file imports Flutter). Keep in sync.
const _btnOpen = '22+, A2s+, K2s+, Q4s+, Q3s:0.5, J6s+, J5s:0.5, T6s+, 96s+, '
    '85s+, 74s+, 64s+, 53s+, 43s:0.6, A2o+, K8o+, K7o:0.5, Q9o+, Q8o:0.4, '
    'J9o+, J8o:0.3, T9o, T8o:0.4, 98o:0.5, 87o:0.25';
const _bb3bet = 'QQ+, JJ:0.6, TT:0.3, AKs, AQs:0.6, A5s-A2s:0.5, KQs:0.4, '
    'K9s-K6s:0.25, Q9s:0.3, J9s:0.3, T8s:0.3, 97s:0.3, 86s:0.3, 75s:0.3, '
    '64s:0.3, 54s:0.3, AKo, AQo:0.4, A5o:0.3, KJo:0.3';
const _bbDefend = '22+, A2s+, K2s+, Q2s+, J4s+, T5s+, 95s+, 85s+, 74s+, '
    '63s+, 53s+, 42s+, A2o+, K5o+, K4o:0.5, Q7o+, Q6o:0.4, J7o+, T7o+, 97o+, '
    '87o, 76o:0.6, 65o:0.4';

/// Representative flops grouped by texture (r = rainbow, s = suited).
const flopsByTexture = {
  'A-high dry': ['As7d2c', 'Ah8c3d', 'AdTc4s', 'Ac6h2d', 'AsJd5c'],
  'K-high dry': ['Ks7d2c', 'Kh8c3d', 'KdTc4s', 'Kc6h2d', 'Ks9d4c'],
  'Broadway wet': ['KsQdJc', 'QhJdTc', 'AdQsJh', 'KhJcTd', 'AsKdTc'],
  'Middling connected': ['9h8d6c', 'Ts9c7d', '8s7d5c', 'Jd9c8h', '9c7d6s'],
  'Low connected': ['6h5d4c', '7d5c4h', '6s4d3c', '5h3c2d', '7c6d3s'],
  'Paired': ['KsKd4c', '8h8d3c', 'QcQh6d', '5s5dKh', 'AhAd7c'],
  'Monotone': ['Ah8h3h', 'Ks9s5s', 'Td7d2d', 'Qc6c4c', '9h8h5h'],
  'Two-tone': ['9s8s7d', 'AhKh5d', 'Jd9d3c', 'Kc8c4h', '7h6h2c'],
};

const realiseOop = 0.9; // BB's equity realisation (BTN gets the rest)
const targetExpl = 0.05; // % of pot: stop below this
const oop = 0, ip = 1;

// ---------------------------------------------------------------- tree ----

class Node {
  final String? id;
  final int kind; // 0 decision, 1 fold, 2 showdown
  final int player; // decision: actor; fold: who folded
  final List<String> actions;
  final List<Node> children;
  final double invO, invI; // flop money put in (on top of 0.5 each)
  late List<Float64List> regret, stratSum;
  Node.decision(this.id, this.player, this.actions, this.children)
      : kind = 0,
        invO = 0,
        invI = 0;
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
  Node vsBet(String id, String raiseId, double b) => Node.decision(
        id,
        oop,
        ['Fold', 'Call', 'Raise'],
        [
          Node.fold(oop, 0, b),
          Node.showdown(b),
          Node.decision(raiseId, ip, ['Fold', 'Call'],
              [Node.fold(ip, 3 * b, b), Node.showdown(3 * b)]),
        ],
      );
  return Node.decision('root', ip, [
    'Check',
    'Bet 33%',
    'Bet 75%'
  ], [
    Node.showdown(0),
    vsBet('bbVs33', 'btnVsRaise33', 0.33),
    vsBet('bbVs75', 'btnVsRaise75', 0.75),
  ]);
}

void visit(Node n, void Function(Node) f) {
  f(n);
  for (final c in n.children) {
    visit(c, f);
  }
}

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
  final List<int> c1 = [], c2 = [];
  final List<double> w = [];
  late Int32List same;
  int get n => c1.length;
}

Side buildSide(RangeMap range, Set<int> board) {
  final s = Side();
  for (final e in range.entries) {
    if (e.value <= 0) continue;
    for (final c in HandClass.byIndex(e.key).combos()) {
      if (board.contains(c[0]) || board.contains(c[1])) continue;
      s.c1.add(c[0]);
      s.c2.add(c[1]);
      s.w.add(e.value);
    }
  }
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

/// Exact flop equity of every OOP combo vs every IP combo (0 when the two
/// combos share a card), enumerating all turn+river runouts.
Float64List equityMatrix(Side o, Side p, List<int> flop) {
  final nO = o.n, nI = p.n;
  final acc = Int32List(nO * nI);
  final live = [
    for (var c = 0; c < 52; c++)
      if (!flop.contains(c)) c
  ];
  final sO = Int32List(nO), sI = Int32List(nI);
  final cards = List<int>.filled(7, 0);
  cards[2] = flop[0];
  cards[3] = flop[1];
  cards[4] = flop[2];
  final vO = Int32List(nO), vI = Int32List(nI);
  for (var a = 0; a < live.length; a++) {
    for (var b = a + 1; b < live.length; b++) {
      final t = live[a], r = live[b];
      cards[5] = t;
      cards[6] = r;
      var kO = 0, kI = 0;
      for (var i = 0; i < nO; i++) {
        final x = o.c1[i], y = o.c2[i];
        if (x == t || x == r || y == t || y == r) continue;
        cards[0] = x;
        cards[1] = y;
        sO[i] = evaluate(cards);
        vO[kO++] = i;
      }
      for (var j = 0; j < nI; j++) {
        final x = p.c1[j], y = p.c2[j];
        if (x == t || x == r || y == t || y == r) continue;
        cards[0] = x;
        cards[1] = y;
        sI[j] = evaluate(cards);
        vI[kI++] = j;
      }
      for (var ii = 0; ii < kO; ii++) {
        final i = vO[ii];
        final s = sO[i];
        final row = i * nI;
        for (var jj = 0; jj < kI; jj++) {
          final j = vI[jj];
          final d = s - sI[j];
          acc[row + j] += d > 0 ? 2 : (d == 0 ? 1 : 0);
        }
      }
    }
  }
  final eq = Float64List(nO * nI);
  for (var i = 0; i < nO; i++) {
    for (var j = 0; j < nI; j++) {
      final c = o.c1[i], d = o.c2[i], e = p.c1[j], f = p.c2[j];
      if (c == e || c == f || d == e || d == f) continue;
      eq[i * nI + j] = acc[i * nI + j] / (2 * 990);
    }
  }
  return eq;
}

class Game {
  final List<Side> sides;
  final Node root;
  final Float64List eq; // OOP-major, OOP equity vs IP
  Game(this.sides, this.root, this.eq);

  final _cs = Float64List(52);

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

  /// Sum over opponent combos of reach * OOP equity, for each of [p]'s.
  Float64List eqMass(int p, Float64List oppR) {
    final nO = sides[0].n, nI = sides[1].n;
    if (p == oop) {
      final out = Float64List(nO);
      for (var i = 0; i < nO; i++) {
        var s = 0.0;
        final row = i * nI;
        for (var j = 0; j < nI; j++) {
          s += eq[row + j] * oppR[j];
        }
        out[i] = s;
      }
      return out;
    }
    final out = Float64List(nI);
    for (var i = 0; i < nO; i++) {
      final r = oppR[i];
      if (r == 0) continue;
      final row = i * nI;
      for (var j = 0; j < nI; j++) {
        out[j] += eq[row + j] * r;
      }
    }
    return out;
  }

  Float64List terminal(Node n, int p, Float64List oppR) {
    final m = oppMass(p, oppR);
    if (n.kind == 1) {
      final lost = 0.5 + (n.player == oop ? n.invO : n.invI);
      final u = n.player == p ? -lost : lost;
      for (var i = 0; i < m.length; i++) {
        m[i] *= u;
      }
      return m;
    }
    final pot = 1 + 2 * n.invO, inv = 0.5 + n.invO;
    final e = eqMass(p, oppR);
    // OOP gets pot * 0.9 * eqO; IP gets pot * (1 - 0.9 * eqO).
    for (var i = 0; i < m.length; i++) {
      m[i] = p == oop
          ? pot * realiseOop * e[i] - inv * m[i]
          : (pot - inv) * m[i] - pot * realiseOop * e[i];
    }
    return m;
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

Map<String, dynamic> solveBoard(String boardStr, String texture, RangeMap oopR,
    RangeMap ipR, int maxIters) {
  final sw = Stopwatch()..start();
  final flop = parseCards(boardStr);
  final bset = flop.toSet();
  final so = buildSide(oopR, bset), si = buildSide(ipR, bset);
  linkSides(so, si);
  final eq = equityMatrix(so, si, flop);
  final eqSecs = sw.elapsedMilliseconds / 1000;
  final root = buildTree();
  final g = Game([so, si], root, eq)..init();
  final wO = Float64List.fromList(so.w), wI = Float64List.fromList(si.w);
  final pairs = dot(g.oppMass(oop, wI), so.w);
  double expl() {
    final bo = dot(g.evalAvg(root, oop, wI, true), so.w);
    final bi = dot(g.evalAvg(root, ip, wO, true), si.w);
    return (bo + bi) / 2 / pairs * 100;
  }

  final trace = <List<num>>[];
  var iters = 0;
  var ex = 100.0;
  for (var t = 1; t <= maxIters; t++) {
    g.cfr(root, ip, wI, wO, t.toDouble());
    g.cfr(root, oop, wO, wI, t.toDouble());
    iters = t;
    if (t % 50 == 0 || t == maxIters) {
      ex = expl();
      trace.add([t, r3(ex)]);
      if (ex < targetExpl && t >= 200) break;
    }
  }

  final nodes = <String, Node>{};
  visit(root, (n) {
    if (n.kind == 0) nodes[n.id!] = n;
  });
  final avg = {for (final e in nodes.entries) e.key: g.average(e.value)};

  // Raw flop equity of each combo vs the opponent's whole range.
  Float64List eqVs(int p, Float64List oppR) {
    final e = g.eqMass(p, oppR), m = g.oppMass(p, oppR);
    return Float64List.fromList([
      for (var i = 0; i < m.length; i++)
        m[i] <= 0 ? 0 : (p == oop ? e[i] / m[i] : 1 - e[i] / m[i])
    ]);
  }

  final eqO = eqVs(oop, wI), eqI = eqVs(ip, wO);
  double wavg(List<double> v, List<double> w) =>
      dot(v, w) / w.reduce((a, b) => a + b);
  // Nut advantage: share of each range that has two pair or better now.
  double nutShare(Side s) {
    var n = 0.0, tot = 0.0;
    for (var i = 0; i < s.n; i++) {
      final cat = handCategory(evaluate([s.c1[i], s.c2[i], ...flop]));
      tot += s.w[i];
      if (cat >= 2) n += s.w[i];
    }
    return n / tot;
  }

  // Strong equity share: combos with > 75% equity vs the other range.
  double strongShare(Float64List e, List<double> w) {
    var n = 0.0, tot = 0.0;
    for (var i = 0; i < e.length; i++) {
      tot += w[i];
      if (e[i] > 0.75) n += w[i];
    }
    return n / tot;
  }

  final rootAvg = avg['root']!;
  Map<String, num> freqs(
      List<double> reach, List<Float64List> s, List<String> acts) {
    final tot = reach.reduce((a, b) => a + b);
    return {
      for (var a = 0; a < acts.length; a++) acts[a]: r3(dot(reach, s[a]) / tot)
    };
  }

  // BB's response frequencies, weighted by BB's full range.
  final evI = dot(g.evalAvg(root, ip, wO, false), si.w) / pairs;
  final stats = {
    'btn': freqs(si.w, rootAvg, nodes['root']!.actions),
    'bbVs33': freqs(so.w, avg['bbVs33']!, nodes['bbVs33']!.actions),
    'bbVs75': freqs(so.w, avg['bbVs75']!, nodes['bbVs75']!.actions),
    'btnEquity': r3(wavg(eqI, si.w)),
    'bbEquity': r3(wavg(eqO, so.w)),
    'btnNuts': r3(nutShare(si)),
    'bbNuts': r3(nutShare(so)),
    'btnStrong': r3(strongShare(eqI, si.w)),
    'bbStrong': r3(strongShare(eqO, so.w)),
    'btnEvShare': r3(0.5 + evI),
  };

  String combos(Side s) => [
        for (var i = 0; i < s.n; i++)
          cardToString(s.c1[i]) + cardToString(s.c2[i])
      ].join();
  final paths = ownerPaths(root);
  final st = stats['btn'] as Map;
  stderr.writeln('$boardStr ($texture): ${so.n}x${si.n} eq ${eqSecs}s, '
      '$iters it, expl ${r3(ex)}% pot, BTN $st '
      '[${sw.elapsedMilliseconds / 1000}s]');
  return {
    'board': boardStr,
    'texture': texture,
    'bb': {
      'combos': combos(so),
      'w': [for (final x in so.w) (x * 100).round()],
      'eq': [for (final x in eqO) (x * 100).round()],
    },
    'btn': {
      'combos': combos(si),
      'w': [for (final x in si.w) (x * 100).round()],
      'eq': [for (final x in eqI) (x * 100).round()],
    },
    'nodes': {
      for (final e in nodes.entries)
        e.key: {
          'player': e.value.player == oop ? 'bb' : 'btn',
          'actions': e.value.actions,
          'reach': paths[e.key],
          's': [
            for (var i = 0; i < g.sides[e.value.player].n; i++)
              ...pctRound([for (final a in avg[e.key]!) a[i]])
                  .sublist(0, e.value.actions.length - 1)
          ],
        }
    },
    'stats': stats,
    'iterations': iters,
    'exploitabilityPctPot': r3(ex),
    'explTrace': trace,
  };
}

void main(List<String> args) {
  final maxIters = args.isNotEmpty ? int.parse(args[0]) : 3000;
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
  for (final e in flopsByTexture.entries) {
    for (final b in e.value) {
      if (count++ >= maxBoards) break;
      if (parseCards(b).toSet().length != 3) throw StateError('bad flop $b');
      out.add(solveBoard(b, e.key, oopR, ipR, maxIters));
    }
  }
  final expl = [for (final r in out) r['exploitabilityPctPot'] as num];
  final f = File('assets/data/flops.json');
  f.writeAsStringSync(jsonEncode({
    'format': 'Simplified: one street, equity realisation. HU flop, BTN '
        '(opener, IP) vs BB (caller, OOP), single-raised pot, BB checks. '
        'Pot = 1. Check-check and called bets are settled by exact flop '
        'equity (all turn+river runouts); BB realises '
        '${(realiseOop * 100).round()}% of its equity, BTN the rest. Ranges: '
        'full preflop ranges (BTN open, BB flat call) minus board blockers.',
    'solver': 'CFR+ (regret-matching+, alternating updates, linear '
        'averaging), stops below $targetExpl% pot exploitability',
    'realiseOop': realiseOop,
    'solveSeconds': sw.elapsed.inSeconds,
    'maxExploitabilityPctPot': expl.reduce((a, b) => a > b ? a : b),
    'boards': out,
  }));
  stderr.writeln('wrote ${f.path} (${f.lengthSync()} bytes) '
      '${out.length} boards in ${sw.elapsed.inSeconds}s');
}
