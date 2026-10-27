import 'package:flutter/material.dart';

import '../../gto/coach.dart' show pct;
import '../../gto/flop.dart';
import '../../gto/hand_class.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';
import 'flop_drill_screen.dart';
import 'river_screen.dart' show prettyCards, riverActionColor;

/// Colour for a flop action (reuses the river palette; raise = all-in red).
Color flopActionColor(String a, Brightness b) =>
    riverActionColor(a == 'Raise' ? 'All-in' : a, b);

/// Browser for the simplified flop c-bet library.
class FlopScreen extends StatefulWidget {
  /// Preloaded data (tests); otherwise loaded from the asset bundle.
  final FlopLibrary? library;
  const FlopScreen({super.key, this.library});

  @override
  State<FlopScreen> createState() => _FlopScreenState();
}

class _FlopScreenState extends State<FlopScreen> {
  int boardIdx = 0;
  String nodeId = 'root';

  /// Grid view: null = all actions mixed, otherwise one action's frequency.
  int? only;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FlopLibrary>(
      future: widget.library != null
          ? Future.value(widget.library)
          : FlopLibrary.load(),
      builder: (context, snap) {
        final lib = snap.data;
        return Scaffold(
          appBar: AppBar(title: const Text('Flop c-bets (simplified)')),
          body: lib == null
              ? Center(
                  child: snap.hasError
                      ? Text('Could not load flop data: ${snap.error}')
                      : const CircularProgressIndicator())
              : _body(context, lib),
        );
      },
    );
  }

  Widget _body(BuildContext context, FlopLibrary lib) {
    final t = Theme.of(context).textTheme;
    final b = lib.boards[boardIdx];
    final node = b.nodes[nodeId]!;
    final rf = b.rangeFreqs(node);
    final sel = only != null && only! < node.actions.length ? only : null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Text(
            '$flopModelLabel. BTN opened, BB called and checks the flop. '
            '${lib.boards.length} flops solved with CFR+ together with a '
            'small turn game (one 75% bet size); the river is not played, '
            'turn showdowns use river-card equity. Fewer sizes and streets '
            'than a full solver: treat frequencies as a rough guide.',
            style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
        const SizedBox(height: 8),
        DropdownButton<int>(
          isExpanded: true,
          value: boardIdx,
          items: [
            for (var i = 0; i < lib.boards.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(
                    '${lib.boards[i].texture}: '
                    '${prettyCards(lib.boards[i].boardStr)}',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => boardIdx = v ?? 0),
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (final card in b.cards)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: PlayingCard(card: card, width: 52),
            ),
        ]),
        const SizedBox(height: 8),
        Text(b.headline(), style: t.titleSmall, textAlign: TextAlign.center),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final id in flopNodeInfo.keys)
            if (b.nodes.containsKey(id))
              ChoiceChip(
                label: Text(flopNodeInfo[id]!.$1),
                selected: id == nodeId,
                onSelected: (_) => setState(() {
                  nodeId = id;
                  only = null;
                }),
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
                    '${flopSeatName[node.player]}: ${flopNodeInfo[nodeId]!.$1}',
                    style: t.titleMedium),
                Text(flopNodeInfo[nodeId]!.$2, style: t.bodySmall),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: sel == null,
                    onSelected: (_) => setState(() => only = null),
                  ),
                  for (var a = 0; a < node.actions.length; a++)
                    ChoiceChip(
                      label: Text(node.actions[a]),
                      selected: sel == a,
                      onSelected: (_) => setState(() => only = a),
                    ),
                ]),
                const SizedBox(height: 10),
                FlopGrid(
                  strategy: b.classStrategy(node),
                  actions: node.actions,
                  only: sel,
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
                  '(${b.iterations} CFR+ iterations) within this simplified '
                  'model.',
                  style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextureComparison(library: lib),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => FlopDrillScreen(library: lib))),
          icon: const Icon(Icons.fitness_center),
          label: const Text('Flop c-bet drill'),
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
              color: flopActionColor(a, br),
              borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 5),
      Text('$a ${pct(f)}', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  void _showCombos(
      BuildContext context, FlopBoard b, FlopNode node, HandClass h) {
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
                  '${h.name}: ${flopSeatName[node.player]}, '
                  '${flopNodeInfo[node.id]!.$1}',
                  style: t.titleMedium),
              const SizedBox(height: 6),
              if (idx.isEmpty)
                Text('${h.name} is not in ${flopSeatName[node.player]}\'s '
                    'range on this flop.'),
              for (final i in idx)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${prettyCards(side.comboName(i))}  ·  '
                          '${b.handName(node.player, i)}'
                          '${_draw(side, i, b)}  ·  '
                          'equity ${pct(side.eq[i])}',
                          style: t.bodyMedium),
                      Text(
                          reach[i] < 1e-4
                              ? 'Never reaches this spot. '
                                  '${flopStrategyLine(node.actions, node.freqs(i))}'
                              : flopStrategyLine(node.actions, node.freqs(i)),
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

  String _draw(FlopSide s, int i, FlopBoard b) {
    final d = drawName([s.c1[i], s.c2[i]], b.cards);
    return d == null ? '' : ' + ${d.replaceFirst(RegExp(r'^an? '), '')}';
  }
}

/// 13×13 grid of per-class strategies; [only] shows one action's frequency
/// as a filled bar, otherwise every action stacked. Null cells = not in range.
class FlopGrid extends StatelessWidget {
  final List<List<double>?> strategy;
  final List<String> actions;
  final int? only;
  final int? highlight;
  final ValueChanged<HandClass>? onTap;
  const FlopGrid(
      {super.key,
      required this.strategy,
      required this.actions,
      this.only,
      this.highlight,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    final br = Theme.of(context).brightness;
    final colors = [for (final a in actions) flopActionColor(a, br)];
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
    Widget fill;
    if (f == null) {
      fill = ColoredBox(color: empty);
    } else if (only != null) {
      final x = f[only!];
      fill = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (x > 0.001)
          Expanded(
              flex: (x * 1000).round(),
              child: ColoredBox(color: colors[only!])),
        if (x < 0.999)
          Expanded(
              flex: ((1 - x) * 1000).round(),
              child: ColoredBox(color: empty.withOpacity(0.6))),
      ]);
    } else {
      fill = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var a = 0; a < f.length; a++)
          if (f[a] > 0.001)
            Expanded(
                flex: (f[a] * 1000).round(),
                child: ColoredBox(color: colors[a])),
      ]);
    }
    return GestureDetector(
      onTap: onTap == null ? null : () => onTap!(h),
      child: Container(
        margin: const EdgeInsets.all(0.5),
        decoration: hl
            ? BoxDecoration(border: Border.all(color: Felt.gold, width: 2.5))
            : null,
        child: Stack(fit: StackFit.expand, children: [
          ClipRRect(borderRadius: BorderRadius.circular(2), child: fill),
          Center(
            child: Text(
              h.name,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: (size * 0.3).clamp(6, 14),
                fontWeight: FontWeight.w600,
                color: f == null || only != null
                    ? Theme.of(context).colorScheme.onSurface
                    : Colors.white,
                shadows: only != null
                    ? null
                    : const [Shadow(blurRadius: 2, color: Colors.black26)],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Horizontal bars: BTN's average c-bet frequency per flop texture.
class TextureComparison extends StatelessWidget {
  final FlopLibrary library;
  const TextureComparison({super.key, required this.library});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final br = Theme.of(context).brightness;
    final small = flopActionColor('Bet 33%', br);
    final big = flopActionColor('Bet 75%', br);
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    final avg = library.textureAverages();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('C-bet % by texture', style: t.titleMedium),
            Text('Average over the solved flops of each texture.',
                style: t.bodySmall),
            const SizedBox(height: 8),
            for (final e in avg.entries) ...[
              Row(children: [
                Expanded(child: Text(e.key, style: t.bodyMedium)),
                Text(pct(e.value.$1 + e.value.$2), style: t.labelLarge),
              ]),
              const SizedBox(height: 3),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 12,
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (e.value.$1 > 0.001)
                          Expanded(
                              flex: (e.value.$1 * 1000).round(),
                              child: ColoredBox(color: small)),
                        if (e.value.$2 > 0.001)
                          Expanded(
                              flex: (e.value.$2 * 1000).round(),
                              child: ColoredBox(color: big)),
                        if (e.value.$3 > 0.001)
                          Expanded(
                              flex: (e.value.$3 * 1000).round(),
                              child: ColoredBox(color: track)),
                      ]),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(spacing: 14, children: [
              _key(context, small, 'Bet 33%'),
              _key(context, big, 'Bet 75%'),
              _key(context, track, 'Check'),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _key(BuildContext context, Color c, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}
