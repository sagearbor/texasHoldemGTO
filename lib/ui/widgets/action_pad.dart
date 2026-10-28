import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../homegame/home_game.dart';
import '../theme.dart';

/// Distance or speed that turns a drag on the pad into a swipe.
const _swipeDistance = 40.0;
const _swipeSpeed = 300.0;

/// Big no-look input for the hand being played: tap = call / limp, swipe
/// up = raise, swipe down = undo (back to the default fold), swipe sideways
/// = next hand (when [onNext] is set). Each gesture buzzes differently so
/// you never have to look. Doing nothing is a fold.
class ActionPad extends StatefulWidget {
  final PreAction? pending;
  final bool skipped;
  final ValueChanged<PreAction?> onAction;
  final VoidCallback? onNext;
  const ActionPad({
    super.key,
    required this.pending,
    required this.onAction,
    this.skipped = false,
    this.onNext,
  });

  @override
  State<ActionPad> createState() => _ActionPadState();
}

class _ActionPadState extends State<ActionPad> {
  double _dx = 0, _dy = 0;

  void _call() {
    HapticFeedback.lightImpact();
    widget.onAction(PreAction.call);
  }

  void _raise() {
    HapticFeedback.heavyImpact();
    widget.onAction(PreAction.raise);
  }

  void _undo() {
    HapticFeedback.selectionClick();
    widget.onAction(null);
  }

  void _next() {
    HapticFeedback.mediumImpact();
    widget.onNext!();
  }

  bool _swiped(double d, double? v) =>
      d.abs() >= _swipeDistance || (v ?? 0).abs() >= _swipeSpeed;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final a = widget.pending;
    final label = widget.skipped
        ? 'Not seen'
        : a == null
            ? 'Fold'
            : preActionLabels[a]!;
    final sub = widget.skipped
        ? 'saved as unknown'
        : a == null
            ? 'default: do nothing'
            : 'swipe down to undo';
    final bg = a == null
        ? Felt.feltCard
        : Felt.actionColor(preActionLabels[a]!, b);
    const hint = TextStyle(color: Colors.white70, fontSize: 13);
    return Semantics(
      container: true,
      button: true,
      label: 'Action pad: $label. Tap for call, swipe up for raise, '
          'swipe down to undo${widget.onNext == null ? '' : ', swipe sideways for next hand'}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _call,
        onVerticalDragStart: (_) => _dy = 0,
        onVerticalDragUpdate: (d) => _dy += d.delta.dy,
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity;
          if (!_swiped(_dy, v)) return;
          (_dy + (v ?? 0) * 0.1) < 0 ? _raise() : _undo();
        },
        onHorizontalDragStart: widget.onNext == null ? null : (_) => _dx = 0,
        onHorizontalDragUpdate:
            widget.onNext == null ? null : (d) => _dx += d.delta.dx,
        onHorizontalDragEnd: widget.onNext == null
            ? null
            : (d) {
                if (_swiped(_dx, d.primaryVelocity)) _next();
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 150,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Felt.gold.withOpacity(0.6), width: 1.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(children: [
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label.toUpperCase(),
                      maxLines: 1,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 40,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5)),
                ),
                Text(sub, style: hint),
              ]),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                  widget.onNext == null
                      ? 'tap = call · swipe up = raise · swipe down = undo'
                      : 'tap = call · up = raise · down = undo · sideways = next hand',
                  maxLines: 1,
                  style: hint),
            ),
          ]),
        ),
      ),
    );
  }
}
