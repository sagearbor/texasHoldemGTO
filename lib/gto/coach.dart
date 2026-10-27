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
bool isMixedHand(Spot spot, HandClass h) =>
    spot.freqs(h).every((f) => f < 0.9);

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

String _rangeSizeNote(Spot spot) => spot.actions.contains('Fold')
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
double playFreq(Spot spot, HandClass h) =>
    1 - spot.freqs(h)[spot.passiveIndex];

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
    final famName = h.isPair ? 'pairs' : '${rankChars[h.highRank]}x${h.isSuited ? ' suited' : ' offsuit'}';
    if (always.isNotEmpty || mixed.isNotEmpty) {
      final b = StringBuffer('Among $famName: ');
      if (always.isNotEmpty) {
        b.write('${_spanName(always)} always play');
      }
      if (mixed.isNotEmpty) {
        if (always.isNotEmpty) b.write('; ');
        b.write('${_spanName(mixed)} ${mixed.length == 1 ? 'is' : 'are'} borderline');
      }
      b.write('.');
      notes.add(b.toString());
    } else {
      notes.add('No $famName are played here. They are too weak for this spot.');
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
  if (spot.hero == 'BTN' && spot.villain == null) {
    notes.add('The button is the best seat: you act last after the flop on '
        'every street, so you can open almost half your hands.');
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
