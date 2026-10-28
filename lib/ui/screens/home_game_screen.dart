import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../camera/snap_cards_screen.dart';
import '../../gto/coach.dart';
import '../../homegame/home_game.dart';
import '../../poker/cards.dart';
import '../../trainer/trainer_model.dart';
import '../theme.dart';
import '../widgets/action_pad.dart';
import '../widgets/badges.dart';
import '../widgets/button_draw_dialog.dart';
import '../widgets/my_result_dialog.dart';
import '../../homegame/board_speech.dart';
import '../widgets/board_row.dart';
import '../widgets/playing_card.dart';
import '../widgets/story_tags.dart';
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
                  onPressed: () {
                    // A light-theme coach snackbar would otherwise float over
                    // the dark-only TV screen.
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    Navigator.of(context).push(MaterialPageRoute(
                        fullscreenDialog: true,
                        builder: (_) => DashboardScreen(model: model)));
                  },
                ),
              if (s != null)
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'result') editMyResult(context, model, s);
                    if (v == 'end') {
                      // Optional, yours only: Skip leaves it blank.
                      await editMyResult(context, model, s, skipLabel: 'Skip');
                      if (!context.mounted) return;
                      model.end();
                      // Wrapped: show tonight's recap straight away.
                      Navigator.of(context).push(MaterialPageRoute(
                          fullscreenDialog: true,
                          builder: (_) =>
                              RecapScreen(model: model, session: s)));
                    }
                    if (v == 'seats') showSeatsEditor(context, model);
                    if (v == 'clock') openBlindClock(context);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'clock', child: Text('Blind clock')),
                    PopupMenuItem(
                        value: 'seats', child: Text('Players & seats')),
                    PopupMenuItem(value: 'result', child: Text('My result')),
                    PopupMenuItem(value: 'end', child: Text('End game night')),
                  ],
                ),
            ],
          ),
          body: s == null
              ? _Setup(model: model)
              : _Logger(model: model, session: s, trainer: trainer),
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
  final names =
      TextEditingController(text: 'Me, Alex, Sam, Jordan, Casey, Riley');
  int hero = 0;

  /// First dealer; -1 = not known yet (tapped in the game when learning).
  int button = -1;

  /// Seat order from the first-orbit dealer taps instead of typed order.
  bool learn = true;

  /// Typed names, blanks and repeats dropped (seats are matched by name).
  List<String> get players {
    final seen = <String>{};
    return [
      for (final n in names.text.split(','))
        if (n.trim().isNotEmpty && seen.add(n.trim().toLowerCase())) n.trim()
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = players;
    if (hero >= p.length) hero = 0;
    if (button >= p.length || (!learn && button < 0)) button = learn ? -1 : 0;
    final past = widget.model.sessions.reversed.toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Text('Start a game night', style: t.headlineSmall),
        const SizedBox(height: 4),
        Text(
            'Everything stays on this phone. Do nothing on hands you fold: '
            'tap the big pad only when you call or raise. The organizer taps '
            'Next hand once per hand and Felt Notes moves the button.',
            style: t.bodyMedium),
        const SizedBox(height: 16),
        TextField(
          controller: names,
          decoration: InputDecoration(
            labelText: learn
                ? "Who's playing (any order)"
                : 'Players in seat order, clockwise',
            helperText: 'Comma separated, 2–10 players',
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: learn,
          onChanged: (v) => setState(() => learn = v),
          title: const Text('Learn the seats from the deal'),
          subtitle: const Text(
              'First orbit: tap whoever is dealing. That order becomes the seating.'),
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
        Text(
            learn
                ? 'Who deals first? (optional: or tap them once the game starts)'
                : 'Who has the dealer button for the first hand?',
            style: t.labelLarge),
        Wrap(spacing: 6, children: [
          for (var i = 0; i < p.length; i++)
            ChoiceChip(
                // The gold disc is the dealer button; a tick on top of it
                // looked like a greyed-out radio.
                showCheckmark: false,
                avatar: button == i
                    ? const Icon(Icons.circle, size: 14, color: Felt.gold)
                    : null,
                label: Text(p[i]),
                selected: button == i,
                onSelected: (on) =>
                    setState(() => button = on || !learn ? i : -1)),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: p.length < 2 || p.length > 10
                ? null
                : () async {
                    final w = await showButtonDraw(context, p);
                    if (w != null && mounted) setState(() => button = w);
                  },
            icon: const Icon(Icons.style_outlined, size: 18),
            label: const Text('Draw for the button'),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: p.length < 2 || p.length > 10
              ? null
              : () => widget.model.start(
                    name: 'Game night ${_date(DateTime.now())}',
                    players: p,
                    heroSeat: hero,
                    buttonSeat: button,
                    learnSeats: learn,
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
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CrewScreen(model: widget.model))),
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
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            fullscreenDialog: true,
                            builder: (_) =>
                                RecapScreen(model: widget.model, session: s))),
                  ),
                  IconButton(
                    tooltip: 'Dashboard',
                    icon: const Icon(Icons.bar_chart),
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            fullscreenDialog: true,
                            builder: (_) => DashboardScreen(
                                model: widget.model, session: s))),
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
  List<int>? get _cards => hasCards ? cards.cast<int>() : null;

  /// After a hand boundary: clear the entry, coach a graded miss, badges.
  void _afterClose(int before) {
    final s = widget.session;
    setState(() {
      cards = [null, null];
      facing = Facing.unopened;
    });
    if (s.hands.length <= before) return;
    final last = s.hands.last;
    // Instant feedback for graded spots.
    if (last.hand != null &&
        last.action != null &&
        last.facing == Facing.unopened) {
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
    showBadgeSnack(context, widget.model.claimNewBadges());
  }

  /// Organizer: the hand is over, the button moves on.
  void _nextHand() {
    final before = widget.session.hands.length;
    widget.model.nextHand(cards: _cards);
    _afterClose(before);
  }

  /// Organizer, first orbit: [seat] is dealing now.
  void _dealerTap(int seat) {
    final before = widget.session.hands.length;
    HapticFeedback.mediumImpact();
    if (widget.model.dealerTap(seat, cards: _cards)) _afterClose(before);
  }

  /// Your tap for this hand. The explicit buttons pass what it was facing;
  /// the gesture pad leaves it unknown.
  void _tap(PreAction? a, {bool fromButton = false}) =>
      widget.model.setPending(a, facing: fromButton ? facing : null);

  /// "That was hand…": put the cards/action being entered on an earlier
  /// hand picked by its board, instead of the hand being played now.
  Future<void> _attachLate() async {
    final done = await showAttachSheet(context, widget.model,
        cards: _cards, facing: facing);
    if (!done || !mounted) return;
    setState(() {
      cards = [null, null];
      facing = Facing.unopened;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Added to that hand')));
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
    final pick = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Who is dealing this hand?'),
          ),
          for (var i = 0; i < s.tableSize; i++)
            ListTile(
              leading: Icon(i == s.buttonSeat
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: Text(
                  i == s.heroSeat ? '${s.players[i]} (you)' : s.players[i]),
              onTap: () => Navigator.pop(ctx, i),
            ),
          if (!s.learning) ...[
            for (final n in s.bench)
              ListTile(
                leading: const Icon(Icons.person_add_alt),
                title: Text(n),
                subtitle: const Text('joins: seated where they deal'),
                onTap: () => Navigator.pop(ctx, n),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Someone new'),
              onTap: () async {
                final name = await askName(ctx);
                if (name != null && ctx.mounted) Navigator.pop(ctx, name);
              },
            ),
          ],
        ]),
      ),
    );
    if (pick is int) widget.model.setDealer(pick);
    if (pick is String) widget.model.dealerArrives(pick);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = widget.session;
    final n = s.hands.length + 1;
    final st = computeStats(s.hands, widget.model.library);
    final b = Theme.of(context).brightness;
    // The pad sits under the list, never inside it: a scroll must not be
    // read as a swipe.
    return Column(children: [
      Expanded(child: _list(context, s, n, st, t, b)),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: ActionPad(
            pending: s.pendingAction,
            skipped: s.pendingSkip,
            onAction: _tap,
            onNext: s.learning ? null : _nextHand,
          ),
        ),
      ),
    ]);
  }

  Widget _list(BuildContext context, HomeSession s, int n, SessionStats st,
      TextTheme t, Brightness b) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
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
              'towards the hands you chose to log. Just tap Next hand: an untouched '
              'hand counts as a fold.',
              style: t.bodySmall?.copyWith(color: Felt.mixedText(context)),
            ),
          ),
        const SizedBox(height: 12),
        _Organizer(
          session: s,
          onNext: _nextHand,
          onDealer: _dealerTap,
          onPickDealer: _pickDealer,
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Text('Hand $n', style: t.titleLarge),
                    const SizedBox(width: 12),
                    // Spacer + Flexible split the free width in half, so even
                    // "Dealer: Me" was cut to "Dealer: …".
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: ActionChip(
                          avatar: Icon(Icons.circle,
                              size: 12, color: Felt.accent(context)),
                          label: Text(
                              s.handInProgress
                                  ? 'Dealer: ${s.players[s.buttonSeat]}'
                                  : 'Dealer: ?',
                              overflow: TextOverflow.ellipsis),
                          onPressed: _pickDealer,
                        ),
                      ),
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
                        // A tick made the chip wider, so correcting the
                        // position reflowed the whole row.
                        showCheckmark: false,
                        onSelected: (_) => widget.model.setPosition(p),
                      ),
                  ]),
                  const SizedBox(height: 14),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (snapCardsSupported) const SizedBox(width: 56),
                    // Without Semantics the card slots were invisible to screen
                    // readers (a bare GestureDetector has no tap action).
                    Semantics(
                      container: true,
                      button: true,
                      label: hasCards ? 'Change my cards' : 'Add my cards',
                      child: GestureDetector(
                        onTap: _pickCards,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          PlayingCard(card: cards[0], width: 66),
                          const SizedBox(width: 10),
                          PlayingCard(card: cards[1], width: 66),
                        ]),
                      ),
                    ),
                    if (snapCardsSupported)
                      SizedBox(
                        width: 56,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
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
                        hasCards
                            ? 'Tap to change. Saved with the hand at Next hand'
                            : 'Cards are optional: tap to add them',
                        textAlign: TextAlign.center,
                        style: t.bodySmall),
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<Facing>(
                    segments: const [
                      ButtonSegment(
                          value: Facing.unopened, label: Text('Folded to me')),
                      ButtonSegment(
                          value: Facing.raised, label: Text('Someone raised')),
                    ],
                    selected: {facing},
                    onSelectionChanged: (v) {
                      setState(() => facing = v.first);
                      // Re-grade a button tap already made this hand.
                      if (s.pendingFacing != null) {
                        widget.model.setPending(s.pendingAction, facing: facing);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    for (final a in PreAction.values) ...[
                      if (a != PreAction.fold) const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                Felt.actionColor(preActionLabels[a]!, b),
                            foregroundColor:
                                a == PreAction.fold && b == Brightness.light
                                    ? Colors.black87
                                    : Colors.white,
                            minimumSize: const Size.fromHeight(50),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            side: s.pendingAction == a
                                ? BorderSide(
                                    color: Felt.accent(context), width: 3)
                                : null,
                          ),
                          onPressed: () => _tap(a, fromButton: true),
                          // "Call / limp" wrapped onto two lines at 390 px.
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(preActionLabels[a]!, maxLines: 1),
                          ),
                        ),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 8),
                  Wrap(alignment: WrapAlignment.spaceBetween, children: [
                    TextButton(
                      onPressed: () => widget.model.setPendingSkip(!s.pendingSkip),
                      child: Text(s.pendingSkip
                          ? 'Count it as a fold after all'
                          : "Didn't see this hand"),
                    ),
                    // Late logging: match an earlier hand by its board.
                    if (widget.model.handsWithBoards().isNotEmpty)
                      TextButton.icon(
                        onPressed: _attachLate,
                        icon: const Icon(Icons.history, size: 18),
                        label: const Text('That was hand…'),
                      ),
                  ]),
                ]),
          ),
        ),
        BoardRow(
          model: widget.model,
          session: s,
          dead: [
            for (final c in cards)
              if (c != null) c
          ],
        ),
        const SizedBox(height: 12),
        // No story tags for a skipped hand: there is no story to tell.
        if (s.hands.isNotEmpty && !s.hands.last.skipped)
          StoryTagRow(model: widget.model, hand: s.hands.last),
        if (s.hands.isNotEmpty) ...[
          Row(children: [
            Expanded(
                child: Text('Recent hands',
                    overflow: TextOverflow.ellipsis, style: t.titleMedium)),
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
                  ? 'Not seen · ${h.position}'
                  : '${h.cards == null ? 'No cards' : prettyCards(h.cards!)}  ·  ${h.position}'),
              subtitle: h.board == null
                  ? null
                  : Text('Board ${boardLabel(h.board!)}'),
              trailing: Text(h.action == null
                  ? ''
                  : h.assumed
                      ? 'Fold (auto)'
                      : preActionLabels[h.action]!),
            ),
        ],
      ],
    );
  }
}

/// The organizer's hand-boundary control. First orbit: a name button per
/// unseated player (tap whoever deals; the tap order becomes the seating).
/// After that: one big Next hand button, the button moves by itself.
class _Organizer extends StatelessWidget {
  final HomeSession session;
  final VoidCallback onNext;
  final ValueChanged<int> onDealer;
  final VoidCallback onPickDealer;
  const _Organizer({
    required this.session,
    required this.onNext,
    required this.onDealer,
    required this.onPickDealer,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = session;
    final learned = s.learnedSeats;
    if (learned == null) {
      final next = s.players[(s.buttonSeat + 1) % s.tableSize];
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(64),
            textStyle: t.titleLarge,
          ),
          onPressed: () {
            HapticFeedback.mediumImpact();
            onNext();
          },
          icon: const Icon(Icons.skip_next, size: 30),
          label: const Text('Next hand'),
        ),
        const SizedBox(height: 4),
        Text(
          '${s.players[s.buttonSeat]} is dealing · next: $next. '
          'Organizer taps once per hand; untouched hands count as folds.',
          style: t.bodySmall,
          textAlign: TextAlign.center,
        ),
      ]);
    }
    final first = learned >= 2 ? s.players[0] : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(learned == 0 ? 'Who deals the first hand?' : 'Who is dealing now?',
              style: t.titleMedium),
          const SizedBox(height: 2),
          Text(
            'Organizer: tap each dealer as the deal goes round. The order you '
            'tap becomes the seating, then the button moves by itself.'
            '${learned == 0 ? '' : ' Dealing now: ${s.players[s.buttonSeat]}.'}',
            style: t.bodySmall,
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = learned; i < s.tableSize; i++)
              FilledButton.tonal(
                style: FilledButton.styleFrom(minimumSize: const Size(96, 52)),
                onPressed: () => onDealer(i),
                child: Text(i == s.heroSeat ? '${s.players[i]} (you)' : s.players[i]),
              ),
            if (first != null)
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(96, 52)),
                onPressed: () => onDealer(0),
                child: Text('$first again: orbit done'),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// Asks for one player name; null when cancelled or blank.
Future<String?> askName(BuildContext context) async {
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
  final n = name?.trim();
  return n == null || n.isEmpty ? null : n;
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
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SafeArea(
            child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Text('Players & seats (clockwise)',
                      style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                      s.learning
                          ? 'Seats are being learned from the deal: '
                              '${s.learnedSeats} of ${s.tableSize} confirmed.'
                          : 'Tap + between two players to seat someone there.',
                      style: Theme.of(ctx).textTheme.bodySmall),
                  for (var i = 0; i < s.tableSize; i++) ...[
                    _AddHere(onAdd: (name) => model.addPlayer(name, i)),
                    ListTile(
                      dense: true,
                      leading: i == s.buttonSeat
                          ? Icon(Icons.circle, size: 18, color: Felt.accent(ctx))
                          : const Icon(Icons.event_seat, size: 18),
                      title: Text(i == s.heroSeat
                          ? '${s.players[i]} (you)'
                          : s.players[i]),
                      subtitle: i == s.buttonSeat
                          ? const Text('dealer this hand')
                          : null,
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
                  if (s.bench.isNotEmpty)
                    Text(
                        'Not in the deal: ${s.bench.join(', ')}. They join the '
                        'rotation when picked as dealer.',
                        style: Theme.of(ctx).textTheme.bodySmall),
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
          final name = await askName(context);
          if (name != null) onAdd(name);
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
            Text(value,
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
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
              Text(
                  chosen.isEmpty
                      ? 'Tap your first card'
                      : 'Now your second card',
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
  const _TwoPickCell(
      {required this.card, required this.selected, required this.onTap});

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
                  color: suitColor(cardSuit(card)),
                  fontWeight: FontWeight.w800,
                  fontSize: 15)),
          Text(suitSymbols[cardSuit(card)],
              style: TextStyle(color: suitColor(cardSuit(card)), fontSize: 13)),
        ]),
      ),
    );
  }
}
