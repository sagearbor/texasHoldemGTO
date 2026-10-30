/// The organizer's phone runs the normal hand logger ([HomeSession]); this
/// mirrors it into the table night's event log, so the hand logger needs
/// no sync code at all.
///
/// It works from state, not from button presses: [OrganizerBridge.reconcile]
/// compares the session (seats, hand starts and dealers, boards, the
/// organizer's own closed hands, ended) with what the log already says and
/// appends only the difference. So undo, a dealer correction, the first
/// orbit reshuffling the seats, an app restart or a missed notification all
/// converge to the same log. Times come from the session (the moment each
/// hand started), not from when the bridge ran.
///
/// The organizer's own cards are written only for hands that are over (a
/// [LoggedHand] exists once Next hand was tapped), marked `done` so they may
/// go to the cloud straight away; the hand being played never leaves.
library;

import 'dart:convert';

import '../homegame/home_game.dart';
import 'night_events.dart';
import 'table_sync.dart';

/// Seat ids on a table night are the names in the hand logger (unique
/// within a night: the setup and "someone new" both refuse duplicates).
List<Seat> seatsOf(HomeSession s) => [for (final p in s.players) Seat(p, p)];

/// Everyone on tonight's list, seated first, for the QR's "which one are
/// you".
List<Seat> rosterOf(HomeSession s) => [...seatsOf(s), for (final b in s.bench) Seat(b, b)];

class _Own {
  final PreAction? action;
  final Facing? facing;
  final List<int>? cards;
  const _Own(this.action, this.facing, this.cards);
  bool get empty => action == null && cards == null;
  String get key => '${action?.name}|${facing?.name}|${cards?.join(',')}';
}

class OrganizerBridge {
  final LocalTableSync sync;
  OrganizerBridge(this.sync);

  bool _running = false;
  bool _again = false;
  HomeSession? _pending;

  /// Brings the log in line with [s]. Safe to call on every change; calls
  /// made while one is running coalesce into one more pass.
  Future<void> reconcile(HomeSession s) async {
    _pending = s;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        await _reconcile(_pending!);
      } while (_again);
    } finally {
      _running = false;
    }
  }

  /// Records the blind clock (BlindClock json) when it differs from the
  /// last one recorded.
  Future<void> recordClock(Map<String, Object?> json) async {
    String? last;
    for (final e in sync.localEvents.reversed) {
      if (e.kind == EventKind.clock) {
        last = jsonEncode(e.data['j']);
        break;
      }
    }
    if (last == jsonEncode(json)) return;
    await sync.appendEvent(EventKind.clock, {'j': json});
  }

  Future<void> _reconcile(HomeSession s) async {
    final evs = sync.localEvents;
    // ---- what the log says so far
    List<Seat>? lastSeats;
    final hands = <int, (int, String?)>{};
    final boards = <int, String>{};
    var ended = false;
    for (final e in evs) {
      switch (e.kind) {
        case EventKind.seats:
          lastSeats = [for (final x in (e.data['seats'] as List? ?? const [])) Seat.fromJson(x)];
        case EventKind.hand:
          final n = e.data['n'];
          if (n is int) hands[n] = (e.ms, e.data['d'] as String?);
        case EventKind.unhand:
          hands.remove(e.data['n']);
        case EventKind.board:
          final n = e.data['n'];
          if (n is int) boards[n] = ((e.data['c'] as List?) ?? const []).join(',');
        case EventKind.end:
          ended = true;
        default:
          break;
      }
    }

    // ---- what the session says
    final want = <int, (int, String?)>{};
    for (var i = 0; i < s.hands.length; i++) {
      final h = s.hands[i];
      final start = h.start ?? (i == 0 ? s.started : s.hands[i - 1].ts);
      want[h.number] = (start, h.dealer);
    }
    final current = s.hands.length + 1;
    if (!s.closed && s.handInProgress) {
      want[current] = (s.handStartedAt!, s.players[s.buttonSeat]);
    }

    // Seats first: a hand takes the seats recorded before it.
    final seats = seatsOf(s);
    final wasLearning = sync.log.meta['br.learning'] == true;
    final reseat = lastSeats == null || !_sameSeats(lastSeats, seats);
    if (reseat) await sync.setSeats(seats);
    // The first orbit just ended: the seat order is final, so give every
    // hand so far the final seats (positions become right).
    final redoAll = wasLearning && !s.learning;
    if (wasLearning != s.learning) await sync.log.setMeta('br.learning', s.learning ? true : null);

    final order = want.keys.toList()..sort();
    for (final n in order) {
      final w = want[n]!;
      if (redoAll || hands[n] != w) {
        await sync.appendEvent(EventKind.hand, {'n': n, 'd': w.$2}, ms: w.$1);
      }
    }
    for (final n in hands.keys.toList()..sort()) {
      if (!want.containsKey(n)) await sync.appendEvent(EventKind.unhand, {'n': n});
    }

    // Boards (3 to 5 cards; an empty one clears a board that was undone).
    final wantBoards = <int, String>{
      for (final h in s.hands)
        if (h.board != null && h.board!.length >= 3) h.number: h.board!.join(','),
      if (!s.closed && s.currentBoard.length >= 3) current: s.currentBoard.join(','),
    };
    for (final n in wantBoards.keys) {
      if (boards[n] != wantBoards[n]) {
        await sync.appendEvent(EventKind.board, {'n': n, 'c': wantBoards[n]!.split(',').map(int.parse).toList()});
      }
    }
    for (final n in boards.keys) {
      if (!wantBoards.containsKey(n) && boards[n]!.isNotEmpty && want.containsKey(n)) {
        await sync.appendEvent(EventKind.board, {'n': n, 'c': <int>[]});
      }
    }

    // The organizer's own closed hands, one entry each, tagged with the
    // hand number (`h`) so the log alone says which entry is whose: no
    // separate bookkeeping that a crash could leave out of step.
    final live = <int, Set<int>>{}; // hand -> live entries
    final undone = <int>{};
    final acts = <int, (PreAction?, Facing?)>{};
    final cards = <int, List<int>>{};
    var top = 0;
    for (final e in evs) {
      final x = e.data['e'];
      if (x is! int) continue;
      if (x > top) top = x;
      if (e.kind == EventKind.undo) undone.add(x);
      final h = e.data['h'];
      if (h is! int) continue;
      live.putIfAbsent(h, () => {}).add(x);
      if (e.kind == EventKind.play) {
        acts[x] = (
          PreAction.values.where((a) => a.name == e.data['a']).firstOrNull,
          Facing.values.where((f) => f.name == e.data['f']).firstOrNull,
        );
      }
      if (e.kind == EventKind.cards && e.data['c'] is List) cards[x] = (e.data['c'] as List).cast<int>();
    }
    for (final l in live.values) {
      l.removeAll(undone);
    }
    final closed = {for (final h in s.hands) h.number: h};
    for (final n in {...closed.keys, ...live.keys}.toList()..sort()) {
      final h = closed[n];
      final own = h == null
          ? const _Own(null, null, null)
          : _Own(h.assumed ? null : h.action, h.assumed ? null : h.facing, h.cards);
      final have = live[n] ?? const <int>{};
      final logged = have.length == 1
          ? _Own(acts[have.single]?.$1, acts[have.single]?.$2, cards[have.single])
          : const _Own(null, null, null);
      if (have.length <= 1 && logged.key == own.key) continue;
      for (final old in have) {
        await sync.appendEvent(EventKind.undo, {'e': old});
      }
      if (own.empty || h == null) continue;
      final e = ++top;
      final ms = (want[n]?.$1 ?? h.ts) + 1;
      if (own.cards != null) {
        await sync.appendEvent(EventKind.cards, {'e': e, 'h': n, 'c': own.cards, 'done': true}, ms: ms);
      }
      if (own.action != null) {
        await sync.appendEvent(
            EventKind.play, {'e': e, 'h': n, 'a': own.action!.name, if (own.facing != null) 'f': own.facing!.name},
            ms: ms);
      }
    }

    if (s.closed && !ended) {
      await sync.appendEvent(EventKind.end, const {}, ms: s.hands.isEmpty ? null : s.hands.last.ts);
    }
  }

  static bool _sameSeats(List<Seat> a, List<Seat> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
