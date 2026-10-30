/// The one table night this phone is in, for the whole app: organizer
/// (mirroring the hand logger through [OrganizerBridge]) or player (the
/// table pad). Survives restarts (the night id is stored; the log is the
/// state), uploads in the background while the app is open, and flushes
/// when the app goes to the background or comes back.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../homegame/blind_clock_controller.dart';
import '../homegame/home_game.dart';
import 'cloud_config.dart';
import 'event_log.dart';
import 'night_events.dart';
import 'night_merge.dart';
import 'organizer_bridge.dart';
import 'table_sync.dart';

const _currentKey = 'sync.current';
const _optInKey = 'sync.tableNightOnStart';

class TableNightService extends ChangeNotifier with WidgetsBindingObserver {
  TableNightService._();
  static final instance = TableNightService._();

  KeyValueStore? _store;
  HomeGameModel? _home;
  LocalTableSync? night;
  OrganizerBridge? _bridge;
  bool _started = false;

  /// "Let other phones and a TV join" on the setup screen: remembered.
  bool startWithTableNight = true;

  bool get active => night != null;

  /// [init] ran (the app does it at launch; widget tests of single screens
  /// do not, and then no table night is started behind their back).
  bool get ready => _started;
  bool get isOrganizer => night?.isOrganizer ?? false;

  /// The hand-logger night the organizer's table night mirrors.
  String? get sessionId => night?.log.meta['session'] as String?;

  bool linkedTo(HomeSession s) => isOrganizer && sessionId == s.id;

  /// Attach once, after the home-game model has loaded. Never throws.
  Future<void> init(HomeGameModel home, {KeyValueStore? store}) async {
    if (_started) return;
    _started = true;
    _home = home;
    try {
      _store = store ?? await SharedPrefsStore.open();
      startWithTableNight = _store!.get(_optInKey) != 'off';
      home.addListener(_onHome);
      BlindClockController.shared.addListener(_onClock);
      WidgetsBinding.instance.addObserver(this);
      final id = _store!.get(_currentKey);
      if (id != null) {
        final cloud = await openCloud();
        final s = await LocalTableSync.resume(_store!, id, cloud: cloud);
        if (s != null) await _attach(s);
      }
    } catch (_) {
      // Storage trouble: table nights simply stay off this run.
    }
  }

  Future<void> setStartWithTableNight(bool on) async {
    startWithTableNight = on;
    notifyListeners();
    await _store?.set(_optInKey, on ? 'on' : 'off');
  }

  // ------------------------------------------------------------ organizer

  /// Turns the hand-logger night [s] into a table night (QR + TV).
  Future<LocalTableSync> organize(HomeSession s, {bool sharing = true}) async {
    if (linkedTo(s)) return night!;
    await _detach();
    final store = _store ??= await SharedPrefsStore.open();
    final cloud = await openCloud();
    final sync = await LocalTableSync.organize(store,
        organizerName: s.heroName, selfPid: s.heroName, roster: rosterOf(s), sharing: sharing, cloud: cloud);
    await sync.log.setMeta('session', s.id);
    await _attach(sync);
    return sync;
  }

  // --------------------------------------------------------------- player

  Future<LocalTableSync> join(JoinTicket t,
      {required String name, String? claimPid, required int scannedAtMs, required bool sharing}) async {
    await _detach();
    final store = _store ??= await SharedPrefsStore.open();
    final cloud = await openCloud();
    final sync = await LocalTableSync.join(store, t,
        name: name, claimPid: claimPid, scannedAtMs: scannedAtMs, sharing: sharing, cloud: cloud);
    await _attach(sync);
    return sync;
  }

  /// A player done for the night: records leaving and keeps uploading in
  /// the background until the cloud has it.
  Future<void> leave() async {
    final s = night;
    if (s == null) return;
    if (!s.isOrganizer) await s.leave();
    await _release(s);
  }

  /// Stops being in [s] (if it is still the current night: a new night may
  /// have been started meanwhile).
  Future<void> _release(LocalTableSync s) async {
    if (night != s) return;
    night = null;
    _bridge = null;
    await _store?.remove(_currentKey);
    s.uploader?.flushNow();
    _finishing = s;
    notifyListeners();
    _drainThenDispose(s);
  }

  LocalTableSync? _finishing;

  /// Keep trying for a while so the last taps reach the cloud; the log
  /// stays on the phone either way (and goes up the next time it is
  /// opened from the past nights list, if ever).
  void _drainThenDispose(LocalTableSync s) {
    var tries = 0;
    Timer.periodic(const Duration(seconds: 15), (t) async {
      tries++;
      final up = s.uploader;
      if (up == null || !up.pending || tries > 40) {
        t.cancel();
        if (_finishing == s) _finishing = null;
        await s.dispose();
        return;
      }
      await up.drainOnce();
    });
  }

  // --------------------------------------------------------------- shared

  Future<void> setSharing(bool on) async {
    final s = night;
    if (s == null) return;
    await s.setSharing(on);
    s.uploader?.flushNow();
    notifyListeners();
  }

  bool get sharing => night?.sharing ?? true;

  /// Upload right now (button, or app lifecycle).
  void flush() => night?.uploader?.flushNow();

  Future<void> _attach(LocalTableSync s) async {
    night = s;
    await _store?.set(_currentKey, s.nightId);
    // Nobody listens live on a phone (the TV does): saves a read per
    // change per phone. The pad fetches once on demand.
    s.startSync(onStatus: notifyListeners);
    if (s.isOrganizer) {
      _bridge = OrganizerBridge(s);
      await _onHomeAsync();
      await _bridge!.recordClock(BlindClockController.shared.clock.toJson());
    }
    notifyListeners();
  }

  Future<void> _detach() async {
    final s = night;
    if (s != null) await _release(s);
  }

  void _onHome() => unawaited(_onHomeAsync());

  Future<void> _onHomeAsync() async {
    final s = night, b = _bridge, home = _home;
    if (s == null || b == null || home == null) return;
    final id = sessionId;
    HomeSession? session;
    for (final x in home.sessions) {
      if (x.id == id) session = x;
    }
    if (session == null) {
      // The night was deleted on this phone: stop mirroring it.
      await _release(s);
      return;
    }
    try {
      await b.reconcile(session);
    } catch (_) {
      return;
    }
    if (session.closed) {
      // Ended: the end event is in the log; finish uploading, then let go.
      await _release(s);
    }
  }

  void _onClock() {
    final b = _bridge;
    if (b == null) return;
    unawaited(b.recordClock(BlindClockController.shared.clock.toJson()).catchError((_) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.resumed) {
      night?.uploader?.flushNow();
      _finishing?.uploader?.flushNow();
    }
  }

  // ---------------------------------------------------------------- views

  /// One line, honest about where things are.
  String statusLine() {
    final s = night;
    if (s == null) return '';
    final up = s.uploader;
    if (s.cloud == null || up == null) {
      return cloudError == null
          ? 'Saved on this phone only (no cloud in this build).'
          : 'Saved on this phone only (cloud did not start: $cloudError).';
    }
    final ok = up.lastOkMs;
    final ago = ok == null ? null : _ago(DateTime.now().millisecondsSinceEpoch - ok);
    if (up.lastError != null) {
      return 'No connection: saved on this phone, it will upload by itself${ago == null ? '' : ' (last upload $ago)'}.';
    }
    if (up.pending) return 'Saved on this phone, uploading…';
    if (up.holdingCards) return 'Up to date${ago == null ? '' : ' ($ago)'}. Cards go up once the hand is over.';
    return ok == null ? 'Connecting…' : 'Up to date ($ago).';
  }

  /// What the switch says it shares, in one line.
  static const sharingLine =
      'On: your taps (call / raise), the cards you enter (only after the hand '
      'is over) and your stats show on the table TV. Off: they stay on this phone; '
      'the TV shows you as "private".';

  MergedNight? merged() => night?.merged();

  /// The organizer's name on a night this phone joined.
  String tableName() {
    final s = night;
    if (s == null) return '';
    final n = s.ticket.organizerName;
    return n.isEmpty ? 'Table ${s.nightId}' : "$n's table";
  }
}

String _ago(int ms) {
  final s = ms ~/ 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  return '${s ~/ 3600} h ago';
}

/// The TV page for a night, on the web app.
String tvUrl(JoinTicket t) => 'https://sagearbor.github.io/texasHoldemGTO/#/tv?c=${t.code}';
