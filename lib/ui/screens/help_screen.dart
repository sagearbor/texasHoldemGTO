import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_data.dart';
import '../../learn/glossary.dart';
import '../../trainer/trainer_model.dart';
import '../theme.dart';
import 'about_screen.dart';
import 'glossary_screen.dart';
import 'leak_test_screen.dart';
import 'settings_screen.dart';

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
      'Difficulty (in the drill menu or Settings): Beginner deals only clear-cut hands, Expert only '
          'borderline ones. When the solver mixes a hand, the "solver dice" show how it '
          'randomises between actions (Settings can hide the dice).',
      'Daily 10 (gold card at the top): the same 10 hands for everyone today. One try per day; '
          'keep your streak going and tap Copy result to brag in the group chat.',
      'Drill my leaks uses spaced repetition: a hand you miss comes back in 10 minutes, then '
          'after 1, 3, 7 and 21 days as you keep getting it right. "N due" shows what is waiting. '
          'Mistakes from your home game are added automatically.',
      'The 60-second leak test (offered on first launch, retake it at the bottom of this '
          'page): 10 fast borderline hands, then plain-language leaks such as "you defend '
          'too little from the big blind". "Drill my leaks" queues every hand you missed.',
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
      'Colour blind? The menu at the top right of Charts (or Settings) turns on colour-blind friendly charts: blue / orange '
          'plus stripes = raise, dots = call, plain = fold, on every grid and bar.',
      'Tap any hand for its frequencies and an explanation. "Drill" sends that spot to the trainer.',
      'My mistakes (toggle above the grid): each hand coloured by how often you got it right in '
          'that spot (or the whole group), recent answers counting most. Grey = not drilled yet. '
          '"Drill my weak hands" deals mostly the reddest cells.',
      '6-max 100bb charts are approximate GTO baselines. Push/fold charts are an exact '
          'solution computed by Felt Notes.',
      'River spots (solved), at the bottom of Charts: 258 river boards solved with CFR+ for '
          'BB vs BTN, in single-raised and 3-bet pots, across six board textures, with 33%, 75% '
          'and 150% bets and all-in raises. Browse each decision as a grid, read the value/bluff '
          'summary, or drill it. Each board shows how exploitable its solution is. Ranges are '
          'simplified (no flop/turn narrowing), so treat exact numbers as illustrative.',
      'Short stack (Charts): solved jam-or-fold spots for cash games when the big blind has '
          '15, 20 or 25bb: should the BB jam over an open, and should the opener call the jam? '
          'The opening ranges are the approximate 100bb charts; the rest is solver output.',
      'Facing limpers: iso-raise, overlimp or fold charts for limp-heavy home games '
          '(hand-authored approximations).',
      'Facing a 3-bet: you opened and got 3-bet. 4-bet (22bb in position, 25bb out of '
          'position), call or fold, for the most common seat pairs (hand-authored '
          'approximations). Hands you would not have opened are faded.',
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
      'GTO score over time (chart icon at the top): your accuracy per week or per day, '
          'plus the GTO grade of each home-game night.',
      'Everything stays on this phone.',
    ]
  ),
  HelpTopic.homeGame: (
    Icons.groups,
    'Home game',
    [
      'Before the game: type who is playing (any order), pick yourself, then Start. '
          'Leave "Learn the seats from the deal" on and you never type the seat order.',
      'First orbit, organizer only: tap the name of whoever is dealing, each hand, as the '
          'deal goes round. That tap order becomes the seating. After one orbit the button '
          'moves by itself and you get one big Next hand button.',
      'Every hand, the fastest habit: do nothing on hands you fold. An untouched hand '
          'counts as a fold when Next hand is tapped. Played it? Use the big pad at the '
          'bottom without looking: tap = call / limp, swipe up = raise, swipe down = undo, '
          'swipe sideways = Next hand. Each one buzzes differently.',
      'The buttons in the hand card do the same, and also record whether it was folded '
          'to you or someone raised (needed for the GTO grade). Cards are optional: tap the '
          'card slots; they are saved with the hand at Next hand.',
      '"Didn\'t see this hand" saves it as unknown instead of a fold, so it does not '
          'count for VPIP or PFR.',
      'Your position is predicted from the button. If it\'s wrong (a re-deal), tap your '
          'real position or tap "Dealer" and pick who is dealing. Someone new deals? Pick '
          '"Someone new" there and they are seated where they dealt.',
      'Someone joins or leaves: the menu at the top right → Players & seats.',
      'Raise or fold mistakes in unopened pots pop up with a "Why?" link.',
      'The TV icon opens the dashboard. Mirror (cast) your phone screen to the TV to show it. '
          'By default it only shows hands from 15+ minutes ago, so nobody reads the last hand '
          'off the screen. Tap the clock at the top to choose Instant up to 60 minutes.',
      'Undo last fixes a mis-tap. End the game night from the menu at the top right. Past nights stay listed.',
      'Snap my cards (Beta): tap the camera next to the card slots, then take or pick a photo '
          'of your two cards so the corners show. It reads them on your device (nothing is '
          'uploaded) and also hints the street from the board cards it sees; always check the '
          'cards before saving.',
      'Board caller (optional): whoever reads the flop, turn and river aloud holds the mic '
          'button under the hand and says it, e.g. "flop king of hearts seven of spades four '
          'of clubs", then "turn jack diamonds". Speech is recognised on the phone and never '
          'recorded. Or tap the keyboard to type "Kh 7s 4c", or ✎ to pick the cards. The board '
          'is saved with the hand when you log it.',
      'Remembered your cards late? Enter them, tap "That was hand…" and pick the hand by its '
          'board: they go on that hand instead of the one being played now.',
      'With boards the Night Recap adds flops seen and your best made hand.',
      'Blind clock: from the setup screen or the menu at the top right. It starts as a '
          'cash game (stakes on the TV, no timer). For a tournament pick Tournament clock in '
          'its menu: a big countdown, levels and breaks you can edit. It keeps time even if '
          'the phone sleeps.',
      'End game night shows the Night Recap: best hand, cold streaks, card luck, awards and '
          '"Dealer of Doom" (who dealt you the worst cards). Copy it for the group chat.',
      'Crew & season (setup screen): everyone who has played, attendance streaks and your '
          'trends from night to night.',
      'Optional extras: tag a memorable hand (Bad beat, Cooler…) under the logger; it shows in '
          'the recap and, after the delay, on the dashboard. "Draw for the button" at setup deals '
          'a card to each seat (high card deals, ♠ > ♥ > ♦ > ♣ break ties). The menu at the top right → My result stores '
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
      'More terms: the Glossary (book icon at the top of Train and Home game, or at the top '
          'of this page). Tap a seat on the table diagram to look it up.',
    ]
  ),
};

class HelpScreen extends StatelessWidget {
  final HelpTopic? focus;
  const HelpScreen({super.key, this.focus});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final trainer = AppScope.maybeOf(context)?.trainer;
    return Scaffold(
      appBar: AppBar(title: const Text('How to use Felt Notes')),
      body: Felt.narrow(ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          Card(
            child: ListTile(
              key: const Key('help-settings'),
              leading: Icon(Icons.settings_outlined, color: Felt.accent(context)),
              title: Text('Settings', style: t.titleMedium),
              subtitle: const Text('Theme, cards, difficulty, currency'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openSettings(context),
            ),
          ),
          Card(
            child: ListTile(
              key: const Key('help-glossary'),
              leading: Icon(Icons.menu_book_outlined, color: Felt.accent(context)),
              title: Text('Glossary', style: t.titleMedium),
              subtitle: Text('${glossary.length} poker terms in plain English'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openGlossary(context),
            ),
          ),
          for (final e in _topics.entries)
            Card(
              child: ExpansionTile(
                initiallyExpanded: e.key == focus,
                leading: Icon(e.value.$1, color: Felt.accent(context)),
                title: Text(e.value.$2, style: t.titleMedium),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in e.value.$3)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 7, right: 8),
                          child: Icon(Icons.circle, size: 6, color: Felt.accent(context)),
                        ),
                        Expanded(child: Text(line, style: t.bodyMedium)),
                      ]),
                    ),
                ],
              ),
            ),
          if (trainer != null)
            Card(
              child: ListTile(
                leading: Icon(Icons.timer_outlined, color: Felt.accent(context)),
                title: Text('Retake the leak test', style: t.titleMedium),
                subtitle: const Text('10 fast hands, then your leaks in plain words'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openLeakTest(context, trainer),
              ),
            ),
          Card(
            child: ListTile(
              leading: Icon(Icons.info_outline, color: Felt.accent(context)),
              title: Text('About & privacy', style: t.titleMedium),
              subtitle: const Text('Version, privacy, credits, feedback, reset data'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const AboutScreen())),
            ),
          ),
        ],
      )),
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

/// First launch: the onboarding flow (welcome card + optional 60-second
/// leak test). Existing users who already saw the old welcome dialog
/// ('seen_welcome_v1' true) never get it automatically; they can take the
/// test from Help.
Future<void> maybeShowWelcome(BuildContext context, TrainerModel model) async {
  const key = 'seen_welcome_v1';
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(key) == true) return;
    await prefs.setBool(key, true);
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => OnboardingFlow(model: model)));
}
