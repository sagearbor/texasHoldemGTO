// 3-handed push/fold Nash solver (BTN, SB, BB), blinds 0.5/1, no ante,
// equal effective stacks 5..20bb.
//
// Tree:
//   BTN: jam / fold
//   SB vs BTN jam: call / fold          SB after BTN fold: jam / fold
//   BB vs BTN jam (SB folded): call / fold
//   BB vs BTN jam + SB call: overcall / fold
//   BB vs SB jam (BTN folded): call / fold
// Equal stacks, so there are no side pots; folded blinds are dead money.
//
// Equities:
//   * 2-way: 169x169 Monte Carlo matrix, as in tool/solve_pushfold.dart.
//     In 3-handed pots where one player folded, the folded hand's cards are
//     not removed from the board deck (tiny effect, ignored).
//   * 3-way: Monte Carlo per unordered class triple (a <= b <= c; 828,409
//     triples) with [samples3] boards each, expanded by symmetry to the
//     ordered 169^3 table.
// Card removal: the joint weight of a class triple is the EXACT number of
// non-overlapping combo triples (enumerated while sampling). This is better
// than the usual product-of-pairwise approximation
//   N(a,b,c) ~ n_a n_b n_c * r_ab * r_ac * r_bc,  r_xy = w_xy / (n_x n_y)
// and costs nothing extra because the MC enumerates the combo triples anyway.
// All six decisions are weighted by this joint distribution, so e.g. the
// SB-vs-BB subgame after a BTN fold sees the removal effect of the BTN's
// folding range (the HU solution is not reused).
//
// Solve: CFR+ style regret matching+ with linear averaging (every player has
// exactly one decision per deal, so this is per-hand regret matching with
// regrets weighted by the opponents' reach). Every 25 iterations the
// exploitability of the AVERAGE profile is measured exactly: the sum over the
// three players of their best-response gain, in bb per hand. Stops below
// [targetExpl] or at the iteration cap. Fictitious play is kept as
// mode 'fp' for comparison; it needs ~10x more iterations for the same
// exploitability. One profile evaluation is a single pass over the 169^3
// ordered triples (~45ms AOT on an M4 P-core).
//
// The equity tables are cached (binary) under tool/.cache (gitignored).
//
// Build + run (AOT is ~3x faster than JIT):
//   dart compile exe tool/solve_pushfold3.dart -o tool/.cache/pf3
//   tool/.cache/pf3 [samples3=300] [samples2=6000] [maxIters=2000]
// Self-test of the fast evaluator against lib/poker/evaluator.dart:
//   tool/.cache/pf3 --selftest
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/poker/evaluator.dart' as ref;

const int nH = 169;
const int nH2 = nH * nH;
const int nH3 = nH2 * nH;
const List<int> stacks = [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20];
const double targetExpl = 0.0002; // bb per hand, summed over players

// ---------------------------------------------------------------------------
// Fast allocation-free 7-card evaluator. Score is only used for comparisons.

final Int8List _pop = () {
  final t = Int8List(8192);
  for (var m = 1; m < 8192; m++) {
    t[m] = t[m >> 1] + (m & 1);
  }
  return t;
}();

final Int8List _hi = () {
  final t = Int8List(8192)..[0] = -1;
  for (var m = 1; m < 8192; m++) {
    var r = 12;
    while (m & (1 << r) == 0) {
      r--;
    }
    t[m] = r;
  }
  return t;
}();

final Int8List _straight = () {
  final t = Int8List(8192);
  for (var mask = 0; mask < 8192; mask++) {
    final m = (mask << 1) | ((mask >> 12) & 1);
    var v = -1;
    for (var top = 13; top >= 4; top--) {
      if ((m >> (top - 4)) & 0x1F == 0x1F) {
        v = top - 1;
        break;
      }
    }
    t[mask] = v;
  }
  return t;
}();

int _keepTop(int m, int k) {
  while (_pop[m] > k) {
    m &= m - 1;
  }
  return m;
}

/// cards: 7 card ints (rank = c >> 2, suit = c & 3).
int eval7(Int32List cards) {
  var m1 = 0, m2 = 0, m3 = 0, m4 = 0, s0 = 0, s1 = 0, s2 = 0, s3 = 0;
  for (var i = 0; i < 7; i++) {
    final c = cards[i];
    final b = 1 << (c >> 2);
    m4 |= m3 & b;
    m3 |= m2 & b;
    m2 |= m1 & b;
    m1 |= b;
    switch (c & 3) {
      case 0:
        s0 |= b;
      case 1:
        s1 |= b;
      case 2:
        s2 |= b;
      default:
        s3 |= b;
    }
  }
  var fl = -1;
  if (_pop[s0] >= 5) {
    fl = s0;
  } else if (_pop[s1] >= 5) {
    fl = s1;
  } else if (_pop[s2] >= 5) {
    fl = s2;
  } else if (_pop[s3] >= 5) {
    fl = s3;
  }
  if (fl >= 0) {
    final sf = _straight[fl];
    if (sf >= 0) return (8 << 26) | sf;
  }
  if (m4 != 0) {
    final q = _hi[m4];
    return (7 << 26) | (q << 13) | _hi[m1 & ~(1 << q)];
  }
  if (m3 != 0) {
    final t = _hi[m3];
    final rest = m2 & ~(1 << t);
    if (rest != 0) return (6 << 26) | (t << 13) | _hi[rest];
  }
  if (fl >= 0) return (5 << 26) | _keepTop(fl, 5);
  final st = _straight[m1];
  if (st >= 0) return (4 << 26) | st;
  if (m3 != 0) {
    final t = _hi[m3];
    return (3 << 26) | (t << 13) | _keepTop(m1 & ~(1 << t), 2);
  }
  if (m2 != 0) {
    if (_pop[m2] >= 2) {
      final p = _keepTop(m2, 2);
      return (2 << 26) | (p << 13) | _hi[m1 & ~p];
    }
    final p = _hi[m2];
    return (1 << 26) | (p << 13) | _keepTop(m1 & ~(1 << p), 3);
  }
  return _keepTop(m1, 5);
}

// xorshift64* style generator (top bits used).
class Rng {
  int s;
  Rng(int seed) : s = seed == 0 ? 0x9E3779B97F4A7C15 : seed;
  int next() {
    var x = s;
    x ^= x << 13;
    x ^= x >>> 7;
    x ^= x << 17;
    s = x;
    return x >>> 11; // 53 non-negative bits
  }
}

List<Int32List> _combos() => [
      for (final h in allHandClasses)
        Int32List.fromList([for (final c in h.combos()) ...c])
    ];

// ---------------------------------------------------------------------------
// Monte Carlo workers.

/// For a fixed i: rows j >= i of [weight, eq_i] (eq_j = 1 - eq_i).
Float32List _mc2Row(int i, int samples) {
  final combos = _combos();
  final rng = Rng(0x1234567 + i * 7919);
  final out = Float32List((nH - i) * 2);
  final cards = Int32List(7), cards2 = Int32List(7);
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
    if (n == 0) {
      out[o + 1] = 0.5;
      continue;
    }
    var share = 0.0;
    for (var s = 0; s < samples; s++) {
      final k = n == 1 ? 0 : rng.next() % n;
      final a0 = ci[pa[k]], a1 = ci[pa[k] + 1];
      final b0 = cj[pb[k]], b1 = cj[pb[k] + 1];
      var used = (1 << a0) | (1 << a1) | (1 << b0) | (1 << b1);
      cards[0] = a0;
      cards[1] = a1;
      cards2[0] = b0;
      cards2[1] = b1;
      for (var d = 2; d < 7;) {
        final c = rng.next() % 52;
        if (used & (1 << c) != 0) continue;
        used |= 1 << c;
        cards[d] = c;
        cards2[d] = c;
        d++;
      }
      final x = eval7(cards), y = eval7(cards2);
      share += x > y ? 1 : (x == y ? 0.5 : 0);
    }
    var e = share / samples;
    if (i == j) e = 0.5;
    out[o + 1] = e;
  }
  return out;
}

/// For a fixed i: all (j, k) with i <= j <= k, 4 floats each:
/// [exact combo-triple count, eq_i, eq_j, eq_k].
Float32List _mc3Row(int i, int samples) {
  final combos = _combos();
  final rng = Rng(0xABCDEF + i * 104729);
  var count = 0;
  for (var j = i; j < nH; j++) {
    count += nH - j;
  }
  final out = Float32List(count * 4);
  final ha = Int32List(7), hb = Int32List(7), hc = Int32List(7);
  final ta = Int32List(1728), tb = Int32List(1728), tc = Int32List(1728);
  final ci = combos[i];
  var o = 0;
  for (var j = i; j < nH; j++) {
    final cj = combos[j];
    for (var k = j; k < nH; k++) {
      final ck = combos[k];
      var n = 0;
      for (var x = 0; x < ci.length; x += 2) {
        final ma = (1 << ci[x]) | (1 << ci[x + 1]);
        for (var y = 0; y < cj.length; y += 2) {
          final mb = (1 << cj[y]) | (1 << cj[y + 1]);
          if (ma & mb != 0) continue;
          final mab = ma | mb;
          for (var z = 0; z < ck.length; z += 2) {
            final mc = (1 << ck[z]) | (1 << ck[z + 1]);
            if (mab & mc != 0) continue;
            ta[n] = x;
            tb[n] = y;
            tc[n] = z;
            n++;
          }
        }
      }
      out[o] = n.toDouble();
      if (n == 0) {
        out[o + 1] = out[o + 2] = out[o + 3] = 1 / 3;
        o += 4;
        continue;
      }
      var ea = 0.0, eb = 0.0, ec = 0.0;
      for (var s = 0; s < samples; s++) {
        final t = n == 1 ? 0 : rng.next() % n;
        final a0 = ci[ta[t]], a1 = ci[ta[t] + 1];
        final b0 = cj[tb[t]], b1 = cj[tb[t] + 1];
        final c0 = ck[tc[t]], c1 = ck[tc[t] + 1];
        var used = (1 << a0) | (1 << a1) | (1 << b0) | (1 << b1) | (1 << c0) | (1 << c1);
        ha[0] = a0;
        ha[1] = a1;
        hb[0] = b0;
        hb[1] = b1;
        hc[0] = c0;
        hc[1] = c1;
        for (var d = 2; d < 7;) {
          final c = rng.next() % 52;
          if (used & (1 << c) != 0) continue;
          used |= 1 << c;
          ha[d] = c;
          hb[d] = c;
          hc[d] = c;
          d++;
        }
        final x = eval7(ha), y = eval7(hb), z = eval7(hc);
        var best = x > y ? x : y;
        if (z > best) best = z;
        final w = (x == best ? 1 : 0) + (y == best ? 1 : 0) + (z == best ? 1 : 0);
        final sh = 1.0 / w;
        if (x == best) ea += sh;
        if (y == best) eb += sh;
        if (z == best) ec += sh;
      }
      ea /= samples;
      eb /= samples;
      ec /= samples;
      // Identical classes have identical equity by symmetry.
      if (i == j && j == k) {
        ea = eb = ec = 1 / 3;
      } else if (i == j) {
        ea = eb = (ea + eb) / 2;
      } else if (j == k) {
        eb = ec = (eb + ec) / 2;
      }
      out[o + 1] = ea;
      out[o + 2] = eb;
      out[o + 3] = ec;
      o += 4;
    }
  }
  return out;
}

Future<List<Float32List>> _parallel(
    int workers, Float32List Function(int i, int samples) f, int samples) async {
  final results = List<Float32List?>.filled(nH, null);
  // Interleave so each worker gets a mix of heavy (small i) and light rows.
  final futures = <Future<void>>[];
  for (var w = 0; w < workers; w++) {
    futures.add(Isolate.run(() {
      final rows = <int, Float32List>{};
      for (var i = w; i < nH; i += workers) {
        rows[i] = f(i, samples);
      }
      return rows;
    }).then((rows) => rows.forEach((i, v) => results[i] = v)));
  }
  await Future.wait(futures);
  return [for (final r in results) r!];
}

// ---------------------------------------------------------------------------
// Cache: header + 2-way rows + 3-way rows (all Float32).

String _cachePath(int s3, int s2) => 'tool/.cache/pf3_eq_${s3}_$s2.bin';

Future<void> _buildCache(String path, int s3, int s2, int workers) async {
  final sw = Stopwatch()..start();
  stderr.writeln('building 2-way equities ($s2 samples/matchup)...');
  final r2 = await _parallel(workers, _mc2Row, s2);
  stderr.writeln('  done in ${sw.elapsed.inSeconds}s');
  stderr.writeln('building 3-way equities ($s3 samples/triple)...');
  final r3 = await _parallel(workers, _mc3Row, s3);
  stderr.writeln('  done in ${sw.elapsed.inSeconds}s');
  final b = BytesBuilder(copy: false);
  for (final r in r2) {
    b.add(r.buffer.asUint8List(r.offsetInBytes, r.lengthInBytes));
  }
  for (final r in r3) {
    b.add(r.buffer.asUint8List(r.offsetInBytes, r.lengthInBytes));
  }
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(b.takeBytes());
}

/// Expanded tables. Ordered index (a, b, c) = (a * 169 + b) * 169 + c.
class Tables {
  final Float32List w3 = Float32List(nH3); // exact combo-triple counts
  final Float32List e3a = Float32List(nH3); // equity of the first hand
  final Float32List e3b = Float32List(nH3); // equity of the second hand
  final Float64List e2 = Float64List(nH2); // e2[x * 169 + y] = eq of x vs y
  final Float64List w2 = Float64List(nH2);
  final Float64List marg = Float64List(nH); // sum over (b,c) of w3(a,b,c)

  Tables.load(String path) {
    final bytes = File(path).readAsBytesSync();
    final f = bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
    var o = 0;
    for (var i = 0; i < nH; i++) {
      for (var j = i; j < nH; j++) {
        w2[i * nH + j] = w2[j * nH + i] = f[o];
        e2[i * nH + j] = f[o + 1];
        e2[j * nH + i] = 1 - f[o + 1];
        o += 2;
      }
    }
    for (var i = 0; i < nH; i++) {
      for (var j = i; j < nH; j++) {
        for (var k = j; k < nH; k++) {
          final n = f[o], ei = f[o + 1], ej = f[o + 2], ek = f[o + 3];
          o += 4;
          void put(int p, int q, int r, double ep, double eq) {
            final idx = (p * nH + q) * nH + r;
            w3[idx] = n;
            e3a[idx] = ep;
            e3b[idx] = eq;
          }

          put(i, j, k, ei, ej);
          put(i, k, j, ei, ek);
          put(j, i, k, ej, ei);
          put(j, k, i, ej, ek);
          put(k, i, j, ek, ei);
          put(k, j, i, ek, ej);
        }
      }
    }
    for (var a = 0; a < nH; a++) {
      var s = 0.0;
      final base = a * nH2;
      for (var t = 0; t < nH2; t++) {
        s += w3[base + t];
      }
      marg[a] = s;
    }
  }
}

// ---------------------------------------------------------------------------
// Solver.

const nodeNames = [
  'btnJam',
  'sbCallVsBtn',
  'sbJamVsBb',
  'bbCallVsBtn',
  'bbOvercall',
  'bbCallVsSb',
];

/// Fold value (bb, net for the hand) of the acting player at each node.
const foldValue = [0.0, -0.5, -0.5, -1.0, -1.0, -1.0];

class Evs {
  // ev[node][hand] of the aggressive action, reach[node][hand] = weight of
  // reaching the node with that hand (unnormalized, same scale as marg).
  final ev = List.generate(6, (_) => Float64List(nH));
  final reach = List.generate(6, (_) => Float64List(nH));
}

/// One pass over all ordered triples (BTN a, SB b, BB c): EV of the
/// aggressive action at every node against the strategy profile [st].
void evaluateProfile(Tables t, double s, List<Float64List> st, Evs out) {
  final x = st[0], y = st[1], z = st[2], u = st[3], v = st[4], q = st[5];
  final w3 = t.w3, e3a = t.e3a, e3b = t.e3b, e2 = t.e2;
  final nums = [for (var n = 0; n < 6; n++) out.ev[n]..fillRange(0, nH, 0)];
  final dens = [for (var n = 0; n < 6; n++) out.reach[n]..fillRange(0, nH, 0)];
  final numBtn = nums[0], numSbC = nums[1], numSbJ = nums[2];
  final denSbC = dens[1], denSbJ = dens[2];
  final numBb1 = nums[3], numBbO = nums[4], numBbS = nums[5];
  final denBb1 = dens[3], denBbO = dens[4], denBbS = dens[5];
  final pot5 = 2 * s + 0.5, pot6 = 2 * s + 1, pot3 = 2 * s, pot7 = 3 * s;
  for (var a = 0; a < nH; a++) {
    final xa = x[a], fa = 1 - xa;
    var accBtn = 0.0;
    final rowA = a * nH;
    for (var b = 0; b < nH; b++) {
      final yb = y[b], zb = z[b];
      final e2ab = e2[rowA + b];
      final btnT6 = e2ab * pot6 - s, sbT6 = (1 - e2ab) * pot6 - s;
      final wJamCall = xa * yb, wJamFold = xa * (1 - yb), wFoldJam = fa * zb;
      final rowB = b * nH;
      final base = (rowA + b) * nH;
      var accSbC = 0.0, accSbCd = 0.0, accSbJ = 0.0, accSbJd = 0.0;
      var accBtnB = 0.0;
      for (var c = 0; c < nH; c++) {
        final n = w3[base + c];
        if (n == 0) continue;
        final uc = u[c], vc = v[c], qc = q[c];
        final ea = e3a[base + c], eb = e3b[base + c];
        final e2ac = e2[rowA + c], e2bc = e2[rowB + c];
        // BTN jam EV (given SB / BB responses).
        final btnT5 = e2ac * pot5 - s;
        final btnT7 = ea * pot7 - s;
        accBtnB += n *
            ((1 - yb) * ((1 - uc) * 1.5 + uc * btnT5) +
                yb * ((1 - vc) * btnT6 + vc * btnT7));
        // SB call vs BTN jam.
        final nj = n * xa;
        accSbC += nj * ((1 - vc) * sbT6 + vc * (eb * pot7 - s));
        accSbCd += nj;
        // SB jam after BTN fold.
        final nf = n * fa;
        accSbJ += nf * ((1 - qc) + qc * (e2bc * pot3 - s));
        accSbJd += nf;
        // BB nodes.
        final w1 = n * wJamFold;
        numBb1[c] += w1 * ((1 - e2ac) * pot5 - s);
        denBb1[c] += w1;
        final wo = n * wJamCall;
        numBbO[c] += wo * ((1 - ea - eb) * pot7 - s);
        denBbO[c] += wo;
        final ws = n * wFoldJam;
        numBbS[c] += ws * ((1 - e2bc) * pot3 - s);
        denBbS[c] += ws;
      }
      accBtn += accBtnB;
      numSbC[b] += accSbC;
      denSbC[b] += accSbCd;
      numSbJ[b] += accSbJ;
      denSbJ[b] += accSbJd;
    }
    numBtn[a] = accBtn;
  }
  out.reach[0].setAll(0, t.marg);
  for (var n = 0; n < 6; n++) {
    final e = nums[n], d = dens[n];
    for (var h = 0; h < nH; h++) {
      e[h] = d[h] > 1e-9 ? e[h] / d[h] : foldValue[n];
    }
  }
}

/// Best-response gain per player (BTN, SB, BB) in bb per hand.
List<double> exploitability(Tables t, List<Float64List> st, Evs e) {
  var total = 0.0;
  for (var h = 0; h < nH; h++) {
    total += t.marg[h];
  }
  final owner = [0, 1, 1, 2, 2, 2];
  final gains = [0.0, 0.0, 0.0];
  for (var n = 0; n < 6; n++) {
    final fv = foldValue[n];
    for (var h = 0; h < nH; h++) {
      final evA = e.ev[n][h], f = st[n][h];
      final cur = f * evA + (1 - f) * fv;
      final br = evA > fv ? evA : fv;
      gains[owner[n]] += e.reach[n][h] / total * (br - cur);
    }
  }
  return gains;
}

/// Solver modes: 'fp' = fictitious play (best response to the running
/// average), 'cfr' = regret matching+ with linear averaging (CFR+ on this
/// one-decision-per-player tree; regrets weighted by opponents' reach).
Map<String, dynamic> solveStack(Tables t, int stack, int maxIters,
    {String mode = 'cfr', int checkEvery = 20, bool verbose = false}) {
  final s = stack.toDouble();
  final avg = List.generate(6, (_) => Float64List(nH)..fillRange(0, nH, 0.5));
  final cur = List.generate(6, (_) => Float64List(nH)..fillRange(0, nH, 0.5));
  final regJ = List.generate(6, (_) => Float64List(nH));
  final regF = List.generate(6, (_) => Float64List(nH));
  final wsum = List.generate(6, (_) => Float64List(nH));
  var wtot = 0.0;
  final e = Evs();
  final sw = Stopwatch()..start();
  var it = 0;
  List<double> g = const [1, 1, 1];
  for (it = 1; it <= maxIters; it++) {
    if (mode == 'fp') {
      evaluateProfile(t, s, avg, e);
      g = exploitability(t, avg, e);
      if (verbose && it % checkEvery == 0) {
        stderr.writeln('  it $it expl ${g.reduce((a, b) => a + b)}');
      }
      if (g[0] + g[1] + g[2] < targetExpl && it > 50) break;
      final a = 1 / (it + 1);
      for (var n = 0; n < 6; n++) {
        final fv = foldValue[n];
        for (var h = 0; h < nH; h++) {
          final br = e.ev[n][h] > fv ? 1.0 : 0.0;
          avg[n][h] += a * (br - avg[n][h]);
        }
      }
    } else {
      evaluateProfile(t, s, cur, e);
      final wt = it.toDouble();
      wtot += wt;
      for (var n = 0; n < 6; n++) {
        final fv = foldValue[n];
        final ev = e.ev[n], rc = e.reach[n], c = cur[n];
        final rj = regJ[n], rf = regF[n], ws = wsum[n], av = avg[n];
        for (var h = 0; h < nH; h++) {
          ws[h] += wt * c[h];
          av[h] = ws[h] / wtot;
          final v = c[h] * ev[h] + (1 - c[h]) * fv;
          rj[h] = max(0.0, rj[h] + rc[h] * (ev[h] - v));
          rf[h] = max(0.0, rf[h] + rc[h] * (fv - v));
          final tot = rj[h] + rf[h];
          c[h] = tot > 0 ? rj[h] / tot : 0.5;
        }
      }
      if (it % checkEvery == 0 || it == maxIters) {
        evaluateProfile(t, s, avg, e);
        g = exploitability(t, avg, e);
        if (verbose) {
          stderr.writeln('  it $it expl ${g.reduce((a, b) => a + b)}');
        }
        if (g[0] + g[1] + g[2] < targetExpl) break;
      }
    }
  }
  final st = avg;
  evaluateProfile(t, s, st, e);
  g = exploitability(t, st, e);
  double r3(double v) => (v * 1000).round() / 1000;
  return {
    'stack': stack,
    'iters': it,
    'seconds': sw.elapsed.inMilliseconds / 1000,
    'exploitability': [for (final v in g) r3(v * 1000) / 1000],
    'freq': {
      for (var n = 0; n < 6; n++) nodeNames[n]: [for (final v in st[n]) r3(v)]
    },
    'edge': {
      for (var n = 0; n < 6; n++)
        nodeNames[n]: [for (final v in e.ev[n]) r3(v - foldValue[n])]
    },
    // Probability (0..1) the node is reached, over all deals.
    'reach': {
      for (var n = 0; n < 6; n++)
        nodeNames[n]: () {
          var r = 0.0, tot = 0.0;
          for (var h = 0; h < nH; h++) {
            r += e.reach[n][h];
            tot += t.marg[h];
          }
          return r3(r / tot);
        }()
    },
  };
}

double pctCombos(List<num> freq) {
  var c = 0.0;
  for (var i = 0; i < nH; i++) {
    c += freq[i] * HandClass.byIndex(i).comboCount;
  }
  return c / 1326;
}

void _selfTest() {
  final rng = Random(7);
  final a = Int32List(7), b = Int32List(7);
  var bad = 0;
  for (var n = 0; n < 300000; n++) {
    final deck = List<int>.generate(52, (i) => i)..shuffle(rng);
    for (var i = 0; i < 7; i++) {
      a[i] = deck[i];
      b[i] = deck[i + 7];
    }
    final f = eval7(a).compareTo(eval7(b));
    final r = ref.evaluate(a.toList()).compareTo(ref.evaluate(b.toList()));
    if (f != r) bad++;
  }
  stderr.writeln('selftest: $bad mismatches in 300000 comparisons');
  if (bad > 0) exit(1);
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) return _selfTest();
  if (args.contains('--bench')) {
    final sw = Stopwatch()..start();
    final t = Tables.load(_cachePath(int.parse(args[1]), int.parse(args[2])));
    stderr.writeln('load ${sw.elapsedMilliseconds}ms');
    sw.reset();
    final r = solveStack(t, int.parse(args[5]), int.parse(args[3]),
        mode: args[4], checkEvery: 25, verbose: true);
    stderr.writeln('20 iters ${sw.elapsedMilliseconds}ms expl ${r['exploitability']}');
    return;
  }
  final samples3 = args.isNotEmpty ? int.parse(args[0]) : 300;
  final samples2 = args.length > 1 ? int.parse(args[1]) : 6000;
  final maxIters = args.length > 2 ? int.parse(args[2]) : 2000;
  final workers = Platform.numberOfProcessors;
  final total = Stopwatch()..start();
  final path = _cachePath(samples3, samples2);
  if (!File(path).existsSync()) {
    await _buildCache(path, samples3, samples2, workers);
  } else {
    stderr.writeln('using cached equities $path');
  }

  // Solve stacks in parallel isolates; each loads the cache itself.
  final results = <int, Map<String, dynamic>>{};
  final nWorkers = min(workers, stacks.length);
  await Future.wait([
    for (var w = 0; w < nWorkers; w++)
      Isolate.run(() {
        final t = Tables.load(path);
        return [
          for (var i = w; i < stacks.length; i += nWorkers)
            jsonEncode(solveStack(t, stacks[i], maxIters, checkEvery: 25))
        ];
      }).then((list) {
        for (final js in list) {
          final m = jsonDecode(js) as Map<String, dynamic>;
          results[m['stack'] as int] = m;
        }
      })
  ]);

  final hu = jsonDecode(File('assets/data/pushfold.json').readAsStringSync())
      as Map<String, dynamic>;
  final out = <String, dynamic>{
    'format': '3-handed push/fold (BTN, SB, BB), blinds 0.5/1, no ante, '
        'equal stacks = effective bb',
    'samplesPerTriple': samples3,
    'samplesPerMatchup': samples2,
    'nodes': nodeNames,
    'stacks': stacks,
    'exploitability': {},
    for (final n in nodeNames) n: {},
    for (final n in nodeNames) '${n}Edge': {},
  };
  stderr.writeln('stack  iters  expl(mbb: BTN/SB/BB)       '
      'BTN%  SBcall%  SBjam%  BBvBTN%  BBover%  BBvSB%  | HU SBjam%  HU BBcall%');
  for (final stack in stacks) {
    final r = results[stack]!;
    final freq = r['freq'] as Map<String, dynamic>;
    final edge = r['edge'] as Map<String, dynamic>;
    for (final n in nodeNames) {
      out[n]['$stack'] = freq[n];
      out['${n}Edge']['$stack'] = edge[n];
    }
    out['exploitability']['$stack'] = r['exploitability'];
    String p(String n) => (pctCombos((freq[n] as List).cast<num>()) * 100)
        .toStringAsFixed(1)
        .padLeft(6);
    final huJam = (pctCombos((hu['sbJam']['$stack'] as List).cast<num>()) * 100)
        .toStringAsFixed(1);
    final huCall = (pctCombos((hu['bbCall']['$stack'] as List).cast<num>()) * 100)
        .toStringAsFixed(1);
    stderr.writeln('${'$stack'.padLeft(5)}  ${'${r['iters']}'.padLeft(5)}  '
        '${(r['exploitability'] as List).map((v) => ((v as num) * 1000).toStringAsFixed(2)).join('/').padRight(24)} '
        '${p('btnJam')}  ${p('sbCallVsBtn')}  ${p('sbJamVsBb')}  '
        '${p('bbCallVsBtn')}  ${p('bbOvercall')}  ${p('bbCallVsSb')}  | '
        '${huJam.padLeft(6)}  ${huCall.padLeft(6)}   (${r['seconds']}s)');
  }
  final f = File('assets/data/pushfold3.json');
  f.writeAsStringSync(jsonEncode(out));
  stderr.writeln('wrote ${f.path} (${f.lengthSync()} bytes) '
      'in ${total.elapsed.inSeconds}s wall');
}
