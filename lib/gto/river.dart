/// Pre-solved river spots (BB vs BTN; single-raised and 3-bet pots) computed
/// offline by tool/solve_river.dart with CFR+ and stored in
/// assets/data/rivers.bin (format described in that tool).
///
/// Every number and sentence here comes from the solver output: the coaching
/// is templated text filled from frequencies, equities and pot odds.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../poker/cards.dart';
import '../poker/evaluator.dart';
import 'coach.dart' show Grade, gradeFor, pct;
import 'hand_class.dart';

const riverOop = 0, riverIp = 1;
const riverSeatName = ['BB', 'BTN'];
const riverAsset = 'assets/data/rivers.bin';

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
}

/// A decision node of a preset's tree (same for every board of the preset).
class RiverNodeSpec {
  final String id;
  final int player;
  final List<String> actions;

  /// Owner's earlier decisions on the path: (nodeId, actionIndex).
  final List<(String, int)> path;

  /// Bet the player to act must match, and what it already put in (pots).
  final double facing, heroIn;

  /// The opponent's (node, action) that made the bet faced here.
  final (String, int)? src;

  /// Response node after each of this node's bet actions.
  final Map<int, String> resp;
  RiverNodeSpec(this.id, this.player, this.actions, this.path, this.facing,
      this.heroIn, this.src, this.resp);

  static RiverNodeSpec fromJson(Map<String, dynamic> j) {
    final src = j['src'] as List?;
    return RiverNodeSpec(
      j['id'] as String,
      j['player'] == 'oop' ? riverOop : riverIp,
      (j['actions'] as List).cast<String>(),
      [
        for (final p in j['reach'] as List)
          ((p as List)[0] as String, (p[1] as num).toInt())
      ],
      (j['facing'] as num).toDouble(),
      (j['heroIn'] as num).toDouble(),
      src == null ? null : (src[0] as String, (src[1] as num).toInt()),
      {
        for (final e in (j['resp'] as Map<String, dynamic>? ?? {}).entries)
          int.parse(e.key): e.value as String
      },
    );
  }
}

class RiverNode {
  final RiverNodeSpec spec;

  /// Flat per-combo frequencies, combo-major: s[i * k + a]. Combos that can
  /// never reach the node (reach 0) hold an even split: their strategy is
  /// undefined and never shown or graded.
  final List<double> s;
  RiverNode(this.spec, this.s);

  String get id => spec.id;
  int get player => spec.player;
  List<String> get actions => spec.actions;
  List<(String, int)> get path => spec.path;

  List<double> freqs(int combo) {
    final k = actions.length;
    return s.sublist(combo * k, combo * k + k);
  }
}

/// Short label and one-line description of the betting before a node.
(String, String) riverNodeInfo(String id) {
  final m = RegExp(r'^([a-zA-Z]+?)(\d*)$').firstMatch(id)!;
  final x = m.group(2)!;
  return switch (m.group(1)) {
    'root' => ('BB first to act', 'BB acts first on the river.'),
    'ipVsCheck' => ('BTN vs check', 'BB checks to you on the BTN.'),
    'ipVsBet' => ('BTN vs $x% bet', 'BB bets $x% of the pot.'),
    'oopVsBet' => ('BB vs $x% bet', 'You check, BTN bets $x% of the pot.'),
    'oopVsRaise' => ('BB vs all-in ($x% lead)', 'You bet $x%, BTN moves all-in.'),
    'ipVsRaise' => (
        'BTN vs check-raise ($x%)',
        'You bet $x%, BB check-raises all-in.'
      ),
    _ => (id, id),
  };
}

/// Equity needed to call at [n]: price / final pot (pot = 1 before betting).
double potOddsNeeded(RiverNodeSpec n) {
  if (n.facing <= n.heroIn) return 0;
  return (n.facing - n.heroIn) / (1 + 2 * n.facing);
}

class RiverPreset {
  final String id, label, line;
  final double stack;
  final List<int> oopRange, ipRange; // percent per hand class
  final List<RiverNodeSpec> nodes;
  RiverPreset(this.id, this.label, this.line, this.stack, this.oopRange,
      this.ipRange, this.nodes);

  static RiverPreset fromJson(Map<String, dynamic> j) => RiverPreset(
        j['id'] as String,
        j['label'] as String,
        j['line'] as String,
        (j['stack'] as num).toDouble(),
        (j['oopRange'] as List).cast<int>(),
        (j['ipRange'] as List).cast<int>(),
        [
          for (final n in j['nodes'] as List)
            RiverNodeSpec.fromJson(n as Map<String, dynamic>)
        ],
      );

  /// Combos of a range on [board], in the solver's order.
  static (List<int>, List<int>, List<double>) combosOn(
      List<int> range, List<int> board) {
    final c1 = <int>[], c2 = <int>[];
    final w = <double>[];
    for (var k = 0; k < 169; k++) {
      if (range[k] <= 0) continue;
      for (final c in HandClass.byIndex(k).combos()) {
        if (board.contains(c[0]) || board.contains(c[1])) continue;
        c1.add(c[0]);
        c2.add(c[1]);
        w.add(range[k] / 100);
      }
    }
    return (c1, c2, w);
  }
}

class RiverBoard {
  final String boardStr;
  final List<int> cards;
  final String texture;
  final RiverPreset preset;
  final Map<String, dynamic> stats;

  /// Exploitability of the solver's strategy, and of the stored one
  /// (rounded to whole percents), in % of the pot.
  final double exploitabilityPctPot, storedExploitabilityPctPot;
  final int iterations;

  /// Probability that play reaches each node (both players' strategies).
  final Map<String, double> arrival;
  final Uint8List _blob;
  final int _nOop, _nIp;
  RiverBoard(
      this.boardStr,
      this.texture,
      this.preset,
      this.stats,
      this.exploitabilityPctPot,
      this.storedExploitabilityPctPot,
      this.iterations,
      this.arrival,
      this._blob,
      this._nOop,
      this._nIp)
      : cards = parseCards(boardStr);

  List<RiverSide>? _sides;
  Map<String, RiverNode>? _nodes;

  List<RiverSide> get sides {
    _decode();
    return _sides!;
  }

  Map<String, RiverNode> get nodes {
    _decode();
    return _nodes!;
  }

  void _decode() {
    if (_sides != null) return;
    var o = 0;
    final sides = <RiverSide>[];
    for (final (range, n) in [
      (preset.oopRange, _nOop),
      (preset.ipRange, _nIp)
    ]) {
      final (c1, c2, w) = RiverPreset.combosOn(range, cards);
      if (c1.length != n) {
        throw StateError('$boardStr: ${c1.length} combos, expected $n');
      }
      sides.add(RiverSide(c1, c2, w, [for (var i = 0; i < n; i++) _blob[o + i] / 100]));
      o += n;
    }
    final nodes = <String, RiverNode>{};
    for (final spec in preset.nodes) {
      final side = sides[spec.player];
      final k = spec.actions.length;
      final s = List<double>.filled(side.n * k, 1 / k);
      for (var i = 0; i < side.n; i++) {
        var r = side.w[i];
        for (final (id, a) in spec.path) {
          r *= nodes[id]!.s[i * nodes[id]!.actions.length + a];
        }
        if (r <= 0) continue;
        var rest = 100;
        for (var a = 0; a < k - 1; a++) {
          final v = _blob[o++];
          s[i * k + a] = v / 100;
          rest -= v;
        }
        s[i * k + k - 1] = max(0, rest) / 100;
      }
      nodes[spec.id] = RiverNode(spec, s);
    }
    if (o != _blob.length) {
      throw StateError('$boardStr: decoded $o of ${_blob.length} bytes');
    }
    _sides = sides;
    _nodes = nodes;
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

  /// Reach-weighted strategy per hand class (null = class not in range, or
  /// never reaches this node).
  List<List<double>?> classStrategy(RiverNode n) {
    final side = sides[n.player];
    final r = reach(n);
    final k = n.actions.length;
    final sum = List<List<double>?>.filled(169, null);
    final wt = List<double>.filled(169, 0);
    for (var i = 0; i < side.n; i++) {
      if (r[i] <= 0) continue;
      final c = side.cls(i).index;
      final f = n.freqs(i);
      final acc = sum[c] ??= List<double>.filled(k, 0);
      for (var a = 0; a < k; a++) {
        acc[a] += r[i] * f[a];
      }
      wt[c] += r[i];
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

  double _stat(String key, String field) =>
      ((stats[key] as Map<String, dynamic>?)?[field] as num? ?? 0).toDouble();

  /// "Bet 75%" -> "75".
  static String _size(String action) =>
      action.replaceAll(RegExp(r'[^0-9]'), '');

  /// Template sentences describing the solved strategy, from numbers only.
  List<String> summary() {
    final out = <String>[];
    final root = nodes['root']!;
    final rf = rangeFreqs(root);
    final lead = 1 - rf[0];
    if (lead < 0.03) {
      out.add('BB almost never leads (${pct(lead)}): it checks its whole '
          'range and lets BTN act.');
    } else {
      out.add('BB leads ${pct(lead)} (${_sizes(root.actions, rf)}).');
      out.addAll(_mainSize('BB', 'BTN', 'oopBet', root.actions, rf));
    }
    final ivc = nodes['ipVsCheck']!;
    final cf = rangeFreqs(ivc);
    out.add('When checked to, BTN bets ${pct(1 - cf[0])} '
        '(${_sizes(ivc.actions, cf)}).');
    out.addAll(_mainSize('BTN', 'BB', 'ipBet', ivc.actions, cf));
    if (ivc.actions.length > 2) {
      out.add('Value share by bet size: ${[
        for (var a = 1; a < ivc.actions.length; a++)
          if (cf[a] > 0.01)
            '${_size(ivc.actions[a])}% → '
                '${pct(_stat('ipBet${_size(ivc.actions[a])}', 'valuePct'))}'
      ].join(', ')}. Bigger bets give the caller a worse price, so they '
          'carry more bluffs per value hand.');
    }
    if (lead >= 0.03) {
      var a = 1;
      for (var x = 2; x < root.actions.length; x++) {
        if (rf[x] > rf[a]) a = x;
      }
      final vb = nodes[root.spec.resp[a]!]!;
      final f = rangeFreqs(vb);
      out.add('Facing BB\'s ${_size(root.actions[a])}% lead, BTN folds '
          '${pct(f[0])}, calls ${pct(f[1])}'
          '${f.length > 2 ? ' and raises all-in ${pct(f[2])}' : ''}.');
    }
    // Defence vs BTN's largest bet.
    final big = ivc.actions.length - 1;
    final vsBig = nodes[ivc.spec.resp[big]!]!;
    final size = int.parse(_size(ivc.actions[big])) / 100;
    final def = 1 - rangeFreqs(vsBig)[0];
    final mdf = 1 / (1 + size);
    final bluff = _stat('ipBet${_size(ivc.actions[big])}', 'bluffPct');
    out.add('After checking, BB defends ${pct(def)} vs a '
        '${_size(ivc.actions[big])}% bet (minimum defence to stop any-two-card '
        'bluffs: ${pct(mdf)})'
        '${def < mdf - 0.03 && cf[big] > 0.01 ? ': it can fold more because '
            'only ${pct(bluff)} of those bets are bluffs' : ''}.');
    final eq = (stats['oopEquity'] as num).toDouble();
    final ev = (stats['oopEvShare'] as num).toDouble();
    out.add('BB\'s range has ${pct(eq)} raw equity and realises ${pct(ev)} '
        'of the pot${ev < eq ? ' (being out of position costs it ${pct(eq - ev)})' : ''}.');
    return out;
  }

  String _sizes(List<String> actions, List<double> f) => [
        for (var a = 1; a < actions.length; a++)
          '${_size(actions[a])}%: ${pct(f[a])}'
      ].join(', ');

  /// Value/bluff split and blockers of the most-used bet size.
  List<String> _mainSize(String hero, String villain, String prefix,
      List<String> actions, List<double> f) {
    var a = 1;
    for (var x = 2; x < actions.length; x++) {
      if (f[x] > f[a]) a = x;
    }
    if (f[a] < 0.03) return const [];
    final key = '$prefix${_size(actions[a])}';
    final b = int.parse(_size(actions[a])) / 100;
    final m = stats[key] as Map<String, dynamic>? ?? const {};
    return [
      '$hero\'s ${_size(actions[a])}% bets are ${pct(_stat(key, 'valuePct'))}'
          ' value and ${pct(_stat(key, 'bluffPct'))} bluffs (the caller needs '
          '${pct(b / (1 + 2 * b))} equity).',
      ..._blockerLine(hero, villain, m),
    ];
  }

  List<String> _blockerLine(
      String hero, String villain, Map<String, dynamic> m) {
    final bb = (m['bluffBlock'] as num? ?? 0).toDouble();
    final gb = (m['giveUpBlock'] as num? ?? 0).toDouble();
    if ((m['bluffPct'] as num? ?? 0) < 0.05 || gb <= 0) return const [];
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

  /// One line naming the solver and how exact this board's solution is.
  String get solverLine => 'Solved by Felt Notes with CFR+ '
      '($iterations iterations): exploitable for '
      '${exploitabilityPctPot.toStringAsFixed(3)}% of the pot '
      '(${storedExploitabilityPctPot.toStringAsFixed(3)}% after rounding to '
      'whole percents).';
}

class RiverLibrary {
  final List<RiverBoard> boards;
  final List<RiverPreset> presets;
  final String format;
  RiverLibrary(this.boards, this.presets, this.format);

  static RiverLibrary parse(Uint8List bytes) {
    if (ascii.decode(bytes.sublist(0, 4)) != 'FNRV') {
      throw const FormatException('not a river library');
    }
    final hl = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
    final j = jsonDecode(utf8.decode(bytes.sublist(8, 8 + hl)))
        as Map<String, dynamic>;
    final blob0 = 8 + hl;
    final presets = {
      for (final p in j['presets'] as List)
        (p as Map<String, dynamic>)['id'] as String: RiverPreset.fromJson(p)
    };
    return RiverLibrary(
      [
        for (final b in (j['boards'] as List).cast<Map<String, dynamic>>())
          () {
            final p = presets[b['preset']]!;
            final arr = (b['arrival'] as List).cast<num>();
            final off = blob0 + (b['offset'] as num).toInt();
            return RiverBoard(
              b['board'] as String,
              b['texture'] as String,
              p,
              b['stats'] as Map<String, dynamic>,
              (b['exploitabilityPctPot'] as num).toDouble(),
              (b['storedExploitabilityPctPot'] as num).toDouble(),
              (b['iterations'] as num).toInt(),
              {
                for (var k = 0; k < p.nodes.length; k++)
                  p.nodes[k].id: arr[k].toDouble()
              },
              Uint8List.sublistView(
                  bytes, off, off + (b['length'] as num).toInt()),
              (b['nOop'] as num).toInt(),
              (b['nIp'] as num).toInt(),
            );
          }()
      ],
      presets.values.toList(),
      j['format'] as String,
    );
  }

  static Future<RiverLibrary>? _cache;
  static Future<RiverLibrary> load() => _cache ??= rootBundle
      .load(riverAsset)
      .then((d) => RiverLibrary.parse(d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes)));

  double get maxExploitability =>
      boards.map((b) => b.exploitabilityPctPot).reduce(max);
  double get maxStoredExploitability =>
      boards.map((b) => b.storedExploitabilityPctPot).reduce(max);

  List<RiverBoard> boardsOf(String? preset) => preset == null
      ? boards
      : [for (final b in boards) if (b.preset.id == preset) b];
}

// ---------------------------------------------------------------- drill ----

/// Nodes reached less often than this (both players' strategies) are not
/// drilled: the hero's strategy there barely matters to the equilibrium.
const riverMinArrival = 0.02;

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

/// Random question. Boards are picked evenly across (preset, texture)
/// buckets so every line and texture is drilled equally, then a node the
/// hand reaches often enough, then a hero combo sampled by how often the
/// hand actually reaches that node. [preset] limits it to one line.
RiverQuestion randomRiverQuestion(RiverLibrary lib, Random rng,
    {String? preset}) {
  final buckets = <String, List<RiverBoard>>{};
  for (final b in lib.boardsOf(preset)) {
    (buckets['${b.preset.id}/${b.texture}'] ??= []).add(b);
  }
  final keys = buckets.keys.toList();
  for (;;) {
    final bs = buckets[keys[rng.nextInt(keys.length)]]!;
    final b = bs[rng.nextInt(bs.length)];
    final ids = [
      for (final s in b.preset.nodes)
        if (b.arrival[s.id]! >= riverMinArrival) s.id
    ];
    final n = b.nodes[ids[rng.nextInt(ids.length)]]!;
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

/// Showdown equity of the hero's combo vs opponent combos weighted by [w]
/// (card removal applied). Null when the weights are empty.
double? equityVsWeights(RiverQuestion q, List<double> w) =>
    comboEquityVs(q.board, q.node.player, q.combo, w);

/// Showdown equity of [player]'s combo [i] vs opponent weights [w].
double? comboEquityVs(RiverBoard b, int player, int i, List<double> w) {
  final opp = b.sides[1 - player];
  final me = b.sides[player];
  final h = [me.c1[i], me.c2[i]];
  final mine = evaluate([...h, ...b.cards]);
  var win = 0.0, tot = 0.0;
  for (var j = 0; j < opp.n; j++) {
    if (w[j] <= 0) continue;
    if (h.contains(opp.c1[j]) || h.contains(opp.c2[j])) continue;
    final s = evaluate([opp.c1[j], opp.c2[j], ...b.cards]);
    tot += w[j];
    if (mine > s) {
      win += w[j];
    } else if (mine == s) {
      win += w[j] / 2;
    }
  }
  return tot > 1e-9 ? win / tot : null;
}

/// Reach-weighted range that made the bet faced at [n], or null.
List<double>? bettorRange(RiverBoard b, RiverNode n) {
  final src = n.spec.src;
  if (src == null) return null;
  final p = b.nodes[src.$1]!;
  final r = b.reach(p);
  return [for (var j = 0; j < r.length; j++) r[j] * p.freqs(j)[src.$2]];
}

/// Equity vs the range that made the bet the hero is facing.
double? equityVsBettor(RiverQuestion q) {
  final w = bettorRange(q.board, q.node);
  return w == null ? null : equityVsWeights(q, w);
}

/// (opponent fold %, hero equity vs the continuing range) after the hero
/// bets with action [a] at the current node.
(double, double?)? afterBet(RiverQuestion q, int a) {
  final id = q.node.spec.resp[a];
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
List<String> riverCoach(RiverQuestion q, int chosen) {
  final notes = <String>[];
  final f = q.freqs;
  final stack = q.board.preset.stack;
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
  final need = potOddsNeeded(q.node.spec);
  if (need > 0) {
    final b = q.node.spec.facing;
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
