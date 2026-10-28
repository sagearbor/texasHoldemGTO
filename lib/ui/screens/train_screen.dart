import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../gto/spots.dart';
import '../../trainer/trainer_model.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';
import '../widgets/table_diagram.dart';
import 'daily_screen.dart';
import 'glossary_screen.dart';
import 'help_screen.dart';
import 'quiz_screen.dart';
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
            // A focus-spot chip is long: on a phone it gets the title's room
            // (the bottom bar already says Train).
            title: model.focusSpotId != null &&
                    MediaQuery.sizeOf(context).width < 400
                ? null
                : const Text('Train'),
            actions: [
              _ModeMenu(model: model),
              IconButton(
                tooltip: 'Quizzes',
                icon: const Icon(Icons.quiz_outlined),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const QuizScreen())),
              ),
              const GlossaryButton(),
              const HelpButton(HelpTopic.train),
            ],
          ),
          body: d == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [
                    DailyCard(model: model),
                    const SizedBox(height: 8),
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
    DrillMode.cashOnly: 'Cash',
    DrillMode.pushFoldOnly: 'Push/fold',
    DrillMode.leaks: 'Drill my leaks',
  };

  @override
  Widget build(BuildContext context) {
    final due = model.dueCount;
    String name(DrillMode m) => m == DrillMode.leaks && due > 0
        ? '${labels[m]} · $due due'
        : labels[m]!;
    final label = model.focusSpotId == null
        ? name(model.mode)
        : model.weakTargets.isNotEmpty
            ? 'Weak hands · ${model.library.byId(model.focusSpotId!).title}'
            : model.library.byId(model.focusSpotId!).title;
    return PopupMenuButton<Object>(
      tooltip: 'Drill mode',
      onSelected: (v) {
        if (v is DrillMode) model.setMode(v);
        if (v is Difficulty) model.setDifficulty(v);
      },
      // Plain items with a leading tick (not CheckedPopupMenuItem, whose
      // indent didn't line up with the mode rows); the current drill
      // mode gets a tick too, like the difficulty.
      itemBuilder: (_) {
        PopupMenuItem<Object> item(Object value, String text, bool on) =>
            PopupMenuItem<Object>(
              value: value,
              child: Row(children: [
                SizedBox(
                    width: 28,
                    child: on ? const Icon(Icons.check, size: 18) : null),
                Text(text),
              ]),
            );
        return [
          for (final e in labels.entries)
            item(e.key, name(e.key),
                model.focusSpotId == null && model.mode == e.key),
          const PopupMenuDivider(),
          const PopupMenuItem<Object>(
              enabled: false, height: 32, child: Text('Difficulty')),
          for (final e in difficultyLabels.entries)
            item(e.key, e.value, model.difficulty == e.key),
        ];
      },
      child: Chip(
        avatar: Icon(
            model.mode == DrillMode.leaks ? Icons.healing : Icons.tune,
            size: 18),
        // Long focus-spot titles ellipsize instead of overflowing the
        // app bar on a 360px phone.
        label: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.32),
          child: Text(
              model.difficulty == Difficulty.intermediate
                  ? label
                  : '$label · ${difficultyLabels[model.difficulty]}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
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
                label: Text(switch (spot.format) {
                  SpotFormat.cash100 => '6-max · 100bb',
                  SpotFormat.pushFold => 'HU · Nash',
                  SpotFormat.pushFold3 => '3-handed · Nash',
                  SpotFormat.rejam => 'Short stack · solved',
                }),
                visualDensity: VisualDensity.compact,
              ),
            ]),
            const SizedBox(height: 4),
            Text(spot.situation, style: t.bodyMedium),
            const SizedBox(height: 12),
            TableDiagram(
                hero: spot.hero,
                villain: spot.villain,
                otherVillains: spot.otherVillains,
                headsUp: spot.format == SpotFormat.pushFold,
                threeHanded: spot.format == SpotFormat.pushFold3),
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
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () => model.answer(i),
                      // One line always: "Overlimp" / "Iso 5bb" used to
                      // wrap mid-word in three-button rows at phone width.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(spot.actions[i],
                            maxLines: 1,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ])
            else ...[
              CoachPanel(
                  spot: spot,
                  hand: drill.hand,
                  chosen: ans.chosen,
                  roll: model.lastRoll,
                  simple: model.difficulty == Difficulty.beginner,
                  showGrid: model.gradeOf(ans) != Grade.correct),
              const SizedBox(height: 14),
              Row(children: [
                if (model.gradeOf(ans) == Grade.correct)
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
