import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../gto/spots.dart';
import '../../trainer/trainer_model.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';
import '../widgets/table_diagram.dart';
import 'review_sheet.dart';

class TrainScreen extends StatelessWidget {
  final TrainerModel model;
  const TrainScreen({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final d = model.current;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Train'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _ModeMenu(model: model),
              ),
            ],
          ),
          body: d == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [
                    _SessionBar(model: model),
                    const SizedBox(height: 12),
                    _DrillCard(model: model, drill: d),
                  ],
                ),
        );
      },
    );
  }
}

class _ModeMenu extends StatelessWidget {
  final TrainerModel model;
  const _ModeMenu({required this.model});

  static const labels = {
    DrillMode.mixed: 'All spots',
    DrillMode.cashOnly: '6-max 100bb',
    DrillMode.pushFoldOnly: 'Push/fold',
    DrillMode.leaks: 'Drill my leaks',
  };

  @override
  Widget build(BuildContext context) {
    final label = model.focusSpotId != null
        ? model.library.byId(model.focusSpotId!).title
        : labels[model.mode]!;
    return PopupMenuButton<Object>(
      tooltip: 'Drill mode',
      onSelected: (v) {
        if (v is DrillMode) model.setMode(v);
      },
      itemBuilder: (_) => [
        for (final e in labels.entries)
          PopupMenuItem(value: e.key, child: Text(e.value)),
      ],
      child: Chip(
        avatar: Icon(
            model.mode == DrillMode.leaks ? Icons.healing : Icons.tune,
            size: 18),
        label: Text(label),
        onDeleted: model.focusSpotId != null ? () => model.focus(null) : null,
      ),
    );
  }
}

class _SessionBar extends StatelessWidget {
  final TrainerModel model;
  const _SessionBar({required this.model});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final acc = model.sessionCount == 0
        ? '–'
        : '${(100 * model.sessionGood / model.sessionCount).round()}%';
    Widget stat(String label, String value) => Expanded(
          child: Column(children: [
            Text(value, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: t.bodySmall),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          stat('Session', '${model.sessionCount}'),
          stat('Accuracy', acc),
          stat('Streak', '${model.streak}${model.streak >= 5 ? ' 🔥' : ''}'),
        ]),
      ),
    );
  }
}

class _DrillCard extends StatelessWidget {
  final TrainerModel model;
  final Drill drill;
  const _DrillCard({required this.model, required this.drill});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final spot = drill.spot;
    final ans = model.lastAnswer;
    final b = Theme.of(context).brightness;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: Text(spot.title, style: t.titleLarge)),
              Chip(
                label: Text(spot.format == SpotFormat.cash100
                    ? '6-max · 100bb'
                    : 'HU · Nash'),
                visualDensity: VisualDensity.compact,
              ),
            ]),
            const SizedBox(height: 4),
            Text(spot.situation, style: t.bodyMedium),
            const SizedBox(height: 12),
            TableDiagram(
                hero: spot.hero,
                villain: spot.villain,
                headsUp: spot.format == SpotFormat.pushFold),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              PlayingCard(card: drill.cards[0], width: 72),
              const SizedBox(width: 10),
              PlayingCard(card: drill.cards[1], width: 72),
            ]),
            const SizedBox(height: 18),
            if (ans == null)
              Row(children: [
                for (var i = 0; i < spot.actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Felt.actionColor(spot.actions[i], b),
                        foregroundColor: spot.actions[i] == 'Fold' &&
                                b == Brightness.light
                            ? Colors.black87
                            : Colors.white,
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: () => model.answer(i),
                      child: Text(spot.actions[i],
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ])
            else ...[
              CoachPanel(
                  spot: spot,
                  hand: drill.hand,
                  chosen: ans.chosen,
                  showGrid: ans.grade != Grade.correct),
              const SizedBox(height: 14),
              Row(children: [
                if (ans.grade == Grade.correct)
                  TextButton(
                    onPressed: () => showCoachSheet(context, spot, drill.hand),
                    child: const Text('See chart'),
                  ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: model.next,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Next hand'),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
