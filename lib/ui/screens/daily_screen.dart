import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../gto/coach.dart';
import '../../gto/spots.dart';
import '../../trainer/daily.dart';
import '../../trainer/trainer_model.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';
import '../widgets/range_grid.dart';
import '../widgets/table_diagram.dart';
import 'review_sheet.dart';

const _markEmoji = {'G': '🟩', 'Y': '🟨', 'R': '🟥'};

String _squares(String marks) =>
    marks.split('').map((c) => _markEmoji[c] ?? '').join();

Future<void> copyDailyResult(BuildContext context, DailyModel d) async {
  await Clipboard.setData(ClipboardData(text: d.share));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Result copied: paste it anywhere')));
  }
}

/// Prominent entry card at the top of the Train screen.
class DailyCard extends StatelessWidget {
  final TrainerModel model;
  const DailyCard({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final d = model.daily;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final t = Theme.of(context).textTheme;
        final streak = d.streak;
        final sub = d.done
            ? '${scoreLabel(d.score)}/$dailyLength  ${_squares(d.marks)}'
            : d.started
                ? '${d.answered}/$dailyLength answered: tap to continue'
                : 'Same 10 hands for everyone today. One shot.';
        return Card(
          color: Felt.gold.withOpacity(0.16),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Felt.gold, width: 1.2)),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DailyScreen(model: model))),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(children: [
                const Icon(Icons.today, color: Felt.gold, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Daily 10 · #${d.number}',
                          style: t.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(sub, style: t.bodySmall),
                      if (streak > 0)
                        Text('Day streak $streak${streak >= 3 ? ' 🔥' : ''}',
                            style: t.bodySmall?.copyWith(color: Felt.gold)),
                    ],
                  ),
                ),
                if (d.done)
                  IconButton(
                    tooltip: 'Copy result',
                    icon: const Icon(Icons.copy),
                    onPressed: () => copyDailyResult(context, d),
                  )
                else
                  const Icon(Icons.chevron_right),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class DailyScreen extends StatefulWidget {
  final TrainerModel model;
  const DailyScreen({super.key, required this.model});

  @override
  State<DailyScreen> createState() => _DailyScreenState();
}

class _DailyScreenState extends State<DailyScreen> {
  /// The drill just answered, shown with its coaching until "Next".
  (DailyDrill, int)? reveal;

  DailyModel get d => widget.model.daily;

  void _answer(DailyDrill drill, int i) {
    d.answer(i);
    widget.model.record(drill.spot, drill.hand, i);
    setState(() => reveal = (drill, i));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final r = reveal;
        final drill = r?.$1 ?? d.currentDrill;
        return Scaffold(
          appBar: AppBar(title: Text('Daily 10 · #${d.number}')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              _Progress(marks: d.marks),
              const SizedBox(height: 12),
              if (drill == null)
                _Summary(daily: d)
              else
                _DailyDrillCard(
                  drill: drill,
                  number: r != null ? d.answered : d.answered + 1,
                  chosen: r?.$2,
                  onAnswer: (i) => _answer(drill, i),
                  onNext: () => setState(() => reveal = null),
                  last: d.done,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Progress extends StatelessWidget {
  final String marks;
  const _Progress({required this.marks});

  @override
  Widget build(BuildContext context) {
    final empty = Theme.of(context).colorScheme.surfaceContainerHighest;
    Color c(String m) => switch (m) {
          'G' => Felt.good,
          'Y' => Felt.mixed,
          _ => Felt.bad,
        };
    return Row(children: [
      for (var i = 0; i < dailyLength; i++) ...[
        if (i > 0) const SizedBox(width: 4),
        Expanded(
          child: Container(
            height: 10,
            decoration: BoxDecoration(
              color: i < marks.length ? c(marks[i]) : empty,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ],
    ]);
  }
}

class _DailyDrillCard extends StatelessWidget {
  final DailyDrill drill;
  final int number;
  final int? chosen;
  final void Function(int) onAnswer;
  final VoidCallback onNext;
  final bool last;
  const _DailyDrillCard({
    required this.drill,
    required this.number,
    required this.chosen,
    required this.onAnswer,
    required this.onNext,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final spot = drill.spot;
    final b = Theme.of(context).brightness;
    final ch = chosen;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Hand $number of $dailyLength', style: t.labelMedium),
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
                otherVillains: spot.otherVillains,
                headsUp: spot.format == SpotFormat.pushFold),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              PlayingCard(card: drill.cards[0], width: 72),
              const SizedBox(width: 10),
              PlayingCard(card: drill.cards[1], width: 72),
            ]),
            const SizedBox(height: 18),
            if (ch == null)
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
                      onPressed: () => onAnswer(i),
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
                  chosen: ch,
                  showGrid: gradeFor(spot.freqs(drill.hand)[ch]) !=
                      Grade.correct),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: onNext,
                  icon: Icon(last ? Icons.flag : Icons.arrow_forward),
                  label: Text(last ? 'See result' : 'Next hand'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final DailyModel daily;
  const _Summary({required this.daily});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final d = daily;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Text('${scoreLabel(d.score)}/$dailyLength',
              style: t.displayMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: HeatGrid.heat(d.score / dailyLength))),
          const SizedBox(height: 6),
          Text(_squares(d.marks), style: const TextStyle(fontSize: 22)),
          const SizedBox(height: 10),
          Text('🟩 GTO play  🟨 mixed / fine  🟥 miss', style: t.bodySmall),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _Stat('Day streak', '${d.streak}'),
            _Stat('Best streak', '${d.bestStreak}'),
          ]),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () => copyDailyResult(context, d),
            icon: const Icon(Icons.copy),
            label: const Text('Copy result'),
          ),
          const SizedBox(height: 8),
          Text('New hands tomorrow. Misses go into "Drill my leaks".',
              style: t.bodySmall, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value;
  const _Stat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(children: [
      Text(value, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      Text(label, style: t.bodySmall),
    ]);
  }
}

/// Month heatmap of Daily 10 scores (Mon-first weeks).
class DailyCalendar extends StatelessWidget {
  final DailyModel daily;
  const DailyCalendar({super.key, required this.daily});

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', //
    'August', 'September', 'October', 'November', 'December'
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final now = daily.date;
    final first = DateTime(now.year, now.month, 1);
    final days = DateTime(now.year, now.month + 1, 0).day;
    final lead = first.weekday - 1; // Monday = 0
    final cells = <Widget>[
      for (final l in ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
        Center(child: Text(l, style: t.labelSmall)),
      for (var i = 0; i < lead; i++) const SizedBox.shrink(),
      for (var day = 1; day <= days; day++)
        () {
          final k = dayKey(DateTime(now.year, now.month, day));
          final m = daily.results[k];
          final complete = (m?.length ?? 0) >= dailyLength;
          final color = m == null || m.isEmpty
              ? scheme.surfaceContainerHighest
              : complete
                  ? HeatGrid.heat(dailyScore(m) / dailyLength)
                  : scheme.outlineVariant;
          return Container(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(5),
              border: k == daily.today
                  ? Border.all(color: Felt.gold, width: 2)
                  : null,
            ),
            alignment: Alignment.center,
            child: Text('$day',
                style: t.labelSmall?.copyWith(
                    color: complete ? Colors.white : null,
                    fontWeight: complete ? FontWeight.w700 : null)),
          );
        }(),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text('Daily 10 · ${_months[now.month - 1]}',
                      style: t.titleMedium)),
              Text('Streak ${daily.streak} · best ${daily.bestStreak}',
                  style: t.bodySmall),
            ]),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 1.3,
              children: cells,
            ),
            if (daily.done) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => copyDailyResult(context, daily),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy today\'s result'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
