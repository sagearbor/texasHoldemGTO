/// Shareable report-card images: a 1080x1350 felt card rendered off-screen
/// to PNG and handed to the system share sheet (a download on desktop web).
/// Every number on the card comes from the same stored data and gates as
/// the in-app screens; nothing is generated.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../gto/coach.dart';
import '../../homegame/recap.dart';
import '../../trainer/trainer_model.dart';
import '../../poker/cards.dart';
import '../theme.dart';
import 'range_grid.dart';

/// Portrait 4:5, the size Instagram and most chat apps show uncropped.
const shareCardSize = Size(1080, 1350);
const shareFooter = 'Felt Notes · sagearbor.github.io/texasHoldemGTO';

// ------------------------------------------------------------------ render

/// Lays out [card] off-screen at [size] logical pixels and returns PNG
/// bytes of exactly that many pixels. Throws where the renderer cannot
/// read pixels back (the HTML web renderer).
Future<Uint8List> renderShareCardPng(Widget card, {Size size = shareCardSize}) async {
  final boundary = RenderRepaintBoundary();
  final view = WidgetsBinding.instance.platformDispatcher.implicitView ??
      WidgetsBinding.instance.platformDispatcher.views.first;
  final renderView = RenderView(
    view: view,
    child: RenderPositionedBox(alignment: Alignment.center, child: boundary),
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size),
      devicePixelRatio: 1,
    ),
  );
  final pipeline = PipelineOwner()..rootNode = renderView;
  renderView.prepareInitialFrame();
  final build = BuildOwner(focusManager: FocusManager());
  final root = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.noScaling),
      child: Directionality(
        textDirection: TextDirection.ltr,
        // Share cards are dark-only by design, whatever the app theme.
        child: Theme(
          data: Felt.dark(),
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white, fontSize: 32),
            child: SizedBox.fromSize(size: size, child: card),
          ),
        ),
      ),
    ),
  ).attachToRenderTree(build);
  try {
    build.buildScope(root);
    build.finalizeTree();
    pipeline.flushLayout();
    pipeline.flushCompositingBits();
    pipeline.flushPaint();
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG encoding failed');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    // Unmount the off-screen tree so nothing outlives the render.
    RenderObjectToWidgetAdapter<RenderBox>(container: boundary).attachToRenderTree(build, root);
    build.finalizeTree();
  }
}

/// Renders [card] and opens the share sheet. On web without the Web Share
/// API, share_plus downloads the PNG instead. If the image cannot be made
/// at all, [fallbackText] goes to the clipboard.
Future<void> shareCardImage(
  BuildContext context, {
  required Widget card,
  required String fileName,
  required String fallbackText,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  try {
    final png = await renderShareCardPng(card);
    final file = XFile.fromData(png, mimeType: 'image/png', name: fileName);
    await Share.shareXFiles([file],
        text: kIsWeb ? null : fallbackText.split('\n').first,
        fileNameOverrides: [fileName],
        sharePositionOrigin: origin);
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: fallbackText));
    messenger?.showSnackBar(const SnackBar(
        content: Text('Could not make the image here: recap copied as text instead')));
  }
}

// ------------------------------------------------------------------ layout

/// The felt frame shared by every card: title band, body, footer.
class ShareCardFrame extends StatelessWidget {
  final String kicker;
  final String title;
  final String? subtitle;
  final Widget body;
  const ShareCardFrame({
    super.key,
    required this.kicker,
    required this.title,
    this.subtitle,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          colors: [Color(0xFF2F6B47), Felt.feltCard, Felt.feltDark],
          stops: [0, 0.75, 1],
          radius: 1.15,
        ),
      ),
      padding: const EdgeInsets.all(36),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(48),
          border: Border.all(color: Felt.gold.withOpacity(0.6), width: 4),
        ),
        padding: const EdgeInsets.fromLTRB(64, 56, 64, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(kicker.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Felt.gold, fontSize: 30, letterSpacing: 8, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _Fit(title,
              style: const TextStyle(
                  color: Colors.white, fontSize: 64, fontWeight: FontWeight.w800, height: 1.1)),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(subtitle!,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 32)),
            ),
          const SizedBox(height: 36),
          // Scale the body down rather than overflow on a very full night.
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: SizedBox(width: c.maxWidth, child: body),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Container(height: 2, color: Felt.gold.withOpacity(0.4)),
          const SizedBox(height: 22),
          const _Fit(shareFooter,
              style: TextStyle(color: Felt.gold, fontSize: 30, letterSpacing: 1)),
        ]),
      ),
    );
  }
}

/// One-line text that shrinks to fit rather than wrapping or clipping.
class _Fit extends StatelessWidget {
  final String text;
  final TextStyle style;
  const _Fit(this.text, {required this.style});

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text, maxLines: 1, textAlign: TextAlign.center, style: style),
      );
}

/// A big number with a label under it.
class _Stat extends StatelessWidget {
  final String label, value;
  final String? note;
  final Color color;
  const _Stat(this.label, this.value, {this.note, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.22),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _Fit(value,
            style: TextStyle(color: color, fontSize: 76, fontWeight: FontWeight.w800, height: 1.1)),
        _Fit(label.toUpperCase(),
            style: const TextStyle(color: Felt.gold, fontSize: 24, letterSpacing: 3)),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _Fit(note!, style: const TextStyle(color: Colors.white70, fontSize: 24)),
          ),
      ]),
    );
  }
}

/// A labelled line: "Best hand ........ AA".
class _Line extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final String? note;
  const _Line(this.icon, this.label, this.value, {this.note});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Icon(icon, color: Felt.gold, size: 44),
        const SizedBox(width: 22),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, maxLines: 1, style: const TextStyle(color: Colors.white70, fontSize: 26)),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white, fontSize: 40, fontWeight: FontWeight.w700)),
            if (note != null)
              Text(note!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 24)),
          ]),
        ),
      ]),
    );
  }
}

/// Two-column grid of [_Stat]s with no scrolling.
Widget _statGrid(List<_Stat> stats) {
  final rows = <Widget>[];
  for (var i = 0; i < stats.length; i += 2) {
    rows.add(Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: stats[i]),
        const SizedBox(width: 20),
        Expanded(child: i + 1 < stats.length ? stats[i + 1] : const SizedBox()),
      ])),
    ));
  }
  return Column(mainAxisSize: MainAxisSize.min, children: rows);
}

const _suitGlyph = {'s': '♠', 'h': '♥', 'd': '♦', 'c': '♣'};

String _pretty(String card) => '${card[0]}${_suitGlyph[card[1]] ?? card[1]}';

String _date(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

// ------------------------------------------------------------------ night card

/// The award worth headlining: the first non-dealer award (dealer luck has
/// its own line), else the first award.
Award? topAward(NightRecap r) {
  for (final a in r.awards) {
    if (a.id != AwardId.goldenArm && a.id != AwardId.dealerOfDoom) return a;
  }
  return r.awards.isEmpty ? null : r.awards.first;
}

class NightShareCard extends StatelessWidget {
  final NightRecap recap;
  const NightShareCard(this.recap, {super.key});

  @override
  Widget build(BuildContext context) {
    final r = recap, st = r.stats;
    final stats = <_Stat>[
      _Stat('hands', '${st.logged}',
          note: r.duration == null ? null : 'over ${durationLabel(r.duration!)}'),
      if (r.showStyle)
        _Stat('style', st.style, note: 'VPIP ${pct(st.vpipPct)} · PFR ${pct(st.pfrPct)}'),
      if (r.showGto)
        _Stat('GTO grade', r.gtoGrade!,
            note: '${pct(st.gtoScore)} of ${st.graded} spots',
            color: st.gtoScore >= 0.8 ? Felt.good : (st.gtoScore >= 0.6 ? Felt.mixed : Felt.bad)),
      if (r.showPremiums)
        _Stat('premiums', '${st.premiums}',
            note: '${r.expectedPremiums.toStringAsFixed(1)} expected'),
    ];
    final best = r.best;
    final award = topAward(r);
    final golden = r.dealers.goldenArm, doom = r.dealers.dealerOfDoom;
    return ShareCardFrame(
      kicker: 'Night recap',
      title: r.session.name,
      subtitle: _date(r.session.started),
      body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _statGrid(stats),
            if (best != null)
              _Line(Icons.emoji_events_outlined, 'Best hand',
                  '${best.hand!.name}  ${best.cards!.map((c) => _pretty(cardToString(c))).join(' ')}',
                  note:
                      'Hand #${best.number} from ${best.position} · ${pct(r.bestEquity)} vs random'),
            if (award != null)
              _Line(Icons.military_tech_outlined, 'Top award', award.title, note: award.detail),
            if (golden != null)
              _Line(Icons.back_hand_outlined, 'Golden Arm', golden.name,
                  note: '${luckLabel(golden.avgEquity)} card luck over ${golden.hands} hands'),
            if (doom != null)
              _Line(Icons.back_hand_outlined, 'Dealer of Doom', doom.name,
                  note: '${luckLabel(doom.avgEquity)} card luck over ${doom.hands} hands'),
          ]),
    );
  }
}

// ------------------------------------------------------------------ trainer card

/// Trainer numbers for the "My GTO report card" share.
class TrainerReport {
  final int drilled;
  final double accuracy;
  final double? last7;

  /// Spots with enough drills to judge (best / worst accuracy).
  final (String, double, int)? bestSpot, worstSpot;

  /// Longest run of non-miss answers ever, and the run you are on now.
  final int bestStreak, currentStreak;

  const TrainerReport({
    required this.drilled,
    required this.accuracy,
    required this.last7,
    required this.bestSpot,
    required this.worstSpot,
    required this.bestStreak,
    required this.currentStreak,
  });

  static const minSpotDrills = 5;

  factory TrainerReport.from(TrainerModel m, {DateTime? now}) {
    // Hand-authored spots are drilled but never scored.
    final h = m.scoredHistory;
    final week = (now ?? DateTime.now()).subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    final recent = h.where((a) => a.ts >= week).toList();
    final spots = [
      for (final e in m.bySpot().entries)
        if (e.value.length >= minSpotDrills)
          (m.library.byId(e.key).title, m.accuracy(e.value), e.value.length)
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    var best = 0, run = 0;
    for (final a in h) {
      run = a.isMiss ? 0 : run + 1;
      if (run > best) best = run;
    }
    return TrainerReport(
      drilled: m.history.length,
      accuracy: m.accuracy(h),
      last7: recent.isEmpty ? null : m.accuracy(recent),
      bestSpot: spots.isEmpty ? null : spots.last,
      worstSpot: spots.length < 2 ? null : spots.first,
      bestStreak: best,
      currentStreak: run,
    );
  }

  String toText() {
    final b = StringBuffer('My GTO report card - Felt Notes\n');
    b.writeln('Hands drilled: $drilled');
    b.writeln('Accuracy: ${pct(accuracy)} (grade ${letterGrade(accuracy)})');
    if (last7 != null) b.writeln('Last 7 days: ${pct(last7!)}');
    if (bestSpot != null) b.writeln('Best spot: ${bestSpot!.$1} ${pct(bestSpot!.$2)}');
    if (worstSpot != null) b.writeln('Worst spot: ${worstSpot!.$1} ${pct(worstSpot!.$2)}');
    b.writeln('Best streak: $bestStreak');
    b.write(shareFooter);
    return b.toString();
  }
}

class TrainerShareCard extends StatelessWidget {
  final TrainerReport report;
  final DateTime? date;
  const TrainerShareCard(this.report, {super.key, this.date});

  @override
  Widget build(BuildContext context) {
    final r = report;
    final grade = letterGrade(r.accuracy);
    return ShareCardFrame(
      kicker: 'My GTO report card',
      title: 'Grade $grade',
      subtitle: 'Preflop trainer · ${_date((date ?? DateTime.now()).millisecondsSinceEpoch)}',
      body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _statGrid([
              _Stat('accuracy', pct(r.accuracy),
                  color: HeatGrid.heat(r.accuracy),
                  note: r.last7 == null ? null : 'last 7 days ${pct(r.last7!)}'),
              _Stat('hands drilled', '${r.drilled}'),
              _Stat('best streak', '${r.bestStreak}', note: 'GTO plays in a row'),
              _Stat('current streak', '${r.currentStreak}'),
            ]),
            if (r.bestSpot != null)
              _Line(Icons.trending_up, 'Best spot', r.bestSpot!.$1,
                  note: '${pct(r.bestSpot!.$2)} over ${r.bestSpot!.$3} hands'),
            if (r.worstSpot != null)
              _Line(Icons.school_outlined, 'Working on', r.worstSpot!.$1,
                  note: '${pct(r.worstSpot!.$2)} over ${r.worstSpot!.$3} hands'),
          ]),
    );
  }
}
