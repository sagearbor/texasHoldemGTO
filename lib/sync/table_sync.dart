/// Multi-phone table night: the seam between the app's UI and sync.
///
/// [TableSync] is what the screens call. The organizer side (seats, "next
/// hand", undo, board, end) is the dealer bookkeeping the effortless-input
/// UI drives; the player side is the one-tap-per-played-hand input. Every
/// call only appends to this phone's local log, so it works with no network
/// at all; an [Uploader] sends the log when a connection appears, and
/// [TableSync.merged] combines this phone's log with whatever other phones
/// have uploaded.
///
/// See docs/MULTIPHONE.md, section "What the organizer UI must call".
library;

import 'dart:async';
import 'dart:math';

import '../homegame/home_game.dart';
import 'cloud_logs.dart';
import 'event_log.dart';
import 'night_events.dart';
import 'night_merge.dart';

enum NightRole { organizer, player }

abstract class TableSync {
  String get deviceId;
  String get nightId;
  NightRole get role;
  bool get isOrganizer;

  /// The organizer's ticket (for the QR) or the one this phone scanned.
  JoinTicket get ticket;

  // ------------------------------------------------ organizer bookkeeping

  /// The ticket to draw right now (fresh clock reading). Organizer only;
  /// redraw it every second while the QR is on screen.
  JoinTicket qrTicket({List<Seat>? roster});

  /// The table in clockwise order, from the next hand on. The first-orbit
  /// dealer taps produce the first call; adding or removing a player is
  /// another call with the new list. Pids are the organizer UI's own ids
  /// (players without the app get one too).
  Future<void> setSeats(List<Seat> clockwise);

  /// "Next hand": hand [handNo] starts now, dealt by [dealerPid]. The UI
  /// owns numbering and rotation ([nextDealer] helps); the timestamp of
  /// this call is the hand boundary everyone's taps are matched against.
  Future<void> startHand(int handNo, String dealerPid);

  /// The last "next hand" was a mis-tap.
  Future<void> undoHand(int handNo);

  /// Community cards if someone called them (3 to 5; call again to add).
  Future<void> recordBoard(int handNo, List<int> cards);

  Future<void> endNight();

  // ---------------------------------------------------------- any player

  /// One tap for a hand you played. Not tapping = fold. A second tap within
  /// [LocalTableSync.correctionWindow] replaces the first (mis-tap), otherwise it is the
  /// next hand.
  Future<void> tap(PreAction action, {Facing? facing});

  /// Your own hole cards (optional). Attached to the hand you are tapping
  /// in, or the start of the next entry.
  Future<void> setCards(List<int> cards);

  /// Withdraws the latest entry.
  Future<void> undoLast();

  /// Sharing with the table (the TV), per player, ON by default (the join
  /// screen asks). While off, none of this phone's taps or cards leave it.
  Future<void> setSharing(bool on);
  bool get sharing;

  Future<void> leave();

  // ---------------------------------------------------------------- views

  List<NightEvent> get localEvents;

  /// Everyone's data that has reached this phone, merged.
  MergedNight merged({MergeOptions opts = const MergeOptions()});

  /// Fires after every local append and every cloud update.
  Stream<MergedNight> watchMerged();
}

/// The next dealer clockwise after [dealerPid] in [seats], skipping
/// nobody (removing a player is a new seat list). Null for an empty table.
String? nextDealer(List<Seat> seats, String? dealerPid) {
  if (seats.isEmpty) return null;
  final i = seats.indexWhere((s) => s.pid == dealerPid);
  return seats[(i + 1) % seats.length].pid;
}

/// The local-first implementation: an [EventLog] on this phone, an optional
/// [CloudLogs] (null in the default build: local only).
class LocalTableSync implements TableSync {
  final EventLog log;
  final CloudLogs? cloud;
  final int Function() now;
  final String myName;
  @override
  final NightRole role;
  @override
  final JoinTicket ticket;

  /// A second tap this soon after the first replaces it.
  static const correctionWindow = Duration(seconds: 10);

  /// Cards and a tap this close together are the same hand.
  static const entryWindow = Duration(minutes: 3);

  Uploader? uploader;
  List<DeviceLog> _remote = const [];
  StreamSubscription<List<DeviceLog>>? _sub;
  final _out = StreamController<MergedNight>.broadcast();

  LocalTableSync._(
    this.log, {
    required this.role,
    required this.ticket,
    required this.myName,
    this.cloud,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  @override
  String get deviceId => log.deviceId;
  @override
  bool get isOrganizer => role == NightRole.organizer;
  @override
  String get nightId => log.nightId;

  /// Organizer: a fresh night. [selfPid] is the organizer's own seat id.
  static Future<LocalTableSync> organize(
    KeyValueStore store, {
    required String organizerName,
    required String selfPid,
    List<Seat> roster = const [],
    bool sharing = true,
    CloudLogs? cloud,
    int Function()? now,
    Random? rng,
  }) async {
    rng ??= Random.secure();
    final device = await deviceIdFor(store, rng: rng);
    final ticket = JoinTicket(
      nightId: randomCode(rng, nightIdLength),
      secret: randomCode(rng, secretLength),
      organizerName: organizerName,
      roster: roster,
    );
    final log = await EventLog.open(store, ticket.nightId, device);
    final s = LocalTableSync._(log, role: NightRole.organizer, ticket: ticket, myName: organizerName, cloud: cloud, now: now);
    await s._saveMeta();
    await s._append(EventKind.join, {'name': organizerName, 'claim': selfPid, 'offset': 0});
    await s._append(EventKind.share, {'on': sharing});
    if (roster.isNotEmpty) await s.setSeats(roster);
    return s;
  }

  /// Player: scanned (or typed) [t] at [scannedAtMs] on this phone's clock.
  static Future<LocalTableSync> join(
    KeyValueStore store,
    JoinTicket t, {
    required String name,
    String? claimPid,
    required int scannedAtMs,
    bool sharing = true,
    CloudLogs? cloud,
    int Function()? now,
  }) async {
    final device = await deviceIdFor(store);
    final log = await EventLog.open(store, t.nightId, device);
    final s = LocalTableSync._(log, role: NightRole.player, ticket: t, myName: name, cloud: cloud, now: now);
    await s._saveMeta();
    final offset = clockOffsetFrom(t, scannedAtMs);
    await s._append(EventKind.join, {
      'name': name,
      if (claimPid != null) 'claim': claimPid,
      if (offset != null) 'offset': offset,
    }, ms: scannedAtMs);
    await s._append(EventKind.share, {'on': sharing});
    return s;
  }

  /// Reopens a night this phone already has a log for.
  static Future<LocalTableSync?> resume(KeyValueStore store, String nightId,
      {CloudLogs? cloud, int Function()? now}) async {
    final device = await deviceIdFor(store);
    final log = await EventLog.open(store, nightId, device);
    final t = log.meta['ticket'];
    if (t is! String) return null;
    final ticket = JoinTicket.parse(t);
    if (ticket == null) return null;
    return LocalTableSync._(
      log,
      role: log.meta['role'] == 'organizer' ? NightRole.organizer : NightRole.player,
      ticket: ticket,
      myName: (log.meta['name'] as String?) ?? '',
      cloud: cloud,
      now: now,
    );
  }

  Future<void> _saveMeta() async {
    await log.setMeta('ticket', ticket.encode());
    await log.setMeta('role', role.name);
    await log.setMeta('name', myName);
    await log.setMeta('organizerDevice', role == NightRole.organizer ? deviceId : null);
    await log.setMeta('started', now());
  }

  /// The organizer's device id, once known (for a player: learned from
  /// the cloud, the device whose log has hand events).
  String? get organizerDeviceId {
    final m = log.meta['organizerDevice'];
    if (m is String) return m;
    for (final l in _remote) {
      if (l.events.any((e) => e.kind == EventKind.hand || e.kind == EventKind.seats)) return l.deviceId;
    }
    return null;
  }

  /// Starts uploading when a [cloud] is configured (no-op in a local-only
  /// build). With [listen] (the organizer) it also follows everyone else's
  /// uploads live; players fetch once on demand ([refresh]) to save reads.
  void startSync({
    Duration minInterval = const Duration(seconds: 20),
    bool listen = false,
    void Function()? onStatus,
  }) {
    final c = cloud;
    if (c == null) return;
    uploader ??= Uploader(
        log: log, cloud: c, ticket: ticket, name: myName, now: now, minInterval: minInterval, onChange: onStatus)
      ..start();
    if (listen) _listen(c);
  }

  /// When the cloud last sent the other phones' logs (this phone's clock).
  int? remoteAtMs;
  Timer? _relisten;
  bool _disposed = false;

  void _listen(CloudLogs c) {
    if (_sub != null || _disposed) return;
    _sub = c.watch(nightId).listen((logs) {
      _remote = logs;
      remoteAtMs = now();
      _emit();
    }, onError: (_) {
      // Not a member yet (the first upload is still on its way), or the
      // network dropped: listen again shortly.
      _sub?.cancel();
      _sub = null;
      _relisten?.cancel();
      _relisten = Timer(const Duration(seconds: 30), () => _listen(c));
    }, onDone: () {
      _sub = null;
    });
  }

  /// One fetch of everyone's uploads (players; or "refresh" anywhere).
  Future<bool> refresh() async {
    final c = cloud;
    if (c == null) return false;
    try {
      setRemote(await c.fetch(nightId));
      remoteAtMs = now();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    uploader?.stop();
    _relisten?.cancel();
    await _sub?.cancel();
    await _out.close();
  }

  /// Feed logs from elsewhere (tests, or a one-shot fetch at home).
  void addRemote(List<DeviceLog> logs) {
    _remote = [..._remote, ...logs];
    _emit();
  }

  /// Replace what is known from the cloud (a full fetch).
  void setRemote(List<DeviceLog> logs) {
    _remote = logs;
    _emit();
  }

  /// Appends one event at [ms] (default now). For the organizer bridge,
  /// which mirrors the hand logger's state with the logger's own times.
  Future<NightEvent> appendEvent(EventKind kind, Map<String, Object?> data, {int? ms}) =>
      _append(kind, data, ms: ms);

  Future<NightEvent> _append(EventKind k, Map<String, Object?> data, {int? ms}) async {
    final e = await log.append(k, ms ?? now(), data);
    uploader?.kick();
    _emit();
    return e;
  }

  void _emit() {
    if (!_out.isClosed && _out.hasListener) _out.add(merged());
  }

  void _organizerOnly() {
    if (role != NightRole.organizer) throw StateError('organizer only');
  }

  // ---------------------------------------------------------- organizer

  /// [roster] replaces the ticket's (the organizer's current seats).
  @override
  JoinTicket qrTicket({List<Seat>? roster}) {
    _organizerOnly();
    final t = roster == null
        ? ticket
        : JoinTicket(
            nightId: ticket.nightId, secret: ticket.secret, organizerName: ticket.organizerName, roster: roster);
    return t.withClock(now());
  }

  @override
  Future<void> setSeats(List<Seat> clockwise) async {
    _organizerOnly();
    await _append(EventKind.seats, {'seats': [for (final s in clockwise) s.toJson()]});
  }

  @override
  Future<void> startHand(int handNo, String dealerPid) async {
    _organizerOnly();
    await _append(EventKind.hand, {'n': handNo, 'd': dealerPid});
  }

  @override
  Future<void> undoHand(int handNo) async {
    _organizerOnly();
    await _append(EventKind.unhand, {'n': handNo});
  }

  @override
  Future<void> recordBoard(int handNo, List<int> cards) async {
    _organizerOnly();
    if (cards.length < 3 || cards.length > 5) throw ArgumentError('3 to 5 board cards');
    await _append(EventKind.board, {'n': handNo, 'c': cards});
  }

  @override
  Future<void> endNight() async {
    _organizerOnly();
    await _append(EventKind.end, const {});
  }

  // ------------------------------------------------------------- player

  /// The latest entry: (entry number, first ms, has action, has cards).
  (int, int, bool, bool)? _openEntry() {
    int? e, first;
    var act = false, cards = false;
    final undone = <int>{};
    for (final ev in log.events) {
      if (ev.kind == EventKind.undo) undone.add(ev.data['e'] as int);
    }
    for (final ev in log.events.reversed) {
      final x = ev.data['e'];
      if (x is! int || ev.kind == EventKind.undo) continue;
      if (e == null) {
        if (undone.contains(x)) return null;
        e = x;
      }
      if (x != e) break;
      first = ev.ms;
      if (ev.kind == EventKind.play) act = true;
      if (ev.kind == EventKind.cards) cards = true;
    }
    return e == null ? null : (e, first!, act, cards);
  }

  int _newEntry() {
    var top = 0;
    for (final ev in log.events) {
      final x = ev.data['e'];
      if (x is int && x > top) top = x;
    }
    return top + 1;
  }

  @override
  Future<void> tap(PreAction action, {Facing? facing}) async {
    final o = _openEntry();
    final t = now();
    final int e;
    if (o != null && o.$3 && t - _lastPlayMs(o.$1) <= correctionWindow.inMilliseconds) {
      e = o.$1; // correction of a mis-tap
    } else if (o != null && !o.$3 && o.$4 && t - o.$2 <= entryWindow.inMilliseconds) {
      e = o.$1; // cards first, then the tap
    } else {
      e = _newEntry();
    }
    await _append(EventKind.play, {'e': e, 'a': action.name, if (facing != null) 'f': facing.name});
  }

  int _lastPlayMs(int e) {
    for (final ev in log.events.reversed) {
      if (ev.kind == EventKind.play && ev.data['e'] == e) return ev.ms;
    }
    return 0;
  }

  @override
  Future<void> setCards(List<int> cards) async {
    if (cards.length != 2) throw ArgumentError('two hole cards');
    final o = _openEntry();
    final t = now();
    final e = (o != null && !o.$4 && t - o.$2 <= entryWindow.inMilliseconds) ? o.$1 : _newEntry();
    await _append(EventKind.cards, {'e': e, 'c': cards});
  }

  @override
  Future<void> undoLast() async {
    final o = _openEntry();
    if (o == null) return;
    await _append(EventKind.undo, {'e': o.$1});
  }

  @override
  bool get sharing => log.sharing;

  @override
  Future<void> setSharing(bool on) async {
    if (on == sharing) return;
    await _append(EventKind.share, {'on': on});
  }

  @override
  Future<void> leave() => _append(EventKind.leave, const {});

  // -------------------------------------------------------------- views

  @override
  List<NightEvent> get localEvents => log.events;

  @override
  MergedNight merged({MergeOptions opts = const MergeOptions()}) {
    final org = organizerDeviceId;
    final mine = DeviceLog(deviceId, log.events, serverSkewMs: log.meta['skew'] as int?);
    return mergeNight(
      organizerDeviceId: org ?? '',
      logs: [mine, ..._remote],
      opts: opts,
      selfDeviceId: deviceId,
    );
  }

  @override
  Stream<MergedNight> watchMerged() => _out.stream;
}
