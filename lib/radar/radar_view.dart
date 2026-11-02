/// Drawing the seat radar: the table, its fixed seat slots, the camera,
/// and each app player's colour filling the slots in proportion to how
/// likely they sit there (solid where most likely, tinted elsewhere: a
/// tight, single colour means confident). Slots nobody's phone claims stay
/// grey ("no app"). Shared by the organizer's Radar screen and the TV.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'radar_model.dart';

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

/// Below this a phone's share of a slot is not drawn.
const _minShare = 0.05;

class RadarView extends StatelessWidget {
  final RadarEstimate estimate;
  final Map<String, String> names;
  final Set<String> stale;
  final Map<String, Color> colours;

  /// Name for the organizer's own seat (no phone of theirs on it).
  final String? organizerName;
  final bool dark;
  const RadarView({
    super.key,
    required this.estimate,
    required this.names,
    required this.colours,
    this.stale = const {},
    this.organizerName,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    final lay = estimate.layout;
    final xs = [...lay.slots.map((p) => p.$1), lay.camera.$1], ys = [...lay.slots.map((p) => p.$2), lay.camera.$2];
    final w = xs.reduce(math.max) - xs.reduce(math.min) + 1.2, h = ys.reduce(math.max) - ys.reduce(math.min) + 1.0;
    return AspectRatio(
      aspectRatio: w / h,
      child: CustomPaint(
        painter: _RadarPainter(estimate, names, colours, stale, organizerName, dark),
        size: Size.infinite,
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final RadarEstimate e;
  final Map<String, String> names;
  final Map<String, Color> colours;
  final Set<String> stale;
  final String? organizerName;
  final bool dark;
  _RadarPainter(this.e, this.names, this.colours, this.stale, this.organizerName, this.dark);

  @override
  void paint(Canvas c, Size size) {
    final lay = e.layout;
    final xs = [...lay.slots.map((p) => p.$1), lay.camera.$1], ys = [...lay.slots.map((p) => p.$2), lay.camera.$2];
    final minX = xs.reduce(math.min) - 0.6, maxX = xs.reduce(math.max) + 0.6;
    final minY = ys.reduce(math.min) - 0.5, maxY = ys.reduce(math.max) + 0.5;
    final k = math.min(size.width / (maxX - minX), size.height / (maxY - minY));
    final ox = (size.width - (maxX - minX) * k) / 2, oy = (size.height - (maxY - minY) * k) / 2;
    Offset at(Pt p) => Offset(ox + (p.$1 - minX) * k, oy + (maxY - p.$2) * k);

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

    final textColour = dark ? Colors.white : Colors.black87;
    final r = k * 0.2;
    final best = {for (final p in e.probs.keys) p: e.bestSlot(p)};
    for (var s = 0; s < lay.slots.length; s++) {
      final o = at(lay.slots[s]);
      final rect = Rect.fromCircle(center: o, radius: r);
      // Grey first: whatever no phone claims.
      c.drawCircle(o, r, Paint()..color = dark ? const Color(0xFF3A3F3C) : const Color(0xFFCFD3D0));
      var start = -math.pi / 2;
      final shares = [
        for (final p in e.probs.entries)
          if (p.value[s] >= _minShare) (p.key, p.value[s])
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      for (final (phone, share) in shares) {
        final sweep = 2 * math.pi * share.clamp(0, 1);
        final col = colours[phone] ?? Colors.grey;
        final faded = stale.contains(phone);
        final alpha = (best[phone] == s ? 1.0 : 0.55) * (faded ? 0.4 : 1.0);
        c.drawArc(rect, start, sweep, true, Paint()..color = col.withOpacity(alpha));
        start += sweep;
      }
      c.drawCircle(
          o,
          r,
          Paint()
            ..color = dark ? Colors.white24 : Colors.black26
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      if (s == e.organizerSlot) {
        c.drawCircle(
            o,
            r * 1.12,
            Paint()
              ..color = textColour
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
      }
      _text(c, '${s + 1}', o, r * 0.7, dark ? Colors.white : Colors.black, bold: true);
    }

    // Names outside each phone's most likely slot.
    final labelsAt = <int, List<String>>{};
    for (final p in e.probs.keys) {
      final b = best[p];
      if (b == null) continue;
      (labelsAt[b] ??= []).add('${names[p] ?? p.substring(0, math.min(4, p.length))}${stale.contains(p) ? ' (left?)' : ''}');
    }
    if (e.organizerSlot != null && organizerName != null) {
      (labelsAt[e.organizerSlot!] ??= []).insert(0, organizerName!);
    }
    for (final entry in labelsAt.entries) {
      final p = lay.slots[entry.key];
      final len = math.sqrt(p.$1 * p.$1 + p.$2 * p.$2);
      final out = len == 0 ? p : (p.$1 * (len + 0.42) / len, p.$2 * (len + 0.42) / len);
      _text(c, entry.value.join('\n'), at(out), math.max(10, k * 0.13), textColour);
    }
  }

  void _text(Canvas c, String s, Offset centre, double size, Color col, {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(color: col, fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size * 10);
    tp.paint(c, centre - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_RadarPainter old) => true;
}

/// One line per phone: colour, name, how sure, "left?".
class RadarLegend extends StatelessWidget {
  final RadarEstimate estimate;
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
      this.stale = const {},
      this.onTap,
      this.dark = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final col = dark ? Colors.white : null;
    final phones = estimate.probs.keys.toList()..sort((a, b) => (names[a] ?? a).compareTo(names[b] ?? b));
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
              Text(
                  'seat ${(estimate.bestSlot(p) ?? 0) + 1} · '
                  '${((estimate.probs[p]![estimate.bestSlot(p) ?? 0]) * 100).round()}%',
                  style: t.bodySmall?.copyWith(color: col)),
            ]),
          ),
        ),
    ]);
  }
}
