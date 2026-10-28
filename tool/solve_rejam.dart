// Short-stack cash spot: the big blind's 3-bet JAM over an open, and the
// opener's call-off, solved as a two-player equilibrium.
//
// Game, for opener P in UTG/HJ/CO/BTN/SB and BB effective stack S bb (the
// opener covers; everyone else folds; blinds 0.5/1, no ante):
//   P opens 2.5bb (SB: 3bb) with the app's RFI chart for P (a FIXED input:
//   lib/gto/spots.dart, an approximation of solver output, not solved here).
//   BB: Fold | All-in S.        P vs the jam: Fold | Call.
// BB has no flat call or small 3-bet in this model: it answers "if you are
// going to play this hand, is it a jam?", which is how short stacks (<= 25bb)
// play against an open. Larger stacks are left out because jam-or-fold
// stops being close to the full strategy there.
//
// Payoffs (bb, relative to the start of the hand): BB folds -1; BB jams and
// P folds +3 (the 2.5bb open + the dead SB, or the SB's 3bb open); P calls:
// BB gets eq * (2S + dead) - S, where dead = 0.5 when the SB folded.
//
// Equities: 169x169 preflop all-in matrix by Monte Carlo (fast evaluator from
// tool/solve_pushfold3.dart), with exact card-removal pair counts; cached
// under tool/.cache. Folded players' cards are ignored (as in push/fold).
// Solve: regret-matching+ with linear averaging over hand classes, until the
// exploitability of the average profile (sum of both players' best-response
// gains, bb per hand) is below [targetExpl].
//
// Output: assets/data/rejam.json.
// Run: dart compile exe tool/solve_rejam.dart -o tool/.cache/rejam
//      tool/.cache/rejam [samples=20000]
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/range_parser.dart';

import 'solve_pushfold3.dart' show Rng, eval7, nH;

const stacks = [15, 20, 25];
const openers = ['UTG', 'HJ', 'CO', 'BTN', 'SB'];
const targetExpl = 0.00002; // bb per hand
const maxIters = 200000;
const minIters = 5000; // lets near-pure hands shed early-iteration mixing

// Copied from lib/gto/spots.dart (_rfiRanges). Keep in sync.
const rfiRanges = {
  'UTG': '66+, 55:0.6, 44:0.3, A9s+, A8s:0.6, A5s-A3s, A2s:0.5, A7s-A6s:0.3, '
      'KTs+, K9s:0.5, QTs+, Q9s:0.3, JTs, J9s:0.3, T9s, 98s:0.5, 87s:0.3, '
      '76s:0.25, AJo+, ATo:0.5, KQo, KJo:0.3',
  'HJ': '55+, 44:0.6, 33:0.3, A2s+, K9s+, K8s:0.4, Q9s+, J9s+, T9s, T8s:0.4, '
      '98s, 87s:0.6, 76s:0.5, 65s:0.4, ATo+, KJo+, KTo:0.4, QJo, QTo:0.3',
  'CO': '33+, 22:0.6, A2s+, K6s+, K5s:0.5, Q8s+, J8s+, T8s+, 97s+, 86s+, 75s+, '
      '65s, 54s:0.6, A9o+, A8o:0.4, KTo+, K9o:0.3, QTo+, JTo, J9o:0.2',
  'BTN': '22+, A2s+, K2s+, Q4s+, Q3s:0.5, J6s+, J5s:0.5, T6s+, 96s+, 85s+, '
      '74s+, 64s+, 53s+, 43s:0.6, A2o+, K8o+, K7o:0.5, Q9o+, Q8o:0.4, J9o+, '
      'J8o:0.3, T9o, T8o:0.4, 98o:0.5, 87o:0.25',
  'SB': '22+, A2s+, K3s+, Q5s+, J7s+, T7s+, 96s+, 86s+, 75s+, 64s+, 54s, '
      '43s:0.4, A2o+, K8o+, K7o:0.4, Q9o+, Q8o:0.3, J9o+, T9o, 98o:0.4',
};

List<Int32List> _combos() => [
      for (final h in allHandClasses)
        Int32List.fromList([for (final c in h.combos()) ...c])
    ];

/// Row i: for j >= i, [pair count, equity of i vs j].
Float32List _mcRow(int i, int samples) {
  final combos = _combos();
  final rng = Rng(0x5EED + i * 7919);
  final out = Float32List((nH - i) * 2);
  final a = Int32List(7), b = Int32List(7);
  final pa = Int32List(144), pb = Int32List(144);
  final ci = combos[i];
  for (var j = i; j < nH; j++) {
    final cj = combos[j];
    var n = 0;
    for (var x = 0; x < ci.length; x += 2) {
      for (var y = 0; y < cj.length; y += 2) {
        final a0 = ci[x], a1 = ci[x + 1], b0 = cj[y], b1 = cj[y + 1];
        if (a0 == b0 || a0 == b1 || a1 == b0 || a1 == b1) continue;
        pa[n] = x;
        pb[n] = y;
        n++;
      }
    }
    final o = (j - i) * 2;
    out[o] = n.toDouble();
    if (n == 0 || i == j) {
      out[o + 1] = 0.5;
      continue;
    }
    var share = 0.0;
    for (var s = 0; s < samples; s++) {
      final k = n == 1 ? 0 : rng.next() % n;
      final a0 = ci[pa[k]], a1 = ci[pa[k] + 1];
      final b0 = cj[pb[k]], b1 = cj[pb[k] + 1];
      var used = (1 << a0) | (1 << a1) | (1 << b0) | (1 << b1);
      a[0] = a0;
      a[1] = a1;
      b[0] = b0;
      b[1] = b1;
      for (var d = 2; d < 7;) {
        final c = rng.next() % 52;
        if (used & (1 << c) != 0) continue;
        used |= 1 << c;
        a[d] = c;
        b[d] = c;
        d++;
      }
      final x = eval7(a), y = eval7(b);
      share += x > y ? 1 : (x == y ? 0.5 : 0);
    }
    out[o + 1] = share / samples;
  }
  return out;
}

/// (w2, e2): flat 169x169 pair counts and equity of row vs column.
Future<(Float64List, Float64List)> equities(int samples, int workers) async {
  final path = 'tool/.cache/rejam_eq2_$samples.bin';
  final f = File(path);
  if (!f.existsSync()) {
    final sw = Stopwatch()..start();
    final rows = List<Float32List?>.filled(nH, null);
    await Future.wait([
      for (var w = 0; w < workers; w++)
        Isolate.run(() => {
              for (var i = w; i < nH; i += workers) i: _mcRow(i, samples)
            }).then((m) => m.forEach((i, r) => rows[i] = r)),
    ]);
    final bb = BytesBuilder();
    for (final r in rows) {
      bb.add(r!.buffer.asUint8List());
    }
    f
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bb.takeBytes());
    stderr.writeln('equities: ${sw.elapsed.inSeconds}s');
  }
  final bytes = f.readAsBytesSync();
  final v = bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
  final w2 = Float64List(nH * nH), e2 = Float64List(nH * nH);
  var o = 0;
  for (var i = 0; i < nH; i++) {
    for (var j = i; j < nH; j++) {
      w2[i * nH + j] = w2[j * nH + i] = v[o];
      e2[i * nH + j] = v[o + 1];
      e2[j * nH + i] = 1 - v[o + 1];
      o += 2;
    }
  }
  return (w2, e2);
}

class Solution {
  final List<double> jam, call, jamEdge, callEdge;
  final double expl, bbEv;
  final int iters;
  Solution(this.jam, this.call, this.jamEdge, this.callEdge, this.expl,
      this.bbEv, this.iters);
}

/// Solves one (opener, stack) game. [rfi]: opening frequency per class.
Solution solve(List<double> rfi, double s, bool sbOpens, Float64List w2,
    Float64List e2) {
  final open = sbOpens ? 3.0 : 2.5;
  final dead = sbOpens ? 0.0 : 0.5;
  const steal = 3.0; // BB's gain when the opener folds to the jam
  final pot = 2 * s + dead;
  // Joint weight W[i][j] = rfi_i * pairs(i, j): opener i, BB j.
  final wt = Float64List(nH * nH);
  var total = 0.0;
  for (var i = 0; i < nH; i++) {
    for (var j = 0; j < nH; j++) {
      final x = rfi[i] * w2[i * nH + j];
      wt[i * nH + j] = x;
      total += x;
    }
  }
  final colW = List<double>.generate(
      nH, (j) => [for (var i = 0; i < nH; i++) wt[i * nH + j]].fold(0.0, (a, b) => a + b));

  // EV(jam) - EV(fold) for BB class j vs opener call profile.
  List<double> bbEdge(List<double> call) => [
        for (var j = 0; j < nH; j++)
          () {
            if (colW[j] == 0) return 0.0;
            var v = 0.0;
            for (var i = 0; i < nH; i++) {
              final x = wt[i * nH + j];
              if (x == 0) continue;
              final c = call[i];
              v += x * ((1 - c) * steal + c * (e2[j * nH + i] * pot - s));
            }
            return v / colW[j] - (-1);
          }()
      ];
  // EV(call) - EV(fold) for opener class i vs BB jam profile.
  List<double> opEdge(List<double> jam) => [
        for (var i = 0; i < nH; i++)
          () {
            var v = 0.0, d = 0.0;
            for (var j = 0; j < nH; j++) {
              final x = wt[i * nH + j] * jam[j];
              if (x == 0) continue;
              v += x * (e2[i * nH + j] * pot - s); // opener i's equity
              d += x;
            }
            return d == 0 ? 0.0 : v / d - (-open);
          }()
      ];

  // Regret-matching+ on two binary decisions per class.
  final rj = List<double>.filled(nH, 0), rjF = List<double>.filled(nH, 0);
  final rc = List<double>.filled(nH, 0), rcF = List<double>.filled(nH, 0);
  final sj = List<double>.filled(nH, 0), sc = List<double>.filled(nH, 0);
  final nj = List<double>.filled(nH, 0), nc = List<double>.filled(nH, 0);
  double cur(double a, double b) => a + b > 0 ? a / (a + b) : 0.5;

  late List<double> avgJ, avgC;
  double exploit() {
    avgJ = [for (var j = 0; j < nH; j++) nj[j] > 0 ? sj[j] / nj[j] : 0.5];
    avgC = [for (var i = 0; i < nH; i++) nc[i] > 0 ? sc[i] / nc[i] : 0.5];
    final eb = bbEdge(avgC), eo = opEdge(avgJ);
    // Best-response gain = sum over classes of weight * (max(edge,0) - p*edge).
    var g = 0.0;
    for (var j = 0; j < nH; j++) {
      g += colW[j] * (max(eb[j], 0) - avgJ[j] * eb[j]);
    }
    // Opener's decision is reached with weight sum_j W[i][j] * jam_j.
    for (var i = 0; i < nH; i++) {
      var reach = 0.0;
      for (var j = 0; j < nH; j++) {
        reach += wt[i * nH + j] * avgJ[j];
      }
      g += reach * (max(eo[i], 0) - avgC[i] * eo[i]);
    }
    return g / total;
  }

  var t = 0;
  var e = double.infinity;
  while (t < maxIters) {
    t++;
    // BB update vs current opener strategy.
    final callNow = [for (var i = 0; i < nH; i++) cur(rc[i], rcF[i])];
    final eb = bbEdge(callNow);
    for (var j = 0; j < nH; j++) {
      final p = cur(rj[j], rjF[j]);
      // Regrets relative to the mixed value; jam payoff edge eb vs fold 0.
      rj[j] = max(0, rj[j] + (1 - p) * eb[j]);
      rjF[j] = max(0, rjF[j] - p * eb[j]);
      final p2 = cur(rj[j], rjF[j]);
      sj[j] += t * p2;
      nj[j] += t;
    }
    final jamNow = [for (var j = 0; j < nH; j++) cur(rj[j], rjF[j])];
    final eo = opEdge(jamNow);
    for (var i = 0; i < nH; i++) {
      final p = cur(rc[i], rcF[i]);
      rc[i] = max(0, rc[i] + (1 - p) * eo[i]);
      rcF[i] = max(0, rcF[i] - p * eo[i]);
      sc[i] += t * cur(rc[i], rcF[i]);
      nc[i] += t;
    }
    if (t % 200 == 0) {
      e = exploit();
      if (e < targetExpl && t >= minIters) break;
    }
  }
  e = exploit();
  final eb = bbEdge(avgC), eo = opEdge(avgJ);
  var bbEv = 0.0;
  for (var j = 0; j < nH; j++) {
    bbEv += colW[j] * (-1 + avgJ[j] * eb[j]);
  }
  return Solution(avgJ, [for (var i = 0; i < nH; i++) rfi[i] > 0 ? avgC[i] : 0],
      eb, [for (var i = 0; i < nH; i++) rfi[i] > 0 ? eo[i] : 0], e, bbEv / total, t);
}

double share(List<double> f, [List<double>? reach]) {
  var c = 0.0, n = 0.0;
  for (var i = 0; i < nH; i++) {
    final w = HandClass.byIndex(i).comboCount * (reach?[i] ?? 1);
    c += f[i] * w;
    n += w;
  }
  return c / n;
}

Future<void> main(List<String> args) async {
  final samples = args.isNotEmpty ? int.parse(args[0]) : 20000;
  final (w2, e2) = await equities(samples, 10);
  double r3(double v) => (v * 1000).round() / 1000;
  final out = <String, dynamic>{
    'format': 'BB jam-or-fold vs an open, opener call-or-fold. Opener range '
        '= the app\'s RFI chart (input). Blinds 0.5/1, no ante, open 2.5bb '
        '(SB 3bb), stack = BB effective stack in bb.',
    'solver': 'Regret-matching+ with linear averaging over hand classes, '
        'Monte Carlo all-in equities ($samples boards per class matchup), '
        'exact card-removal pair counts.',
    'samplesPerMatchup': samples,
    'stacks': stacks,
    'openers': openers,
    'spots': <String, dynamic>{},
  };
  for (final p in openers) {
    final r = parseRange(rfiRanges[p]!);
    final rfi = [for (var i = 0; i < nH; i++) r[i] ?? 0.0];
    for (final s in stacks) {
      final sol = solve(rfi, s.toDouble(), p == 'SB', w2, e2);
      out['spots']['$p-$s'] = {
        'bbJam': [for (final v in sol.jam) r3(v)],
        'bbJamEdge': [for (final v in sol.jamEdge) r3(v)],
        'openCall': [for (final v in sol.call) r3(v)],
        'openCallEdge': [for (final v in sol.callEdge) r3(v)],
        'exploitabilityBb': double.parse(sol.expl.toStringAsPrecision(2)),
        'iterations': sol.iters,
        'bbEv': r3(sol.bbEv),
      };
      stderr.writeln('$p ${s}bb: BB jams ${(share(sol.jam) * 100).toStringAsFixed(1)}% '
          'of hands, opener calls ${(share(sol.call, rfi) * 100).toStringAsFixed(1)}% '
          'of opens; expl ${sol.expl.toStringAsFixed(5)}bb in ${sol.iters} it');
    }
  }
  final f = File('assets/data/rejam.json');
  f.writeAsStringSync(jsonEncode(out));
  stderr.writeln('wrote ${f.path} (${f.lengthSync()} bytes)');
}
