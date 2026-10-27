import 'package:flutter/material.dart';

import '../../homegame/home_game.dart';

/// Optional one-tap story for the hand just logged. Tap again to clear.
/// Never required: the next hand can be logged straight away.
class StoryTagRow extends StatelessWidget {
  final HomeGameModel model;
  final LoggedHand hand;
  const StoryTagRow({super.key, required this.model, required this.hand});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Hand #${hand.number} a story? (optional)', style: t.labelMedium),
        const SizedBox(height: 2),
        Wrap(spacing: 6, runSpacing: 0, children: [
          for (final tag in StoryTag.values)
            ChoiceChip(
              label: Text(storyTagLabels[tag]!),
              selected: hand.tag == tag,
              visualDensity: VisualDensity.compact,
              onSelected: (on) => model.setTag(hand, on ? tag : null),
            ),
        ]),
      ]),
    );
  }
}
