import 'dart:math';

import 'package:flutter/material.dart';

import '../../gto/coach.dart' show Grade, pct;
import '../../gto/river.dart';
import '../widgets/playing_card.dart';
import 'review_sheet.dart' show GradeBadge;
import 'river_screen.dart';

/// Random board + hero combo + decision node; graded by solver frequency.
class RiverDrillScreen extends StatefulWidget {
  final RiverLibrary library;
  const RiverDrillScreen({super.key, required this.library});

  @override
  State<RiverDrillScreen> createState() => _RiverDrillScreenState();
}

class _RiverDrillScreenState extends State<RiverDrillScreen> {
  final rng = Random();
  late RiverQuestion q = randomRiverQuestion(widget.library, rng);
  int? chosen;
  int played = 0, good = 0;

  void _answer(int a) {
    if (chosen != null) return;
    final g = gradeRiver(q, a);
    setState(() {
      chosen = a;
      played++;
      if (g == Grade.correct || g == Grade.mixed) good++;
    });
  }

  void _next() => setState(() {
        q = randomRiverQuestion(widget.library, rng);
        chosen = null;
      });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final info = riverNodeInfo[q.node.id]!;
    final br = Theme.of(context).brightness;
    return Scaffold(
      appBar: AppBar(title: const Text('River drill')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text(
              played == 0
                  ? 'Pick the play the solver makes most.'
                  : 'Score $good / $played (GTO or mixed)',
              style: t.labelLarge),
          const SizedBox(height: 10),
          Text('Board (${q.board.texture})', style: t.labelMedium),
          const SizedBox(height: 4),
          LayoutBuilder(builder: (context, c) {
            final w = ((c.maxWidth - 32) / 5).clamp(36.0, 60.0);
            return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (final card in q.board.cards)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: PlayingCard(card: card, width: w),
                ),
            ]);
          }),
          const SizedBox(height: 12),
          Text('You are ${q.hero} with', style: t.labelMedium),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (final c in q.holeCards)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: PlayingCard(card: c, width: 56),
              ),
          ]),
          const SizedBox(height: 10),
          Text('Single-raised pot, BTN opened and BB called. ${info.$2}',
              style: t.bodyMedium, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var a = 0; a < q.node.actions.length; a++)
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: riverActionColor(q.node.actions[a], br),
                      foregroundColor:
                          q.node.actions[a] == 'Fold' && br == Brightness.light
                              ? Colors.black87
                              : Colors.white),
                  onPressed: chosen == null ? () => _answer(a) : null,
                  child: Text(q.node.actions[a]),
                ),
            ],
          ),
          if (chosen != null) ...[
            const SizedBox(height: 14),
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: GradeBadge(
                    grade: gradeRiver(q, chosen!),
                    action: q.node.actions[chosen!]),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Solver: ${riverStrategyLine(q.node.actions, q.freqs)}',
                        style: t.titleSmall),
                    const SizedBox(height: 6),
                    for (final n
                        in riverCoach(q, chosen!, widget.library.stack))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $n', style: t.bodyMedium),
                      ),
                    const SizedBox(height: 6),
                    Text('${q.hero}\'s whole range here: ${_rangeLine()}',
                        style: t.bodySmall),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _next,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Next spot'),
            ),
          ],
        ],
      ),
    );
  }

  String _rangeLine() {
    final rf = q.board.rangeFreqs(q.node);
    return [
      for (var a = 0; a < rf.length; a++) '${q.node.actions[a]} ${pct(rf[a])}'
    ].join(' · ');
  }
}
