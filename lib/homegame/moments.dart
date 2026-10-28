/// Short callouts for the TV dashboard and its "Tonight's drama" line.
/// Callers pass only the hands the dashboard may show (past the delay).
library;

import '../gto/hand_class.dart';
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

/// Someone's hole cards for a hand (null when they did not log them).
/// Today only yours exist; a later multi-phone sync supplies the others.
class ShownHand {
  final String player;
  final List<int>? cards;
  const ShownHand(this.player, this.cards);

  /// "Sage AKo", or just "Sage" without cards.
  String get label {
    final c = cards;
    if (c == null || c.length < 2) return player;
    return '$player ${HandClass.fromCards(c[0], c[1]).name}';
  }
}

/// Other players' shared cards for [h], for the drama line. Single-phone
/// nights have none.
typedef SharedCards = List<ShownHand> Function(LoggedHand h);

List<ShownHand> _none(LoggedHand h) => const [];

/// Local wall-clock time, 12-hour: "8:22pm", "12:05am".
String clockLabel(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')}${d.hour < 12 ? 'am' : 'pm'}';
}

/// Who was in it: "Sage AKo", or "John KK vs Joe AA" once others' cards
/// for the same hand are shared.
String storyPlayers(LoggedHand h,
        {String hero = 'Me', List<ShownHand> others = const []}) =>
    [ShownHand(hero, h.cards), ...others].map((p) => p.label).join(' vs ');

/// "Bad beat · Sage AKo · 8:22pm" (local time the hand ended).
String storyLine(LoggedHand h,
        {String hero = 'Me', List<ShownHand> others = const []}) =>
    '${storyTagLabels[h.tag]} · ${storyPlayers(h, hero: hero, others: others)} · ${clockLabel(h.ts)}';

/// "Tonight's drama" for the dashboard: up to [max] newest stories, or null.
String? dramaLine(List<LoggedHand> shown,
    {String hero = 'Me', SharedCards shared = _none, int max = 3}) {
  final s = stories(shown);
  if (s.isEmpty) return null;
  return [
    for (final h in s.take(max)) storyLine(h, hero: hero, others: shared(h))
  ].join('  |  ');
}

List<Moment> dashboardMoments(List<LoggedHand> shown, SpotLibrary lib,
    {String hero = 'Me', SharedCards shared = _none}) {
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
        '${storyPlayers(story, hero: hero, others: shared(story))} · ${clockLabel(story.ts)}'));
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
