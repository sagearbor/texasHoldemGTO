// Multi-phone table night: the QR join at the start of the night.
//
// Organizer: shows a QR (redrawn every second so it carries a fresh clock
// reading) and the same code as text. Players: take a photo of the QR
// (ML Kit barcode reader, on-device) or paste the code (web, or a phone
// without a camera). After that each phone works offline; the dealer
// bookkeeping screens (seats, next hand) are built on the effortless-input
// branch and call TableSync. The small player pad here is a stand-in.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../homegame/home_game.dart';
import '../../sync/cloud_config.dart';
import '../../sync/event_log.dart';
import '../../sync/night_events.dart';
import '../../sync/table_sync.dart';

/// Debug builds, or --dart-define=FELT_TABLE_NIGHT=true.
const tableNightUiEnabled = kDebugMode || bool.fromEnvironment('FELT_TABLE_NIGHT');

class TableNightScreen extends StatefulWidget {
  const TableNightScreen({super.key});
  @override
  State<TableNightScreen> createState() => _TableNightScreenState();
}

class _TableNightScreenState extends State<TableNightScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  JoinTicket? _scanned;
  int? _scannedAt;
  String? _claim;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _organize() async {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Enter your name first.');
    setState(() => _busy = true);
    final store = await SharedPrefsStore.open();
    final cloud = await openCloud();
    final sync = await LocalTableSync.organize(store,
        organizerName: name, selfPid: 'p1', roster: [Seat('p1', name)], cloud: cloud);
    sync.startSync();
    if (!mounted) return;
    setState(() => _busy = false);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrganizerQrScreen(sync: sync)));
  }

  Future<void> _scan() async {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera, requestFullMetadata: false);
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
      setState(() => _error = 'Could not read the photo ($e). Paste the code instead.');
    } finally {
      await scanner.close();
    }
  }

  Future<void> _join() async {
    final t = _scanned ?? JoinTicket.parse(_code.text);
    final name = _name.text.trim();
    if (t == null) return setState(() => _error = 'That is not a join code.');
    if (name.isEmpty) return setState(() => _error = 'Enter your name first.');
    setState(() => _busy = true);
    final store = await SharedPrefsStore.open();
    final cloud = await openCloud();
    final sync = await LocalTableSync.join(store, t,
        name: name,
        claimPid: _claim,
        scannedAtMs: _scanned != null ? _scannedAt! : DateTime.now().millisecondsSinceEpoch,
        cloud: cloud);
    sync.startSync();
    if (!mounted) return;
    setState(() => _busy = false);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerPadScreen(sync: sync)));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ticket = _scanned;
    return Scaffold(
      appBar: AppBar(title: const Text('Table night (beta)')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
          'Everyone logs on their own phone. No signal needed at the table: '
          'each phone keeps its own notes and uploads them later.'
          '${cloudSyncEnabled ? '' : '\n\nThis build is local-only (no cloud configured).'}',
          style: t.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Your name')),
        const SizedBox(height: 20),
        Text('Organizing tonight?', style: t.titleMedium),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _organize,
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Show the join QR'),
        ),
        const SizedBox(height: 24),
        Text('Joining?', style: t.titleMedium),
        const SizedBox(height: 8),
        if (!kIsWeb)
          OutlinedButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text("Photograph the organizer's QR"),
          ),
        if (ticket != null) ...[
          const SizedBox(height: 8),
          Text('Found ${ticket.organizerName.isEmpty ? 'a' : "${ticket.organizerName}'s"} table.'),
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
                    if (v && _name.text.trim().isEmpty) _name.text = s.name;
                  }),
                ),
            ]),
          ],
        ] else ...[
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            decoration: const InputDecoration(labelText: 'Or paste the code (ABCD2345-WXYZ6789)'),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton(onPressed: _busy ? null : _join, child: const Text('Join')),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ]),
    );
  }
}

/// The organizer's QR, redrawn every second with a fresh clock reading.
class OrganizerQrScreen extends StatefulWidget {
  final TableSync sync;
  const OrganizerQrScreen({super.key, required this.sync});
  @override
  State<OrganizerQrScreen> createState() => _OrganizerQrScreenState();
}

class _OrganizerQrScreenState extends State<OrganizerQrScreen> {
  late Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ticket = widget.sync.qrTicket();
    return Scaffold(
      appBar: AppBar(title: const Text('Join tonight’s table')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(data: ticket.encode(), size: 260, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 16),
            SelectableText(ticket.code, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('Each player photographs this once, at the start.', textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}

/// Stand-in player pad: one tap per played hand, optional sharing.
class PlayerPadScreen extends StatefulWidget {
  final LocalTableSync sync;
  const PlayerPadScreen({super.key, required this.sync});
  @override
  State<PlayerPadScreen> createState() => _PlayerPadScreenState();
}

class _PlayerPadScreenState extends State<PlayerPadScreen> {
  Future<void> _do(Future<void> Function() f) async {
    await f();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sync;
    final plays = s.localEvents.where((e) => e.kind == EventKind.play).length;
    final up = s.uploader;
    final status = up == null
        ? 'Saved on this phone (local-only build).'
        : up.pending
            ? 'Saved on this phone; will upload when there is a connection.'
            : 'Uploaded.';
    return Scaffold(
      appBar: AppBar(title: Text("${s.ticket.organizerName.isEmpty ? 'Table' : "${s.ticket.organizerName}'s table"} · night ${s.nightId}")),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Tap only when you put money in. Every other hand counts as a fold.',
            style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
              child: FilledButton(
                  onPressed: () => _do(() => s.tap(PreAction.call)), child: const Text('Call'))),
          const SizedBox(width: 12),
          Expanded(
              child: FilledButton(
                  onPressed: () => _do(() => s.tap(PreAction.raise)), child: const Text('Raise'))),
        ]),
        const SizedBox(height: 8),
        TextButton(onPressed: () => _do(s.undoLast), child: const Text('Undo last tap')),
        SwitchListTile(
          title: const Text('Share my cards with the table'),
          subtitle: const Text('Off: your cards never leave this phone.'),
          value: s.sharing,
          onChanged: (v) => _do(() => s.setSharing(v)),
        ),
        const SizedBox(height: 8),
        Text('$plays taps tonight. $status'),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () async {
            await s.leave();
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('I’m leaving'),
        ),
      ]),
    );
  }
}
