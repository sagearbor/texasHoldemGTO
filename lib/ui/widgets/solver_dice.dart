import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../gto/hand_class.dart';
import '../../gto/spots.dart';
import '../theme.dart';

/// Action bands on a 0..99 dial: (actionIndex, start, end) with end
/// exclusive, in action order, zero-width actions skipped. The last band
/// always ends at 100.
List<(int, int, int)> diceBands(List<double> freqs) {
  final out = <(int, int, int)>[];
  var cum = 0.0;
  var start = 0;
  for (var i = 0; i < freqs.length; i++) {
    cum += freqs[i];
    final end = i == freqs.length - 1 ? 100 : (cum * 100).round().clamp(0, 100);
    if (end > start) out.add((i, start, end));
    start = end > start ? end : start;
  }
  if (out.isNotEmpty && out.last.$3 != 100) {
    final (i, s, _) = out.removeLast();
    out.add((i, s, 100));
  }
  return out;
}

/// Action index that a roll of [roll] (0..99) lands on.
int actionForRoll(List<double> freqs, int roll) {
  for (final (i, _, end) in diceBands(freqs)) {
    if (roll < end) return i;
  }
  return diceBands(freqs).last.$1;
}

/// "The solver plays this hand both ways: Raise 60%, Fold 40%. Rolling 37 →
/// Raise. Either choice is fine; mixing keeps you unexploitable."
String diceText(Spot spot, HandClass hand, int roll) {
  final f = spot.freqs(hand);
  final bands = diceBands(f);
  final parts = [
    for (final (i, s, e) in bands) '${spot.actions[i]} ${e - s}%'
  ];
  final two = bands.length <= 2;
  // Hand-authored charts are not solver output: say so.
  final who = spot.handAuthored ? 'This approximate chart' : 'The solver';
  return '$who plays this hand ${two ? 'both ways' : 'several ways'}: '
      '${parts.join(', ')}. Rolling $roll → '
      '${spot.actions[actionForRoll(f, roll)]}. '
      '${two ? 'Either choice is fine' : 'Any of these is fine'}; '
      'mixing keeps you unexploitable.';
}

/// Small "solver dice" explainer for mixed hands: a 0–99 bar split into
/// action bands with a marker at the roll.
class SolverDice extends StatelessWidget {
  final Spot spot;
  final HandClass hand;
  final int roll;
  const SolverDice(
      {super.key, required this.spot, required this.hand, required this.roll});

  /// Shown only for mixed hands (no action at 90% or more).
  static bool applies(Spot spot, HandClass hand) => isMixedHand(spot, hand);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final b = Theme.of(context).brightness;
    final bands = diceBands(spot.freqs(hand));
    final marker = b == Brightness.dark ? Felt.cream : Colors.black87;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Felt.gold.withOpacity(0.6)),
        color: Felt.gold.withOpacity(0.08),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.casino_outlined, size: 18, color: Felt.accent(context)),
            const SizedBox(width: 6),
            Text('Solver dice', style: t.labelLarge),
            const Spacer(),
            Text('Roll $roll', style: t.labelLarge),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 30,
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              final x = w * (roll + 0.5) / 100;
              return Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(
                  top: 6,
                  bottom: 6,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, s, e) in bands)
                            Expanded(
                              flex: e - s,
                              child: ColoredBox(
                                color: Felt.actionColor(spot.actions[i], b),
                                child: Center(
                                  child: Text(
                                    e - s >= 18 ? spot.actions[i] : '',
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    // White on the light theme's pale fold
                                    // band was invisible.
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: ThemeData.estimateBrightnessForColor(
                                                    Felt.actionColor(spot.actions[i], b)) ==
                                                Brightness.dark
                                            ? Colors.white
                                            : Colors.black87,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                            ),
                        ]),
                  ),
                ),
                Positioned(
                  key: const ValueKey('dice-marker'),
                  left: (x - 1.5).clamp(0, w - 3),
                  top: 0,
                  bottom: 0,
                  width: 3,
                  child: ColoredBox(color: marker),
                ),
              ]);
            }),
          ),
          Row(children: [
            Text('0', style: t.bodySmall),
            const Spacer(),
            Text('99', style: t.bodySmall),
          ]),
          const SizedBox(height: 4),
          Text(diceText(spot, hand, roll), style: t.bodyMedium),
        ],
      ),
    );
  }
}
