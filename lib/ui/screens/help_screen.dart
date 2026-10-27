import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import 'about_screen.dart';

enum HelpTopic { train, charts, equity, stats, homeGame, terms }

const _topics = {
  HelpTopic.train: (
    Icons.fitness_center,
    'Train',
    [
      'You get a spot (your seat and what happened before you) plus two cards.',
      'Tap what you would do. Felt Notes grades it against GTO straight away: '
          'green = GTO play, gold = a mixed hand where either choice is fine, red = mistake.',
      'Read the bullet points for the why, check the chart (your hand is outlined in gold), then tap Next hand.',
      'The chip at the top right picks what you drill: all spots, 6-max 100bb, push/fold, '
          'or "Drill my leaks", which keeps serving the spots and hands you miss.',
      'Most hands dealt are borderline ones, because that is where mistakes happen.',
      'Daily 10 (gold card at the top): the same 10 hands for everyone today. One try per day; '
          'keep your streak going and tap Copy result to brag in the group chat.',
      'Drill my leaks uses spaced repetition: a hand you miss comes back in 10 minutes, then '
          'after 1, 3, 7 and 21 days as you keep getting it right. "N due" shows what is waiting. '
          'Mistakes from your home game are added automatically.',
      'Quizzes (quiz icon at the top): pot odds ("what equity do I need to call?") and '
          'range reading ("which hand is NOT in the button\'s opening range?"), 10 per session.',
    ]
  ),
  HelpTopic.charts: (
    Icons.grid_on,
    'Charts',
    [
      'Each grid shows all 169 starting hands. Pairs run down the diagonal, suited hands '
          'are above it, offsuit hands below.',
      'Colours: red = raise / 3-bet / all-in, green = call, dark = fold. A cell split '
          'between colours is a mixed hand: GTO plays it both ways at those rates.',
      'Colour blind? The ⋮ menu on Charts turns on colour-blind friendly charts: blue / orange '
          'plus stripes = raise, dots = call, plain = fold, on every grid and bar.',
      'Tap any hand for its frequencies and an explanation. "Drill" sends that spot to the trainer.',
      '6-max 100bb charts are approximate GTO baselines. Push/fold charts are an exact '
          'solution computed by Felt Notes.',
      'Push/fold "Players 3" shows 3-handed charts (BTN, SB, BB; 5–20bb, no ante): '
          'pick the decision with the chips, e.g. "BB overcall" when BTN jams and SB calls.',
    ]
  ),
  HelpTopic.equity: (
    Icons.percent,
    'Equity',
    [
      'Equity = your share of the pot if all the cards were run out.',
      'Hand vs hand: tap the empty card slots to pick cards, add up to 6 players, '
          'optionally add a board (3, 4 or 5 cards), then Calculate.',
      'Hand vs range: compare your hand against everything a player would hold in a spot, '
          'for example the hands the button opens.',
    ]
  ),
  HelpTopic.stats: (
    Icons.insights,
    'Stats',
    [
      'Fills in as you train. The grid colours each hand by how GTO you play it: green good, red leak.',
      '"Most teachable hands" lists your repeat mistakes, worst first. Tap one to review it.',
      'Spots are listed weakest first, each with a Drill button.',
      'Everything stays on this phone.',
    ]
  ),
  HelpTopic.homeGame: (
    Icons.groups,
    'Home game',
    [
      'Before the game: type the players in seat order going clockwise, pick your seat '
          'and who deals the first hand, then Start.',
      'Every hand, the fastest habit: boring hand → just tap Fold (no cards needed). '
          'Interesting hand → tap the card slots, pick your two cards, say whether it was '
          'folded to you or someone raised, then tap Fold, Call / limp or Raise.',
      'Log every hand, even with a single Fold tap. If you only log the hands you play, '
          'VPIP and PFR will make you look far looser than you are.',
      'The dealer moves one seat each time you log a hand, so your position is predicted. '
          'If it\'s wrong (you skipped hands, a re-deal), tap your real position or tap '
          '"Dealer" and pick who is dealing.',
      'Someone joins or leaves: ⋮ menu → Players & seats.',
      'Raise or fold mistakes in unopened pots pop up with a "Why?" link.',
      'The TV icon opens the dashboard. Mirror (cast) your phone screen to the TV to show it. '
          'By default it only shows hands from 15+ minutes ago, so nobody reads the last hand '
          'off the screen. Tap the clock at the top to choose Instant up to 60 minutes.',
      'Undo last fixes a mis-tap. End the game night from the ⋮ menu. Past nights stay listed.',
      'Snap my cards (Beta, phone only): tap the camera next to the card slots and photograph '
          'your two cards so the corners show. It reads them on the phone (nothing is uploaded); '
          'always check the suits before saving.',
      'Blind clock: from the setup screen or the ⋮ menu. Big countdown for the TV, levels and '
          'breaks you can edit, or Cash game mode. It keeps time even if the phone sleeps.',
      'End game night shows the Night Recap: best hand, cold streaks, card luck, awards and '
          '"Dealer of Doom" (who dealt you the worst cards). Copy it for the group chat.',
      'Crew & season (setup screen): everyone who has played, attendance streaks and your '
          'trends from night to night.',
      'Optional extras: tag a memorable hand (Bad beat, Cooler…) under the logger; it shows in '
          'the recap and, after the delay, on the dashboard. "Draw for the button" at setup deals '
          'a card to each seat (high card deals, ♠ > ♥ > ♦ > ♣ break ties). ⋮ → My result stores '
          'your own buy-in and cash-out (just you — nobody else\'s money is tracked). '
          'Badges for milestones are on Crew & season.',
    ]
  ),
  HelpTopic.terms: (
    Icons.menu_book,
    'Poker terms',
    [
      'GTO (game-theory optimal): a strategy that can\'t be exploited. The baseline a solver finds.',
      'bb: big blinds. Stacks and bets are measured in them.',
      'RFI (raise first in): opening the pot with a raise when everyone before you folded.',
      '3-bet: re-raising a raise (the blind is bet 1, the raise is bet 2).',
      'Push/fold: with short stacks the choice is simply all-in or fold.',
      'VPIP: % of hands you voluntarily put money in before the flop.',
      'PFR: % of hands you raised before the flop. Compared with VPIP it shows how aggressive you are.',
      'Positions: UTG (first to act) → HJ → CO → BTN (dealer, acts last) → SB → BB.',
    ]
  ),
};

class HelpScreen extends StatelessWidget {
  final HelpTopic? focus;
  const HelpScreen({super.key, this.focus});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('How to use Felt Notes')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          for (final e in _topics.entries)
            Card(
              child: ExpansionTile(
                initiallyExpanded: e.key == focus,
                leading: Icon(e.value.$1, color: Felt.gold),
                title: Text(e.value.$2, style: t.titleMedium),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in e.value.$3)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 7, right: 8),
                          child: Icon(Icons.circle, size: 6, color: Felt.gold),
                        ),
                        Expanded(child: Text(line, style: t.bodyMedium)),
                      ]),
                    ),
                ],
              ),
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline, color: Felt.gold),
              title: Text('About & privacy', style: t.titleMedium),
              subtitle: const Text('Version, privacy, credits, feedback, reset data'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const AboutScreen())),
            ),
          ),
        ],
      ),
    );
  }
}

/// "?" button for an AppBar that opens the guide at [topic].
class HelpButton extends StatelessWidget {
  final HelpTopic topic;
  const HelpButton(this.topic, {super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'How to use',
        icon: const Icon(Icons.help_outline),
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => HelpScreen(focus: topic))),
      );
}

/// Shows a one-time welcome the first time the app opens.
Future<void> maybeShowWelcome(BuildContext context) async {
  const key = 'seen_welcome_v1';
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(key) == true) return;
    await prefs.setBool(key, true);
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Welcome to Felt Notes'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• Train: tap what you\'d do with the hand shown and get graded against GTO.'),
          SizedBox(height: 6),
          Text('• Charts: the GTO strategy for every spot. Tap a hand to learn why.'),
          SizedBox(height: 6),
          Text('• Home game: at your poker night, log your two cards each hand and get live stats.'),
          SizedBox(height: 6),
          Text('Tap ? at the top of any screen for help.'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const HelpScreen()));
          },
          child: const Text('Full guide'),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Start training')),
      ],
    ),
  );
}
