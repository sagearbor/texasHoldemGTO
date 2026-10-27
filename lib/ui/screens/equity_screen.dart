import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../gto/range_parser.dart';
import '../../gto/spots.dart';
import '../../poker/equity.dart';
import '../../poker/evaluator.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';
import 'help_screen.dart';

class EquityScreen extends StatefulWidget {
  final SpotLibrary library;
  const EquityScreen({super.key, required this.library});

  @override
  State<EquityScreen> createState() => _EquityScreenState();
}

class _EquityScreenState extends State<EquityScreen> {
  /// players[i] = two nullable cards. Player 0 is you.
  final players = <List<int?>>[
    [null, null],
    [null, null],
  ];
  final board = List<int?>.filled(5, null);
  bool vsRange = false;
  String rangeSpotId = 'cash-rfi-BTN';
  List<double>? result;
  double? rangeResult;
  bool busy = false;

  Set<int> get used => {
        for (final p in players) ...p.whereType<int>(),
        ...board.whereType<int>(),
      };

  Future<void> _pick(List<int?> slots, int i) async {
    final c = await pickCard(context, used..remove(slots[i]));
    if (c != null) {
      setState(() {
        slots[i] = c;
        result = null;
        rangeResult = null;
      });
    }
  }

  RangeMap _rangeOf(Spot s) {
    final fold = s.passiveIndex;
    final reach = s.reach;
    return {
      for (var i = 0; i < 169; i++)
        if (s.strategy[i][fold] < 1 && (reach == null || reach[i] > 0))
          i: (1 - s.strategy[i][fold]) * (reach?[i] ?? 1)
    };
  }

  Future<void> _calc() async {
    setState(() => busy = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final b = board.whereType<int>().toList();
    if (vsRange) {
      final hero = players[0].whereType<int>().toList();
      final r = handVsRangeEquity(
          hero, _rangeOf(widget.library.byId(rangeSpotId)), b,
          samples: 8000);
      setState(() {
        rangeResult = r;
        busy = false;
      });
    } else {
      final hands = [
        for (final p in players)
          if (p.every((c) => c != null)) p.cast<int>()
      ];
      final r = handsEquity(hands, b, samples: 15000);
      setState(() {
        result = r.equity;
        busy = false;
      });
    }
  }

  bool get _ready {
    final boardCount = board.whereType<int>().length;
    if (boardCount > 0 && boardCount < 3) return false;
    if (players[0].contains(null)) return false;
    if (vsRange) return true;
    return players.where((p) => !p.contains(null)).length >= 2 &&
        players.every((p) => !p.contains(null) || p.every((c) => c == null));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final boardCards = board.whereType<int>().toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Equity'), actions: [
        const HelpButton(HelpTopic.equity),
        IconButton(
          tooltip: 'Clear',
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() {
            for (final p in players) {
              p.fillRange(0, 2, null);
            }
            board.fillRange(0, 5, null);
            result = null;
            rangeResult = null;
          }),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Hand vs hand')),
              ButtonSegment(value: true, label: Text('Hand vs range')),
            ],
            selected: {vsRange},
            onSelectionChanged: (v) => setState(() {
              vsRange = v.first;
              result = null;
              rangeResult = null;
            }),
          ),
          const SizedBox(height: 14),
          for (var p = 0; p < (vsRange ? 1 : players.length); p++)
            _PlayerRow(
              label: p == 0 ? 'You' : 'Player ${p + 1}',
              slots: players[p],
              onPick: (i) => _pick(players[p], i),
              equity: result != null && p < result!.length ? result![p] : null,
              onRemove: p >= 2
                  ? () => setState(() {
                        players.removeAt(p);
                        result = null;
                      })
                  : null,
            ),
          if (!vsRange && players.length < 6)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  players.add([null, null]);
                  result = null;
                }),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Add player'),
              ),
            ),
          if (vsRange) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: rangeSpotId,
              decoration: const InputDecoration(
                  labelText: 'Villain range', border: OutlineInputBorder()),
              items: [
                for (final s in widget.library.cash)
                  DropdownMenuItem(
                      value: s.id,
                      child: Text('${s.title}  (${pct(s.playPercent)})')),
              ],
              onChanged: (v) => setState(() {
                rangeSpotId = v!;
                rangeResult = null;
              }),
            ),
          ],
          const SizedBox(height: 16),
          Text('Board', style: t.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            for (var i = 0; i < 5; i++)
              PlayingCard(card: board[i], width: 52, onTap: () => _pick(board, i)),
          ]),
          if (boardCards.length >= 3 && !players[0].contains(null))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  'You have: ${describeHand([...players[0].cast<int>(), ...boardCards])}',
                  style: t.bodyMedium),
            ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _ready && !busy ? _calc : null,
            icon: busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.calculate),
            label: const Text('Calculate equity'),
          ),
          if (rangeResult != null) ...[
            const SizedBox(height: 16),
            _EquityBar(label: 'You', value: rangeResult!),
            _EquityBar(
                label: widget.library.byId(rangeSpotId).title, value: 1 - rangeResult!),
          ],
          const SizedBox(height: 12),
          Text('Tap a slot to choose a card. Board can be empty (preflop), 3, 4 or 5 cards.',
              style: t.bodySmall),
        ],
      ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  final String label;
  final List<int?> slots;
  final void Function(int) onPick;
  final double? equity;
  final VoidCallback? onRemove;
  const _PlayerRow(
      {required this.label,
      required this.slots,
      required this.onPick,
      this.equity,
      this.onRemove});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        SizedBox(width: 70, child: Text(label, style: t.labelLarge)),
        PlayingCard(card: slots[0], width: 44, onTap: () => onPick(0)),
        const SizedBox(width: 4),
        PlayingCard(card: slots[1], width: 44, onTap: () => onPick(1)),
        const SizedBox(width: 12),
        Expanded(
          child: equity == null
              ? const SizedBox()
              : _EquityBar(label: null, value: equity!),
        ),
        if (onRemove != null)
          IconButton(onPressed: onRemove, icon: const Icon(Icons.close, size: 18)),
      ]),
    );
  }
}

class _EquityBar extends StatelessWidget {
  final String? label;
  final double value;
  const _EquityBar({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (label != null) Text(label!, style: t.labelMedium),
        Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 14,
                color: Felt.gold,
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
              width: 52,
              child: Text('${(value * 100).toStringAsFixed(1)}%',
                  textAlign: TextAlign.right,
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
        ]),
      ]),
    );
  }
}
