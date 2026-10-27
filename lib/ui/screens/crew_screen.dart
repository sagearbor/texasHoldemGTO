import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../homegame/home_game.dart';
import '../../homegame/milestones.dart';
import '../../homegame/recap.dart';
import '../widgets/badges.dart';
import '../widgets/my_result_dialog.dart';

/// Everyone you've played with, plus your own numbers night by night.
class CrewScreen extends StatelessWidget {
  final HomeGameModel model;
  const CrewScreen({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final crew = crewStats(model.sessions);
    final trend = heroTrend(model.sessions, model.library);
    return Scaffold(
      appBar: AppBar(title: const Text('Crew & season')),
      body: crew.nights.isEmpty
          ? const Center(
              child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No game nights with hands logged yet.', textAlign: TextAlign.center),
            ))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                Text('Your season', style: t.titleLarge),
                Text(
                    '${crew.nights.length} night${crew.nights.length == 1 ? '' : 's'} · '
                    '${trend.fold(0, (a, n) => a + n.logged)} hands logged',
                    style: t.bodyMedium),
                const SizedBox(height: 8),
                _TrendRow('VPIP', [for (final n in trend) n.vpip], pct),
                _TrendRow('PFR', [for (final n in trend) n.pfr], pct),
                _TrendRow('Card luck', [for (final n in trend) n.avgStrength], luckLabel,
                    baseline: 0.5),
                _TrendRow('GTO preflop', [for (final n in trend) n.gto], pct),
                Text('Oldest night on the left. Gaps are nights with too few hands.',
                    style: t.bodySmall),
                const SizedBox(height: 24),
                Text('The crew', style: t.titleLarge),
                if (crew.members.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Nobody else seated yet.'),
                  ),
                for (final m in crew.members)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(m.name.characters.first.toUpperCase())),
                      title: Text(m.name),
                      subtitle: Text(
                          '${m.nights} of ${crew.nights.length} night${crew.nights.length == 1 ? '' : 's'}'
                          ' · last seen ${_date(m.lastSeen)}'),
                      trailing: m.streak >= 2
                          ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Text('${m.streak}',
                                  style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                              Text('in a row', style: t.bodySmall),
                            ])
                          : null,
                    ),
                  ),
                const SizedBox(height: 24),
                MyResultSummary(sessions: model.sessions),
                const SizedBox(height: 24),
                Text('Badges', style: t.titleLarge),
                BadgeWall(badges: milestones(model.sessions, model.library)),
              ],
            ),
    );
  }

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}/${d.day}/${d.year % 100}';
  }
}

class _TrendRow extends StatelessWidget {
  final String label;
  final List<double?> values;
  final String Function(double) format;
  final double? baseline;
  const _TrendRow(this.label, this.values, this.format, {this.baseline});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final last = values.lastWhere((v) => v != null, orElse: () => null);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(children: [
          SizedBox(
            width: 92,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t.labelMedium),
              Text(last == null ? '–' : format(last),
                  style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            ]),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 44,
              child: CustomPaint(
                painter: Sparkline(values,
                    color: cs.primary, faint: cs.onSurface.withOpacity(0.25), baseline: baseline),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Tiny line chart; null values leave a gap. One point is drawn as a dot.
class Sparkline extends CustomPainter {
  final List<double?> values;
  final Color color, faint;
  final double? baseline;
  Sparkline(this.values, {required this.color, required this.faint, this.baseline});

  @override
  void paint(Canvas canvas, Size size) {
    final present = [for (final v in values) if (v != null) v];
    if (present.isEmpty) return;
    var lo = present.reduce((a, b) => a < b ? a : b);
    var hi = present.reduce((a, b) => a > b ? a : b);
    if (baseline != null) {
      lo = lo < baseline! ? lo : baseline!;
      hi = hi > baseline! ? hi : baseline!;
    }
    if (hi - lo < 0.05) {
      final mid = (hi + lo) / 2;
      lo = mid - 0.025;
      hi = mid + 0.025;
    }
    final n = values.length;
    double x(int i) => n == 1 ? size.width / 2 : size.width * i / (n - 1);
    double y(double v) => size.height - 4 - (size.height - 8) * (v - lo) / (hi - lo);
    if (baseline != null) {
      canvas.drawLine(Offset(0, y(baseline!)), Offset(size.width, y(baseline!)),
          Paint()
            ..color = faint
            ..strokeWidth = 1);
    }
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Path? path;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null) {
        if (path != null) canvas.drawPath(path, line);
        path = null;
        continue;
      }
      final p = Offset(x(i), y(v));
      if (path == null) {
        path = Path()..moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawCircle(p, 2.5, Paint()..color = color);
    }
    if (path != null) canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(Sparkline oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.color != color ||
      oldDelegate.baseline != baseline;
}
