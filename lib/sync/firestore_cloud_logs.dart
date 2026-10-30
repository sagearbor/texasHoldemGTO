/// [CloudLogs] on Cloud Firestore. Only constructed when the build has
/// FELT_CLOUD=true (cloud_config.dart); the default build never reaches it.
/// Paths and fields match firestore.rules, which tool/firestore_rules/
/// tests against the local emulator.
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
    required String projectId,
    required String apiKey,
    required String appId,
    required String senderId,
    String? emulator,
    String? authEmulator,
  }) async {
    final app = await Firebase.initializeApp(
      name: 'feltnotes-sync',
      options: FirebaseOptions(apiKey: apiKey, appId: appId, messagingSenderId: senderId, projectId: projectId),
    );
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

  @override
  Future<void> join(JoinTicket ticket, {required String deviceId, required String name}) async {
    final uid = await _uid();
    final night = _night(ticket.nightId);
    // The first phone online creates the night; the rules let a non-member
    // read a night only to learn it does not exist yet.
    var exists = false;
    try {
      exists = (await night.get().timeout(_timeout)).exists;
    } on FirebaseException {
      exists = true; // permission denied: it exists and we are not in yet
    }
    if (!exists) {
      try {
        await night.set({
          'secret': ticket.secret,
          'organizer': ticket.organizerName,
          'createdAt': FieldValue.serverTimestamp(),
        }).timeout(_timeout);
      } on FirebaseException {
        // Someone else created it a moment ago: fine, the member write
        // below checks the secret against theirs.
      }
    }
    await night.collection('members').doc(uid).set({
      'name': name.isEmpty ? '?' : (name.length > 24 ? name.substring(0, 24) : name),
      'deviceId': deviceId,
      'secret': ticket.secret,
      'joinedAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);
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
      'name': part.name.isEmpty ? '?' : (part.name.length > 24 ? part.name.substring(0, 24) : part.name),
      if (part.skewMs != null) 'skew': part.skewMs,
      'clientMs': clientMs,
      'updatedAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);
    if (!measure) return null;
    final snap = await ref.get(const GetOptions(source: Source.server)).timeout(_timeout);
    final ts = snap.data()?['updatedAt'];
    return ts is Timestamp ? ts.millisecondsSinceEpoch : null;
  }

  static LogPart? _part(Map<String, dynamic> d) {
    final dev = d['deviceId'];
    if (dev is! String) return null;
    return LogPart(
      deviceId: dev,
      part: (d['part'] as int?) ?? 0,
      name: (d['name'] as String?) ?? '',
      skewMs: d['skew'] as int?,
      events: [
        for (final s in (d['events'] as List? ?? const []).whereType<String>())
          if (NightEvent.decode(dev, s) case final e?) e
      ],
    );
  }

  @override
  Future<List<DeviceLog>> fetch(String nightId) async {
    await _uid();
    final q = await _night(nightId).collection('logs').get().timeout(_timeout);
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
