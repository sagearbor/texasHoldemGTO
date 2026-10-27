import 'package:flutter/material.dart';

/// Placeholder for the home-game mode (phase 2). Explains what is coming so
/// the tab is useful to share with the group before it ships.
class HomeGameScreen extends StatelessWidget {
  const HomeGameScreen({super.key});

  static const _items = [
    (Icons.style, 'Log your own cards',
        'Tap or snap your hole cards each hand. Seats stay fixed, so Felt Notes knows your position.'),
    (Icons.tv, 'Live TV dashboard',
        'Cast a leaderboard, player-style map, luck meter and blind timer to the TV while phones stay in hand.'),
    (Icons.emoji_events, 'End-of-night awards',
        'Calling Station of the Month, Biggest Suckout, Nit Award, Luckiest and Unluckiest.'),
    (Icons.lock_outline, 'Private GTO report card',
        'Your preflop decisions graded against the solver. Only you see it unless you share.'),
    (Icons.visibility_outlined, 'Give to get',
        'Share your hands with the table to see theirs. Keep yours hidden and theirs stay hidden too.'),
    (Icons.people_alt_outlined, 'Rivalries and predictions',
        'Head-to-head records, pre-game "who wins tonight" picks and achievement badges.'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Home game')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text('Coming next', style: t.headlineSmall),
          const SizedBox(height: 4),
          Text('Stats for your monthly game, built so nobody has to keep score.',
              style: t.bodyMedium),
          const SizedBox(height: 12),
          for (final (icon, title, body) in _items)
            Card(
              child: ListTile(
                leading: Icon(icon),
                title: Text(title),
                subtitle: Text(body),
              ),
            ),
        ],
      ),
    );
  }
}
