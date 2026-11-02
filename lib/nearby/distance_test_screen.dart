/// Bluetooth distance test (Settings → Diagnostics): open it on two or more
/// phones, put them a known distance apart, record 60 seconds, repeat at
/// other distances and placements, export the JSONL to the Mac and run
/// tool/positioning/calibrate.py. Works outside any game. While open, this
/// screen owns Bluetooth: the phone advertises its install id (and model)
/// and scans without pause; the game loop is paused until it closes.
///
/// One log per device (`bt_distance/bt-distance-<id>.jsonl`), append-only:
/// the run list is read back from it, deleting a run appends a `deleted`
/// marker, and Export writes a copy without the deleted runs.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../record/record_log.dart';
import '../record/record_native.dart' show deviceInfo;
import '../ui/app_settings.dart';
import '../sync/event_log.dart';
import 'ble_payload.dart';
import 'distance_test.dart';
import 'nearby_ble.dart';
import 'nearby_service.dart';
import 'nearby_ui.dart' show askBluetooth;

const _runSeconds = 60;
const _unitKey = 'bt_distance_unit_v1';
const _labelKey = 'bt_distance_label_v1';

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
  /// Peer key -> the name it advertises (its phone label).
  final Map<String, String> _models = {};

  /// "Asher's phone": advertised, in every log line and the export name.
  final TextEditingController _labelCtl = TextEditingController();
  String get _phoneLabel => _labelCtl.text.trim().isEmpty ? (_model ?? 'phone') : _labelCtl.text.trim();

  File? _file;
  RecordLogWriter? _log;
  final Stopwatch _clock = Stopwatch()..start();
  List<RunRecord> _runs = const [];

  DistanceUnit _unit = DistanceUnit.metres;
  double _value = defaultOf(DistanceUnit.metres);

  /// The owner set the distance this session (Record stays off until then).
  bool _distanceSet = false;
  Placement _placement = Placement.tableUp;
  int? _run; // run id (start ms) while recording
  int _left = 0;

  double get _metres => metresOf(_unit, _value);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    // Leaving mid-run any other way (app killed is caught on reload: no
    // run_end): this run is incomplete.
    final run = _run;
    if (run != null) _write('run_end', {'run': run, 'complete': false, 'reason': 'left', 'secs': _runSeconds - _left});
    _tick?.cancel();
    _sub?.cancel();
    _labelCtl.dispose();
    bleScanStop();
    WakelockPlus.disable();
    NearbyService.instance.resumeAfterTest();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getString(_labelKey);
      final name = AppSettings.playerName.value;
      _labelCtl.text = saved ?? (name.isEmpty ? '' : "$name's phone");
      final u = unitFromName(p.getString(_unitKey));
      if (u != null && mounted) {
        setState(() {
          _unit = u;
          _value = defaultOf(u);
        });
      }
    } catch (_) {}
    if (!bleSupported) return setState(() => _error = 'Bluetooth is only on the phone apps.');
    if (!mounted) return;
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
      if (_labelCtl.text.isEmpty && _model != null) _labelCtl.text = _model!;
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/bt_distance');
      await dir.create(recursive: true);
      _file = File('${dir.path}/bt-distance-${_me!.substring(8)}.jsonl');
      _log = RecordLogWriter(FileLineSink(_file!),
          wallMs: () => DateTime.now().millisecondsSinceEpoch, elapsedMs: () => _clock.elapsedMilliseconds);
      _reloadRuns();
      _write('open', {'obs': _me, 'obs_model': _model, 'os': dev?['os'], 'platform': Platform.operatingSystem});
      // Night tag 0: no game. The model rides as the name.
      final ok = await _advertise();
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

  /// Night tag 0: no game. The phone's label rides as the name.
  Future<bool> _advertise() => bleAdvertise(advertUuid(PresenceAdvert(_me!, 0)), name: _phoneLabel);

  Future<void> _saveLabel() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_labelKey, _labelCtl.text.trim());
    } catch (_) {}
    _write('label', {'label': _phoneLabel});
    if (_me != null && _scanning) await _advertise();
    if (mounted) setState(() {});
  }

  void _reloadRuns() {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    try {
      _runs = runsFromLog(f.readAsLinesSync());
    } catch (_) {}
  }

  List<RunRecord> get _kept => [for (final r in _runs) if (!r.deleted) r];

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
      _write('sample', sampleLine(
        run: run,
        heardMs: s.ms,
        observer: _me!,
        observerModel: _model,
        peer: key,
        peerModel: _models[key],
        rssi: s.rssi,
        txPower: s.txPower,
        distanceM: _metres,
        placement: _placement,
        unit: _unit,
        entered: _value,
      ));
    }
  }

  void _write(String k, Map<String, Object?> f) {
    try {
      _log?.write(k, {...f, 'observerLabel': _phoneLabel});
    } catch (_) {}
  }

  void _onTick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final p in _peers.values) {
      p.trim(now);
    }
    if (_run != null) {
      _left--;
      if (_left <= 0) _endRun(complete: true, reason: 'time');
    }
    if (mounted) setState(() {});
  }

  void _startRun() {
    _run = DateTime.now().millisecondsSinceEpoch;
    _left = _runSeconds;
    _write('run_start', {
      'run': _run,
      'd_m': _metres,
      'unit': _unit.name,
      'entered': _value,
      'label': distanceLabel(_unit, _value),
      'place': _placement.name,
      'obs': _me,
      'obs_model': _model,
    });
    setState(() {});
  }

  /// [complete]: ran its time or was stopped by the owner; false when the
  /// screen was left mid-run.
  void _endRun({required bool complete, required String reason}) {
    final run = _run;
    if (run == null) return;
    _run = null;
    _write('run_end', {'run': run, 'complete': complete, 'reason': reason, 'secs': _runSeconds - _left});
    _reloadRuns();
    if (mounted) setState(() {});
  }

  void _setDeleted(List<int> ids, bool deleted) {
    _write(deleted ? 'deleted' : 'undeleted', {'runs': ids});
    _reloadRuns();
    if (mounted) setState(() {});
  }

  void _delete(RunRecord r) {
    _setDeleted([r.id], true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Run at ${distanceLabel(r.unit, r.entered)} deleted'),
        action: SnackBarAction(label: 'Undo', onPressed: () => _setDeleted([r.id], false)),
      ));
  }

  Future<void> _clearAll() async {
    final ids = [for (final r in _kept) r.id];
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Clear all runs?'),
        content: Text('All ${ids.length} runs on this phone are left out of the export.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Clear all')),
        ],
      ),
    );
    if (ok == true) _setDeleted(ids, true);
  }

  /// The same copy, saved where the owner picks (Downloads by default).
  Future<void> _saveToPhone() async {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    final name = exportFileName(_phoneLabel, DateTime.now());
    final bytes = Uint8List.fromList(
        utf8.encode('${exportLines(await f.readAsLines()).join('\n')}\n'));
    String? path;
    try {
      path = await FilePicker.platform.saveFile(fileName: name, bytes: bytes);
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(path == null ? 'Not saved' : 'Saved $name')));
  }

  /// A copy of the log without the deleted runs.
  Future<void> _export() async {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
    final name = exportFileName(_phoneLabel, DateTime.now());
    final out = File('${(await getTemporaryDirectory()).path}/$name');
    await out.writeAsString('${exportLines(await f.readAsLines()).join('\n')}\n');
    // The name survives into Messages / AirDrop / Quick Share.
    await Share.shareXFiles([XFile(out.path, name: name, mimeType: 'text/plain')],
        fileNameOverrides: [name], sharePositionOrigin: origin);
  }

  Future<bool> _confirmLeave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Stop this run and leave?'),
        content: const Text('The run so far is kept but marked incomplete.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep recording')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Stop and leave')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _setUnit(DistanceUnit u) async {
    setState(() {
      _value = convertValue(_unit, u, _value);
      _unit = u;
    });
    try {
      await (await SharedPreferences.getInstance()).setString(_unitKey, u.name);
    } catch (_) {}
  }

  String _label(String key) => '${shortPeer(key)}${_models[key] == null ? '' : ' (${_models[key]})'}';

  String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final peers = _peers.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final recording = _run != null;
    final kept = _kept;
    return PopScope(
      // A stray back swipe must not end a run.
      canPop: !recording,
      onPopInvoked: (didPop) async {
        if (didPop || !recording) return;
        final nav = Navigator.of(context);
        if (await _confirmLeave() && mounted) {
          _endRun(complete: false, reason: 'left');
          // pop() itself is not stopped by the PopScope.
          nav.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Bluetooth distance test')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            key: const Key('bt-phone-label'),
            controller: _labelCtl,
            enabled: !recording,
            maxLength: 20,
            decoration: const InputDecoration(
              labelText: "This phone's name",
              helperText: 'Shown on the other phones and in the export file name',
              counterText: '',
              isDense: true,
            ),
            onSubmitted: (_) => _saveLabel(),
            onTapOutside: (_) {
              FocusScope.of(context).unfocus();
              _saveLabel();
            },
          ),
          const SizedBox(height: 8),
          // ---- the setting that matters, first and big
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('1. True distance between the phones', style: t.titleMedium)),
                  SegmentedButton<DistanceUnit>(
                    segments: const [
                      ButtonSegment(value: DistanceUnit.metres, label: Text('m')),
                      ButtonSegment(value: DistanceUnit.feet, label: Text('ft')),
                    ],
                    selected: {_unit},
                    onSelectionChanged: recording ? null : (s) => _setUnit(s.first),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  IconButton.filledTonal(
                    iconSize: 32,
                    tooltip: 'Closer',
                    onPressed: recording
                        ? null
                        : () => setState(() {
                              _value = stepValue(_unit, _value, -1);
                              _distanceSet = true;
                            }),
                    icon: const Icon(Icons.remove),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: recording ? null : () => setState(() => _distanceSet = true),
                      child: Column(children: [
                        Text(distanceLabel(_unit, _value),
                            key: const Key('bt-distance-value'),
                            textAlign: TextAlign.center,
                            style: t.displaySmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: _distanceSet ? null : Theme.of(context).disabledColor)),
                        Text(_distanceSet ? 'set' : 'tap − / + or this number to set it',
                            style: t.bodySmall, textAlign: TextAlign.center),
                      ]),
                    ),
                  ),
                  IconButton.filledTonal(
                    iconSize: 32,
                    tooltip: 'Farther',
                    onPressed: recording
                        ? null
                        : () => setState(() {
                              _value = stepValue(_unit, _value, 1);
                              _distanceSet = true;
                            }),
                    icon: const Icon(Icons.add),
                  ),
                ]),
                const SizedBox(height: 12),
                Text('2. How the phones lie', style: t.titleMedium),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final p in Placement.values)
                    ChoiceChip(
                      label: Text(placementLabels[p]!),
                      selected: _placement == p,
                      onSelected: recording ? null : (_) => setState(() => _placement = p),
                    ),
                ]),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('bt-record'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: !_scanning || (!_distanceSet && !recording)
                      ? null
                      : () => recording ? _endRun(complete: true, reason: 'stopped') : _startRun(),
                  icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(recording
                      ? 'Recording… $_left s (tap to stop)'
                      : !_distanceSet
                          ? 'Set the distance first'
                          : '3. Record $_runSeconds s at ${distanceLabel(_unit, _value)}'),
                ),
              ]),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 12),
          Text(
              'Felt Notes phones heard (this phone: ${_me == null ? '…' : shortPeer(_me!)}'
              '${_model == null ? '' : ', $_model'})',
              style: t.titleSmall),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_scanning ? 'None yet: open this screen on the other phone too.' : '—', style: t.bodySmall),
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
          Row(children: [
            Expanded(child: Text('Runs on this phone (${kept.length})', style: t.titleSmall)),
            TextButton(onPressed: kept.isEmpty || recording ? null : _clearAll, child: const Text('Clear all runs')),
          ]),
          if (kept.isEmpty) Text('None yet. Swipe a run to delete it.', style: t.bodySmall),
          for (final r in kept)
            Dismissible(
              key: ValueKey('run-${r.id}'),
              direction: recording ? DismissDirection.none : DismissDirection.horizontal,
              onDismissed: (_) => _delete(r),
              background: Container(color: Colors.red.withOpacity(0.25)),
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${_time(r.id)} · ${distanceLabel(r.unit, r.entered)} · '
                    '${placementLabels[Placement.values.where((p) => p.name == r.place).firstOrNull] ?? r.place}'),
                subtitle: Text(r.overall == null
                    ? 'no phone heard${r.complete ? '' : ' · incomplete'}'
                    : '${r.overall!.n} samples · median ${r.overall!.median.toStringAsFixed(1)} dBm · '
                        'sd ${r.overall!.std.toStringAsFixed(1)} dB${r.complete ? '' : ' · incomplete'}'),
                trailing: Icon(r.complete ? Icons.check_circle_outline : Icons.warning_amber,
                    color: r.complete ? null : Colors.amber.shade800),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('bt-export'),
            onPressed: kept.isEmpty || recording ? null : _export,
            icon: const Icon(Icons.ios_share),
            label: Text('Export ${kept.length} run${kept.length == 1 ? '' : 's'}'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('bt-save'),
            onPressed: kept.isEmpty || recording ? null : _saveToPhone,
            icon: const Icon(Icons.download),
            label: const Text('Save to this phone'),
          ),
        ]),
      ),
    );
  }
}
