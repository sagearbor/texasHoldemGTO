/// Merging everyone's logs into one night (pure Dart, no I/O).
///
/// Inputs: the organizer's log (seats, "next hand" taps with ms timestamps,
/// dealer per hand) and each player's log (join with clock offset, one tap
/// per played hand, optional own cards, leave). Any subset may be missing
/// (the TV shows whatever has arrived), duplicated or out of order.
///
/// Alignment: every player tap is moved onto the organizer's clock with the
/// device's offset (from the join QR; server time as a fallback) and filed
/// under the hand whose [start, next start) interval holds it. A device
/// gets at most one entry per hand, so when skew pushes two taps into one
/// hand, a small dynamic program picks the assignment with the least total
/// distance (taps keep their order). Taps farther than
/// [MergeOptions.maxSkewMs] from any hand the player was in are reported
/// as unassigned instead of guessed. Hands a present player did not tap
/// are folds ("default fold"), marked inferred.
library;

import 'dart:math';

import '../gto/hand_class.dart';
import '../homegame/home_game.dart';
import '../poker/equity.dart';
import '../poker/evaluator.dart';
import 'board_consensus.dart';
import 'night_events.dart';

/// Every event one device wrote (or the part of it that has arrived).
class DeviceLog {
  final String deviceId;
  final List<NightEvent> events;

  /// Server clock minus device clock, ms, if the uploader measured it.
  final int? serverSkewMs;

  /// Server time of this phone's latest upload (ms), for the TV's "last
  /// update" line. Null for a local log.
  final int? uploadedAtMs;

  const DeviceLog(this.deviceId, this.events, {this.serverSkewMs, this.uploadedAtMs});
}

class MergeOptions {
  /// A tap farther than this from every hand the player sat in is not
  /// assigned (clock badly off, or tapped long after the night).
  final int maxSkewMs;

  /// Length given to the last hand when there is no next hand or end yet.
  final int lastHandMs;

  /// A camera board read this soon after a "next hand" tap that shows a
  /// longer street than the new hand has yet belongs to the hand before
  /// (the river read lands while the dealer is already shuffling).
  final int lateBoardMs;

  const MergeOptions({this.maxSkewMs = 120000, this.lastHandMs = 8 * 60000, this.lateBoardMs = 15000});
}

// ---------------------------------------------------------------- timeline

class TimelineHand {
  final int n;

  /// Organizer clock, ms.
  final int startMs;
  final int endMs;
  final String? dealer;

  /// Clockwise.
  final List<Seat> seats;
  final List<int>? board;

  const TimelineHand({
    required this.n,
    required this.startMs,
    required this.endMs,
    required this.dealer,
    required this.seats,
    this.board,
  });

  int seatOf(String pid) => seats.indexWhere((s) => s.pid == pid);

  String? positionOf(String pid) {
    final i = seatOf(pid);
    final d = dealer == null ? -1 : seatOf(dealer!);
    if (i < 0 || d < 0 || seats.length < 2) return null;
    return positionName(seats.length, (i - d) % seats.length);
  }

  /// Distance in ms from [t] to [startMs, endMs); 0 inside.
  int distance(int t) => t < startMs ? startMs - t : (t >= endMs ? t - endMs + 1 : 0);
}

class Timeline {
  final List<TimelineHand> hands;
  final int? endMs;

  /// Everyone the organizer ever seated, by pid (latest name wins).
  final Map<String, String> names;

  /// The organizer's blind clock (BlindClock json), latest wins.
  final Map<String, Object?>? clock;

  /// The seats in force for the next hand (the latest seats event).
  final List<Seat> seatsNow;

  const Timeline(this.hands, this.endMs, this.names, {this.clock, this.seatsNow = const []});

  static const empty = Timeline([], null, {});

  /// A later hand has started (or the night ended): [h] is over.
  bool isOver(TimelineHand h) => endMs != null || hands.isNotEmpty && hands.last.n != h.n;
}

/// Builds the hand timeline from the organizer's events (seq order). A
/// seats event applies to hands started after it; a repeated hand number
/// replaces the earlier tap; `unhand` deletes a mistaken tap.
Timeline buildTimeline(Iterable<NightEvent> organizerEvents, {MergeOptions opts = const MergeOptions()}) {
  final evs = organizerEvents.toList()..sort((a, b) => a.seq.compareTo(b.seq));
  var seats = <Seat>[];
  final names = <String, String>{};
  final starts = <int, (int, String?, List<Seat>)>{};
  final boards = <int, List<int>>{};
  int? end;
  Map<String, Object?>? clock;
  for (final e in evs) {
    switch (e.kind) {
      case EventKind.seats:
        seats = [for (final s in (e.data['seats'] as List? ?? const [])) Seat.fromJson(s)];
        for (final s in seats) {
          names[s.pid] = s.name;
        }
      case EventKind.hand:
        final n = e.data['n'];
        if (n is int) starts[n] = (e.ms, e.data['d'] as String?, seats);
      case EventKind.unhand:
        starts.remove(e.data['n']);
      case EventKind.board:
        final n = e.data['n'], c = e.data['c'];
        if (n is int && c is List) boards[n] = c.cast<int>();
      case EventKind.end:
        end = e.ms;
      case EventKind.clock:
        final j = e.data['j'];
        if (j is Map) clock = j.cast<String, Object?>();
      default:
        break;
    }
  }
  final order = starts.entries.toList()..sort((a, b) => a.value.$1.compareTo(b.value.$1));
  final hands = <TimelineHand>[];
  for (var i = 0; i < order.length; i++) {
    final (start, dealer, s) = order[i].value;
    var endMs = i + 1 < order.length ? order[i + 1].value.$1 : (end ?? start + opts.lastHandMs);
    if (endMs <= start) endMs = start + 1;
    hands.add(TimelineHand(
      n: order[i].key,
      startMs: start,
      endMs: endMs,
      dealer: dealer,
      seats: s,
      board: boards[order[i].key],
    ));
  }
  return Timeline(hands, end, names, clock: clock, seatsNow: seats);
}

// ------------------------------------------------------------------ devices

enum OffsetSource { organizer, qr, server, none }

class DeviceInfo {
  final String deviceId;
  final String name;

  /// The roster id this phone belongs to. `dev:<deviceId>` when it could
  /// not be linked to anyone the organizer seated.
  final String pid;
  final bool linked;

  /// Add to this device's clock to get the organizer's clock.
  final int offsetMs;
  final OffsetSource offsetSource;

  /// Organizer-clock intervals [join, leave) the phone was at the table.
  final List<(int, int)> present;
  final bool sharing;

  /// Sharing is off and this is not the phone doing the merge: its taps
  /// never reached us, so it is left out of every hand (the TV says
  /// "private") instead of being counted as folding everything.
  final bool private;

  /// Left the table (latest presence interval is closed).
  final bool left;

  final int? uploadedAtMs;

  const DeviceInfo({
    required this.deviceId,
    required this.name,
    required this.pid,
    required this.linked,
    required this.offsetMs,
    required this.offsetSource,
    required this.present,
    required this.sharing,
    this.private = false,
    this.left = false,
    this.uploadedAtMs,
  });

  bool presentAt(TimelineHand h) => present.any((p) => p.$1 < h.endMs && p.$2 > h.startMs);
}

/// One played-hand record from one phone, on the organizer's clock.
class Entry {
  final String deviceId;
  final int e;
  final int ms;
  final PreAction? action;
  final Facing? facing;
  final List<int>? cards;
  final bool hadCards;
  const Entry(this.deviceId, this.e, this.ms, this.action, this.facing, this.cards, this.hadCards);
}

// ------------------------------------------------------------------ output

class PlayerHand {
  final String pid;
  final String name;
  final String deviceId;
  final String? position;
  final PreAction action;
  final Facing? facing;

  /// True for a "default fold": the phone was at the table and did not tap.
  final bool inferred;

  /// Only when that player shares cards (or on their own phone).
  final List<int>? cards;
  final bool hadCards;

  /// Organizer-clock time of the tap, if there was one.
  final int? tapMs;

  /// The phone's entry number for this hand (the card document key).
  final int? entryNo;

  const PlayerHand({
    required this.pid,
    required this.name,
    required this.deviceId,
    required this.position,
    required this.action,
    this.facing,
    required this.inferred,
    this.cards,
    this.hadCards = false,
    this.tapMs,
    this.entryNo,
  });

  bool get voluntary => action != PreAction.fold;
}

class MergedHand {
  final TimelineHand hand;

  /// Players with a phone at the table for this hand, by pid.
  final Map<String, PlayerHand> players;

  /// The community cards as agreed (lib/sync/board_consensus.dart): the
  /// organizer's call, else a one-tap fix, else the cameras' vote.
  final AgreedBoard agreedBoard;
  const MergedHand(this.hand, this.players, {this.agreedBoard = AgreedBoard.none});
  int get n => hand.n;

  /// The board as exact cards (every card known), or null.
  List<int>? get board => agreedBoard.exact;
}

class Unassigned {
  final Entry entry;
  final String reason;
  const Unassigned(this.entry, this.reason);
}

class MergedNight {
  final Timeline timeline;
  final List<MergedHand> hands;
  final List<DeviceInfo> devices;
  final List<Unassigned> unassigned;
  final List<String> warnings;

  const MergedNight({
    required this.timeline,
    required this.hands,
    required this.devices,
    required this.unassigned,
    required this.warnings,
  });

  String nameOf(String pid) {
    final n = timeline.names[pid];
    if (n != null) return n;
    for (final d in devices) {
      if (d.pid == pid) return d.name;
    }
    return '?';
  }

  /// The [LoggedHand]s for [pid], so the existing stats, recap and badges
  /// work unchanged on any phone.
  List<LoggedHand> loggedHandsFor(String pid) => [
        for (final h in hands)
          if (h.players[pid] case final p?)
            LoggedHand(
              number: h.n,
              cards: p.cards,
              position: p.position ?? '?',
              dealer: h.hand.dealer == null ? null : nameOf(h.hand.dealer!),
              action: p.action,
              facing: p.inferred ? null : p.facing,
              ts: h.hand.startMs,
              board: h.board,
            )
      ];
}

// -------------------------------------------------------------------- merge

/// Union of every copy of every event, by `deviceId_seq` (re-uploads,
/// overlapping parts and the local copy all collapse).
Map<String, Map<int, NightEvent>> _union(Iterable<DeviceLog> logs) {
  final out = <String, Map<int, NightEvent>>{};
  for (final l in logs) {
    final m = out.putIfAbsent(l.deviceId, () => {});
    for (final e in l.events) {
      m.putIfAbsent(e.seq, () => e);
    }
  }
  return out;
}

String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// [selfDeviceId] is the phone doing the merge (its own log is complete
/// whatever its sharing says); null on the TV.
MergedNight mergeNight({
  required String organizerDeviceId,
  required Iterable<DeviceLog> logs,
  Map<String, String> links = const {},
  MergeOptions opts = const MergeOptions(),
  String? selfDeviceId,
}) {
  final logList = logs.toList();
  final byDevice = _union(logList);
  final skew = <String, int>{};
  final uploaded = <String, int>{};
  for (final l in logList) {
    if (l.serverSkewMs != null) skew[l.deviceId] = l.serverSkewMs!;
    final u = l.uploadedAtMs;
    if (u != null && u > (uploaded[l.deviceId] ?? 0)) uploaded[l.deviceId] = u;
  }
  final warnings = <String>[];
  final orgEvents = byDevice[organizerDeviceId]?.values ?? const <NightEvent>[];
  final timeline = buildTimeline(orgEvents, opts: opts);
  if (timeline.hands.isEmpty) warnings.add('No hands from the organizer yet.');

  // Pids someone was seated as in any hand.
  final seatedEver = <String>{for (final h in timeline.hands) for (final s in h.seats) s.pid};
  final byName = <String, List<String>>{};
  timeline.names.forEach((pid, name) => byName.putIfAbsent(_norm(name), () => []).add(pid));

  final devices = <DeviceInfo>[];
  final claimed = <String>{};
  // Organizer first, then by device id, so linking is deterministic.
  final ids = byDevice.keys.toList()
    ..sort((a, b) => a == organizerDeviceId ? -1 : (b == organizerDeviceId ? 1 : a.compareTo(b)));
  for (final id in ids) {
    final evs = byDevice[id]!.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    NightEvent? lastJoin;
    for (final e in evs) {
      if (e.kind == EventKind.join) lastJoin = e;
    }
    final name = (lastJoin?.data['name'] as String?) ?? '?';
    // Offset.
    int offset = 0;
    var src = OffsetSource.none;
    if (id == organizerDeviceId) {
      src = OffsetSource.organizer;
    } else if (lastJoin?.data['offset'] is int) {
      offset = lastJoin!.data['offset'] as int;
      src = OffsetSource.qr;
    } else if (skew[id] != null && skew[organizerDeviceId] != null) {
      offset = skew[id]! - skew[organizerDeviceId]!;
      src = OffsetSource.server;
    } else {
      warnings.add('No clock offset for $name; assuming the clocks agree.');
    }
    // Link to a roster seat.
    String? pid = links[id];
    final claim = lastJoin?.data['claim'] as String?;
    if (pid == null && claim != null && (seatedEver.contains(claim) || timeline.names.containsKey(claim))) {
      pid = claim;
    }
    if (pid == null) {
      final cands = (byName[_norm(name)] ?? const []).where((p) => !claimed.contains(p)).toList();
      if (cands.length == 1) pid = cands.single;
    }
    final linked = pid != null;
    pid ??= 'dev:$id';
    if (claimed.contains(pid)) {
      warnings.add('Two phones claim ${timeline.names[pid] ?? pid}; keeping the first.');
      pid = 'dev:$id';
    }
    claimed.add(pid);
    // Presence and sharing.
    final present = <(int, int)>[];
    int? open;
    // No share event at all (older logs): on, the product default.
    var sharing = true;
    for (final e in evs) {
      final t = e.ms + offset;
      if (e.kind == EventKind.join) open ??= t;
      if (e.kind == EventKind.leave && open != null) {
        present.add((open, t));
        open = null;
      }
      if (e.kind == EventKind.share) sharing = e.data['on'] == true;
    }
    if (open != null) present.add((open, 1 << 52));
    if (evs.every((e) => e.kind != EventKind.join) && id == organizerDeviceId) {
      present.add((-(1 << 52), 1 << 52));
    }
    devices.add(DeviceInfo(
      deviceId: id,
      name: linked ? (timeline.names[pid] ?? name) : name,
      pid: pid,
      linked: linked,
      offsetMs: offset,
      offsetSource: src,
      present: present,
      sharing: sharing,
      private: !sharing && id != selfDeviceId,
      left: open == null && present.isNotEmpty,
      uploadedAtMs: uploaded[id],
    ));
  }

  // Entries per device, then align.
  final assigned = <String, Map<int, Entry>>{}; // deviceId -> hand n -> entry
  final unassigned = <Unassigned>[];
  for (final d in devices) {
    if (d.private) continue;
    final entries = _entries(d, byDevice[d.deviceId]!.values);
    final eligible = [
      for (final h in timeline.hands)
        if (d.presentAt(h) && (h.seatOf(d.pid) >= 0 || !seatedEver.contains(d.pid))) h
    ];
    final (match, rest) = _align(entries, eligible, opts.maxSkewMs);
    assigned[d.deviceId] = match;
    for (final e in rest) {
      unassigned.add(Unassigned(e, eligible.isEmpty ? 'no hand for this phone yet' : 'too far from any hand'));
    }
  }

  // Board reads and fixes from every phone, on the organizer's clock.
  final reads = <int, List<BoardObservation>>{}; // hand n -> reads
  final fixes = <int, (int, List<int>)>{}; // hand n -> (ms, cards), latest wins
  for (final d in devices) {
    for (final e in byDevice[d.deviceId]!.values) {
      if (e.kind == EventKind.boardFix) {
        final n = e.data['n'], c = e.data['c'];
        if (n is int && c is List && c.length >= 3 && c.length <= 5) {
          final t = e.ms + d.offsetMs;
          if ((fixes[n]?.$1 ?? -1 << 60) < t) fixes[n] = (t, c.cast<int>());
        }
      } else if (e.kind == EventKind.boardRead) {
        final obs = _observation(d.deviceId, e, d.offsetMs);
        if (obs == null) continue;
        final n = _handForBoard(timeline, obs, reads, opts);
        if (n != null) reads.putIfAbsent(n, () => []).add(obs);
      }
    }
  }

  final hands = <MergedHand>[];
  for (final h in timeline.hands) {
    final players = <String, PlayerHand>{};
    for (final d in devices) {
      if (d.private || !d.presentAt(h)) continue;
      final seated = h.seatOf(d.pid) >= 0;
      if (!seated && seatedEver.contains(d.pid)) continue; // sat out / gone
      final e = assigned[d.deviceId]![h.n];
      players[d.pid] = PlayerHand(
        pid: d.pid,
        name: d.name,
        deviceId: d.deviceId,
        position: h.positionOf(d.pid),
        action: e?.action ?? PreAction.fold,
        facing: e?.facing,
        inferred: e?.action == null,
        cards: e?.cards,
        hadCards: e?.hadCards ?? false,
        tapMs: e?.ms,
        entryNo: e?.e,
      );
    }
    final held = <int>{
      for (final p in players.values)
        if (p.cards != null) ...p.cards!
    };
    final agreed = agreeBoard(
      observations: reads[h.n] ?? const [],
      called: h.board,
      fixed: fixes[h.n]?.$2,
      holeCards: held,
    );
    hands.add(MergedHand(h, players, agreedBoard: agreed));
  }
  return MergedNight(
    timeline: timeline,
    hands: hands,
    devices: devices,
    unassigned: unassigned,
    warnings: warnings,
  );
}

/// A `boardRead` event as a [BoardObservation] on the organizer's clock,
/// or null when malformed.
BoardObservation? _observation(String deviceId, NightEvent e, int offsetMs) {
  final c = e.data['c'];
  if (c is! List || c.isEmpty || c.length > 5) return null;
  final q = e.data['q'], u = e.data['u'];
  final cards = <PartialCard>[];
  for (var i = 0; i < c.length; i++) {
    final tok = c[i];
    if (tok is! String) return null;
    final rc = q is List && i < q.length && q[i] is num ? (q[i] as num).toDouble() : 0.5;
    final sc = u is List && i < u.length && u[i] is num ? (u[i] as num).toDouble() : 0.3;
    final card = PartialCard.parse(tok, rankConf: rc, suitConf: sc);
    if (card == null) return null;
    cards.add(card);
  }
  return BoardObservation(deviceId, e.ms + offsetMs, cards);
}

/// The hand a board read belongs to: the one whose interval holds it,
/// except a read in the first [MergeOptions.lateBoardMs] of a hand that
/// shows more cards than that hand has been read with so far, which is
/// the previous hand's turn or river seen late.
int? _handForBoard(Timeline tl, BoardObservation o, Map<int, List<BoardObservation>> reads, MergeOptions opts) {
  for (var i = 0; i < tl.hands.length; i++) {
    final h = tl.hands[i];
    if (o.ms < h.startMs || o.ms >= h.endMs) continue;
    if (i > 0 && o.ms - h.startMs < opts.lateBoardMs && o.count >= 4) {
      final prev = tl.hands[i - 1];
      final prevMax = (reads[prev.n] ?? const []).fold(0, (m, r) => max(m, r.count));
      final thisMax = (reads[h.n] ?? const []).fold(0, (m, r) => max(m, r.count));
      if (prevMax >= 3 && prevMax < o.count && thisMax < o.count) return prev.n;
    }
    return h.n;
  }
  return null;
}

List<Entry> _entries(DeviceInfo d, Iterable<NightEvent> events) {
  final evs = events.toList()..sort((a, b) => a.seq.compareTo(b.seq));
  final first = <int, int>{};
  final action = <int, PreAction>{};
  final facing = <int, Facing>{};
  final cards = <int, List<int>>{};
  final had = <int>{};
  final undone = <int>{};
  for (final ev in evs) {
    final e = ev.data['e'];
    if (e is! int) continue;
    switch (ev.kind) {
      case EventKind.play:
        first.putIfAbsent(e, () => ev.ms);
        final a = PreAction.values.where((x) => x.name == ev.data['a']);
        if (a.isNotEmpty) action[e] = a.first;
        final f = Facing.values.where((x) => x.name == ev.data['f']);
        if (f.isNotEmpty) {
          facing[e] = f.first;
        } else {
          facing.remove(e);
        }
      case EventKind.cards:
        first.putIfAbsent(e, () => ev.ms);
        had.add(e);
        final c = ev.data['c'];
        if (c is List && c.length == 2) {
          cards[e] = c.cast<int>();
        } else {
          cards.remove(e);
        }
      case EventKind.undo:
        undone.add(e);
      default:
        break;
    }
  }
  final out = [
    for (final e in first.keys)
      if (!undone.contains(e))
        Entry(d.deviceId, e, first[e]! + d.offsetMs, action[e], facing[e], cards[e], had.contains(e))
  ]..sort((a, b) => a.ms != b.ms ? a.ms.compareTo(b.ms) : a.e.compareTo(b.e));
  return out;
}

/// Order-preserving assignment of [entries] to distinct [hands] (both
/// sorted by time) minimising total distance; an entry may stay unassigned
/// at cost [maxSkew], and may only match a hand within [maxSkew].
(Map<int, Entry>, List<Entry>) _align(List<Entry> entries, List<TimelineHand> hands, int maxSkew) {
  final k = entries.length, m = hands.length;
  if (k == 0) return (const {}, const []);
  if (m == 0) return (const {}, entries);
  const inf = 1 << 60;
  // dp[i][j]: best cost for the first i entries using the first j hands.
  final dp = List.generate(k + 1, (_) => List<int>.filled(m + 1, inf));
  final how = List.generate(k + 1, (_) => List<int>.filled(m + 1, 0)); // 0 match, 1 skip entry, 2 skip hand
  for (var j = 0; j <= m; j++) {
    dp[0][j] = 0;
    how[0][j] = 2;
  }
  for (var i = 1; i <= k; i++) {
    dp[i][0] = dp[i - 1][0] + maxSkew;
    how[i][0] = 1;
    for (var j = 1; j <= m; j++) {
      var best = inf, b = 0;
      final d = hands[j - 1].distance(entries[i - 1].ms);
      if (d <= maxSkew && dp[i - 1][j - 1] < inf) {
        best = dp[i - 1][j - 1] + d;
        b = 0;
      }
      if (dp[i - 1][j] + maxSkew < best) {
        best = dp[i - 1][j] + maxSkew;
        b = 1;
      }
      if (dp[i][j - 1] < best) {
        best = dp[i][j - 1];
        b = 2;
      }
      dp[i][j] = best;
      how[i][j] = b;
    }
  }
  final match = <int, Entry>{};
  final rest = <Entry>[];
  var i = k, j = m;
  while (i > 0) {
    final b = how[i][j];
    if (b == 0 && j > 0) {
      match[hands[j - 1].n] = entries[i - 1];
      i--;
      j--;
    } else if (b == 1 || j == 0) {
      rest.add(entries[i - 1]);
      i--;
    } else {
      j--;
    }
  }
  return (match, rest.reversed.toList());
}

// -------------------------------------------------------------- drama lines

class DramaLine {
  final int handNo;
  final String kind;
  final String text;
  const DramaLine(this.handNo, this.kind, this.text);
  @override
  String toString() => text;
}

bool _premium(HandClass h) =>
    (h.isPair && h.highRank >= 9) || (h.highRank == 12 && h.lowRank == 11); // JJ+, AK

String clockLabel(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')}${t.hour < 12 ? 'am' : 'pm'}';
}

/// Two-player lines for the recap, from hands where at least two players
/// who share their cards both played:
///   "Bad beat · John KK vs Joe 76s · 8:22pm"  (5-card board known, the
///      preflop favourite, listed first, lost)
///   "Cooler · John KK vs Joe AA · 8:22pm"     (both had JJ+ or AK)
List<DramaLine> dramaLines(MergedNight night, {int samples = 4000, Random? rng}) {
  rng ??= Random(1);
  final out = <DramaLine>[];
  for (final h in night.hands) {
    final shown = [
      for (final p in h.players.values)
        if (p.voluntary && p.cards != null && p.cards!.length == 2) p
    ]..sort((a, b) => a.name.compareTo(b.name));
    if (shown.length < 2) continue;
    final a = shown[0], b = shown[1];
    if ({...a.cards!, ...b.cards!}.length < 4) continue; // typo'd duplicate card
    final ha = HandClass.fromCards(a.cards![0], a.cards![1]);
    final hb = HandClass.fromCards(b.cards![0], b.cards![1]);
    final when = clockLabel(h.hand.startMs);
    final board = h.board;
    if (board != null && board.length == 5 && {...a.cards!, ...b.cards!, ...board}.length == 9) {
      final eq = handsEquity([a.cards!, b.cards!], const [], samples: samples, rng: rng).equity;
      final sa = evaluate([...a.cards!, ...board]), sb = evaluate([...b.cards!, ...board]);
      if (sa != sb) {
        final (fav, dog, favEq) = eq[0] >= eq[1] ? (a, b, eq[0]) : (b, a, eq[1]);
        final favWon = (fav == a) == (sa > sb);
        if (!favWon && favEq >= 0.65) {
          final hf = fav == a ? ha : hb, hd = fav == a ? hb : ha;
          out.add(DramaLine(h.n, 'badBeat', 'Bad beat · ${fav.name} ${hf.name} vs ${dog.name} ${hd.name} · $when'));
          continue;
        }
      }
    }
    if (_premium(ha) && _premium(hb)) {
      out.add(DramaLine(h.n, 'cooler', 'Cooler · ${a.name} ${ha.name} vs ${b.name} ${hb.name} · $when'));
    }
  }
  return out;
}

// ------------------------------------------------------------- live summary

/// VPIP / PFR per player for the TV, from whatever has arrived. Inferred
/// folds count (that is the point of default fold); [confirmed] says how
/// many hands had a real tap so the TV can be honest about coverage.
class LiveRow {
  final String pid;
  final String name;
  final int hands;
  final int confirmed;
  final int vpip;
  final int pfr;

  /// Sharing is off: show the name and "private", no numbers.
  final bool private;
  const LiveRow(this.pid, this.name, this.hands, this.confirmed, this.vpip, this.pfr, {this.private = false});
  double get vpipPct => hands == 0 ? 0 : vpip / hands;
  double get pfrPct => hands == 0 ? 0 : pfr / hands;
  String get style => playStyle(hands, vpipPct, pfrPct);
}

/// Rows for hands that finished at least [delayMs] before [nowMs]
/// (organizer clock), so the TV never shows the hand just played.
List<LiveRow> liveRows(MergedNight night, {required int nowMs, int delayMs = 0}) {
  final acc = <String, List<int>>{};
  for (final h in night.hands) {
    if (h.hand.endMs > nowMs - delayMs) continue;
    for (final p in h.players.values) {
      final r = acc.putIfAbsent(p.pid, () => [0, 0, 0, 0]);
      r[0]++;
      if (!p.inferred) r[1]++;
      if (p.voluntary) r[2]++;
      if (p.action == PreAction.raise) r[3]++;
    }
  }
  final rows = [
    for (final d in night.devices)
      LiveRow(d.pid, night.nameOf(d.pid), acc[d.pid]?[0] ?? 0, acc[d.pid]?[1] ?? 0, acc[d.pid]?[2] ?? 0,
          acc[d.pid]?[3] ?? 0,
          private: d.private)
  ]..sort((a, b) => a.name.compareTo(b.name));
  return rows;
}

/// The organizer's device among uploaded logs: the one with the hand
/// timeline (only the organizer writes seats / hand events).
String? organizerOf(Iterable<DeviceLog> logs) {
  for (final l in logs) {
    if (l.events.any((e) => e.kind == EventKind.hand || e.kind == EventKind.seats)) return l.deviceId;
  }
  return null;
}
