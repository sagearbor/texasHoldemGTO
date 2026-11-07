// Pulse on the TV: one line chart of the last 10 minutes, a line per
// player ending in their face circle (crown and glow on the leader), the
// leader's song (with "Tap to enable sound" when the browser blocks it)
// and the now-playing chip with "Listen on Apple Music".

import 'dart:math';

import 'package:flutter/material.dart';

import '../../pulse/pulse_board.dart';
import '../../pulse/pulse_cloud.dart';
import '../theme.dart';
import 'pulse_widgets.dart';
import 'song_player.dart';

const _dim = Color(0xFF9FB3A8);
const _grid = Color(0xFF1E3329);

Color pulseColour(int i) => Color(pulseColours[i % pulseColours.length]);

/// The TV's song: runs [SongDj] once a second and plays the leader's
/// preview. A browser that blocks sound until a tap leaves [blocked] set;
/// [enable] (the "Tap to enable sound" button) plays it from the tap.
class PulseTvAudio extends ChangeNotifier {
  final SongPlayer player;
  final SongDj dj;
  /// [blocked] from the start on the web: a fresh TV page has had no tap,
  /// so browsers refuse sound; one tap on the button unlocks it for good.
  PulseTvAudio(this.player, {SongDj? dj, this.blocked = false}) : dj = dj ?? SongDj();

  PulseMember? nowPlaying;
  int? startedAtMs;

  /// The browser refused to play without a tap.
  bool blocked;

  /// Sound switched off on this TV.
  bool muted = false;

  /// A preview runs 30 s: the chip goes after this.
  static const previewMs = 30000;

  Future<void> tick(int nowMs, PulseBoard board) async {
    final at = startedAtMs;
    if (nowPlaying != null && at != null && nowMs - at > previewMs) {
      nowPlaying = null;
      notifyListeners();
    }
    final m = dj.tick(nowMs, board);
    if (m == null || muted) return;
    // Still blocked: show the chip and the button, try anyway (a browser
    // that already allows sound just plays).
    nowPlaying = m;
    startedAtMs = nowMs;
    final ok = await player.play(m.song!.previewUrl);
    blocked = !ok;
    notifyListeners();
  }

  /// From a tap: browsers allow sound now.
  Future<void> enable(int nowMs) async {
    blocked = false;
    muted = false;
    final m = nowPlaying;
    if (m?.song != null) {
      startedAtMs = nowMs;
      blocked = !await player.play(m!.song!.previewUrl);
    }
    notifyListeners();
  }

  Future<void> setMuted(bool v) async {
    muted = v;
    if (v) await player.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    player.stop();
    player.dispose();
    super.dispose();
  }
}

class PulseChart extends StatelessWidget {
  final PulseBoard board;
  final double scale;

  /// The face circle at each line's end (96 px on a TV).
  final double faceSize;
  const PulseChart({super.key, required this.board, this.scale = 1, this.faceSize = 96});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: LayoutBuilder(builder: (context, box) {
          final g = _Geometry(board, box.biggest, faceSize, scale);
          return Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(child: CustomPaint(painter: _ChartPainter(board, g, scale))),
            for (final e in g.ends) ..._end(e, g),
          ]);
        }),
      ),
      SizedBox(height: 6 * scale),
      // Legend: identity never by colour alone.
      Wrap(spacing: 16 * scale, runSpacing: 4 * scale, children: [
        for (final l in board.lines)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 18 * scale, height: 3 * scale, color: pulseColour(l.colour)),
            SizedBox(width: 6 * scale),
            Text(l.member.name, style: TextStyle(color: Colors.white, fontSize: 14 * scale)),
          ]),
      ]),
    ]);
  }

  List<Widget> _end(_End e, _Geometry g) {
    final l = e.line;
    final f = faceSize;
    final lead = l.leader;
    return [
      if (e.faceY != e.y)
        Positioned.fill(child: CustomPaint(painter: _Connector(Offset(e.x, e.y), Offset(g.faceX, e.faceY), pulseColour(l.colour)))),
      Positioned(
        left: g.faceX - f / 2,
        top: e.faceY - f / 2,
        child: Container(
          key: ValueKey('pulse-face-${l.deviceId}'),
          decoration: lead
              ? BoxDecoration(shape: BoxShape.circle, boxShadow: [
                  BoxShadow(color: Felt.gold.withOpacity(0.7), blurRadius: f * 0.35, spreadRadius: f * 0.04)
                ])
              : null,
          child: FaceCircle.b64(l.member.faceB64,
              name: l.member.name,
              colour: pulseColour(l.colour),
              size: f,
              ring: lead ? Felt.gold : pulseColour(l.colour),
              ringWidth: max(2, f * (lead ? 0.07 : 0.045))),
        ),
      ),
      if (lead)
        Positioned(
          left: g.faceX - f * 0.25,
          top: e.faceY - f / 2 - f * 0.42,
          child: Icon(Icons.emoji_events, key: const Key('pulse-crown'), color: Felt.gold, size: f * 0.5),
        ),
      Positioned(
        left: g.faceX + f / 2 + 8 * scale,
        top: e.faceY - 20 * scale,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.bpm == null ? '--' : '${l.bpm}',
              style: TextStyle(
                  color: lead ? Felt.gold : Colors.white,
                  fontSize: 26 * scale,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          Text(l.bpm == null ? 'no signal' : 'bpm', style: TextStyle(color: _dim, fontSize: 12 * scale, height: 1.2)),
        ]),
      ),
    ];
  }
}

class _End {
  final PulseLine line;
  final double x, y;
  double faceY;
  _End(this.line, this.x, this.y) : faceY = y;
}

/// Where everything goes: plot area left, a column for faces and bpm right.
class _Geometry {
  final PulseBoard b;
  final Rect plot;
  final double faceX;
  final List<_End> ends = [];

  _Geometry(this.b, Size size, double face, double scale)
      : plot = Rect.fromLTRB(40 * scale, face * 0.75, max(80 * scale, size.width - face - 70 * scale), max(face, size.height - 22 * scale)),
        faceX = max(80 * scale, size.width - face - 70 * scale) + face / 2 + 4 * scale {
    for (final l in b.lines) {
      if (l.visible.isEmpty) continue;
      final last = l.visible.last;
      ends.add(_End(l, xOf(last.tMs), yOf(l.bpm ?? last.bpm)));
    }
    // Faces may not overlap: push them apart vertically, keep them inside.
    ends.sort((a, c) => a.y.compareTo(c.y));
    final gap = face * 1.02;
    for (var i = 1; i < ends.length; i++) {
      ends[i].faceY = max(ends[i].faceY, ends[i - 1].faceY + gap);
    }
    final bottom = plot.bottom;
    if (ends.isNotEmpty && ends.last.faceY > bottom) {
      ends.last.faceY = bottom;
      for (var i = ends.length - 2; i >= 0; i--) {
        ends[i].faceY = min(ends[i].faceY, ends[i + 1].faceY - gap);
      }
    }
  }

  double xOf(int t) => plot.left + (t - b.fromMs) / max(1, b.toMs - b.fromMs) * plot.width;
  double yOf(int bpm) => plot.bottom - (bpm - b.minBpm) / max(1, b.maxBpm - b.minBpm) * plot.height;
}

class _ChartPainter extends CustomPainter {
  final PulseBoard b;
  final _Geometry g;
  final double scale;
  _ChartPainter(this.b, this.g, this.scale);

  void _text(Canvas c, String s, Offset at, {TextAlign align = TextAlign.left}) {
    final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(color: _dim, fontSize: 12 * scale)), textDirection: TextDirection.ltr)
      ..layout();
    final dx = align == TextAlign.right ? at.dx - tp.width : (align == TextAlign.center ? at.dx - tp.width / 2 : at.dx);
    tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = g.plot;
    final grid = Paint()
      ..color = _grid
      ..strokeWidth = 1;
    final step = b.maxBpm - b.minBpm > 60 ? 20 : 10;
    for (var v = (b.minBpm / step).ceil() * step; v <= b.maxBpm; v += step) {
      final y = g.yOf(v);
      canvas.drawLine(Offset(p.left, y), Offset(p.right, y), grid);
      _text(canvas, '$v', Offset(p.left - 6 * scale, y), align: TextAlign.right);
    }
    final span = b.toMs - b.fromMs;
    for (final (frac, label) in [(0.0, '-${span ~/ 60000} min'), (0.5, '-${span ~/ 120000} min'), (1.0, 'now')]) {
      _text(canvas, label, Offset(p.left + frac * p.width, p.bottom + 12 * scale),
          align: frac == 0 ? TextAlign.left : (frac == 1 ? TextAlign.right : TextAlign.center));
    }
    // Non-leaders first, the leader on top.
    final order = [...b.lines]..sort((a, c) => (a.leader ? 1 : 0) - (c.leader ? 1 : 0));
    for (final l in order) {
      if (l.visible.isEmpty) continue;
      final paint = Paint()
        ..color = pulseColour(l.colour)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (l.leader ? 3.5 : 2.5) * scale
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final path = Path();
      int? prevT;
      for (final s in l.visible) {
        final pt = Offset(g.xOf(s.tMs), g.yOf(s.bpm.clamp(b.minBpm, b.maxBpm)));
        // A gap of more than 20 s (watch off) breaks the line.
        if (prevT == null || s.tMs - prevT > 20000) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
        prevT = s.tMs;
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => true;
}

class _Connector extends CustomPainter {
  final Offset a, b;
  final Color colour;
  _Connector(this.a, this.b, this.colour);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
        a,
        b,
        Paint()
          ..color = colour.withOpacity(0.6)
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_Connector old) => old.a != a || old.b != b;
}

/// The song playing: artwork, title, artist, "Listen on Apple Music".
class NowPlayingChip extends StatelessWidget {
  final PulseMember member;
  final double scale;
  const NowPlayingChip({super.key, required this.member, this.scale = 1});

  @override
  Widget build(BuildContext context) {
    final s = member.song!;
    return Container(
      key: const Key('pulse-now-playing'),
      padding: EdgeInsets.all(6 * scale),
      decoration: BoxDecoration(color: const Color(0xFF10221A), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(s.artworkUrl,
              width: 44 * scale,
              height: 44 * scale,
              errorBuilder: (_, __, ___) => Icon(Icons.music_note, color: _dim, size: 44 * scale)),
        ),
        SizedBox(width: 10 * scale),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text("♪ ${member.name}'s song: ${s.title}",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white, fontSize: 15 * scale, fontWeight: FontWeight.w700)),
            Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _dim, fontSize: 13 * scale)),
            InkWell(
              onTap: () => openSongLink(s.trackViewUrl),
              child: Text('Listen on Apple Music',
                  style: TextStyle(color: Felt.gold, fontSize: 12 * scale, decoration: TextDecoration.underline)),
            ),
          ]),
        ),
      ]),
    );
  }
}
