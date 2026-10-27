import 'package:flutter/material.dart';

import '../../camera/snap_cards_screen.dart';
import '../../gto/coach.dart';
import '../../homegame/home_game.dart';
import '../../poker/cards.dart';
import '../../trainer/trainer_model.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';
import 'blind_clock_screen.dart';
import 'crew_screen.dart';
import 'dashboard_screen.dart';
import 'help_screen.dart';
import 'recap_screen.dart';
import 'review_sheet.dart';

class HomeGameScreen extends StatelessWidget {
  final HomeGameModel model;

  /// When set, graded home-game misses are queued as leak drills.
  final TrainerModel? trainer;
  const HomeGameScreen({super.key, required this.model, this.trainer});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final s = model.active;
        return Scaffold(
          appBar: AppBar(
            title: Text(s == null ? 'Home game' : s.name),
            actions: [
              const HelpButton(HelpTopic.homeGame),
              if (s != null)
                IconButton(
                  tooltip: 'TV dashboard',
                  icon: const Icon(Icons.tv),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => DashboardScreen(model: model))),
                ),
              if (s != null)
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'end') {
                      model.end();
                      // Wrapped: show tonight's recap straight away.
                      Navigator.of(context).push(MaterialPageRoute(
                          fullscreenDialog: true,
                          builder: (_) => RecapScreen(model: model, session: s)));
                    }
                    if (v == 'seats') showSeatsEditor(context, model);
                    if (v == 'clock') openBlindClock(context);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'clock', child: Text('Blind clock')),
                    PopupMenuItem(value: 'seats', child: Text('Players & seats')),
                    PopupMenuItem(value: 'end', child: Text('End game night')),
                  ],
                ),
            ],
          ),
          body: s == null ? _Setup(model: model) : _Logger(model: model, session: s, trainer: trainer),
        );
      },
    );
  }
}

class _Setup extends StatefulWidget {
  final HomeGameModel model;
  const _Setup({required this.model});

  @override
  State<_Setup> createState() => _SetupState();
}

class _SetupState extends State<_Setup> {
  final names = TextEditingController(text: 'Me, Alex, Sam, Jordan, Casey, Riley');
  int hero = 0;
  int button = 0;

  List<String> get players => [
        for (final n in names.text.split(','))
          if (n.trim().isNotEmpty) n.trim()
      ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = players;
    if (hero >= p.length) hero = 0;
    if (button >= p.length) button = 0;
    final past = widget.model.sessions.reversed.toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Text('Start a game night', style: t.headlineSmall),
        const SizedBox(height: 4),
        Text(
            'Everything stays on this phone. Each hand you log your two cards '
            '(and, if you like, what you did before the flop). Seats are fixed, so '
            'Felt Notes works out your position as the button moves.',
            style: t.bodyMedium),
        const SizedBox(height: 16),
        TextField(
          controller: names,
          decoration: const InputDecoration(
            labelText: 'Players in seat order, clockwise',
            helperText: 'Comma separated, 2–10 players',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        Text('Which seat is you?', style: t.labelLarge),
        Wrap(spacing: 6, children: [
          for (var i = 0; i < p.length; i++)
            ChoiceChip(
                label: Text(p[i]),
                selected: hero == i,
                onSelected: (_) => setState(() => hero = i)),
        ]),
        const SizedBox(height: 12),
        Text('Who has the dealer button for the first hand?', style: t.labelLarge),
        Wrap(spacing: 6, children: [
          for (var i = 0; i < p.length; i++)
            ChoiceChip(
                avatar: button == i ? const Icon(Icons.circle, size: 14) : null,
                label: Text(p[i]),
                selected: button == i,
                onSelected: (_) => setState(() => button = i)),
        ]),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: p.length < 2 || p.length > 10
              ? null
              : () => widget.model.start(
                    name: 'Game night ${_date(DateTime.now())}',
                    players: p,
                    heroSeat: hero,
                    buttonSeat: button,
                  ),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => openBlindClock(context),
          icon: const Icon(Icons.timer_outlined),
          label: const Text('Blind clock'),
        ),
        if (past.isNotEmpty) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => CrewScreen(model: widget.model))),
            icon: const Icon(Icons.groups_outlined),
            label: const Text('Crew & season'),
          ),
        ],
        if (past.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text('Past game nights', style: t.titleMedium),
          for (final s in past)
            Card(
              child: ListTile(
                title: Text(s.name),
                subtitle: Text(_summary(widget.model, s)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(
                    child: const Text('Recap'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        fullscreenDialog: true,
                        builder: (_) => RecapScreen(model: widget.model, session: s))),
                  ),
                  IconButton(
                    tooltip: 'Dashboard',
                    icon: const Icon(Icons.bar_chart),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        fullscreenDialog: true,
                        builder: (_) => DashboardScreen(model: widget.model, session: s))),
                  ),
                ]),
              ),
            ),
        ],
      ],
    );
  }
}

String _date(DateTime d) => '${d.month}/${d.day}';

String _summary(HomeGameModel m, HomeSession s) {
  final st = computeStats(s.hands, m.library);
  return '${st.logged} hands · VPIP ${pct(st.vpipPct)} · PFR ${pct(st.pfrPct)}';
}

class _Logger extends StatefulWidget {
  final HomeGameModel model;
  final HomeSession session;
  final TrainerModel? trainer;
  const _Logger({required this.model, required this.session, this.trainer});

  @override
  State<_Logger> createState() => _LoggerState();
}

class _LoggerState extends State<_Logger> {
  List<int?> cards = [null, null];
  Facing facing = Facing.unopened;

  bool get hasCards => !cards.contains(null);

  void _save(PreAction? a, {bool keepCards = true}) {
    widget.model.logHand(
      cards: hasCards && keepCards ? cards.cast<int>() : null,
      action: a,
      facing: facing,
    );
    final last = widget.session.hands.last;
    setState(() {
      cards = [null, null];
      facing = Facing.unopened;
    });
    // Instant feedback for graded spots.
    if (last.hand != null && last.action != null && last.facing == Facing.unopened) {
      final st = computeStats([last], widget.model.library);
      if (st.misses.isNotEmpty) {
        final (h, spot, _) = st.misses.first;
        widget.trainer?.addExternalMisses([(spot.id, h.hand!.index)]);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${h.hand!.name} from ${h.position}: GTO says '
              '${strategyLine(spot, h.hand!)}'),
          action: SnackBarAction(
            label: 'Why?',
            onPressed: () => showCoachSheet(context, spot, h.hand!,
                chosen: rfiActionIndex(h.action!)),
          ),
        ));
      }
    }
  }

  Future<void> _pickCards() async {
    final picked = await pickTwoCards(context);
    if (picked != null) setState(() => cards = picked);
  }

  /// Beta camera flow; always optional, the picker stays one tap away.
  Future<void> _snapCards() async {
    final snapped = await snapCards(context);
    if (snapped == null || !mounted) return;
    if (snapped.every((c) => c == null)) {
      await _pickCards();
    } else {
      setState(() => cards = snapped);
    }
  }

  Future<void> _pickDealer() async {
    final s = widget.session;
    final seat = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Who is dealing this hand?'),
          ),
          for (var i = 0; i < s.tableSize; i++)
            ListTile(
              leading: Icon(i == s.buttonSeat ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(i == s.heroSeat ? '${s.players[i]} (you)' : s.players[i]),
              onTap: () => Navigator.pop(ctx, i),
            ),
        ]),
      ),
    );
    if (seat != null) widget.model.setDealer(seat);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = widget.session;
    final n = s.hands.length + 1;
    final st = computeStats(s.hands, widget.model.library);
    final b = Theme.of(context).brightness;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Row(children: [
          _Mini('Hands', '${st.logged}'),
          _Mini('VPIP', st.recorded == 0 ? '–' : pct(st.vpipPct)),
          _Mini('PFR', st.recorded == 0 ? '–' : pct(st.pfrPct)),
          _Mini('GTO', st.graded == 0 ? '–' : pct(st.gtoScore)),
        ]),
        if (st.logged >= 10 && st.coverage < 0.7)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Only ${pct(st.coverage)} of hands have an action, so VPIP/PFR lean '
              'towards the hands you chose to log. Tap Fold on boring hands (no cards needed).',
              style: t.bodySmall?.copyWith(color: Felt.mixed),
            ),
          ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Text('Hand $n', style: t.titleLarge),
                const Spacer(),
                ActionChip(
                  avatar: const Icon(Icons.circle, size: 12),
                  label: Text('Dealer: ${s.players[s.buttonSeat]}'),
                  onPressed: _pickDealer,
                ),
              ]),
              const SizedBox(height: 8),
              Text('Your position (tap to correct)', style: t.labelMedium),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final p in s.positionsInOrder)
                  ChoiceChip(
                    label: Text(p),
                    selected: p == s.position,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => widget.model.setPosition(p),
                  ),
              ]),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (snapCardsSupported) const SizedBox(width: 56),
                GestureDetector(
                  onTap: _pickCards,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    PlayingCard(card: cards[0], width: 66),
                    const SizedBox(width: 10),
                    PlayingCard(card: cards[1], width: 66),
                  ]),
                ),
                if (snapCardsSupported)
                  SizedBox(
                    width: 56,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Snap my cards (beta)',
                        icon: const Icon(Icons.photo_camera_outlined),
                        onPressed: _snapCards,
                      ),
                      const BetaBadge(),
                    ]),
                  ),
              ]),
              const SizedBox(height: 6),
              Center(
                child: Text(
                    hasCards ? 'Tap to change' : 'Cards are optional: tap to add them',
                    style: t.bodySmall),
              ),
              const SizedBox(height: 14),
              SegmentedButton<Facing>(
                segments: const [
                  ButtonSegment(value: Facing.unopened, label: Text('Folded to me')),
                  ButtonSegment(value: Facing.raised, label: Text('Someone raised')),
                ],
                selected: {facing},
                onSelectionChanged: (v) => setState(() => facing = v.first),
              ),
              const SizedBox(height: 10),
              Row(children: [
                for (final a in PreAction.values) ...[
                  if (a != PreAction.fold) const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Felt.actionColor(preActionLabels[a]!, b),
                        foregroundColor: a == PreAction.fold && b == Brightness.light
                            ? Colors.black87
                            : Colors.white,
                        minimumSize: const Size.fromHeight(50),
                      ),
                      onPressed: () => _save(a),
                      child: Text(preActionLabels[a]!),
                    ),
                  ),
                ],
              ]),
              const SizedBox(height: 8),
              Row(children: [
                TextButton(
                  onPressed: hasCards ? () => _save(null) : null,
                  child: const Text('Save cards only'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _save(null, keepCards: false),
                  child: const Text('Skip hand'),
                ),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        if (s.hands.isNotEmpty) ...[
          Row(children: [
            Text('Recent hands', style: t.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: widget.model.undo,
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('Undo last'),
            ),
          ]),
          for (final h in s.hands.reversed.take(8))
            ListTile(
              dense: true,
              leading: SizedBox(
                width: 38,
                child: Text('#${h.number}', style: t.labelMedium),
              ),
              title: Text(h.skipped
                  ? 'Skipped · ${h.position}'
                  : '${h.cards == null ? 'No cards' : '${cardToString(h.cards![0])} ${cardToString(h.cards![1])}'}  ·  ${h.position}'),
              trailing: Text(h.action == null ? '' : preActionLabels[h.action]!),
            ),
        ],
      ],
    );
  }
}

/// Add or remove players mid-game. You can't remove yourself.
void showSeatsEditor(BuildContext context, HomeGameModel model) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: model,
      builder: (ctx, _) {
        final s = model.active;
        if (s == null) return const SizedBox();
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SafeArea(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
              Text('Players & seats (clockwise)', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('Tap + between two players to seat someone there.',
                  style: Theme.of(ctx).textTheme.bodySmall),
              for (var i = 0; i < s.tableSize; i++) ...[
                _AddHere(onAdd: (name) => model.addPlayer(name, i)),
                ListTile(
                  dense: true,
                  leading: Icon(i == s.buttonSeat ? Icons.circle : Icons.event_seat, size: 18),
                  title: Text(i == s.heroSeat ? '${s.players[i]} (you)' : s.players[i]),
                  subtitle: i == s.buttonSeat ? const Text('dealer this hand') : null,
                  trailing: i == s.heroSeat || s.tableSize <= 2
                      ? null
                      : IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () => model.removePlayer(i),
                        ),
                ),
              ],
              _AddHere(onAdd: (name) => model.addPlayer(name, s.tableSize)),
            ]),
          ),
        );
      },
    ),
  );
}

class _AddHere extends StatelessWidget {
  final ValueChanged<String> onAdd;
  const _AddHere({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Seat someone here'),
        onPressed: () async {
          final c = TextEditingController();
          final name = await showDialog<String>(
            context: context,
            builder: (d) => AlertDialog(
              title: const Text('New player'),
              content: TextField(
                controller: c,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Name'),
                onSubmitted: (v) => Navigator.pop(d, v),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Add')),
              ],
            ),
          );
          if (name != null && name.trim().isNotEmpty) onAdd(name.trim());
        },
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  final String label, value;
  const _Mini(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(children: [
            Text(value, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: t.bodySmall),
          ]),
        ),
      ),
    );
  }
}

/// Grid of all 52 cards; tap two and the sheet closes.
Future<List<int?>?> pickTwoCards(BuildContext context) {
  return showModalBottomSheet<List<int?>>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final chosen = <int>[];
      return StatefulBuilder(builder: (ctx, setSheet) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(chosen.isEmpty ? 'Tap your first card' : 'Now your second card',
                  style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 8),
              for (var s = 3; s >= 0; s--)
                Row(children: [
                  for (var r = 12; r >= 0; r--)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(1.5),
                        child: _TwoPickCell(
                          card: makeCard(r, s),
                          selected: chosen.contains(makeCard(r, s)),
                          onTap: () {
                            final c = makeCard(r, s);
                            if (chosen.contains(c)) {
                              setSheet(() => chosen.remove(c));
                              return;
                            }
                            chosen.add(c);
                            if (chosen.length == 2) {
                              Navigator.pop(ctx, <int?>[chosen[0], chosen[1]]);
                            } else {
                              setSheet(() {});
                            }
                          },
                        ),
                      ),
                    ),
                ]),
            ]),
          ),
        );
      });
    },
  );
}

class _TwoPickCell extends StatelessWidget {
  final int card;
  final bool selected;
  final VoidCallback onTap;
  const _TwoPickCell({required this.card, required this.selected, required this.onTap});

  static const _colors = [
    Color(0xFF1F7A3F),
    Color(0xFF2563EB),
    Color(0xFFD62839),
    Color(0xFF1B1B1B),
  ];

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: selected ? Felt.gold : Colors.white,
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(rankChars[cardRank(card)],
              style: TextStyle(
                  color: _colors[cardSuit(card)],
                  fontWeight: FontWeight.w800,
                  fontSize: 15)),
          Text(suitSymbols[cardSuit(card)],
              style: TextStyle(color: _colors[cardSuit(card)], fontSize: 13)),
        ]),
      ),
    );
  }
}
