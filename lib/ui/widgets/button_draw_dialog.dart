import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../homegame/button_draw.dart';
import '../../poker/cards.dart';
import '../theme.dart';
import 'playing_card.dart';

/// Deals one card to each seat, one at a time; high card takes the button.
/// Returns the winning seat, or null if dismissed.
Future<int?> showButtonDraw(BuildContext context, List<String> players,
    {Random? rng, Duration step = const Duration(milliseconds: 350)}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _ButtonDrawDialog(players: players, rng: rng ?? Random(), step: step),
  );
}

class _ButtonDrawDialog extends StatefulWidget {
  final List<String> players;
  final Random rng;
  final Duration step;
  const _ButtonDrawDialog({required this.players, required this.rng, required this.step});

  @override
  State<_ButtonDrawDialog> createState() => _ButtonDrawDialogState();
}

class _ButtonDrawDialogState extends State<_ButtonDrawDialog> {
  late ButtonDraw draw;
  int revealed = 0;
  Timer? _timer;

  bool get done => revealed >= widget.players.length;

  @override
  void initState() {
    super.initState();
    _deal();
  }

  void _deal() {
    _timer?.cancel();
    draw = drawForButton(widget.players.length, widget.rng);
    revealed = 0;
    _timer = Timer.periodic(widget.step, (t) {
      if (!mounted) return t.cancel();
      setState(() => revealed++);
      if (done) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = widget.players;
    final w = draw.winner;
    return AlertDialog(
      title: const Text('Draw for the button'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('High card deals first. Ties on rank go by suit: ♠ > ♥ > ♦ > ♣.',
                style: t.bodySmall),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 10, alignment: WrapAlignment.center, children: [
              for (var i = 0; i < p.length; i++)
                SizedBox(
                  width: 64,
                  child: Column(children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                      child: i < revealed
                          ? Container(
                              key: ValueKey('up$i${draw.cards[i]}'),
                              decoration: done && i == w
                                  ? BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      boxShadow: const [
                                        BoxShadow(color: Felt.gold, blurRadius: 10, spreadRadius: 2)
                                      ])
                                  : null,
                              child: PlayingCard(card: draw.cards[i], width: 44),
                            )
                          : _CardBack(key: ValueKey('down$i'), width: 44),
                    ),
                    const SizedBox(height: 4),
                    Text(p[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.labelSmall?.copyWith(
                            fontWeight: done && i == w ? FontWeight.w800 : null)),
                  ]),
                ),
            ]),
            const SizedBox(height: 12),
            Text(
                done
                    ? '${p[w]} deals first (${prettyCard(draw.cards[w])})'
                    : 'Dealing…',
                style: t.titleSmall),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: done ? () => setState(_deal) : null, child: const Text('Draw again')),
        FilledButton(
          onPressed: done ? () => Navigator.pop(context, w) : null,
          child: const Text('Use this'),
        ),
      ],
    );
  }
}

class _CardBack extends StatelessWidget {
  final double width;
  const _CardBack({super.key, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: width * 1.4,
      decoration: BoxDecoration(
        color: Felt.feltCard,
        borderRadius: BorderRadius.circular(width * 0.12),
        border: Border.all(color: Felt.gold, width: 1.5),
      ),
    );
  }
}
