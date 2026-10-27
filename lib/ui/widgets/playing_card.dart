import 'package:flutter/material.dart';

import '../../poker/cards.dart';

/// A face-up card, or a placeholder slot when [card] is null.
class PlayingCard extends StatelessWidget {
  final int? card;
  final double width;
  final VoidCallback? onTap;
  const PlayingCard({super.key, this.card, this.width = 64, this.onTap});

  static const _suitColors = [
    Color(0xFF1F7A3F), // clubs: green (four-colour deck)
    Color(0xFF2563EB), // diamonds: blue
    Color(0xFFD62839), // hearts: red
    Color(0xFF1B1B1B), // spades: black
  ];

  @override
  Widget build(BuildContext context) {
    final h = width * 1.4;
    final c = card;
    final child = c == null
        ? Container(
            width: width,
            height: h,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(width * 0.12),
              border: Border.all(
                  color: Theme.of(context).colorScheme.outline, width: 1.5),
            ),
            child: Icon(Icons.add,
                color: Theme.of(context).colorScheme.outline, size: width * 0.4),
          )
        : Container(
            width: width,
            height: h,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(width * 0.12),
              boxShadow: const [
                BoxShadow(blurRadius: 4, offset: Offset(0, 2), color: Colors.black38)
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(rankChars[cardRank(c)] == 'T' ? '10' : rankChars[cardRank(c)],
                    style: TextStyle(
                        fontSize: width * 0.42,
                        fontWeight: FontWeight.w800,
                        height: 1,
                        color: _suitColors[cardSuit(c)])),
                Text(suitSymbols[cardSuit(c)],
                    style: TextStyle(
                        fontSize: width * 0.38,
                        height: 1.1,
                        color: _suitColors[cardSuit(c)])),
              ],
            ),
          );
    if (onTap == null) return child;
    // Tappable slot: expose it as a button so screen readers can use it.
    return Semantics(
      container: true,
      button: true,
      label: c == null ? 'Choose a card' : null,
      child: GestureDetector(onTap: onTap, child: child),
    );
  }
}

/// Bottom sheet letting the user pick one card; [used] cards are disabled.
Future<int?> pickCard(BuildContext context, Set<int> used) {
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var s = 3; s >= 0; s--)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    for (var r = 12; r >= 0; r--)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(1.5),
                          child: _PickCell(
                            card: makeCard(r, s),
                            enabled: !used.contains(makeCard(r, s)),
                            onTap: () => Navigator.pop(ctx, makeCard(r, s)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _PickCell extends StatelessWidget {
  final int card;
  final bool enabled;
  final VoidCallback onTap;
  const _PickCell({required this.card, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = PlayingCard._suitColors[cardSuit(card)];
    return Opacity(
      opacity: enabled ? 1 : 0.2,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(4)),
          alignment: Alignment.center,
          child: Text('${rankChars[cardRank(card)]}${suitSymbols[cardSuit(card)]}',
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w700, fontSize: 12)),
        ),
      ),
    );
  }
}
