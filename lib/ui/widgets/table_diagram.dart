import 'dart:math';

import 'package:flutter/material.dart';

import '../../gto/spots.dart';
import '../screens/glossary_screen.dart';
import '../theme.dart';

/// Small oval table showing the hero's seat (gold), the villain (red) and
/// the dealer button. 6-max seats, 3 for 3-handed or 2 for heads-up spots.
class TableDiagram extends StatelessWidget {
  final String hero;
  final String? villain;

  /// Further aggressor seats for grouped spots ("HJ, CO or BTN 3-bets").
  final List<String> otherVillains;
  final bool headsUp;
  final bool threeHanded;
  const TableDiagram(
      {super.key,
      required this.hero,
      this.villain,
      this.otherVillains = const [],
      this.headsUp = false,
      this.threeHanded = false});

  @override
  Widget build(BuildContext context) {
    final seats = headsUp
        ? const ['SB', 'BB']
        : threeHanded
            ? const ['BTN', 'SB', 'BB']
            : positions6max;
    return AspectRatio(
      aspectRatio: 2.1,
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth, h = c.maxHeight;
        // Hero always sits at the bottom centre.
        final heroIdx = seats.indexOf(hero);
        return Stack(children: [
          Positioned(
            left: w * 0.12,
            right: w * 0.12,
            top: h * 0.16,
            bottom: h * 0.16,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E5C3A),
                borderRadius: BorderRadius.circular(h),
                border: Border.all(color: const Color(0xFF6B4A2B), width: 5),
              ),
            ),
          ),
          for (var i = 0; i < seats.length; i++)
            () {
              final rel = (i - heroIdx) % seats.length;
              final ang = pi / 2 + rel * 2 * pi / seats.length;
              final x = w / 2 + cos(ang) * w * 0.40;
              final y = h / 2 + sin(ang) * h * 0.40;
              final s = seats[i];
              final isHero = s == hero, isVillain =
                  s == villain || otherVillains.contains(s);
              return Positioned(
                left: x - 24,
                top: y - 14,
                // Tap a seat for what UTG / CO / ... means.
                child: GlossaryLink(
                  term: s,
                  child: Container(
                  width: 48,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isHero
                        ? Felt.gold
                        : isVillain
                            ? Felt.aggressive
                            : const Color(0xFF2B3A31),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.black26),
                  ),
                  child: Text(s,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isHero ? Colors.black : Colors.white)),
                  ),
                ),
              );
            }(),
        ]);
      }),
    );
  }
}
