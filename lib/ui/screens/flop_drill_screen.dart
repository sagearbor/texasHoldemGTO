import 'dart:math';

import 'package:flutter/material.dart';

import '../../gto/coach.dart' show Grade, pct;
import '../../gto/flop.dart';
import '../widgets/playing_card.dart';
import 'flop_screen.dart' show flopActionColor;
import 'review_sheet.dart' show GradeBadge;

/// Random flop + BTN combo: check, bet small or bet big? Graded by the
/// simplified solver's frequency.
class FlopDrillScreen extends StatefulWidget {
  final FlopLibrary library;
  const FlopDrillScreen({super.key, required this.library});

  @override
  State<FlopDrillScreen> createState() => _FlopDrillScreenState();
}

class _FlopDrillScreenState extends State<FlopDrillScreen> {
  final rng = Random();
  late FlopQuestion q = randomFlopQuestion(widget.library, rng);
  int? chosen;
  int played = 0, good = 0;

  void _answer(int a) {
    if (chosen != null) return;
    final g = gradeFlop(q, a);
    setState(() {
      chosen = a;
      played++;
      if (g == Grade.correct || g == Grade.mixed) good++;
    });
  }

  void _next() => setState(() {
        q = randomFlopQuestion(widget.library, rng);
        chosen = null;
      });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final br = Theme.of(context).brightness;
    final acts = q.node.actions;
    return Scaffold(
      appBar: AppBar(title: const Text('Flop c-bet drill')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text(
              played == 0
                  ? 'Pick the play the solver makes most.'
                  : 'Score $good / $played (GTO or mixed)',
              style: t.labelLarge),
          Text(flopModelLabel,
              style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
          const SizedBox(height: 10),
          Text('Flop (${q.board.texture})', style: t.labelMedium),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (final card in q.board.cards)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: PlayingCard(card: card, width: 52),
              ),
          ]),
          const SizedBox(height: 12),
          Text('You are BTN with', style: t.labelMedium),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (final c in q.holeCards)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: PlayingCard(card: c, width: 56),
              ),
          ]),
          const SizedBox(height: 10),
          Text(
              'You opened on the BTN, BB called. BB checks to you on the flop.',
              style: t.bodyMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var a = 0; a < acts.length; a++)
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: flopActionColor(acts[a], br),
                      foregroundColor: Colors.white),
                  onPressed: chosen == null ? () => _answer(a) : null,
                  child: Text(a == 0
                      ? 'Check'
                      : '${flopDrillLabels[a]} (${acts[a].substring(4)})'),
                ),
            ],
          ),
          if (chosen != null) ...[
            const SizedBox(height: 14),
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: GradeBadge(
                    grade: gradeFlop(q, chosen!), action: acts[chosen!]),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Solver: ${flopStrategyLine(acts, q.freqs)}',
                        style: t.titleSmall),
                    const SizedBox(height: 6),
                    for (final n in flopCoach(q, chosen!))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $n', style: t.bodyMedium),
                      ),
                    const SizedBox(height: 6),
                    Text(
                        'BTN\'s whole range here: '
                        '${[
                          for (var a = 0; a < acts.length; a++)
                            '${acts[a]} ${pct(q.board.btnFreq(acts[a]))}'
                        ].join(' · ')}',
                        style: t.bodySmall),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _next,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Next flop'),
            ),
          ],
        ],
      ),
    );
  }
}
