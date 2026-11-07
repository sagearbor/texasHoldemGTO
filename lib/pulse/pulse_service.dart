/// Pulse mode on this phone, for the whole app: follows the table night
/// this phone is in ([TableNightService]) and, only while the player has
/// turned "Share my heart rate with this table" on for that night, reads
/// the watch and uploads every 15 s. Off by default for every night;
/// turning it off stops the uploads and deletes what this phone sent (a
/// failed delete is retried until it goes through).
///
/// The switch lives in the night's log metadata (`pulse.on`), so it is per
/// night and survives a restart.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../homegame/home_game.dart';
import '../settings/dev_settings.dart';
import '../sync/cloud_config.dart';
import '../sync/event_log.dart';
import '../sync/table_night_service.dart';
import '../sync/table_sync.dart';
import 'pulse_board.dart';
import 'pulse_firestore.dart';
import 'pulse_profile.dart';
import 'pulse_protocol.dart';
import 'pulse_source.dart';
import 'pulse_uploader.dart';

const _onKey = 'pulse.on';
const _cleanupKey = 'pulse.cleanup';

/// A night that was started as a Pulse night (Play → Start a Pulse night).
const pulseNightKey = 'pulse.night';

class PulseService extends ChangeNotifier {
  PulseService._();
  static final instance = PulseService._();

  /// Tests: a service of their own.
  @visibleForTesting
  factory PulseService.forTest({PulseSource Function()? source, int Function()? now, Duration? window}) {
    final s = PulseService._();
    if (source != null) s.makeSource = source;
    if (now != null) s.now = now;
    if (window != null) s.window = window;
    return s;
  }

  /// The watch, or a pretend one in Developer mode.
  PulseSource Function() makeSource =
      () => DevSettings.simulatedPulse ? SimulatedPulseSource() : ChannelPulseSource();
  int Function() now = () => DateTime.now().millisecondsSinceEpoch;
  Duration window = const Duration(seconds: 15);

  LocalTableSync? _night;
  PulseSource? _source;
  StreamSubscription<PulseMessage>? _sub;
  PulseFilter _filter = PulseFilter();
  PulseUploader? _up;
  Timer? _cleanupRetry;
  bool _hooked = false;

  /// The latest bpm and when it was measured (this phone's view).
  int? bpm;
  int? bpmAtMs;

  /// The watch says it is measuring; [watchErr] why not ("no_permission").
  bool watchRunning = false;
  String? watchErr;
  WatchStatus status = WatchStatus.none;

  /// Follow the app's table night from now on (the app calls it at launch).
  void hook() {
    if (_hooked) return;
    _hooked = true;
    TableNightService.instance.addListener(_onTn);
    _onTn();
  }

  void _onTn() => unawaited(follow(TableNightService.instance.night));

  LocalTableSync? get night => _night;

  /// Heart rate sharing is on for the current night.
  bool get on => _night?.log.meta[_onKey] == true;

  /// The current night was started as a Pulse night.
  bool get pulseNight => _night?.log.meta[pulseNightKey] == true;

  /// This night's heart rate on this phone (while sharing was on).
  List<PulseSample> get mySamples => _up?.samples ?? const [];

  PulseUploader? get uploader => _up;

  /// Switches to [s] (null: no night). A night that had Pulse on carries
  /// on; one with a delete still owed retries it.
  Future<void> follow(LocalTableSync? s) async {
    if (identical(s, _night)) {
      // Same night; the cloud may have started late.
      if (on && _up == null) _startUploads();
      return;
    }
    await _stopReading();
    _up?.stop();
    _up = null;
    _cleanupRetry?.cancel();
    _night = s;
    bpm = null;
    bpmAtMs = null;
    if (s != null) {
      if (on) await _startSharing();
      if (s.log.meta[_cleanupKey] == true) unawaited(_cleanup());
    }
    notifyListeners();
  }

  /// "Share my heart rate with this table". Needs a profile when turning on.
  Future<void> setOn(bool v) async {
    final s = _night;
    if (s == null || v == on) return;
    await s.log.setMeta(_onKey, v);
    if (v) {
      await s.log.setMeta(_cleanupKey, false);
      _cleanupRetry?.cancel();
      await _startSharing();
    } else {
      await _stopReading(sendStop: true);
      await s.log.setMeta(_cleanupKey, true);
      unawaited(_cleanup());
    }
    notifyListeners();
  }

  Future<void> _startSharing() async {
    await PulseProfileStore.load();
    _startUploads();
    await _startReading();
  }

  void _startUploads() {
    final s = _night;
    final cloud = pulseCloudFor(s?.cloud);
    if (s == null || cloud == null || _up != null) return;
    _up = PulseUploader(
      cloud: cloud,
      nightId: s.nightId,
      deviceId: s.deviceId,
      now: now,
      window: window,
      profile: () => PulseProfileStore.profile.value ?? PulseProfile(name: s.myName),
      ensureJoined: () async {
        if (s.log.meta['up.joined'] == true) return;
        await s.cloud!.join(s.ticket, deviceId: s.deviceId, name: s.myName);
        await s.log.setMeta('up.joined', true);
      },
      onChange: notifyListeners,
    )..start();
  }

  Future<void> _startReading() async {
    if (_source != null) return;
    final src = _source = makeSource();
    _filter = PulseFilter();
    _sub = src.messages.listen(_onMessage);
    await refreshStatus();
    await src.start();
  }

  Future<void> _stopReading({bool sendStop = false}) async {
    final src = _source;
    _source = null;
    await _sub?.cancel();
    _sub = null;
    if (src != null) {
      if (sendStop) await src.stop();
      src.dispose();
    }
    watchRunning = false;
  }

  void _onMessage(PulseMessage m) {
    switch (m) {
      case PulseHr(:final samples):
        final kept = _filter.keep(samples);
        if (kept.isEmpty) return;
        bpm = kept.last.bpm;
        bpmAtMs = now();
        watchRunning = true;
        _up?.add(kept);
      case PulseState(:final running, :final err):
        watchRunning = running;
        watchErr = err;
      case PulseCtl():
        return;
    }
    notifyListeners();
  }

  /// Deletes what this phone sent for the night; retried every 30 s until
  /// it goes through (offline, or the cloud has not started yet).
  Future<void> _cleanup() async {
    final s = _night;
    if (s == null || s.log.meta[_cleanupKey] != true) return;
    final cloud = pulseCloudFor(s.cloud);
    final up = _up ??
        (cloud == null
            ? null
            : PulseUploader(
                cloud: cloud,
                nightId: s.nightId,
                deviceId: s.deviceId,
                profile: () => PulseProfile(name: s.myName),
                ensureJoined: () async {}));
    final ok = up != null && await up.wipe();
    if (_night != s) return;
    _up = null;
    if (ok) {
      await s.log.setMeta(_cleanupKey, false);
    } else {
      _cleanupRetry?.cancel();
      _cleanupRetry = Timer(const Duration(seconds: 30), () => unawaited(_cleanup()));
    }
    notifyListeners();
  }

  /// A delete is still owed to the cloud.
  bool get cleanupPending => _night?.log.meta[_cleanupKey] == true;

  Future<WatchStatus> refreshStatus() async {
    final src = _source ?? makeSource();
    try {
      status = await src.status();
    } finally {
      if (!identical(src, _source)) src.dispose();
    }
    notifyListeners();
    return status;
  }

  Future<bool> startWatch() async {
    if (_source == null) await _startReading();
    final ok = await _source!.start();
    notifyListeners();
    return ok;
  }

  Future<bool> stopWatch() async {
    final ok = await _source?.stop() ?? false;
    notifyListeners();
    return ok;
  }

  Future<bool> openWatchStore() async {
    final src = _source ?? makeSource();
    try {
      return await src.openWatchStore();
    } finally {
      if (!identical(src, _source)) src.dispose();
    }
  }

  /// The selfie or song changed: send it with the next batch.
  void profileChanged() {
    _up?.profileChanged();
    if (on) unawaited(_up?.flush());
  }

  /// Upload now (the screen's "send now", tests).
  Future<bool> flush() async => await _up?.flush() ?? false;

  /// One line for the Pulse screen.
  String statusLine() {
    final s = _night;
    if (s == null) return 'Not in a table night.';
    if (!on) return cleanupPending ? 'Off. Deleting what was sent…' : 'Off: your heart rate stays on this phone.';
    final up = _up;
    if (up == null) return 'On, but not connected yet: it stays on this phone until it is.';
    if (up.lastError != null) return 'No connection: it will send by itself.';
    final ok = up.lastOkMs;
    if (ok == null) return 'Sharing with the table…';
    final ago = (now() - ok) ~/ 1000;
    return 'Sharing with the table · sent ${ago < 5 ? 'just now' : '$ago s ago'}';
  }

  // ------------------------------------------------------ end of the night

  /// The Pulse summary of the table night behind the hand-logger night
  /// [session] (the host's recap), or null when it had no Pulse or the
  /// cloud cannot be reached. Hand numbers come from the session.
  static Future<PulseSummary?> summaryForSession(HomeSession session, {KeyValueStore? store}) async {
    try {
      final st = store ?? await SharedPrefsStore.open();
      String? nightId;
      for (final id in storedNights(st)) {
        final log = await EventLog.open(st, id, await deviceIdFor(st));
        if (log.meta['session'] == session.id) nightId = id;
      }
      if (nightId == null) return null;
      final cloud = pulseCloudFor(await openCloud());
      if (cloud == null) return null;
      final n = await cloud.fetch(nightId);
      if (!n.hasData) return null;
      final s = pulseSummary(n, handAt: handFinder(sessionHandSpans(session)));
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }
}

/// (hand number, start, end) for each hand with a start time; the last
/// one runs 8 minutes.
List<(int, int, int)> sessionHandSpans(HomeSession s) {
  final hands = [for (final h in s.hands) if (h.start != null) (h.number, h.start!)]..sort((a, b) => a.$2.compareTo(b.$2));
  return [
    for (var i = 0; i < hands.length; i++)
      (hands[i].$1, hands[i].$2, i + 1 < hands.length ? hands[i + 1].$2 : hands[i].$2 + 8 * 60000)
  ];
}
