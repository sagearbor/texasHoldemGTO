/// Derived, read-only views over logged home-game data: the end-of-night
/// recap ("Wrapped"), luck per dealer, and the crew / season view across
/// nights. Everything here is a pure function of the stored sessions: no
/// new data is recorded, and every title comes from a fixed rule.
library;

import '../gto/coach.dart';
import '../gto/hand_class.dart';
import '../gto/spots.dart';
import 'home_game.dart';
import 'moments.dart';
import 'my_result.dart';

const _premiumNames = {'AA', 'KK', 'QQ', 'JJ', 'AKs', 'AKo'};

/// Sample-size gates. Below these a card or award is left out entirely,
/// so a short night shows fewer cards rather than empty ones.
class RecapGates {
  static const coldRunWindow = 10;
  static const coldRunMinDealt = 15;
  static const premiumsMinDealt = 10;
  static const gtoMinGraded = 5;
  static const foldStreakMin = 3;
  static const dealerMinHands = 4;
  static const luckAwardMinDealt = 20;
  static const banditMinSamples = 5;
}

double? _equity(LoggedHand h, SpotLibrary lib) {
  final hc = h.hand;
  if (hc == null || lib.vsRandom.isEmpty) return null;
  return lib.vsRandom[hc.index];
}

String _key(String name) => name.trim().toLowerCase();

// ---------------------------------------------------------------- dealer luck

class DealerLuckRow {
  /// Display name (trimmed, most recent spelling).
  final String name;

  /// Hands this person dealt where you entered your cards.
  final int hands;
  final double avgEquity;
  final int premiums;
  final HandClass? best;
  final int? bestNumber;
  final double bestEquity;

  DealerLuckRow({
    required this.name,
    required this.hands,
    required this.avgEquity,
    required this.premiums,
    required this.best,
    required this.bestNumber,
    required this.bestEquity,
  });
}

class DealerLuck {
  /// Every dealer who dealt you at least one hand with cards, most hands first.
  final List<DealerLuckRow> all;

  /// Dealers with enough hands to compare, best average equity first.
  final List<DealerLuckRow> ranked;

  DealerLuck(this.all, this.ranked);

  /// Needs at least two ranked dealers: luck is relative.
  DealerLuckRow? get goldenArm => ranked.length >= 2 ? ranked.first : null;
  DealerLuckRow? get dealerOfDoom => ranked.length >= 2 ? ranked.last : null;
}

DealerLuck dealerLuck(Iterable<LoggedHand> hands, SpotLibrary lib) {
  final groups = <String, List<LoggedHand>>{};
  final names = <String, String>{};
  for (final h in hands) {
    final d = h.dealer;
    if (d == null || d.trim().isEmpty || h.hand == null) continue;
    final k = _key(d);
    (groups[k] ??= []).add(h);
    names[k] = d.trim();
  }
  final rows = <DealerLuckRow>[];
  for (final MapEntry(key: k, value: hs) in groups.entries) {
    var sum = 0.0, premiums = 0, bestEq = -1.0;
    LoggedHand? best;
    for (final h in hs) {
      final eq = _equity(h, lib) ?? 0.5;
      sum += eq;
      if (_premiumNames.contains(h.hand!.name)) premiums++;
      if (eq > bestEq) {
        bestEq = eq;
        best = h;
      }
    }
    rows.add(DealerLuckRow(
      name: names[k]!,
      hands: hs.length,
      avgEquity: sum / hs.length,
      premiums: premiums,
      best: best?.hand,
      bestNumber: best?.number,
      bestEquity: bestEq,
    ));
  }
  rows.sort((a, b) => b.hands.compareTo(a.hands));
  final ranked = [
    for (final r in rows)
      if (r.hands >= RecapGates.dealerMinHands) r
  ]..sort((a, b) => b.avgEquity.compareTo(a.avgEquity));
  return DealerLuck(rows, ranked);
}

// ---------------------------------------------------------------- night recap

class ColdRun {
  /// Hand numbers (as logged) of the first and last hand in the window.
  final int from, to;
  final double avg;
  ColdRun(this.from, this.to, this.avg);
}

enum AwardId { cardDead, heater, buttonBandit, rock, maniac, station, gtoRobot, premiumMagnet, patience, dealerOfDoom, goldenArm }

class Award {
  final AwardId id;
  final String title;
  final String detail;
  const Award(this.id, this.title, this.detail);
}

/// Fixed award titles. Never generated text.
const awardTitles = {
  AwardId.cardDead: 'Card Dead',
  AwardId.heater: 'On a Heater',
  AwardId.buttonBandit: 'Button Bandit',
  AwardId.rock: 'Rock',
  AwardId.maniac: 'Maniac',
  AwardId.station: 'Calling Station',
  AwardId.gtoRobot: 'GTO Robot',
  AwardId.premiumMagnet: 'Premium Magnet',
  AwardId.patience: 'Patience of a Saint',
  AwardId.dealerOfDoom: 'Dealer of Doom',
  AwardId.goldenArm: 'Golden Arm',
};

class NightRecap {
  final HomeSession session;
  final SessionStats stats;

  /// First to last logged hand, when at least two were logged.
  final Duration? duration;

  /// Strongest hand of the night by equity vs a random hand.
  final LoggedHand? best;
  final double bestEquity;
  final ColdRun? coldRun;

  /// Longest run of consecutive recorded folds (hands without an action
  /// neither break nor extend it).
  final int foldStreak;
  final DealerLuck dealers;
  final List<Award> awards;

  NightRecap({
    required this.session,
    required this.stats,
    required this.duration,
    required this.best,
    required this.bestEquity,
    required this.coldRun,
    required this.foldStreak,
    required this.dealers,
    required this.awards,
  });

  double get expectedPremiums => stats.dealt * SessionStats.premiumRate;

  bool get showPremiums => stats.dealt >= RecapGates.premiumsMinDealt;
  bool get showStyle => stats.recorded >= 10;
  bool get showGto => stats.graded >= RecapGates.gtoMinGraded;
  bool get showFoldStreak => foldStreak >= RecapGates.foldStreakMin;
  bool get showDealers => dealers.ranked.isNotEmpty;

  String? get gtoGrade => showGto ? letterGrade(stats.gtoScore) : null;
}

/// A–F from the share of graded spots played GTO.
String letterGrade(double score) {
  if (score >= 0.9) return 'A';
  if (score >= 0.8) return 'B';
  if (score >= 0.7) return 'C';
  if (score >= 0.6) return 'D';
  return 'F';
}

/// Card luck as a signed percentage vs the 50% a random hand averages.
String luckLabel(double avg) {
  final d = (avg - 0.5) * 100;
  return '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)}%';
}

String durationLabel(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  if (h == 0) return '${m}m';
  return '${h}h ${m.toString().padLeft(2, '0')}m';
}

NightRecap nightRecap(HomeSession s, SpotLibrary lib) {
  final hands = s.hands;
  final st = computeStats(hands, lib);

  Duration? duration;
  if (hands.length >= 2) {
    final ts = [for (final h in hands) h.ts]..sort();
    duration = Duration(milliseconds: ts.last - ts.first);
  }

  LoggedHand? best;
  var bestEq = -1.0;
  final dealtEq = <(LoggedHand, double)>[];
  for (final h in hands) {
    final eq = _equity(h, lib);
    if (eq == null) continue;
    dealtEq.add((h, eq));
    if (eq > bestEq) {
      bestEq = eq;
      best = h;
    }
  }

  ColdRun? cold;
  const w = RecapGates.coldRunWindow;
  if (st.dealt >= RecapGates.coldRunMinDealt && dealtEq.length >= w) {
    var sum = 0.0;
    for (var i = 0; i < w; i++) {
      sum += dealtEq[i].$2;
    }
    var minSum = sum, minAt = 0;
    for (var i = w; i < dealtEq.length; i++) {
      sum += dealtEq[i].$2 - dealtEq[i - w].$2;
      if (sum < minSum - 1e-12) {
        minSum = sum;
        minAt = i - w + 1;
      }
    }
    cold = ColdRun(dealtEq[minAt].$1.number, dealtEq[minAt + w - 1].$1.number, minSum / w);
  }

  var streak = 0, run = 0;
  for (final h in hands) {
    final a = h.action;
    if (a == null) continue;
    run = a == PreAction.fold ? run + 1 : 0;
    if (run > streak) streak = run;
  }

  final dealers = dealerLuck(hands, lib);
  final awards = <Award>[];
  void award(AwardId id, String detail) => awards.add(Award(id, awardTitles[id]!, detail));

  if (st.dealt >= RecapGates.luckAwardMinDealt && lib.vsRandom.isNotEmpty) {
    if (st.avgStrength < 0.47) {
      award(AwardId.cardDead, 'Card luck ${luckLabel(st.avgStrength)} over ${st.dealt} hands');
    } else if (st.avgStrength > 0.53) {
      award(AwardId.heater, 'Card luck ${luckLabel(st.avgStrength)} over ${st.dealt} hands');
    }
  }

  var lateN = 0, lateRaise = 0;
  for (final h in hands) {
    if (h.action == null) continue;
    if (h.position == 'BTN' || h.position == 'CO' || h.position == 'BTN/SB') {
      lateN++;
      if (h.action == PreAction.raise) lateRaise++;
    }
  }
  if (lateN >= RecapGates.banditMinSamples && lateRaise / lateN >= 0.6) {
    award(AwardId.buttonBandit, 'Raised $lateRaise of $lateN from the button and cutoff');
  }

  switch (st.style) {
    case 'Rock':
      award(AwardId.rock, 'Played ${pct(st.vpipPct)} of hands');
    case 'Maniac':
      award(AwardId.maniac, 'VPIP ${pct(st.vpipPct)}, raised ${pct(st.pfrPct)}');
    case 'Calling Station':
      award(AwardId.station, 'VPIP ${pct(st.vpipPct)}, raised only ${pct(st.pfrPct)}');
  }

  if (st.graded >= 10 && st.gtoScore >= 0.9) {
    award(AwardId.gtoRobot, '${pct(st.gtoScore)} GTO in ${st.graded} graded spots');
  }

  final expected = st.dealt * SessionStats.premiumRate;
  if (st.dealt >= RecapGates.premiumsMinDealt && st.premiums >= 3 && st.premiums >= 2 * expected) {
    award(AwardId.premiumMagnet,
        '${st.premiums} premiums, ${expected.toStringAsFixed(1)} expected');
  }

  if (streak >= 15) award(AwardId.patience, 'Folded $streak hands in a row');

  final doom = dealers.dealerOfDoom, golden = dealers.goldenArm;
  if (golden != null) {
    award(AwardId.goldenArm,
        '${golden.name}: card luck ${luckLabel(golden.avgEquity)} over ${golden.hands} hands');
  }
  if (doom != null) {
    award(AwardId.dealerOfDoom,
        '${doom.name}: card luck ${luckLabel(doom.avgEquity)} over ${doom.hands} hands');
  }

  return NightRecap(
    session: s,
    stats: st,
    duration: duration,
    best: best,
    bestEquity: bestEq,
    coldRun: cold,
    foldStreak: streak,
    dealers: dealers,
    awards: awards,
  );
}

/// Plain-text summary for the clipboard. Same gates as the cards.
String recapText(NightRecap r) {
  final st = r.stats;
  final b = StringBuffer('${r.session.name} - Felt Notes recap\n');
  b.write('${st.logged} hands logged');
  if (r.duration != null) b.write(' over ${durationLabel(r.duration!)}');
  b.writeln();
  if (r.best != null) {
    b.writeln('Best hand: ${r.best!.hand!.name} (hand #${r.best!.number}, ${r.best!.position}, '
        '${pct(r.bestEquity)} vs random)');
  }
  if (r.coldRun != null) {
    b.writeln('Coldest stretch: hands #${r.coldRun!.from}-#${r.coldRun!.to}, '
        'card luck ${luckLabel(r.coldRun!.avg)}');
  }
  if (r.showPremiums) {
    b.writeln('Premiums (JJ+/AK): ${st.premiums}, expected ${r.expectedPremiums.toStringAsFixed(1)}');
  }
  if (r.showStyle) {
    b.writeln('Style: ${st.style} (VPIP ${pct(st.vpipPct)}, PFR ${pct(st.pfrPct)})');
  }
  if (r.showGto) {
    b.writeln('GTO preflop: ${r.gtoGrade} (${pct(st.gtoScore)} of ${st.graded} spots)');
  }
  if (r.showFoldStreak) b.writeln('Longest fold streak: ${r.foldStreak}');
  if (r.showDealers) {
    b.writeln('Dealer luck:');
    for (final d in r.dealers.ranked) {
      b.writeln('  ${d.name}: ${luckLabel(d.avgEquity)} over ${d.hands} hands');
    }
  }
  final told = stories(r.session.hands);
  if (told.isNotEmpty) {
    b.writeln('Stories:');
    for (final h in told.reversed) {
      b.writeln('  ${storyLine(h)}');
    }
  }
  final net = r.session.net;
  if (net != null) b.writeln('My result: ${moneyLabel(net, signed: true)}');
  if (r.awards.isNotEmpty) {
    b.writeln('Awards:');
    for (final a in r.awards) {
      b.writeln('  ${a.title} - ${a.detail}');
    }
  }
  return b.toString().trimRight();
}

// ---------------------------------------------------------------- crew & season

class CrewMember {
  /// Most recent spelling of the name.
  final String name;
  final int nights;

  /// Consecutive nights attended, counting back from the latest night.
  final int streak;

  /// `started` of the last night they were at.
  final int lastSeen;
  CrewMember(this.name, this.nights, this.streak, this.lastSeen);
}

class CrewStats {
  /// Nights counted (sessions with at least one logged hand), oldest first.
  final List<HomeSession> nights;
  final List<CrewMember> members;
  CrewStats(this.nights, this.members);
}

List<HomeSession> _nights(List<HomeSession> sessions) =>
    [for (final s in sessions) if (s.hands.isNotEmpty) s]
      ..sort((a, b) => a.started.compareTo(b.started));

/// Everyone who sat with you (current seats plus anyone who dealt a logged
/// hand, so people who left mid-game still count). You are identified by
/// your seat in each night, not by name, and never appear in the list.
CrewStats crewStats(List<HomeSession> sessions) {
  final nights = _nights(sessions);
  final attended = <String, List<int>>{}; // key -> night indexes
  final spelling = <String, String>{};
  for (var i = 0; i < nights.length; i++) {
    final s = nights[i];
    final hero = s.heroSeat >= 0 && s.heroSeat < s.players.length
        ? _key(s.players[s.heroSeat])
        : null;
    final seen = <String>{};
    void add(String? n) {
      if (n == null || n.trim().isEmpty) return;
      final k = _key(n);
      if (k == hero || !seen.add(k)) return;
      spelling[k] = n.trim();
      (attended[k] ??= []).add(i);
    }

    for (final h in s.hands) {
      add(h.dealer);
    }
    for (final p in s.players) {
      add(p);
    }
  }
  final last = nights.length - 1;
  final members = <CrewMember>[];
  for (final MapEntry(key: k, value: idx) in attended.entries) {
    var streak = 0;
    final set = idx.toSet();
    for (var i = last; i >= 0 && set.contains(i); i--) {
      streak++;
    }
    members.add(CrewMember(spelling[k]!, idx.length, streak, nights[idx.last].started));
  }
  members.sort((a, b) {
    final c = b.nights.compareTo(a.nights);
    if (c != 0) return c;
    final d = b.lastSeen.compareTo(a.lastSeen);
    return d != 0 ? d : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return CrewStats(nights, members);
}

class HeroNight {
  final HomeSession session;
  final int logged;

  /// Null when that night's sample is too small to plot.
  final double? vpip, pfr, avgStrength, gto;
  HeroNight(this.session, this.logged, this.vpip, this.pfr, this.avgStrength, this.gto);
}

/// Your numbers per night, oldest first, for the season sparklines.
List<HeroNight> heroTrend(List<HomeSession> sessions, SpotLibrary lib) => [
      for (final s in _nights(sessions))
        () {
          final st = computeStats(s.hands, lib);
          return HeroNight(
            s,
            st.logged,
            st.recorded >= 5 ? st.vpipPct : null,
            st.recorded >= 5 ? st.pfrPct : null,
            st.dealt >= 5 && lib.vsRandom.isNotEmpty ? st.avgStrength : null,
            st.graded >= 3 ? st.gtoScore : null,
          );
        }(),
    ];
