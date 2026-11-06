import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../homegame/home_game.dart';
import '../theme.dart';

/// Distance or speed that turns a drag on the pad into a swipe.
const _swipeDistance = 40.0;
const _swipeSpeed = 300.0;

/// Swipes up within this of each other add up to one raise size.
const raiseSizeWindow = Duration(milliseconds: 1200);

/// A raise size in half pots, short: "½ pot", "pot", "1½ pot", "2 pots".
String raiseSizeLabel(int halves) => switch (halves) {
      1 => '½ pot',
      2 => 'pot',
      _ => halves.isEven ? '${halves ~/ 2} pots' : '${halves ~/ 2}½ pot',
    };

/// The same, spoken: "raise half", "raise pot", "raise one and a half".
String spokenRaiseSize(int halves) {
  const words = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten'];
  final whole = halves ~/ 2;
  final w = whole < words.length ? words[whole] : '$whole';
  return switch (halves) {
    1 => 'raise half',
    2 => 'raise pot',
    _ => halves.isEven ? 'raise $w pots' : 'raise $w and a half',
  };
}

/// Big no-look input for the hand being played: tap = call / limp, swipe
/// up = raise (each swipe up within [raiseSizeWindow] adds half a pot:
/// twice = pot, three times = 1.5 pot), swipe down = fold, long press =
/// reset (nothing marked),
/// swipe sideways = next hand (when [onNext] is set). Each gesture buzzes
/// differently so you never have to look. Doing nothing is a fold (on Watch
/// my cards, [untappedUnknown]: "not recorded").
class ActionPad extends StatefulWidget {
  final PreAction? pending;
  final bool skipped;
  final ValueChanged<PreAction?> onAction;
  final VoidCallback? onNext;

  /// The raise size in half pots, once the swipes up stop for
  /// [raiseSizeWindow] (after [onAction] gave the raise).
  final ValueChanged<int>? onRaiseSize;

  /// The pending raise's size in half pots, to show (null: none given).
  final int? raiseHalves;

  /// Dark and dim (Watch my cards' black screen, propped facing the
  /// table): black fill, grey text, no action colours.
  final bool lowLight;
  final double height;

  /// Watch my cards: doing nothing records "not recorded" (unknown), not a
  /// fold.
  final bool untappedUnknown;
  const ActionPad({
    super.key,
    required this.pending,
    required this.onAction,
    this.skipped = false,
    this.onNext,
    this.onRaiseSize,
    this.raiseHalves,
    this.lowLight = false,
    this.height = 150,
    this.untappedUnknown = false,
  });

  @override
  State<ActionPad> createState() => _ActionPadState();
}

class _ActionPadState extends State<ActionPad> {
  double _dx = 0, _dy = 0;

  /// Swipes up so far in the raise being sized; [_sizing] runs until the
  /// size is committed.
  int _halves = 0;
  Timer? _sizing;

  @override
  void dispose() {
    _sizing?.cancel();
    super.dispose();
  }

  void _stopSizing() {
    _sizing?.cancel();
    _sizing = null;
  }

  void _call() {
    _stopSizing();
    HapticFeedback.lightImpact();
    widget.onAction(PreAction.call);
  }

  void _raise() {
    HapticFeedback.heavyImpact();
    if (_sizing == null) {
      _halves = 1;
      widget.onAction(PreAction.raise);
    } else {
      _halves++;
    }
    _sizing?.cancel();
    _sizing = Timer(raiseSizeWindow, () {
      _sizing = null;
      widget.onRaiseSize?.call(_halves);
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  void _fold() {
    _stopSizing();
    HapticFeedback.mediumImpact();
    widget.onAction(PreAction.fold);
  }

  void _undo() {
    _stopSizing();
    HapticFeedback.selectionClick();
    widget.onAction(null);
  }

  void _next() {
    // A raise still being sized goes with the hand it was swiped on.
    if (_sizing != null) {
      _stopSizing();
      widget.onRaiseSize?.call(_halves);
    }
    HapticFeedback.mediumImpact();
    widget.onNext!();
  }

  bool _swiped(double d, double? v) =>
      d.abs() >= _swipeDistance || (v ?? 0).abs() >= _swipeSpeed;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final a = widget.pending;
    final unk = widget.untappedUnknown;
    final halves = _sizing != null ? _halves : widget.raiseHalves;
    final size = a == PreAction.raise && halves != null ? ' ${raiseSizeLabel(halves)}' : '';
    final label = widget.skipped
        ? 'Not seen'
        : a == null
            ? (unk ? 'Not recorded' : 'Fold')
            : '${preActionLabels[a]!}$size';
    final sub = widget.skipped
        ? 'saved as unknown'
        : a == null
            ? (unk ? 'no tap = not recorded' : 'default: do nothing')
            : _sizing != null
                ? 'up again = +½ pot'
                : 'hold to reset';
    final low = widget.lowLight;
    final bg = low
        ? Colors.black
        : a == null
            ? Felt.feltCard
            : Felt.actionColor(preActionLabels[a]!, b);
    final hint = TextStyle(color: low ? const Color(0x55FFFFFF) : Colors.white70, fontSize: 13);
    return Semantics(
      container: true,
      button: true,
      label: 'Action pad: $label. Tap for call, swipe up for raise (again for half a pot more), '
          'swipe down for fold, hold to reset${widget.onNext == null ? '' : ', swipe sideways for next hand'}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _call,
        onLongPress: _undo,
        onVerticalDragStart: (_) => _dy = 0,
        onVerticalDragUpdate: (d) => _dy += d.delta.dy,
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity;
          if (!_swiped(_dy, v)) return;
          (_dy + (v ?? 0) * 0.1) < 0 ? _raise() : _fold();
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
          height: widget.height,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
                color: low ? const Color(0x22FFFFFF) : Felt.gold.withOpacity(0.6), width: 1.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(children: [
            // Scales down as a whole so large system text never spills
            // onto the hint line below.
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(label.toUpperCase(),
                      maxLines: 1,
                      style: TextStyle(
                          color: low ? const Color(0x66FFFFFF) : Colors.white,
                          fontSize: 40,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5)),
                  Text(sub, style: hint),
                ]),
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                  unk || widget.onNext == null
                      ? 'tap = call · up = raise +½ pot · down = fold · hold = reset'
                      : 'tap = call · up = raise +½ pot · down = fold · hold = reset · sideways = next',
                  maxLines: 1,
                  style: hint),
            ),
          ]),
        ),
      ),
    );
  }
}
