/// The cloud side of a table night, as an interface, plus the uploader that
/// drains a phone's local log into it whenever there is a connection.
///
/// Layout (firestore.rules, docs/MULTIPHONE.md):
///   nights/{nightId}                      {secret, organizer, createdAt}
///   nights/{nightId}/members/{uid}        {name, deviceId, secret, joinedAt}
///   nights/{nightId}/logs/{deviceId}_{p}  {uid, deviceId, part, count,
///                                          events: [compact json], name,
///                                          skew?, clientMs, updatedAt}
/// One log document holds up to [partSize] events of one phone (seq
/// p*partSize+1 ..). Every upload rewrites whole parts, so re-sending is
/// harmless and the cloud copy can always be rebuilt from the phone.
library;

import 'dart:async';
import 'dart:math';

import 'event_log.dart';
import 'night_events.dart';
import 'night_merge.dart';

const partSize = 400;

int partOf(int seq) => (seq - 1) ~/ partSize;

class LogPart {
  final String deviceId;
  final int part;
  final List<NightEvent> events;
  final String name;

  /// Server clock minus device clock, once measured.
  final int? skewMs;

  const LogPart({required this.deviceId, required this.part, required this.events, required this.name, this.skewMs});

  String get docId => '${deviceId}_$part';
}

abstract class CloudLogs {
  /// Makes sure the night exists (the first phone online creates it; any
  /// phone holding the ticket may) and this phone is a member.
  Future<void> join(JoinTicket ticket, {required String deviceId, required String name});

  /// Writes (overwrites) one part. When [measure] is true, also returns the
  /// server's timestamp of the write (ms) so the caller can work out its
  /// clock skew; otherwise may return null.
  Future<int?> putPart(String nightId, LogPart part, {required int clientMs, bool measure = false});

  /// Everything uploaded so far, one [DeviceLog] per phone.
  Future<List<DeviceLog>> fetch(String nightId);

  /// Live: the organizer's TV listens to this when it has a connection.
  Stream<List<DeviceLog>> watch(String nightId);
}

/// Groups uploaded parts back into one log per device.
List<DeviceLog> logsFromParts(Iterable<LogPart> parts) {
  final ev = <String, List<NightEvent>>{};
  final skew = <String, int>{};
  for (final p in parts) {
    ev.putIfAbsent(p.deviceId, () => []).addAll(p.events);
    if (p.skewMs != null) skew[p.deviceId] = p.skewMs!;
  }
  return [for (final d in ev.keys) DeviceLog(d, ev[d]!, serverSkewMs: skew[d])];
}

/// The cloud copy of one event: cards stay on the phone unless the player
/// is sharing at upload time (the copy keeps "had cards" for the entry).
NightEvent redactForCloud(NightEvent e, {required bool sharing}) {
  if (e.kind != EventKind.cards || sharing) return e;
  return e.withData({'e': e.data['e']});
}

// ------------------------------------------------------------------ backoff

/// Exponential backoff with jitter: 5 s, 10 s, 20 s ... capped at 10 min.
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

/// Drains one phone's [EventLog] into [CloudLogs]. Safe to call any time:
/// it uploads the parts that changed since the last successful upload
/// (all parts if card sharing changed), and records progress in the log's
/// metadata only after the server accepted the write.
class Uploader {
  final EventLog log;
  final CloudLogs cloud;
  final JoinTicket ticket;
  final String name;
  final int Function() now;
  final Backoff backoff;

  /// Minimum gap between uploads while online, to bound writes per night.
  final Duration minInterval;

  Timer? _timer;
  bool _busy = false;
  bool _stopped = true;
  DateTime? _lastOk;

  /// Last error, for a small "not uploaded yet" hint in the UI.
  Object? lastError;

  Uploader({
    required this.log,
    required this.cloud,
    required this.ticket,
    required this.name,
    int Function()? now,
    Backoff? backoff,
    this.minInterval = const Duration(minutes: 2),
  })  : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        backoff = backoff ?? Backoff();

  int get uploadedSeq => (log.meta['up.seq'] as int?) ?? 0;
  bool get _reskew => log.meta['up.reskew'] == true;
  bool get _shareChanged => (log.meta['up.share'] as bool? ?? false) != log.sharing;

  /// Anything the cloud does not have yet.
  bool get pending =>
      log.meta['up.joined'] != true || log.lastSeq > uploadedSeq || _shareChanged || _reskew;

  Future<UploadResult> drainOnce() async {
    if (_busy || !pending) return UploadResult.nothing;
    _busy = true;
    try {
      if (log.meta['up.joined'] != true) {
        await cloud.join(ticket, deviceId: log.deviceId, name: name);
        await log.setMeta('up.joined', true);
      }
      final sharing = log.sharing;
      final top = log.lastSeq;
      final reskew = _reskew;
      // Parts to (re)write: all of them when sharing flipped (cards appear
      // or disappear), else from the first part with unsent events; after
      // the skew was first measured, the last part once more to carry it.
      final from = _shareChanged ? 0 : partOf(max(1, reskew ? top : uploadedSeq + 1));
      var measured = false;
      for (var p = from; top > 0 && p <= partOf(top); p++) {
        final evs = [
          for (final e in log.events)
            if (partOf(e.seq) == p && e.seq <= top) redactForCloud(e, sharing: sharing)
        ];
        if (evs.isEmpty) continue;
        final skew = log.meta['skew'] as int?;
        final sent = now();
        final serverMs = await cloud.putPart(
          log.nightId,
          LogPart(deviceId: log.deviceId, part: p, events: evs, name: name, skewMs: skew),
          clientMs: sent,
          measure: skew == null,
        );
        final ack = now();
        // Only trust a quick round trip: half of it is the error bound.
        if (serverMs != null && skew == null && ack - sent < 5000) {
          await log.setMeta('skew', serverMs - (sent + ack) ~/ 2);
          measured = true;
        }
      }
      await log.setMeta('up.seq', top);
      await log.setMeta('up.share', sharing);
      await log.setMeta('up.reskew', measured ? true : null);
      backoff.reset();
      lastError = null;
      _lastOk = DateTime.now();
      return UploadResult.uploaded;
    } catch (e) {
      lastError = e;
      return UploadResult.failed;
    } finally {
      _busy = false;
    }
  }

  /// Background loop: retry with backoff while failing, otherwise check
  /// every [minInterval]. Call [kick] after appending an event.
  void start() {
    _stopped = false;
    _schedule(Duration.zero);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  /// Something new to send: upload soon (respecting [minInterval]).
  void kick() {
    if (_stopped) return;
    final since = _lastOk == null ? minInterval : DateTime.now().difference(_lastOk!);
    if (backoff.failures > 0) return; // the retry timer is already set
    _schedule(since >= minInterval ? Duration.zero : minInterval - since);
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, () async {
      if (_stopped) return;
      final r = await drainOnce();
      if (_stopped) return;
      _schedule(r == UploadResult.failed ? backoff.next() : minInterval);
    });
  }
}

// ------------------------------------------------------------- fake cloud

/// In-memory [CloudLogs] for tests and the default (local-only) build's
/// demos. Enforces the same ownership checks as firestore.rules and counts
/// billed operations for the cost estimate. Toggle [online] to simulate the
/// basement.
class FakeCloudLogs implements CloudLogs {
  bool online = true;
  int serverOffsetMs;
  final int Function() clock;

  final Map<String, ({String secret, String organizer})> nights = {};
  final Map<String, Map<String, String>> members = {}; // night -> deviceId -> name
  final Map<String, Map<String, LogPart>> parts = {}; // night -> docId -> part
  int reads = 0, writes = 0;
  final _changes = StreamController<String>.broadcast(sync: true);

  FakeCloudLogs({int Function()? clock, this.serverOffsetMs = 0})
      : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  void _net() {
    if (!online) throw StateError('offline');
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
    final m = members[nightId];
    if (m == null || !m.containsKey(part.deviceId)) throw StateError('not a member');
    if (part.events.length > partSize) throw StateError('part too big');
    final docs = parts.putIfAbsent(nightId, () => {});
    final old = docs[part.docId];
    if (old != null && old.events.length > part.events.length) throw StateError('count may not shrink');
    reads++; // rules get() of the member doc
    writes++;
    docs[part.docId] = part;
    _changes.add(nightId);
    if (measure) {
      reads++;
      return clock() + serverOffsetMs;
    }
    return null;
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
        yield logsFromParts(parts[nightId]!.values);
      }
    }
  }
}
