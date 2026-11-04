import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../gto/spots.dart';
import '../../trainer/mistakes.dart';
import '../../trainer/trainer_model.dart';
import '../widgets/range_grid.dart';
import 'help_screen.dart';
import 'review_sheet.dart';
import 'river_screen.dart';

class ChartsScreen extends StatefulWidget {
  final SpotLibrary library;
  final void Function(String spotId) onDrill;

  /// Trainer history for the "My mistakes" view; without it only the
  /// strategy chart is shown.
  final TrainerModel? model;

  /// "Drill my weak hands": drill [spotId], biased to [targets].
  final void Function(String spotId, List<(String, int)> targets)? onDrillWeak;
  const ChartsScreen(
      {super.key,
      required this.library,
      required this.onDrill,
      this.model,
      this.onDrillWeak});

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends State<ChartsScreen> {
  SpotFormat format = SpotFormat.cash100;
  late String cashId = widget.library.cash.first.id;
  int stack = 10;
  bool bbSide = false;

  /// Push/fold players: 2 = heads-up, 3 = BTN/SB/BB (if data is loaded).
  int players = 2;
  String node3 = pushFold3Nodes.first.key;

  /// "My mistakes" heatmap instead of the strategy chart.
  bool mistakes = false;

  /// Mistakes aggregated over every spot in the shown spot's group.
  bool wholeGroup = false;

  /// Short-stack jam spots: opener seat, stack, and which side to show.
  String rjOpener = 'BTN';
  int rjStack = 20;
  bool rjOpenerSide = false;
  bool get hasRejam => widget.library.rejam.isNotEmpty;

  bool get has3 => widget.library.pushFold3.isNotEmpty;
  bool get threeHanded => players == 3 && has3;
  int get minStack => threeHanded ? 5 : 3;
  int get maxStack => threeHanded ? 20 : 25;

  Spot get spot {
    if (format == SpotFormat.cash100) return widget.library.byId(cashId);
    if (format == SpotFormat.rejam) {
      return widget.library.byId(rjOpenerSide
          ? rejamOpenerId(rjOpener, rjStack)
          : rejamBbId(rjOpener, rjStack));
    }
    if (threeHanded) {
      return widget.library.byId(pushFold3Id(node3, stack.clamp(5, 20)));
    }
    return widget.library.byId('pf-${bbSide ? 'bb' : 'sb'}-$stack');
  }

  /// Every spot choice of the current format, in a sheet.
  Future<void> _pickSpot(Map<String, List<Spot>> groups) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheet) => StatefulBuilder(builder: (sheet, setSheet) {
          final t = Theme.of(sheet).textTheme;
          void set(VoidCallback f) {
            setState(f);
            setSheet(() {});
          }

          ChoiceChip chip(String label, bool selected, VoidCallback onTap, {Key? key}) => ChoiceChip(
                key: key,
                visualDensity: VisualDensity.compact,
                showCheckmark: false,
                label: Text(label),
                selected: selected,
                onSelected: (_) => onTap(),
              );
          Widget label(String s) => Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Text(s, style: t.labelLarge),
              );
          final children = <Widget>[
            if (format == SpotFormat.cash100)
              for (final g in groups.entries) ...[
                label(g.key),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final c in g.value)
                    chip(
                        c.title.replaceAll(' open', '').replaceAll(' 3-bet', '').replaceAll('vs ', 'v '),
                        c.id == cashId, () {
                      setState(() => cashId = c.id);
                      Navigator.pop(sheet);
                    }),
                ]),
              ]
            else if (format == SpotFormat.rejam) ...[
              label('Opener'),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final p in rejamOpeners) chip(p, p == rjOpener, () => set(() => rjOpener = p)),
              ]),
              label('Decision'),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('BB: jam?')),
                  ButtonSegment(value: true, label: Text('Opener: call?')),
                ],
                selected: {rjOpenerSide},
                onSelectionChanged: (v) => set(() => rjOpenerSide = v.first),
              ),
              label('Big blind stack'),
              SegmentedButton<int>(
                segments: [
                  for (final st in rejamStacks) ButtonSegment(value: st, label: Text('${st}bb')),
                ],
                selected: {rjStack},
                onSelectionChanged: (v) => set(() => rjStack = v.first),
              ),
            ] else ...[
              if (has3) ...[
                label('Players'),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 3, label: Text('3')),
                  ],
                  selected: {players},
                  onSelectionChanged: (v) => set(() {
                    players = v.first;
                    stack = stack.clamp(minStack, maxStack);
                  }),
                ),
              ],
              label('Decision'),
              if (threeHanded)
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final n in pushFold3Nodes) chip(n.label, n.key == node3, () => set(() => node3 = n.key)),
                ])
              else
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('SB: jam?')),
                    ButtonSegment(value: true, label: Text('BB: call jam?')),
                  ],
                  selected: {bbSide},
                  onSelectionChanged: (v) => set(() => bbSide = v.first),
                ),
            ],
          ];
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ...children,
                  if (format != SpotFormat.cash100) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                          key: const Key('chart-spot-done'),
                          onPressed: () => Navigator.pop(sheet),
                          child: const Text('Done')),
                    ),
                  ],
                ]),
              ),
            ),
          );
        }),
      );

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
          actions: const [HelpButton(HelpTopic.charts), ChartOptionsMenu()]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // One compact header so the grid is on screen at once: the format,
          // then the spot as a single "Spot ▾" button (choices in a sheet).
          SegmentedButton<SpotFormat>(
            key: const Key('chart-format'),
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: [
              const ButtonSegment(value: SpotFormat.cash100, label: FittedBox(fit: BoxFit.scaleDown, child: Text('6-max 100bb', maxLines: 1))),
              if (hasRejam)
                const ButtonSegment(value: SpotFormat.rejam, label: FittedBox(fit: BoxFit.scaleDown, child: Text('Short stack', maxLines: 1))),
              const ButtonSegment(value: SpotFormat.pushFold, label: FittedBox(fit: BoxFit.scaleDown, child: Text('Push/fold', maxLines: 1))),
            ],
            selected: {format},
            onSelectionChanged: (v) => setState(() => format = v.first),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('chart-spot-picker'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: () => _pickSpot(groups),
            child: Row(children: [
              Text('Spot: ', style: t.labelLarge),
              Expanded(
                child: Text(s.title, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const Icon(Icons.arrow_drop_down),
            ]),
          ),
          if (format == SpotFormat.pushFold)
            Row(children: [
              Text('${stack}bb', style: t.titleMedium),
              Expanded(
                child: Slider(
                  value: stack.toDouble(),
                  min: minStack.toDouble(),
                  max: maxStack.toDouble(),
                  divisions: maxStack - minStack,
                  label: '${stack}bb',
                  onChanged: (v) => setState(() => stack = v.round()),
                ),
              ),
            ])
          else
            const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The spot's name is on the picker above; here only the
                  // view toggle and the situation in words (on tap).
                  Row(children: [
                    Expanded(
                      child: widget.model == null
                          ? const SizedBox.shrink()
                          : SegmentedButton<bool>(
                              key: const Key('chart-mistakes-toggle'),
                              showSelectedIcon: false,
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              segments: const [
                                ButtonSegment(
                                    value: false,
                                    label: FittedBox(fit: BoxFit.scaleDown, child: Text('Chart', maxLines: 1))),
                                ButtonSegment(
                                    value: true,
                                    label: FittedBox(fit: BoxFit.scaleDown, child: Text('My mistakes', maxLines: 1))),
                              ],
                              selected: {mistakes},
                              onSelectionChanged: (v) => setState(() => mistakes = v.first),
                            ),
                    ),
                    IconButton(
                      key: const Key('chart-info'),
                      tooltip: 'About this spot',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.info_outline, size: 20),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (d) => AlertDialog(
                          title: Text(s.title),
                          content: Text(s.situation),
                          actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('OK'))],
                        ),
                      ),
                    ),
                  ]),
                  if (s.handAuthored) ...[
                    const ApproximateChip(),
                    const SizedBox(height: 4),
                  ],
                  const SizedBox(height: 6),
                  if (mistakes && widget.model != null)
                    _MistakesView(
                      model: widget.model!,
                      spot: s,
                      wholeGroup: wholeGroup,
                      onScope: (v) => setState(() => wholeGroup = v),
                      onDrill: () => widget.onDrill(s.id),
                      onDrillWeak: widget.onDrillWeak,
                    )
                  else ...[
                    RangeGrid(
                      spot: s,
                      onTap: (h) => showCoachSheet(context, s, h,
                          onDrill: () => widget.onDrill(s.id)),
                    ),
                    const SizedBox(height: 8),
                    if (s.reach != null) ...[
                      // Three long action labels: legend gets the full width.
                      ActionLegend(spot: s),
                      const SizedBox(height: 4),
                      Text('Continues ${pct(s.continueShare)} of opens',
                          style: t.labelLarge),
                    ] else
                      Row(children: [
                        Expanded(child: ActionLegend(spot: s)),
                        Text('Plays ${pct(s.playPercent)}', style: t.labelLarge),
                      ]),
                    const SizedBox(height: 6),
                    Text(
                      switch (s.format) {
                        SpotFormat.cash100 when s.solved =>
                          '${s.solverNote ?? ''} Tap any hand for coaching.',
                        SpotFormat.cash100 => s.reach != null
                            ? 'Hand-authored approximation. Faded hands are not '
                                'in the opening range. Tap any hand for coaching.'
                            : 'Approximate GTO baseline. Tap any hand for coaching.',
                        SpotFormat.pushFold =>
                          'Nash equilibrium, solved by Felt Notes (Monte Carlo equities, exact card removal).',
                        SpotFormat.pushFold3 =>
                          '3-handed equilibrium (BTN/SB/BB, no ante), solved by Felt Notes '
                              '(Monte Carlo 2- and 3-way equities, exact card removal).',
                        SpotFormat.rejam => '${s.solverNote ?? ''} Monte Carlo '
                            'equities, exact card removal; the BB has no flat or '
                            'small 3-bet in this model.',
                      },
                      style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (!mistakes || widget.model == null)
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
              subtitle: const Text(
                  'BB vs BTN river strategies, single-raised and 3-bet pots, + drill'),
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

/// "My mistakes": the 13x13 grid coloured by your recency-weighted accuracy
/// in this spot (or its whole group), plus "Drill my weak hands".
class _MistakesView extends StatelessWidget {
  final TrainerModel model;
  final Spot spot;
  final bool wholeGroup;
  final ValueChanged<bool> onScope;
  final VoidCallback onDrill;
  final void Function(String spotId, List<(String, int)> targets)? onDrillWeak;
  const _MistakesView(
      {required this.model,
      required this.spot,
      required this.wholeGroup,
      required this.onScope,
      required this.onDrill,
      required this.onDrillWeak});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final ids = wholeGroup
            ? {
                for (final x in model.library.all)
                  if (x.group == spot.group) x.id
              }
            : {spot.id};
        final now = model.now.millisecondsSinceEpoch;
        // Hand-authored spots are drilled but never scored as leaks.
        final scored = model.scoredHistory;
        final scores = cellScores(scored, ids, now);
        final weak = weakTargets(scored, ids, now);
        final tries = scores.values.fold<int>(0, (a, b) => a + b.attempts);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              ChoiceChip(
                visualDensity: VisualDensity.compact,
                showCheckmark: false,
                label: const Text('This spot'),
                selected: !wholeGroup,
                onSelected: (_) => onScope(false),
              ),
              ChoiceChip(
                key: const Key('mistakes-group'),
                visualDensity: VisualDensity.compact,
                showCheckmark: false,
                label: Text('All of ${spot.group}',
                    overflow: TextOverflow.ellipsis),
                selected: wholeGroup,
                onSelected: (_) => onScope(true),
              ),
            ]),
            const SizedBox(height: 10),
            MistakeGrid(
              scores: scores,
              onTap: (h) => showCoachSheet(context, spot, h, onDrill: onDrill),
            ),
            const SizedBox(height: 8),
            const MistakeLegend(),
            const SizedBox(height: 6),
            Text(
              spot.handAuthored
                  ? '$approximateLabel: this spot is a hand-authored '
                      'approximation, so it is not scored as leaks here. You '
                      'can still drill it.'
                  : tries == 0
                  ? 'No drills here yet. Play this spot in the trainer and your '
                      'mistakes show up on the grid.'
                  : '$tries ${tries == 1 ? 'answer' : 'answers'}. Recent answers '
                      'count most: one from ${mistakeHalfLife.inDays} days ago '
                      'counts half. Tap a hand for coaching.',
              style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              key: const Key('drill-weak-hands'),
              onPressed: weak.isEmpty || onDrillWeak == null
                  ? null
                  : () => onDrillWeak!(spot.id, weak),
              icon: const Icon(Icons.healing),
              label: Text(weak.isEmpty
                  ? 'No weak hands yet'
                  : 'Drill my weak hands (${weak.length})'),
            ),
          ],
        );
      },
    );
  }
}
