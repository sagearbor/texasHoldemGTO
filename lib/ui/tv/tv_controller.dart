/// Feeds the TV page: joins the night as a read-only member, listens to
/// every phone's log, fetches cards as they may be shown, and rebuilds the
/// [TvBoard] every few seconds (so delays run out and "last update" ages
/// even when nothing arrives). Reconnects by itself; a reload resumes from
/// the URL or the remembered code.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../pulse/pulse_cloud.dart';
import '../../pulse/pulse_firestore.dart';
import '../../sync/cloud_config.dart';
import '../../radar/radar_model.dart';
import '../../sync/cloud_logs.dart';
import '../../sync/event_log.dart';
import '../../sync/night_events.dart';
import '../../sync/night_merge.dart';
import '../../sync/tv_board.dart';

const _tvDeviceKey = 'tv.deviceId';
const lastTvCodeKey = 'tv.lastCode';

/// A night code, or a TV link containing `c=CODE`, or a join QR payload.
JoinTicket? ticketFromTvInput(String raw) {
  final s = raw.trim();
  final m = RegExp(r'[?&]c=([A-Za-z0-9\-]+)').firstMatch(s);
  return JoinTicket.parse(m?.group(1) ?? s);
}

enum TvLink { connecting, live, offline, failed }

class TvController extends ChangeNotifier {
  final JoinTicket ticket;
  final TvOptions opts;
  final int Function() now;

  /// For tests: a cloud instead of the app's Firebase.
  final Future<CloudLogs?> Function() _open;

  TvController(this.ticket, {this.opts = const TvOptions(), int Function()? now, Future<CloudLogs?> Function()? open})
      : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _open = open ?? openCloud;

  CloudLogs? _cloud;
  CardFetcher? _cards;
  StreamSubscription<List<DeviceLog>>? _sub;
  StreamSubscription<PulseNight>? _pulseSub;

  /// Pulse mode: every member's heart rate, selfie and song (empty when
  /// nobody shares).
  PulseNight pulse = PulseNight.empty;
  Timer? _tick, _retry;
  int _failures = 0;
  bool _disposed = false;
  List<DeviceLog> _logs = const [];

  TvLink link = TvLink.connecting;
  String? error;

  /// This screen's clock when the last snapshot arrived.
  int? snapshotAtMs;
  MergedNight? merged;
  TvBoard? board;

  /// Seat radar, if the organizer set the table up (a `radar` event);
  /// recomputed at most every 30 s (it is the heaviest thing here).
  RadarEstimate? radar;
  RadarInput radarInput = const RadarInput();
  int _radarAtMs = -1 << 40;

  Future<void> start() async {
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => _rebuild(fetchCards: true));
    await _connect();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    try {
      _cloud ??= await _open();
      final c = _cloud;
      if (c == null) {
        link = TvLink.failed;
        error = cloudError == null ? 'This build has no cloud.' : 'Cloud did not start: $cloudError';
        notifyListeners();
        return;
      }
      _cards ??= CardFetcher(c, ticket.nightId, now: now);
      final store = await SharedPrefsStore.open();
      final dev = await deviceIdFor(_TvStore(store));
      await c.join(ticket, deviceId: dev, name: 'TV', create: false);
      await store.set(lastTvCodeKey, ticket.code);
      await _sub?.cancel();
      _sub = c.watch(ticket.nightId).listen((logs) {
        _logs = logs;
        snapshotAtMs = now();
        link = TvLink.live;
        _failures = 0;
        error = null;
        _rebuild(fetchCards: true);
      }, onError: (Object e) => _lost(e), onDone: () => _lost('closed'));
      // Pulse: its own listener; a failure here never takes the board down
      // (the next reconnect tries again).
      await _pulseSub?.cancel();
      _pulseSub = pulseCloudFor(c)?.watch(ticket.nightId).listen((n) {
        pulse = n;
        notifyListeners();
      }, onError: (Object _) {});
    } catch (e) {
      _lost(e);
    }
  }

  void _lost(Object e) {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    _pulseSub?.cancel();
    _pulseSub = null;
    link = TvLink.offline;
    error = '$e';
    _failures++;
    notifyListeners();
    // 5 s, 10 s, 20 s ... a minute: the last board stays on screen.
    _retry?.cancel();
    _retry = Timer(Duration(seconds: min(60, 5 * (1 << min(_failures - 1, 4)))), _connect);
  }

  bool _fetching = false;

  Future<void> _rebuild({bool fetchCards = false}) async {
    if (_disposed) return;
    final org = organizerOf(_logs);
    final cards = _cards;
    var m = mergeNight(organizerDeviceId: org ?? '', logs: injectCards(_logs, cards?.got ?? const {}));
    if (fetchCards && cards != null && !_fetching) {
      _fetching = true;
      try {
        if (await cards.fill(m, opts: opts)) {
          m = mergeNight(organizerDeviceId: org ?? '', logs: injectCards(_logs, cards.got));
        }
      } finally {
        _fetching = false;
      }
    }
    if (_disposed) return;
    merged = m;
    board = buildTvBoard(m, nowMs: now(), opts: opts);
    _rebuildRadar(org);
    notifyListeners();
  }

  void _rebuildRadar(String? org) {
    final t = now();
    if (t - _radarAtMs < 30000) return;
    _radarAtMs = t;
    try {
      final cfg = radarConfigIn(_logs, organizerDevice: org);
      if (cfg == null) {
        radar = null;
        return;
      }
      final input = radarInputFrom(_logs).live(t);
      // The organizer's own phone is a player's (not the camera): pinned
      // to the organizer's seat, as on the organizer's Radar screen.
      final pin = org != null && cfg.organizerSeat != null && !input.cameras.contains(org) ? org : null;
      radarInput = input;
      radar = estimateSeats(cfg.copyWith(organizerDevice: () => pin), input, beam: 1500);
    } catch (_) {
      radar = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _retry?.cancel();
    _sub?.cancel();
    _pulseSub?.cancel();
    super.dispose();
  }
}

/// The TV keeps its own device id (a member needs one), apart from the
/// phone's own if the app on a phone is used as the TV.
class _TvStore implements KeyValueStore {
  final KeyValueStore inner;
  _TvStore(this.inner);
  String _k(String key) => key == 'sync.deviceId' ? _tvDeviceKey : key;
  @override
  String? get(String key) => inner.get(_k(key));
  @override
  Future<void> set(String key, String value) => inner.set(_k(key), value);
  @override
  Future<void> remove(String key) => inner.remove(_k(key));
  @override
  Iterable<String> keys() => inner.keys();
}
