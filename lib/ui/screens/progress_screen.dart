import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../homegame/home_game.dart';
import '../../trainer/progress.dart';
import '../../trainer/trainer_model.dart';
import '../theme.dart';

/// "GTO score over time": trainer accuracy per week (or day) and the GTO
/// grade of each home-game night. Everything is computed from local data.
class ProgressScreen extends StatefulWidget {
  final TrainerModel trainer;
  final HomeGameModel? home;
  const ProgressScreen({super.key, required this.trainer, this.home});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  bool byDay = false;

  static const weeks = 12, days = 30;

  static String _date(DateTime d) => '${d.month}/${d.day}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('GTO score over time')),
      body: Felt.narrow(ListenableBuilder(
        listenable: Listenable.merge(
            [widget.trainer, if (widget.home != null) widget.home!]),
        builder: (context, _) {
          final m = widget.trainer;
          final buckets = bucketAnswers(m.scoredHistory, m.now,
              byDay: byDay, count: byDay ? days : weeks);
          final answered = buckets.fold<int>(0, (a, b) => a + b.count);
          final current = buckets.last;
          final nights = widget.home == null
              ? const <NightGrade>[]
              : nightGrades(widget.home!.sessions, m.library);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              SegmentedButton<bool>(
                key: const Key('progress-period'),
                segments: const [
                  ButtonSegment(value: false, label: Text('Per week')),
                  ButtonSegment(value: true, label: Text('Per day')),
                ],
                selected: {byDay},
                onSelectionChanged: (v) => setState(() => byDay = v.first),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Trainer accuracy', style: t.titleMedium),
                      Text(
                          byDay
                              ? 'Share of drill answers that were GTO, last $days days'
                              : 'Share of drill answers that were GTO, last $weeks weeks',
                          style: t.bodySmall),
                      const SizedBox(height: 10),
                      if (answered == 0)
                        _Empty(byDay
                            ? 'No drills in the last $days days. Train a few '
                                'hands and your daily score appears here.'
                            : 'No drills in the last $weeks weeks. Train a few '
                                'hands and your weekly score appears here.')
                      else ...[
                        Text(
                            '${byDay ? 'Today' : 'This week'}: '
                            '${current.accuracy == null ? '–' : pct(current.accuracy!)}'
                            ' · $answered answers in all',
                            style: t.labelLarge),
                        const SizedBox(height: 8),
                        ScoreChart(
                          values: [for (final b in buckets) b.accuracy],
                          firstLabel: _date(buckets.first.start),
                          lastLabel: byDay ? 'today' : 'this week',
                          semantics: 'Trainer accuracy '
                              '${byDay ? 'per day' : 'per week'}: ${[
                            for (final b in buckets)
                              if (b.accuracy != null)
                                '${_date(b.start)} ${pct(b.accuracy!)}'
                          ].join(', ')}',
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Home-game GTO grade', style: t.titleMedium),
                      Text(
                          'Per night: raise-or-fold decisions when it was '
                          'folded to you that match the chart',
                          style: t.bodySmall),
                      const SizedBox(height: 10),
                      if (nights.isEmpty)
                        const _Empty(
                            'No graded home-game nights yet. Log your cards and '
                            'actions at a game night and each night gets a grade.')
                      else ...[
                        ScoreChart(
                          values: [for (final n in nights) n.score],
                          firstLabel: _date(nights.first.date),
                          lastLabel: _date(nights.last.date),
                          semantics: 'GTO grade per night: ${[
                            for (final n in nights)
                              '${_date(n.date)} ${pct(n.score)}'
                          ].join(', ')}',
                        ),
                        const SizedBox(height: 8),
                        for (final n in nights.reversed.take(8))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(children: [
                              SizedBox(
                                  width: 48,
                                  child: Text(_date(n.date), style: t.bodySmall)),
                              Expanded(
                                child: Text(n.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: t.bodyMedium),
                              ),
                              Text('${pct(n.score)} of ${n.graded}',
                                  style: t.labelLarge),
                            ]),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      )),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium),
      );
}

/// 0-100% line chart with gridlines at 0 / 50 / 100% and the first / last
/// x labels. Null values leave a gap.
class ScoreChart extends StatelessWidget {
  final List<double?> values;
  final String firstLabel, lastLabel;
  final String semantics;
  const ScoreChart(
      {super.key,
      required this.values,
      required this.firstLabel,
      required this.lastLabel,
      required this.semantics});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: semantics,
      excludeSemantics: true,
      child: Column(children: [
        SizedBox(
          height: 150,
          child: CustomPaint(
            size: Size.infinite,
            painter: ScoreChartPainter(values,
                line: cs.primary,
                grid: cs.onSurface.withOpacity(0.15),
                label: t.bodySmall!.copyWith(color: cs.onSurfaceVariant)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: ScoreChartPainter.axisWidth),
          child: Row(children: [
            Text(firstLabel, style: t.bodySmall),
            const Spacer(),
            Text(lastLabel, style: t.bodySmall),
          ]),
        ),
      ]),
    );
  }
}

class ScoreChartPainter extends CustomPainter {
  final List<double?> values;
  final Color line, grid;
  final TextStyle label;
  ScoreChartPainter(this.values,
      {required this.line, required this.grid, required this.label});

  /// Room on the left for the "100%" labels.
  static const axisWidth = 36.0;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 6.0, bottom = 6.0, right = 6.0;
    final h = size.height - top - bottom;
    final w = size.width - axisWidth - right;
    if (w <= 0 || h <= 0) return;
    double y(double v) => top + h * (1 - v.clamp(0, 1));
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final g in const [0.0, 0.5, 1.0]) {
      canvas.drawLine(Offset(axisWidth, y(g)),
          Offset(size.width - right, y(g)), gridPaint);
      final tp = TextPainter(
          text: TextSpan(text: '${(g * 100).round()}%', style: label),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(axisWidth - 6 - tp.width, y(g) - tp.height / 2));
    }
    final n = values.length;
    double x(int i) => axisWidth + (n == 1 ? w / 2 : w * i / (n - 1));
    final stroke = Paint()
      ..color = line
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..color = line;
    Path? path;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null) {
        if (path != null) canvas.drawPath(path, stroke);
        path = null;
        continue;
      }
      final p = Offset(x(i), y(v));
      path == null
          ? path = (Path()..moveTo(p.dx, p.dy))
          : path.lineTo(p.dx, p.dy);
      canvas.drawCircle(p, 3, dot);
    }
    if (path != null) canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(ScoreChartPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.line != line ||
      oldDelegate.grid != grid;
}
