/// Lifetime badges across every game night. A pure function of the stored
/// sessions: each badge has a fixed title and a fixed rule.
library;

import '../gto/spots.dart';
import 'home_game.dart';
import 'recap.dart';

enum MilestoneId {
  hands100,
  hands500,
  hands1000,
  pocketAces,
  nights5,
  nights10,
  regular,
  foldStreak20,
  gtoA,
  storyteller,
  winningNight,
}

class Milestone {
  final MilestoneId id;
  final String title;

  /// What it takes, in plain words.
  final String rule;
  final int progress, target;
  const Milestone(this.id, this.title, this.rule, this.progress, this.target);

  bool get unlocked => progress >= target;
}

/// Most days allowed between two nights for them to count as "in a row".
const regularGapDays = 8;

List<Milestone> milestones(List<HomeSession> sessions, SpotLibrary lib) {
  final nights = [for (final s in sessions) if (s.hands.isNotEmpty) s]
    ..sort((a, b) => a.started.compareTo(b.started));
  var logged = 0, stories = 0, bestFold = 0, gtoA = 0, winning = 0, aces = 0;
  for (final s in nights) {
    logged += s.hands.length;
    var run = 0;
    for (final h in s.hands) {
      if (h.tag != null) stories++;
      if (h.hand?.name == 'AA') aces++;
      final a = h.action;
      if (a == null) continue;
      run = a == PreAction.fold ? run + 1 : 0;
      if (run > bestFold) bestFold = run;
    }
    final st = computeStats(s.hands, lib);
    if (st.graded >= RecapGates.gtoMinGraded && letterGrade(st.gtoScore) == 'A') gtoA++;
  }
  for (final s in sessions) {
    final n = s.net;
    if (n != null && n > 0) winning++;
  }
  var regular = nights.isEmpty ? 0 : 1;
  var run = regular;
  for (var i = 1; i < nights.length; i++) {
    final gap = nights[i].started - nights[i - 1].started;
    run = gap <= regularGapDays * Duration.millisecondsPerDay ? run + 1 : 1;
    if (run > regular) regular = run;
  }
  return [
    Milestone(MilestoneId.hands100, 'Century', 'Log 100 hands', logged, 100),
    Milestone(MilestoneId.hands500, 'Grinder', 'Log 500 hands', logged, 500),
    Milestone(MilestoneId.hands1000, 'Iron Butt', 'Log 1,000 hands', logged, 1000),
    Milestone(MilestoneId.pocketAces, 'Pocket Rockets', 'Get dealt pocket aces', aces, 1),
    Milestone(MilestoneId.nights5, 'Regular Seat', 'Play 5 game nights', nights.length, 5),
    Milestone(MilestoneId.nights10, 'Season Ticket', 'Play 10 game nights', nights.length, 10),
    Milestone(MilestoneId.regular, 'Never Miss a Week',
        '3 nights in a row, each within $regularGapDays days of the last', regular, 3),
    Milestone(MilestoneId.foldStreak20, 'Survivor', 'Fold 20 hands in a row in one night',
        bestFold, 20),
    Milestone(MilestoneId.gtoA, 'Straight-A Night', 'Score an A for GTO preflop on a night',
        gtoA, 1),
    Milestone(MilestoneId.storyteller, 'Storyteller', 'Tag 10 hands with a story', stories, 10),
    Milestone(MilestoneId.winningNight, 'In the Black',
        'Cash out more than you bought in (My result)', winning, 1),
  ];
}
