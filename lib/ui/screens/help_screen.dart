import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_data.dart';
import '../../learn/glossary.dart';
import '../../trainer/trainer_model.dart';
import '../app_settings.dart';
import '../dev_mode.dart';
import '../theme.dart';
import 'about_screen.dart';
import 'glossary_screen.dart';
import 'leak_test_screen.dart';
import 'settings_screen.dart';

/// One help topic per screen: the Learn sections, Play and History.
enum HelpTopic { train, charts, equity, stats, play, history }

/// One help line: a short [title] anyone can scan, the long [detail] on tap.
/// [dev] lines describe developer-mode tools and are hidden otherwise.
class HelpTip {
  final String title;
  final String? detail;
  final bool dev;
  const HelpTip(this.title, [this.detail, this.dev = false]);
}

class HelpTopicInfo {
  final IconData icon;
  final String title;

  /// One line on the Help page.
  final String summary;
  final List<HelpTip> tips;
  const HelpTopicInfo(this.icon, this.title, this.summary, this.tips);
}

const helpTopics = {
  HelpTopic.train: HelpTopicInfo(Icons.fitness_center, 'Learn: Train', 'Play hands, get graded against GTO', [
    HelpTip('You get a spot and two cards: tap your play.',
        'The spot is your seat and what happened before you. Felt Notes grades your answer straight away, '
            'with the reasons in bullet points and the chart (your hand outlined in gold). Then tap Next hand.'),
    HelpTip('Green = GTO play, gold = mixed (either is fine), red = mistake.'),
    HelpTip('The chip at the top right picks what you drill.',
        'All spots, 6-max 100bb, push/fold, or "Drill my leaks". Most hands dealt are borderline ones, '
            'because that is where mistakes happen.'),
    HelpTip('Daily 10: the same 10 hands for everyone today.',
        'One try per day. Keep your streak going and tap Copy result to brag in the group chat.'),
    HelpTip('Drill my leaks brings back the hands you miss.',
        'Spaced repetition: a missed hand comes back in 10 minutes, then after 1, 3, 7 and 21 days as you keep '
            'getting it right. "N due" shows what is waiting. Mistakes from your home game are added too.'),
    HelpTip('Difficulty and the solver dice are in Settings.',
        'Beginner deals only clear-cut hands, Expert only borderline ones. When the solver mixes a hand, the '
            'solver dice show how it randomises between actions.'),
    HelpTip('Quizzes (quiz icon): pot odds and range reading.', '10 questions per session.'),
    HelpTip('The 60-second leak test: 10 fast hands, then your leaks.',
        'Plain-language leaks such as "you defend too little from the big blind". Retake it from Help.'),
  ]),
  HelpTopic.charts: HelpTopicInfo(Icons.grid_on, 'Learn: Charts', 'Every preflop spot as a 13x13 grid', [
    HelpTip('Pick the format and the spot at the top; the grid shows all 169 hands.',
        'Pairs run down the diagonal, suited hands above it, offsuit hands below.'),
    HelpTip('Red = raise / all-in, green = call, dark = fold.',
        'A cell split between colours is a mixed hand: GTO plays it both ways at those rates.'),
    HelpTip('Tap a hand for its frequencies and why. Drill sends the spot to Train.'),
    HelpTip('My mistakes: the grid coloured by how often you got each hand right.',
        'Recent answers count most. Grey = not drilled yet. "Drill my weak hands" deals mostly the reddest cells.'),
    HelpTip('Colour-blind charts: the menu at the top right, or Settings.',
        'Blue / orange plus patterns: stripes = raise, dots = call, plain = fold, on every grid and bar.'),
    HelpTip('6-max 100bb, Short stack and Push/fold.',
        '6-max 100bb charts are approximate GTO baselines (facing limpers and facing a 3-bet are hand-authored '
            'approximations). Short stack: solved jam-or-fold spots when the big blind has 15, 20 or 25bb. '
            'Push/fold is an exact solution computed by Felt Notes; "Players 3" shows 3-handed charts.'),
    HelpTip('River spots (solved): at the bottom of Charts.',
        '258 river boards solved with CFR+ for BB vs BTN, single-raised and 3-bet pots. Ranges are simplified, '
            'so treat exact numbers as illustrative.'),
  ]),
  HelpTopic.equity: HelpTopicInfo(Icons.percent, 'Learn: Equity', 'Who is ahead, hand vs hand or range', [
    HelpTip('Equity = your share of the pot if all the cards were run out.'),
    HelpTip('Hand vs hand: tap the card slots, add players and a board, then Calculate.',
        'Up to 6 players; the board can have 3, 4 or 5 cards.'),
    HelpTip('Hand vs range: your hand against everything a player holds in a spot.'),
  ]),
  HelpTopic.stats: HelpTopicInfo(Icons.insights, 'Learn: Stats', 'Your accuracy and repeat mistakes', [
    HelpTip('Fills in as you train: green = good, red = leak.'),
    HelpTip('"Most teachable hands" lists your repeat mistakes, worst first.'),
    HelpTip('Spots are listed weakest first, each with a Drill button.'),
    HelpTip('GTO score over time: the chart icon at the top.',
        'Your accuracy per week or per day, plus the GTO grade of each home-game night.'),
  ]),
  HelpTopic.play: HelpTopicInfo(Icons.style_outlined, 'Play', 'Host or join a game night, log your hands', [
    HelpTip('Join: games at your table show up on Play. Tap Join.',
        'Tap Find games nearby once and allow Bluetooth (no internet needed). It only looks while Play is on '
            'screen and uses your name from Settings. In a game the phone also notes how strong the other '
            'Felt Notes phones\' signals are, for a seat-finding experiment; that is never shown and stays on the '
            'phone with sharing off.'),
    HelpTip("Not listed? Tap Scan the host's code.",
        "Photograph the host's QR once (or type the code), pick your name, then tap only Call or Raise on "
            'hands you play.'),
    HelpTip('Host a game: check the names, pick yourself, Start.',
        'The names are filled in for you (your name, then Player 2, Player 3...). Leave "Learn the seats from '
            'the deal" on and you never type the seat order.'),
    HelpTip('First orbit (host): tap whoever is dealing, each hand.',
        'That tap order becomes the seating. After one orbit the button moves by itself and you get one big '
            'Next hand button.'),
    HelpTip('Folded? Do nothing. Played it? Use the big pad.',
        'An untouched hand counts as a fold at Next hand. On the pad: tap = call / limp, swipe up = raise, '
            'swipe down = undo, swipe sideways = Next hand. Each buzzes differently. "Didn\'t see this hand" '
            'saves it as unknown instead of a fold.'),
    HelpTip('Wrong position or a mis-tap? Undo last, or tap the real position.',
        'Tap "Dealer" to pick who is dealing; "Someone new" seats a new dealer where they dealt. Someone joins '
            'or leaves: the menu at the top right, Players & seats.'),
    HelpTip('Cards are optional: tap the card slots, or Camera.',
        'Camera opens Watch my cards (Beta): prop the phone beside you, aim, Start. The screen goes black and '
            'your cards are read when you peek, on the phone; nothing is uploaded, and nothing is recorded '
            'unless you turn on "Also record the table" (photos stay on the phone, export from Recordings). '
            'The dim pad at the bottom of the black screen logs your action: tap call, swipe up raise, down '
            'undo, sideways next hand; doing nothing is a fold. With earbuds it says the cards quietly. '
            'Wrong? Tap the chip on the black screen. "Just one photo" reads a single photo instead. '
            'Remembered your cards late? Enter them and tap "That was hand...".'),
    HelpTip('Board caller: hold the mic button and say the flop.',
        'For example "flop king of hearts seven of spades four of clubs", then "turn jack diamonds". Or tap '
            'the keyboard to type "Kh 7s 4c". Speech is recognised on the phone and never recorded.'),
    HelpTip('Show on the TV: Cast to a Chromecast, or open the TV link.',
        'Cast to a TV (Android, same Wi-Fi): the TV runs the table by itself; only the night code is sent. '
            'No Chromecast? Open the link under the QR on a laptop or tablet. The TV shows hands from 15+ '
            'minutes ago by default (Settings, or the clock at the top of the dashboard).'),
    HelpTip('Blind clock: Host a game, or the menu at the top right.',
        'Starts as a cash game (stakes, no timer). Tournament clock: countdown, levels and breaks you can edit.'),
    HelpTip('What a table night shares.',
        'Your hands stay on your phone (only that you joined, by name, goes up) unless you turn on '
            '"Share my hands with the table": then your call / raise taps, and your cards only after the hand is '
            'over. Hosting works the same; the switch is on the QR sheet. For the seat radar, "Share seat-finding '
            'signals (Bluetooth)" is on by default: which Felt Notes phones yours hears and how loud, and your '
            'phone model; nothing about cards or actions. Both switches are under Advanced. No account (an anonymous id), readable only with the night\'s code, deleted after '
            'about 60 days. Your money never leaves the phone.'),
    HelpTip('End game night (top right menu) shows the Night Recap.',
        'Best hand, cold streaks, card luck, awards and "Dealer of Doom". Copy it for the group chat.'),
    HelpTip('Record the table (developer mode).',
        'Prop the phone where it sees the whole table, plugged in. Saves 1 to 2 photos a second and a log on '
            'this phone only (about 2 to 3 GB an hour). Hold the red button to stop.',
        true),
  ]),
  HelpTopic.history: HelpTopicInfo(Icons.history, 'History', 'Past nights, recaps and your crew', [
    HelpTip('Each past night has its Recap and Dashboard.'),
    HelpTip('Crew & season: attendance, streaks, badges and trends.'),
    HelpTip('My result (menu during a night): your own buy-in and cash-out.', 'Nobody else\'s money is tracked.'),
    HelpTip('Everything stays on this phone: back it up from About & privacy.'),
  ]),
};

class HelpScreen extends StatelessWidget {
  /// The topic of the screen the "?" was tapped on, shown first.
  final HelpTopic? focus;
  const HelpScreen({super.key, this.focus});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final trainer = AppScope.maybeOf(context)?.trainer;
    final accent = Felt.accent(context);
    Widget header(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
          child: Text(s, style: t.labelLarge?.copyWith(color: accent)),
        );
    Widget tile(IconData icon, String title, String subtitle, VoidCallback onTap, {Key? key, Color? subColor}) =>
        Card(
          child: ListTile(
            key: key,
            leading: Icon(icon, color: accent),
            title: Text(title, style: t.titleMedium),
            subtitle: Text(subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: subColor == null ? null : TextStyle(color: subColor)),
            trailing: const Icon(Icons.chevron_right),
            onTap: onTap,
          ),
        );
    Widget topic(HelpTopic k, {Key? key}) {
      final i = helpTopics[k]!;
      return tile(i.icon, i.title, i.summary, () => openHelpTopic(context, k), key: key);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: Felt.narrow(ValueListenableBuilder<String>(
        valueListenable: AppSettings.playerName,
        builder: (context, name, _) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
          children: [
            if (focus != null) ...[header('This screen'), topic(focus!, key: const Key('help-focus'))],
            header('Settings'),
            tile(
              Icons.settings_outlined,
              'Settings',
              name.trim().isEmpty ? 'Your name is not set' : 'Your name, camera lens, appearance',
              () => openSettings(context),
              key: const Key('help-settings'),
              subColor: name.trim().isEmpty ? Theme.of(context).colorScheme.error : null,
            ),
            tile(Icons.info_outline, 'About & privacy', 'Version, privacy, backup, feedback',
                () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen()))),
            header('How to use'),
            for (final k in HelpTopic.values)
              if (k != focus) topic(k),
            header('More'),
            tile(Icons.menu_book_outlined, 'Glossary', '${glossary.length} poker terms in plain English',
                () => openGlossary(context),
                key: const Key('help-glossary')),
            if (trainer != null)
              tile(Icons.timer_outlined, 'Retake the leak test', '10 fast hands, then your leaks',
                  () => openLeakTest(context, trainer)),
          ],
        ),
      )),
    );
  }
}

void openHelpTopic(BuildContext context, HelpTopic k) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => HelpTopicScreen(topic: k)));

/// One topic: a short line per tip; tips with more to say expand on tap.
class HelpTopicScreen extends StatelessWidget {
  final HelpTopic topic;
  const HelpTopicScreen({super.key, required this.topic});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final info = helpTopics[topic]!;
    final accent = Felt.accent(context);
    final tips = [
      for (final tip in info.tips)
        if (!tip.dev || DevMode.on.value) tip
    ];
    return Scaffold(
      appBar: AppBar(title: Text(info.title)),
      body: Felt.narrow(ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          Card(
            child: Column(children: [
              for (final tip in tips)
                tip.detail == null
                    ? ListTile(
                        leading: Icon(Icons.circle, size: 8, color: accent),
                        minLeadingWidth: 8,
                        title: Text(tip.title, style: t.bodyLarge),
                      )
                    : ExpansionTile(
                        leading: Icon(Icons.circle, size: 8, color: accent),
                        title: Text(tip.title, style: t.bodyLarge),
                        shape: const Border(),
                        collapsedShape: const Border(),
                        childrenPadding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        children: [Text(tip.detail!, style: t.bodyMedium)],
                      ),
            ]),
          ),
        ],
      )),
    );
  }
}

/// "?" button for an AppBar: Help, with [topic] (this screen) first.
class HelpButton extends StatelessWidget {
  final HelpTopic topic;
  const HelpButton(this.topic, {super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Help',
        icon: const Icon(Icons.help_outline),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => HelpScreen(focus: topic))),
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
