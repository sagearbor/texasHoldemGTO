/// Drawing the seat radar: the table, the camera, and one shape per person
/// on the band of chairs around it (radar_shapes.dart). Puzzle: the shapes
/// tile the band and never overlap; Overlap: each person's own 60% region.
/// Narrow and solid = sure, wide and faint = unsure; grey band = nobody's
/// phone there. Small faint seat numbers sit just inside the table edge.
/// Shapes tween (600 ms) from the last picture. Shared by the organizer's
/// Radar screen and the TV.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'radar_model.dart';
import 'radar_shapes.dart';

/// Colour-blind-safe (Okabe-Ito, then Tol's muted), also apart in
/// lightness.
const radarPalette = [
  Color(0xFFE69F00), // orange
  Color(0xFF56B4E9), // sky blue
  Color(0xFF009E73), // bluish green
  Color(0xFFF0E442), // yellow
  Color(0xFF0072B2), // blue
  Color(0xFFD55E00), // vermillion
  Color(0xFFCC79A7), // reddish purple
  Color(0xFF999933), // olive
  Color(0xFF882255), // wine
  Color(0xFF44AA99), // teal
  Color(0xFFDDCC77), // sand
  Color(0xFF332288), // indigo
];

/// Stable colours: phones in id order.
Map<String, Color> radarColours(Iterable<String> phones) {
  final ids = phones.toList()..sort();
  return {for (var i = 0; i < ids.length; i++) ids[i]: radarPalette[i % radarPalette.length]};
}

/// The band's half-widths inward / outward from the chair line (metres).
const _bandIn = 0.19, _bandOut = 0.22;

/// Gap left at each end of a puzzle shape (cells) so neighbours touch
/// with a thin seam.
const _seam = 0.18;

class RadarView extends StatefulWidget {
  final RadarEstimate estimate;
  final Map<String, String> names;
  final Set<String> stale;
  final Map<String, Color> colours;

  /// The shapes to draw (already smoothed and partitioned); null: the
  /// puzzle shapes of [estimate] as it is.
  final List<SeatRegion>? regions;

  /// Overlap mode: translucent shapes with an outline.
  final bool overlap;

  /// Name for the organizer's own seat (no phone of theirs on it).
  final String? organizerName;
  final bool dark;
  const RadarView({
    super.key,
    required this.estimate,
    required this.names,
    required this.colours,
    this.stale = const {},
    this.regions,
    this.overlap = false,
    this.organizerName,
    this.dark = false,
  });

  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView> with SingleTickerProviderStateMixin {
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600))..value = 1;
  List<SeatRegion> _from = const [], _to = const [];

  List<SeatRegion> _target() =>
      widget.regions ?? radarRegions(widget.estimate, overlap: widget.overlap, organizer: widget.organizerName != null);

  @override
  void initState() {
    super.initState();
    _to = _target();
    _from = _to;
  }

  @override
  void didUpdateWidget(RadarView old) {
    super.didUpdateWidget(old);
    // The TV rebuilds every second: partition again only for new data.
    if (identical(old.estimate, widget.estimate) &&
        identical(old.regions, widget.regions) &&
        old.overlap == widget.overlap &&
        old.organizerName == widget.organizerName) {
      return;
    }
    final next = _target();
    if (!_same(next, _to)) {
      _from = lerpRegions(_from, _to, Curves.easeInOut.transform(_anim.value));
      _to = next;
      _anim.forward(from: 0);
    }
  }

  static bool _same(List<SeatRegion> a, List<SeatRegion> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lay = widget.estimate.layout;
    final xs = [...lay.slots.map((p) => p.$1), lay.camera.$1], ys = [...lay.slots.map((p) => p.$2), lay.camera.$2];
    final w = xs.reduce(math.max) - xs.reduce(math.min) + 1.2, h = ys.reduce(math.max) - ys.reduce(math.min) + 1.0;
    return AspectRatio(
      aspectRatio: w / h,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) => CustomPaint(
          painter: _RadarPainter(
            widget.estimate,
            lerpRegions(_from, _to, Curves.easeInOut.transform(_anim.value)),
            widget.names,
            widget.colours,
            widget.stale,
            widget.organizerName,
            widget.dark,
            widget.overlap,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final RadarEstimate e;
  final List<SeatRegion> regions;
  final Map<String, String> names;
  final Map<String, Color> colours;
  final Set<String> stale;
  final String? organizerName;
  final bool dark, overlap;
  _RadarPainter(this.e, this.regions, this.names, this.colours, this.stale, this.organizerName, this.dark, this.overlap);

  @override
  void paint(Canvas c, Size size) {
    final lay = e.layout;
    final xs = [...lay.slots.map((p) => p.$1), lay.camera.$1], ys = [...lay.slots.map((p) => p.$2), lay.camera.$2];
    final minX = xs.reduce(math.min) - 0.6, maxX = xs.reduce(math.max) + 0.6;
    final minY = ys.reduce(math.min) - 0.5, maxY = ys.reduce(math.max) + 0.5;
    final k = math.min(size.width / (maxX - minX), size.height / (maxY - minY));
    final ox = (size.width - (maxX - minX) * k) / 2, oy = (size.height - (maxY - minY) * k) / 2;
    Offset at(Pt p) => Offset(ox + (p.$1 - minX) * k, oy + (maxY - p.$2) * k);
    final textColour = dark ? Colors.white : Colors.black87;

    // Table.
    final path = Path()..addPolygon([for (final p in lay.outline) at(p)], true);
    c.drawPath(path, Paint()..color = const Color(0xFF1E5C3A));
    c.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF7A5A0E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2, k * 0.05));

    // Camera.
    final cam = at(lay.camera);
    final camR = k * 0.09;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: cam, width: camR * 2.4, height: camR * 1.7), Radius.circular(camR * 0.3)),
        Paint()..color = dark ? Colors.white70 : Colors.black87);
    c.drawCircle(cam, camR * 0.45, Paint()..color = dark ? Colors.black : Colors.white);

    // The point at band position x (cells) pushed [off] metres out from
    // the chair line.
    Pt band(double x, double off) {
      final s = x / bandCells * lay.perimeter;
      final p = lay.chairAt(s);
      final a = lay.chairAt(s - 0.02), b = lay.chairAt(s + 0.02);
      var nx = b.$2 - a.$2, ny = -(b.$1 - a.$1);
      final len = math.sqrt(nx * nx + ny * ny);
      if (len == 0) return p;
      nx /= len;
      ny /= len;
      if (nx * p.$1 + ny * p.$2 < 0) {
        nx = -nx;
        ny = -ny;
      }
      return (p.$1 + nx * off, p.$2 + ny * off);
    }

    // The empty band, grey: nobody's phone there.
    final grey = Path();
    for (var i = 0; i <= 144; i++) {
      final o = at(band(i * bandCells / 144, (_bandOut - _bandIn) / 2));
      i == 0 ? grey.moveTo(o.dx, o.dy) : grey.lineTo(o.dx, o.dy);
    }
    c.drawPath(
        grey,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (_bandIn + _bandOut) * k
          ..color = (dark ? Colors.white : Colors.black).withOpacity(0.07));

    // Seat numbers, small and faint, just inside the table edge.
    for (var s = 0; s < lay.slots.length; s++) {
      final o = at(band(slotCell(lay, s), -chairOffsetM - 0.13));
      c.drawCircle(o, k * 0.075, Paint()..color = Colors.white.withOpacity(0.16));
      _text(c, '${s + 1}', o, math.max(8, k * 0.085), Colors.white.withOpacity(0.7), bold: true);
    }

    // The shapes, widest (least sure) first so sure ones sit on top.
    final sorted = [...regions]..sort((a, b) => b.len.compareTo(a.len));
    final labels = <(SeatRegion, String, double, Color)>[];
    for (final r in sorted) {
      final org = r.id == organizerRegionId;
      final col = org ? (dark ? Colors.white : const Color(0xFF555555)) : (colours[r.id] ?? Colors.grey);
      final faded = stale.contains(r.id);
      final gap = overlap ? 0.0 : math.min(_seam, r.len / 4);
      final a = r.start + gap, len = math.max(0.05, r.len - 2 * gap);
      final steps = math.max(2, (len * 4).ceil());
      final outer = [for (var i = 0; i <= steps; i++) at(band(a + len * i / steps, _bandOut))];
      final inner = [for (var i = steps; i >= 0; i--) at(band(a + len * i / steps, -_bandIn))];
      final shape = _rounded([...outer, ...inner], k * 0.09);
      final conf = r.conf.clamp(0.0, 1.0);
      final alpha = (overlap ? 0.22 + 0.4 * conf : 0.35 + 0.6 * conf) * (faded ? 0.45 : 1.0);
      c.drawPath(shape, Paint()..color = col.withOpacity(alpha));
      c.drawPath(
          shape,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = overlap ? 2 : 1
            ..color = overlap ? col.withOpacity(faded ? 0.5 : 0.95) : (dark ? Colors.black54 : Colors.white70));
      final name = org
          ? (organizerName ?? 'organizer')
          : '${names[r.id] ?? r.id.substring(0, math.min(4, r.id.length))}${faded ? ' (left?)' : ''}';
      labels.add((r, name, len / bandCells * lay.perimeter * k, alpha > 0.6 ? _ink(col) : textColour));
    }
    // Names inside their shape (Puzzle, when it fits), else just outside.
    final fs = math.max(10.0, k * 0.11);
    for (final (r, name, arcPx, ink) in labels) {
      final tp = _painter(name, fs, ink);
      if (!overlap && tp.width <= arcPx * 0.95) {
        tp.paint(c, at(band(r.mid, (_bandOut - _bandIn) / 2)) - Offset(tp.width / 2, tp.height / 2));
      } else {
        _text(c, name, at(band(r.mid, _bandOut + 0.2)), fs, textColour);
      }
    }
  }

  /// Black or white, whichever reads on [bg].
  static Color _ink(Color bg) => bg.computeLuminance() > 0.35 ? Colors.black : Colors.white;

  /// A closed polygon with its corners rounded (radius up to [r], at most
  /// half of each edge, so the dense arc edges stay smooth curves).
  static Path _rounded(List<Offset> pts, double r) {
    final p = Path();
    final n = pts.length;
    for (var i = 0; i < n; i++) {
      final v = pts[i], prev = pts[(i - 1 + n) % n], next = pts[(i + 1) % n];
      Offset cut(Offset to) {
        final d = to - v;
        final len = d.distance;
        if (len == 0) return v;
        return v + d * (math.min(r, len / 2) / len);
      }

      final a = cut(prev), b = cut(next);
      if (i == 0) {
        p.moveTo(a.dx, a.dy);
      } else {
        p.lineTo(a.dx, a.dy);
      }
      p.quadraticBezierTo(v.dx, v.dy, b.dx, b.dy);
    }
    return p..close();
  }

  static TextPainter _painter(String s, double size, Color col, {bool bold = false}) => TextPainter(
        text: TextSpan(
            text: s, style: TextStyle(color: col, fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w600)),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size * 10);

  void _text(Canvas c, String s, Offset centre, double size, Color col, {bool bold = false}) {
    final tp = _painter(s, size, col, bold: bold);
    tp.paint(c, centre - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_RadarPainter old) => true;
}

/// One line per phone: colour, name, the seat its shape implies and how
/// sure ("seat 8 · 64%"), "left?".
class RadarLegend extends StatelessWidget {
  final RadarEstimate estimate;

  /// The shapes drawn (their seats); null: each phone's likeliest seat.
  final List<SeatRegion>? regions;
  final Map<String, String> names;
  final Map<String, Color> colours;
  final Set<String> stale;
  final ValueChanged<String>? onTap;
  final bool dark;
  const RadarLegend(
      {super.key,
      required this.estimate,
      required this.names,
      required this.colours,
      this.regions,
      this.stale = const {},
      this.onTap,
      this.dark = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final col = dark ? Colors.white : null;
    final phones = estimate.probs.keys.toList()..sort((a, b) => (names[a] ?? a).compareTo(names[b] ?? b));
    final byId = {for (final r in regions ?? const <SeatRegion>[]) r.id: r};
    (int, double) seatOf(String p) {
      final r = byId[p];
      if (r != null && r.seat != null) return (r.seat!, r.conf);
      final b = estimate.bestSlot(p) ?? 0;
      return (b, estimate.probs[p]![b]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final p in phones)
        InkWell(
          key: Key('radar-phone-$p'),
          onTap: onTap == null ? null : () => onTap!(p),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(color: colours[p], shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${names[p] ?? p}${stale.contains(p) ? '  · left?' : ''}',
                    style: t.bodyMedium?.copyWith(color: col)),
              ),
              Text('seat ${seatOf(p).$1 + 1} · ${(seatOf(p).$2 * 100).round()}%',
                  style: t.bodySmall?.copyWith(color: col)),
            ]),
          ),
        ),
    ]);
  }
}
