import 'dart:async';

import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../homegame/home_game.dart';
import '../theme.dart';
import '../widgets/blind_clock_strip.dart';
import '../widgets/dealer_luck_tile.dart';
import '../widgets/moments_carousel.dart';
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

  // Dark-only by design (read across the room / shared as screenshots):
  // the felt look stays even when the app is in light mode.
  @override
  Widget build(BuildContext context) => Felt.darkOnly(Builder(builder: _build));

  Widget _build(BuildContext context) {
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
            // Phone: two tiles fill the row (fixed 160 px left a ragged
            // 50 px gap on the right at 390 px).
            // TV / desktop: three tiles per row filling the left 3/5 column,
            // with text scaled to the screen so it reads across the room.
            final scale = wide ? (c.maxWidth / 1100).clamp(1.0, 1.7) : 1.0;
            final tileW = wide
                ? (((c.maxWidth - 32 - 16) * 3 / 5 - 2 * 12) / 3).floorToDouble()
                : ((c.maxWidth - 32 - 12) / 2).floorToDouble();
            final tiles = Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Tile('VPIP', st.recorded == 0 ? '–' : pct(st.vpipPct),
                    'put money in preflop', wide, width: tileW, scale: scale),
                _Tile('PFR', st.recorded == 0 ? '–' : pct(st.pfrPct),
                    'raised preflop', wide, width: tileW, scale: scale),
                _Tile('Style', st.style, '', wide, small: true, width: tileW, scale: scale),
                _Tile('GTO preflop', st.graded == 0 ? '–' : pct(st.gtoScore),
                    '${st.graded} unopened spots graded', wide, width: tileW, scale: scale),
                _Tile('Card luck', st.dealt == 0 ? '–' : _luck(st.avgStrength),
                    'avg equity vs a random hand', wide, width: tileW, scale: scale),
                _Tile('Premiums', '${st.premiums}',
                    'JJ+/AK · expected ${(st.dealt * SessionStats.premiumRate).toStringAsFixed(1)}',
                    wide, width: tileW, scale: scale),
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
                if (live) const BlindClockStrip(),
                if (live && hidden > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                        '$hidden recent hand${hidden == 1 ? '' : 's'} will appear after the '
                        '${model.dashboardDelayMinutes}-minute delay',
                        style: const TextStyle(color: Colors.white54)),
                  ),
                MomentsCarousel(hands: shown, library: model.library),
                DramaLine(hands: shown),
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
                Text('Your cards tonight (taller = stronger)',
                    style: TextStyle(color: Colors.white70, fontSize: 14 * scale)),
                const SizedBox(height: 6),
                strip,
                const SizedBox(height: 16),
                DealerLuckTile(hands: shown, library: model.library),
                if (st.misses.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Most teachable so far',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18 * scale,
                          fontWeight: FontWeight.w700)),
                  for (final (h, spot, _) in st.misses.reversed.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                          'Hand ${h.number}: ${h.hand!.name} from ${h.position}: you '
                          '${_past[h.action]}, GTO ${strategyLine(spot, h.hand!)}',
                          style: TextStyle(color: Colors.white70, fontSize: 15 * scale)),
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
  final double? width;
  final double scale;
  const _Tile(this.label, this.value, this.sub, this.wide,
      {this.small = false, this.width, this.scale = 1});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width ?? (wide ? 220 : 160),
      padding: EdgeInsets.all(14 * scale),
      decoration: BoxDecoration(
          color: Felt.feltCard, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: TextStyle(color: Felt.gold, fontSize: 12 * scale, letterSpacing: 1.2)),
        SizedBox(height: 4 * scale),
        Text(value,
            style: TextStyle(
                color: Colors.white,
                fontSize: (small ? (wide ? 22 : 18) : (wide ? 40 : 32)) * scale,
                fontWeight: FontWeight.w800)),
        if (sub.isNotEmpty)
          Text(sub,
              style: TextStyle(
                  color: Colors.white60, fontSize: (wide ? 14 : 12) * scale)),
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
    // Region labels grow with the map: a fixed 11 px was unreadable on a
    // TV across the table.
    final fs = (size.width / 36).clamp(11.0, 22.0);
    // The axis caption sits in its own strip under the plot so it never
    // crosses a grid line or a region label.
    final axis = TextPainter(
      text: TextSpan(
          text: 'VPIP →   ·   PFR ↑',
          style: base.copyWith(color: Colors.white38, fontSize: fs - 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    final plotH = size.height - axis.height - 4;
    Offset pt(double v, double p) =>
        Offset(size.width * (v / maxV), plotH * (1 - p / maxP));
    // Region dividers: VPIP 15% / 28% / 45%; aggressive above PFR = 0.6·VPIP.
    for (final v in [0.15, 0.28, 0.45]) {
      canvas.drawLine(pt(v, 0), pt(v, maxP), grid);
    }
    canvas.drawLine(pt(0, 0), pt(maxV, maxV * 0.6), grid..color = Colors.white38);
    void label(String s, double v, double p) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: base.copyWith(color: Colors.white54, fontSize: fs)),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pt(v, p) - Offset(tp.width / 2, tp.height / 2));
    }

    // Rock: mid-column, well clear of the aggression diagonal near the floor.
    label('Rock', 0.075, 0.2);
    label('TAG', 0.215, 0.2);
    // Two lines: one line was wider than its 13%-VPIP column on a phone
    // and ran over the grid lines.
    label('Tight-\npassive', 0.215, 0.05);
    label('LAG', 0.365, 0.3);
    label('Loose-\npassive', 0.365, 0.05);
    label('Station', 0.525, 0.05);
    label('Maniac', 0.525, 0.36);
    canvas.drawLine(Offset(0, plotH), Offset(size.width, plotH), grid..color = Colors.white24);
    axis.paint(canvas, Offset(size.width - axis.width, size.height - axis.height));
    if (show) {
      // Keep the whole marker inside the card: a 63% / 50% maniac sat on
      // the top-right corner, half outside it.
      final raw = pt(vpip.clamp(0, maxV), pfr.clamp(0, maxP));
      final p = Offset(raw.dx.clamp(13.0, size.width - 13),
          raw.dy.clamp(13.0, plotH - 13));
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
