/// [CloudLogs] on Cloud Firestore (project felt-notes-poker, or a local
/// emulator). Paths and fields match firestore.rules, which
/// tool/firestore_rules/ tests against the emulator and tool/e2e/ against
/// the real project.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import 'cloud_logs.dart';
import 'night_events.dart';
import 'night_merge.dart';

class FirestoreCloudLogs implements CloudLogs {
  final FirebaseFirestore db;
  final FirebaseAuth auth;

  FirestoreCloudLogs(this.db, this.auth);

  static Future<FirestoreCloudLogs> start({
    required FirebaseOptions options,
    String? emulator,
    String? authEmulator,
  }) async {
    final app = await Firebase.initializeApp(name: 'feltnotes-sync', options: options);
    final db = FirebaseFirestore.instanceFor(app: app);
    final auth = FirebaseAuth.instanceFor(app: app);
    if (emulator != null) {
      final i = emulator.lastIndexOf(':');
      final host = emulator.substring(0, i);
      db.useFirestoreEmulator(host, int.parse(emulator.substring(i + 1)));
      final a = authEmulator ?? '$host:9099';
      final j = a.lastIndexOf(':');
      await auth.useAuthEmulator(a.substring(0, j), int.parse(a.substring(j + 1)));
    }
    // The phone's own EventLog is the source of truth and the outbox, so
    // the SDK's offline cache is not needed (and a queued write would make
    // the server-time skew measurement meaningless).
    db.settings = const Settings(persistenceEnabled: false);
    return FirestoreCloudLogs(db, auth);
  }

  static const _timeout = Duration(seconds: 20);

  Future<String> _uid() async {
    final u = auth.currentUser ?? (await auth.signInAnonymously().timeout(_timeout)).user;
    if (u == null) throw StateError('no anonymous user');
    return u.uid;
  }

  DocumentReference<Map<String, dynamic>> _night(String id) => db.collection('nights').doc(id);

  /// TTL field (firestore.rules wants 1 to 90 days ahead).
  static Timestamp _expiry() =>
      Timestamp.fromDate(DateTime.now().add(const Duration(days: retentionDays)));

  static String _short(String name) => name.isEmpty ? '?' : (name.length > 24 ? name.substring(0, 24) : name);

  @override
  Future<void> join(JoinTicket ticket, {required String deviceId, required String name, bool create = true}) async {
    final uid = await _uid();
    final night = _night(ticket.nightId);
    // The first phone online creates the night; the rules let a non-member
    // read a night only to learn it does not exist yet.
    var exists = false;
    try {
      exists = (await night.get(const GetOptions(source: Source.server)).timeout(_timeout)).exists;
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      exists = true; // it exists and we are not in yet
    }
    if (!exists && !create) throw StateError('No such table night (yet).');
    if (!exists) {
      try {
        await night.set({
          'secret': ticket.secret,
          'organizer': ticket.organizerName.length > 24 ? ticket.organizerName.substring(0, 24) : ticket.organizerName,
          'createdAt': FieldValue.serverTimestamp(),
          'expireAt': _expiry(),
        }).timeout(_timeout);
      } on FirebaseException catch (e) {
        // Someone else created it a moment ago: fine, the member write
        // below checks the secret against theirs.
        if (e.code != 'permission-denied') rethrow;
      }
    }
    Future<void> member(String uid) => night.collection('members').doc(uid).set({
          'name': _short(name),
          'deviceId': deviceId,
          'secret': ticket.secret,
          'joinedAt': FieldValue.serverTimestamp(),
          'expireAt': _expiry(),
        }).timeout(_timeout);
    try {
      await member(uid);
    } on FirebaseException catch (e) {
      // This sign-in already joined the night under another device id (an
      // iPhone keeps its sign-in in the keychain across a reinstall, a
      // browser may keep it after its storage was cleared): the rules never
      // let a member change device, so join again as a fresh anonymous user.
      if (e.code != 'permission-denied') rethrow;
      await auth.signOut();
      await member(await _uid());
    }
  }

  @override
  Future<int?> putPart(String nightId, LogPart part, {required int clientMs, bool measure = false}) async {
    final uid = await _uid();
    final ref = _night(nightId).collection('logs').doc(part.docId);
    await ref.set({
      'uid': uid,
      'deviceId': part.deviceId,
      'part': part.part,
      'count': part.events.length,
      'events': [for (final e in part.events) e.encode()],
      'name': _short(part.name),
      if (part.skewMs != null) 'skew': part.skewMs,
      'clientMs': clientMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'expireAt': _expiry(),
    }).timeout(_timeout);
    if (!measure) return null;
    final snap = await ref.get(const GetOptions(source: Source.server)).timeout(_timeout);
    final ts = snap.data()?['updatedAt'];
    return ts is Timestamp ? ts.millisecondsSinceEpoch : null;
  }

  @override
  Future<void> deletePart(String nightId, String deviceId, int part) async {
    await _uid();
    await _night(nightId).collection('logs').doc('${deviceId}_$part').delete().timeout(_timeout);
  }

  @override
  Future<void> putCards(String nightId, String deviceId, int entry, List<int> cards) async {
    final uid = await _uid();
    await _night(nightId).collection('cards').doc(cardDocId(deviceId, entry)).set({
      'uid': uid,
      'deviceId': deviceId,
      'e': entry,
      'c': cards,
      'at': FieldValue.serverTimestamp(),
      'expireAt': _expiry(),
    }).timeout(_timeout);
  }

  @override
  Future<void> deleteCards(String nightId, String deviceId, int entry) async {
    await _uid();
    await _night(nightId).collection('cards').doc(cardDocId(deviceId, entry)).delete().timeout(_timeout);
  }

  @override
  Future<List<int>?> getCards(String nightId, String deviceId, int entry) async {
    await _uid();
    try {
      final snap = await _night(nightId)
          .collection('cards')
          .doc(cardDocId(deviceId, entry))
          .get(const GetOptions(source: Source.server))
          .timeout(_timeout);
      final c = snap.data()?['c'];
      return c is List && c.length == 2 ? c.cast<int>() : null;
    } on FirebaseException catch (e) {
      // Missing, or still inside the server's hold: try again later.
      if (e.code == 'permission-denied' || e.code == 'not-found') return null;
      rethrow;
    }
  }

  static LogPart? _part(Map<String, dynamic> d) {
    final dev = d['deviceId'];
    if (dev is! String) return null;
    final at = d['updatedAt'];
    return LogPart(
      deviceId: dev,
      part: (d['part'] as int?) ?? 0,
      name: (d['name'] as String?) ?? '',
      skewMs: d['skew'] as int?,
      uploadedAtMs: at is Timestamp ? at.millisecondsSinceEpoch : null,
      events: [
        for (final s in (d['events'] as List? ?? const []).whereType<String>())
          if (NightEvent.decode(dev, s) case final e?) e
      ],
    );
  }

  @override
  Future<List<DeviceLog>> fetch(String nightId) async {
    await _uid();
    final q = await _night(nightId).collection('logs').get(const GetOptions(source: Source.server)).timeout(_timeout);
    return logsFromParts([for (final d in q.docs) if (_part(d.data()) case final p?) p]);
  }

  @override
  Stream<List<DeviceLog>> watch(String nightId) async* {
    await _uid();
    yield* _night(nightId)
        .collection('logs')
        .snapshots()
        .map((q) => logsFromParts([for (final d in q.docs) if (_part(d.data()) case final p?) p]));
  }
}
