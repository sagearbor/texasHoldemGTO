/// Preflop spot library.
///
/// Two sources:
///  * 6-max 100bb cash: baseline ranges written from standard modern theory
///    (2.5x opens, 3x SB open, ~3x IP / ~3.5x OOP 3-bets). They are
///    approximations of solver output, labelled as such in the UI.
///  * Heads-up push/fold: true Nash equilibrium computed by
///    tool/solve_pushfold.dart (assets/data/pushfold.json).
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'hand_class.dart';
import 'range_parser.dart';

enum SpotFormat { cash100, pushFold }

class Spot {
  final String id;
  final SpotFormat format;
  final String group;
  final String title;

  /// One-line situation shown to the player, e.g. "Folds to you on the BTN".
  final String situation;
  final String hero;
  final String? villain;
  final List<String> actions;

  /// strategy[handIndex][actionIndex] = frequency. Rows sum to 1.
  final List<List<double>> strategy;

  /// Optional EV advantage (bb) of actions[0] over Fold, per hand.
  final List<double>? edge;
  final bool solved;

  Spot({
    required this.id,
    required this.format,
    required this.group,
    required this.title,
    required this.situation,
    required this.hero,
    this.villain,
    required this.actions,
    required this.strategy,
    this.edge,
    this.solved = false,
  });

  List<double> freqs(HandClass h) => strategy[h.index];

  /// Percent of all combos that take a non-fold action.
  double get playPercent {
    final foldIdx = actions.indexOf('Fold');
    var c = 0.0;
    for (final h in allHandClasses) {
      c += h.comboCount * (1 - strategy[h.index][foldIdx]);
    }
    return c / 1326;
  }
}

List<List<double>> _rfi(String raise) {
  final r = parseRange(raise);
  return [
    for (var i = 0; i < 169; i++) [r[i] ?? 0, 1 - (r[i] ?? 0)]
  ];
}

List<List<double>> _vsOpen(String threeBet, String defend) {
  final r = parseRange(threeBet), d = parseRange(defend);
  return [
    for (var i = 0; i < 169; i++)
      () {
        final rr = r[i] ?? 0;
        final dd = (d[i] ?? 0) > rr ? d[i]! : rr;
        return [rr, dd - rr, 1 - dd];
      }()
  ];
}

const _rfiRanges = {
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

/// (hero, villain) -> (3-bet range, total defend range).
const _vsOpenRanges = {
  ('HJ', 'UTG'): (
    'QQ+, JJ:0.3, AKs, AQs:0.3, A5s:0.4, AKo',
    '77+, 66:0.4, AJs+, ATs:0.6, A5s:0.4, KQs, KJs:0.6, QJs:0.5, JTs:0.4, AQo+'
  ),
  ('CO', 'UTG'): (
    'QQ+, JJ:0.3, AKs, AQs:0.4, A5s:0.4, AKo',
    '66+, 55:0.4, ATs+, A5s-A4s:0.6, KTs+, QTs+, JTs, T9s:0.6, AQo+, KQo:0.4'
  ),
  ('CO', 'HJ'): (
    'QQ+, JJ:0.5, AQs+, AJs:0.3, A5s-A4s:0.6, KQs:0.4, AKo, AQo:0.3',
    '55+, ATs+, A5s-A2s:0.6, KTs+, QTs+, JTs, T9s, 98s:0.5, AJo+, KQo:0.6'
  ),
  ('BTN', 'UTG'): (
    'QQ+, JJ:0.4, AKs, AQs:0.5, A5s:0.5, KQs:0.3, AKo',
    '22+, A9s+, A5s-A4s, KTs+, QTs+, JTs, T9s, 98s, 87s, 76s:0.6, AQo+, '
        'AJo:0.5, KQo:0.6'
  ),
  ('BTN', 'HJ'): (
    'JJ+, TT:0.4, AQs+, AJs:0.4, A5s-A4s:0.6, KQs:0.5, K9s:0.2, AKo, AQo:0.4',
    '22+, A7s+, A5s-A2s, K9s+, Q9s+, J9s+, T9s, 98s, 87s, 76s, 65s:0.6, '
        'AJo+, KQo, KJo:0.4'
  ),
  ('BTN', 'CO'): (
    'TT+, 99:0.4, AJs+, ATs:0.5, A5s-A3s:0.6, KQs, KJs:0.5, K9s:0.3, QJs:0.4, '
        'T8s:0.3, 76s:0.3, 65s:0.3, AQo+, AJo:0.4, KQo:0.4',
    '22+, A2s+, K8s+, Q9s+, J9s+, T8s+, 97s+, 86s+, 75s+, 65s, 54s, ATo+, '
        'KJo+, QJo, A9o:0.3, KTo:0.4'
  ),
  ('SB', 'UTG'): (
    'TT+, 99:0.5, AJs+, A5s:0.6, KQs, KJs:0.5, AQo+',
    'TT+, 99:0.5, AJs+, A5s:0.6, KQs, KJs:0.5, AQo+'
  ),
  ('SB', 'CO'): (
    '99+, 88:0.6, 77:0.3, ATs+, A5s-A4s:0.7, KTs+, QTs+, JTs, T9s:0.5, AJo+, '
        'KQo, ATo:0.3',
    '99+, 88:0.6, 77:0.3, ATs+, A5s-A4s:0.7, KTs+, QTs+, JTs, T9s:0.5, AJo+, '
        'KQo, ATo:0.3'
  ),
  ('SB', 'BTN'): (
    '88+, 77:0.6, 66:0.4, A9s+, A8s-A2s:0.6, KTs+, K9s:0.5, QTs+, JTs, '
        'J9s:0.4, T9s, 98s:0.6, 87s:0.4, 76s:0.4, ATo+, A9o:0.4, KQo, KJo:0.6, '
        'QJo:0.3',
    '88+, 77:0.6, 66:0.4, A9s+, A8s-A2s:0.6, KTs+, K9s:0.5, QTs+, JTs, '
        'J9s:0.4, T9s, 98s:0.6, 87s:0.4, 76s:0.4, ATo+, A9o:0.4, KQo, KJo:0.6, '
        'QJo:0.3'
  ),
  ('BB', 'UTG'): (
    'QQ+, JJ:0.3, AKs, A5s:0.5, A4s:0.4, KQs:0.2, 76s:0.2, AKo:0.6',
    '22+, A2s+, K5s+, Q8s+, J8s+, T8s+, 97s+, 86s+, 75s+, 65s, 54s, AJo+, '
        'ATo:0.6, KQo, KJo:0.5, QJo:0.4'
  ),
  ('BB', 'HJ'): (
    'QQ+, JJ:0.5, AKs, AQs:0.4, A5s-A4s:0.6, KQs:0.3, K9s:0.2, 65s:0.25, AKo',
    '22+, A2s+, K4s+, Q7s+, J8s+, T7s+, 97s+, 86s+, 75s+, 64s+, 54s, ATo+, '
        'A9o:0.4, KJo+, KTo:0.5, QJo, QTo:0.4, JTo:0.4'
  ),
  ('BB', 'CO'): (
    'JJ+, TT:0.5, AQs+, AJs:0.4, A5s-A2s:0.5, KQs:0.5, KJs:0.3, K9s:0.25, '
        'Q9s:0.25, J9s:0.25, T8s:0.25, 76s:0.3, 65s:0.3, AKo, AQo:0.5, KQo:0.25',
    '22+, A2s+, K2s+, Q4s+, J6s+, T6s+, 96s+, 85s+, 75s+, 64s+, 53s+, '
        '43s:0.6, A7o+, A6o:0.4, A5o:0.6, K9o+, K8o:0.5, Q9o+, J9o+, T9o, '
        '98o:0.5'
  ),
  ('BB', 'BTN'): (
    'QQ+, JJ:0.6, TT:0.3, AKs, AQs:0.6, A5s-A2s:0.5, KQs:0.4, K9s-K6s:0.25, '
        'Q9s:0.3, J9s:0.3, T8s:0.3, 97s:0.3, 86s:0.3, 75s:0.3, 64s:0.3, '
        '54s:0.3, AKo, AQo:0.4, A5o:0.3, KJo:0.3',
    '22+, A2s+, K2s+, Q2s+, J4s+, T5s+, 95s+, 85s+, 74s+, 63s+, 53s+, 42s+, '
        'A2o+, K5o+, K4o:0.5, Q7o+, Q6o:0.4, J7o+, T7o+, 97o+, 87o, 76o:0.6, '
        '65o:0.4'
  ),
  ('BB', 'SB'): (
    'TT+, 99:0.5, AJs+, ATs:0.5, A5s-A2s:0.5, KJs+, K9s-K5s:0.3, QJs:0.5, '
        'Q9s:0.3, J9s:0.4, T8s:0.4, 97s:0.4, 86s:0.4, 75s:0.4, AQo+, AJo:0.5, '
        'KQo:0.5, K9o:0.3, Q9o:0.3, J9o:0.3',
    '22+, A2s+, K2s+, Q2s+, J2s+, T4s+, 95s+, 84s+, 74s+, 63s+, 53s+, 43s, '
        'A2o+, K4o+, Q6o+, J7o+, T7o+, 97o+, 86o+, 76o, 65o:0.5'
  ),
};

const positions6max = ['UTG', 'HJ', 'CO', 'BTN', 'SB', 'BB'];

List<Spot> buildCashSpots() {
  final spots = <Spot>[];
  _rfiRanges.forEach((pos, range) {
    final folded = positions6max.sublist(0, positions6max.indexOf(pos));
    spots.add(Spot(
      id: 'cash-rfi-$pos',
      format: SpotFormat.cash100,
      group: 'Open (RFI)',
      title: '$pos open',
      situation: folded.isEmpty
          ? 'You are first to act from $pos.'
          : '${folded.join(', ')} fold to you on the $pos.',
      hero: pos,
      actions: [pos == 'SB' ? 'Raise 3bb' : 'Raise 2.5bb', 'Fold'],
      strategy: _rfi(range),
    ));
  });
  _vsOpenRanges.forEach((key, ranges) {
    final (hero, villain) = key;
    final threeOnly = hero == 'SB';
    spots.add(Spot(
      id: 'cash-$hero-vs-$villain',
      format: SpotFormat.cash100,
      group: 'Facing an open',
      title: '$hero vs $villain open',
      situation: '$villain opens ${villain == 'SB' ? '3bb' : '2.5bb'}'
          ' and it folds to you in the $hero.',
      hero: hero,
      villain: villain,
      actions: threeOnly ? ['3-bet', 'Fold'] : ['3-bet', 'Call', 'Fold'],
      strategy: threeOnly
          ? [
              for (final row in _vsOpen(ranges.$1, ranges.$2))
                [row[0], 1 - row[0]]
            ]
          : _vsOpen(ranges.$1, ranges.$2),
    ));
  });
  return spots;
}

Future<List<Spot>> loadPushFoldSpots() async {
  final data = jsonDecode(await rootBundle.loadString('assets/data/pushfold.json'))
      as Map<String, dynamic>;
  final spots = <Spot>[];
  for (final s in (data['stacks'] as List).cast<int>()) {
    if (s % 1 != 0) continue;
    List<double> l(String k) =>
        [for (final v in (data[k]['$s'] as List)) (v as num).toDouble()];
    final jam = l('sbJam'), call = l('bbCall');
    spots.add(Spot(
      id: 'pf-sb-$s',
      format: SpotFormat.pushFold,
      group: 'Push/fold ${s}bb',
      title: 'SB jam ${s}bb',
      situation: 'Heads-up, ${s}bb effective. You are in the SB.',
      hero: 'SB',
      villain: 'BB',
      actions: ['All-in', 'Fold'],
      strategy: [for (final f in jam) [f, 1 - f]],
      edge: l('sbJamEdge'),
      solved: true,
    ));
    spots.add(Spot(
      id: 'pf-bb-$s',
      format: SpotFormat.pushFold,
      group: 'Push/fold ${s}bb',
      title: 'BB vs SB jam ${s}bb',
      situation: 'Heads-up, ${s}bb effective. SB moves all-in.',
      hero: 'BB',
      villain: 'SB',
      actions: ['Call', 'Fold'],
      strategy: [for (final f in call) [f, 1 - f]],
      edge: l('bbCallEdge'),
      solved: true,
    ));
  }
  return spots;
}

/// Equity of each hand class vs one random hand (0..1), from the solver run.
Future<List<double>> loadVsRandom() async {
  final data = jsonDecode(await rootBundle.loadString('assets/data/pushfold.json'))
      as Map<String, dynamic>;
  return [for (final v in data['vsRandom'] as List) (v as num).toDouble()];
}

class SpotLibrary {
  final List<Spot> cash;
  final List<Spot> pushFold;
  final List<double> vsRandom;
  SpotLibrary(this.cash, this.pushFold, [this.vsRandom = const []]);

  List<Spot> get all => [...cash, ...pushFold];
  Spot byId(String id) => all.firstWhere((s) => s.id == id);

  static Future<SpotLibrary> load() async => SpotLibrary(
      buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
}
