/// Nearby games and the seating experiment, for the whole app.
///
/// One loop, foreground first: every 20 to 60 seconds a 4-second Bluetooth
/// scan. Not in a game: the scan looks for hosts ([games], the "Nearby
/// game" card). In a game: the phone advertises (a host its game, a player
/// its presence) and every scan is also a reading of the other phones for
/// the seating experiment (sense.dart), logged and never shown. iPhones
/// with UWB also range with each other. Nothing here needs a network: the
/// join is the normal table-night join (local log, uploads when it can).
///
/// Bluetooth is used only after the owner of the phone said yes, just in
/// time (the "Find a game nearby" button, or hosting); a phone that never
/// asked never scans. iOS cannot advertise usefully in the background
/// (the UUID moves to an overflow area Android cannot see) and suspends
/// the app anyway: the log says when a phone was in the background.
library;

import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../record/record_log.dart';
import '../record/record_native.dart' show deviceInfo;
import '../sync/event_log.dart';
import '../sync/night_events.dart';
import '../sync/table_night_service.dart';
import '../sync/table_sync.dart';
import 'ble_payload.dart';
import 'distance_test.dart' show HealAction, RadioHealth;
import 'uwb_android.dart';
import 'nearby_ble.dart';
import 'sense.dart';

class NearbyService extends ChangeNotifier with WidgetsBindingObserver {
  NearbyService._();
  static final instance = NearbyService._();

  bool _started = false;

  /// Bluetooth permission given (the loop runs only then).
  bool allowed = false;
  bool poweredOn = true;
  bool uwb = false;

  /// Games heard in the last 2 minutes, strongest first.
  List<NearbyGame> games = const [];

  /// What this phone advertises now (null: nothing).
  String? advertising;
  bool advertiseFailed = false;

  bool _foreground = true;
  String? _loopNight;
  bool _scanning = false;
  Timer? _timer;
  int _quietScans = 0;
  final List<BleSighting> _recent = [];
  StreamSubscription<Map<String, Object?>>? _events;

  // Seating experiment, per night.
  String? _senseNight;
  RecordLogWriter? _senseLog;
  final Stopwatch _clock = Stopwatch()..start();
  final SenseWindow _window = SenseWindow();
  final UwbThrottle _uwbThrottle = UwbThrottle();
  final Set<String> _uwbAsked = {};
  final Map<String, String> _uwbUuidOf = {};

  /// Record the table mirrors the experiment into its own session log
  /// while it runs.
  void Function(String kind, Map<String, Object?> fields)? mirror;

  TableNightService get _tn => TableNightService.instance;

  /// What this phone heard itself in the last 2 minutes: advert key ->
  /// median RSSI (the radar's offline view: distance from me only).
  Map<String, double> get recentPeers {
    final by = <String, List<int>>{};
    for (final x in _recent) {
      final a = x.advert;
      if (a != null && a.peerKey != _selfKey) (by[a.peerKey] ??= []).add(x.rssi);
    }
    return {for (final e in by.entries) e.key: median(e.value)};
  }

  // ---------------------------------------- Record the table (camera)

  /// A recording runs on this phone: it advertises with the camera flag
  /// (a fixed anchor, never a seat) and logs every scan into the recording
  /// even outside a game. Only if Bluetooth was already allowed: a
  /// recording never asks, and works the same with Bluetooth off.
  bool _recording = false;
  bool _soon = false;
  String? _selfDevice;
  final RadioHealth _health = RadioHealth(cooldownMs: 30000, silenceMs: 1 << 30);

  bool get camera => _recording;

  Future<void> startRecording() async {
    if (!bleSupported || _recording) return;
    try {
      _selfDevice ??= await deviceIdFor(await SharedPrefsStore.open());
    } catch (_) {
      return;
    }
    _recording = true;
    _line('role', {'role': 'camera', 'device': _selfDevice, 'allowed': allowed});
    _loopNight = '-'; // re-evaluate the advert and restart the loop
    await _onNightAsync();
  }

  Future<void> stopRecording() async {
    if (!_recording) return;
    _recording = false;
    _loopNight = '-';
    await _onNightAsync();
  }

  /// A line in the experiment's logs (local JSONL and, while recording,
  /// the recording), e.g. Leave-on-the-table enter / exit.
  void note(String kind, Map<String, Object?> fields) => _line(kind, fields);

  /// After TableNightService.init. Starts scanning only if Bluetooth was
  /// already allowed on an earlier run. Never throws.
  Future<void> init() async {
    if (_started || !bleSupported) return;
    _started = true;
    try {
      WidgetsBinding.instance.addObserver(this);
      _tn.addListener(_onNight);
      allowed = await bleAllowed();
      if (allowed) await _go();
    } catch (e) {
      debugPrint('nearby init: $e');
    }
  }

  /// The "Find a game nearby" / hosting button: shows the OS prompt.
  Future<bool> enable() async {
    if (!bleSupported) return false;
    allowed = await bleRequest();
    notifyListeners();
    if (allowed) await _go();
    return allowed;
  }

  Future<void> _go() async {
    poweredOn = await blePoweredOn();
    uwb = await uwbSupported();
    if (!kIsWeb && Platform.isAndroid) unawaited(refreshUwb());
    _events ??= bleEvents().listen(_onEvent, onError: (_) {});
    await _onNightAsync();
    _schedule(Duration.zero);
    notifyListeners();
  }

  // ------------------------------------------------------------ the loop

  bool get _inGame => _tn.night != null;

  /// Scans are readings (logged), not just a search for games.
  bool get _sensing => _inGame || _recording;

  Duration get _interval {
    if (_sensing) return const Duration(seconds: 30);
    // Nobody hosting for a while: look less often.
    return _quietScans > 9 ? const Duration(seconds: 60) : const Duration(seconds: 20);
  }

  /// The Bluetooth distance test owns the radio while it is open: no
  /// loop scans, and its own advert.
  bool _paused = false;

  void pauseForTest() {
    _paused = true;
    _timer?.cancel();
  }

  /// Back to normal: whatever this phone should advertise, and the loop.
  Future<void> resumeAfterTest() async {
    _paused = false;
    advertising = null;
    _loopNight = '-';
    await bleStopAdvertising();
    if (allowed) await _onNightAsync();
  }

  /// Out of a game, the search for hosts runs only while the Play tab is
  /// on screen (battery): the shell switches this as tabs change.
  bool _looking = false;
  bool get looking => _looking;

  void setLooking(bool on) {
    if (on == _looking) return;
    _looking = on;
    if (!_started || !allowed || _paused) return;
    if (on) {
      _schedule(Duration.zero);
    } else if (!_sensing) {
      _timer?.cancel();
    }
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (!allowed || _paused) return;
    // Out of a game, only look while the app and the Play tab are on screen.
    if (!_sensing && (!_foreground || !_looking)) return;
    _timer = Timer(d, () async {
      await _scanOnce();
      final soon = _soon;
      _soon = false;
      _schedule(soon ? const Duration(seconds: 2) : _interval);
    });
  }

  Future<void> _scanOnce() async {
    if (_scanning) return;
    _scanning = true;
    final t0 = DateTime.now().millisecondsSinceEpoch;
    try {
      poweredOn = await blePoweredOn();
      final got = poweredOn ? await bleScan(4000) : const <BleSighting>[];
      final now = DateTime.now().millisecondsSinceEpoch;
      _recent
        ..removeWhere((s) => s.ms < now - 120000)
        ..addAll(got);
      final mine = _tn.night?.nightId;
      final g = gamesIn(_recent, sinceMs: now - 120000).where((x) => x.advert.nightId != mine).toList();
      _quietScans = g.isEmpty ? _quietScans + 1 : 0;
      final changed = g.length != games.length || [for (var i = 0; i < g.length; i++) g[i].advert.nightId != games[i].advert.nightId].any((x) => x);
      games = g;
      if (changed) notifyListeners();
      if (_sensing) await _sense(got, scanMs: now - t0);
    } catch (e) {
      debugPrint('nearby scan: $e');
    } finally {
      _scanning = false;
    }
  }

  // ------------------------------------------------------- advertising

  String? get _selfKey {
    final n = _tn.night;
    if (n == null) return _recording && _selfDevice != null ? 'D:$_selfDevice' : null;
    return n.isOrganizer ? 'H:${n.nightId}' : 'D:${n.deviceId}';
  }

  int get _flags =>
      (uwb ? flagUwb : 0) | (!kIsWeb && Platform.isIOS ? flagIos : 0) | (_recording || _tn.isCamera ? flagCamera : 0);

  void _onNight() => unawaited(_onNightAsync());

  Future<void> _onNightAsync() async {
    if (!allowed || _paused) return;
    final n = _tn.night;
    String? want;
    String? name;
    if (n != null) {
      want = n.isOrganizer
          ? advertUuid(GameAdvert(n.nightId, n.ticket.secret, flags: _flags))
          : advertUuid(PresenceAdvert(n.deviceId, nightTagOf(n.nightId), flags: _flags));
      if (n.isOrganizer) name = n.ticket.organizerName;
    } else if (_recording && _selfDevice != null) {
      // Recording outside a game: presence only (night tag 0), as a camera.
      want = advertUuid(PresenceAdvert(_selfDevice!, 0, flags: _flags));
    }
    if (want != advertising) {
      advertising = want;
      if (want == null) {
        await bleStopAdvertising();
        if (uwb) await uwbStop();
      } else {
        advertiseFailed = !await bleAdvertise(want,
            name: name, connectable: uwb && !kIsWeb && Platform.isAndroid && n != null);
        if (uwb) await uwbStart(n?.deviceId ?? _selfDevice!);
      }
      notifyListeners();
    }
    // TableNightService also notifies on every upload status change: only
    // a different night restarts the loop.
    final changed = n?.nightId != _loopNight;
    _loopNight = n?.nightId;
    if (n != null && _senseNight != n.nightId) await _openSense(n);
    if (n == null) {
      _senseNight = null;
      _senseLog = null;
    }
    if (changed) _schedule(_sensing ? const Duration(seconds: 2) : _interval);
  }

  // ----------------------------------------------- seating experiment

  Future<void> _openSense(LocalTableSync n) async {
    _senseNight = n.nightId;
    _window.take(0);
    _uwbAsked.clear();
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/sense');
      await dir.create(recursive: true);
      _senseLog = RecordLogWriter(FileLineSink(File('${dir.path}/${n.nightId}.jsonl')),
          wallMs: () => DateTime.now().millisecondsSinceEpoch, elapsedMs: () => _clock.elapsedMilliseconds);
    } catch (_) {
      _senseLog = null;
    }
    // Once per join: which phone this is (the analysis corrects RSSI per
    // model).
    if (!n.log.events.any((e) => e.kind == EventKind.device)) {
      final dev = await deviceInfo();
      final app = await PackageInfo.fromPlatform().then((p) => '${p.version}+${p.buildNumber}', onError: (_) => null);
      final data = {
        'model': dev?['model'],
        'maker': dev?['manufacturer'],
        'os': dev?['os'],
        'app': app,
        'uwb': uwb,
        'key': _selfKey,
        if (_recording || _tn.isCamera) 'role': 'camera',
      };
      await n.appendEvent(EventKind.device, data);
      _line('device', {'night': n.nightId, 'device': n.deviceId, ...data});
    }
  }

  void _line(String kind, Map<String, Object?> fields) {
    try {
      _senseLog?.write(kind, fields);
    } catch (_) {}
    mirror?.call('sense_$kind', fields);
  }

  Future<void> _sense(List<BleSighting> got, {required int scanMs}) async {
    final n = _tn.night;
    final peers = scanPeers(got, selfKey: _selfKey);
    final state = await _phoneState();
    _line('scan', {...scanLine(peers, scanMs: scanMs), ...state, if (_recording) 'role': 'camera'});
    final now = DateTime.now().millisecondsSinceEpoch;
    if (n != null) {
      _window.addScan(peers, now);
      if (_window.startMs != null && now - _window.startMs! >= 55000) {
        // Android UWB: the minute's counts, and every 10 minutes the night
        // so far (only from phones with UWB hardware).
        final ua = uwbTelemetry.takeMinute();
        final hw = uwbTelemetry.capability?.hardware == true;
        final nightDue = hw && now - _uwbNightAt >= 600000;
        if (nightDue) _uwbNightAt = now;
        await n.appendEvent(EventKind.sense, _window.take(now, extra: {
          ...state,
          if (ua != null) 'ua': ua,
          if (nightDue) 'uaN': uwbTelemetry.night(),
        }));
      }
    }
    if (_recording) await _checkDeaf(now);
    if (uwb) await _rangeNew(got);
  }

  /// While recording: the distance test's deaf-spell logic, per scan. A
  /// scan that hears under 10% of the last few scans' average (all
  /// devices, not just Felt Notes) starts a spell; the next scan comes at
  /// once instead of in 30 s (a fresh scan is the restart), and the spell
  /// ends, with its duration, when the count is back to half.
  Future<void> _checkDeaf(int now) async {
    final st = await bleStatus();
    if (st == null) return;
    final heard = _health.heard(st);
    // Bursts: each scan is a new one, so "scan running" is true by design.
    final heals = _health.check({...st, 'scan': true, 'advert': true}, nowMs: now, heardAll: heard.$1);
    for (final (k, f) in _health.events) {
      _line(k, {...f, 'heard_felt': heard.$2});
    }
    for (final (a, why) in heals) {
      if (a != HealAction.scan) continue;
      _line('self_heal', {'what': 'scan', 'reason': why});
      _soon = true;
    }
  }

  Future<Map<String, Object?>> _phoneState() async {
    int? bat;
    bool? chg;
    try {
      final b = Battery();
      bat = await b.batteryLevel;
      final st = await b.batteryState;
      chg = st == BatteryState.charging || st == BatteryState.full;
    } catch (_) {}
    return {'fg': _foreground, 'scr': await screenOn(), 'bat': bat, 'chg': chg};
  }

  /// iPhone pairs: the phone whose own key sorts first starts the token
  /// exchange (both sides decide the same way). One attempt per advert
  /// until the native side says that session ended or failed.
  Future<void> _rangeNew(List<BleSighting> got) async {
    final me = _selfKey;
    if (me == null) return;
    if (!kIsWeb && Platform.isAndroid) return _rangeAndroid(got, me);
    for (final s in got) {
      final a = s.advert;
      if (a == null || !a.uwb || !a.ios || me.compareTo(a.peerKey) >= 0) continue;
      final uuid = s.uuids.firstWhere((u) => parseAdvertUuid(u) != null).toLowerCase();
      if (!_uwbAsked.add(uuid)) continue;
      _line('uwb_ask', {'p': a.peerKey});
      await uwbRange(uuid);
    }
  }

  // ------------------------------------------------ Android-Android UWB

  final UwbTelemetry uwbTelemetry = UwbTelemetry();
  final AndroidUwb _androidUwb = AndroidUwb();
  final Set<String> _uwbPeersSeen = {};
  final Map<String, int> _uwbLastRanged = {};
  int _uwbNightAt = 0;

  /// Android phones with UWB in the advert (and not iPhones: no
  /// iPhone-Android UWB), the controller side only, a couple at a time,
  /// longest-unranged first.
  Future<void> _rangeAndroid(List<BleSighting> got, String me) async {
    final uuidOf = <String, String>{};
    for (final s in got) {
      final a = s.advert;
      if (a == null || !a.uwb || a.ios) continue;
      if (_uwbPeersSeen.add(a.peerKey)) {
        _line('uwb_android', {'stage': 'peer_seen', 'peer': a.peerKey, 'platform': 'android', 'uwb': true,
          'controller': isController(me, a.peerKey)});
      }
      if (!isController(me, a.peerKey)) continue;
      uuidOf[a.peerKey] = s.uuids.firstWhere((u) => parseAdvertUuid(u) != null).toLowerCase();
    }
    if (uuidOf.isEmpty) return;
    final active = {for (final e in uuidOf.entries) if (_uwbAsked.contains(e.value)) e.key};
    for (final peer in pickPeers(uuidOf.keys, active: active, lastRangedMs: _uwbLastRanged)) {
      final uuid = uuidOf[peer]!;
      _uwbAsked.add(uuid);
      _uwbLastRanged[peer] = DateTime.now().millisecondsSinceEpoch;
      _line('uwb_android', {'stage': 'range_request', 'peer': peer});
      await _androidUwb.range(uuid, peer);
    }
  }

  /// Android with UWB hardware: what it can do now (logged once a night,
  /// and again after the permission was asked).
  Future<void> refreshUwb() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final c = await _androidUwb.capability();
    uwbTelemetry.capability = c;
    if (c.hardware || c.feature) _line('uwb_android', {'stage': 'capability', ...c.toJson()});
    final was = uwb;
    uwb = c.usable;
    if (uwb != was) {
      advertising = null; // the advert's UWB bit and connectability change
      _loopNight = '-';
      await _onNightAsync();
    }
  }

  void _onEvent(Map<String, Object?> e) {
    switch (e['type']) {
      case 'uwb_android':
        uwbTelemetry.onStage(e);
        _line('uwb_android', Map.of(e)..remove('type'));
      case 'uwb':
        final peer = '${e['peer']}';
        final m = (e['m'] as num?)?.toDouble();
        if (m == null) return;
        final dir = (e['dir'] as List?)?.map((x) => (x as num).toDouble()).toList();
        final s = UwbSample('D:$peer', m, (e['t'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
            direction: dir);
        _window.addUwb(s);
        if (e['android'] == true) uwbTelemetry.onReading(s.peer, m);
        final az = (e['az'] as num?)?.toDouble(), el = (e['el'] as num?)?.toDouble();
        if (_uwbThrottle.keep(s)) {
          _line('uwb', {
            'p': s.peer,
            'm': m,
            if (dir != null) 'dir': dir,
            if (az != null) 'az': az,
            if (el != null) 'el': el,
            if (e['android'] == true) 'android': true,
          });
        }
      case 'uwbState':
        _line('uwb_state', {
          if (e['peer'] != null) 'p': 'D:${e['peer']}',
          'state': e['state'],
          if (e['why'] != null) 'why': e['why'],
        });
        final st = e['state'], uuid = (e['uuid'] as String?)?.toLowerCase(), peer = e['peer'] as String?;
        if (uuid != null && peer != null) _uwbUuidOf[peer] = uuid;
        if (st == 'ended' || st == 'failed') {
          // Free that advert for another try on a later scan.
          final u = uuid ?? (peer == null ? null : _uwbUuidOf[peer]);
          if (u != null) _uwbAsked.remove(u);
        }
      case 'bt':
        poweredOn = e['on'] == true;
        if (_sensing) _line('ble_event', e);
        notifyListeners();
      case 'scanFailed':
      case 'advert':
      case 'screen':
        if (_sensing) _line('ble_event', e);
    }
  }

  /// The calibration diagram's answer (ground truth for the analysis).
  Future<void> recordSeat(double x, double y, double angle) async {
    final n = _tn.night;
    if (n == null) return;
    final data = {'x': (x * 1000).round() / 1000, 'y': (y * 1000).round() / 1000, 'a': angle.round()};
    await n.appendEvent(EventKind.seat, data);
    _line('seat', data);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.hidden) return;
    if (fg == _foreground) return;
    _foreground = fg;
    if (_inGame) _line(fg ? 'foreground' : 'background', {'platform': defaultTargetPlatform.name});
    if (fg) {
      _schedule(const Duration(seconds: 1));
    } else if (!_inGame) {
      _timer?.cancel();
    }
  }
}
