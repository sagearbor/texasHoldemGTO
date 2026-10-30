// Multi-phone table night screens.
//
// Organizer: nothing new to learn. Starting a game night with "Let other
// phones and a TV join" on makes it a table night; the QR, the TV link and
// the sharing switch live in [showTableNightSheet] (the table icon on the
// hand logger). Players: [JoinTableNightScreen] (photograph the QR or type
// the code, pick your name, sharing on/off), then [PlayerPadScreen]: tap
// only for hands you play. Every phone works offline and uploads by itself.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../gto/coach.dart';
import '../../homegame/home_game.dart';
import '../../sync/night_events.dart';
import '../../sync/organizer_bridge.dart';
import '../../sync/table_night_service.dart';
import '../theme.dart';
import '../tv/tv_controller.dart' show ticketFromTvInput;
import '../tv/tv_screen.dart';
import '../widgets/playing_card.dart';
import 'home_game_screen.dart' show pickTwoCards;

TableNightService get _svc => TableNightService.instance;

/// The sharing switch, the same everywhere: one line says what it shares.
class SharingTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const SharingTile({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        secondary: Icon(value ? Icons.tv : Icons.lock_outline, color: value ? Felt.accent(context) : null),
        title: Text('Share my game with the table (TV)', style: t.titleSmall),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(TableNightService.sharingLine, style: t.bodySmall),
        ),
        isThreeLine: true,
      ),
    );
  }
}

// ------------------------------------------------------------------- join

class JoinTableNightScreen extends StatefulWidget {
  const JoinTableNightScreen({super.key});
  @override
  State<JoinTableNightScreen> createState() => _JoinTableNightScreenState();
}

class _JoinTableNightScreenState extends State<JoinTableNightScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  JoinTicket? _scanned;
  int? _scannedAt;
  String? _claim;
  String? _error;
  bool _busy = false;
  bool _share = true;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final XFile? shot;
    try {
      shot = await ImagePicker().pickImage(source: ImageSource.camera, requestFullMetadata: false);
    } catch (e) {
      setState(() => _error = 'No camera here ($e). Type the code instead.');
      return;
    }
    if (shot == null) return;
    final at = DateTime.now().millisecondsSinceEpoch;
    final scanner = BarcodeScanner(formats: [BarcodeFormat.qrCode]);
    try {
      final codes = await scanner.processImage(InputImage.fromFilePath(shot.path));
      for (final c in codes) {
        final t = JoinTicket.parse(c.rawValue ?? '');
        if (t != null) {
          // [at] is when the picker returned, a second or two after the
          // shutter; the merge tolerates that.
          setState(() {
            _scanned = t;
            _scannedAt = at;
            _error = null;
          });
          return;
        }
      }
      setState(() => _error = 'No Felt Notes QR in that photo. Try again closer.');
    } catch (e) {
      setState(() => _error = 'Could not read the photo ($e). Type the code instead.');
    } finally {
      await scanner.close();
    }
  }

  Future<void> _join() async {
    final t = _scanned ?? JoinTicket.parse(_code.text);
    final name = _name.text.trim();
    if (t == null) return setState(() => _error = 'That is not a join code (it looks like ABCD2345-WXYZ6789).');
    if (name.isEmpty) return setState(() => _error = 'Enter your name first (pick it above if it is listed).');
    setState(() => _busy = true);
    try {
      await _svc.join(t,
          name: name,
          claimPid: _claim,
          scannedAtMs: _scanned != null ? _scannedAt! : DateTime.now().millisecondsSinceEpoch,
          sharing: _share);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not join ($e).');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PlayerPadScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ticket = _scanned;
    return Scaffold(
      appBar: AppBar(title: const Text('Join a table night')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
          'The organizer logs the hands; you tap only when you play one. '
          'No signal needed at the table: your phone keeps its own notes and '
          'uploads them when it can.',
          style: t.bodyMedium,
        ),
        const SizedBox(height: 16),
        if (!kIsWeb) ...[
          FilledButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text("Photograph the organizer's QR"),
          ),
          const SizedBox(height: 8),
        ],
        if (ticket != null) ...[
          Text('Found ${ticket.organizerName.isEmpty ? 'a' : "${ticket.organizerName}'s"} table.',
              style: t.titleMedium),
          if (ticket.roster.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Which one are you?'),
            Wrap(spacing: 8, children: [
              for (final s in ticket.roster)
                ChoiceChip(
                  label: Text(s.name),
                  selected: _claim == s.pid,
                  onSelected: (v) => setState(() {
                    _claim = v ? s.pid : null;
                    if (v) _name.text = s.name;
                  }),
                ),
            ]),
          ],
        ] else
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Or type the code (ABCD2345-WXYZ6789)'),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Your name (as the organizer typed it)'),
        ),
        const SizedBox(height: 16),
        SharingTile(value: _share, onChanged: (v) => setState(() => _share = v)),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _join, child: const Text('Join')),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ]),
    );
  }
}

// -------------------------------------------------------------- player pad

/// One tap per hand you play. Not tapping = fold. Cards are optional.
class PlayerPadScreen extends StatefulWidget {
  const PlayerPadScreen({super.key});
  @override
  State<PlayerPadScreen> createState() => _PlayerPadScreenState();
}

class _PlayerPadScreenState extends State<PlayerPadScreen> {
  List<int>? _cards;
  bool _refreshing = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _refresh();
    // The status line says "2 min ago": keep it honest.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final s = _svc.night;
    if (s == null) return;
    setState(() => _refreshing = true);
    await s.refresh();
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _do(Future<void> Function() f) async {
    HapticFeedback.mediumImpact();
    await f();
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    final s = _svc.night;
    if (s == null) return;
    final c = await pickTwoCards(context);
    if (c == null || c.contains(null)) return;
    final cards = c.cast<int>();
    await s.setCards(cards);
    setState(() => _cards = cards);
  }

  Future<void> _tap(PreAction a) async {
    final s = _svc.night;
    if (s == null) return;
    await _do(() => s.tap(a));
    _cards = null; // the next cards are for the next hand
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _svc,
      builder: (context, _) {
        final s = _svc.night;
        if (s == null || s.isOrganizer) {
          return Scaffold(
            appBar: AppBar(title: const Text('Table night')),
            body: const Center(child: Text('Not in a table night.')),
          );
        }
        final t = Theme.of(context).textTheme;
        final plays = s.localEvents.where((e) => e.kind == EventKind.play).length;
        final m = s.merged();
        final me = m.devices.where((d) => d.deviceId == s.deviceId).firstOrNull;
        final mine = me == null ? const <LoggedHand>[] : m.loggedHandsFor(me.pid);
        final done = [for (final h in mine) h];
        final vp = done.where((h) => h.action != PreAction.fold).length;
        final pf = done.where((h) => h.action == PreAction.raise).length;
        return Scaffold(
          appBar: AppBar(
            title: Text(_svc.tableName()),
            actions: [
              IconButton(
                tooltip: 'Show the table on this screen (TV)',
                icon: const Icon(Icons.tv),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => TvScreen(ticket: s.ticket))),
              ),
            ],
          ),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text('Tap only when you put money in. Every other hand counts as a fold.', style: t.bodyLarge),
            const SizedBox(height: 16),
            Row(children: [
              for (final a in const [PreAction.call, PreAction.raise]) ...[
                if (a == PreAction.raise) const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Felt.actionColor(preActionLabels[a]!, Theme.of(context).brightness),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(72),
                      textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                    onPressed: () => _tap(a),
                    child: Text(a == PreAction.call ? 'Call' : 'Raise'),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 8),
            Row(children: [
              TextButton.icon(
                onPressed: () => _do(s.undoLast),
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('Undo last tap'),
              ),
              const Spacer(),
              Semantics(
                button: true,
                label: _cards == null ? 'Add my cards' : 'Change my cards',
                child: GestureDetector(
                  onTap: _pick,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    PlayingCard(card: _cards?[0], width: 40),
                    const SizedBox(width: 6),
                    PlayingCard(card: _cards?[1], width: 40),
                  ]),
                ),
              ),
            ]),
            Text(
              'Cards are optional. Add them before your tap; they go to the table only after the hand.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 16),
            SharingTile(value: s.sharing, onChanged: (v) => _svc.setSharing(v)),
            const SizedBox(height: 12),
            Row(children: [
              Icon(s.uploader?.lastError == null ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_svc.statusLine(), style: t.bodySmall)),
            ]),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('My night so far', style: t.titleMedium)),
                    IconButton(
                      tooltip: 'Fetch the latest hands',
                      onPressed: _refreshing ? null : _refresh,
                      icon: _refreshing
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh),
                    ),
                  ]),
                  if (done.isEmpty)
                    Text('$plays taps so far. Your hand count, VPIP and PFR appear once the '
                        "organizer's phone has uploaded the hands.")
                  else
                    Text('${done.length} hands · $plays tapped · VPIP ${pct(vp / done.length)} · '
                        'PFR ${pct(pf / done.length)} · ${playStyle(done.length, vp / done.length, pf / done.length)}'),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Leaving the table?'),
                    content: const Text('Hands after now are not counted for you. '
                        'Your taps keep uploading in the background.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Stay')),
                      FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Leave')),
                    ],
                  ),
                );
                if (ok != true) return;
                await _svc.leave();
                if (context.mounted) Navigator.of(context).pop();
              },
              icon: const Icon(Icons.logout),
              label: const Text('I’m leaving'),
            ),
          ]),
        );
      },
    );
  }
}

// --------------------------------------------------------------- organizer

/// The organizer's table-night panel: the QR to join, the TV link, the
/// sharing switch and the upload status.
Future<void> showTableNightSheet(BuildContext context, HomeSession session) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _OrganizerSheet(session: session),
  );
}

class _OrganizerSheet extends StatefulWidget {
  final HomeSession session;
  const _OrganizerSheet({required this.session});
  @override
  State<_OrganizerSheet> createState() => _OrganizerSheetState();
}

class _OrganizerSheetState extends State<_OrganizerSheet> {
  late Timer _tick;

  @override
  void initState() {
    super.initState();
    // Redrawn every second: the QR carries a fresh clock reading.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = _svc.night;
    if (s == null || !_svc.linkedTo(widget.session)) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('This game night is on this phone only.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                await _svc.organize(widget.session);
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Let other phones and a TV join'),
            ),
          ]),
        ),
      );
    }
    final ticket = s.qrTicket(roster: rosterOf(widget.session));
    final url = tvUrl(ticket);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Players: photograph this once', style: t.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(10),
              child: QrImageView(data: ticket.encode(), size: 240, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(height: 8),
          Center(child: SelectableText(ticket.code, style: t.headlineSmall)),
          const SizedBox(height: 4),
          Text('Home game → Join a table night. No app? They just play: you log the hands.',
              style: t.bodySmall, textAlign: TextAlign.center),
          const Divider(height: 28),
          Text('TV', style: t.titleMedium),
          const SizedBox(height: 4),
          Text('Open this link on a laptop, tablet or spare phone and cast or plug it into the TV:',
              style: t.bodySmall),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: SelectableText(url, style: t.bodyMedium)),
            IconButton(
              tooltip: 'Copy the TV link',
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('TV link copied')));
              },
            ),
          ]),
          TextButton.icon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => TvScreen(ticket: ticket))),
            icon: const Icon(Icons.tv),
            label: const Text('Preview the TV on this phone'),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: _svc,
            builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SharingTile(value: _svc.sharing, onChanged: _svc.setSharing),
              if (!_svc.sharing)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      'As the organizer, the hand count, dealer, seating, board and blind clock still go up, '
                      'so the TV keeps working.',
                      style: t.bodySmall),
                ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: Text(_svc.statusLine(), style: t.bodySmall)),
                TextButton(onPressed: _svc.flush, child: const Text('Upload now')),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ----------------------------------------------------- entry points (setup)

/// Setup screen: join someone's night, get back to yours, or show a night
/// on this screen as the TV.
class TableNightEntry extends StatelessWidget {
  const TableNightEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _svc,
      builder: (context, _) {
        final s = _svc.night;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (s != null && !s.isOrganizer)
            FilledButton.tonalIcon(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlayerPadScreen())),
              icon: const Icon(Icons.touch_app_outlined),
              label: Text('Back to ${_svc.tableName()}'),
            )
          else
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const JoinTableNightScreen())),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Join a table night'),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => showTvCodeDialog(context),
            icon: const Icon(Icons.tv),
            label: const Text('Show a table night on this screen (TV)'),
          ),
        ]);
      },
    );
  }
}

/// Setup screen switch: start the game night as a table night.
class TableNightStartSwitch extends StatelessWidget {
  final bool namesHaveMe;
  const TableNightStartSwitch({super.key, this.namesHaveMe = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _svc,
      builder: (context, _) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _svc.startWithTableNight,
        onChanged: _svc.setStartWithTableNight,
        title: const Text('Let other phones and a TV join'),
        subtitle: Text(namesHaveMe && _svc.startWithTableNight
            ? 'Players scan a QR; a TV shows the table live. Use real names: "Me" would show on the TV.'
            : 'Players scan a QR; a TV shows the table live. Works without signal, uploads when it can.'),
      ),
    );
  }
}

/// Called right after the setup screen started a night. The setup screen
/// is gone by then (the logger replaced it), so the sheet opens on the
/// navigator.
Future<void> afterGameNightStart(NavigatorState nav, HomeGameModel model) async {
  final s = model.active;
  if (s == null || !_svc.ready || !_svc.startWithTableNight) return;
  await _svc.organize(s);
  if (nav.mounted) await showTableNightSheet(nav.context, s);
}

/// The table icon on the hand logger (organizer of this night).
class TableNightButton extends StatelessWidget {
  final HomeSession session;
  const TableNightButton({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _svc,
      builder: (context, _) {
        final on = _svc.linkedTo(session);
        final up = _svc.night?.uploader;
        final trouble = on && up != null && up.lastError != null;
        return IconButton(
          tooltip: on ? 'Table night: QR, TV, sharing' : 'Let other phones and a TV join',
          icon: Badge(
            isLabelVisible: on,
            backgroundColor: trouble ? Felt.mixed : Felt.good,
            smallSize: 8,
            child: Icon(on ? Icons.qr_code_2 : Icons.qr_code_2_outlined),
          ),
          onPressed: () => showTableNightSheet(context, session),
        );
      },
    );
  }
}

/// "Show a table night on this screen": type or paste the code (or the
/// whole TV link).
Future<void> showTvCodeDialog(BuildContext context) async {
  final c = TextEditingController();
  final raw = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Show a table night'),
      content: TextField(
        controller: c,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(hintText: 'ABCD2345-WXYZ6789'),
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Show')),
      ],
    ),
  );
  if (raw == null || !context.mounted) return;
  final t = ticketFromTvInput(raw);
  if (t == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That is not a table night code.')));
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => TvScreen(ticket: t)));
}
