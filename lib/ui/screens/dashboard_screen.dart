import 'dart:async';

import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../homegame/home_game.dart';
import '../theme.dart';
import '../widgets/range_grid.dart';

/// Big-type live view for a TV (screen-mirror the phone, or later Cast).
/// During a live game it only shows hands older than the chosen delay, so
/// the table can't read the hand that just finished off the screen.
class DashboardScreen extends StatefulWidget {
  final HomeGameModel model;
  final HomeSession? session;
  const DashboardScreen({super.key, required this.model, this.session});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Delayed hands "arrive" over time even when nobody logs anything.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final s = widget.session ?? model.active;
        if (s == null) {
          return const Scaffold(body: Center(child: Text('No game in progress')));
        }
        final live = !s.closed;
        final cutoff = DateTime.now().millisecondsSinceEpoch -
            model.dashboardDelayMinutes * 60000;
        final shown = live ? s.hands.where((h) => h.ts <= cutoff).toList() : s.hands;
        final hidden = s.hands.length - shown.length;
        final st = computeStats(shown, model.library);
        return Scaffold(
          backgroundColor: Felt.feltDark,
          appBar: AppBar(
            backgroundColor: Felt.feltDark,
            foregroundColor: Colors.white,
            title: Text(s.name),
            actions: [
              if (live)
                PopupMenuButton<int>(
                  tooltip: 'Delay',
                  initialValue: model.dashboardDelayMinutes,
                  onSelected: model.setDelay,
                  itemBuilder: (_) => [
                    for (final m in dashboardDelays)
                      PopupMenuItem(
                          value: m, child: Text(m == 0 ? 'Instant' : '$m min delay')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      const Icon(Icons.schedule, size: 18, color: Felt.gold),
                      const SizedBox(width: 4),
                      Text(
                          model.dashboardDelayMinutes == 0
                              ? 'Instant'
                              : '${model.dashboardDelayMinutes} min',
                          style: const TextStyle(color: Felt.gold)),
                    ]),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                    child: Text('${st.logged} hands', style: const TextStyle(color: Felt.gold))),
              ),
            ],
          ),
          body: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > 800;
            final tiles = Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Tile('VPIP', st.recorded == 0 ? '–' : pct(st.vpipPct),
                    'put money in preflop', wide),
                _Tile('PFR', st.recorded == 0 ? '–' : pct(st.pfrPct),
                    'raised preflop', wide),
                _Tile('Style', st.style, '', wide, small: true),
                _Tile('GTO preflop', st.graded == 0 ? '–' : pct(st.gtoScore),
                    '${st.graded} unopened spots graded', wide),
                _Tile('Card luck', st.dealt == 0 ? '–' : _luck(st.avgStrength),
                    'avg equity vs a random hand', wide),
                _Tile('Premiums', '${st.premiums}',
                    'JJ+/AK · expected ${(st.dealt * SessionStats.premiumRate).toStringAsFixed(1)}',
                    wide),
              ],
            );
            final map = _StyleMap(vpip: st.vpipPct, pfr: st.pfrPct, show: st.recorded > 0);
            final strip = _StrengthStrip(
                values: [
                  for (final h in shown)
                    if (h.hand != null) model.library.vsRandom.isEmpty ? 0.5 : model.library.vsRandom[h.hand!.index]
                ]);
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (live && hidden > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                        '$hidden recent hand${hidden == 1 ? '' : 's'} will appear after the '
                        '${model.dashboardDelayMinutes}-minute delay',
                        style: const TextStyle(color: Colors.white54)),
                  ),
                if (wide)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 3, child: tiles),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: map),
                  ])
                else ...[
                  tiles,
                  const SizedBox(height: 16),
                  map,
                ],
                const SizedBox(height: 16),
                const Text('Your cards tonight (taller = stronger)',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                strip,
                if (st.misses.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Most teachable so far',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  for (final (h, spot, _) in st.misses.reversed.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                          'Hand ${h.number}: ${h.hand!.name} from ${h.position}: you '
                          '${_past[h.action]}, GTO ${strategyLine(spot, h.hand!)}',
                          style: const TextStyle(color: Colors.white70, fontSize: 15)),
                    ),
                ],
              ],
            );
          }),
        );
      },
    );
  }

  static String _luck(double avg) {
    // A random hand averages 50% vs another random hand.
    final d = (avg - 0.5) * 100;
    return '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)}%';
  }
}

const _past = {
  PreAction.fold: 'folded',
  PreAction.call: 'called',
  PreAction.raise: 'raised',
};

class _Tile extends StatelessWidget {
  final String label, value, sub;
  final bool wide;
  final bool small;
  const _Tile(this.label, this.value, this.sub, this.wide, {this.small = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: wide ? 220 : 160,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Felt.feltCard, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: const TextStyle(color: Felt.gold, fontSize: 12, letterSpacing: 1.2)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                color: Colors.white,
                fontSize: small ? (wide ? 22 : 18) : (wide ? 40 : 32),
                fontWeight: FontWeight.w800)),
        if (sub.isNotEmpty)
          Text(sub, style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ]),
    );
  }
}

/// VPIP (x) vs PFR (y) with the classic style regions.
class _StyleMap extends StatelessWidget {
  final double vpip, pfr;
  final bool show;
  const _StyleMap({required this.vpip, required this.pfr, required this.show});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.2,
      child: Container(
        decoration: BoxDecoration(
            color: Felt.feltCard, borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.all(12),
        child: CustomPaint(
            painter: _StylePainter(
                vpip, pfr, show, DefaultTextStyle.of(context).style)),
      ),
    );
  }
}

class _StylePainter extends CustomPainter {
  final double vpip, pfr;
  final bool show;

  /// The surrounding text style, so the labels use the app's font.
  final TextStyle base;
  _StylePainter(this.vpip, this.pfr, this.show, this.base);

  static const maxV = 0.6, maxP = 0.4;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    Offset pt(double v, double p) =>
        Offset(size.width * (v / maxV), size.height * (1 - p / maxP));
    // Region dividers: VPIP 15% / 28% / 45%; aggressive above PFR = 0.6·VPIP.
    for (final v in [0.15, 0.28, 0.45]) {
      canvas.drawLine(pt(v, 0), pt(v, maxP), grid);
    }
    canvas.drawLine(pt(0, 0), pt(maxV, maxV * 0.6), grid..color = Colors.white38);
    void label(String s, double v, double p) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: base.copyWith(color: Colors.white54, fontSize: 11)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pt(v, p) - Offset(tp.width / 2, tp.height / 2));
    }

    label('Rock', 0.075, 0.03);
    label('TAG', 0.215, 0.2);
    label('Tight-passive', 0.215, 0.03);
    label('LAG', 0.365, 0.3);
    label('Loose-passive', 0.365, 0.05);
    label('Station', 0.525, 0.05);
    label('Maniac', 0.525, 0.36);
    final axis = TextPainter(
      text: TextSpan(
          text: 'VPIP →   ·   PFR ↑',
          style: base.copyWith(color: Colors.white38, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    axis.paint(canvas, Offset(size.width - axis.width, size.height - axis.height));
    if (show) {
      final p = pt(vpip.clamp(0, maxV), pfr.clamp(0, maxP));
      canvas.drawCircle(p, 13, Paint()..color = Felt.gold.withOpacity(0.3));
      canvas.drawCircle(p, 8, Paint()..color = Felt.gold);
    }
  }

  @override
  bool shouldRepaint(_StylePainter old) =>
      old.vpip != vpip ||
      old.pfr != pfr ||
      old.show != show ||
      old.base != base;
}

class _StrengthStrip extends StatelessWidget {
  final List<double> values;
  const _StrengthStrip({required this.values});

  @override
  Widget build(BuildContext context) {
    final last = values.length > 60 ? values.sublist(values.length - 60) : values;
    if (last.isEmpty) {
      return const Text('No hands yet', style: TextStyle(color: Colors.white38));
    }
    // Fixed-width bars (room for 60) so a short night doesn't stretch.
    return SizedBox(
      height: 70,
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth / 60;
        return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final v in last)
            SizedBox(
              width: w,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: FractionallySizedBox(
                  // 0.3 (worst) .. 0.85 (AA) mapped onto 10%..100% height.
                  heightFactor: (0.1 + (v - 0.3) / 0.55 * 0.9).clamp(0.1, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: HeatGrid.heat(((v - 0.3) / 0.55).clamp(0, 1)),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
        ]);
      }),
    );
  }
}
