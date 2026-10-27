// SIMPLIFIED heads-up FLOP c-bet solver: BTN (preflop raiser, in position)
// vs BB (caller, out of position), single-raised pot. The flop is solved
// together with a small TURN game; the river is not played.
//
// Pot normalised to 1 at the start of the flop (0.5 each invested); stacks
// are deep enough that nobody is all-in.
//
// FLOP (the strategies the app shows):
//   BB checks (assumed: BB checks its whole range to the raiser).
//   BTN: Check | Bet 33% | Bet 75%
//     vs bet b:  BB Fold | Call | Raise 3x (to 3b)
//       vs raise: BTN Fold | Call
// TURN (after check-check, call, or raise-call; every one of the 49 turn
// cards is dealt and solved, then discarded from the output):
//   BB: Check | Bet 75%
//     vs check: BTN Check | Bet 75%  (vs bet: BB Fold | Call)
//     vs bet:   BTN Fold | Call
// RIVER: not played. Turn showdowns are settled by each pair's exact equity
// over the 44 river cards (combo vs combo, card removal), with a mild
// equity-realisation adjustment for the skipped river street:
//   realised share of BB = e*Ro / (e*Ro + (1-e)*Ri),
//   Ro = rO0 + (rO1 - rO0) * h,   Ri = rI0 + (rI1 - rI0) * h',
// where e is the pair's river-card equity and h / h' are the two combos'
// equities vs the opponent's whole (preflop-weighted) range on that turn.
// Weak hands out of position realise less; the shares sum to 1 so the game
// stays zero-sum.
//
// Ranges: the full preflop ranges (BTN open from the 6-max chart; BB's
// flat-call part of the BB-vs-BTN defence), weighted by preflop frequency,
// minus combos blocked by the board. Copied from lib/gto/spots.dart.
// Turn ranges are NOT narrowed beyond what the flop strategies imply (they
// are: the solver plays flop and turn as one game).
//
// Solve: CFR+ (regret-matching+, alternating updates, linear averaging),
// vectorised over combos; turn showdowns are matrix-vector products with
// the per-turn-card equity matrices. Exploitability of the average strategy
// (whole flop+turn game, % of the flop pot) is measured every 25
// iterations; stops below [targetExpl]. Boards run in parallel isolates.
//
// Output: assets/data/flops.json: per-combo FLOP strategies for every board
// (suits matter on two-tone and monotone flops), quantised to 1%; the app
// aggregates to 13x13 hand classes for the grids.
//
// Run: dart compile exe tool/solve_flop.dart -o tool/.cache/solve_flop
//      tool/.cache/solve_flop [maxIters=400]
//   env: FLOPS=As7d2c,... (subset)  OUT=path  WORKERS=9
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

/// Representative flops grouped by texture.
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

double _env(String k, double d) =>
    double.tryParse(Platform.environment[k] ?? '') ?? d;

// River realisation (one skipped street), see header.
final double rO0 = _env('RO0', 0.8), rO1 = _env('RO1', 1.0);
final double rI0 = _env('RI0', 0.95), rI1 = _env('RI1', 1.05);
final double turnBet = _env('TURNBET', 0.75);
final double targetExpl = _env('TARGET', 0.1); // % of flop pot
const oop = 0, ip = 1;

// ---------------------------------------------------------------- tree ----

class Node {
  final String? id; // flop decision nodes only
  final int kind; // 0 decision, 1 fold, 2 showdown, 3 chance (turn deal)
  final int player; // decision: actor; fold: who folded
  final List<String> actions;
  final List<Node> children;
  final double invO, invI; // total invested (incl. the 0.5 each preflop)
  final int turn; // index into the turn-card list, -1 on the flop
  late List<Float64List> regret, stratSum;
  Node(this.id, this.kind, this.player, this.actions, this.children, this.invO,
      this.invI, this.turn);
}

Node _dec(String? id, int p, List<String> a, List<Node> c, int turn) =>
    Node(id, 0, p, a, c, 0, 0, turn);
Node _fold(int p, double o, double i) =>
    Node(null, 1, p, const [], const [], o, i, -1);
Node _show(double x, int turn) =>
    Node(null, 2, -1, const [], const [], x, x, turn);

Node turnTree(int t, double x) {
  final b = turnBet * 2 * x;
  return _dec(
      null,
      oop,
      ['Check', 'Bet'],
      [
        _dec(
            null,
            ip,
            ['Check', 'Bet'],
            [
              _show(x, t),
              _dec(null, oop, ['Fold', 'Call'],
                  [_fold(oop, x, x + b), _show(x + b, t)], t),
            ],
            t),
        _dec(null, ip, ['Fold', 'Call'], [_fold(ip, x + b, x), _show(x + b, t)],
            t),
      ],
      t);
}

Node chance(int nTurns, double x) => Node(null, 3, -1, const [],
    [for (var t = 0; t < nTurns; t++) turnTree(t, x)], x, x, -1);

Node buildTree(int nTurns) {
  Node vsBet(String id, String raiseId, double b) => _dec(
        id,
        oop,
        ['Fold', 'Call', 'Raise'],
        [
          _fold(oop, 0.5, 0.5 + b),
          chance(nTurns, 0.5 + b),
          _dec(
              raiseId,
              ip,
              ['Fold', 'Call'],
              [_fold(ip, 0.5 + 3 * b, 0.5 + b), chance(nTurns, 0.5 + 3 * b)],
              -1),
        ],
        -1,
      );
  return _dec(
      'root',
      ip,
      ['Check', 'Bet 33%', 'Bet 75%'],
      [
        chance(nTurns, 0.5),
        vsBet('bbVs33', 'btnVsRaise33', 0.33),
        vsBet('bbVs75', 'btnVsRaise75', 0.75),
      ],
      -1);
}

void visit(Node n, void Function(Node) f) {
  f(n);
  for (final c in n.children) {
    visit(c, f);
  }
}

/// Owner's flop action path to each flop decision node (for reach).
Map<String, List<List<Object>>> ownerPaths(Node root) {
  final out = <String, List<List<Object>>>{};
  void go(Node n, List<List<Object>> path) {
    if (n.kind != 0 || n.id == null) return;
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

Side buildSide(Map<int, double> range, Set<int> board) {
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

/// For each turn card: OOP-vs-IP equity over the 44 rivers (0 when the
/// combos share a card or hold the turn card).
List<Float32List> turnEquities(
    Side o, Side p, List<int> flop, List<int> turns) {
  final nO = o.n, nI = p.n;
  final out = <Float32List>[];
  final sO = Int32List(nO), sI = Int32List(nI);
  final vO = Int32List(nO), vI = Int32List(nI);
  final cards = List<int>.filled(7, 0);
  cards[2] = flop[0];
  cards[3] = flop[1];
  cards[4] = flop[2];
  final acc = Int32List(nO * nI);
  for (final t in turns) {
    acc.fillRange(0, acc.length, 0);
    cards[5] = t;
    for (final r in turns) {
      if (r == t) continue;
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
    final eq = Float32List(nO * nI);
    for (var i = 0; i < nO; i++) {
      final c = o.c1[i], d = o.c2[i];
      if (c == t || d == t) continue;
      for (var j = 0; j < nI; j++) {
        final e = p.c1[j], f = p.c2[j];
        if (e == t || f == t || c == e || c == f || d == e || d == f) continue;
        eq[i * nI + j] = acc[i * nI + j] / (2 * 44);
      }
    }
    out.add(eq);
  }
  return out;
}

class Game {
  final List<Side> sides;
  final Node root;
  final List<Float32List> eqT; // realised OOP share per turn card
  final List<List<Uint8List>> live; // [turn][player][combo] 1 = no clash
  final int nTurns;
  Game(this.sides, this.root, this.eqT, this.live) : nTurns = eqT.length;

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

  Float64List eqMass(int p, Float64List oppR, Float32List eq) {
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
      final lost = n.player == oop ? n.invO : n.invI;
      final u = n.player == p ? -lost : lost;
      for (var i = 0; i < m.length; i++) {
        m[i] *= u;
      }
      return m;
    }
    final pot = 2 * n.invO, inv = n.invO;
    final e = eqMass(p, oppR, eqT[n.turn]);
    for (var i = 0; i < m.length; i++) {
      m[i] =
          p == oop ? pot * e[i] - inv * m[i] : (pot - inv) * m[i] - pot * e[i];
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

  Float64List _mask(Float64List r, Uint8List l) {
    final o = Float64List(r.length);
    for (var i = 0; i < r.length; i++) {
      if (l[i] != 0) o[i] = r[i];
    }
    return o;
  }

  /// Chance node: average over turn cards (each hand pair sees 45 of them).
  Float64List _chance(Node n, int p, Float64List selfR, Float64List oppR,
      Float64List Function(Node, Float64List, Float64List) rec) {
    final m = selfR.length;
    final v = Float64List(m);
    for (var t = 0; t < nTurns; t++) {
      final ls = live[t][p], lo = live[t][1 - p];
      final va = rec(n.children[t], _mask(selfR, ls), _mask(oppR, lo));
      for (var i = 0; i < m; i++) {
        if (ls[i] != 0) v[i] += va[i];
      }
    }
    final inv = 1 / (nTurns - 4);
    for (var i = 0; i < m; i++) {
      v[i] *= inv;
    }
    return v;
  }

  Float64List cfr(
      Node n, int p, Float64List selfR, Float64List oppR, double t) {
    if (n.kind == 1 || n.kind == 2) return terminal(n, p, oppR);
    if (n.kind == 3) {
      return _chance(n, p, selfR, oppR, (c, s, o) => cfr(c, p, s, o, t));
    }
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

  Float64List evalAvg(
      Node n, int p, Float64List selfR, Float64List oppR, bool br) {
    if (n.kind == 1 || n.kind == 2) return terminal(n, p, oppR);
    if (n.kind == 3) {
      return _chance(n, p, selfR, oppR, (c, s, o) => evalAvg(c, p, s, o, br));
    }
    final sigma = average(n);
    final k = n.actions.length;
    if (n.player == p) {
      final m = sides[p].n;
      final v = Float64List(m);
      if (br) v.fillRange(0, m, double.negativeInfinity);
      for (var a = 0; a < k; a++) {
        final va = evalAvg(n.children[a], p, selfR, oppR, br);
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
      final va = evalAvg(n.children[a], p, selfR, r, br);
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

Map<String, dynamic> solveBoard(String boardStr, String texture,
    Map<int, double> oopR, Map<int, double> ipR, int maxIters) {
  final sw = Stopwatch()..start();
  final flop = parseCards(boardStr);
  final bset = flop.toSet();
  final so = buildSide(oopR, bset), si = buildSide(ipR, bset);
  linkSides(so, si);
  final nO = so.n, nI = si.n;
  final turns = [
    for (var c = 0; c < 52; c++)
      if (!bset.contains(c)) c
  ];
  final raw = turnEquities(so, si, flop, turns);
  final eqSecs = sw.elapsedMilliseconds / 1000;

  bool blocked(int i, int j) =>
      so.c1[i] == si.c1[j] ||
      so.c1[i] == si.c2[j] ||
      so.c2[i] == si.c1[j] ||
      so.c2[i] == si.c2[j];
  final live = [
    for (final t in turns)
      [
        Uint8List.fromList([
          for (var i = 0; i < nO; i++) so.c1[i] == t || so.c2[i] == t ? 0 : 1
        ]),
        Uint8List.fromList([
          for (var j = 0; j < nI; j++) si.c1[j] == t || si.c2[j] == t ? 0 : 1
        ]),
      ]
  ];

  // Raw flop equity (average over the 45 live turn cards of each pair).
  final flopEq = Float64List(nO * nI);
  for (final e in raw) {
    for (var k = 0; k < e.length; k++) {
      flopEq[k] += e[k];
    }
  }
  for (var k = 0; k < flopEq.length; k++) {
    flopEq[k] /= turns.length - 4;
  }

  // Realised shares per turn card (see header).
  final real = <Float32List>[];
  for (var t = 0; t < turns.length; t++) {
    final e = raw[t];
    final hO = Float64List(nO), hI = Float64List(nI);
    final mO = Float64List(nO), mI = Float64List(nI);
    for (var i = 0; i < nO; i++) {
      if (live[t][0][i] == 0) continue;
      for (var j = 0; j < nI; j++) {
        if (live[t][1][j] == 0 || blocked(i, j)) continue;
        final x = e[i * nI + j];
        hO[i] += si.w[j] * x;
        mO[i] += si.w[j];
        hI[j] += so.w[i] * (1 - x);
        mI[j] += so.w[i];
      }
    }
    final r = Float32List(nO * nI);
    for (var i = 0; i < nO; i++) {
      if (mO[i] <= 0) continue;
      final ro = rO0 + (rO1 - rO0) * hO[i] / mO[i];
      for (var j = 0; j < nI; j++) {
        if (mI[j] <= 0 || live[t][1][j] == 0 || blocked(i, j)) continue;
        final ri = rI0 + (rI1 - rI0) * hI[j] / mI[j];
        final x = e[i * nI + j];
        final a = x * ro, b = (1 - x) * ri;
        r[i * nI + j] = a + b > 0 ? a / (a + b) : 0.5;
      }
    }
    real.add(r);
  }

  final root = buildTree(turns.length);
  final g = Game([so, si], root, real, live)..init();
  final wO = Float64List.fromList(so.w), wI = Float64List.fromList(si.w);
  final pairs = dot(g.oppMass(oop, wI), so.w);
  double expl() {
    final bo = dot(g.evalAvg(root, oop, wO, wI, true), so.w);
    final bi = dot(g.evalAvg(root, ip, wI, wO, true), si.w);
    return (bo + bi) / 2 / pairs * 100;
  }

  final trace = <List<num>>[];
  var iters = 0;
  var ex = 100.0;
  for (var t = 1; t <= maxIters; t++) {
    g.cfr(root, ip, wI, wO, t.toDouble());
    g.cfr(root, oop, wO, wI, t.toDouble());
    iters = t;
    if (t % 25 == 0 || t == maxIters) {
      ex = expl();
      trace.add([t, r3(ex)]);
      if (ex < targetExpl && t >= 50) break;
    }
  }

  final nodes = <String, Node>{};
  visit(root, (n) {
    if (n.kind == 0 && n.id != null) nodes[n.id!] = n;
  });
  final avg = {for (final e in nodes.entries) e.key: g.average(e.value)};

  Float64List eqVs(int p, Float64List oppR) {
    final m = g.oppMass(p, oppR);
    final out = Float64List(p == oop ? nO : nI);
    for (var i = 0; i < nO; i++) {
      for (var j = 0; j < nI; j++) {
        if (blocked(i, j)) continue;
        final x = flopEq[i * nI + j];
        if (p == oop) {
          out[i] += x * oppR[j];
        } else {
          out[j] += (1 - x) * oppR[i];
        }
      }
    }
    for (var i = 0; i < out.length; i++) {
      out[i] = m[i] > 0 ? out[i] / m[i] : 0;
    }
    return out;
  }

  final eqO = eqVs(oop, wI), eqI = eqVs(ip, wO);
  double wavg(List<double> v, List<double> w) =>
      dot(v, w) / w.reduce((a, b) => a + b);
  double nutShare(Side s) {
    var n = 0.0, tot = 0.0;
    for (var i = 0; i < s.n; i++) {
      final cat = handCategory(evaluate([s.c1[i], s.c2[i], ...flop]));
      tot += s.w[i];
      if (cat >= 2) n += s.w[i];
    }
    return n / tot;
  }

  double strongShare(Float64List e, List<double> w) {
    var n = 0.0, tot = 0.0;
    for (var i = 0; i < e.length; i++) {
      tot += w[i];
      if (e[i] > 0.75) n += w[i];
    }
    return n / tot;
  }

  Map<String, num> freqs(
      List<double> reach, List<Float64List> s, List<String> acts) {
    final tot = reach.reduce((a, b) => a + b);
    return {
      for (var a = 0; a < acts.length; a++) acts[a]: r3(dot(reach, s[a]) / tot)
    };
  }

  final evI = dot(g.evalAvg(root, ip, wI, wO, false), si.w) / pairs;
  final stats = {
    'btn': freqs(si.w, avg['root']!, nodes['root']!.actions),
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
  stderr.writeln('$boardStr ($texture): ${so.n}x${si.n} eq ${eqSecs}s, '
      '$iters it, expl ${r3(ex)}% pot, BTN ${stats['btn']} '
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

Future<void> main(List<String> args) async {
  final maxIters = args.isNotEmpty ? int.parse(args[0]) : 400;
  final workers = _env('WORKERS', 9).toInt();
  final ipR = parseRange(_btnOpen);
  final three = parseRange(_bb3bet), def = parseRange(_bbDefend);
  final oopR = <int, double>{};
  def.forEach((k, v) {
    final c = v - (three[k] ?? 0);
    if (c > 0.001) oopR[k] = c;
  });
  final ipMap = Map<int, double>.of(ipR);
  final only = Platform.environment['FLOPS']?.split(',');
  final jobs = <(String, String)>[
    for (final e in flopsByTexture.entries)
      for (final b in e.value)
        if (only == null || only.contains(b)) (b, e.key)
  ];
  stderr.writeln('realisation BB $rO0..$rO1 BTN $rI0..$rI1, turn bet '
      '$turnBet, ${jobs.length} flops on $workers isolates');
  final sw = Stopwatch()..start();
  final results = List<Map<String, dynamic>?>.filled(jobs.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < jobs.length) {
      final k = next++;
      final (b, tex) = jobs[k];
      results[k] =
          await Isolate.run(() => solveBoard(b, tex, oopR, ipMap, maxIters));
    }
  }

  await Future.wait([for (var w = 0; w < workers; w++) worker()]);
  final out = results.cast<Map<String, dynamic>>();
  final expl = [for (final r in out) r['exploitabilityPctPot'] as num];
  final f = File(Platform.environment['OUT'] ?? 'assets/data/flops.json');
  f.writeAsStringSync(jsonEncode({
    'format': 'Simplified: flop + turn, no river betting. HU, BTN (opener, '
        'IP) vs BB (caller, OOP), single-raised pot, BB checks the flop. '
        'Pot = 1. Flop: BTN check / bet 33% / bet 75%, BB fold / call / '
        'raise 3x, BTN fold / call. Turn (every card solved): BB check / '
        'bet 75%, BTN check / bet 75% / fold / call. Turn showdowns use '
        'exact river-card equity with a mild realisation adjustment '
        '(BB $rO0..$rO1, BTN $rI0..$rI1 by hand strength, zero-sum). '
        'Ranges: full preflop ranges (BTN open, BB flat call) minus board '
        'blockers.',
    'solver': 'CFR+ (regret-matching+, alternating updates, linear '
        'averaging) on the flop+turn game, stops below $targetExpl% pot '
        'exploitability',
    'realisation': {
      'oop': [rO0, rO1],
      'ip': [rI0, rI1],
      'turnBet': turnBet,
    },
    'solveSeconds': sw.elapsed.inSeconds,
    'maxExploitabilityPctPot': expl.reduce((a, b) => a > b ? a : b),
    'boards': out,
  }));
  stderr.writeln('wrote ${f.path} (${f.lengthSync()} bytes) '
      '${out.length} boards in ${sw.elapsed.inSeconds}s');
}
