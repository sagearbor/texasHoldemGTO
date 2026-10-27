import 'package:flutter/material.dart';

import '../../homegame/home_game.dart';
import '../../homegame/my_result.dart';
import '../theme.dart';

/// Optional buy-in / cash-out for one night, yours only. Returns true when
/// saved, false on Skip / dismiss.
Future<bool> editMyResult(BuildContext context, HomeGameModel model, HomeSession s,
    {String skipLabel = 'Cancel'}) async {
  String fmt(double? v) => v == null ? '' : moneyLabel(v).replaceFirst('\$', '');
  final buy = TextEditingController(text: fmt(s.buyIn));
  final cash = TextEditingController(text: fmt(s.cashOut));
  const kb = TextInputType.numberWithOptions(decimal: true);
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('My result'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(myResultNote, style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('Optional. Add re-buys to the buy-in.'),
          const SizedBox(height: 12),
          TextField(
            controller: buy,
            keyboardType: kb,
            decoration: const InputDecoration(labelText: 'Buy-in', prefixText: '\$ '),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: cash,
            keyboardType: kb,
            decoration: const InputDecoration(labelText: 'Cash-out', prefixText: '\$ '),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(skipLabel)),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save')),
      ],
    ),
  );
  if (ok != true) return false;
  model.setResult(s, buyIn: parseMoney(buy.text), cashOut: parseMoney(cash.text));
  return true;
}

/// Season profit / loss on the Crew screen. Renders a prompt when no night
/// has both numbers yet.
class MyResultSummary extends StatelessWidget {
  final List<HomeSession> sessions;
  const MyResultSummary({super.key, required this.sessions});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = seasonResult(sessions);
    Color tone(double v) => v > 0 ? Felt.good : (v < 0 ? Felt.bad : t.bodyMedium!.color!);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('My result', style: t.titleMedium)),
            if (r.nights.isNotEmpty)
              Text(moneyLabel(r.total, signed: true),
                  style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: tone(r.total))),
          ]),
          Text(myResultNote, style: t.bodySmall),
          const SizedBox(height: 6),
          if (r.nights.isEmpty)
            Text('Add your buy-in and cash-out from a night\'s menu or recap to see your season.',
                style: t.bodyMedium)
          else ...[
            Text('${r.winning} of ${r.nights.length} night${r.nights.length == 1 ? '' : 's'} in profit',
                style: t.bodyMedium),
            for (final (s, net) in r.nights.reversed.take(10))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  Expanded(child: Text(s.name, overflow: TextOverflow.ellipsis, style: t.bodyMedium)),
                  Text(moneyLabel(net, signed: true),
                      style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: tone(net))),
                ]),
              ),
          ],
        ]),
      ),
    );
  }
}
