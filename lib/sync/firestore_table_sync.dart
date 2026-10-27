/// Firestore-backed [TableSync]: a DOCUMENTED STUB on this branch.
///
/// The app ships without Firebase plugins or config, so this file has no
/// Firebase imports and every method throws. Each method's comment is the
/// exact Firestore operation to write once the owner decides to add
/// firebase_core ^3.8.1 / firebase_auth ^5.3.3 / cloud_firestore ^5.5.1
/// (the versions the oralhistory_timeline repo builds with on Flutter
/// 3.22.2). Paths and fields match firestore.rules, which is tested against
/// the emulator in tool/firestore_rules/. See docs/MULTIPHONE.md.
///
/// `T` below is `tables/{code}`. `uid` is FirebaseAuth.instance
/// .signInAnonymously() on first use; `now` is FieldValue.serverTimestamp()
/// (the rules require it for createdAt / joinedAt / ts).
library;

import '../homegame/home_game.dart';
import 'table_sync.dart';

class FirestoreTableSync implements TableSync {
  @override
  String get uid => throw _stub;

  static final _stub = UnimplementedError(
      'Multi-phone sync is a prototype: see docs/MULTIPHONE.md');

  /// Retry newJoinCode until `T.set(...)` succeeds on a missing doc
  /// (transaction: get, must not exist, set {hostUid: uid, name, createdAt:
  /// now, closed: false, currentHand: 1, boardCaller: uid, delayMin,
  /// rotation: [{from: 1, seats: [uid], button: 0}], names: {uid: hostName}}),
  /// then join().
  @override
  Future<String> createTable({required String name, required String hostName, int delayMin = 15}) =>
      throw _stub;

  /// T.get() (any signed-in user may get by code, nobody may list), then
  /// T/players/{uid}.set({name, sharing: false, joinedAt: now}); on
  /// re-join, update({name}) instead (sharing cannot be reset).
  @override
  Future<TableState> join(String code, String displayName) => throw _stub;

  /// T.get(). Cached by the SDK; prefer watchTable.
  @override
  Future<TableState> table(String code) => throw _stub;

  /// T.snapshots(): listener #1 on every phone.
  @override
  Stream<TableState> watchTable(String code) => throw _stub;

  /// T.update({rotation: FieldValue.arrayUnion([state.reseat(...)]),
  /// names.{uid}: name}). arrayUnion dedupes identical maps, which is fine:
  /// an identical segment changes nothing.
  @override
  Future<void> seatPlayers(String code, List<String> seats, {String? dealer}) => throw _stub;

  /// Same as seatPlayers with the current seats and a new dealer.
  @override
  Future<void> setDealer(String code, String dealerUid) => throw _stub;

  /// T.update({boardCaller: uid}).
  @override
  Future<void> setBoardCaller(String code, String uid) => throw _stub;

  /// T.update({closed: true}). After this the night is read-only.
  @override
  Future<void> closeTable(String code) => throw _stub;

  /// T.update({currentHand: from + 1}). PERMISSION_DENIED means another
  /// phone already advanced: return false, not an error. (No transaction
  /// needed; the rule "new == old + 1" is the compare-and-set.)
  @override
  Future<bool> advanceHand(String code, {required int from}) => throw _stub;

  /// T/entries/{uid}_{handNo}.set({uid, handNo, action?, facing?, position,
  /// hasCards, ts: now}). Offline: queued by the SDK and sent later; the
  /// handNo was fixed by the EntryDraft, so a late send is still right.
  @override
  Future<void> logEntry(String code,
          {required int handNo, PreAction? action, Facing? facing, required bool hasCards}) =>
      throw _stub;

  /// T/cards/{uid}_{handNo}.set({uid, handNo, cards: [c1, c2], revealed}).
  @override
  Future<void> saveCards(String code, int handNo, List<int> cards, {bool reveal = false}) =>
      throw _stub;

  /// T/cards/{uid}_{handNo}.update({revealed: true}).
  @override
  Future<void> revealCards(String code, int handNo) => throw _stub;

  /// T/players/{uid}.update({sharing: true}), then a batch flipping your
  /// earlier hidden cards docs to revealed (optional, the owner decides).
  @override
  Future<void> startSharing(String code) => throw _stub;

  /// T/boards/{handNo}.set({handNo, cards, by: uid, ts: now}). The voice
  /// board entry calls this with 3, then 4, then 5 cards.
  @override
  Future<void> recordBoard(String code, int handNo, List<int> cards) => throw _stub;

  /// T/players.get() (members only).
  @override
  Future<List<PlayerInfo>> players(String code) => throw _stub;

  /// T/boards.get().
  @override
  Future<List<Board>> boards(String code) => throw _stub;

  /// T/boards.where('handNo', isGreaterThan: currentHand - 12).snapshots():
  /// listener #2, opened only while the late-entry picker is on screen or
  /// on the board caller's phone.
  @override
  Stream<List<Board>> watchBoards(String code) => throw _stub;

  /// T/entries.get().
  @override
  Future<List<HandEntry>> entries(String code) => throw _stub;

  /// T/entries.snapshots(): the TV dashboard's listener. Player phones do
  /// not open it.
  @override
  Stream<List<HandEntry>> watchEntries(String code) => throw _stub;

  /// T/cards.where('uid', isEqualTo: uid).get(). Normally unnecessary: the
  /// phone keeps its own cards in its local HomeSession.
  @override
  Future<List<HoleCards>> myCards(String code) => throw _stub;

  /// T/cards.where('revealed', isEqualTo: true)
  ///        .where('handNo', isLessThan: currentHand).get()
  /// Both filters are required: the rules only allow a query they can
  /// prove returns revealed cards of finished hands. Then drop your own.
  @override
  Future<List<HoleCards>> revealedCards(String code) => throw _stub;
}
