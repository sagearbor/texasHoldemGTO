/// "Record the table": prop the phone at the table on the widest lens and
/// keep 1 to 2 stills a second, plus a session log, for tuning seat and
/// fold detection offline later. Solo by design: the owner sets a player
/// count, optionally taps the dealer, checks the framing for 10 seconds and
/// leaves the phone alone. Nothing leaves the phone; Export shares a zip.
///
/// Flow: setup (players, where the phone sits, lens, rate) -> framing check
/// (seat boxes over the live view) -> recording status screen (dims after
/// 30 s) -> hold to stop. "I moved" starts a new segment with a new framing
/// check. If the app is killed, the log and the photos so far are already
/// on disk and the next launch offers to resume or close the session
/// ([maybeOfferRecordResume]).
library;

import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../camera/lens.dart';
import '../camera/lens_camera.dart';
import '../camera/watch_frame.dart' show uprightRotation;
import '../camera/watch_screen.dart' show watchFrameFromCamera, watchModeSupported;
import '../nearby/nearby_ble.dart' show bleSupported;
import '../nearby/nearby_service.dart';
import '../nearby/nearby_ui.dart' show askBluetooth, maybeAskUwb;
import '../radar/radar_model.dart' show CameraAt;
import '../radar/radar_screen.dart';
import '../radar/radar_settings.dart';
import '../sync/table_night_service.dart';
import '../ui/app_settings.dart';
import '../ui/theme.dart';
import 'record_log.dart';
import 'record_native.dart';
import 'record_session.dart';
import 'record_storage.dart';
import 'seat_zones.dart';

/// Phones only (a camera stream and app storage).
bool get recordModeSupported => watchModeSupported;

Future<void> openRecordMode(BuildContext context, {StoredSession? resume}) async {
  await Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => RecordScreen(resume: resume),
  ));
}

/// At launch: a session the app did not stop (killed, crashed, phone died)
/// is offered for resume or close. Everything up to the kill is on disk
/// either way.
Future<void> maybeOfferRecordResume(BuildContext context) async {
  if (!recordModeSupported) return;
  final s = await interruptedSession();
  if (s == null || !context.mounted) return;
  final when = s.summary.lastWallMs == null
      ? ''
      : ' at ${TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(s.summary.lastWallMs!)).format(context)}';
  final pick = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (d) => AlertDialog(
      title: const Text('Recording interrupted'),
      content: Text('The table recording stopped$when with ${s.summary.photos} photos saved. '
          'Everything up to then is on this phone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, 'close'), child: const Text('Close it')),
        FilledButton(onPressed: () => Navigator.pop(d, 'resume'), child: const Text('Resume')),
      ],
    ),
  );
  if (!context.mounted) return;
  if (pick == 'resume') {
    await openRecordMode(context, resume: s);
  } else if (pick == 'close') {
    closeInterrupted(s);
  }
}

/// Marks an interrupted session finished (one `closed` line).
void closeInterrupted(StoredSession s) {
  final sum = s.summary;
  final w = RecordLogWriter(FileLineSink(s.log),
      wallMs: () => DateTime.now().millisecondsSinceEpoch,
      elapsedMs: () => 0,
      baseM: resumeBaseMs(lastM: sum.lastM, lastWallMs: sum.lastWallMs, nowWallMs: DateTime.now().millisecondsSinceEpoch),
      run: sum.runs + 1);
  w.write('closed', {'reason': 'interrupted', 'photos': sum.photos});
}

enum _Stage { setup, framing, live }

class RecordScreen extends StatefulWidget {
  final StoredSession? resume;
  const RecordScreen({super.key, this.resume});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

const _prefPlayers = 'record_players_v1';
const _prefRate = 'record_rate_v1';
const _prefWidest = 'record_widest_v1';
const _prefLocationAsked = 'record_location_asked_v1';

/// 1080p frames, JPEG quality 85: about 300 to 500 KB a still, so 1.5 a
/// second is roughly 2 to 3 GB an hour, and a far seat is still a person
/// with hands, not a smudge.
const _preset = ResolutionPreset.veryHigh;
const _quality = 85;

/// The framing check, per segment.
const _framingSeconds = 10;

const _deviceDegrees = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

class _RecordScreenState extends State<RecordScreen> with WidgetsBindingObserver {
  _Stage _stage = _Stage.setup;

  // ------------------------------------------------------------- setup
  int _players = 6;
  PhonePosition _position = PhonePosition.end;
  bool _widest = true;

  /// The lens asked for: Settings → Camera lens, or this screen's own
  /// switch when that is Automatic.
  bool get _effWidest => useWidest(CameraLens.choice.value, featureDefault: _widest);
  double _rate = 1.5;
  int? _dealerSeat;

  /// Host a game for phones nearby while recording (Bluetooth, optional).
  bool _host = false;
  bool _hostedStandalone = false;

  // ------------------------------------------------------------ camera
  CameraController? _cam;
  LensInfo? _lens;
  String? _error;
  bool _opening = false;
  CameraImage? _lastFrame;

  // ----------------------------------------------------------- session
  Directory? _dir;
  RecordLogWriter? _log;
  RecordSession? _session;
  final Stopwatch _clock = Stopwatch();
  final CapturePacer _pacer = CapturePacer(667);
  int? _lastPhotoAtMs;
  File? _latest;
  int _framingLeft = _framingSeconds;
  Timer? _framingTimer;
  Uint8List? _refGrid;
  double? _match;
  int _lastGridMs = 0;
  bool _segmentLogged = false;

  // ------------------------------------------------------------ status
  Timer? _tick;
  int? _battery;
  bool? _charging;
  String _thermal = 'unknown';
  int? _free;
  List<RecordWarning> _warnings = const [];
  final Set<RecordWarning> _loggedWarnings = {};

  // -------------------------------------------------------------- dim
  bool _dim = false;
  Timer? _dimTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs();
    _initCamera();
    RadarSettings.config.addListener(_onRadar);
  }

  /// The player count is shared with the seat radar, both ways: a change
  /// there (people came or went) shows here and goes into the log.
  void _onRadar() {
    final n = RadarSettings.config.value.seats;
    if (!mounted || n == _players) return;
    final s = _session;
    if (s != null && s.phase != RecordPhase.stopped) _write(('players', {'seg': s.segment.n, 'players': n, 'from': 'radar'}));
    setState(() => _players = n);
  }

  void _setPlayers(int n) {
    setState(() => _players = n);
    unawaited(RadarSettings.setSeats(n, why: 'record'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RadarSettings.config.removeListener(_onRadar);
    _tick?.cancel();
    _framingTimer?.cancel();
    _dimTimer?.cancel();
    final c = _cam;
    _cam = null;
    if (c != null) {
      if (c.value.isStreamingImages) c.stopImageStream().ignore();
      c.dispose();
    }
    WakelockPlus.disable();
    NearbyService.instance.mirror = null;
    unawaited(NearbyService.instance.stopRecording());
    // Leaving without "hold to stop" (back gesture): the session stays
    // open and is offered for resume at the next launch, like a kill.
    final s = _session;
    if (s != null && s.phase != RecordPhase.stopped) _write(s.setBackground(true));
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final r = widget.resume?.summary.start;
      await RadarSettings.load();
      if (!mounted) return;
      setState(() {
        _players = (r?['players'] as int?) ??
            (RadarSettings.saved ? RadarSettings.config.value.seats : p.getInt(_prefPlayers) ?? 6);
        _rate = (r?['rate'] as num?)?.toDouble() ?? p.getDouble(_prefRate) ?? 1.5;
        if (!recordRates.contains(_rate)) _rate = 1.5;
        _widest = p.getBool(_prefWidest) ?? true;
      });
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_prefPlayers, _players);
      await p.setDouble(_prefRate, _rate);
      await p.setBool(_prefWidest, _widest);
    } catch (_) {}
  }

  // ------------------------------------------------------------ camera

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Both platforms take the camera away in the background: release it,
    // log it, and open it again on return (the session goes on).
    if (state == AppLifecycleState.paused) {
      final s = _session;
      if (s != null && s.phase != RecordPhase.stopped && !s.backgrounded) _write(s.setBackground(true));
      final c = _cam;
      if (c == null || _opening) return;
      _cam = null;
      if (c.value.isStreamingImages) c.stopImageStream().ignore();
      c.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      final s = _session;
      if (s != null && s.backgrounded) _write(s.setBackground(false));
      if (_cam == null) _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (_opening || !recordModeSupported) return;
    _opening = true;
    try {
      final (c, lens) = await openCameraWithLens(
          direction: CameraLensDirection.back,
          widest: _effWidest,
          preset: _preset,
          fps: 15,
          imageFormatGroup: ImageFormatGroup.yuv420);
      if (!mounted) {
        c.dispose();
        return;
      }
      await c.startImageStream(_onImage);
      setState(() {
        _cam = c;
        _lens = lens;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera unavailable ($e)');
    } finally {
      _opening = false;
    }
  }

  Future<void> _switchLens(bool widest) async {
    setState(() => _widest = widest);
    final c = _cam;
    _cam = null;
    if (c != null) {
      if (c.value.isStreamingImages) await c.stopImageStream();
      await c.dispose();
    }
    _segmentLogged = false;
    await _initCamera();
  }

  int get _rotation {
    final c = _cam;
    if (c == null || Platform.isIOS) return 0; // iOS frames are upright
    return uprightRotation(c.description.sensorOrientation, _deviceDegrees[c.value.deviceOrientation] ?? 0,
        front: false);
  }

  void _onImage(CameraImage img) {
    _lastFrame = img;
    final s = _session;
    if (s == null) return;
    final t = _clock.elapsedMilliseconds;
    if (!_segmentLogged) {
      _segmentLogged = true;
      _write(s.segmentStart(width: img.width, height: img.height, rotation: _rotation));
    }
    // "Table in view": a coarse luma grid against the framing reference,
    // every 2 seconds.
    if (_refGrid != null && t - _lastGridMs >= 2000) {
      _lastGridMs = t;
      final m = viewMatch(_refGrid!, watchFrameFromCamera(img).lumaGrid(16, 9));
      if (mounted) setState(() => _match = m);
    }
    if (!s.capturing || !_pacer.due(t)) return;
    unawaited(_save(s, img, t));
  }

  Future<void> _save(RecordSession s, CameraImage img, int t) async {
    final dir = _dir;
    if (dir == null) return _pacer.done();
    final wall = DateTime.now().millisecondsSinceEpoch;
    final n = s.photos + 1;
    final rel = '${s.segment.folder}/${n.toString().padLeft(6, '0')}-$wall.jpg';
    final sw = Stopwatch()..start();
    try {
      final bytes = await encodeJpeg(img, '${dir.path}/$rel', quality: _quality, rotation: _rotation);
      if (bytes == null || _session != s || s.phase == RecordPhase.stopped) return;
      _write(s.photoSaved(rel, bytes,
          width: img.width, height: img.height, encodeMs: sw.elapsedMilliseconds, lagMs: _clock.elapsedMilliseconds - t));
      _lastPhotoAtMs = _clock.elapsedMilliseconds;
      // The thumbnail only every few photos: decoding a 1080p JPEG is not
      // free and the status screen is mostly dimmed anyway.
      if (mounted && (!_dim || _latest == null) && (n % 3 == 1 || _latest == null)) {
        setState(() => _latest = File('${dir.path}/$rel'));
      }
    } finally {
      _pacer.done();
    }
  }

  // ----------------------------------------------------------- session

  void _write(LogEntry e) {
    try {
      _log?.write(e.$1, e.$2);
    } catch (err) {
      debugPrint('record log: $err');
    }
  }

  Future<void> _start() async {
    final lens = _lens;
    if (lens == null) return;
    await _savePrefs();
    // The radar takes the camera's place and the player count from here.
    unawaited(RadarSettings.set(
        RadarSettings.config.value.copyWith(
            seats: _players, camera: _position == PhonePosition.side ? CameraAt.side : CameraAt.end),
        why: 'record start'));
    final location = await _askLocation();
    final r = widget.resume;
    final now = DateTime.now();
    final Directory dir;
    final RecordLogWriter log;
    final RecordSession s;
    if (r == null) {
      final id = newSessionId(now);
      dir = Directory('${(await recordingsRoot()).path}/$id');
      await dir.create(recursive: true);
      log = RecordLogWriter(FileLineSink(File('${dir.path}/$sessionLogName')),
          wallMs: () => DateTime.now().millisecondsSinceEpoch, elapsedMs: () => _clock.elapsedMilliseconds);
      s = RecordSession(_position, lens);
      _clock
        ..reset()
        ..start();
      final info = await PackageInfo.fromPlatform().then((p) => '${p.version}+${p.buildNumber}', onError: (_) => null);
      log.write('session_start', {
        'session': id,
        'app': info,
        'platform': defaultTargetPlatform.name,
        'device': await deviceInfo(),
        'location': location,
        'players': _players,
        'dealer': _dealerSeat,
        'rate': _rate,
        'quality': _quality,
        'preset': _preset.name,
        'lens_setting': CameraLens.choice.value.name,
        'seats': 'seat 0 = the phone owner (out of view), then clockwise from above',
        'role': 'camera',
        'tz_offset_min': now.timeZoneOffset.inMinutes,
      });
    } else {
      dir = r.dir;
      final sum = r.summary;
      log = RecordLogWriter(FileLineSink(r.log),
          wallMs: () => DateTime.now().millisecondsSinceEpoch,
          elapsedMs: () => _clock.elapsedMilliseconds,
          baseM: resumeBaseMs(lastM: sum.lastM, lastWallMs: sum.lastWallMs, nowWallMs: now.millisecondsSinceEpoch),
          run: sum.runs + 1);
      s = RecordSession(_position, lens, firstSegment: sum.segments + 1, photos: sum.photos, marks: sum.marks)
        ..photoBytes = sum.photoBytes;
      _clock
        ..reset()
        ..start();
      log.write('resume_session', {
        'after_ms': sum.lastWallMs == null ? null : now.millisecondsSinceEpoch - sum.lastWallMs!,
        'players': _players,
        'device': await deviceInfo(),
        'location': location,
      });
    }
    _dir = dir;
    _log = log;
    _session = s;
    await _startHosting(log);
    _segmentLogged = false;
    _pacer.intervalMs = intervalForRate(_rate);
    WakelockPlus.enable();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), _onTick);
    unawaited(_refreshStatus());
    _startFraming();
  }

  /// Optional: the recording phone hosts a game phones nearby can join
  /// (or shares the table night it already organizes). Its ids go in the
  /// log so the offline analysis can match this phone's Bluetooth advert.
  Future<void> _startHosting(RecordLogWriter log) async {
    final tn = TableNightService.instance;
    if (_host && mounted && await askBluetooth(context, hosting: true)) {
      if (mounted) await maybeAskUwb(context);
      try {
        final had = tn.night;
        final n = await tn.organizeStandalone(AppSettings.playerName.value.isEmpty ? 'Host' : AppSettings.playerName.value,
            role: 'camera');
        _hostedStandalone = had == null && tn.standalone;
        log.write('nearby_host', {
          'night': n.nightId,
          'device': n.deviceId,
          'organizer': n.isOrganizer,
          'standalone': _hostedStandalone,
        });
      } catch (e) {
        log.write('nearby_host', {'error': '$e'});
      }
    } else if (tn.night != null) {
      log.write('nearby_night', {'night': tn.night!.nightId, 'device': tn.night!.deviceId, 'organizer': tn.isOrganizer});
    }
    // The seating experiment's readings also land in this log, and this
    // phone advertises as a camera. Only if Bluetooth was already allowed:
    // nothing is asked here, and recording works without it.
    NearbyService.instance.mirror = (k, f) => _write((k, f));
    if (NearbyService.instance.allowed) {
      try {
        await NearbyService.instance.startRecording();
      } catch (e) {
        log.write('nearby_error', {'error': '$e'});
      }
    } else {
      log.write('nearby_off', {'reason': 'Bluetooth not allowed in this app'});
    }
  }

  /// Just in time, once: ask before the OS prompt, in plain words. Later
  /// sessions use it only if it was allowed.
  Future<Map<String, Object?>?> _askLocation() async {
    var asked = true;
    SharedPreferences? p;
    try {
      p = await SharedPreferences.getInstance();
      asked = p.getBool(_prefLocationAsked) ?? false;
    } catch (_) {}
    if (asked || !mounted) return coarseLocation();
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Note roughly where this is?'),
        content: const Text('Felt Notes can save your approximate location (the area, not the house) once, '
            'at the start of each recording, so recordings from different venues can be told apart later. '
            'It stays in the recording on this phone. No is fine.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Allow')),
        ],
      ),
    );
    await p?.setBool(_prefLocationAsked, true);
    return coarseLocation(ask: yes == true);
  }

  void _startFraming() {
    _framingTimer?.cancel();
    _refGrid = null;
    _match = null;
    setState(() {
      _stage = _Stage.framing;
      _framingLeft = _framingSeconds;
    });
    _framingTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _framingLeft--);
      if (_framingLeft <= 0) {
        t.cancel();
        _framingDone(skipped: false);
      }
    });
  }

  void _framingDone({required bool skipped}) {
    _framingTimer?.cancel();
    final s = _session;
    if (s == null || s.phase != RecordPhase.framing) return;
    final f = _lastFrame;
    _refGrid = f == null ? null : watchFrameFromCamera(f).lumaGrid(16, 9);
    _write(s.framingDone(skipped: skipped, refGrid: _refGrid));
    if (_dealerSeat != null) _write(('dealer', {'seg': s.segment.n, 'seat': _dealerSeat}));
    _pacer.reset();
    _lastPhotoAtMs = _clock.elapsedMilliseconds;
    setState(() => _stage = _Stage.live);
    _poke();
  }

  void _togglePause() {
    final s = _session;
    if (s == null) return;
    _write(s.phase == RecordPhase.paused ? s.resume() : s.pause());
    _lastPhotoAtMs = _clock.elapsedMilliseconds;
    _pacer.reset();
    setState(() {});
    _poke();
  }

  void _mark() {
    final s = _session;
    if (s == null) return;
    final e = s.mark();
    _write(e);
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: Text('Hand marked (#${e.$2['n']})'),
    ));
    setState(() {});
    _poke();
  }

  Future<void> _moved() async {
    final s = _session;
    if (s == null) return;
    var pos = s.segment.position;
    var players = _players;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: const Text('I moved the phone'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('A new segment starts with a fresh 10-second framing check.'),
            const SizedBox(height: 12),
            _PositionPicker(value: pos, onChanged: (v) => set(() => pos = v)),
            const SizedBox(height: 8),
            _PlayersStepper(value: players, onChanged: (v) => set(() => players = v)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Check framing')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted || _lens == null) return;
    for (final e in s.moved(pos, _lens!)) {
      _write(e);
    }
    if (players != _players) {
      _write(('players', {'seg': s.segment.n, 'players': players}));
      unawaited(RadarSettings.setSeats(players, why: 'record moved'));
    }
    setState(() {
      _players = players;
      _position = pos;
      _dealerSeat = null;
      _dim = false;
    });
    _segmentLogged = false;
    _startFraming();
  }

  Future<void> _stop() async {
    final s = _session;
    if (s == null || s.phase == RecordPhase.stopped) return;
    for (final e in s.stop(durationMs: _clock.elapsedMilliseconds)) {
      _write(e);
    }
    _tick?.cancel();
    WakelockPlus.disable();
    NearbyService.instance.mirror = null;
    unawaited(NearbyService.instance.stopRecording());
    if (_hostedStandalone) unawaited(TableNightService.instance.endStandalone());
    // A camera that joined someone's game leaves it with the recording.
    if (!_hostedStandalone && TableNightService.instance.isCamera) unawaited(TableNightService.instance.leave());
    HapticFeedback.heavyImpact();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(
      content: Text('Saved ${s.photos} photos. Export: Home game → Record the table → Recordings.'),
    ));
  }

  // ------------------------------------------------------------ status

  void _onTick(Timer t) {
    final s = _session;
    if (s == null || !mounted) return;
    if (t.tick % 15 == 0) unawaited(_refreshStatus());
    if (t.tick % 60 == 0) {
      _write(('status', {
        'seg': s.segment.n,
        'phase': s.phase.name,
        'photos': s.photos,
        'bytes': s.photoBytes,
        'battery': _battery,
        'charging': _charging,
        'thermal': _thermal,
        'free': _free,
        'in_view': _match == null ? null : (_match! * 100).round(),
        'bg': s.backgrounded,
      }));
    }
    _updateWarnings();
    setState(() {});
  }

  Future<void> _refreshStatus() async {
    try {
      final b = Battery();
      final level = await b.batteryLevel;
      final st = await b.batteryState;
      _battery = level;
      _charging = st == BatteryState.charging || st == BatteryState.full
          ? true
          : st == BatteryState.discharging
              ? false
              : null;
    } catch (_) {}
    _thermal = await thermalState();
    final d = _dir;
    if (d != null) _free = await freeBytes(d);
    if (mounted) setState(_updateWarnings);
  }

  int get _bytesPerHour {
    final s = _session;
    final ms = _clock.elapsedMilliseconds;
    if (s == null || ms < 60000 || s.photos == 0) return (2.5 * (1 << 30)).round();
    return (s.photoBytes * 3600000 / ms).round();
  }

  void _updateWarnings() {
    final s = _session;
    if (s == null) return;
    final since = _lastPhotoAtMs == null ? null : _clock.elapsedMilliseconds - _lastPhotoAtMs!;
    final w = recordWarnings(
      capturing: s.capturing,
      charging: _charging,
      msSincePhoto: since,
      freeBytes: _free,
      bytesPerHour: _bytesPerHour,
      thermal: _thermal,
    );
    // Each warning is logged once when it first appears, and when it
    // clears.
    for (final x in w) {
      if (_loggedWarnings.add(x)) _write(('warn', {'what': x.name, 'on': true}));
    }
    for (final x in _loggedWarnings.difference(w.toSet()).toList()) {
      _loggedWarnings.remove(x);
      _write(('warn', {'what': x.name, 'on': false}));
    }
    _warnings = w;
  }

  // --------------------------------------------------------------- dim

  /// Any touch wakes the screen and restarts the 30-second dim timer.
  void _poke() {
    _dimTimer?.cancel();
    if (_dim) setState(() => _dim = false);
    if (_stage != _Stage.live) return;
    _dimTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && _stage == _Stage.live) setState(() => _dim = true);
    });
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final body = switch (_stage) {
      _Stage.setup => _setup(context),
      _Stage.framing => _framing(context),
      _Stage.live => _live(context),
    };
    return PopScope(
      // While recording, only "hold to stop" ends it (a stray back swipe
      // would otherwise leave the table unrecorded).
      canPop: _stage == _Stage.setup,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _poke(),
        child: Stack(children: [
          Scaffold(
            appBar: _dim
                ? null
                : AppBar(
                    title: Text(widget.resume == null ? 'Record the table' : 'Resume recording'),
                    automaticallyImplyLeading: _stage == _Stage.setup,
                  ),
            body: SafeArea(child: body),
          ),
          if (_dim) Positioned.fill(child: _DimOverlay(elapsedMs: _clock.elapsedMilliseconds, paused: _session?.phase == RecordPhase.paused, warn: _warnings.isNotEmpty)),
        ]),
      ),
    );
  }

  Widget _preview({bool boxes = true, bool tapSeats = false}) {
    final c = _cam;
    if (c == null || !c.value.isInitialized) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: _error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                ),
        ),
      );
    }
    return CameraPreview(
      c,
      child: boxes
          ? _SeatBoxes(
              players: _players,
              position: _position,
              dealer: _dealerSeat,
              onTap: tapSeats ? (i) => setState(() => _dealerSeat = _dealerSeat == i ? null : i) : null,
            )
          : null,
    );
  }

  Widget _setup(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
      Text(
          'Prop the phone where it sees the whole table, plugged in. It saves '
          '${_rate == 1 ? 'a photo' : '${_rate.toString().replaceAll('.0', '')} photos'} a second '
          'and a log, on this phone only, for working out seats and folds later.',
          style: t.bodyMedium),
      const SizedBox(height: 12),
      ClipRRect(borderRadius: BorderRadius.circular(8), child: _preview(tapSeats: true)),
      const SizedBox(height: 4),
      Text(
          _lens == null ? '' : lensLine(_lens!, widest: _effWidest),
          style: t.bodySmall),
      const SizedBox(height: 12),
      _PlayersStepper(value: _players, onChanged: _setPlayers),
      const SizedBox(height: 8),
      _PositionPicker(value: _position, onChanged: (v) => setState(() => _position = v)),
      const SizedBox(height: 8),
      Text('Dealer: ${_dealerSeat == null ? 'tap their box (optional)' : 'seat $_dealerSeat'}', style: t.bodySmall),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _effWidest,
        // Settings → Camera lens, when not Automatic, decides for every
        // camera feature.
        onChanged: _opening || CameraLens.choice.value != LensChoice.auto ? null : _switchLens,
        title: const Text('Widest lens'),
        subtitle: Text(CameraLens.choice.value == LensChoice.auto
            ? 'Ultra-wide where the phone has one'
            : 'Set in Settings → Camera lens: ${lensChoiceLabels[CameraLens.choice.value]}'),
      ),
      if (bleSupported)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _host,
          onChanged: (v) => setState(() => _host = v),
          title: const Text('Let phones nearby join'),
          subtitle: const Text('Players with Felt Notes see a one-tap "Nearby game" card. Bluetooth, no internet.'),
        ),
      const _JoinAsCamera(),
      Text('Photos a second', style: t.labelLarge),
      Wrap(spacing: 8, children: [
        for (final r in recordRates)
          ChoiceChip(
            label: Text(r.toString().replaceAll('.0', '')),
            selected: _rate == r,
            onSelected: (_) => setState(() => _rate = r),
          ),
      ]),
      Text('About ${(_rate * 1.7).toStringAsFixed(1)} GB an hour.', style: t.bodySmall),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _lens == null ? null : _start,
        icon: const Icon(Icons.fiber_manual_record),
        label: Text(widget.resume == null ? 'Check framing, then record' : 'Check framing, then resume'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecordingsScreen())),
        icon: const Icon(Icons.folder_outlined),
        label: const Text('Recordings & export'),
      ),
    ]);
  }

  Widget _framing(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      Text('Framing check · segment ${_session?.segment.n ?? 1}', style: t.titleMedium),
      const SizedBox(height: 4),
      Text('Every seat should sit inside its box, more or less. Tap the dealer\'s box if you like.', style: t.bodySmall),
      const SizedBox(height: 8),
      ClipRRect(borderRadius: BorderRadius.circular(8), child: _preview(tapSeats: true)),
      const SizedBox(height: 12),
      LinearProgressIndicator(value: 1 - _framingLeft / _framingSeconds),
      const SizedBox(height: 8),
      Text('Recording starts in $_framingLeft s', style: t.titleSmall, textAlign: TextAlign.center),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () {
              _framingTimer?.cancel();
              setState(() => _framingLeft = _framingSeconds);
              _startFraming();
            },
            child: const Text('Again'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(onPressed: () => _framingDone(skipped: true), child: const Text('Looks good')),
        ),
      ]),
    ]);
  }

  Widget _live(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = _session!;
    final paused = s.phase == RecordPhase.paused;
    final elapsed = _clock.elapsedMilliseconds;
    final perSec = s.photos == 0 || elapsed < 5000 ? null : s.photos / (elapsed / 1000);
    Widget row(IconData i, String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Icon(i, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: t.bodyMedium)),
            Text(value, style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: color)),
          ]),
        );
    final match = _match;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      Row(children: [
        Icon(Icons.fiber_manual_record, color: paused ? Colors.grey : Colors.red, size: 18),
        const SizedBox(width: 6),
        Text(paused ? 'PAUSED' : (s.backgrounded ? 'IN BACKGROUND' : 'RECORDING'),
            style: t.titleMedium?.copyWith(color: paused ? null : Colors.red, fontWeight: FontWeight.w800)),
        const Spacer(),
        Text(elapsedLabel(elapsed), style: t.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
      if (_warnings.isNotEmpty) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.amber.shade700, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final w in _warnings)
              Text(warningText(w), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
          ]),
        ),
      ],
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          aspectRatio: _thumbAspect(),
          child: Stack(fit: StackFit.expand, children: [
            Container(color: Colors.black),
            if (_latest != null)
              Image.file(_latest!, fit: BoxFit.cover, cacheWidth: 640, gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const SizedBox()),
            _SeatBoxes(players: _players, position: _position, dealer: _dealerSeat),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      row(Icons.photo_library_outlined, 'Photos saved',
          '${s.photos}${perSec == null ? '' : ' · ${perSec.toStringAsFixed(1)}/s'}'),
      row(Icons.sd_storage_outlined, 'Storage used / free',
          '${bytesLabel(s.photoBytes)} / ${_free == null ? '?' : bytesLabel(_free!)}'),
      row(_charging == true ? Icons.battery_charging_full : Icons.battery_std, 'Battery',
          '${_battery == null ? '?' : '$_battery%'}${_charging == true ? ' · charging' : _charging == false ? ' · not charging' : ''}',
          color: _charging == false ? Colors.amber.shade800 : null),
      row(Icons.thermostat, 'Phone temperature', _thermal,
          color: _thermal == 'serious' || _thermal == 'critical' ? Colors.red : null),
      row(Icons.visibility_outlined, 'Table in view',
          match == null ? '—' : match >= 0.6 ? 'yes (${(match * 100).round()}%)' : 'check it (${(match * 100).round()}%)',
          color: match != null && match < 0.6 ? Colors.amber.shade800 : null),
      row(Icons.auto_awesome_outlined, 'Live guess', 'off (tuned later from recordings)'),
      row(Icons.bookmark_outline, 'Marked hands', '${s.marks}'),
      Text(
          'Segment ${s.segment.n} · ${s.segment.position.name} · '
          '${s.segment.lens.kind == 'ultra_wide' ? 'ultra-wide' : 'normal lens'} · $_players players',
          style: t.bodySmall),
      const SizedBox(height: 12),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: _mark,
        icon: const Icon(Icons.bookmark_add_outlined),
        label: const Text('Mark this hand'),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _togglePause,
            icon: Icon(paused ? Icons.play_arrow : Icons.pause),
            label: Text(paused ? 'Resume' : 'Pause'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _moved,
            icon: const Icon(Icons.open_with),
            label: const Text('I moved'),
          ),
        ),
      ]),
      TextButton.icon(
        onPressed: () => openRadar(context),
        icon: const Icon(Icons.radar),
        label: const Text('Seat radar'),
      ),
      _HoldToStop(onDone: _stop),
      const SizedBox(height: 8),
      Text('The screen dims after 30 seconds; tap to wake. Keep the app open: the camera stops in the background.',
          style: t.bodySmall, textAlign: TextAlign.center),
    ]);
  }

  double _thumbAspect() {
    final c = _cam;
    if (c == null || !c.value.isInitialized) return 16 / 9;
    // Preview size is landscape (sensor); the photo is upright for the
    // way the phone is held.
    final a = c.value.aspectRatio;
    return MediaQuery.orientationOf(context) == Orientation.portrait ? 1 / a : a;
  }
}

class _PlayersStepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _PlayersStepper({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(children: [
      Expanded(child: Text('Players at the table (with you)', style: t.labelLarge)),
      IconButton.outlined(
        tooltip: 'Fewer',
        onPressed: value > 2 ? () => onChanged(value - 1) : null,
        icon: const Icon(Icons.remove),
      ),
      SizedBox(width: 40, child: Text('$value', style: t.titleLarge, textAlign: TextAlign.center)),
      IconButton.outlined(
        tooltip: 'More',
        onPressed: value < 10 ? () => onChanged(value + 1) : null,
        icon: const Icon(Icons.add),
      ),
    ]);
  }
}

class _PositionPicker extends StatelessWidget {
  final PhonePosition value;
  final ValueChanged<PhonePosition> onChanged;
  const _PositionPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Where the phone sits', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 4),
      SegmentedButton<PhonePosition>(
        segments: const [
          ButtonSegment(value: PhonePosition.end, label: Text('End')),
          ButtonSegment(value: PhonePosition.side, label: Text('Side')),
          ButtonSegment(value: PhonePosition.other, label: Text('Other')),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    ]);
  }
}

/// Seat boxes over the picture (seat_zones.dart); tap one to mark the
/// dealer.
class _SeatBoxes extends StatelessWidget {
  final int players;
  final PhonePosition position;
  final int? dealer;
  final ValueChanged<int>? onTap;
  const _SeatBoxes({required this.players, required this.position, this.dealer, this.onTap});

  @override
  Widget build(BuildContext context) {
    final zones = seatZones(players, position);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return Stack(children: [
        for (var i = 0; i < zones.length; i++)
          Positioned(
            left: zones[i].left * w,
            top: zones[i].top * h,
            width: zones[i].width * w,
            height: zones[i].height * h,
            child: GestureDetector(
              onTap: onTap == null ? null : () => onTap!(i + 1),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: dealer == i + 1 ? Felt.gold : Colors.white70, width: dealer == i + 1 ? 3 : 1.5),
                  color: dealer == i + 1 ? Felt.gold.withOpacity(0.18) : Colors.transparent,
                ),
                alignment: Alignment.topLeft,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text(dealer == i + 1 ? '${i + 1} D' : '${i + 1}',
                      style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            ),
          ),
      ]);
    });
  }
}

/// Black (OLED pixels off) with a small status that drifts, so nothing
/// burns in. Any touch wakes the full screen.
class _DimOverlay extends StatelessWidget {
  final int elapsedMs;
  final bool paused, warn;
  const _DimOverlay({required this.elapsedMs, required this.paused, required this.warn});

  @override
  Widget build(BuildContext context) {
    final step = (elapsedMs ~/ 60000) % 6;
    final align = [
      Alignment.topLeft,
      Alignment.topRight,
      Alignment.center,
      Alignment.bottomLeft,
      Alignment.bottomRight,
      Alignment.centerLeft,
    ][step];
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Align(
          alignment: align,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '${paused ? 'PAUSED' : '● REC'} ${elapsedLabel(elapsedMs)}${warn ? '  ⚠' : ''}\ntap to wake',
              textAlign: TextAlign.center,
              style: TextStyle(color: paused ? Colors.white38 : Colors.red.withOpacity(0.7), fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }
}

/// Press and hold for 1.5 s to stop: a tap or a brush does nothing.
class _HoldToStop extends StatefulWidget {
  final VoidCallback onDone;
  const _HoldToStop({required this.onDone});

  @override
  State<_HoldToStop> createState() => _HoldToStopState();
}

class _HoldToStopState extends State<_HoldToStop> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final red = Colors.red.shade700;
    return GestureDetector(
      onTapDown: (_) => _a.forward(from: 0),
      onTapUp: (_) => _a.reverse(),
      onTapCancel: () => _a.reverse(),
      child: AnimatedBuilder(
        animation: _a,
        builder: (context, _) => Container(
          height: 52,
          decoration: BoxDecoration(border: Border.all(color: red, width: 2), borderRadius: BorderRadius.circular(26)),
          clipBehavior: Clip.antiAlias,
          child: Stack(children: [
            FractionallySizedBox(widthFactor: _a.value, child: Container(color: red.withOpacity(0.35))),
            Center(
              child: Text(_a.value > 0 ? 'Keep holding…' : 'Hold to stop and save',
                  style: TextStyle(color: red, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- export

/// The sessions on this phone: share one as a zip (or just its log), see
/// where the folder is (Android), delete.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});
  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  List<StoredSession>? _sessions;
  final Map<String, int> _sizes = {};
  String? _busy;
  String? _root;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await listSessions();
    final root = await recordingsRoot();
    if (!mounted) return;
    setState(() {
      _sessions = list;
      _root = root.path;
    });
    for (final s in list) {
      final b = await folderBytes(s.dir);
      if (mounted) setState(() => _sizes[s.id] = b);
    }
  }

  Future<void> _share(StoredSession s, {required bool logOnly}) async {
    setState(() => _busy = s.id);
    try {
      final f = await zipSession(s, logOnly: logOnly);
      if (!mounted) return;
      await shareRecordingFile(context, f);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not make the zip ($e)')));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _delete(StoredSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete this recording?'),
        content: Text('${s.summary.photos} photos and the log go for good.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await s.dir.delete(recursive: true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final list = _sessions;
    return Scaffold(
      appBar: AppBar(title: const Text('Recordings')),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text(
                  Platform.isAndroid
                      ? 'On a Mac: share a zip, or plug in and run\nadb pull ${_root ?? ''}'
                      : 'On a Mac: share a zip (AirDrop), or plug in and open the iPhone in Finder → Files → Felt Notes.',
                  style: t.bodySmall),
              if (Platform.isAndroid && _root != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _root!));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Folder path copied')));
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy folder path'),
                  ),
                ),
              if (list.isEmpty) const Padding(padding: EdgeInsets.only(top: 24), child: Text('No recordings yet.')),
              for (final s in list)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.id, style: t.titleSmall),
                      Text(
                          '${elapsedLabel(s.summary.durationMs)} · ${s.summary.photos} photos · '
                          '${s.summary.segments} segment${s.summary.segments == 1 ? '' : 's'} · ${s.summary.marks} marks'
                          '${_sizes[s.id] == null ? '' : ' · ${bytesLabel(_sizes[s.id]!)}'}'
                          '${s.summary.interrupted ? ' · not stopped' : ''}',
                          style: t.bodySmall),
                      if (_busy == s.id)
                        const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: LinearProgressIndicator())
                      else
                        Wrap(spacing: 4, children: [
                          TextButton.icon(
                            onPressed: _busy != null ? null : () => _share(s, logOnly: false),
                            icon: const Icon(Icons.ios_share, size: 18),
                            label: const Text('Share zip'),
                          ),
                          TextButton(
                            onPressed: _busy != null ? null : () => _share(s, logOnly: true),
                            child: const Text('Log only'),
                          ),
                          if (s.summary.interrupted)
                            TextButton(
                              onPressed: () async {
                                closeInterrupted(s);
                                await _load();
                              },
                              child: const Text('Close'),
                            ),
                          IconButton(
                            tooltip: 'Delete',
                            onPressed: _busy != null ? null : () => _delete(s),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ]),
                    ]),
                  ),
                ),
            ]),
    );
  }
}

/// The share sheet for one zip (AirDrop to the Mac, Files, Drive...).
Future<void> shareRecordingFile(BuildContext context, File f) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
  await Share.shareXFiles([XFile(f.path, mimeType: 'application/zip')], sharePositionOrigin: origin);
}

/// A second recording phone: join the game hosted nearby as a camera (a
/// fixed anchor for the seating experiment, never a player or a seat).
/// Shown only when Bluetooth is already allowed and a game is heard.
class _JoinAsCamera extends StatelessWidget {
  const _JoinAsCamera();

  @override
  Widget build(BuildContext context) {
    final near = NearbyService.instance, tn = TableNightService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([near, tn]),
      builder: (context, _) {
        if (!near.allowed || tn.night != null || near.games.isEmpty) {
          if (tn.night != null && tn.isCamera) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('In ${tn.tableName()} as the camera.', style: Theme.of(context).textTheme.bodySmall),
            );
          }
          return const SizedBox.shrink();
        }
        final g = near.games.first;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.videocam_outlined),
            label: Text('Join ${g.label} as the camera'),
            onPressed: () async {
              final me = AppSettings.playerName.value;
              var name = '${me.isEmpty ? 'Table' : me} camera';
              if (name.length > 24) name = name.substring(0, 24).trim();
              try {
                await tn.join(g.ticket,
                    name: name, scannedAtMs: DateTime.now().millisecondsSinceEpoch, sharing: true, role: 'camera');
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not join ($e)')));
                }
              }
            },
          ),
        );
      },
    );
  }
}
