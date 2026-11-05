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

/// Nights this phone left (or whose host ended them) with something still
/// to upload, comma-separated: drained on every launch until the cloud has
/// all of it (the log itself never leaves the phone's storage).
const _outboxKey = 'sync.outbox';

class TableNightService extends ChangeNotifier with WidgetsBindingObserver {
  TableNightService._();
  static final instance = TableNightService._();

  /// Tests: a second service on the same storage, as after an app restart.
  @visibleForTesting
  factory TableNightService.restarted() => TableNightService._();

  /// Tests: the app process dies (timers stop, nothing is flushed).
  @visibleForTesting
  Future<void> debugKill() async {
    for (final t in _drains) {
      t.cancel();
    }
    _drains.clear();
    _cloudRetry?.cancel();
    _endWatch?.cancel();
    final s = night;
    night = null;
    _bridge = null;
    await s?.dispose();
    _home?.removeListener(_onHome);
  }

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
    if (_started) {
      // A new home-game model (tests build one each): follow that one.
      if (!identical(home, _home)) {
        _home?.removeListener(_onHome);
        _home = home;
        home.addListener(_onHome);
      }
      return;
    }
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
      await _drainOutbox();
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

  /// Turns the hand-logger night [s] into a table night (QR + TV). The
  /// host's own cards and taps stay on the phone unless they turn sharing on.
  Future<LocalTableSync> organize(HomeSession s, {bool sharing = false}) async {
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

  /// A table night with no hand logger behind it, for Record the table
  /// hosting phones nearby: no seats and no hands, just a night that
  /// others can join and log into. Already in a night: that one (a player
  /// cannot host, and an organizer's own night is the one to share).
  Future<LocalTableSync> organizeStandalone(String name, {String? role}) async {
    final have = night;
    if (have != null) return have;
    final store = _store ??= await SharedPrefsStore.open();
    final cloud = await openCloud();
    final sync = await LocalTableSync.organize(store, organizerName: name, selfPid: 'host', cloud: cloud, role: role);
    await sync.log.setMeta('standalone', true);
    await _attach(sync);
    return sync;
  }

  /// The current night is a standalone one ([organizeStandalone]).
  bool get standalone => night?.log.meta['standalone'] == true;

  /// This phone is in the night as a camera (Record the table), not a player.
  bool get isCamera {
    final s = night;
    if (s == null) return false;
    for (final e in s.log.events) {
      if (e.kind == EventKind.join) return e.data['role'] == 'camera';
    }
    return false;
  }

  /// Ends a standalone night (the recording that hosted it stopped).
  Future<void> endStandalone() async {
    final s = night;
    if (s == null || s.log.meta['standalone'] != true) return;
    await s.endNight();
    await _release(s);
  }

  // --------------------------------------------------------------- player

  Future<LocalTableSync> join(JoinTicket t,
      {required String name,
      String? claimPid,
      required int scannedAtMs,
      required bool sharing,
      bool seatSignals = true,
      String? role}) async {
    await _detach();
    final store = _store ??= await SharedPrefsStore.open();
    final cloud = await openCloud();
    final sync = await LocalTableSync.join(store, t,
        name: name,
        claimPid: claimPid,
        scannedAtMs: scannedAtMs,
        sharing: sharing,
        seatSignals: seatSignals,
        cloud: cloud,
        role: role);
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
    _endWatch?.cancel();
    _endWatch = null;
    _bridge = null;
    _reattachTried = null; // a Resume / Undo may bring it back
    await _store?.remove(_currentKey);
    await _setOutbox(s.nightId, true);
    s.uploader?.flushNow();
    _finishing = s;
    notifyListeners();
    _drainThenDispose(s);
  }

  LocalTableSync? _finishing;
  final List<Timer> _drains = [];

  List<String> _outbox() =>
      (_store?.get(_outboxKey) ?? '').split(',').where((x) => x.isNotEmpty).toList();

  Future<void> _setOutbox(String id, bool add) async {
    final o = _outbox()..remove(id);
    if (add) o.add(id);
    await _store?.set(_outboxKey, o.join(','));
  }

  /// At launch: every night left with something unsent goes on uploading
  /// (its own log, its sharing choices as they were).
  Future<void> _drainOutbox() async {
    final store = _store;
    if (store == null) return;
    for (final id in _outbox()) {
      if (id == night?.nightId) {
        await _setOutbox(id, false);
        continue;
      }
      final s = await LocalTableSync.resume(store, id, cloud: await openCloud());
      if (s == null) {
        await _setOutbox(id, false);
        continue;
      }
      s.startSync();
      _drainThenDispose(s);
    }
  }

  /// Keep trying for a while (10 minutes, enough for held cards to come
  /// due) so the last of the night reaches the cloud. Whatever is still
  /// unsent then stays in the outbox for the next launch; the log stays on
  /// the phone either way.
  void _drainThenDispose(LocalTableSync s) {
    var tries = 0;
    late Timer timer;
    timer = Timer.periodic(const Duration(seconds: 15), (t) async {
      tries++;
      final up = s.uploader;
      if (night == s) {
        t.cancel(); // resumed: it is the current night again
        _drains.remove(timer);
        return;
      }
      final done = up != null && !up.pending && !up.holdingCards;
      if (done || up == null || tries > 40) {
        t.cancel();
        _drains.remove(timer);
        if (done) await _setOutbox(s.nightId, false);
        if (_finishing == s) _finishing = null;
        await s.dispose();
        return;
      }
      await up.drainOnce();
    });
    _drains.add(timer);
  }

  // ------------------------------------------------------ the host's end

  /// A joined player: how often the cloud is asked whether the host ended
  /// the game (one read per uploaded log; the host's End uploads at once).
  /// Night 3QRM3V67: the pad checked every 90 s and only while it was on
  /// screen, so a phone that slept or sat on another screen kept showing
  /// the game for 11 minutes.
  static Duration endCheckEvery = const Duration(seconds: 45);

  Timer? _endWatch;
  bool _checkingEnd = false;
  int _lastEndCheckMs = 0;

  /// "Sage ended the game", set once when this phone left because the
  /// host ended; whoever shows it calls [takeHostEnded].
  final hostEnded = ValueNotifier<String?>(null);

  /// The message, once (the pad or the shell, whichever is first).
  String? takeHostEnded() {
    final m = hostEnded.value;
    if (m != null) hostEnded.value = null;
    return m;
  }

  /// (Re)starts the periodic check for a joined player's night, whatever
  /// screen is showing (root zone: it belongs to the app, not a screen).
  void watchHostEnd() {
    _endWatch?.cancel();
    _endWatch = null;
    final s = night;
    if (s == null || s.isOrganizer) return;
    _endWatch = Zone.root.run(() => Timer.periodic(endCheckEvery, (_) => unawaited(checkHostEnded())));
  }

  /// The host's Bluetooth advert went quiet: ask the cloud (at most every
  /// 30 s; a quiet advert alone never ends anything).
  Future<bool> hostMaybeGone() async {
    if (DateTime.now().millisecondsSinceEpoch - _lastEndCheckMs < 30000) return false;
    return checkHostEnded();
  }

  /// A joined player: fetches the night ([fetch]) and, if the host's log
  /// says it ended, leaves (the leave uploads in the background) and sets
  /// [hostEnded]. Never throws.
  Future<bool> checkHostEnded({bool fetch = true}) async {
    final s = night;
    if (s == null || s.isOrganizer || _checkingEnd) return false;
    _checkingEnd = true;
    try {
      if (fetch) {
        _lastEndCheckMs = DateTime.now().millisecondsSinceEpoch;
        await s.refresh();
      }
      if (night != s || !s.organizerEnded) return false;
      final who = s.ticket.organizerName.isEmpty ? 'The host' : s.ticket.organizerName;
      await leave();
      hostEnded.value = '$who ended the game';
      return true;
    } catch (_) {
      return false;
    } finally {
      _checkingEnd = false;
    }
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

  /// Seat-finding signals (Bluetooth) to the table: ON by default.
  bool get sharingSeat => night?.sharingSeat ?? true;

  Future<void> setSharingSeat(bool on) async {
    final s = night;
    if (s == null) return;
    await s.setSharingSeat(on);
    s.uploader?.flushNow();
    notifyListeners();
  }

  Timer? _cloudRetry;

  /// The cloud failed to start when this night began: try again (every
  /// 30 s while a night is on, or now from the "retry" button). Returns
  /// whether the night has a cloud now.
  Future<bool> retryCloud() async {
    final s = night;
    if (s == null) return false;
    if (s.cloud != null) {
      s.uploader?.flushNow();
      return true;
    }
    final c = await openCloud();
    if (c == null || night != s) return false;
    s.attachCloud(c);
    notifyListeners();
    return true;
  }

  void _watchCloud() {
    _cloudRetry?.cancel();
    if (night?.cloud != null) return;
    _cloudRetry = Timer.periodic(const Duration(seconds: 30), (t) async {
      if (night == null || await retryCloud()) t.cancel();
    });
  }

  /// Upload right now (button, or app lifecycle).
  void flush() => night?.uploader?.flushNow();

  Future<void> _attach(LocalTableSync s) async {
    night = s;
    await _store?.set(_currentKey, s.nightId);
    // Nobody listens live on a phone (the TV does): saves a read per
    // change per phone. The pad fetches once on demand.
    s.startSync(onStatus: notifyListeners);
    _watchCloud();
    watchHostEnd();
    if (s.isOrganizer && s.log.meta['standalone'] != true) {
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

  bool _reattaching = false;
  String? _reattachTried;

  /// A night that ended came back (History → Resume, or Undo): pick up its
  /// table night again, the same code, so joined phones keep working.
  Future<void> _reattach(HomeSession session) async {
    if (_reattaching) return;
    _reattaching = true;
    try {
      final store = _store;
      if (store == null) return;
      LocalTableSync? s;
      final f = _finishing;
      if (f != null && f.log.meta['session'] == session.id) {
        s = f; // still uploading its end: keep that one
        _finishing = null;
      } else {
        for (final id in storedNights(store)) {
          final log = await EventLog.open(store, id, await deviceIdFor(store));
          if (log.meta['session'] == session.id && log.meta['role'] == 'organizer') {
            s = await LocalTableSync.resume(store, id, cloud: await openCloud());
            break;
          }
        }
      }
      if (s == null || _home?.active != session) return;
      await _attach(s);
    } catch (_) {
      // Not found or storage trouble: the night goes on, local only.
    } finally {
      _reattaching = false;
    }
  }

  Future<void> _onHomeAsync() async {
    final active = _home?.active;
    // Once per night that becomes the active one (not on every tap).
    if (night == null && active != null && active.id != _reattachTried) {
      _reattachTried = active.id;
      await _reattach(active);
    }
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
    if (!identical(this, instance)) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.resumed) {
      night?.uploader?.flushNow();
      _finishing?.uploader?.flushNow();
    }
    // Back on screen (the phone slept through the host's End): ask now,
    // not at the next tick.
    if (state == AppLifecycleState.resumed) unawaited(checkHostEnded());
  }

  // ---------------------------------------------------------------- views

  /// Connected or not, and why, for the host's QR sheet and the radar:
  /// "Connected · last upload 1 min ago" or "Offline: <reason>".
  CloudStatus cloudStatus() {
    final s = night;
    if (s == null) return const CloudStatus(false, 'Offline: not in a table night.');
    final up = s.uploader;
    if (s.cloud == null || up == null) {
      return CloudStatus(
          false,
          cloudError == null
              ? 'Offline: this build has no cloud.'
              : 'Offline: the cloud did not start (${_short(cloudError!)}). Trying again every 30 s.');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final ok = up.lastOkMs;
    final last = ok == null ? 'never uploaded' : 'last upload ${_ago(now - ok)}';
    final err = up.lastError;
    if (err != null) {
      final at = up.lastErrorAtMs == null ? '' : ' ${_ago(now - up.lastErrorAtMs!)}';
      return CloudStatus(false, 'Offline: ${up.lastErrorStep ?? 'upload'} failed$at (${_short('$err')}). $last; retrying.');
    }
    if (ok == null) return CloudStatus(false, up.attempts == 0 ? 'Connecting…' : 'Connecting (signing in)…');
    return CloudStatus(true, 'Connected · $last${up.pending ? ' · sending…' : ''}');
  }

  static String _short(String e) {
    final one = e.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 140 ? '${one.substring(0, 140)}…' : one;
  }

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
    if (up.holdingCards) return 'Up to date${ago == null ? '' : ' ($ago)'}. Cards go up 20 minutes after you enter them.';
    return ok == null ? 'Connecting…' : 'Up to date ($ago).';
  }

  /// A player who joins someone's night: what stays on the phone (all of
  /// it, unless they turn sharing on).
  static const joinerPrivateLine = 'Your cards and hands stay on this phone. The table sees that you '
      'joined (your name) and, for the seat radar, which phones yours hears over Bluetooth.';

  /// The seat-signal switch, in one line.
  static const seatSignalsLine = 'On (the default): which Felt Notes phones yours hears over Bluetooth, '
      'how strongly, and your phone model, so the seat radar can tell who sits where. Nothing about '
      'your cards or actions.';

  /// The joiner's advanced switch, in one line.
  static const joinerSharingLine = 'Off (the default): nothing about your hands leaves this phone. On: your '
      'taps (call / raise), the cards you enter (20 minutes later) and your stats go to the '
      'table and its TV.';

  /// What the switch says it shares, in one line.
  static const sharingLine =
      'On: your taps (call / raise), the cards you enter (20 minutes '
      'later) and your stats show on the table TV. Off: they stay on this phone; '
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

/// [TableNightService.cloudStatus]: one line, and whether the night is
/// reaching the cloud.
class CloudStatus {
  final bool connected;
  final String line;
  const CloudStatus(this.connected, this.line);
}

String _ago(int ms) {
  final s = ms ~/ 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  return '${s ~/ 3600} h ago';
}

/// The TV page for a night, on the web app.
String tvUrl(JoinTicket t) => 'https://sagearbor.github.io/texasHoldemGTO/#/tv?c=${t.code}';
