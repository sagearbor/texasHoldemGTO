/// What the table TV shows, from a merged night (pure Dart, no I/O), and
/// the card-document fetching that feeds it.
///
/// Anti-cheat, in three layers (docs/MULTIPHONE.md, "What the TV shows"):
///   1. a phone writes a player's cards only after that hand is over
///      (cloud_logs.dart [releasedCards]);
///   2. the rules keep a card document unreadable for 2 minutes after it
///      arrives, and nobody can list them;
///   3. the TV only asks for, and only shows, cards of hands that are over
///      (a later hand started) AND ended at least [TvOptions.cardDelayMs]
///      ago. Stats count finished hands straight away.
library;

import 'dart:math';

import '../homegame/home_game.dart';
import 'cloud_logs.dart';
import 'night_events.dart';
import 'night_merge.dart';

class TvOptions {
  /// Cards of a finished hand show this long after it ended.
  final int cardDelayMs;

  /// Finished hands listed under "Recent hands".
  final int recent;

  /// The organizer's phone counts as quiet after this long without an
  /// upload while the night is running (the TV says so).
  final int staleMs;

  const TvOptions({this.cardDelayMs = 3 * 60000, this.recent = 6, this.staleMs = 5 * 60000});
}

enum TvStatus { sharing, private, noPhone, left }

class TvRow {
  final String pid;
  final String name;
  final TvStatus status;

  /// Finished hands this player was dealt in (default folds included).
  final int hands;
  final int confirmed;
  final int vpip;
  final int pfr;

  /// Latest voluntary actions in finished hands, newest first: "Raise #41".
  final List<String> recent;

  const TvRow({
    required this.pid,
    required this.name,
    required this.status,
    this.hands = 0,
    this.confirmed = 0,
    this.vpip = 0,
    this.pfr = 0,
    this.recent = const [],
  });

  double get vpipPct => hands == 0 ? 0 : vpip / hands;
  double get pfrPct => hands == 0 ? 0 : pfr / hands;
  String get style => playStyle(hands, vpipPct, pfrPct);
  bool get hasStats => status == TvStatus.sharing || status == TvStatus.left;
}

class TvPlay {
  final String name;
  final PreAction action;

  /// Only once the hand is past the card delay, and only if shared.
  final List<int>? cards;
  const TvPlay(this.name, this.action, this.cards);
}

class TvHand {
  final int n;
  final int startMs;
  final String? dealer;
  final List<TvPlay> plays;
  final List<int>? board;

  /// False while the card delay is still running: cards stay hidden.
  final bool cardsOpen;
  const TvHand(this.n, this.startMs, this.dealer, this.plays, this.board, this.cardsOpen);
}

class TvBoard {
  /// The hand being played now (null before the first "next hand").
  final int? handNow;
  final int? handNowStartMs;
  final int finished;
  final bool ended;
  final List<TvRow> rows;
  final List<TvHand> recent;
  final List<DramaLine> drama;

  /// The organizer's blind clock (BlindClock json), if it is running one.
  final Map<String, Object?>? clock;

  /// Server time of the organizer's latest upload, and of anyone's.
  final int? organizerUploadMs;
  final int? latestUploadMs;
  final bool hasOrganizer;

  const TvBoard({
    required this.handNow,
    required this.handNowStartMs,
    required this.finished,
    required this.ended,
    required this.rows,
    required this.recent,
    required this.drama,
    required this.clock,
    required this.organizerUploadMs,
    required this.latestUploadMs,
    required this.hasOrganizer,
  });

  /// True when the organizer's phone has gone quiet for a while: the TV is
  /// showing the last state it got.
  bool staleAt(int nowMs, {TvOptions opts = const TvOptions()}) =>
      !ended && (organizerUploadMs == null || nowMs - organizerUploadMs! > opts.staleMs);
}

/// Cards of [h] may be shown at [nowMs].
bool cardsOpen(Timeline t, TimelineHand h, int nowMs, int delayMs) =>
    t.isOver(h) && h.endMs + delayMs <= nowMs;

String _short(PreAction a) => switch (a) {
      PreAction.raise => 'Raise',
      PreAction.call => 'Call',
      PreAction.fold => 'Fold',
    };

TvBoard buildTvBoard(MergedNight m, {required int nowMs, TvOptions opts = const TvOptions()}) {
  final t = m.timeline;
  final done = [for (final h in m.hands) if (t.isOver(h.hand)) h];
  final acc = <String, List<int>>{};
  final recentActs = <String, List<String>>{};
  for (final h in done) {
    for (final p in h.players.values) {
      final r = acc.putIfAbsent(p.pid, () => [0, 0, 0, 0]);
      r[0]++;
      if (!p.inferred) r[1]++;
      if (p.voluntary) r[2]++;
      if (p.action == PreAction.raise) r[3]++;
    }
  }
  for (final h in done.reversed) {
    for (final p in h.players.values) {
      if (!p.voluntary || p.inferred) continue;
      final l = recentActs.putIfAbsent(p.pid, () => []);
      if (l.length < 3) l.add('${_short(p.action)} #${h.n}');
    }
  }

  final rows = <TvRow>[];
  final seen = <String>{};
  for (final d in m.devices) {
    if (!seen.add(d.pid)) continue;
    final a = acc[d.pid];
    final status = d.private ? TvStatus.private : (d.left ? TvStatus.left : TvStatus.sharing);
    rows.add(TvRow(
      pid: d.pid,
      name: m.nameOf(d.pid),
      status: status,
      hands: d.private ? 0 : a?[0] ?? 0,
      confirmed: d.private ? 0 : a?[1] ?? 0,
      vpip: d.private ? 0 : a?[2] ?? 0,
      pfr: d.private ? 0 : a?[3] ?? 0,
      recent: d.private ? const [] : recentActs[d.pid] ?? const [],
    ));
  }
  // Seated by the organizer, no phone (or not uploaded yet).
  for (final s in t.seatsNow) {
    if (seen.add(s.pid)) rows.add(TvRow(pid: s.pid, name: s.name, status: TvStatus.noPhone));
  }
  int rank(TvRow r) => switch (r.status) {
        TvStatus.sharing => 0,
        TvStatus.private => 1,
        TvStatus.left => 2,
        TvStatus.noPhone => 3,
      };
  rows.sort((a, b) {
    final c = rank(a).compareTo(rank(b));
    if (c != 0) return c;
    final h = b.hands.compareTo(a.hands);
    return h != 0 ? h : a.name.compareTo(b.name);
  });

  final recent = <TvHand>[];
  for (final h in done.reversed.take(opts.recent)) {
    final open = cardsOpen(t, h.hand, nowMs, opts.cardDelayMs);
    final plays = [
      for (final p in h.players.values)
        if (p.voluntary) TvPlay(m.nameOf(p.pid), p.action, open ? p.cards : null)
    ]..sort((a, b) => a.name.compareTo(b.name));
    recent.add(TvHand(
      h.n,
      h.hand.startMs,
      h.hand.dealer == null ? null : m.nameOf(h.hand.dealer!),
      plays,
      // The agreed board: called, fixed, or the cameras' vote when exact
      // (board_consensus.dart). Public cards, so no delay applies.
      h.board,
      open,
    ));
  }

  // Drama only from hands whose cards may be shown.
  final openHands = [for (final h in done) if (cardsOpen(t, h.hand, nowMs, opts.cardDelayMs)) h];
  final drama = dramaLines(MergedNight(
    timeline: t,
    hands: openHands,
    devices: m.devices,
    unassigned: const [],
    warnings: const [],
  )).reversed.toList();

  final org = m.devices.where((d) => d.offsetSource == OffsetSource.organizer).firstOrNull;
  final ups = [for (final d in m.devices) if (d.uploadedAtMs != null) d.uploadedAtMs!];
  final last = t.hands.isEmpty || t.endMs != null ? null : t.hands.last;
  return TvBoard(
    handNow: last?.n,
    handNowStartMs: last?.startMs,
    finished: done.length,
    ended: t.endMs != null,
    rows: rows,
    recent: recent,
    drama: drama,
    clock: t.clock,
    organizerUploadMs: org?.uploadedAtMs,
    latestUploadMs: ups.isEmpty ? null : ups.reduce(max),
    hasOrganizer: t.hands.isNotEmpty || org != null,
  );
}

// ------------------------------------------------------------- card fetch

/// Fills the "had cards" stubs in [logs] with cards fetched from the card
/// documents ([cards] keyed by `deviceId_entry`).
List<DeviceLog> injectCards(List<DeviceLog> logs, Map<String, List<int>> cards) {
  if (cards.isEmpty) return logs;
  return [
    for (final l in logs)
      DeviceLog(
        l.deviceId,
        [
          for (final e in l.events)
            if (e.kind == EventKind.cards && e.data['c'] == null && cards[cardDocId(l.deviceId, e.data['e'] as int? ?? -1)] != null)
              e.withData({...e.data, 'c': cards[cardDocId(l.deviceId, e.data['e'] as int)]})
            else
              e
        ],
        serverSkewMs: l.serverSkewMs,
        uploadedAtMs: l.uploadedAtMs,
      )
  ];
}

/// Asks for the cards the TV may show, once per entry, retrying missing
/// ones (the phone was offline, or the server's hold is still running)
/// with a growing gap: 1, 2, 4 ... 10 minutes. Card reads are what the
/// TV spends most of its few hundred reads a night on.
class CardFetcher {
  final CloudLogs cloud;
  final String nightId;
  final int Function() now;
  final Map<String, List<int>> got = {};
  final Map<String, (int, int)> _wait = {}; // id -> (tries, next attempt ms)

  CardFetcher(this.cloud, this.nightId, {int Function()? now})
      : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Fetches what is due; true when new cards arrived.
  Future<bool> fill(MergedNight m, {TvOptions opts = const TvOptions()}) async {
    final t = now();
    var fresh = false;
    for (final h in m.hands) {
      if (!cardsOpen(m.timeline, h.hand, t, opts.cardDelayMs)) continue;
      for (final p in h.players.values) {
        final e = p.entryNo;
        if (!p.hadCards || p.cards != null || e == null) continue;
        final id = cardDocId(p.deviceId, e);
        if (got.containsKey(id)) continue;
        final w = _wait[id];
        if (w != null && t < w.$2) continue;
        List<int>? c;
        try {
          c = await cloud.getCards(nightId, p.deviceId, e);
        } catch (_) {
          c = null;
        }
        if (c != null) {
          got[id] = c;
          _wait.remove(id);
          fresh = true;
        } else {
          final tries = (w?.$1 ?? 0) + 1;
          _wait[id] = (tries, t + min(10 * 60000, 60000 * (1 << min(tries - 1, 4))));
        }
      }
    }
    return fresh;
  }
}
