import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../gto/spots.dart';
import '../widgets/range_grid.dart';
import 'help_screen.dart';
import 'review_sheet.dart';
import 'river_screen.dart';

class ChartsScreen extends StatefulWidget {
  final SpotLibrary library;
  final void Function(String spotId) onDrill;
  const ChartsScreen({super.key, required this.library, required this.onDrill});

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends State<ChartsScreen> {
  SpotFormat format = SpotFormat.cash100;
  late String cashId = widget.library.cash.first.id;
  int stack = 10;
  bool bbSide = false;

  Spot get spot => format == SpotFormat.cash100
      ? widget.library.byId(cashId)
      : widget.library.byId('pf-${bbSide ? 'bb' : 'sb'}-$stack');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = spot;
    final groups = <String, List<Spot>>{};
    for (final c in widget.library.cash) {
      (groups[c.group] ??= []).add(c);
    }
    return Scaffold(
      appBar: AppBar(
          title: const Text('Charts'),
          actions: const [HelpButton(HelpTopic.charts)]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          SegmentedButton<SpotFormat>(
            segments: const [
              ButtonSegment(value: SpotFormat.cash100, label: Text('6-max 100bb')),
              ButtonSegment(value: SpotFormat.pushFold, label: Text('Push/fold HU')),
            ],
            selected: {format},
            onSelectionChanged: (v) => setState(() => format = v.first),
          ),
          const SizedBox(height: 12),
          if (format == SpotFormat.cash100)
            for (final g in groups.entries) ...[
              Text(g.key, style: t.labelLarge),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in g.value)
                  ChoiceChip(
                    label: Text(c.title.replaceAll(' open', '').replaceAll('vs ', 'v ')),
                    selected: c.id == cashId,
                    onSelected: (_) => setState(() => cashId = c.id),
                  ),
              ]),
              const SizedBox(height: 10),
            ]
          else ...[
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('SB: jam?')),
                ButtonSegment(value: true, label: Text('BB: call jam?')),
              ],
              selected: {bbSide},
              onSelectionChanged: (v) => setState(() => bbSide = v.first),
            ),
            Row(children: [
              Text('${stack}bb', style: t.titleMedium),
              Expanded(
                child: Slider(
                  value: stack.toDouble(),
                  min: 3,
                  max: 25,
                  divisions: 22,
                  label: '${stack}bb',
                  onChanged: (v) => setState(() => stack = v.round()),
                ),
              ),
            ]),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.title, style: t.titleMedium),
                  Text(s.situation, style: t.bodySmall),
                  const SizedBox(height: 10),
                  RangeGrid(
                    spot: s,
                    onTap: (h) => showCoachSheet(context, s, h,
                        onDrill: () => widget.onDrill(s.id)),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: ActionLegend(spot: s)),
                    Text('Plays ${pct(s.playPercent)}', style: t.labelLarge),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    s.solved
                        ? 'Nash equilibrium, solved by Felt Notes (Monte Carlo equities, exact card removal).'
                        : 'Approximate GTO baseline. Tap any hand for coaching.',
                    style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () => widget.onDrill(s.id),
            icon: const Icon(Icons.fitness_center),
            label: Text('Drill ${s.title}'),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.water),
              title: const Text('River spots (solved)'),
              subtitle: const Text('BB vs BTN river strategies + drill'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RiverScreen())),
            ),
          ),
        ],
      ),
    );
  }
}
