/// Short callouts for the TV dashboard and its "Tonight's drama" line.
/// Callers pass only the hands the dashboard may show (past the delay).
library;

import '../gto/spots.dart';
import 'home_game.dart';
import 'recap.dart';

const _premiums = {'AA', 'KK', 'QQ', 'JJ', 'AKs', 'AKo'};

class Moment {
  /// Small caps label, the big-type headline, and one line of detail.
  final String label, headline, detail;
  const Moment(this.label, this.headline, this.detail);
}

/// Trailing run of recorded folds (hands with no action are ignored).
int currentFoldStreak(List<LoggedHand> hands) {
  var n = 0;
  for (final h in hands.reversed) {
    final a = h.action;
    if (a == null) continue;
    if (a != PreAction.fold) break;
    n++;
  }
  return n;
}

/// Tagged hands, newest first.
List<LoggedHand> stories(Iterable<LoggedHand> hands) =>
    [for (final h in hands) if (h.tag != null) h].reversed.toList();

/// "Bad beat · hand #12 · AKo"
String storyLine(LoggedHand h) =>
    '${storyTagLabels[h.tag]} · hand #${h.number}${h.hand == null ? '' : ' · ${h.hand!.name}'}';

/// "Tonight's drama" for the dashboard: up to [max] newest stories, or null.
String? dramaLine(List<LoggedHand> shown, {int max = 3}) {
  final s = stories(shown);
  if (s.isEmpty) return null;
  return [for (final h in s.take(max)) '${storyTagLabels[h.tag]} (#${h.number})'].join(' · ');
}

List<Moment> dashboardMoments(List<LoggedHand> shown, SpotLibrary lib) {
  final out = <Moment>[];
  for (final h in shown.reversed) {
    final hc = h.hand;
    if (hc != null && _premiums.contains(hc.name)) {
      out.add(Moment('Newest premium', hc.name, 'Hand #${h.number} from ${h.position}'));
      break;
    }
  }
  final streak = currentFoldStreak(shown);
  if (streak >= RecapGates.foldStreakMin) {
    out.add(Moment('Fold streak', '$streak', 'folds in a row and counting'));
  }
  if (lib.vsRandom.isNotEmpty) {
    final dealt = [for (final h in shown) if (h.hand != null) lib.vsRandom[h.hand!.index]];
    if (dealt.length >= 10) {
      final last = dealt.sublist(dealt.length - 10);
      final avg = last.reduce((a, b) => a + b) / 10;
      out.add(Moment('Last 10 hands', luckLabel(avg), 'card luck vs a random hand'));
    }
  }
  final golden = dealerLuck(shown, lib).goldenArm;
  if (golden != null) {
    out.add(Moment('Golden Arm', golden.name,
        'card luck ${luckLabel(golden.avgEquity)} over ${golden.hands} hands'));
  }
  final story = stories(shown).firstOrNull;
  if (story != null) {
    out.add(Moment("Tonight's drama", storyTagLabels[story.tag]!,
        'Hand #${story.number}${story.hand == null ? '' : ' · ${story.hand!.name}'}'));
  }
  if (shown.length >= 5) {
    final ts = [for (final h in shown) h.ts]..sort();
    final span = ts.last - ts.first;
    if (span >= 15 * 60000) {
      final perHour = shown.length / (span / 3600000);
      out.add(Moment('Hands per hour', perHour.round().toString(),
          '${shown.length} hands in ${durationLabel(Duration(milliseconds: span))}'));
    }
  }
  return out;
}
