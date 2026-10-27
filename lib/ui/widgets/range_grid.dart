import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../gto/hand_class.dart';
import '../../gto/spots.dart';
import '../chart_prefs.dart';
import '../theme.dart';

enum ActionKind { aggressive, call, fold }

ActionKind actionKind(String action) {
  final a = action.toLowerCase();
  if (a.startsWith('fold')) return ActionKind.fold;
  if (a.startsWith('call')) return ActionKind.call;
  return ActionKind.aggressive;
}

/// Okabe-Ito vermillion / blue: safe for red-green colour blindness.
const cbAggressive = Color(0xFFD55E00);
const cbCall = Color(0xFF0072B2);

/// Chart colour for an action. With [colorBlind] the raise / call pair is
/// swapped for a colour-blind-safe one; fold keeps the felt grey.
Color chartColor(String action, Brightness b, {bool colorBlind = false}) {
  if (!colorBlind) return Felt.actionColor(action, b);
  return switch (actionKind(action)) {
    ActionKind.aggressive => cbAggressive,
    ActionKind.call => cbCall,
    ActionKind.fold => Felt.actionColor(action, b),
  };
}

/// Screen-reader label for one cell, e.g. "AKs: raise 2.5bb 70%, fold 30%".
String cellSemantics(Spot spot, HandClass h) {
  final f = spot.freqs(h);
  final parts = [
    for (var i = 0; i < f.length; i++)
      if (f[i] > 0.001) '${spot.actions[i].toLowerCase()} ${pct(f[i])}',
  ];
  return '${h.name}: ${parts.join(', ')}';
}

/// Rebuilds [builder] when the colour-blind chart setting changes. A
/// non-null [forced] pins the mode.
class _ChartMode extends StatelessWidget {
  final bool? forced;
  final Widget Function(BuildContext context, bool colorBlind) builder;
  const _ChartMode({this.forced, required this.builder});

  @override
  Widget build(BuildContext context) {
    if (forced != null) return builder(context, forced!);
    return ValueListenableBuilder<bool>(
      valueListenable: ChartPrefs.colorBlind,
      builder: (context, cb, _) => builder(context, cb),
    );
  }
}

/// One frequency band: its colour, plus the action's pattern in
/// colour-blind mode (hatching = raise, dots = call, plain = fold).
class ActionBand extends StatelessWidget {
  final String action;
  final bool patterned;
  const ActionBand({super.key, required this.action, required this.patterned});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final box = ColoredBox(color: chartColor(action, b, colorBlind: patterned));
    final kind = actionKind(action);
    if (!patterned || kind == ActionKind.fold) return box;
    return CustomPaint(
        foregroundPainter: ActionPatternPainter(kind), child: box);
  }
}

/// Paints the colour-blind pattern for [kind] over a band.
class ActionPatternPainter extends CustomPainter {
  final ActionKind kind;
  const ActionPatternPainter(this.kind);

  static const _spacing = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.4)
      ..isAntiAlias = true;
    switch (kind) {
      case ActionKind.aggressive:
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3;
        // Diagonal hatching, bottom-left to top-right.
        for (var x = -size.height; x < size.width; x += _spacing) {
          canvas.drawLine(
              Offset(x, size.height), Offset(x + size.height, 0), paint);
        }
      case ActionKind.call:
        paint.style = PaintingStyle.fill;
        for (var y = _spacing / 2; y < size.height; y += _spacing) {
          final shift = ((y / _spacing).floor().isOdd) ? _spacing / 2 : 0.0;
          for (var x = _spacing / 2 + shift; x < size.width; x += _spacing) {
            canvas.drawCircle(Offset(x, y), 1.1, paint);
          }
        }
      case ActionKind.fold:
        break;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ActionPatternPainter oldDelegate) =>
      oldDelegate.kind != kind;
}

/// 13×13 strategy grid. Each cell is filled left-to-right with one band per
/// action, sized by frequency.
class RangeGrid extends StatelessWidget {
  final Spot spot;
  final int? highlight;
  final ValueChanged<HandClass>? onTap;

  /// Forces pattern mode on or off; null follows [ChartPrefs.colorBlind].
  final bool? patterns;
  const RangeGrid(
      {super.key,
      required this.spot,
      this.highlight,
      this.onTap,
      this.patterns});

  @override
  Widget build(BuildContext context) {
    return _ChartMode(
      forced: patterns,
      builder: (context, cb) {
        final b = Theme.of(context).brightness;
        return _Grid(
          highlight: highlight,
          onTap: onTap,
          semantics: (h) => cellSemantics(spot, h),
          cell: (h) {
            final f = spot.freqs(h);
            final row = Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < f.length; i++)
                    if (f[i] > 0.001)
                      Expanded(
                          flex: (f[i] * 1000).round(),
                          child: ActionBand(
                              action: spot.actions[i], patterned: cb)),
                ]);
            // Hands hero never holds here (not in the opening range) fade.
            return spot.reach?[h.index] == 0
                ? Opacity(opacity: 0.35, child: row)
                : row;
          },
          textColor: (h) {
            final fold = spot.passiveIndex;
            final folded = spot.freqs(h)[fold] > 0.5;
            if (!folded) return Colors.white;
            return b == Brightness.dark ? Colors.white60 : Colors.black54;
          },
        );
      },
    );
  }
}

/// Horizontal bar of one hand's action frequencies.
class ActionFreqBar extends StatelessWidget {
  final Spot spot;
  final HandClass hand;
  final double height;

  /// Forces pattern mode on or off; null follows [ChartPrefs.colorBlind].
  final bool? patterns;
  const ActionFreqBar(
      {super.key,
      required this.spot,
      required this.hand,
      this.height = 14,
      this.patterns});

  @override
  Widget build(BuildContext context) {
    final f = spot.freqs(hand);
    return _ChartMode(
      forced: patterns,
      builder: (context, cb) => Semantics(
        label: cellSemantics(spot, hand),
        excludeSemantics: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: height,
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < f.length; i++)
                if (f[i] > 0.001)
                  Expanded(
                      flex: (f[i] * 1000).round(),
                      child:
                          ActionBand(action: spot.actions[i], patterned: cb)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 13×13 heatmap: [value] returns 0..1 (null = no data).
class HeatGrid extends StatelessWidget {
  final double? Function(HandClass) value;
  final ValueChanged<HandClass>? onTap;

  /// Screen-reader label per cell; defaults to "AKs: 80%" / "AKs: no data".
  final String Function(HandClass)? semantics;
  const HeatGrid({super.key, required this.value, this.onTap, this.semantics});

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
      semantics: semantics ??
          (h) {
            final v = value(h);
            return '${h.name}: ${v == null ? 'no data' : pct(v)}';
          },
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
  final String Function(HandClass) semantics;
  final int? highlight;
  final ValueChanged<HandClass>? onTap;
  const _Grid(
      {required this.cell,
      required this.textColor,
      required this.semantics,
      this.highlight,
      this.onTap});

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
    return Semantics(
      label: semantics(h),
      button: onTap != null,
      selected: hl,
      excludeSemantics: true,
      child: GestureDetector(
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
                    shadows: const [
                      Shadow(blurRadius: 2, color: Colors.black54)
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// App-bar overflow menu with the chart display settings.
class ChartOptionsMenu extends StatelessWidget {
  const ChartOptionsMenu({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ChartPrefs.colorBlind,
      builder: (context, cb, _) => PopupMenuButton<String>(
        tooltip: 'Chart options',
        onSelected: (v) {
          if (v == 'cb') ChartPrefs.setColorBlind(!cb);
        },
        itemBuilder: (context) => [
          CheckedPopupMenuItem(
            value: 'cb',
            checked: cb,
            child: const Text('Colour-blind friendly charts'),
          ),
        ],
      ),
    );
  }
}

class ActionLegend extends StatelessWidget {
  final Spot spot;

  /// Forces pattern mode on or off; null follows [ChartPrefs.colorBlind].
  final bool? patterns;
  const ActionLegend({super.key, required this.spot, this.patterns});

  @override
  Widget build(BuildContext context) {
    return _ChartMode(
      forced: patterns,
      builder: (context, cb) => Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          for (final a in spot.actions)
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: cb ? 16 : 12,
                height: cb ? 16 : 12,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: ActionBand(action: a, patterned: cb),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                  cb
                      ? '$a (${switch (actionKind(a)) {
                          ActionKind.aggressive => 'stripes',
                          ActionKind.call => 'dots',
                          ActionKind.fold => 'plain',
                        }})'
                      : a,
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
        ],
      ),
    );
  }
}
