// The Pulse screen: dark and dim, keeps the phone awake (so the app stays
// in the foreground and keeps reading the watch on both OSes), shows the
// heart rate big, the watch's state, and the sharing switch. The host of a
// Pulse night also gets the join QR, the TV link and End.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../pulse/pulse_profile.dart';
import '../../pulse/pulse_service.dart';
import '../../sync/night_events.dart';
import '../../sync/table_night_service.dart';
import '../theme.dart';
import '../tv/show_on_tv.dart';
import '../tv/tv_screen.dart';
import 'pulse_profile_screen.dart';
import 'pulse_widgets.dart';

const _bg = Colors.black;
const _dim = Color(0xFF7D8C84);
const _text = Color(0xFFB8C4BD);

Future<void> openPulseScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PulseScreen()));

/// Play → "Start a Pulse night": a night with no hand logger behind it,
/// this phone sharing, then the Pulse screen (QR to invite on it).
Future<void> startPulseNight(BuildContext context, String hostName) async {
  final tn = TableNightService.instance;
  final s = await tn.organizeStandalone(hostName);
  await s.log.setMeta(pulseNightKey, true);
  // A seat for the host marks this phone as the organizer for the TV (it
  // has no hands to go by), so the TV knows when the night ends.
  if (s.isOrganizer && !s.log.events.any((e) => e.kind == EventKind.seats)) {
    await s.setSeats([Seat('host', hostName)]);
  }
  final svc = PulseService.instance;
  await svc.follow(s);
  if (context.mounted) await turnPulseOn(context);
  if (context.mounted && !svc.on) await openPulseScreen(context);
}

class PulseScreen extends StatefulWidget {
  /// Tests: no wakelock plugin.
  final bool keepAwake;
  const PulseScreen({super.key, this.keepAwake = true});

  @override
  State<PulseScreen> createState() => _PulseScreenState();
}

class _PulseScreenState extends State<PulseScreen> {
  PulseService get svc => PulseService.instance;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.keepAwake) unawaited(WakelockPlus.enable().catchError((_) {}));
    unawaited(svc.refreshStatus());
    // "sent 12 s ago" and the watch state stay honest.
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (widget.keepAwake) unawaited(WakelockPlus.disable().catchError((_) {}));
    super.dispose();
  }

  Future<void> _end() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('End the Pulse night?'),
        content: const Text('The TV shows the night\'s summary. Heart rates stay with the night until it expires.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('End')),
        ],
      ),
    );
    if (ok != true) return;
    await svc.flush();
    await TableNightService.instance.endStandalone();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Felt.darkOnly(ListenableBuilder(
      listenable: Listenable.merge([svc, PulseProfileStore.profile]),
      builder: (context, _) {
        final s = svc.night;
        final t = Theme.of(context).textTheme;
        final p = PulseProfileStore.profile.value;
        final host = s != null && s.isOrganizer && svc.pulseNight;
        final fresh = svc.bpmAtMs != null && svc.now() - svc.bpmAtMs! < 30000;
        return Scaffold(
          backgroundColor: _bg,
          appBar: AppBar(
            backgroundColor: _bg,
            foregroundColor: _text,
            title: const Text('Pulse'),
            actions: [
              if (s != null)
                IconButton(
                  tooltip: 'Show the table on this screen (TV)',
                  icon: const Icon(Icons.tv),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      fullscreenDialog: true, builder: (_) => TvScreen(ticket: s.ticket, castUrl: tvUrl(s.ticket)))),
                ),
            ],
          ),
          body: s == null
              ? const Center(child: Text('Not in a table night.', style: TextStyle(color: _text)))
              : ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
                  Row(children: [
                    FaceCircle(face: p?.face, name: p?.name ?? s.myName, colour: const Color(0xFF3987E5), size: 56),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p?.name ?? s.myName, style: t.titleLarge?.copyWith(color: _text)),
                        Text(p?.song == null ? 'No song picked' : '♪ ${p!.song!.title} · ${p.song!.artist}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: _dim)),
                      ]),
                    ),
                    TextButton(
                      key: const Key('pulse-edit-profile'),
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PulseProfileScreen())),
                      child: const Text('Edit'),
                    ),
                  ]),
                  const SizedBox(height: 28),
                  Center(
                    child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic, children: [
                      Icon(Icons.favorite, color: fresh ? const Color(0xFFB03A3A) : _dim, size: 40),
                      const SizedBox(width: 12),
                      Text(fresh ? '${svc.bpm}' : '--',
                          key: const Key('pulse-bpm'),
                          style: const TextStyle(
                              color: _text, fontSize: 96, fontWeight: FontWeight.w300,
                              fontFeatures: [FontFeature.tabularFigures()])),
                      const SizedBox(width: 8),
                      const Text('bpm', style: TextStyle(color: _dim, fontSize: 22)),
                    ]),
                  ),
                  const SizedBox(height: 4),
                  Center(child: Text(svc.statusLine(), key: const Key('pulse-status'), style: t.bodyMedium?.copyWith(color: _dim))),
                  const SizedBox(height: 24),
                  _WatchCard(svc: svc),
                  const SizedBox(height: 12),
                  Theme(
                    data: Theme.of(context).copyWith(cardTheme: const CardTheme(color: Color(0xFF111614))),
                    child: const PulseShareTile(),
                  ),
                  if (host) ...[const SizedBox(height: 12), _HostCard(onEnd: _end)],
                  const SizedBox(height: 16),
                  Text('Put the phone down with the screen on; it stays dim and keeps reading your watch.',
                      style: t.bodySmall?.copyWith(color: _dim), textAlign: TextAlign.center),
                ]),
        );
      },
    ));
  }
}

class _WatchCard extends StatelessWidget {
  final PulseService svc;
  const _WatchCard({required this.svc});

  @override
  Widget build(BuildContext context) {
    final st = svc.status;
    final t = Theme.of(context).textTheme;
    Widget line(bool ok, String yes, String no) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 18, color: ok ? const Color(0xFF199E70) : _dim),
            const SizedBox(width: 8),
            Expanded(child: Text(ok ? yes : no, style: t.bodyMedium?.copyWith(color: _text))),
          ]),
        );
    return Card(
      color: const Color(0xFF111614),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Watch', style: t.titleMedium?.copyWith(color: _text)),
          const SizedBox(height: 6),
          if (!st.supported)
            Text('No watch connection on this phone (or this build).', style: t.bodyMedium?.copyWith(color: _dim))
          else ...[
            line(st.paired, 'Paired', 'No watch paired'),
            line(st.appInstalled, 'Felt Notes is on the watch', 'Felt Notes is not on the watch yet'),
            line(st.reachable, 'Connected', 'Not connected (open Felt Notes on the watch)'),
            line(svc.watchRunning, 'Measuring', svc.watchErr == 'no_permission'
                ? 'Not measuring: allow heart rate on the watch'
                : 'Not measuring'),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (st.supported && st.paired && !st.appInstalled)
              FilledButton.icon(
                key: const Key('pulse-install'),
                onPressed: () async {
                  final ok = await svc.openWatchStore();
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Open the Play Store (or the Watch app on iPhone) and install Felt Notes on the watch.')));
                  }
                },
                icon: const Icon(Icons.watch),
                label: const Text('Install on watch'),
              ),
            if (svc.on)
              svc.watchRunning
                  ? OutlinedButton.icon(
                      key: const Key('pulse-stop'),
                      onPressed: svc.stopWatch,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'))
                  : FilledButton.tonalIcon(
                      key: const Key('pulse-start'),
                      onPressed: svc.startWatch,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start')),
            TextButton(onPressed: svc.refreshStatus, child: const Text('Check again')),
          ]),
        ]),
      ),
    );
  }
}

/// The host of a Pulse night: invite (QR + code), TV link, End.
class _HostCard extends StatelessWidget {
  final VoidCallback onEnd;
  const _HostCard({required this.onEnd});

  @override
  Widget build(BuildContext context) {
    final s = TableNightService.instance.night!;
    final ticket = s.qrTicket();
    final url = tvUrl(ticket);
    final t = Theme.of(context).textTheme;
    return Card(
      color: const Color(0xFF111614),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Your Pulse night', style: t.titleMedium?.copyWith(color: _text)),
          const SizedBox(height: 6),
          ExpansionTile(
            key: const Key('pulse-invite'),
            tilePadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            iconColor: _text,
            collapsedIconColor: _text,
            leading: const Icon(Icons.qr_code_2, color: _text),
            title: Text('Invite players', style: t.bodyLarge?.copyWith(color: _text)),
            subtitle: Text("On their phone: Play → Scan the host's code", style: t.bodySmall?.copyWith(color: _dim)),
            children: [
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(data: ticket.encode(), size: 200, backgroundColor: Colors.white),
                ),
              ),
              const SizedBox(height: 6),
              Center(child: SelectableText(ticket.code, style: t.titleMedium?.copyWith(color: _text))),
            ],
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cast, color: _text),
            title: Text('Show on the TV', style: t.bodyLarge?.copyWith(color: _text)),
            subtitle: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: _dim)),
            trailing: IconButton(
              tooltip: 'Copy the TV link',
              icon: const Icon(Icons.copy, size: 20, color: _text),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('TV link copied')));
              },
            ),
            onTap: () => showOnTvSheet(context, url),
          ),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            key: const Key('pulse-end'),
            onPressed: onEnd,
            icon: const Icon(Icons.flag_outlined),
            label: const Text('End the night'),
          ),
        ]),
      ),
    );
  }
}
