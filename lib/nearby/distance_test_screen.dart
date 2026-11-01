/// Bluetooth distance test (Settings → Diagnostics): open it on two or more
/// phones, put them a known distance apart, record 60 seconds, repeat at
/// other distances and placements, export the JSONL to the Mac and run
/// tool/positioning/calibrate.py. Works outside any game. While open, this
/// screen owns Bluetooth: the phone advertises its install id (and model)
/// and scans without pause; the game loop is paused until it closes.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../record/record_log.dart';
import '../record/record_native.dart' show deviceInfo;
import '../sync/event_log.dart';
import 'ble_payload.dart';
import 'distance_test.dart';
import 'nearby_ble.dart';
import 'nearby_service.dart';
import 'nearby_ui.dart' show askBluetooth;

const _runSeconds = 60;

class DistanceTestScreen extends StatefulWidget {
  const DistanceTestScreen({super.key});
  @override
  State<DistanceTestScreen> createState() => _DistanceTestScreenState();
}

class _DistanceTestScreenState extends State<DistanceTestScreen> {
  String? _error;
  String? _me;
  String? _model;
  bool _scanning = false;
  StreamSubscription<Map<String, Object?>>? _sub;
  Timer? _tick;
  final Map<String, RollingRssi> _peers = {};
  final Map<String, String> _models = {};

  File? _file;
  RecordLogWriter? _log;
  final Stopwatch _clock = Stopwatch()..start();

  double _distance = 1.0;
  Placement _placement = Placement.tableUp;
  int? _run; // run id (start ms) while recording
  int _left = 0;
  final Map<String, List<int>> _runSamples = {};
  final List<String> _results = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    bleScanStop();
    WakelockPlus.disable();
    NearbyService.instance.resumeAfterTest();
    super.dispose();
  }

  Future<void> _start() async {
    if (!bleSupported) return setState(() => _error = 'Bluetooth is only on the phone apps.');
    if (!await askBluetooth(context)) {
      if (mounted) setState(() => _error = 'Bluetooth is not allowed.');
      return;
    }
    NearbyService.instance.pauseForTest();
    try {
      final store = await SharedPrefsStore.open();
      _me = await deviceIdFor(store);
      final dev = await deviceInfo();
      _model = dev?['model'] as String?;
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/bt_distance');
      await dir.create(recursive: true);
      final d = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      _file = File('${dir.path}/bt-distance-${d.year}${two(d.month)}${two(d.day)}-${_me!.substring(8)}.jsonl');
      _log = RecordLogWriter(FileLineSink(_file!),
          wallMs: () => DateTime.now().millisecondsSinceEpoch, elapsedMs: () => _clock.elapsedMilliseconds);
      _log!.write('open', {'obs': _me, 'obs_model': _model, 'os': dev?['os'], 'platform': Platform.operatingSystem});
      // Night tag 0: no game. The model rides as the name.
      final ok = await bleAdvertise(advertUuid(PresenceAdvert(_me!, 0)), name: _model ?? 'phone');
      _sub = bleEvents().listen(_onEvent);
      _scanning = await bleScanStart();
      WakelockPlus.enable();
      if (!mounted) return;
      setState(() => _error = !_scanning
          ? 'Could not start scanning (is Bluetooth on?).'
          : ok
              ? null
              : 'Scanning, but this phone could not advertise.');
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start ($e)');
    }
  }

  void _onEvent(Map<String, Object?> e) {
    if (e['type'] != 'adv') return;
    final s = BleSighting.fromMap(e);
    final a = s?.advert;
    if (s == null || a == null || a.peerKey == 'D:$_me') return;
    final key = a.peerKey;
    (_peers[key] ??= RollingRssi()).add(s.ms, s.rssi);
    final name = s.hostName;
    if (name != null) _models[key] = name;
    final run = _run;
    if (run != null) {
      (_runSamples[key] ??= []).add(s.rssi);
      _write('sample', sampleLine(
        run: run,
        heardMs: s.ms,
        observer: _me!,
        observerModel: _model,
        peer: key,
        peerModel: _models[key],
        rssi: s.rssi,
        txPower: s.txPower,
        distanceM: _distance,
        placement: _placement,
      ));
    }
  }

  void _write(String k, Map<String, Object?> f) {
    try {
      _log?.write(k, f);
    } catch (_) {}
  }

  void _onTick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final p in _peers.values) {
      p.trim(now);
    }
    if (_run != null) {
      _left--;
      if (_left <= 0) _finishRun();
    }
    if (mounted) setState(() {});
  }

  void _startRun() {
    _runSamples.clear();
    _run = DateTime.now().millisecondsSinceEpoch;
    _left = _runSeconds;
    _write('run_start', {'run': _run, 'd_m': _distance, 'place': _placement.name, 'obs': _me});
    setState(() {});
  }

  void _finishRun() {
    final run = _run;
    if (run == null) return;
    _run = null;
    final lines = <String>[];
    for (final e in _runSamples.entries) {
      final st = RunStats.of(e.value);
      if (st == null) continue;
      _write('run_summary', {
        'run': run,
        'peer': e.key,
        'peer_model': _models[e.key],
        'd_m': _distance,
        'place': _placement.name,
        'n': st.n,
        'median': st.median,
        'std': double.parse(st.std.toStringAsFixed(2)),
      });
      lines.add('${_label(e.key)}: $st');
    }
    _results.insert(
        0,
        '${_distance.toStringAsFixed(2)} m · ${placementLabels[_placement]}\n'
        '${lines.isEmpty ? 'no Felt Notes phone heard' : lines.join('\n')}');
    if (mounted) setState(() {});
  }

  String _label(String key) => '${shortPeer(key)}${_models[key] == null ? '' : ' (${_models[key]})'}';

  Future<void> _export() async {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
    await Share.shareXFiles([XFile(f.path, mimeType: 'application/x-ndjson')], sharePositionOrigin: origin);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final peers = _peers.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final recording = _run != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth distance test'),
        actions: [IconButton(tooltip: 'Export the log', onPressed: _file == null ? null : _export, icon: const Icon(Icons.ios_share))],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
            'Open this on two or more phones. This phone is ${_me == null ? '…' : shortPeer(_me!)}'
            '${_model == null ? '' : ' ($_model)'}. Keep the screens on.',
            style: t.bodyMedium),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 12),
        Text('Felt Notes phones heard', style: t.titleSmall),
        if (peers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_scanning ? 'None yet…' : '—', style: t.bodySmall),
          ),
        for (final e in peers)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(_label(e.key)),
            subtitle: Text('${e.value.rate.toStringAsFixed(1)}/s · ${e.value.total} heard'),
            trailing: Text(
                '${e.value.latest ?? '—'} dBm\nmedian ${e.value.median10?.toStringAsFixed(1) ?? '—'}',
                textAlign: TextAlign.right,
                style: t.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        const Divider(height: 28),
        Text('Measure', style: t.titleSmall),
        Row(children: [
          const Expanded(child: Text('True distance')),
          IconButton.outlined(
            tooltip: 'Closer',
            onPressed: recording ? null : () => setState(() => _distance = stepDistance(_distance, -1)),
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
              width: 72, child: Text('${_distance.toStringAsFixed(2)} m', textAlign: TextAlign.center, style: t.titleMedium)),
          IconButton.outlined(
            tooltip: 'Farther',
            onPressed: recording ? null : () => setState(() => _distance = stepDistance(_distance, 1)),
            icon: const Icon(Icons.add),
          ),
        ]),
        Wrap(spacing: 6, children: [
          for (final p in Placement.values)
            ChoiceChip(
              label: Text(placementLabels[p]!),
              selected: _placement == p,
              onSelected: recording ? null : (_) => setState(() => _placement = p),
            ),
        ]),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: !_scanning ? null : (recording ? _finishRun : _startRun),
          icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record),
          label: Text(recording ? 'Recording… $_left s (tap to stop early)' : 'Record $_runSeconds s'),
        ),
        const SizedBox(height: 12),
        for (final r in _results)
          Card(child: Padding(padding: const EdgeInsets.all(10), child: Text(r, style: t.bodySmall))),
        if (_file != null)
          Text('Log: ${_file!.path.split('/').last} (Export at the top right)', style: t.bodySmall),
      ]),
    );
  }
}
