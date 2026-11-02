/// Live seat radar on the organizer's phone (game-night menu). Players do
/// nothing: their phones already upload a minute of Bluetooth readings at
/// a time. Every 30 s this fetches the night's logs once, rebuilds the
/// estimate (radar_model.dart) and draws it. The player count and the
/// per-end seats are right on top and can change any time as people come
/// and go (each change is logged with its time, and Record the table
/// follows). Without the cloud it falls back to this phone's own scans:
/// distance from this phone only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../nearby/nearby_service.dart';
import '../sync/table_night_service.dart';
import '../ui/app_settings.dart';
import 'radar_model.dart';
import 'radar_settings.dart';
import 'radar_view.dart';

Future<void> openRadar(BuildContext context) async {
  await RadarSettings.load();
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RadarScreen()));
}

/// The estimate off the UI thread (an isolate on phones; on the web,
/// compute runs it inline).
RadarEstimate _estimate((RadarConfig, RadarInput) a) => estimateSeats(a.$1, a.$2);

class RadarScreen extends StatefulWidget {
  /// Tests: no timer, no fetch.
  final bool live;
  const RadarScreen({super.key, this.live = true});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  Timer? _timer;
  RadarInput _input = const RadarInput();
  RadarEstimate? _est;
  int? _updatedMs;
  bool _busy = false;
  bool _offline = false;
  Map<String, double> _mine = const {};

  TableNightService get _tn => TableNightService.instance;

  @override
  void initState() {
    super.initState();
    RadarSettings.config.addListener(_onConfig);
    if (widget.live) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _update(fetch: true));
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _askPlaying();
        await _update(fetch: true);
      });
    } else {
      _update(fetch: false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    RadarSettings.config.removeListener(_onConfig);
    super.dispose();
  }

  /// A new player count / end setting: re-layout now, estimate again
  /// from the readings already in hand.
  void _onConfig() {
    setState(() {});
    _update(fetch: false);
  }

  /// The organizer's phone is a player's phone (hand-logger organizer, not
  /// the camera): pinned to the organizer's seat, a second anchor.
  RadarConfig get _cfg {
    final c = RadarSettings.config.value;
    final n = _tn.night;
    final orgPhone = n != null && n.isOrganizer && !_tn.isCamera && !_tn.standalone && !NearbyService.instance.camera;
    return c.copyWith(organizerDevice: () => orgPhone && c.organizerSeat != null ? n.deviceId : null);
  }

  Future<void> _askPlaying() async {
    final asked = await RadarSettings.askedPlaying();
    if (asked || !mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Are you playing at this table?'),
        content: const Text('Then your seat is the one next to the camera (seat 1). You can change it in the table setup.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Yes, seat 1')),
        ],
      ),
    );
    await RadarSettings.setAskedPlaying();
    if (yes != null) {
      await RadarSettings.set(RadarSettings.config.value.copyWith(organizerSeat: () => yes ? 0 : null), why: 'organizer seat');
    }
  }

  Future<void> _update({required bool fetch}) async {
    if (_busy) return;
    _busy = true;
    try {
      final n = _tn.night;
      if (n != null && fetch) await n.refresh();
      final now = DateTime.now().millisecondsSinceEpoch;
      final logs = n?.allLogs ?? const [];
      final input = radarInputFrom(logs).live(now);
      // Online: someone else's readings reached us.
      final others = input.links.any((l) => l.from != n?.deviceId);
      _offline = !others;
      _mine = NearbyService.instance.recentPeers;
      final est = others ? await compute(_estimate, (_cfg, input)) : null;
      if (!mounted) return;
      setState(() {
        _input = input;
        _est = est;
        _updatedMs = now;
      });
    } catch (e) {
      debugPrint('radar: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _setup() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _SetupSheet(),
    );
  }

  void _readings(String phone) {
    final names = _input.names;
    String nm(String d) => names[d] ?? d.substring(0, d.length.clamp(0, 4));
    final out = [for (final l in _input.links) if (l.from == phone) l]..sort((a, b) => b.rssi.compareTo(a.rssi));
    final inn = [for (final l in _input.links) if (l.to == phone) l]..sort((a, b) => b.rssi.compareTo(a.rssi));
    final uwb = [for (final e in _input.uwb.entries) if (e.key.split('|').contains(phone)) e];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), shrinkWrap: true, children: [
          Text(nm(phone), style: Theme.of(c).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('It hears (stronger = closer):', style: Theme.of(c).textTheme.labelLarge),
          if (out.isEmpty) const Text('nothing uploaded yet'),
          for (final l in out) Text('${nm(l.to)}${_input.cameras.contains(l.to) ? ' (camera)' : ''}: ${l.rssi.round()} dBm · ${l.n} readings'),
          const SizedBox(height: 8),
          Text('Heard by:', style: Theme.of(c).textTheme.labelLarge),
          if (inn.isEmpty) const Text('nobody yet'),
          for (final l in inn) Text('${nm(l.from)}${_input.cameras.contains(l.from) ? ' (camera)' : ''}: ${l.rssi.round()} dBm · ${l.n} readings'),
          if (uwb.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('UWB (iPhone to iPhone):', style: Theme.of(c).textTheme.labelLarge),
            for (final e in uwb)
              Text('${nm(e.key.split('|').firstWhere((x) => x != phone))}: ${(e.value / feetToM).toStringAsFixed(1)} ft'),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cfg = RadarSettings.config.value;
    final est = _est;
    final colours = radarColours(est?.probs.keys ?? const []);
    final age = _input.newestMs == null || _updatedMs == null ? null : (_updatedMs! - _input.newestMs!) ~/ 1000;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Seat radar'),
        actions: [
          IconButton(tooltip: 'Table setup', onPressed: _setup, icon: const Icon(Icons.tune)),
          IconButton(tooltip: 'Update now', onPressed: () => _update(fetch: true), icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        // ---- the count and the ends, always at hand
        Row(children: [
          Expanded(child: Text('Players', style: t.titleMedium)),
          IconButton.outlined(
            key: const Key('radar-fewer'),
            tooltip: 'Fewer',
            onPressed: cfg.seats > 2 ? () => RadarSettings.setSeats(cfg.seats - 1) : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(width: 44, child: Text('${cfg.seats}', key: const Key('radar-count'), style: t.headlineSmall, textAlign: TextAlign.center)),
          IconButton.outlined(
            key: const Key('radar-more'),
            tooltip: 'More',
            onPressed: cfg.seats < 12 ? () => RadarSettings.setSeats(cfg.seats + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ]),
        Row(children: [
          Expanded(child: _EndChoice(label: cfg.camera == CameraAt.end ? 'Camera end' : 'Left end', left: true)),
          const SizedBox(width: 8),
          Expanded(child: _EndChoice(label: cfg.camera == CameraAt.end ? 'Far end' : 'Right end', left: false)),
        ]),
        const SizedBox(height: 10),
        if (est != null && est.notEnough == null) ...[
          RadarView(
            estimate: est,
            names: _input.names,
            colours: colours,
            stale: _input.stale,
            organizerName: cfg.organizerSeat == null || _cfg.organizerDevice != null
                ? null
                : (AppSettings.playerName.value.isEmpty ? 'organizer' : AppSettings.playerName.value),
          ),
          const SizedBox(height: 6),
          RadarLegend(estimate: est, names: _input.names, colours: colours, stale: _input.stale, onTap: _readings),
        ] else
          _Waiting(
            reason: est?.notEnough ?? (_offline ? null : 'Not enough data yet.'),
            offline: _offline,
            mine: _mine,
            names: _input.names,
          ),
        const SizedBox(height: 10),
        Text(
            _updatedMs == null
                ? 'Starting…'
                : 'Updated ${TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(_updatedMs!)).format(context)}'
                    ' · ${_input.phones.difference(_input.cameras).length} phones heard'
                    '${age == null ? '' : ' · data ${age < 90 ? '${age}s' : '${age ~/ 60} min'} old'}',
            key: const Key('radar-legend'),
            style: t.bodySmall),
        Text('Seats are a best guess from Bluetooth signal strength. Solid colour = confident; spread or tinted = unsure. '
            'Grey = no app phone there. Nobody needs to tap anything.',
            style: t.bodySmall),
      ]),
    );
  }
}

class _EndChoice extends StatelessWidget {
  final String label;
  final bool left;
  const _EndChoice({required this.label, required this.left});

  @override
  Widget build(BuildContext context) {
    final c = RadarSettings.config.value;
    final v = left ? c.leftEndSeats : c.rightEndSeats;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 1, label: Text('1 middle')),
          ButtonSegment(value: 2, label: Text('2 corners')),
        ],
        selected: {v},
        showSelectedIcon: false,
        onSelectionChanged: (s) => RadarSettings.set(
            left ? c.copyWith(leftEndSeats: s.first) : c.copyWith(rightEndSeats: s.first),
            why: left ? 'left end' : 'right end'),
      ),
    ]);
  }
}

/// Before there is an estimate: why, and offline the distance from this
/// phone to each phone it hears itself.
class _Waiting extends StatelessWidget {
  final String? reason;
  final bool offline;
  final Map<String, double> mine;
  final Map<String, String> names;
  const _Waiting({required this.reason, required this.offline, required this.mine, required this.names});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final rings = distancesFromMe(mine);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(offline ? 'Offline: distance from you only' : (reason ?? 'Not enough data yet.'),
              key: const Key('radar-waiting'), style: t.titleSmall),
          const SizedBox(height: 4),
          Text(
              offline
                  ? "No other phone's readings have arrived (no connection, or nobody else is in the game yet). "
                      'This is what this phone hears itself.'
                  : 'Phones upload a minute of readings at a time; give it a couple of minutes.',
              style: t.bodySmall),
          if (offline) ...[
            const SizedBox(height: 8),
            if (rings.isEmpty) Text('No Felt Notes phone heard nearby yet.', style: t.bodySmall),
            for (final (key, rssi, m) in rings)
              Text(
                  '${names[key.startsWith('D:') ? key.substring(2) : key] ?? key.substring(key.length - 4)}: '
                  'about ${(m / feetToM).toStringAsFixed(m < 1.2 ? 1 : 0)} ft (${rssi.round()} dBm)'
                  '${m >= 1.2 ? ' or more' : ''}',
                  style: t.bodyMedium),
          ],
        ]),
      ),
    );
  }
}

class _SetupSheet extends StatelessWidget {
  const _SetupSheet();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ValueListenableBuilder<RadarConfig>(
      valueListenable: RadarSettings.config,
      builder: (context, c, _) {
        void set(RadarConfig n, String why) => RadarSettings.set(n, why: why);
        return SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            Text('Table setup (once)', style: t.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<TableShape>(
              segments: const [
                ButtonSegment(value: TableShape.oval, label: Text('Oval')),
                ButtonSegment(value: TableShape.rectangle, label: Text('Rectangle')),
              ],
              selected: {c.shape},
              onSelectionChanged: (s) => set(c.copyWith(shape: s.first), 'shape'),
            ),
            for (final (label, v, minV, maxV, apply) in [
              ('Length', c.lengthFt, 4.0, 16.0, (double x) => c.copyWith(lengthFt: x)),
              ('Width', c.widthFt, 2.5, 8.0, (double x) => c.copyWith(widthFt: x)),
            ])
              Row(children: [
                Expanded(child: Text('$label ${v.toStringAsFixed(1)} ft')),
                IconButton(
                    onPressed: v > minV ? () => set(apply(v - 0.5), label.toLowerCase()) : null,
                    icon: const Icon(Icons.remove)),
                IconButton(
                    onPressed: v < maxV ? () => set(apply(v + 0.5), label.toLowerCase()) : null,
                    icon: const Icon(Icons.add)),
              ]),
            const SizedBox(height: 4),
            Text('Camera phone (Record the table) sits at', style: t.labelLarge),
            SegmentedButton<CameraAt>(
              segments: const [
                ButtonSegment(value: CameraAt.end, label: Text('An end')),
                ButtonSegment(value: CameraAt.side, label: Text('A long side')),
              ],
              selected: {c.camera},
              onSelectionChanged: (s) => set(c.copyWith(camera: s.first), 'camera'),
            ),
            const SizedBox(height: 8),
            Text('Your seat (if you play)', style: t.labelLarge),
            Wrap(spacing: 6, children: [
              ChoiceChip(
                label: const Text('Not playing'),
                selected: c.organizerSeat == null,
                onSelected: (_) => set(c.copyWith(organizerSeat: () => null), 'organizer seat'),
              ),
              for (var k = 0; k < c.seats; k++)
                ChoiceChip(
                  label: Text('${k + 1}'),
                  selected: c.organizerSeat == k,
                  onSelected: (_) => set(c.copyWith(organizerSeat: () => k), 'organizer seat'),
                ),
            ]),
            Text('Seat 1 is next to the camera; numbers go clockwise seen from above.', style: t.bodySmall),
          ]),
        );
      },
    );
  }
}
