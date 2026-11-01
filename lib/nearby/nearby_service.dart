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
import '../sync/night_events.dart';
import '../sync/table_night_service.dart';
import '../sync/table_sync.dart';
import 'ble_payload.dart';
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
    _events ??= bleEvents().listen(_onEvent, onError: (_) {});
    await _onNightAsync();
    _schedule(Duration.zero);
    notifyListeners();
  }

  // ------------------------------------------------------------ the loop

  bool get _inGame => _tn.night != null;

  Duration get _interval {
    if (_inGame) return const Duration(seconds: 30);
    // Nobody hosting for a while: look less often.
    return _quietScans > 9 ? const Duration(seconds: 60) : const Duration(seconds: 20);
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (!allowed) return;
    // Out of a game, only look while the app is on screen.
    if (!_foreground && !_inGame) return;
    _timer = Timer(d, () async {
      await _scanOnce();
      _schedule(_interval);
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
      if (_inGame) await _sense(got, scanMs: now - t0);
    } catch (e) {
      debugPrint('nearby scan: $e');
    } finally {
      _scanning = false;
    }
  }

  // ------------------------------------------------------- advertising

  String? get _selfKey {
    final n = _tn.night;
    if (n == null) return null;
    return n.isOrganizer ? 'H:${n.nightId}' : 'D:${n.deviceId}';
  }

  int get _flags => (uwb ? flagUwb : 0) | (!kIsWeb && Platform.isIOS ? flagIos : 0);

  void _onNight() => unawaited(_onNightAsync());

  Future<void> _onNightAsync() async {
    if (!allowed) return;
    final n = _tn.night;
    String? want;
    String? name;
    if (n != null) {
      want = n.isOrganizer
          ? advertUuid(GameAdvert(n.nightId, n.ticket.secret, flags: _flags))
          : advertUuid(PresenceAdvert(n.deviceId, nightTagOf(n.nightId), flags: _flags));
      if (n.isOrganizer) name = n.ticket.organizerName;
    }
    if (want != advertising) {
      advertising = want;
      if (want == null) {
        await bleStopAdvertising();
        if (uwb) await uwbStop();
      } else {
        advertiseFailed = !await bleAdvertise(want, name: name);
        if (uwb) await uwbStart(n!.deviceId);
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
    if (changed) _schedule(_inGame ? const Duration(seconds: 2) : _interval);
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
    if (n == null) return;
    final peers = scanPeers(got, selfKey: _selfKey);
    final state = await _phoneState();
    _line('scan', {...scanLine(peers, scanMs: scanMs), ...state});
    final now = DateTime.now().millisecondsSinceEpoch;
    _window.addScan(peers, now);
    if (_window.startMs != null && now - _window.startMs! >= 55000) {
      await n.appendEvent(EventKind.sense, _window.take(now, extra: state));
    }
    if (uwb) await _rangeNew(got);
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
    for (final s in got) {
      final a = s.advert;
      if (a == null || !a.uwb || !a.ios || me.compareTo(a.peerKey) >= 0) continue;
      final uuid = s.uuids.firstWhere((u) => parseAdvertUuid(u) != null).toLowerCase();
      if (!_uwbAsked.add(uuid)) continue;
      _line('uwb_ask', {'p': a.peerKey});
      await uwbRange(uuid);
    }
  }

  void _onEvent(Map<String, Object?> e) {
    switch (e['type']) {
      case 'uwb':
        final peer = '${e['peer']}';
        final m = (e['m'] as num?)?.toDouble();
        if (m == null) return;
        final dir = (e['dir'] as List?)?.map((x) => (x as num).toDouble()).toList();
        final s = UwbSample('D:$peer', m, (e['t'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
            direction: dir);
        _window.addUwb(s);
        if (_uwbThrottle.keep(s)) _line('uwb', {'p': s.peer, 'm': m, if (dir != null) 'dir': dir});
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
        notifyListeners();
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
