/// Turns spot data into plain-English coaching. No AI: every sentence is a
/// template filled from the strategy numbers.
library;

import '../poker/cards.dart';
import 'hand_class.dart';
import 'spots.dart';

enum Grade { correct, mixed, rare, mistake }

const gradeLabels = {
  Grade.correct: 'GTO play',
  Grade.mixed: 'Fine: mixed spot',
  Grade.rare: 'Rarely played this way',
  Grade.mistake: 'Mistake',
};

Grade gradeFor(double freq) {
  if (freq >= 0.7) return Grade.correct;
  if (freq >= 0.25) return Grade.mixed;
  if (freq > 0.02) return Grade.rare;
  return Grade.mistake;
}

/// Beginner grading: the action the solver takes at least half the time is
/// simply right; anything else is a mistake.
Grade beginnerGradeFor(double freq) =>
    freq >= 0.5 ? Grade.correct : Grade.mistake;

/// True when no single action is taken at least 90% of the time.
bool isMixedHand(Spot spot, HandClass h) => spot.freqs(h).every((f) => f < 0.9);

/// Beginner coaching: the recommended action and one reason, nothing more.
List<String> simpleCoachNotes(Spot spot, HandClass h, int chosen) {
  final f = spot.freqs(h);
  final best = _argmax(f);
  final a = spot.actions[best];
  return [
    if (f[chosen] < 0.5)
      'The right play is $a (${pct(f[best])}), not ${spot.actions[chosen]}.'
    else
      '${spot.actions[chosen]} is right with ${h.name} here.',
    if (best == spot.passiveIndex)
      '${h.name} is not strong enough to '
          '${spot.actions.contains('Fold') ? 'play' : 'raise'} from '
          '${spot.hero} in this spot.'
    else
      '${h.name} is one of the stronger hands ${spot.hero} plays here.',
    _rangeSizeNote(spot),
  ];
}

String _rangeSizeNote(Spot spot) => spot.reach != null
    ? 'Of the hands ${spot.hero} opens, it continues with about '
        '${pct(spot.continueShare)} here.'
    : spot.actions.contains('Fold')
        ? '${spot.hero} plays about ${pct(spot.playPercent)} of hands here.'
        : '${spot.hero} raises about ${pct(spot.playPercent)} of hands here.';

String pct(double f) => '${(f * 100).round()}%';

/// "Raise 60%, Fold 40%" (zero-frequency actions omitted).
String strategyLine(Spot spot, HandClass h) {
  final f = spot.freqs(h);
  final parts = <String>[
    for (var i = 0; i < spot.actions.length; i++)
      if (f[i] > 0.005) '${spot.actions[i]} ${pct(f[i])}'
  ];
  return parts.join(' · ');
}

/// Frequency of every non-fold action combined (for the BB facing limpers,
/// which cannot fold: every non-check action).
double playFreq(Spot spot, HandClass h) => 1 - spot.freqs(h)[spot.passiveIndex];

List<String> coachNotes(Spot spot, HandClass h, int chosen) {
  final notes = <String>[];
  final f = spot.freqs(h);
  final best = _argmax(f);
  final aggressive = spot.actions[0];

  // 1. Where this hand sits relative to its neighbours.
  final row = _family(h);
  if (row.length > 1) {
    final always = row.where((x) => playFreq(spot, x) >= 0.95).toList();
    final mixed = row.where((x) {
      final p = playFreq(spot, x);
      return p > 0.05 && p < 0.95;
    }).toList();
    final famName = h.isPair
        ? 'pairs'
        : '${rankChars[h.highRank]}x${h.isSuited ? ' suited' : ' offsuit'}';
    if (always.isNotEmpty || mixed.isNotEmpty) {
      final b = StringBuffer('Among $famName: ');
      if (always.isNotEmpty) {
        b.write('${_spanName(always)} always play');
      }
      if (mixed.isNotEmpty) {
        if (always.isNotEmpty) b.write('; ');
        b.write(
            '${_spanName(mixed)} ${mixed.length == 1 ? 'is' : 'are'} borderline');
      }
      b.write('.');
      notes.add(b.toString());
    } else {
      notes
          .add('No $famName are played here. They are too weak for this spot.');
    }
  }

  // 2. Suited vs offsuit sibling.
  if (!h.isPair) {
    final sib = HandClass(h.col, h.row);
    final ps = playFreq(spot, h), po = playFreq(spot, sib);
    if ((ps - po).abs() >= 0.4) {
      final suited = h.isSuited ? h : sib;
      notes.add('${suited.name} plays far more often than its '
          '${h.isSuited ? 'offsuit' : 'suited'} twin '
          '(${pct(h.isSuited ? ps : po)} vs ${pct(h.isSuited ? po : ps)}): '
          'being suited adds flush equity and makes the hand easier to play after the flop.');
    }
  }

  // 3. Spot-specific heuristics.
  if (spot.id.contains('-vs-') &&
      f[0] > 0.2 &&
      !h.isPair &&
      h.isSuited &&
      h.highRank == 12 &&
      h.lowRank <= 3) {
    notes.add('Small suited aces are classic 3-bet bluffs: the ace makes it '
        'less likely villain has AA/AK, and the hand can still make straights '
        'and nut flushes when called.');
  }
  if (spot.actions.contains('Call') &&
      spot.hero == 'BB' &&
      f[spot.actions.indexOf('Call')] > 0.5) {
    notes.add('The big blind already has 1bb invested and closes the action, '
        'so it gets a discount to call and defends wide.');
  }
  if (spot.group == limperGroup) {
    final passive = spot.actions[1];
    if (f[0] >= 0.5) {
      notes.add(spot.hero == 'BB'
          ? 'Raise for value: a limper\'s range is capped (strong hands '
              'usually raise first), and ${h.name} is ahead of it.'
          : 'Iso-raise for value: ${h.name} is ahead of a limping range, '
              'and the raise thins the field so you play heads-up with the '
              'initiative.');
    } else if (spot.hero == 'BB' && f[1] >= 0.5) {
      notes.add('The big blind sees the flop for free: with no fold option, '
          'check everything that is not a clear value raise.');
    } else if (spot.hero == 'SB' && f[1] >= 0.5) {
      notes.add('Completing costs only half a big blind with limpers already '
          'in, so the small blind can see a cheap flop with many hands.');
    } else if (passive == 'Overlimp' && f[1] >= 0.5) {
      notes.add('Overlimp small pairs and suited connectors: they want a '
          'cheap multiway flop to hit a set or a big draw, and they gain '
          'little from an iso-raise.');
    }
    notes.add('Facing-limper charts are hand-authored approximations: '
        'limped pots are not in standard solver trees.');
  }
  if (spot.group == threeBetGroup) notes.addAll(_threeBetNotes(spot, h));
  if (spot.hero == 'BTN' &&
      spot.villain == null &&
      spot.format == SpotFormat.cash100) {
    notes.add('The button is the best seat: you act last after the flop on '
        'every street, so you can open almost half your hands.');
  }
  if (spot.id.startsWith('pf3-bbOvercall')) {
    notes.add('Two players are already all-in. An overcall has to beat both '
        'ranges, and the SB called a jam, so this is one of the tightest '
        'ranges in 3-handed push/fold.');
  }
  if (spot.id.startsWith('pf3-btnJam')) {
    notes.add('From the button two players are still behind you, so the '
        'jamming range is tighter than heads-up from the small blind.');
  }
  if (spot.hero == 'UTG' && spot.villain == null && playFreq(spot, h) < 0.5) {
    notes.add('Five players are still behind you from UTG, so the range must '
        'stay tight: someone often has a strong hand.');
  }

  // 4. EV numbers where the spot is truly solved.
  if (spot.edge != null) {
    final e = spot.edge![h.index];
    final verb = aggressive.toLowerCase();
    if (e.abs() < 0.05) {
      notes.add('This hand is right at the edge: $verb and fold are worth '
          'almost the same (${e >= 0 ? '+' : ''}${e.toStringAsFixed(2)}bb).');
    } else if (e > 0) {
      notes.add('Going $verb wins about ${e.toStringAsFixed(2)}bb more than '
          'folding, on average.');
    } else {
      notes.add('Going $verb loses about ${(-e).toStringAsFixed(2)}bb compared '
          'with folding.');
    }
  }

  // 5. Range size context.
  notes.add(_rangeSizeNote(spot));

  if (chosen != best && f[chosen] < 0.25) {
    notes.insert(0, 'GTO prefers ${spot.actions[best]} (${pct(f[best])}).');
  }
  return notes;
}

int _argmax(List<double> f) {
  var b = 0;
  for (var i = 1; i < f.length; i++) {
    if (f[i] > f[b]) b = i;
  }
  return b;
}

/// Same high card and suitedness (or all pairs), ordered best first.
List<HandClass> _family(HandClass h) {
  if (h.isPair) return [for (var r = 0; r < 13; r++) HandClass(r, r)];
  final hiRow = 12 - h.highRank;
  return [
    for (var lo = h.highRank - 1; lo >= 0; lo--)
      h.isSuited ? HandClass(hiRow, 12 - lo) : HandClass(12 - lo, hiRow)
  ];
}

/// Compresses a best-first list into "A9o+"-style or "A8o-A6o" text.
String _spanName(List<HandClass> hands) {
  if (hands.length == 1) return hands.first.name;
  return '${hands.first.name}–${hands.last.name}';
}

/// Template notes for the hand-authored facing-a-3-bet spots.
List<String> _threeBetNotes(Spot spot, HandClass h) {
  final f = spot.freqs(h);
  final notes = <String>[];
  final ip = spot.actions[0] == fourBetLabel(inPosition: true);
  final call = spot.actions.indexOf('Call');
  final broadway = h.lowRank >= 8; // both cards T or higher
  if ((spot.reach?[h.index] ?? 1) == 0) {
    notes.add('${h.name} is not in the ${spot.hero} opening range, so it '
        'never reaches this spot: it folds before the flop.');
  } else if (f[0] >= 0.25 && (h.isPair || (h.highRank == 12 && h.lowRank == 11))) {
    notes.add('4-bet for value: ${h.name} is at the top of your range and '
        'ahead of most 3-betting hands. Building the pot now gets stacks in '
        'by the river.');
  } else if (f[0] > 0.05 &&
      h.isSuited &&
      h.highRank == 12 &&
      h.lowRank <= 3) {
    notes.add('${h.name} is a 4-bet bluff: the ace blocks AA and AK, so the '
        '3-bettor is less likely to have a hand that continues, and the '
        'wheel straight and nut-flush draws give it equity when called. The '
        '4-bet range stays polarised: big value hands plus a few of these.');
  }
  if (call >= 0 && f[call] >= 0.5) {
    notes.add(ip
        ? 'Calling in position works: you act last on every street, so '
            'pairs, suited broadways and suited connectors realise their '
            'equity and win big pots when they hit.'
        : 'Calling out of position is harder: the 3-bettor keeps the '
            'initiative and you act first on every street, so out-of-position '
            'calls stay tight (pairs and strong suited broadways).');
  }
  if (!h.isPair && !h.isSuited && broadway && f[spot.passiveIndex] >= 0.5 &&
      (spot.reach?[h.index] ?? 1) > 0) {
    notes.add('Fold offsuit broadways like ${h.name}: they are dominated by '
        'the 3-bettor\'s AK, AQ and KQ, make few strong hands and have no '
        'flush potential to make up for it.');
  }
  notes.add('Facing-a-3-bet charts are hand-authored approximations (4-bet '
      '22bb in position, 25bb out of position), not solver output.');
  return notes;
}
