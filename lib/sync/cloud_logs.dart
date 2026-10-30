/// The cloud side of a table night, as an interface, plus the uploader that
/// drains a phone's local log into it whenever there is a connection.
///
/// Layout (firestore.rules, docs/MULTIPHONE.md):
///   nights/{nightId}                      {secret, organizer, createdAt, expireAt}
///   nights/{nightId}/members/{uid}        {name, deviceId, secret, joinedAt, expireAt}
///   nights/{nightId}/logs/{deviceId}_{p}  {uid, deviceId, part, count,
///                                          events: [compact json], name,
///                                          skew?, clientMs, updatedAt, expireAt}
///   nights/{nightId}/cards/{deviceId}_{e} {uid, deviceId, e, c: [a, b], at, expireAt}
/// One log document holds the cloud copy of up to [partSize] events of one
/// phone (seq p*partSize+1 ..). Every upload rewrites whole parts, so
/// re-sending is harmless and the cloud copy can always be rebuilt from the
/// phone.
///
/// What leaves the phone ([cloudEvents], [releasedCards]):
///   * sharing off: only the join (name), the sharing switch and leaving,
///     plus the organizer's table bookkeeping (seats, hand starts, board,
///     blind clock) so the TV still runs. No taps, no cards.
///   * sharing on: taps as they happen; the log says only "had cards"; the
///     cards themselves go to a card document once the hand is over (a later
///     entry exists, the organizer closed it, or [cardHoldMs] passed), and
///     the rules keep that document unreadable for another
///     [serverCardHoldMs] after it arrives.
library;

import 'dart:async';
import 'dart:math';

import 'event_log.dart';
import 'night_events.dart';
import 'night_merge.dart';

const partSize = 400;

int partOf(int seq) => (seq - 1) ~/ partSize;

/// A phone keeps its cards for an entry at least this long before they go
/// up, unless it knows the hand is over sooner.
const cardHoldMs = 6 * 60000;

/// firestore.rules: nobody may read a card document until this long after
/// it was written (server time). Keep in step with the rules.
const serverCardHoldMs = 2 * 60000;

/// Every cloud document carries `expireAt` = write time + this; a Firestore
/// TTL policy deletes it after that (firestore.rules allows 1 to 90 days).
const retentionDays = 60;

class LogPart {
  final String deviceId;
  final int part;
  final List<NightEvent> events;
  final String name;

  /// Server clock minus device clock, once measured.
  final int? skewMs;

  /// Server time of the write, when read back from the cloud.
  final int? uploadedAtMs;

  const LogPart({
    required this.deviceId,
    required this.part,
    required this.events,
    required this.name,
    this.skewMs,
    this.uploadedAtMs,
  });

  String get docId => '${deviceId}_$part';
}

String cardDocId(String deviceId, int entry) => '${deviceId}_$entry';

abstract class CloudLogs {
  /// Makes sure the night exists (the first phone online creates it; any
  /// phone holding the ticket may) and this phone is a member.
  Future<void> join(JoinTicket ticket, {required String deviceId, required String name});

  /// Writes (overwrites) one part. When [measure] is true, also returns the
  /// server's timestamp of the write (ms) so the caller can work out its
  /// clock skew; otherwise may return null.
  Future<int?> putPart(String nightId, LogPart part, {required int clientMs, bool measure = false});

  /// Removes one of this phone's parts (sharing turned off: the part must
  /// shrink, and the rules never let a part shrink in place).
  Future<void> deletePart(String nightId, String deviceId, int part);

  /// This phone's cards for entry [entry] (written only once the hand is over).
  Future<void> putCards(String nightId, String deviceId, int entry, List<int> cards);
  Future<void> deleteCards(String nightId, String deviceId, int entry);

  /// Someone's cards for an entry, or null while the document is missing or
  /// the server still holds it back.
  Future<List<int>?> getCards(String nightId, String deviceId, int entry);

  /// Everything uploaded so far, one [DeviceLog] per phone.
  Future<List<DeviceLog>> fetch(String nightId);

  /// Live: the organizer's phone and the TV listen to this.
  Stream<List<DeviceLog>> watch(String nightId);
}

/// Groups uploaded parts back into one log per device.
List<DeviceLog> logsFromParts(Iterable<LogPart> parts) {
  final ev = <String, List<NightEvent>>{};
  final skew = <String, int>{};
  final at = <String, int>{};
  for (final p in parts) {
    ev.putIfAbsent(p.deviceId, () => []).addAll(p.events);
    if (p.skewMs != null) skew[p.deviceId] = p.skewMs!;
    final u = p.uploadedAtMs;
    if (u != null && u > (at[p.deviceId] ?? 0)) at[p.deviceId] = u;
  }
  return [
    for (final d in ev.keys) DeviceLog(d, ev[d]!, serverSkewMs: skew[d], uploadedAtMs: at[d])
  ];
}

/// Kinds that are a player's own game: they stay on the phone while
/// sharing is off.
const _playerOwn = {EventKind.play, EventKind.cards, EventKind.undo};

/// The cloud copy of a phone's log: see the library comment.
List<NightEvent> cloudEvents(Iterable<NightEvent> events, {required bool sharing}) => [
      for (final e in events)
        if (!_playerOwn.contains(e.kind))
          e
        else if (sharing)
          e.kind == EventKind.cards ? e.withData({'e': e.data['e']}) : e
    ];

/// The cards this phone may put in the cloud at [nowMs]: entry -> cards,
/// for entries that are not withdrawn and whose hand is over. Also returns
/// when the next held entry matures (null when none is held).
(Map<int, List<int>>, int?) releasedCards(Iterable<NightEvent> events,
    {required int nowMs, int holdMs = cardHoldMs}) {
  final cards = <int, List<int>>{};
  final at = <int, int>{};
  final done = <int>{};
  final undone = <int>{};
  for (final ev in events) {
    final e = ev.data['e'];
    if (e is! int) continue;
    switch (ev.kind) {
      case EventKind.undo:
        undone.add(e);
      case EventKind.cards:
        final c = ev.data['c'];
        if (c is List && c.length == 2) {
          cards[e] = c.cast<int>();
          at[e] = ev.ms;
          if (ev.data['done'] == true) done.add(e);
        } else {
          cards.remove(e);
        }
      default:
        break;
    }
  }
  // Only a live (not withdrawn) later entry proves this phone is in a
  // later hand.
  var live = 0;
  for (final ev in events) {
    final e = ev.data['e'];
    if (e is int && !undone.contains(e) && (ev.kind == EventKind.play || ev.kind == EventKind.cards)) {
      live = max(live, e);
    }
  }
  final out = <int, List<int>>{};
  int? next;
  for (final e in cards.keys) {
    if (undone.contains(e)) continue;
    final due = at[e]! + holdMs;
    if (done.contains(e) || e < live || nowMs >= due) {
      out[e] = cards[e]!;
    } else {
      next = next == null ? due : min(next, due);
    }
  }
  return (out, next);
}

/// 32-bit FNV-1a: a stable fingerprint of what was last uploaded.
String _fnv(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(36);
}

// ------------------------------------------------------------------ backoff

/// Exponential backoff with jitter: 5 s, 10 s, 20 s ... capped (1 min in
/// the app, so a phone that walks back into wifi catches up quickly;
/// failed requests cost nothing).
class Backoff {
  final Duration base;
  final Duration cap;
  final Random rng;
  int failures = 0;

  Backoff({this.base = const Duration(seconds: 5), this.cap = const Duration(minutes: 10), Random? rng})
      : rng = rng ?? Random();

  Duration next() {
    final exp = base.inMilliseconds * pow(2, min(failures, 20));
    failures++;
    final ms = min(exp.toDouble(), cap.inMilliseconds.toDouble());
    final jitter = 0.8 + rng.nextDouble() * 0.4;
    return Duration(milliseconds: (ms * jitter).round());
  }

  void reset() => failures = 0;
}

// ----------------------------------------------------------------- uploader

enum UploadResult { nothing, uploaded, failed }

/// Drains one phone's [EventLog] into [CloudLogs]. Safe to call any time.
/// It works from state, not from a watermark: it computes what the cloud
/// should hold now (log parts after [cloudEvents], released cards) and
/// writes only what differs from the last accepted upload, recorded in the
/// log's metadata after the server accepted each write. So a crash, a
/// duplicate call, a sharing flip or a lost reply all converge.
class Uploader {
  final EventLog log;
  final CloudLogs cloud;
  final JoinTicket ticket;
  final String name;
  final int Function() now;
  final Backoff backoff;

  /// Minimum gap between uploads while online, to bound writes per night.
  final Duration minInterval;

  /// Called after every attempt (UI status).
  void Function()? onChange;

  Timer? _timer;
  bool _busy = false;
  bool _stopped = true;
  int? _lastOkMs;

  /// Last error, for a small "not uploaded yet" hint in the UI.
  Object? lastError;

  Uploader({
    required this.log,
    required this.cloud,
    required this.ticket,
    required this.name,
    int Function()? now,
    Backoff? backoff,
    this.minInterval = const Duration(seconds: 20),
    this.onChange,
  })  : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        backoff = backoff ?? Backoff(cap: const Duration(minutes: 1));

  /// This phone's clock at the last fully successful upload.
  int? get lastOkMs => _lastOkMs ?? log.meta['up.ok'] as int?;

  Map<String, Object?> get _parts => ((log.meta['up.parts'] as Map?) ?? const {}).cast<String, Object?>();
  Map<String, Object?> get _cards => ((log.meta['up.cards'] as Map?) ?? const {}).cast<String, Object?>();

  /// part -> (events, fingerprint), what the cloud should hold now.
  Map<int, (List<NightEvent>, String)> _planParts() {
    final evs = cloudEvents(log.events, sharing: log.sharing);
    final byPart = <int, List<NightEvent>>{};
    for (final e in evs) {
      byPart.putIfAbsent(partOf(e.seq), () => []).add(e);
    }
    final top = byPart.keys.fold(0, max);
    final skew = log.meta['skew'] as int?;
    return {
      for (final p in byPart.keys)
        p: (
          byPart[p]!,
          _fnv('$name|${p == top ? skew : ''}|${byPart[p]!.map((e) => e.encode()).join(',')}')
        )
    };
  }

  Map<int, List<int>> _wantCards() => log.sharing ? releasedCards(log.events, nowMs: now()).$1 : const {};

  /// When the next held card entry may go up (this phone's clock).
  int? get nextCardRelease => log.sharing ? releasedCards(log.events, nowMs: now()).$2 : null;

  /// Cards entered but still held back on the phone.
  bool get holdingCards => nextCardRelease != null;

  /// Anything the cloud does not have yet.
  bool get pending {
    if (log.meta['up.joined'] != true) return true;
    final plan = _planParts(), have = _parts;
    for (final p in plan.keys) {
      if ((have['$p'] as List?)?.last != plan[p]!.$2) return true;
    }
    if (have.keys.any((k) => !plan.containsKey(int.parse(k)))) return true;
    final want = _wantCards(), up = _cards;
    if (up.length != want.length) return true;
    for (final e in want.keys) {
      if (up['$e'] != want[e]!.join(',')) return true;
    }
    return false;
  }

  Future<UploadResult> drainOnce() async {
    if (_busy) return UploadResult.nothing;
    if (!pending) return UploadResult.nothing;
    _busy = true;
    try {
      if (log.meta['up.joined'] != true) {
        await cloud.join(ticket, deviceId: log.deviceId, name: name);
        await log.setMeta('up.joined', true);
      }
      // Twice at most: the first write may measure the skew, which the
      // last part then carries.
      for (var pass = 0; pass < 2; pass++) {
        if (!await _syncParts()) break;
      }
      await _syncCards();
      backoff.reset();
      lastError = null;
      _lastOkMs = now();
      await log.setMeta('up.ok', _lastOkMs);
      return UploadResult.uploaded;
    } catch (e) {
      lastError = e;
      return UploadResult.failed;
    } finally {
      _busy = false;
      onChange?.call();
    }
  }

  /// Returns true when the skew was measured (another pass is useful).
  Future<bool> _syncParts() async {
    final plan = _planParts();
    final have = Map<String, Object?>.of(_parts);
    var measured = false;
    final all = {...plan.keys, for (final k in have.keys) int.parse(k)}.toList()..sort();
    for (final p in all) {
      final old = have['$p'] as List?;
      final want = plan[p];
      if (want == null) {
        await cloud.deletePart(log.nightId, log.deviceId, p);
        have.remove('$p');
        await log.setMeta('up.parts', have);
        continue;
      }
      if (old != null && old.last == want.$2) continue;
      if (old != null && (old.first as int) > want.$1.length) {
        // Sharing went off: the part shrinks, which the rules only allow
        // as delete + create.
        await cloud.deletePart(log.nightId, log.deviceId, p);
        have.remove('$p');
        await log.setMeta('up.parts', have);
      }
      final skew = log.meta['skew'] as int?;
      final sent = now();
      final serverMs = await cloud.putPart(
        log.nightId,
        LogPart(deviceId: log.deviceId, part: p, events: want.$1, name: name, skewMs: skew),
        clientMs: sent,
        measure: skew == null,
      );
      final ack = now();
      have['$p'] = [want.$1.length, want.$2];
      await log.setMeta('up.parts', have);
      // Only trust a quick round trip: half of it is the error bound.
      if (serverMs != null && skew == null && ack - sent < 5000) {
        await log.setMeta('skew', serverMs - (sent + ack) ~/ 2);
        measured = true;
      }
    }
    return measured;
  }

  Future<void> _syncCards() async {
    final want = _wantCards();
    final have = Map<String, Object?>.of(_cards);
    for (final k in have.keys.toList()) {
      if (!want.containsKey(int.parse(k))) {
        await cloud.deleteCards(log.nightId, log.deviceId, int.parse(k));
        have.remove(k);
        await log.setMeta('up.cards', have);
      }
    }
    for (final e in want.keys) {
      final enc = want[e]!.join(',');
      if (have['$e'] == enc) continue;
      await cloud.putCards(log.nightId, log.deviceId, e, want[e]!);
      have['$e'] = enc;
      await log.setMeta('up.cards', have);
    }
  }

  /// Background loop: retry with backoff while failing, otherwise check
  /// every [minInterval] (sooner when held cards mature). Call [kick]
  /// after appending an event.
  void start() {
    _stopped = false;
    _schedule(Duration.zero);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  bool get running => !_stopped;

  /// Something new to send: upload soon (respecting [minInterval]).
  void kick() {
    if (_stopped) return;
    if (backoff.failures > 0) return; // the retry timer is already set
    final last = _lastOkMs;
    final since = last == null ? minInterval : Duration(milliseconds: now() - last);
    _schedule(since >= minInterval ? Duration.zero : minInterval - since);
  }

  /// Upload right away (app going to the background, coming back, or the
  /// "upload now" button), whatever the interval or backoff says.
  void flushNow() {
    if (_stopped) return;
    _schedule(Duration.zero);
  }

  Duration _idleWait() {
    final next = nextCardRelease;
    if (next == null) return minInterval;
    final d = Duration(milliseconds: max(1000, next - now() + 1000));
    return d < minInterval ? d : minInterval;
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, () async {
      if (_stopped) return;
      final r = await drainOnce();
      if (_stopped) return;
      _schedule(r == UploadResult.failed ? backoff.next() : _idleWait());
    });
  }
}

// ------------------------------------------------------------- fake cloud

/// In-memory [CloudLogs] for tests. Enforces the same ownership checks as
/// firestore.rules (members only, own device, parts never shrink in place,
/// card documents held back for [serverCardHoldMs]) and counts billed
/// operations for the cost estimate. Toggle [online] to simulate the
/// basement.
class FakeCloudLogs implements CloudLogs {
  bool online = true;
  int serverOffsetMs;
  final int Function() clock;

  final Map<String, ({String secret, String organizer})> nights = {};
  final Map<String, Map<String, String>> members = {}; // night -> deviceId -> name
  final Map<String, Map<String, LogPart>> parts = {}; // night -> docId -> part
  final Map<String, Map<String, (List<int>, int)>> cards = {}; // night -> docId -> (cards, server ms)
  int reads = 0, writes = 0, deletes = 0;
  final _changes = StreamController<String>.broadcast(sync: true);

  FakeCloudLogs({int Function()? clock, this.serverOffsetMs = 0})
      : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  int get serverNow => clock() + serverOffsetMs;

  void _net() {
    if (!online) throw StateError('offline');
  }

  void _member(String nightId, String deviceId) {
    final m = members[nightId];
    if (m == null || !m.containsKey(deviceId)) throw StateError('not a member');
  }

  @override
  Future<void> join(JoinTicket ticket, {required String deviceId, required String name}) async {
    _net();
    final n = nights[ticket.nightId];
    if (n == null) {
      nights[ticket.nightId] = (secret: ticket.secret, organizer: ticket.organizerName);
      writes++;
    } else if (n.secret != ticket.secret) {
      throw StateError('wrong secret');
    }
    reads++; // rules get() of the night doc
    members.putIfAbsent(ticket.nightId, () => {})[deviceId] = name;
    writes++;
  }

  @override
  Future<int?> putPart(String nightId, LogPart part, {required int clientMs, bool measure = false}) async {
    _net();
    _member(nightId, part.deviceId);
    if (part.events.length > partSize) throw StateError('part too big');
    final docs = parts.putIfAbsent(nightId, () => {});
    final old = docs[part.docId];
    if (old != null && old.events.length > part.events.length) throw StateError('count may not shrink');
    reads++; // rules get() of the member doc
    writes++;
    docs[part.docId] = LogPart(
        deviceId: part.deviceId,
        part: part.part,
        events: part.events,
        name: part.name,
        skewMs: part.skewMs,
        uploadedAtMs: serverNow);
    _changes.add(nightId);
    if (measure) {
      reads++;
      return serverNow;
    }
    return null;
  }

  @override
  Future<void> deletePart(String nightId, String deviceId, int part) async {
    _net();
    _member(nightId, deviceId);
    reads++;
    deletes++;
    parts[nightId]?.remove('${deviceId}_$part');
    _changes.add(nightId);
  }

  @override
  Future<void> putCards(String nightId, String deviceId, int entry, List<int> c) async {
    _net();
    _member(nightId, deviceId);
    if (c.length != 2 || c.any((x) => x < 0 || x > 51)) throw StateError('bad cards');
    reads++;
    writes++;
    cards.putIfAbsent(nightId, () => {})[cardDocId(deviceId, entry)] = (List.of(c), serverNow);
  }

  @override
  Future<void> deleteCards(String nightId, String deviceId, int entry) async {
    _net();
    _member(nightId, deviceId);
    reads++;
    deletes++;
    cards[nightId]?.remove(cardDocId(deviceId, entry));
  }

  @override
  Future<List<int>?> getCards(String nightId, String deviceId, int entry) async {
    _net();
    reads++;
    final c = cards[nightId]?[cardDocId(deviceId, entry)];
    if (c == null || serverNow < c.$2 + serverCardHoldMs) return null;
    return c.$1;
  }

  @override
  Future<List<DeviceLog>> fetch(String nightId) async {
    _net();
    final ps = parts[nightId]?.values.toList() ?? const <LogPart>[];
    reads += max(1, ps.length);
    return logsFromParts(ps);
  }

  @override
  Stream<List<DeviceLog>> watch(String nightId) async* {
    yield await fetch(nightId);
    await for (final n in _changes.stream) {
      if (n == nightId && online) {
        reads++; // one changed doc per event
        yield logsFromParts(parts[nightId]?.values ?? const []);
      }
    }
  }
}
