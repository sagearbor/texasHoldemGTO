// Heads-up push/fold Nash solver (SB jams or folds, BB calls or folds),
// blinds 0.5/1, no ante, for effective stacks 3..25bb.
//
// 1. Builds a 169x169 preflop all-in equity matrix by Monte Carlo, with
//    exact card-removal weights (number of non-overlapping combo pairs).
// 2. Runs fictitious play to an equilibrium per stack size.
// 3. Writes assets/data/pushfold.json with frequencies and the EV edge of
//    the aggressive action over folding (in bb) for every hand class.
//
// Run: dart run tool/solve_pushfold.dart [samplesPerMatchup]
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/poker/evaluator.dart';

void main(List<String> args) {
  final samples = args.isNotEmpty ? int.parse(args[0]) : 1500;
  final rng = Random(42);
  final combos = [for (final h in allHandClasses) h.combos()];

  final eq = List.generate(169, (_) => List<double>.filled(169, 0.5));
  final w = List.generate(169, (_) => List<double>.filled(169, 0));
  final sw = Stopwatch()..start();
  for (var i = 0; i < 169; i++) {
    for (var j = i; j < 169; j++) {
      final pairs = <List<List<int>>>[];
      for (final a in combos[i]) {
        for (final b in combos[j]) {
          if (a[0] == b[0] || a[0] == b[1] || a[1] == b[0] || a[1] == b[1]) {
            continue;
          }
          pairs.add([a, b]);
        }
      }
      w[i][j] = w[j][i] = pairs.length.toDouble();
      if (pairs.isEmpty) continue;
      var share = 0.0;
      for (var s = 0; s < samples; s++) {
        final p = pairs[rng.nextInt(pairs.length)];
        final used = {...p[0], ...p[1]};
        final board = <int>[];
        while (board.length < 5) {
          final c = rng.nextInt(52);
          if (used.add(c)) board.add(c);
        }
        final x = evaluate([...p[0], ...board]);
        final y = evaluate([...p[1], ...board]);
        share += x > y ? 1 : (x == y ? 0.5 : 0);
      }
      eq[i][j] = share / samples;
      eq[j][i] = 1 - eq[i][j];
    }
    if (i % 20 == 0) stderr.writeln('equity row $i/169 (${sw.elapsed.inSeconds}s)');
  }

  final stacks = [for (var s = 3; s <= 25; s++) s];
  final out = <String, dynamic>{
    'format': 'HU push/fold, blinds 0.5/1, no ante, stack = effective bb',
    'samplesPerMatchup': samples,
    'stacks': stacks,
    'sbJam': {},
    'bbCall': {},
    'sbJamEdge': {},
    'bbCallEdge': {},
    // Equity of each hand class vs a random hand (card-removal weighted).
    'vsRandom': [
      for (var i = 0; i < 169; i++)
        () {
          var num = 0.0, den = 0.0;
          for (var j = 0; j < 169; j++) {
            num += w[i][j] * eq[i][j];
            den += w[i][j];
          }
          return (num / den * 1000).round() / 1000;
        }()
    ],
  };

  for (final stack in stacks) {
    final s = stack.toDouble();
    var jam = List<double>.filled(169, 1);
    var call = List<double>.filled(169, 0.5);
    late List<double> jamEdge, callEdge;
    const iters = 3000;
    for (var t = 1; t <= iters; t++) {
      // BB best response to current SB jam range.
      callEdge = List<double>.filled(169, 0);
      final brCall = List<double>.filled(169, 0);
      for (var j = 0; j < 169; j++) {
        var num = 0.0, den = 0.0;
        for (var i = 0; i < 169; i++) {
          final ww = w[i][j] * jam[i];
          if (ww == 0) continue;
          num += ww * (eq[j][i] * 2 * s - s);
          den += ww;
        }
        final evCall = den > 0 ? num / den : -s;
        callEdge[j] = evCall - (-1);
        brCall[j] = callEdge[j] > 0 ? 1 : 0;
      }
      // SB best response to current BB call range.
      jamEdge = List<double>.filled(169, 0);
      final brJam = List<double>.filled(169, 0);
      for (var i = 0; i < 169; i++) {
        var num = 0.0, den = 0.0;
        for (var j = 0; j < 169; j++) {
          final ww = w[i][j];
          if (ww == 0) continue;
          num += ww * ((1 - call[j]) * 1 + call[j] * (eq[i][j] * 2 * s - s));
          den += ww;
        }
        jamEdge[i] = num / den - (-0.5);
        brJam[i] = jamEdge[i] > 0 ? 1 : 0;
      }
      final a = 1 / (t + 1);
      for (var k = 0; k < 169; k++) {
        jam[k] += a * (brJam[k] - jam[k]);
        call[k] += a * (brCall[k] - call[k]);
      }
    }
    double r3(double v) => (v * 1000).round() / 1000;
    out['sbJam']['$stack'] = [for (final v in jam) r3(v)];
    out['bbCall']['$stack'] = [for (final v in call) r3(v)];
    out['sbJamEdge']['$stack'] = [for (final v in jamEdge) r3(v)];
    out['bbCallEdge']['$stack'] = [for (final v in callEdge) r3(v)];
    final jamPct = _pct(jam), callPct = _pct(call);
    stderr.writeln('${stack}bb: SB jams ${(jamPct * 100).toStringAsFixed(1)}%,'
        ' BB calls ${(callPct * 100).toStringAsFixed(1)}%');
  }

  final f = File('assets/data/pushfold.json');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(jsonEncode(out));
  stderr.writeln('wrote ${f.path} in ${sw.elapsed.inSeconds}s');
}

double _pct(List<double> freq) {
  var c = 0.0;
  for (var i = 0; i < 169; i++) {
    c += freq[i] * HandClass.byIndex(i).comboCount;
  }
  return c / 1326;
}
