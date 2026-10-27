import 'package:flutter/material.dart';

import '../../gto/spots.dart';
import '../../homegame/home_game.dart';
import '../../homegame/recap.dart';
import '../theme.dart';

/// Compact dealer-luck tile for the TV dashboard. Pass only the hands the
/// dashboard is allowed to show (its delay cutoff), never the live tail.
/// Renders nothing until some dealer has enough hands to rank.
class DealerLuckTile extends StatelessWidget {
  final Iterable<LoggedHand> hands;
  final SpotLibrary library;
  const DealerLuckTile({super.key, required this.hands, required this.library});

  @override
  Widget build(BuildContext context) {
    final d = dealerLuck(hands, library);
    if (d.ranked.isEmpty) return const SizedBox.shrink();
    final golden = d.goldenArm, doom = d.dealerOfDoom;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Felt.feltCard, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('DEALER LUCK',
            style: TextStyle(color: Felt.gold, fontSize: 12, letterSpacing: 1.2)),
        const SizedBox(height: 6),
        if (golden != null) _line('Golden Arm', golden),
        if (doom != null) _line('Dealer of Doom', doom),
        if (golden == null)
          for (final r in d.ranked) _line('', r),
        const Text('card luck vs a random hand · ${RecapGates.dealerMinHands}+ hands to rank',
            style: TextStyle(color: Colors.white60, fontSize: 12)),
      ]),
    );
  }

  Widget _line(String title, DealerLuckRow r) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          if (title.isNotEmpty)
            SizedBox(
                width: 130,
                child: Text(title, style: const TextStyle(color: Colors.white70, fontSize: 15))),
          Expanded(
            child: Text(r.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
          ),
          Text('${luckLabel(r.avgEquity)} · ${r.hands}h',
              style: TextStyle(
                  color: r.avgEquity >= 0.5 ? Felt.good : Felt.bad,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
        ]),
      );
}
