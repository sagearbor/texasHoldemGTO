/// In-memory [TableSync] for unit tests and offline demos. One
/// [FakeTableBackend] plays the server; each [FakeTableSync] is one phone.
/// Every write is checked the same way firestore.rules checks it (and
/// throws [SyncDenied]), so tests of the fake describe the real contract.
library;

import 'dart:async';
import 'dart:math';

import '../homegame/home_game.dart';
import 'table_sync.dart';

class _Table {
  TableState state;
  final Map<String, PlayerInfo> players = {};
  final Map<String, HandEntry> entries = {};
  final Map<String, HoleCards> cards = {};
  final Map<int, Board> boards = {};
  _Table(this.state);
}

class FakeTableBackend {
  final Random _rng;

  /// Server clock in ms since epoch (tests move it forward).
  int now;
  final Map<String, _Table> _tables = {};
  final _changes = StreamController<String>.broadcast(sync: true);

  /// Document reads a real backend would bill, for the cost estimate.
  int reads = 0;
  int writes = 0;

  FakeTableBackend({int? seed, int? startMs})
      : _rng = Random(seed ?? 7),
        now = startMs ?? DateTime(2026, 10, 30, 19).millisecondsSinceEpoch;

  _Table _get(String code) {
    final t = _tables[code];
    if (t == null) throw SyncDenied('no table $code');
    return t;
  }

  void _write(String code) {
    writes++;
    _changes.add(code);
  }
}

class FakeTableSync implements TableSync {
  final FakeTableBackend _b;
  @override
  final String uid;

  FakeTableSync(this._b, this.uid);

  _Table _t(String code) => _b._get(code);

  void _member(_Table t) {
    if (!t.players.containsKey(uid)) throw const SyncDenied('not a member');
  }

  void _open(_Table t) {
    if (t.state.closed) throw const SyncDenied('table is closed');
  }

  void _host(_Table t) {
    if (t.state.hostUid != uid) throw const SyncDenied('host only');
    _open(t);
  }

  void _handInRange(_Table t, int handNo) {
    if (handNo < 1 || handNo > t.state.currentHand) {
      throw SyncDenied('hand $handNo has not been dealt');
    }
  }

  bool _sharing(_Table t) => t.players[uid]?.sharing ?? false;

  @override
  Future<String> createTable({required String name, required String hostName, int delayMin = 15}) async {
    String code;
    do {
      code = newJoinCode(_b._rng);
    } while (_b._tables.containsKey(code));
    _b._tables[code] = _Table(TableState(
      code: code,
      hostUid: uid,
      name: name,
      currentHand: 1,
      boardCaller: uid,
      delayMin: delayMin,
      closed: false,
      rotation: [
        RotationSegment(from: 1, seats: [uid], button: 0)
      ],
      names: {uid: hostName},
    ));
    _b._write(code);
    await join(code, hostName);
    return code;
  }

  @override
  Future<TableState> join(String code, String displayName) async {
    code = normalizeJoinCode(code);
    final t = _t(code);
    _open(t);
    final name = displayName.trim();
    if (name.isEmpty || name.length > 24) throw const SyncDenied('bad name');
    final had = t.players[uid];
    // Re-joining keeps "sharing" (the rules forbid resetting it).
    t.players[uid] = PlayerInfo(uid: uid, name: name, sharing: had?.sharing ?? false);
    _b._write(code);
    _b.reads++;
    return t.state;
  }

  @override
  Future<TableState> table(String code) async {
    _b.reads++;
    return _t(code).state;
  }

  @override
  Stream<TableState> watchTable(String code) {
    _member(_t(code));
    return _watch(code, () => table(code));
  }

  /// A snapshot listener: the current value on listen, then one per change.
  Stream<T> _watch<T>(String code, Future<T> Function() read) {
    StreamSubscription<String>? sub;
    late final StreamController<T> out;
    out = StreamController<T>(
      onListen: () async {
        out.add(await read());
        sub = _b._changes.stream
            .where((c) => c == code)
            .listen((_) async => out.add(await read()));
      },
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  void _setState(String code, _Table t, TableState next) {
    t.state = next;
    _b._write(code);
  }

  @override
  Future<void> seatPlayers(String code, List<String> seats, {String? dealer}) async {
    final t = _t(code);
    _host(t);
    for (final s in seats) {
      if (!t.players.containsKey(s)) throw SyncDenied('$s has not joined');
    }
    if (seats.toSet().length != seats.length || seats.length < 2) {
      throw const SyncDenied('need two or more distinct seats');
    }
    final seg = t.state.reseat(seats, dealer: dealer);
    _setState(
        code,
        t,
        t.state.copyWith(
          rotation: [...t.state.rotation, seg],
          names: {
            ...t.state.names,
            for (final s in seats) s: t.players[s]!.name,
          },
        ));
  }

  @override
  Future<void> setDealer(String code, String dealerUid) async {
    final t = _t(code);
    _host(t);
    final seats = t.state.seatsAt(t.state.currentHand);
    if (!seats.contains(dealerUid)) throw const SyncDenied('dealer not seated');
    _setState(code, t,
        t.state.copyWith(rotation: [...t.state.rotation, t.state.reseat(seats, dealer: dealerUid)]));
  }

  @override
  Future<void> setBoardCaller(String code, String newCaller) async {
    final t = _t(code);
    _host(t);
    _setState(code, t, t.state.copyWith(boardCaller: newCaller));
  }

  @override
  Future<void> closeTable(String code) async {
    final t = _t(code);
    _host(t);
    _setState(code, t, t.state.copyWith(closed: true));
  }

  @override
  Future<bool> advanceHand(String code, {required int from}) async {
    final t = _t(code);
    _member(t);
    _open(t);
    // Rules: currentHand may only become old + 1. A phone that saw [from]
    // after someone else advanced writes from + 1 == current: rejected.
    if (t.state.currentHand != from) return false;
    _setState(code, t, t.state.copyWith(currentHand: from + 1));
    return true;
  }

  @override
  Future<void> logEntry(String code,
      {required int handNo, PreAction? action, Facing? facing, required bool hasCards}) async {
    final t = _t(code);
    _member(t);
    _open(t);
    _handInRange(t, handNo);
    final e = HandEntry(
      uid: uid,
      handNo: handNo,
      action: action,
      facing: action == null ? null : facing,
      position: t.state.positionOf(uid, handNo) ?? '?',
      hasCards: hasCards,
      ts: _b.now,
    );
    t.entries[e.id] = e;
    _b._write(code);
  }

  @override
  Future<void> saveCards(String code, int handNo, List<int> cards, {bool reveal = false}) async {
    final t = _t(code);
    _member(t);
    _open(t);
    _handInRange(t, handNo);
    if (cards.length != 2 || cards.any((c) => c < 0 || c > 51)) {
      throw const SyncDenied('two cards 0..51');
    }
    final id = '${uid}_$handNo';
    final had = t.cards[id];
    final revealed = reveal || (had?.revealed ?? false);
    if (_sharing(t) && !revealed) {
      throw const SyncDenied('a sharer\'s cards are always revealed');
    }
    t.cards[id] = HoleCards(uid: uid, handNo: handNo, cards: List.of(cards), revealed: revealed);
    _b._write(code);
  }

  @override
  Future<void> revealCards(String code, int handNo) async {
    final t = _t(code);
    _member(t);
    _open(t);
    final had = t.cards['${uid}_$handNo'];
    if (had == null) throw const SyncDenied('no cards saved for that hand');
    t.cards[had.id] = HoleCards(uid: uid, handNo: handNo, cards: had.cards, revealed: true);
    _b._write(code);
  }

  @override
  Future<void> startSharing(String code) async {
    final t = _t(code);
    _member(t);
    _open(t);
    final p = t.players[uid]!;
    t.players[uid] = PlayerInfo(uid: uid, name: p.name, sharing: true);
    _b._write(code);
  }

  @override
  Future<void> recordBoard(String code, int handNo, List<int> cards) async {
    final t = _t(code);
    _open(t);
    if (t.state.boardCaller != uid && t.state.hostUid != uid) {
      throw const SyncDenied('only the board caller records boards');
    }
    _handInRange(t, handNo);
    if (cards.length < 3 || cards.length > 5) throw const SyncDenied('3 to 5 cards');
    t.boards[handNo] = Board(handNo: handNo, cards: List.of(cards), by: uid, ts: _b.now);
    _b._write(code);
  }

  List<T> _read<T>(Iterable<T> docs) {
    final out = docs.toList();
    _b.reads += max(1, out.length);
    return out;
  }

  @override
  Future<List<PlayerInfo>> players(String code) async {
    final t = _t(code);
    _member(t);
    return _read(t.players.values);
  }

  @override
  Future<List<Board>> boards(String code) async {
    final t = _t(code);
    _member(t);
    return _read(t.boards.values.toList()..sort((a, b) => a.handNo - b.handNo));
  }

  @override
  Stream<List<Board>> watchBoards(String code) => _watch(code, () => boards(code));

  @override
  Future<List<HandEntry>> entries(String code) async {
    final t = _t(code);
    _member(t);
    return _read(t.entries.values.toList()
      ..sort((a, b) => a.handNo != b.handNo ? a.handNo - b.handNo : a.uid.compareTo(b.uid)));
  }

  @override
  Stream<List<HandEntry>> watchEntries(String code) => _watch(code, () => entries(code));

  @override
  Future<List<HoleCards>> myCards(String code) async {
    final t = _t(code);
    _member(t);
    return _read(t.cards.values.where((c) => c.uid == uid).toList()
      ..sort((a, b) => a.handNo - b.handNo));
  }

  @override
  Future<List<HoleCards>> revealedCards(String code) async {
    final t = _t(code);
    _member(t);
    if (!_sharing(t)) throw const SyncDenied('share yours to see others\'');
    return _read(t.cards.values
        .where((c) => c.uid != uid && c.revealed && c.handNo < t.state.currentHand)
        .toList()
      ..sort((a, b) => a.handNo != b.handNo ? a.handNo - b.handNo : a.uid.compareTo(b.uid)));
  }
}
