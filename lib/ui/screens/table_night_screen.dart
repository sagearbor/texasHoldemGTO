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
import '../../sync/night_merge.dart' show MergedNight;
import '../../sync/organizer_bridge.dart';
import '../../settings/dev_settings.dart';
import '../../sync/table_night_service.dart';
import '../../nearby/nearby_service.dart';
import '../../nearby/table_mode_screen.dart';
import '../../radar/radar_screen.dart';
import '../../nearby/nearby_ui.dart' show FindNearbyButton, NearbyHostTile, maybeAskUwb, showSeatCalibration;
import '../app_settings.dart';
import '../theme.dart';
import '../../camera/watch_screen.dart' show requestAutoWatch;
import '../tv/tv_controller.dart' show ticketFromTvInput;
import 'cloud_status_row.dart';
import '../tv/show_on_tv.dart';
import '../tv/tv_screen.dart';
import '../widgets/playing_card.dart';
import 'home_game_screen.dart' show pickTwoCards;

TableNightService get _svc => TableNightService.instance;

/// No cloud and the host's Bluetooth advert unheard this long: offer Leave.
const hostQuietMs = 5 * 60000;

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

/// The seat-finding switch (Bluetooth readings for the seat radar): ON by
/// default, separate from sharing hands; nothing about cards.
class SeatSignalsTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const SeatSignalsTile({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => SwitchListTile(
        key: const Key('share-seat-signals'),
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: onChanged,
        title: const Text('Share seat-finding signals (Bluetooth)'),
        subtitle: Text(TableNightService.seatSignalsLine, style: Theme.of(context).textTheme.bodySmall),
        isThreeLine: true,
      );
}

/// A player in someone else's night: hands private by default, sharing
/// under Advanced ("Share my hands with the table (for stats)"), next to
/// the seat-finding switch (on by default).
class JoinerSharingTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool seat;
  final ValueChanged<bool>? onSeatChanged;
  const JoinerSharingTile(
      {super.key, required this.value, required this.onChanged, this.seat = true, this.onSeatChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(value ? Icons.cloud_upload_outlined : Icons.lock_outline, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              value
                  ? 'You share your hands with the table (Advanced, below).'
                  : TableNightService.joinerPrivateLine,
              key: const Key('joiner-private-line'),
              style: t.bodyMedium),
        ),
      ]),
      ExpansionTile(
        key: const Key('joiner-advanced'),
        initiallyExpanded: value,
        tilePadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text('Advanced', style: t.titleSmall),
        children: [
          SwitchListTile(
            key: const Key('joiner-share'),
            contentPadding: EdgeInsets.zero,
            value: value,
            onChanged: onChanged,
            title: const Text('Share my hands with the table (for stats)'),
            subtitle: Text(TableNightService.joinerSharingLine, style: t.bodySmall),
            isThreeLine: true,
          ),
          if (onSeatChanged != null) SeatSignalsTile(value: seat, onChanged: onSeatChanged!),
        ],
      ),
    ]);
  }
}

// ------------------------------------------------------------------- join

class JoinTableNightScreen extends StatefulWidget {
  const JoinTableNightScreen({super.key});
  @override
  State<JoinTableNightScreen> createState() => _JoinTableNightScreenState();
}

class _JoinTableNightScreenState extends State<JoinTableNightScreen> {
  final _name = TextEditingController(text: AppSettings.playerName.value);
  final _code = TextEditingController();
  JoinTicket? _scanned;
  int? _scannedAt;
  String? _claim;
  String? _error;
  bool _busy = false;

  /// Joining someone's night keeps everything on this phone unless the
  /// player turns sharing on (Advanced).
  bool _share = false;

  /// Seat-finding signals (Bluetooth): on unless the player turns them off.
  bool _seat = true;

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
          sharing: _share,
          seatSignals: _seat);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not join ($e).');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    // Optional ground truth for the seating experiment (skippable), and
    // UWB on Android phones that have it.
    if (NearbyService.instance.allowed) {
      await maybeAskUwb(context);
      if (!mounted) return;
      await showSeatCalibration(context);
    }
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PlayerPadScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ticket = _scanned;
    return Scaffold(
      appBar: AppBar(title: const Text("Scan the host's code")),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
          'The organizer logs the hands; you do not need to tap anything. '
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
        JoinerSharingTile(
            value: _share,
            onChanged: (v) => setState(() => _share = v),
            seat: _seat,
            onSeatChanged: (v) => setState(() => _seat = v)),
        const SizedBox(height: 8),
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

/// What the pad's "My night so far" says, from the merged night: hands
/// dealt to [pid], the ones the player marked (a real tap), and VPIP / PFR
/// over the marked ones only. Untapped hands are unknown on a joiner's
/// pad, never folds (owner rule: joiners never need to tap).
class PadStats {
  final int dealt, marked, vpip, pfr;
  const PadStats(this.dealt, this.marked, this.vpip, this.pfr);

  static PadStats of(MergedNight m, String? pid) {
    var dealt = 0, marked = 0, vp = 0, pf = 0;
    if (pid != null) {
      for (final h in m.hands) {
        final p = h.players[pid];
        if (p == null) continue;
        dealt++;
        if (p.inferred) continue;
        marked++;
        if (p.voluntary) vp++;
        if (p.action == PreAction.raise) pf++;
      }
    }
    return PadStats(dealt, marked, vp, pf);
  }

  /// "—" when nothing is marked.
  String get vpipText => marked == 0 ? '—' : pct(vpip / marked);
  String get pfrText => marked == 0 ? '—' : pct(pfr / marked);
}

/// A joined player's screen. Hands-off by default: put the phone on the
/// table (screen off, Bluetooth keeps going). Marking a hand is optional,
/// tucked under "Edit a hand (optional)".
class PlayerPadScreen extends StatefulWidget {
  const PlayerPadScreen({super.key});
  @override
  State<PlayerPadScreen> createState() => _PlayerPadScreenState();
}

/// The optional hand editor's copy.
const padOptionalLine = 'Optional: mark a hand you care about. Untapped hands are not recorded.';

class _PlayerPadScreenState extends State<PlayerPadScreen> {
  List<int>? _cards;
  bool _refreshing = false;
  Timer? _tick;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    // The service asks the cloud every 45 s whether the host ended (also
    // when this screen is not showing) and says so here.
    _svc.hostEnded.addListener(_onHostEnded);
    _refresh();
    // The status line says "2 min ago": keep it honest.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  /// The host ended the game (their log says so): say it and go back.
  void _onHostEnded() {
    if (_leaving || !mounted) return;
    final msg = _svc.takeHostEnded();
    if (msg == null) return;
    _leaving = true;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// No cloud: the host's Bluetooth advert for this night has been gone a
  /// while (one tap to leave, never automatic).
  bool get _hostQuiet {
    final s = _svc.night;
    if (s == null || !NearbyService.instance.allowed || (s.cloud != null && _svc.cloudStatus().connected)) return false;
    final heard = NearbyService.instance.hostHeardMs;
    final since = heard ?? (s.log.meta['started'] as int?);
    return since != null && DateTime.now().millisecondsSinceEpoch - since > hostQuietMs;
  }

  @override
  void dispose() {
    _svc.hostEnded.removeListener(_onHostEnded);
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final s = _svc.night;
    if (s == null) return;
    setState(() => _refreshing = true);
    await s.refresh();
    if (mounted) setState(() => _refreshing = false);
    if (mounted) await _svc.checkHostEnded(fetch: false);
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
        final st = PadStats.of(m, me?.pid);
        return Scaffold(
          appBar: AppBar(
            title: Text(_svc.tableName()),
            actions: [
              IconButton(
                tooltip: 'Show the table on this screen (TV)',
                icon: const Icon(Icons.tv),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    fullscreenDialog: true, builder: (_) => TvScreen(ticket: s.ticket, castUrl: tvUrl(s.ticket)))),
              ),
            ],
          ),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            if (_svc.isCamera)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('This phone is in the game as the camera (Record the table), not as a player.',
                    style: t.bodyMedium),
              ),
            if (_hostQuiet)
              Card(
                key: const Key('host-quiet'),
                child: ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text("The host's game seems to have ended"),
                  subtitle: const Text('Their phone has not been heard for 5 minutes.'),
                  trailing: TextButton(
                    onPressed: () async {
                      final nav = Navigator.of(context);
                      await _svc.leave();
                      nav.popUntil((r) => r.isFirst);
                    },
                    child: const Text('Leave'),
                  ),
                ),
              ),
            // ---- the one thing to do: nothing (put the phone down)
            FilledButton.icon(
              key: const Key('table-mode'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(76),
                textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              onPressed: () => openTableMode(context),
              icon: const Icon(Icons.dark_mode_outlined, size: 28),
              label: const Text('Leave it on the table'),
            ),
            const SizedBox(height: 6),
            Text(
                NearbyService.instance.allowed
                    ? 'Screen off, keeps sending Bluetooth for the seat radar. You never need to tap anything.'
                    : 'Screen off. You never need to tap anything.',
                style: t.bodyMedium),
            const SizedBox(height: 14),
            CloudStatusRow(status: _svc.cloudStatus()),
            const SizedBox(height: 12),
            JoinerSharingTile(
                value: s.sharing,
                onChanged: (v) => _svc.setSharing(v),
                seat: s.sharingSeat,
                onSeatChanged: (v) => _svc.setSharingSeat(v)),
            const SizedBox(height: 12),
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
                  if (st.dealt == 0)
                    Text(plays == 0
                        ? "Your hand count appears once the organizer's phone has uploaded the hands."
                        : '$plays marked so far. Your hand count appears once the '
                            "organizer's phone has uploaded the hands.")
                  else
                    Text('${st.dealt} hands · ${st.marked} marked · VPIP ${st.vpipText} · PFR ${st.pfrText}'
                        '${st.marked == 0 ? '' : ' (of marked hands)'}',
                        key: const Key('pad-stats')),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            // ---- optional: mark a hand
            Card(
              child: ExpansionTile(
                key: const Key('pad-edit'),
                initiallyExpanded: false,
                shape: const Border(),
                collapsedShape: const Border(),
                leading: const Icon(Icons.edit_note),
                title: Text('Edit a hand (optional)', style: t.titleSmall),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  Text(padOptionalLine, style: t.bodyMedium),
                  const SizedBox(height: 12),
                  Row(children: [
                    for (final a in const [PreAction.call, PreAction.raise]) ...[
                      if (a == PreAction.raise) const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Felt.actionColor(preActionLabels[a]!, Theme.of(context).brightness),
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(64),
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
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => _do(s.undoLast),
                          icon: const Icon(Icons.undo, size: 18),
                          label: const Text('Undo last tap', overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
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
                    s.sharing && DevSettings.cardsToCloud
                        ? 'Cards are optional. Add them before your tap; they go to the table only 20 minutes later.'
                        : 'Cards are optional, for your own stats; they stay on this phone.',
                    style: t.bodySmall,
                  ),
                ],
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
    // Picks up roster changes. The QR itself is stable: it carries no clock
    // (see [stableQrTicket]), so redrawing does not change the pattern.
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
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
    final ticket = stableQrTicket(s.qrTicket(roster: rosterOf(widget.session)));
    final url = tvUrl(ticket);
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Players: scan this once', style: t.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(10),
              child: QrImageView(
                  key: const Key('sheet-qr'), data: ticket.encode(), size: 220, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(height: 6),
          Center(child: SelectableText(ticket.code, style: t.headlineSmall)),
          Text("On Play: Join, or Scan the host's code. No app? You log their hands.",
              style: t.bodySmall, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          ListenableBuilder(listenable: _svc, builder: (context, _) => CloudStatusRow(status: _svc.cloudStatus())),
          const SizedBox(height: 8),
          const NearbyHostTile(),
          const Divider(height: 20),
          // Secondary rows: TV, radar, sharing. The primary action is
          // Start playing at the bottom.
          ListTile(
            key: const Key('show-on-tv'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cast),
            title: const Text('Show on the TV'),
            subtitle: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              tooltip: 'Copy the TV link',
              icon: const Icon(Icons.copy, size: 20),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('TV link copied')));
              },
            ),
            onTap: () => showOnTvSheet(context, url),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.radar),
            title: const Text('Seat radar'),
            subtitle: const Text('Who sits where, from the phones'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openRadar(context),
          ),
          ListenableBuilder(
            listenable: _svc,
            builder: (context, _) => ExpansionTile(
              key: const Key('sheet-sharing'),
              dense: true,
              tilePadding: EdgeInsets.zero,
              shape: const Border(),
              collapsedShape: const Border(),
              leading: Icon(_svc.sharing ? Icons.cloud_upload_outlined : Icons.cloud_off_outlined),
              title: Text(_svc.sharing ? 'Sharing with the table: on' : 'Sharing with the table: off'),
              subtitle: Text(_svc.statusLine(), maxLines: 1, overflow: TextOverflow.ellipsis),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SharingTile(value: _svc.sharing, onChanged: _svc.setSharing),
                SeatSignalsTile(value: _svc.sharingSeat, onChanged: _svc.setSharingSeat),
                if (!_svc.sharing)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                        'As the organizer, the hand count, dealer, seating, board and blind clock still go up, '
                        'so the TV keeps working.',
                        style: t.bodySmall),
                  ),
                Row(children: [
                  Expanded(child: Text(_svc.statusLine(), style: t.bodySmall)),
                  TextButton(onPressed: _svc.flush, child: const Text('Upload now')),
                ]),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      fullscreenDialog: true, builder: (_) => TvScreen(ticket: ticket, castUrl: url))),
                  icon: const Icon(Icons.tv),
                  label: const Text('Preview the TV on this phone'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('sheet-start-playing'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: cs.primary),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start playing'),
          ),
        ]),
      ),
    );
  }
}

/// The QR without the organizer's clock reading. With the clock the code
/// changed every second (it looked broken); without it the pattern only
/// changes with the roster. A joiner's clock offset then comes from the
/// server-time measurement every uploading phone makes (the typed-code
/// path); phone clocks are network-synced anyway.
JoinTicket stableQrTicket(JoinTicket t) =>
    JoinTicket(nightId: t.nightId, secret: t.secret, organizerName: t.organizerName, roster: t.roster);

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
          if (s == null) ...[
            const SizedBox(height: 8),
            const FindNearbyButton(),
          ],
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
///
/// However the sheet closes (Start playing, or swiped away), the game then
/// goes straight into Watch my cards when Settings says so.
Future<void> afterGameNightStart(NavigatorState nav, HomeGameModel model) async {
  final s = model.active;
  if (s == null) return;
  if (_svc.ready && _svc.startWithTableNight) {
    await _svc.organize(s);
    if (nav.mounted) await maybeAskUwb(nav.context);
    if (nav.mounted) await showTableNightSheet(nav.context, s);
  }
  if (nav.mounted && model.active == s) await requestAutoWatch();
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
