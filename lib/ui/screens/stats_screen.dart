import 'package:flutter/material.dart';

import '../../app_data.dart';
import '../../gto/coach.dart';
import '../../gto/hand_class.dart';
import '../../trainer/trainer_model.dart';
import '../widgets/range_grid.dart';
import 'daily_screen.dart';
import '../widgets/share_card.dart';
import 'help_screen.dart';
import 'progress_screen.dart';
import 'review_sheet.dart';

class StatsScreen extends StatelessWidget {
  final TrainerModel model;
  final void Function(String spotId) onDrill;
  const StatsScreen({super.key, required this.model, required this.onDrill});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([model, model.daily]),
      builder: (context, _) {
        final t = Theme.of(context).textTheme;
        final h = model.history;
        if (h.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('My stats'), actions: [
              _ProgressButton(model: model),
              const HelpButton(HelpTopic.stats),
            ]),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Play a few drills and your GTO report card shows up here: '
                  'accuracy by hand, your leakiest spots and your most '
                  'teachable mistakes.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        final byHand = model.byHand();
        // Hand-authored spots are drilled but never scored.
        final scored = model.scoredHistory;
        final week = DateTime.now()
            .subtract(const Duration(days: 7))
            .millisecondsSinceEpoch;
        final spots = model.bySpot().entries.toList()
          ..sort((a, b) =>
              model.accuracy(a.value).compareTo(model.accuracy(b.value)));
        final teach = model.teachable(limit: 8);

        return Scaffold(
          appBar: AppBar(title: const Text('My stats'), actions: [
            _ProgressButton(model: model),
            const HelpButton(HelpTopic.stats),
            Builder(
              builder: (bc) => IconButton(
                tooltip: 'Share my GTO report card',
                icon: const Icon(Icons.ios_share),
                onPressed: () {
                  final r = TrainerReport.from(model);
                  shareCardImage(bc,
                      card: TrainerShareCard(r),
                      fileName: 'felt-notes-report-card.png',
                      fallbackText: r.toText());
                },
              ),
            ),
            IconButton(
              tooltip: 'Reset history',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Reset trainer history?'),
                    content: const Text('This clears every recorded drill on this device.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('Reset')),
                    ],
                  ),
                );
                if (ok == true) model.clearHistory();
              },
            ),
          ]),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              Row(children: [
                _Tile('Hands drilled', '${h.length}'),
                _Tile('All-time', pct(model.accuracy(scored))),
                _Tile('Last 7 days',
                    pct(model.accuracy(scored.where((a) => a.ts >= week)))),
              ]),
              Row(children: [
                _Tile('Due for review', '${model.dueCount}'),
                _Tile('Leak cards', '${model.deck.cards.length}'),
                _Tile('Mastered', '${model.deck.cards.values.where((c) => c.box >= srMaxBox).length}'),
              ]),
              Card(
                child: ListTile(
                  key: const Key('stats-progress'),
                  leading: const Icon(Icons.show_chart),
                  title: const Text('GTO score over time'),
                  subtitle: const Text('Accuracy per week or day, and per game night'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openProgress(context, model),
                ),
              ),
              const SizedBox(height: 8),
              DailyCalendar(daily: model.daily),
              const SizedBox(height: 16),
              Text('You vs GTO, by hand', style: t.titleMedium),
              Text('Green = you play it like the solver, red = leak. Tap a hand.',
                  style: t.bodySmall),
              const SizedBox(height: 8),
              HeatGrid(
                value: (hc) {
                  final v = byHand[hc.index];
                  if (v == null) return null;
                  return 1 - v.$2 / v.$1;
                },
                onTap: (hc) => _handDetail(context, hc),
              ),
              const SizedBox(height: 20),
              if (teach.isNotEmpty) ...[
                Text('Most teachable hands', style: t.titleMedium),
                Text('Your biggest repeat mistakes, worst first.', style: t.bodySmall),
                const SizedBox(height: 6),
                for (final a in teach)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                          child: Text(HandClass.byIndex(a.hand).name,
                              style: const TextStyle(fontSize: 11))),
                      title: Text(model.library.byId(a.spotId).title),
                      subtitle: Text(
                          'You: ${model.library.byId(a.spotId).actions[a.chosen]} · '
                          'GTO: ${strategyLine(model.library.byId(a.spotId), HandClass.byIndex(a.hand))}'),
                      trailing: const Icon(Icons.school_outlined),
                      onTap: () => showCoachSheet(
                          context,
                          model.library.byId(a.spotId),
                          HandClass.byIndex(a.hand),
                          chosen: a.chosen,
                          onDrill: () => onDrill(a.spotId)),
                    ),
                  ),
                const SizedBox(height: 20),
              ],
              Text('Spots, weakest first', style: t.titleMedium),
              const SizedBox(height: 6),
              for (final e in spots)
                Card(
                  child: ListTile(
                    title: Text(model.library.byId(e.key).title),
                    subtitle: Text(e.value.length == 1 ? '1 hand' : '${e.value.length} hands'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(pct(model.accuracy(e.value)),
                          style: t.titleMedium?.copyWith(
                              color: HeatGrid.heat(model.accuracy(e.value)),
                              fontWeight: FontWeight.w700)),
                      IconButton(
                        tooltip: 'Drill',
                        icon: const Icon(Icons.fitness_center),
                        onPressed: () => onDrill(e.key),
                      ),
                    ]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _handDetail(BuildContext context, HandClass hc) {
    final answers = model.history.where((a) => a.hand == hc.index).toList().reversed.toList();
    if (answers.isEmpty) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('${hc.name}: ${answers.length} drills',
                style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final a in answers.take(30))
            ListTile(
              dense: true,
              leading: Icon(a.isMiss ? Icons.close : Icons.check,
                  color: HeatGrid.heat(a.isMiss ? 0 : 1)),
              title: Text(model.library.byId(a.spotId).title),
              subtitle: Text('You: ${model.library.byId(a.spotId).actions[a.chosen]} '
                  '(${pct(a.freq)} in GTO)'),
              onTap: () {
                Navigator.pop(ctx);
                showCoachSheet(context, model.library.byId(a.spotId), hc,
                    chosen: a.chosen, onDrill: () => onDrill(a.spotId));
              },
            ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final String label, value;
  const _Tile(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(children: [
            Text(value, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: t.bodySmall, textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}

/// Opens the "GTO score over time" chart.
void openProgress(BuildContext context, TrainerModel model) {
  final home = AppScope.maybeOf(context)?.home;
  Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProgressScreen(trainer: model, home: home)));
}

class _ProgressButton extends StatelessWidget {
  final TrainerModel model;
  const _ProgressButton({required this.model});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'GTO score over time',
        icon: const Icon(Icons.show_chart),
        onPressed: () => openProgress(context, model),
      );
}
