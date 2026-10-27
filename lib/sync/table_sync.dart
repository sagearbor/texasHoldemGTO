/// Multi-phone "table night" sync (PROTOTYPE, not wired into the app).
///
/// One host creates a table with a short join code; friends join with a
/// display name. The host's table document owns seat order and the dealer
/// button; every phone derives hand numbers, dealers and positions from it,
/// so nobody has to agree on timestamps. Each phone writes only its own
/// entries; one board caller writes boards. Hole cards stay private unless
/// revealed, and revealed cards are visible only to players who share too.
///
/// The design, data model, security rules and cost estimate are in
/// docs/MULTIPHONE.md. [TableSync] is the seam: [FakeTableSync]
/// (fake_table_sync.dart) is an in-memory implementation that enforces the
/// same rules as firestore.rules; FirestoreTableSync is a documented stub.
library;

import 'dart:math';

import '../homegame/home_game.dart';
import '../poker/cards.dart';

// ------------------------------------------------------------- join codes

/// No 0/O, 1/I: codes are read aloud across a table.
const joinCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const joinCodeLength = 6;

String newJoinCode(Random rng) => String.fromCharCodes([
      for (var i = 0; i < joinCodeLength; i++)
        joinCodeAlphabet.codeUnitAt(rng.nextInt(joinCodeAlphabet.length))
    ]);

/// Upper-cases and drops spaces/dashes ("abc 234" -> "ABC234"). Codes never
/// contain 0/O/1/I, so a typed look-alike simply fails validation.
String normalizeJoinCode(String raw) =>
    raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

bool isValidJoinCode(String code) =>
    RegExp('^[A-HJ-NP-Z2-9]{$joinCodeLength}\$').hasMatch(code);

// ------------------------------------------------------------- table state

/// From hand [from] on, [seats] (uids, clockwise) are at the table and the
/// button is on seats[button] for hand [from], moving one seat per hand.
/// The host appends a segment whenever seats change or the dealer is
/// corrected; history is never rewritten, so old hand numbers keep their
/// dealer.
class RotationSegment {
  final int from;
  final List<String> seats;
  final int button;

  const RotationSegment({required this.from, required this.seats, required this.button});

  Map<String, dynamic> toJson() => {'from': from, 'seats': seats, 'button': button};

  static RotationSegment fromJson(Map<String, dynamic> j) => RotationSegment(
        from: j['from'] as int,
        seats: (j['seats'] as List).cast<String>(),
        button: j['button'] as int,
      );
}

/// The host-owned table document (tables/{code}).
class TableState {
  final String code;
  final String hostUid;
  final String name;

  /// The hand being dealt now. Hands below it are over.
  final int currentHand;
  final String boardCaller;

  /// TV dashboard delay in minutes (see dashboardDelays).
  final int delayMin;
  final bool closed;
  final List<RotationSegment> rotation;

  /// Display names by uid, copied by the host when seating people.
  final Map<String, String> names;

  const TableState({
    required this.code,
    required this.hostUid,
    required this.name,
    required this.currentHand,
    required this.boardCaller,
    required this.delayMin,
    required this.closed,
    required this.rotation,
    required this.names,
  });

  TableState copyWith({
    int? currentHand,
    String? boardCaller,
    int? delayMin,
    bool? closed,
    List<RotationSegment>? rotation,
    Map<String, String>? names,
  }) =>
      TableState(
        code: code,
        hostUid: hostUid,
        name: name,
        currentHand: currentHand ?? this.currentHand,
        boardCaller: boardCaller ?? this.boardCaller,
        delayMin: delayMin ?? this.delayMin,
        closed: closed ?? this.closed,
        rotation: rotation ?? this.rotation,
        names: names ?? this.names,
      );

  /// The segment in force for [hand]: the last one starting at or before it.
  RotationSegment? segmentFor(int hand) {
    RotationSegment? out;
    for (final s in rotation) {
      if (s.from <= hand) out = s;
    }
    return out;
  }

  List<String> seatsAt(int hand) => segmentFor(hand)?.seats ?? const [];

  /// Seat index of the button for [hand], or null before anyone is seated.
  int? buttonSeatAt(int hand) {
    final s = segmentFor(hand);
    if (s == null || s.seats.isEmpty) return null;
    return (s.button + hand - s.from) % s.seats.length;
  }

  String? dealerOf(int hand) {
    final b = buttonSeatAt(hand);
    return b == null ? null : seatsAt(hand)[b];
  }

  String nameOf(String? uid) => uid == null ? '?' : names[uid] ?? '?';

  /// [uid]'s position in [hand], or null if they were not seated.
  String? positionOf(String uid, int hand) {
    final seats = seatsAt(hand);
    final seat = seats.indexOf(uid);
    final b = buttonSeatAt(hand);
    if (seat < 0 || b == null || seats.length < 2) return null;
    return positionName(seats.length, (seat - b) % seats.length);
  }

  /// A new segment from the current hand with [seats], keeping the button
  /// on [dealer] (default: whoever deals now, if still seated, else the
  /// next seated player clockwise from them).
  RotationSegment reseat(List<String> seats, {String? dealer}) {
    var d = dealer ?? dealerOf(currentHand);
    if (d != null && !seats.contains(d)) {
      final old = seatsAt(currentHand);
      final at = old.indexOf(d);
      d = null;
      for (var k = 1; k <= old.length && d == null; k++) {
        final next = old[(at + k) % old.length];
        if (seats.contains(next)) d = next;
      }
    }
    final b = d == null ? 0 : seats.indexOf(d);
    return RotationSegment(from: currentHand, seats: List.of(seats), button: b < 0 ? 0 : b);
  }

  Map<String, dynamic> toJson() => {
        'hostUid': hostUid,
        'name': name,
        'currentHand': currentHand,
        'boardCaller': boardCaller,
        'delayMin': delayMin,
        'closed': closed,
        'rotation': [for (final s in rotation) s.toJson()],
        'names': names,
      };

  static TableState fromJson(String code, Map<String, dynamic> j) => TableState(
        code: code,
        hostUid: j['hostUid'] as String,
        name: j['name'] as String,
        currentHand: j['currentHand'] as int,
        boardCaller: j['boardCaller'] as String,
        delayMin: j['delayMin'] as int,
        closed: j['closed'] as bool,
        rotation: [
          for (final s in j['rotation'] as List)
            RotationSegment.fromJson((s as Map).cast<String, dynamic>())
        ],
        names: (j['names'] as Map).cast<String, String>(),
      );
}

// ----------------------------------------------------------------- records

/// tables/{code}/players/{uid}
class PlayerInfo {
  final String uid;
  final String name;

  /// One-way for the night: "I reveal my cards, show me others' reveals".
  final bool sharing;

  const PlayerInfo({required this.uid, required this.name, this.sharing = false});
}

/// tables/{code}/entries/{uid}_{handNo}: your public, optional action.
/// Never contains cards. [ts] is the server time of the write.
class HandEntry {
  final String uid;
  final int handNo;
  final PreAction? action;
  final Facing? facing;
  final String position;
  final bool hasCards;
  final int ts;

  const HandEntry({
    required this.uid,
    required this.handNo,
    this.action,
    this.facing,
    required this.position,
    required this.hasCards,
    required this.ts,
  });

  String get id => '${uid}_$handNo';

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'handNo': handNo,
        if (action != null) 'action': action!.name,
        if (facing != null) 'facing': facing!.name,
        'position': position,
        'hasCards': hasCards,
        'ts': ts,
      };
}

/// tables/{code}/cards/{uid}_{handNo}: your hole cards.
class HoleCards {
  final String uid;
  final int handNo;
  final List<int> cards;
  final bool revealed;

  const HoleCards({
    required this.uid,
    required this.handNo,
    required this.cards,
    required this.revealed,
  });

  String get id => '${uid}_$handNo';
}

/// tables/{code}/boards/{handNo}: 3 (flop), 4 (turn) or 5 (river) cards,
/// written by the board caller. Voice entry produces exactly this.
class Board {
  final int handNo;
  final List<int> cards;
  final String by;
  final int ts;

  const Board({required this.handNo, required this.cards, required this.by, required this.ts});
}

/// A write the security rules (and the fake) refuse.
class SyncDenied implements Exception {
  final String reason;
  const SyncDenied(this.reason);
  @override
  String toString() => 'SyncDenied: $reason';
}

// --------------------------------------------------------------- interface

/// Everything a phone (or the TV dashboard) does with a shared table.
/// Each phone acts as one signed-in [uid] (anonymous auth in Firestore).
abstract class TableSync {
  String get uid;

  /// Creates a table with a fresh join code, joins it as host and board
  /// caller, and seats the host. Returns the code.
  Future<String> createTable({required String name, required String hostName, int delayMin = 15});

  /// Joins by code with a display name. Seating is up to the host.
  Future<TableState> join(String code, String displayName);

  Future<TableState> table(String code);

  /// One listener per phone: the table document (hand counter, seats).
  Stream<TableState> watchTable(String code);

  // Host only.
  Future<void> seatPlayers(String code, List<String> seats, {String? dealer});
  Future<void> setDealer(String code, String dealerUid);
  Future<void> setBoardCaller(String code, String uid);
  Future<void> closeTable(String code);

  /// "Next hand". Returns false when another phone already advanced past
  /// [from] (the rules reject the duplicate; it is not an error).
  Future<bool> advanceHand(String code, {required int from});

  /// Your own entry for [handNo]; position comes from the rotation.
  Future<void> logEntry(String code,
      {required int handNo, PreAction? action, Facing? facing, required bool hasCards});

  /// Your own hole cards. Once you share, every save is revealed.
  Future<void> saveCards(String code, int handNo, List<int> cards, {bool reveal = false});
  Future<void> revealCards(String code, int handNo);

  /// Turns on give-to-get sharing for the night (cannot be undone).
  Future<void> startSharing(String code);

  /// Board caller (or host) only. 3-5 cards; overwrite to add turn/river.
  Future<void> recordBoard(String code, int handNo, List<int> cards);

  Future<List<PlayerInfo>> players(String code);
  Future<List<Board>> boards(String code);
  Stream<List<Board>> watchBoards(String code);

  /// Everyone's public entries (the dashboard's single listener).
  Future<List<HandEntry>> entries(String code);
  Stream<List<HandEntry>> watchEntries(String code);

  Future<List<HoleCards>> myCards(String code);

  /// Other players' revealed cards for finished hands. Throws [SyncDenied]
  /// unless you are sharing.
  Future<List<HoleCards>> revealedCards(String code);
}

// ------------------------------------------------------ late entry by board

/// A hand you might mean when logging late.
class HandChoice {
  final int handNo;
  final String? dealerUid;
  final String dealerName;
  final Board? board;

  /// How many hinted cards this hand's board has by rank ("a king and a
  /// seven"), and how many of those also match the suit.
  final int matched;
  final int exact;
  final bool isCurrent;

  /// You already have an entry for it.
  final bool logged;

  const HandChoice({
    required this.handNo,
    required this.dealerUid,
    required this.dealerName,
    required this.board,
    required this.matched,
    required this.exact,
    required this.isCurrent,
    required this.logged,
  });
}

(int, int) _boardMatch(Board? b, List<int> hint) {
  if (b == null) return (0, 0);
  final ranks = [for (final c in b.cards) cardRank(c)];
  var matched = 0, exact = 0;
  for (final c in hint) {
    final i = ranks.indexOf(cardRank(c));
    if (i < 0) continue;
    ranks[i] = -1;
    matched++;
    if (b.cards.contains(c)) exact++;
  }
  return (matched, exact);
}

/// The picker for "which hand was that?": the last [limit] hands, newest
/// first, each with its number, dealer and board if the caller recorded it.
/// With [hint] (board cards you remember; ranks count, suits break ties),
/// hands whose board has every hinted rank are the only ones kept if any
/// exist, otherwise the best partial matches come first. Never by time.
List<HandChoice> handChoices(
  TableState t,
  List<Board> boards, {
  Set<int> logged = const {},
  List<int> hint = const [],
  int limit = 12,
}) {
  final byHand = {for (final b in boards) b.handNo: b};
  final first = max(1, t.currentHand - limit + 1);
  final out = <HandChoice>[
    for (var n = t.currentHand; n >= first; n--)
      () {
        final (m, e) = _boardMatch(byHand[n], hint);
        return HandChoice(
          handNo: n,
          dealerUid: t.dealerOf(n),
          dealerName: t.nameOf(t.dealerOf(n)),
          board: byHand[n],
          matched: m,
          exact: e,
          isCurrent: n == t.currentHand,
          logged: logged.contains(n),
        );
      }()
  ];
  if (hint.isEmpty) return out;
  int byMatch(HandChoice a, HandChoice b) => a.matched != b.matched
      ? b.matched - a.matched
      : a.exact != b.exact
          ? b.exact - a.exact
          : b.handNo - a.handNo;
  final full = out.where((c) => c.matched == hint.length).toList()..sort(byMatch);
  return full.isNotEmpty ? full : (out..sort(byMatch));
}

/// The hand an entry belongs to is fixed when you start it (first card or
/// action tapped), not when you press save, so finishing an entry during
/// the next deal still files it under the right hand.
class EntryDraft {
  final int handNo;
  final String dealerName;
  EntryDraft(TableState t)
      : handNo = t.currentHand,
        dealerName = t.nameOf(t.dealerOf(t.currentHand));

  /// Shown above the save button once the table has moved on.
  String? banner(TableState now) => now.currentHand == handNo
      ? null
      : 'Saving to hand #$handNo ($dealerName dealt). '
          'The table is on #${now.currentHand}.';
}

// ------------------------------------------------------------- dashboard

class PlayerAggregate {
  final String uid;
  final String name;

  /// Entries counted (finished hands older than the dashboard delay).
  final int logged;
  final int recorded;
  final int vpip;
  final int pfr;

  const PlayerAggregate({
    required this.uid,
    required this.name,
    required this.logged,
    required this.recorded,
    required this.vpip,
    required this.pfr,
  });

  double get vpipPct => recorded == 0 ? 0 : vpip / recorded;
  double get pfrPct => recorded == 0 ? 0 : pfr / recorded;
  String get style => playStyle(recorded, vpipPct, pfrPct);
}

/// VPIP / PFR / style per player from public actions only. Counts an entry
/// only when its hand is over and it was written at least the table's
/// dashboard delay ago, so the TV never shows the hand just played.
/// Players with no countable entries are still listed (zeroes).
List<PlayerAggregate> tableAggregates(
  TableState t,
  List<PlayerInfo> players,
  List<HandEntry> entries, {
  required DateTime now,
}) {
  final cutoff = now.millisecondsSinceEpoch - t.delayMin * 60000;
  final by = <String, List<HandEntry>>{};
  for (final e in entries) {
    if (e.handNo >= t.currentHand || e.ts > cutoff) continue;
    by.putIfAbsent(e.uid, () => []).add(e);
  }
  return [
    for (final p in players)
      () {
        final es = by[p.uid] ?? const <HandEntry>[];
        final acted = es.where((e) => e.action != null);
        return PlayerAggregate(
          uid: p.uid,
          name: p.name,
          logged: es.length,
          recorded: acted.length,
          vpip: acted.where((e) => e.action != PreAction.fold).length,
          pfr: acted.where((e) => e.action == PreAction.raise).length,
        );
      }()
  ];
}

// --------------------------------------------------------------- migration

/// The phone keeps its own HomeSession as today; a synced night just fills
/// it from shared state. This builds the local [LoggedHand] for [handNo]
/// so every existing stat, recap and badge works unchanged.
LoggedHand loggedHandFrom(TableState t, String uid, int handNo,
    {HandEntry? entry, HoleCards? cards}) {
  return LoggedHand(
    number: handNo,
    cards: cards?.cards,
    position: entry?.position ?? t.positionOf(uid, handNo) ?? '?',
    dealer: t.nameOf(t.dealerOf(handNo)),
    action: entry?.action,
    facing: entry?.action == null ? null : entry?.facing,
    ts: entry?.ts ?? 0,
  );
}
