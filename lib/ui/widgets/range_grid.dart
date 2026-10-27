import 'package:flutter/material.dart';

import '../../gto/hand_class.dart';
import '../../gto/spots.dart';
import '../theme.dart';

/// 13×13 strategy grid. Each cell is filled left-to-right with one band per
/// action, sized by frequency.
class RangeGrid extends StatelessWidget {
  final Spot spot;
  final int? highlight;
  final ValueChanged<HandClass>? onTap;
  const RangeGrid({super.key, required this.spot, this.highlight, this.onTap});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final colors = [for (final a in spot.actions) Felt.actionColor(a, b)];
    return _Grid(
      highlight: highlight,
      onTap: onTap,
      cell: (h) {
        final f = spot.freqs(h);
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < f.length; i++)
            if (f[i] > 0.001)
              Expanded(
                  flex: (f[i] * 1000).round(),
                  child: ColoredBox(color: colors[i])),
        ]);
      },
      textColor: (h) {
        final fold = spot.actions.indexOf('Fold');
        final folded = spot.freqs(h)[fold] > 0.5;
        if (!folded) return Colors.white;
        return b == Brightness.dark ? Colors.white60 : Colors.black54;
      },
    );
  }
}

/// 13×13 heatmap: [value] returns 0..1 (null = no data).
class HeatGrid extends StatelessWidget {
  final double? Function(HandClass) value;
  final ValueChanged<HandClass>? onTap;
  const HeatGrid({super.key, required this.value, this.onTap});

  static Color heat(double v) {
    // 0 = red (bad) .. 0.5 = gold .. 1 = green (good).
    if (v < 0.5) return Color.lerp(Felt.bad, Felt.mixed, v * 2)!;
    return Color.lerp(Felt.mixed, Felt.good, (v - 0.5) * 2)!;
  }

  @override
  Widget build(BuildContext context) {
    final empty = Theme.of(context).colorScheme.surfaceContainerHighest;
    return _Grid(
      onTap: onTap,
      cell: (h) {
        final v = value(h);
        return ColoredBox(color: v == null ? empty : heat(v));
      },
      textColor: (h) => value(h) == null
          ? Theme.of(context).colorScheme.onSurfaceVariant
          : Colors.white,
    );
  }
}

class _Grid extends StatelessWidget {
  final Widget Function(HandClass) cell;
  final Color Function(HandClass) textColor;
  final int? highlight;
  final ValueChanged<HandClass>? onTap;
  const _Grid(
      {required this.cell, required this.textColor, this.highlight, this.onTap});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(builder: (context, c) {
        final size = c.maxWidth / 13;
        return Column(
          children: [
            for (var r = 0; r < 13; r++)
              Expanded(
                child: Row(
                  children: [
                    for (var col = 0; col < 13; col++)
                      Expanded(child: _cell(HandClass(r, col), size)),
                  ],
                ),
              ),
          ],
        );
      }),
    );
  }

  Widget _cell(HandClass h, double size) {
    final hl = highlight == h.index;
    return GestureDetector(
      onTap: onTap == null ? null : () => onTap!(h),
      child: Container(
        margin: const EdgeInsets.all(0.5),
        decoration: hl
            ? BoxDecoration(border: Border.all(color: Felt.gold, width: 2.5))
            : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(2), child: cell(h)),
            Center(
              child: Text(
                h.name,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: (size * 0.3).clamp(6, 14),
                  fontWeight: FontWeight.w600,
                  color: textColor(h),
                  shadows: const [Shadow(blurRadius: 2, color: Colors.black26)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ActionLegend extends StatelessWidget {
  final Spot spot;
  const ActionLegend({super.key, required this.spot});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final a in spot.actions)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                    color: Felt.actionColor(a, b),
                    borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 5),
            Text(a, style: Theme.of(context).textTheme.bodySmall),
          ]),
      ],
    );
  }
}
