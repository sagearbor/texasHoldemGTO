/// Preflop spot library.
///
/// Two sources:
///  * 6-max 100bb cash: baseline ranges written from standard modern theory
///    (2.5x opens, 3x SB open, ~3x IP / ~3.5x OOP 3-bets). They are
///    approximations of solver output, labelled as such in the UI.
///  * 6-max 100bb facing limpers: hand-authored approximations for
///    limp-heavy home games (iso / overlimp / fold; BB raise / check).
///    Limped pots are not in standard solver trees, so these are labelled
///    "approximate" more loudly than the rest.
///  * 6-max 100bb facing a 3-bet: hand-authored approximations of the
///    opener's 4-bet / call / fold strategy (4-bet 22bb in position, 25bb
///    out of position). Rows are conditional on hero having opened the hand;
///    [Spot.reach] holds the opening frequency.
///  * Heads-up push/fold: true Nash equilibrium computed by
///    tool/solve_pushfold.dart (assets/data/pushfold.json).
///  * 3-handed push/fold (BTN, SB, BB): equilibrium computed by
///    tool/solve_pushfold3.dart (assets/data/pushfold3.json).
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'hand_class.dart';
import 'range_parser.dart';

enum SpotFormat { cash100, pushFold, pushFold3 }

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

  /// How often hero holds each hand class on reaching this spot (e.g. the
  /// opening frequency when facing a 3-bet), or null when every hand can.
  /// The trainer only deals hands with reach > 0.
  final List<double>? reach;

  /// Further seats that can be the aggressor in a grouped spot (e.g. "HJ,
  /// CO or BTN 3-bets"), shown alongside [villain] on the table diagram.
  final List<String> otherVillains;

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
    this.reach,
    this.otherVillains = const [],
  });

  List<double> freqs(HandClass h) => strategy[h.index];

  /// Index of the "do nothing" action: Fold, or Check for the big blind
  /// facing limpers (which has no fold).
  int get passiveIndex {
    final f = actions.indexOf('Fold');
    return f >= 0 ? f : actions.indexOf('Check');
  }

  /// Percent of all combos that take a non-fold (non-check) action.
  double get playPercent {
    final foldIdx = passiveIndex;
    var c = 0.0;
    for (final h in allHandClasses) {
      c += h.comboCount * (1 - strategy[h.index][foldIdx]);
    }
    return c / 1326;
  }

  /// Share of the hands hero can hold here ([reach]-weighted combos) that
  /// take a non-fold action. Equals [playPercent] when [reach] is null.
  double get continueShare {
    final r = reach;
    if (r == null) return playPercent;
    final foldIdx = passiveIndex;
    var c = 0.0, n = 0.0;
    for (final h in allHandClasses) {
      final w = h.comboCount * r[h.index];
      n += w;
      c += w * (1 - strategy[h.index][foldIdx]);
    }
    return n == 0 ? 0 : c / n;
  }
}

/// Group name of the hand-authored facing-a-3-bet spots.
const threeBetGroup = 'Facing a 3-bet';

/// Group name of the hand-authored facing-limpers spots.
const limperGroup = 'Facing limpers';

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

/// Rows of [iso, passive, fold] (or [raise, check] when [check] is true).
/// [passive] is the extra overlimp / complete range, capped so a row never
/// exceeds 1 (iso takes priority).
List<List<double>> _vsLimp(String iso, String passive, {bool check = false}) {
  final r = parseRange(iso), p = parseRange(passive);
  return [
    for (var i = 0; i < 169; i++)
      () {
        final rr = r[i] ?? 0;
        if (check) return [rr, 1 - rr];
        final pp = (p[i] ?? 0).clamp(0.0, 1 - rr);
        return [rr, pp, 1 - rr - pp];
      }()
  ];
}

/// Facing limpers, 6-max 100bb. (hero, limpers) -> (raise, overlimp or
/// complete). Hand-authored from standard theory, not solved:
///  * iso-raises are tighter than RFI and value-heavy (pairs, big cards);
///  * overlimps are mostly small pairs and suited connectors in position,
///    more of them vs two limpers (better price, multiway implied odds);
///  * the SB completes a fair amount for half a big blind;
///  * the BB raises for value and checks everything else for free.
const _vsLimpRanges = {
  ('CO', 1): (
    '88+, 77:0.6, A9s+, A5s-A4s:0.4, KTs+, QJs, QTs:0.5, AJo+, ATo:0.5, KQo, '
        'KJo:0.3',
    '77:0.4, 66-22, A8s-A6s:0.5, A5s-A2s:0.6, K9s:0.5, QTs:0.5, Q9s:0.4, JTs, '
        'J9s:0.5, T9s, 98s, 87s:0.8, 76s:0.6, 65s:0.5'
  ),
  ('BTN', 1): (
    '77+, 66:0.5, A8s+, A5s-A2s:0.5, K9s+, Q9s+, J9s+, T9s:0.5, ATo+, A9o:0.4, '
        'KJo+, KTo:0.4, QJo:0.5',
    '66:0.5, 55-22, A7s-A6s:0.6, A5s-A2s:0.5, K8s-K6s:0.5, Q8s:0.5, J8s:0.5, '
        'T9s:0.5, T8s:0.6, 98s, 97s:0.4, 87s, 86s:0.4, 76s, 75s:0.3, 65s, '
        '54s:0.6, A8o:0.3, KTo:0.3, QTo:0.4, JTo:0.4'
  ),
  ('SB', 1): (
    '88+, 77:0.5, ATs+, A5s:0.5, KJs+, QJs:0.5, AJo+, KQo:0.6',
    '77:0.5, 66-22, A9s-A2s, KTs-K7s, QTs-Q8s, QJs:0.5, J8s+, T8s+, 97s+, '
        '86s+, 75s+, 64s+, 54s, ATo-A8o, KJo-KTo, KQo:0.4, QTo+, JTo, '
        'T9o:0.5, 98o:0.4'
  ),
  ('BB', 1): (
    '99+, 88:0.6, ATs+, A5s:0.4, KJs+, KTs:0.4, QJs:0.4, AJo+, ATo:0.3, KQo, '
        'KJo:0.3',
    ''
  ),
  ('CO', 2): (
    'TT+, 99:0.6, 88:0.3, AJs+, ATs:0.5, KQs, KJs:0.4, AQo+, AJo:0.4, KQo:0.3',
    '99:0.4, 88:0.7, 77-22, ATs:0.5, A9s-A2s:0.7, KJs:0.6, KTs:0.8, K9s:0.4, '
        'QTs+, Q9s:0.5, JTs, J9s:0.6, T9s, 98s, 87s, 76s:0.8, 65s:0.7, 54s:0.4'
  ),
  ('BTN', 2): (
    'TT+, 99:0.6, 88:0.3, ATs+, A5s:0.3, KJs+, QJs:0.3, AQo+, AJo:0.6, KQo:0.5',
    '99:0.4, 88:0.7, 77-22, A9s-A2s, A5s:0.7, KTs-K6s, QJs:0.7, QTs-Q8s, J8s+, '
        'T8s+, 97s+, 86s+, 75s+, 64s+, 54s, 43s:0.5, ATo-A9o:0.5, AJo:0.4, '
        'KJo:0.6, KTo:0.4, KQo:0.5, QJo:0.5, QTo:0.3, JTo:0.5'
  ),
  ('SB', 2): (
    'JJ+, TT:0.6, AQs+, AJs:0.5, AKo, AQo:0.5',
    'TT:0.4, 99-22, AJs:0.5, ATs-A2s, KTs+, K9s-K5s, Q8s+, J8s+, T7s+, 97s+, '
        '86s+, 75s+, 64s+, 53s+, 43s:0.5, AQo:0.5, AJo-A8o, A7o-A2o:0.3, KTo+, '
        'K9o:0.4, QTo+, Q9o:0.4, JTo, J9o:0.4, T9o, 98o:0.5, 87o:0.3'
  ),
  ('BB', 2): (
    'TT+, 99:0.5, AQs+, AJs:0.6, KQs:0.5, AKo, AQo:0.6',
    ''
  ),
};

/// Iso-raise size label: 4bb in position vs one limper, +1bb per extra
/// limper, +1bb more out of position (SB/BB).
String isoLabel(String hero, int limpers) {
  final oop = hero == 'SB' || hero == 'BB';
  final size = 3 + limpers + (oop ? 1 : 0);
  return hero == 'BB' ? 'Raise ${size}bb' : 'Iso ${size}bb';
}

const positions6max = ['UTG', 'HJ', 'CO', 'BTN', 'SB', 'BB'];

/// Rows of [4-bet, call, fold]; the call range is capped so a row never
/// exceeds 1 (4-bet takes priority).
List<List<double>> _vs3bet(String fourBet, String call) => _vsLimp(fourBet, call);

/// Opening frequency of each hand class from [pos] (RFI chart).
List<double> rfiReach(String pos) {
  final r = parseRange(_rfiRanges[pos]!);
  return [for (var i = 0; i < 169; i++) r[i] ?? 0];
}

/// Facing a 3-bet after opening, 6-max 100bb. Hand-authored from standard
/// theory, not solved. Every hand here is in the opener's RFI range.
///  * 4-bets are polarised: QQ+/AK for value plus a few A5s-A3s bluffs
///    (the ace blocks AA/AK);
///  * calls are mostly pairs, suited broadways and suited connectors, more
///    of them in position;
///  * continuing ranges are tighter vs early 3-bettors and vs the bigger,
///    more linear blind 3-bets; offsuit broadways mostly fold.
const _vs3betSpots = <({
  String id,
  String hero,
  String villain,
  List<String> others,
  String title,
  String raiser,
  String size,
  bool heroIp,
  String fourBet,
  String call,
})>[
  (
    id: 'UTG-ip',
    hero: 'UTG',
    villain: 'BTN',
    others: ['HJ', 'CO'],
    title: 'UTG vs IP 3-bet',
    raiser: 'The HJ, CO or BTN',
    size: '7.5bb',
    heroIp: false,
    fourBet: 'KK+, QQ:0.4, AKs:0.7, AKo:0.6, A5s:0.4, A4s:0.3',
    call: 'QQ:0.6, JJ-99, 88:0.6, 77:0.4, AKs:0.3, AKo:0.3, AQs, AJs:0.7, '
        'ATs:0.4, KQs, KJs:0.5, QJs:0.4, JTs:0.4, T9s:0.2, AQo:0.4',
  ),
  (
    id: 'UTG-blinds',
    hero: 'UTG',
    villain: 'BB',
    others: ['SB'],
    title: 'UTG vs blind 3-bet',
    raiser: 'The SB or BB',
    size: '10bb',
    heroIp: true,
    fourBet: 'KK+, QQ:0.5, AKs:0.7, AKo:0.7, A5s:0.3, A4s:0.2',
    call: 'QQ:0.5, JJ-TT, 99:0.7, 88:0.4, AKs:0.3, AKo:0.3, AQs, AJs:0.5, '
        'KQs:0.8, KJs:0.3, QJs:0.3, JTs:0.3, AQo:0.25',
  ),
  (
    id: 'CO-BTN',
    hero: 'CO',
    villain: 'BTN',
    others: [],
    title: 'CO vs BTN 3-bet',
    raiser: 'The BTN',
    size: '7.5bb',
    heroIp: false,
    fourBet: 'KK+, QQ:0.6, AKs, AKo:0.8, A5s:0.5, A4s:0.4, A3s:0.2',
    call: 'QQ:0.4, JJ-66, 55:0.5, 44:0.3, AKo:0.2, AQs-ATs, A9s:0.5, '
        'A8s:0.3, A5s:0.3, A4s:0.3, KQs-KTs, QJs, QTs:0.7, JTs, J9s:0.4, T9s, '
        '98s:0.6, 87s:0.4, 76s:0.3, AQo:0.7, AJo:0.3, KQo:0.4',
  ),
  (
    id: 'CO-blinds',
    hero: 'CO',
    villain: 'BB',
    others: ['SB'],
    title: 'CO vs blind 3-bet',
    raiser: 'The SB or BB',
    size: '10bb',
    heroIp: true,
    fourBet: 'KK+, QQ:0.6, AKs, AKo:0.8, A5s:0.4, A4s:0.3',
    call: 'QQ:0.4, JJ-77, 66:0.5, 55:0.3, AKo:0.2, AQs-AJs, ATs:0.7, A9s:0.3, '
        'A5s:0.3, KQs, KJs:0.8, KTs:0.5, QJs:0.8, QTs:0.4, JTs:0.8, T9s:0.6, '
        '98s:0.4, 87s:0.3, AQo:0.6, KQo:0.3',
  ),
  (
    id: 'BTN-SB',
    hero: 'BTN',
    villain: 'SB',
    others: [],
    title: 'BTN vs SB 3-bet',
    raiser: 'The SB',
    size: '10bb',
    heroIp: true,
    fourBet: 'QQ+, JJ:0.3, AKs, AKo, AQs:0.2, A5s:0.5, A4s:0.4, A3s:0.3',
    call: 'JJ:0.7, TT-44, 33:0.6, 22:0.5, AQs:0.8, AJs-A6s, A5s-A2s:0.5, '
        'KQs-K9s, K8s:0.4, QJs-Q9s, JTs-J9s, T9s, T8s:0.6, 98s, 97s:0.4, '
        '87s, 76s, 65s, 54s:0.6, AQo, AJo:0.8, ATo:0.4, KQo:0.8, KJo:0.4, '
        'QJo:0.3',
  ),
  (
    id: 'BTN-BB',
    hero: 'BTN',
    villain: 'BB',
    others: [],
    title: 'BTN vs BB 3-bet',
    raiser: 'The BB',
    size: '10bb',
    heroIp: true,
    fourBet: 'KK+, QQ:0.7, AKs, AKo:0.8, A5s:0.5, A4s:0.4, A3s:0.2',
    call: 'QQ:0.3, JJ-55, 44:0.6, 33:0.4, 22:0.3, AKo:0.2, AQs-A7s, A6s:0.6, '
        'A5s-A2s:0.4, KQs-K9s, QJs-Q9s, JTs-J9s, T9s, T8s:0.5, 98s, 97s:0.3, '
        '87s, 76s, 65s:0.8, 54s:0.5, AQo, AJo:0.6, ATo:0.3, KQo:0.6, '
        'KJo:0.25',
  ),
  (
    id: 'SB-BB',
    hero: 'SB',
    villain: 'BB',
    others: [],
    title: 'SB vs BB 3-bet',
    raiser: 'The BB',
    size: '9bb',
    heroIp: false,
    fourBet: 'QQ+, JJ:0.4, AKs, AKo, AQs:0.3, A5s:0.6, A4s:0.5, A3s:0.4, '
        'A2s:0.2',
    call: 'JJ:0.6, TT-44, 33:0.5, 22:0.4, AQs:0.7, AJs-A6s, A5s-A2s:0.4, '
        'KQs-K9s, K8s:0.5, QJs-Q9s, JTs-J9s, T9s, T8s:0.6, 98s, 97s:0.4, 87s, '
        '76s, 65s, 54s:0.6, AQo, AJo, ATo:0.5, KQo, KJo:0.5, QJo:0.3',
  ),
];

/// 4-bet size label: 22bb in position, 25bb out of position.
String fourBetLabel({required bool inPosition}) =>
    '4-bet ${inPosition ? 22 : 25}bb';

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
  _vsLimpRanges.forEach((key, ranges) {
    final (hero, n) = key;
    final limpers = n == 1 ? 'UTG limps' : 'UTG and HJ limp';
    final between = positions6max
        .sublist(n == 1 ? 1 : 2, positions6max.indexOf(hero));
    final folds = between.isEmpty
        ? ''
        : ', ${between.join(', ')} fold${between.length == 1 ? 's' : ''}';
    final situation = switch (hero) {
      'BB' => '$limpers$folds. Check for free or raise?',
      'SB' => '$limpers$folds. Action is on you in the SB.',
      _ => '$limpers$folds. Action is on you on the $hero.',
    };
    spots.add(Spot(
      id: 'cash-limp$n-$hero',
      format: SpotFormat.cash100,
      group: limperGroup,
      title: '$hero vs $n limper${n == 1 ? '' : 's'}',
      situation: situation,
      hero: hero,
      villain: n == 1 ? 'UTG' : 'HJ',
      actions: [
        isoLabel(hero, n),
        if (hero == 'BB') 'Check' else if (hero == 'SB') 'Complete' else 'Overlimp',
        if (hero != 'BB') 'Fold',
      ],
      strategy: _vsLimp(ranges.$1, ranges.$2, check: hero == 'BB'),
    ));
  });
  for (final t in _vs3betSpots) {
    final open = t.hero == 'SB' ? '3bb' : '2.5bb';
    final rest = t.hero == 'SB' ? '' : ', the rest fold';
    spots.add(Spot(
      id: 'cash-3b-${t.id}',
      format: SpotFormat.cash100,
      group: threeBetGroup,
      title: t.title,
      situation: 'You open $open from the ${t.hero}. ${t.raiser} 3-bets to '
          '${t.size}$rest. You are ${t.heroIp ? 'in' : 'out of'} position. '
          '(Approximate chart.)',
      hero: t.hero,
      villain: t.villain,
      otherVillains: t.others,
      actions: [fourBetLabel(inPosition: t.heroIp), 'Call', 'Fold'],
      strategy: _vs3bet(t.fourBet, t.call),
      reach: rfiReach(t.hero),
    ));
  }
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

/// Decision nodes of the 3-handed push/fold tree, in the order they are
/// stored in assets/data/pushfold3.json, with display data.
const pushFold3Nodes = <({
  String key,
  String label,
  String title,
  String hero,
  String? villain,
  String action,
  String situation,
})>[
  (
    key: 'btnJam',
    label: 'BTN jam',
    title: 'BTN jam',
    hero: 'BTN',
    villain: null,
    action: 'All-in',
    situation: 'You are first to act on the BTN.',
  ),
  (
    key: 'sbCallVsBtn',
    label: 'SB vs BTN jam',
    title: 'SB vs BTN jam',
    hero: 'SB',
    villain: 'BTN',
    action: 'Call',
    situation: 'BTN moves all-in. You are in the SB, BB still to act.',
  ),
  (
    key: 'sbJamVsBb',
    label: 'SB jam',
    title: 'SB jam vs BB',
    hero: 'SB',
    villain: 'BB',
    action: 'All-in',
    situation: 'BTN folds to you in the SB.',
  ),
  (
    key: 'bbCallVsBtn',
    label: 'BB vs BTN jam',
    title: 'BB vs BTN jam',
    hero: 'BB',
    villain: 'BTN',
    action: 'Call',
    situation: 'BTN moves all-in, folds to you in the BB.',
  ),
  (
    key: 'bbOvercall',
    label: 'BB overcall',
    title: 'BB overcall',
    hero: 'BB',
    villain: 'BTN',
    action: 'Call',
    situation: 'BTN moves all-in and SB calls. You are in the BB.',
  ),
  (
    key: 'bbCallVsSb',
    label: 'BB vs SB jam',
    title: 'BB vs SB jam',
    hero: 'BB',
    villain: 'SB',
    action: 'Call',
    situation: 'BTN folds, SB moves all-in. You are in the BB.',
  ),
];

String pushFold3Id(String node, int stack) => 'pf3-$node-$stack';

/// Spots from a decoded assets/data/pushfold3.json map.
List<Spot> pushFold3SpotsFrom(Map<String, dynamic> data) {
  final spots = <Spot>[];
  for (final s in (data['stacks'] as List).cast<int>()) {
    for (final n in pushFold3Nodes) {
      List<double> l(String k) =>
          [for (final v in (data[k]['$s'] as List)) (v as num).toDouble()];
      spots.add(Spot(
        id: pushFold3Id(n.key, s),
        format: SpotFormat.pushFold3,
        group: 'Push/fold 3-handed ${s}bb',
        title: '${n.title} ${s}bb (3-handed)',
        situation: '3-handed, ${s}bb. ${n.situation}',
        hero: n.hero,
        villain: n.villain,
        actions: [n.action, 'Fold'],
        strategy: [for (final f in l(n.key)) [f, 1 - f]],
        edge: l('${n.key}Edge'),
        solved: true,
      ));
    }
  }
  return spots;
}

Future<List<Spot>> loadPushFold3Spots() async => pushFold3SpotsFrom(
    jsonDecode(await rootBundle.loadString('assets/data/pushfold3.json'))
        as Map<String, dynamic>);

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

  /// 3-handed (BTN/SB/BB) push/fold spots.
  final List<Spot> pushFold3;
  SpotLibrary(this.cash, this.pushFold,
      [this.vsRandom = const [], this.pushFold3 = const []]);

  List<Spot> get all => [...cash, ...pushFold, ...pushFold3];
  Spot byId(String id) => all.firstWhere((s) => s.id == id);

  static Future<SpotLibrary> load() async => SpotLibrary(buildCashSpots(),
      await loadPushFoldSpots(), await loadVsRandom(), await loadPushFold3Spots());
}
