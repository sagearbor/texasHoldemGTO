import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../gto/hand_class.dart';
import '../../gto/spots.dart';
import '../app_settings.dart';
import '../theme.dart';
import '../widgets/range_grid.dart';
import '../widgets/solver_dice.dart';

/// Coaching panel for one hand in one spot. [chosen] is the action the
/// player took (null when browsing charts).
class CoachPanel extends StatelessWidget {
  final Spot spot;
  final HandClass hand;
  final int? chosen;
  final bool showGrid;

  /// Solver-dice roll (0..99); when set and the hand is mixed, the dice
  /// explainer is shown under the strategy line.
  final int? roll;

  /// Beginner mode: >= 50% counts as right and coaching is shortened.
  final bool simple;
  const CoachPanel(
      {super.key,
      required this.spot,
      required this.hand,
      this.chosen,
      this.showGrid = true,
      this.roll,
      this.simple = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = spot.freqs(hand);
    final grade = chosen == null
        ? null
        : simple
            ? beginnerGradeFor(f[chosen!])
            : gradeFor(f[chosen!]);
    final notes = simple && chosen != null
        ? simpleCoachNotes(spot, hand, chosen!)
        : coachNotes(spot, hand, chosen ?? _best(f));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (grade != null) GradeBadge(grade: grade, action: spot.actions[chosen!]),
        const SizedBox(height: 10),
        Text('${hand.name}: ${spot.title}', style: t.titleMedium),
        const SizedBox(height: 6),
        ActionFreqBar(spot: spot, hand: hand),
        const SizedBox(height: 4),
        Text(strategyLine(spot, hand), style: t.bodyMedium),
        if (roll != null && SolverDice.applies(spot, hand))
          // Settings > Trainer can hide the dice.
          ValueListenableBuilder<bool>(
            valueListenable: AppSettings.solverDice,
            builder: (_, show, __) => !show
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SolverDice(spot: spot, hand: hand, roll: roll!),
                  ),
          ),
        const SizedBox(height: 10),
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Icon(Icons.circle, size: 6, color: Felt.accent(context)),
              ),
              Expanded(child: Text(n, style: t.bodyMedium)),
            ]),
          ),
        if (!spot.solved)
          Text('100bb charts are approximate GTO baselines.',
              style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
        if (showGrid) ...[
          const SizedBox(height: 12),
          RangeGrid(spot: spot, highlight: hand.index),
          const SizedBox(height: 6),
          ActionLegend(spot: spot),
        ],
      ],
    );
  }

  int _best(List<double> f) {
    var b = 0;
    for (var i = 1; i < f.length; i++) {
      if (f[i] > f[b]) b = i;
    }
    return b;
  }
}

class GradeBadge extends StatelessWidget {
  final Grade grade;
  final String action;
  const GradeBadge({super.key, required this.grade, required this.action});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (grade) {
      Grade.correct => (Felt.good, Icons.check_circle),
      Grade.mixed => (Felt.mixed, Icons.balance),
      Grade.rare => (Felt.bad, Icons.error_outline),
      Grade.mistake => (Felt.bad, Icons.cancel),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text('${gradeLabels[grade]}  ·  you chose $action',
              style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}


void showCoachSheet(BuildContext context, Spot spot, HandClass hand,
    {int? chosen, VoidCallback? onDrill}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          CoachPanel(spot: spot, hand: hand, chosen: chosen),
          if (onDrill != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                onDrill();
              },
              icon: const Icon(Icons.fitness_center),
              label: Text('Drill ${spot.title}'),
            ),
          ],
        ],
      ),
    ),
  );
}
