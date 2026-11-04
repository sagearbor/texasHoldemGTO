import 'package:flutter/material.dart';

/// The Learn tab: today's Train, Charts, Equity and Stats screens, unchanged,
/// under one segmented header. Each keeps its own app bar and actions.
class LearnScreen extends StatelessWidget {
  final int index;
  final ValueChanged<int> onIndex;

  /// Train, Charts, Equity, Stats, in that order.
  final List<Widget> pages;
  const LearnScreen({super.key, required this.index, required this.onIndex, required this.pages});

  static const labels = ['Train', 'Charts', 'Equity', 'Stats'];

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                key: const Key('learn-tabs'),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  for (var i = 0; i < labels.length; i++)
                    ButtonSegment(
                      value: i,
                      label: Text(labels[i], key: Key('learn-tab-$i'), maxLines: 1, softWrap: false),
                    ),
                ],
                selected: {index},
                onSelectionChanged: (v) => onIndex(v.first),
              ),
            ),
          ),
        ),
      ),
      // The header took the status-bar inset; the screens' own app bars
      // must not add it again.
      Expanded(
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: IndexedStack(index: index, children: pages),
        ),
      ),
    ]);
  }
}
