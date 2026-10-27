import 'package:flutter/material.dart';

import '../../gto/coach.dart' show pct;
import '../../gto/hand_class.dart';
import '../../gto/river.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';
import 'river_drill_screen.dart';

/// Colour for a river action (check/call green, bets red by size, fold grey).
Color riverActionColor(String a, Brightness b) {
  if (a == 'Fold') return Felt.actionColor('Fold', b);
  if (a == 'Check' || a == 'Call') return Felt.call;
  if (a == 'Bet 33%') return const Color(0xFFF08C4A);
  if (a == 'All-in') return const Color(0xFF8E1B2A);
  return Felt.aggressive;
}

/// Browser for the pre-solved river library.
class RiverScreen extends StatefulWidget {
  /// Preloaded data (tests); otherwise loaded from the asset bundle.
  final RiverLibrary? library;
  const RiverScreen({super.key, this.library});

  @override
  State<RiverScreen> createState() => _RiverScreenState();
}

class _RiverScreenState extends State<RiverScreen> {
  int boardIdx = 0;
  String nodeId = 'root';

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RiverLibrary>(
      future: widget.library != null
          ? Future.value(widget.library)
          : RiverLibrary.load(),
      builder: (context, snap) {
        final lib = snap.data;
        return Scaffold(
          appBar: AppBar(title: const Text('River spots')),
          body: Felt.narrow(lib == null
              ? Center(
                  child: snap.hasError
                      ? Text('Could not load river data: ${snap.error}')
                      : const CircularProgressIndicator())
              : _body(context, lib)),
        );
      },
    );
  }

  Widget _body(BuildContext context, RiverLibrary lib) {
    final t = Theme.of(context).textTheme;
    final b = lib.boards[boardIdx];
    final node = b.nodes[nodeId]!;
    final textures = <String, List<int>>{};
    for (var i = 0; i < lib.boards.length; i++) {
      (textures[lib.boards[i].texture] ??= []).add(i);
    }
    final rf = b.rangeFreqs(node);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Text(
            'BB vs BTN, single-raised pot. ${lib.boards.length} river boards '
            'solved with CFR+. Simplified ranges (full preflop ranges, '
            'board blockers removed); stacks ${lib.stack.toStringAsFixed(0)} '
            'pots deep.',
            style: t.bodySmall),
        const SizedBox(height: 8),
        DropdownButton<int>(
          isExpanded: true,
          value: boardIdx,
          items: [
            for (final e in textures.entries)
              for (final i in e.value)
                DropdownMenuItem(
                  value: i,
                  child: Text('${e.key}: ${_pretty(lib.boards[i].boardStr)}',
                      overflow: TextOverflow.ellipsis),
                ),
          ],
          onChanged: (v) => setState(() => boardIdx = v ?? 0),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (context, c) {
          final w = ((c.maxWidth - 32) / 5).clamp(36.0, 64.0);
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final card in b.cards)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: PlayingCard(card: card, width: w),
                ),
            ],
          );
        }),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final id in riverNodeInfo.keys)
            if (b.nodes.containsKey(id) && !id.startsWith('ipVsRaise'))
              ChoiceChip(
                label: Text(riverNodeInfo[id]!.$1),
                selected: id == nodeId,
                onSelected: (_) => setState(() => nodeId = id),
              ),
        ]),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${riverSeatName[node.player]}: ${riverNodeInfo[nodeId]!.$1}',
                    style: t.titleMedium),
                Text(riverNodeInfo[nodeId]!.$2, style: t.bodySmall),
                const SizedBox(height: 10),
                RiverGrid(
                  strategy: b.classStrategy(node),
                  actions: node.actions,
                  onTap: (h) => _showCombos(context, b, node, h),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 14, runSpacing: 6, children: [
                  for (var a = 0; a < node.actions.length; a++)
                    _legend(context, node.actions[a], rf[a]),
                ]),
                const SizedBox(height: 6),
                Text('Tap a hand to see each suit combo.',
                    style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Range summary', style: t.titleMedium),
                const SizedBox(height: 6),
                for (final line in b.summary())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('• $line', style: t.bodyMedium),
                  ),
                Text(
                  'Solver accuracy: exploitable for '
                  '${b.exploitabilityPctPot.toStringAsFixed(3)}% of the pot '
                  '(${lib.iterations} CFR+ iterations).',
                  style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RiverDrillScreen(library: lib))),
          icon: const Icon(Icons.fitness_center),
          label: const Text('River drill'),
        ),
      ],
    );
  }

  Widget _legend(BuildContext context, String a, double f) {
    final br = Theme.of(context).brightness;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
              color: riverActionColor(a, br),
              borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 5),
      Text('$a ${pct(f)}', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  void _showCombos(
      BuildContext context, RiverBoard b, RiverNode node, HandClass h) {
    final side = b.sides[node.player];
    final reach = b.reach(node);
    final idx = [
      for (var i = 0; i < side.n; i++)
        if (side.cls(i) == h) i
    ];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final t = Theme.of(context).textTheme;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(
                  '${h.name}: ${riverSeatName[node.player]}, '
                  '${riverNodeInfo[node.id]!.$1}',
                  style: t.titleMedium),
              const SizedBox(height: 6),
              if (idx.isEmpty)
                Text('${h.name} is not in ${riverSeatName[node.player]}\'s '
                    'range on this board.'),
              for (final i in idx)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${_pretty(side.comboName(i))}  ·  '
                          '${b.handName(node.player, i)}  ·  '
                          'beats ${pct(side.eq[i])}',
                          style: t.bodyMedium),
                      Text(
                          reach[i] < 1e-4
                              ? 'Never reaches this spot. '
                                  '${riverStrategyLine(node.actions, node.freqs(i))}'
                              : riverStrategyLine(node.actions, node.freqs(i)),
                          style: t.bodySmall),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

String _pretty(String cards) {
  final b = StringBuffer();
  for (var i = 0; i < cards.length; i += 2) {
    final s = 'cdhs'.indexOf(cards[i + 1]);
    b.write(cards[i]);
    b.write(const ['♣', '♦', '♥', '♠'][s]);
    if (i + 2 < cards.length) b.write(' ');
  }
  return b.toString();
}

String prettyCards(String cards) => _pretty(cards);

/// 13×13 grid of per-class river strategies; null cells = not in range.
class RiverGrid extends StatelessWidget {
  final List<List<double>?> strategy;
  final List<String> actions;
  final int? highlight;
  final ValueChanged<HandClass>? onTap;
  const RiverGrid(
      {super.key,
      required this.strategy,
      required this.actions,
      this.highlight,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    final br = Theme.of(context).brightness;
    final colors = [for (final a in actions) riverActionColor(a, br)];
    final empty = Theme.of(context).colorScheme.surfaceContainerHighest;
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(builder: (context, c) {
        final size = c.maxWidth / 13;
        return Column(children: [
          for (var r = 0; r < 13; r++)
            Expanded(
              child: Row(children: [
                for (var col = 0; col < 13; col++)
                  Expanded(
                      child: _cell(
                          context, HandClass(r, col), size, colors, empty)),
              ]),
            ),
        ]);
      }),
    );
  }

  Widget _cell(BuildContext context, HandClass h, double size,
      List<Color> colors, Color empty) {
    final f = strategy[h.index];
    final hl = highlight == h.index;
    return GestureDetector(
      onTap: onTap == null ? null : () => onTap!(h),
      child: Container(
        margin: const EdgeInsets.all(0.5),
        decoration: hl
            ? BoxDecoration(border: Border.all(color: Felt.gold, width: 2.5))
            : null,
        child: Stack(fit: StackFit.expand, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: f == null
                ? ColoredBox(color: empty)
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                        for (var a = 0; a < f.length; a++)
                          if (f[a] > 0.001)
                            Expanded(
                                flex: (f[a] * 1000).round(),
                                child: ColoredBox(color: colors[a])),
                      ]),
          ),
          Center(
            child: Text(
              h.name,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: (size * 0.3).clamp(6, 14),
                fontWeight: FontWeight.w600,
                color: f == null
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Colors.white,
                shadows: const [Shadow(blurRadius: 2, color: Colors.black26)],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
