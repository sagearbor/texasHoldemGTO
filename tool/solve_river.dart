// Heads-up RIVER library builder: BB (out of position) vs BTN (in position),
// solved with CFR+ (tool/river_cfr.dart) on ~250 boards across textures, in
// two preflop lines:
//
//   srp: single-raised pot. BTN opens, BB flat-calls. Stack behind 3 pots.
//        BB: Check | Bet 33% | Bet 75%;  BTN vs check: Check | 33 | 75 | 150%.
//   3bp: 3-bet pot. BTN opens, BB 3-bets, BTN calls. Stack behind 1.5 pots.
//        BB: Check | Bet 33% | Bet 75%;  BTN vs check: Check | 33 | 75%.
// Every bet can be raised all-in (BB's check-raise, BTN's raise of a lead),
// and an all-in can be called or folded.
//
// SIMPLIFIED RANGES: the ranges are the app's preflop charts (themselves
// approximations; see lib/gto/spots.dart), weighted by preflop frequency,
// with only the combos blocked by the river board removed. Real river ranges
// are narrowed by flop/turn play, so absolute frequencies are illustrative;
// the structure (value vs bluff, blockers, polarisation, pot odds) is what
// the feature teaches.
//
// Every board is solved until the exploitability of the solver's average
// strategy is <= [targetExpl] % of the pot (or [maxIters]). The strategy is
// then quantised to whole percents (what the app stores and shows) and the
// exploitability of THAT stored strategy is measured and recorded as well.
//
// Output: assets/data/rivers.bin =
//   'FNRV' | u32 LE header length | UTF-8 JSON header | blob.
// Header: presets (range weights per hand class, node list with metadata)
// and boards (board, texture, preset, exploitability, stats, node reach
// frequency, byte offset/length into the blob). Per board the blob holds
// one byte per combo of raw equity (OOP then IP combos), then for each node
// in preset order, for each combo of the acting player that can reach the
// node under the stored strategy, the first k-1 action percentages.
// Combos are enumerated as in lib/gto/river.dart: hand classes in index
// order with weight > 0, HandClass.combos() order, board-blocked removed.
//
// Run: dart compile exe tool/solve_river.dart -o tool/.cache/solve_river
//      tool/.cache/solve_river [workers=10] [maxBoards]
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/range_parser.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/poker/evaluator.dart';

import 'river_cfr.dart';

const targetExpl = 0.003; // % of the pot
const maxIters = 8000;

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
// BTN vs BB 3-bet (hand-authored approximation in spots.dart).
const _btnVs3bet4bet = 'KK+, QQ:0.7, AKs, AKo:0.8, A5s:0.5, A4s:0.4, A3s:0.2';
const _btnVs3betCall = 'QQ:0.3, JJ-55, 44:0.6, 33:0.4, 22:0.3, AKo:0.2, '
    'AQs-A7s, A6s:0.6, A5s-A2s:0.4, KQs-K9s, QJs-Q9s, JTs-J9s, T9s, T8s:0.5, '
    '98s, 97s:0.3, 87s, 76s, 65s:0.8, 54s:0.5, AQo, AJo:0.6, ATo:0.3, '
    'KQo:0.6, KJo:0.25';

/// The 40 boards of the first river library (kept for continuity).
const legacyBoards = [
  'AsKd7c4h2s', 'KhQd6c3s2h', 'AdJc8s5h2d', 'KcTd7h3s2c', 'QsKd8h4d2c',
  'AhTc7d4s2h', 'KdJs7c4h2d', 'AcQd9h5s3c', 'KsKd7c4h2s', '8h8d3cAsJd',
  'QcQh6d4s9c', '5s5dKh9c2d', 'AhAd9c6s3h', 'TdTc4h2sKc', '7c7hJd3s2d',
  'JsJcAd8h4s', 'AsJs7s4d2h', 'Kh9h5h3c2d', 'QdTd4d8c2s', '9c6c3cKdAh',
  'Js8s3sTh2s', 'AhKh6h2h9c', 'Td7d2dKs5h', '8s5s2sQhJd', '9h8d7c6s2h',
  'JsTd9c8h3s', 'KdQsJhTc5d', '6c5d4h3sKh', '7s6d5h4cAd', 'AdKcQhJs4d',
  'Tc9h8d6s2c', '5h4d3c2sKs', '7h6d4c2sKh', '6h5d3c2sTh', '8c7d5h2sQd',
  '9d7c6h3s2d', '5c4h3d9sJc', '8h6d5c2sKs', '7d5s4c2hJh', '9s8c6d3h2c',
];

const textures = [
  'Dry high',
  'Paired',
  'Flush possible',
  'Four to a straight',
  'Straight possible',
  'Low connected',
];

/// Texture of a 5-card board, or null for boards outside the library's
/// categories (e.g. dry middling boards).
String? textureOf(List<int> b) {
  final ranks = [for (final c in b) cardRank(c)];
  final suits = List<int>.filled(4, 0);
  for (final c in b) {
    suits[cardSuit(c)]++;
  }
  final distinct = ranks.toSet();
  if (distinct.length < 5) return 'Paired';
  if (suits.reduce(max) >= 3) return 'Flush possible';
  // Most distinct board ranks inside one 5-rank straight window (the wheel
  // window A-5 counts for four to a straight only: A-2-4 with a king on
  // top still reads as a dry board).
  var best = 0, bestNoWheel = 0;
  for (var lo = -1; lo <= 8; lo++) {
    var n = 0;
    for (var r = lo; r < lo + 5; r++) {
      if (distinct.contains(r < 0 ? 12 : r)) n++;
    }
    best = max(best, n);
    if (lo >= 0) bestNoWheel = max(bestNoWheel, n);
  }
  if (best >= 4) return 'Four to a straight';
  final high = ranks.reduce(max);
  if (bestNoWheel == 3) {
    return high <= 7 ? 'Low connected' : 'Straight possible';
  }
  if (high >= 10) return 'Dry high';
  return null;
}

class Preset {
  final String id, label, line;
  final TreeSpec tree;
  final List<int> oopW, ipW; // per hand class, percent
  final Map<String, int> quota;
  Preset(this.id, this.label, this.line, this.tree, this.oopW, this.ipW,
      this.quota);
}

List<int> pctWeights(Map<int, double> r) =>
    [for (var i = 0; i < 169; i++) ((r[i] ?? 0) * 100).round().clamp(0, 100)];

List<Preset> presets() {
  final open = parseRange(_btnOpen);
  final three = parseRange(_bb3bet), def = parseRange(_bbDefend);
  final flat = <int, double>{};
  def.forEach((k, v) {
    final c = v - (three[k] ?? 0);
    if (c > 0.001) flat[k] = c;
  });
  final fb = parseRange(_btnVs3bet4bet), call = parseRange(_btnVs3betCall);
  final btnCall = <int, double>{};
  for (var i = 0; i < 169; i++) {
    final c = min(call[i] ?? 0, 1 - (fb[i] ?? 0));
    final w = (open[i] ?? 0) * c;
    if (w > 0.001) btnCall[i] = w;
  }
  return [
    Preset(
      'srp',
      'Single-raised pot',
      'BTN opened and BB called.',
      const TreeSpec(stack: 3, leads: [0.33, 0.75], ipBets: [0.33, 0.75, 1.5]),
      pctWeights(flat),
      pctWeights(open),
      {
        'Dry high': 32,
        'Paired': 32,
        'Flush possible': 32,
        'Four to a straight': 30,
        'Straight possible': 30,
        'Low connected': 30,
      },
    ),
    Preset(
      '3bp',
      '3-bet pot',
      'BTN opened, BB 3-bet and BTN called.',
      const TreeSpec(stack: 1.5, leads: [0.33, 0.75], ipBets: [0.33, 0.75]),
      pctWeights(three),
      pctWeights(btnCall),
      {for (final t in textures) t: 12},
    ),
  ];
}

/// Boards per preset: legacy boards first (SRP only), then seeded random
/// boards until every texture quota is filled.
Map<String, List<(String, String)>> pickBoards(List<Preset> ps) {
  final out = <String, List<(String, String)>>{};
  final used = <String>{};
  String key(List<int> b) => (List.of(b)..sort()).join(',');
  for (final p in ps) {
    final have = <String, int>{};
    final list = <(String, String)>[];
    void tryAdd(List<int> b) {
      final t = textureOf(b);
      if (t == null || (have[t] ?? 0) >= p.quota[t]!) return;
      if (!used.add('${p.id}:${key(b)}')) return;
      have[t] = (have[t] ?? 0) + 1;
      list.add(([for (final c in b) cardToString(c)].join(), t));
    }

    if (p.id == 'srp') {
      for (final s in legacyBoards) {
        tryAdd(parseCards(s));
      }
    }
    final rng = Random(p.id == 'srp' ? 2026 : 3003);
    var guard = 0;
    while (list.length < p.quota.values.reduce((a, b) => a + b)) {
      if (++guard > 1000000) throw StateError('quota not reachable');
      final deck = List<int>.generate(52, (i) => i)..shuffle(rng);
      final b = deck.sublist(0, 5)
        ..sort((x, y) => y.compareTo(x)); // high card first
      tryAdd(b);
    }
    out[p.id] = list;
  }
  return out;
}

Side buildSide(List<int> pct, List<int> board) {
  final s = Side();
  final bset = board.toSet();
  final str = <int>[];
  for (var k = 0; k < 169; k++) {
    if (pct[k] <= 0) continue;
    for (final c in HandClass.byIndex(k).combos()) {
      if (bset.contains(c[0]) || bset.contains(c[1])) continue;
      s.c1.add(c[0]);
      s.c2.add(c[1]);
      s.cls.add(k);
      s.w.add(pct[k] / 100);
      str.add(evaluate([c[0], c[1], ...board]));
    }
  }
  s.finish(str);
  return s;
}

double r3(double v) => (v * 1000).round() / 1000;
double r4(double v) => (v * 10000).round() / 10000;

/// Node metadata shared by every board of a preset.
List<Map<String, dynamic>> nodeMeta(Node root) {
  final paths = ownerPaths(root);
  final (src, resp) = betLinks(root);
  return [
    for (final n in decisionNodes(root))
      {
        'id': n.id,
        'player': n.player == oop ? 'oop' : 'ip',
        'actions': n.actions,
        'reach': paths[n.id],
        'facing': n.facing,
        'heroIn': n.heroIn,
        if (src[n.id] != null) 'src': src[n.id],
        if (resp[n.id] != null)
          'resp': {for (final e in resp[n.id]!.entries) '${e.key}': e.value},
      }
  ];
}

(Map<String, dynamic>, Uint8List) solveBoard(
    Preset p, String boardStr, String texture) {
  final board = parseCards(boardStr);
  final so = buildSide(p.oopW, board), si = buildSide(p.ipW, board);
  linkSides(so, si);
  final root = buildTree(p.tree);
  final g = Game([so, si], root)..init();
  final (iters, trace) =
      g.solve(maxIters: maxIters, minIters: 1000, target: targetExpl);
  final explSolver = g.exploitability() * 100;

  // Quantise to whole percents and fix those strategies.
  final nodes = decisionNodes(root);
  final q = <String, List<List<int>>>{};
  for (final n in nodes) {
    final avg = g.average(n);
    final m = g.sides[n.player].n;
    final rows = [
      for (var i = 0; i < m; i++) pctRound([for (final a in avg) a[i]])
    ];
    q[n.id!] = rows;
  }
  for (final n in nodes) {
    final rows = q[n.id!]!;
    n.fixed = [
      for (var a = 0; a < n.actions.length; a++)
        Float64List.fromList([for (final r in rows) r[a] / 100])
    ];
  }
  final explStored = g.exploitability() * 100;
  final evO = g.oopValue();

  // Owner reach (stored strategy) and two-sided arrival frequency per node.
  final paths = ownerPaths(root);
  final byId = {for (final n in nodes) n.id!: n};
  Float64List ownerReach(Node n) {
    final r = Float64List.fromList(g.sides[n.player].w);
    for (final st in paths[n.id]!) {
      final rows = q[st[0] as String]!;
      final a = st[1] as int;
      for (var i = 0; i < r.length; i++) {
        r[i] *= rows[i][a] / 100;
      }
    }
    return r;
  }

  final pairs = g.pairs;
  final arrival = <String, double>{};
  void walk(Node n, Float64List rO, Float64List rI) {
    if (n.kind != 0) return;
    arrival[n.id!] = dot(g.oppMass(oop, rI), rO) / pairs;
    final s = n.fixed!;
    for (var a = 0; a < n.actions.length; a++) {
      final mine = n.player == oop ? rO : rI;
      final nr = Float64List.fromList(
          [for (var i = 0; i < mine.length; i++) mine[i] * s[a][i]]);
      walk(n.children[a], n.player == oop ? nr : rO, n.player == oop ? rI : nr);
    }
  }

  walk(root, g.wO, g.wI);

  // ---- blob ----
  final bytes = BytesBuilder();
  final wO = g.wO, wI = g.wI;
  Float64List eqVs(int pl, Float64List oppR) {
    final (lo, hi) = g.beatMass(pl, oppR);
    final m = g.oppMass(pl, oppR);
    return Float64List.fromList([
      for (var i = 0; i < lo.length; i++)
        m[i] > 0 ? (lo[i] + 0.5 * (m[i] - lo[i] - hi[i])) / m[i] : 0
    ]);
  }

  final eqO = eqVs(oop, wI), eqI = eqVs(ip, wO);
  bytes.add([for (final e in eqO) (e * 100).round()]);
  bytes.add([for (final e in eqI) (e * 100).round()]);
  var stored = 0;
  for (final n in nodes) {
    final r = ownerReach(n);
    final rows = q[n.id!]!;
    final k = n.actions.length;
    for (var i = 0; i < r.length; i++) {
      if (r[i] <= 0) continue;
      bytes.add(rows[i].sublist(0, k - 1));
      stored++;
    }
  }

  // ---- range-level stats (from the stored strategy) ----
  double sum(List<double> a) => a.fold(0.0, (x, y) => x + y);
  Float64List blockShare(int pl, Float64List oppR) {
    final m = g.oppMass(pl, oppR);
    final tot = sum(oppR);
    return Float64List.fromList([for (final x in m) tot > 0 ? 1 - x / tot : 0]);
  }

  Map<String, num> betStats(int pl, Float64List reach, Float64List bet,
      Float64List notBet, Float64List cont) {
    final eq = eqVs(pl, cont);
    final blk = blockShare(pl, cont);
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
      'bluffBlock': bluffW > 0 ? r3(bluffBlk / bluffW) : 0,
      'giveUpBlock': giveW > 0 ? r3(giveBlk / giveW) : 0,
    };
  }

  // Per-node range frequencies are recomputed by the app from the stored
  // strategy (RiverBoard.rangeFreqs); only what needs the opponent's
  // continuing range or the solver's EVs is stored.
  final stats = <String, dynamic>{
    'oopEquity': r3(dot(eqO, so.w) / sum(so.w)),
    'oopEvShare': r3(0.5 + evO),
  };
  // Bet stats: for each bet action at root / ipVsCheck, versus the
  // opponent's continuing range at the response node.
  for (final (bettorId, pl) in [('root', oop), ('ipVsCheck', ip)]) {
    final n = byId[bettorId]!;
    final reach = ownerReach(n);
    final check = n.fixed![0];
    for (var a = 1; a < n.actions.length; a++) {
      final resp = n.children[a];
      final rr = ownerReach(resp);
      final fold = resp.fixed![0];
      final cont = Float64List.fromList(
          [for (var j = 0; j < rr.length; j++) rr[j] * (1 - fold[j])]);
      final name = n.actions[a].replaceAll(RegExp(r'[^0-9]'), '');
      stats['${pl == oop ? 'oop' : 'ip'}Bet$name'] =
          betStats(pl, reach, n.fixed![a], check, cont);
    }
  }

  final blob = bytes.toBytes();
  return (
    {
      'board': boardStr,
      'texture': texture,
      'preset': p.id,
      'iterations': iters,
      'exploitabilityPctPot': r4(explSolver),
      'storedExploitabilityPctPot': r4(explStored),
      'arrival': [for (final n in nodes) r4(arrival[n.id!]!)],
      'stats': stats,
      'nOop': so.n,
      'nIp': si.n,
      'stored': stored,
      'trace': trace,
    },
    blob
  );
}

Future<void> main(List<String> args) async {
  final workers = args.isNotEmpty ? int.parse(args[0]) : 10;
  final maxBoards = args.length > 1 ? int.parse(args[1]) : 100000;
  final ps = presets();
  final picks = pickBoards(ps);
  final jobs = <(int, String, String)>[];
  for (var pi = 0; pi < ps.length; pi++) {
    for (final (b, t) in picks[ps[pi].id]!) {
      jobs.add((pi, b, t));
    }
  }
  if (jobs.length > maxBoards) {
    // Spread a short run across presets.
    final step = jobs.length / maxBoards;
    final keep = [for (var k = 0; k < maxBoards; k++) jobs[(k * step).floor()]];
    jobs
      ..clear()
      ..addAll(keep);
  }
  stderr.writeln('${jobs.length} boards, $workers workers');
  final sw = Stopwatch()..start();
  final results = List<(Map<String, dynamic>, Uint8List)?>.filled(jobs.length, null);
  final futures = <Future<void>>[];
  for (var w = 0; w < workers; w++) {
    final mine = [for (var k = w; k < jobs.length; k += workers) k];
    final myJobs = [for (final k in mine) jobs[k]];
    futures.add(Isolate.run(() {
      final ps = presets();
      return [
        for (final (pi, b, t) in myJobs)
          () {
            final t0 = DateTime.now();
            final r = solveBoard(ps[pi], b, t);
            stderr.writeln('${ps[pi].id} $b ($t): it ${r.$1['iterations']} '
                'expl ${r.$1['exploitabilityPctPot']}% stored '
                '${r.$1['storedExploitabilityPctPot']}% '
                '${r.$2.length}B '
                '[${DateTime.now().difference(t0).inMilliseconds / 1000}s]');
            return r;
          }()
      ];
    }).then((rs) {
      for (var x = 0; x < mine.length; x++) {
        results[mine[x]] = rs[x];
      }
    }));
  }
  await Future.wait(futures);

  final blob = BytesBuilder();
  final boards = <Map<String, dynamic>>[];
  for (final r in results) {
    final (meta, b) = r!;
    meta['offset'] = blob.length;
    meta['length'] = b.length;
    meta.remove('trace');
    blob.add(b);
    boards.add(meta);
  }
  num maxOf(String k) =>
      boards.map((b) => b[k] as num).reduce((a, b) => a > b ? a : b);
  final header = jsonEncode({
    'format': 'HU river, BB (OOP) vs BTN (IP). Pot = 1 at the start of the '
        'river. Simplified ranges: the app\'s preflop charts minus board '
        'blockers.',
    'solver': 'CFR+ (regret-matching+, alternating updates, linear '
        'averaging), exact card removal, solved to <= $targetExpl% of the '
        'pot exploitability (cap $maxIters iterations); strategies stored '
        'rounded to 1%.',
    'targetExplPctPot': targetExpl,
    'solveSeconds': sw.elapsed.inSeconds,
    'maxExploitabilityPctPot': maxOf('exploitabilityPctPot'),
    'maxStoredExploitabilityPctPot': maxOf('storedExploitabilityPctPot'),
    'presets': [
      for (final p in ps)
        {
          'id': p.id,
          'label': p.label,
          'line': p.line,
          'stack': p.tree.stack,
          'oopRange': p.oopW,
          'ipRange': p.ipW,
          'nodes': nodeMeta(buildTree(p.tree)),
        }
    ],
    'boards': boards,
  });
  final hb = utf8.encode(header);
  final out = BytesBuilder()
    ..add(ascii.encode('FNRV'))
    ..add((ByteData(4)..setUint32(0, hb.length, Endian.little))
        .buffer
        .asUint8List())
    ..add(hb)
    ..add(blob.toBytes());
  final f = File('assets/data/rivers.bin');
  f.writeAsBytesSync(out.toBytes());
  stderr.writeln('wrote ${f.path} (${f.lengthSync()} bytes, header '
      '${hb.length}) ${boards.length} boards in ${sw.elapsed.inSeconds}s; '
      'max expl ${maxOf('exploitabilityPctPot')}% stored '
      '${maxOf('storedExploitabilityPctPot')}%');
}
