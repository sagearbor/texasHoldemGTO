// Validation gates on the shipped solved dataset (data/solved/preflop.json,
// produced by tool/solve_all.sh). The same gates run in the pipeline
// (tool/solver/validate.py); a spot that fails any of them ships with
// passed = false and the app keeps its old chart.
import 'dart:convert';
import 'dart:io';

import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/daily.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final data = jsonDecode(File(solvedPreflopAsset).readAsStringSync())
      as Map<String, dynamic>;
  final raw = data['spots'] as Map<String, dynamic>;
  final passed = {
    for (final e in raw.entries)
      if ((e.value as Map)['passed'] == true) e.key: e.value as Map
  };
  final base = buildCashSpots();
  final solved = applySolvedSpots(base, data);
  Spot byId(String id) => solved.firstWhere((s) => s.id == id);
  double f(Spot s, String h, int a) => s.freqs(HandClass.parse(h))[a];

  test('dataset is licensed, attributed and documented', () {
    expect(data['license'], startsWith('CC BY 4.0'));
    expect(File('data/solved/README.md').existsSync(), isTrue);
    expect(File('data/solved/LICENSE-DATA').existsSync(), isTrue);
    expect(File('data/solved/postflop.json').existsSync(), isTrue);
  });

  test('solved spots replace the charts in place, ids and order stable', () {
    expect(solved.map((s) => s.id), base.map((s) => s.id));
    for (var i = 0; i < base.length; i++) {
      final s = solved[i];
      expect(s.group, base[i].group);
      expect(s.actions, base[i].actions);
      expect(s.solved, passed.containsKey(s.id), reason: s.id);
      if (!passed.containsKey(s.id)) expect(identical(s, base[i]), isTrue);
    }
    expect(passed, isNotEmpty);
  });

  test('rows are distributions; solved notes carry exploitability', () {
    for (final id in passed.keys) {
      final s = byId(id);
      expect(s.strategy, hasLength(169));
      for (final row in s.strategy) {
        expect(row.fold<double>(0, (a, b) => a + b), closeTo(1, 1e-6));
        expect(row.every((x) => x >= 0), isTrue);
      }
      expect(s.exploitabilityBb, isNotNull);
      expect(s.exploitabilityBb!, lessThan(0.001), reason: id);
      expect(s.solverNote, contains('Solved by Felt Notes'));
      expect(s.solverNote, contains('bb per hand'));
      expect(s.situation, isNot(contains('Approximate')));
    }
  });

  test('the opener range in the data is the app RFI chart', () {
    for (final id in passed.keys.where((k) => k.startsWith('cash-3b'))) {
      final s = byId(id);
      final rfi = rfiReach(s.hero);
      for (var i = 0; i < 169; i++) {
        expect(s.reach![i], closeTo(rfi[i], 1e-3), reason: '$id $i');
      }
    }
  });

  test('gate: AA and KK never fold (BB vs a limper: always raise)', () {
    for (final id in passed.keys) {
      final s = byId(id);
      for (final h in ['AA', 'KK']) {
        if (s.passiveIndex == s.actions.indexOf('Check')) {
          expect(f(s, h, 0), greaterThanOrEqualTo(0.999), reason: '$id $h');
        } else {
          expect(f(s, h, s.passiveIndex), lessThanOrEqualTo(0.001),
              reason: '$id $h');
        }
      }
    }
  });

  test('gate: the preflop/postflop iteration has settled', () {
    for (final e in passed.entries) {
      final d = e.value['fixedPointDelta'] as num?;
      expect(d, isNotNull, reason: e.key);
      expect(d!, lessThanOrEqualTo(0.05), reason: e.key);
    }
  });

  test('gate: trash never iso-raises a limper', () {
    for (final id in passed.keys.where((k) => k.startsWith('cash-limp'))) {
      for (final h in ['72o', '82o', '92o', '32o', '42o', '83o', 'T2o', 'J3o']) {
        expect(f(byId(id), h, 0), lessThanOrEqualTo(0.01), reason: '$id $h');
      }
    }
  });

  test('gate: SB vs a limper mixes suited connectors', () {
    const id = 'cash-limp1-SB';
    if (!passed.containsKey(id)) return; // failed gate: chart kept
    final s = byId(id);
    expect(f(s, '86s', 1), lessThan(0.99));
    final mixed = ['54s', '65s', '76s', '87s', '98s', 'T9s', '75s', '86s', '97s']
        .where((h) => s.freqs(HandClass.parse(h)).reduce((a, b) => a > b ? a : b) <= 0.9);
    expect(mixed.length, greaterThanOrEqualTo(2));
  });

  test('gate: a solved CO vs a limper plays tighter than the BTN', () {
    if (!passed.containsKey('cash-limp1-CO')) return; // chart kept
    double share(Spot s, int a, {bool not = false}) =>
        allHandClasses.fold(
            0.0,
            (x, h) =>
                x + h.comboCount * (not ? 1 - s.freqs(h)[a] : s.freqs(h)[a])) /
        1326;
    final co = byId('cash-limp1-CO');
    final btnRaw = raw['cash-limp1-BTN'] as Map<String, dynamic>;
    final btn = applySolvedSpots(
        base, {'spots': {'cash-limp1-BTN': {...btnRaw, 'passed': true}}})
        .firstWhere((s) => s.id == 'cash-limp1-BTN');
    expect(share(co, 2, not: true), lessThan(share(btn, 2, not: true) - 0.002));
    expect(share(co, 0), lessThanOrEqualTo(share(btn, 0) + 0.002));
  });

  test('gate: AA and KK 4-bet facing a 3-bet', () {
    for (final id in passed.keys.where((k) => k.startsWith('cash-3b'))) {
      final s = byId(id);
      expect(f(s, 'AA', 0) + f(s, 'KK', 0), greaterThanOrEqualTo(1.0),
          reason: id);
    }
  });

  test('the bundled asset reaches SpotLibrary.load()', () async {
    final lib = await SpotLibrary.load();
    for (final id in passed.keys) {
      final s = lib.byId(id);
      expect(s.solved, isTrue, reason: id);
      expect(s.solverNote, contains('Solved by Felt Notes'), reason: id);
    }
    expect(lib.byId('cash-limp2-BTN').solved, isFalse);
  });

  test('solved groups stay out of the Daily 10', () {
    for (final id in passed.keys) {
      expect(dailyExcludedGroups.contains(byId(id).group), isTrue, reason: id);
    }
  });

  test('pipeline gates recorded in the file agree with passed', () {
    for (final e in raw.entries) {
      final m = e.value as Map;
      final gates = (m['gates'] as List).cast<Map>();
      expect(m['passed'], gates.every((g) => g['ok'] == true), reason: e.key);
    }
  });
}
