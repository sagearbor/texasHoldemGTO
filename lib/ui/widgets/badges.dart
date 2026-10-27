import 'package:flutter/material.dart';

import '../../homegame/milestones.dart';
import '../theme.dart';

/// One-time "Badge unlocked" after a log triggers one or more milestones.
void showBadgeSnack(BuildContext context, List<Milestone> fresh) {
  if (fresh.isEmpty) return;
  final more = fresh.length - 1;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Row(children: [
      const Icon(Icons.military_tech, color: Felt.gold),
      const SizedBox(width: 10),
      Expanded(
        child: Text('Badge unlocked: ${fresh.first.title}'
            '${more > 0 ? ' (+$more more)' : ''}'),
      ),
    ]),
  ));
}

/// Every badge, earned ones in gold, the rest with progress.
class BadgeWall extends StatelessWidget {
  final List<Milestone> badges;
  const BadgeWall({super.key, required this.badges});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final earned = badges.where((b) => b.unlocked).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$earned of ${badges.length} earned', style: t.bodyMedium),
      const SizedBox(height: 4),
      for (final b in badges)
        Card(
          child: ListTile(
            dense: true,
            leading: Icon(b.unlocked ? Icons.military_tech : Icons.lock_outline,
                color: b.unlocked ? Felt.gold : cs.onSurface.withOpacity(0.4)),
            title: Text(b.title,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: b.unlocked ? null : cs.onSurface.withOpacity(0.6))),
            subtitle: Text(b.rule),
            trailing: b.unlocked || b.target == 1
                ? null
                : Text('${b.progress.clamp(0, b.target)}/${b.target}', style: t.labelMedium),
          ),
        ),
    ]);
  }
}
