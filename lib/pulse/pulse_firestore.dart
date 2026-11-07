/// [PulseCloud] on Cloud Firestore, on the same app and anonymous sign-in
/// as the night's [FirestoreCloudLogs]. Paths and fields match
/// firestore.rules (tested in tool/firestore_rules/).
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../sync/cloud_logs.dart';
import '../sync/firestore_cloud_logs.dart';
import 'pulse_cloud.dart';
import 'pulse_profile.dart';

/// The Pulse side of a night's cloud: Firestore when the night is on
/// Firestore, the cloud itself when it already is one (tests), else null.
PulseCloud? pulseCloudFor(CloudLogs? c) {
  final o = debugPulseCloudFor;
  if (o != null) return o(c);
  if (c is PulseCloud) return c as PulseCloud;
  if (c is FirestoreCloudLogs) return FirestorePulseCloud(c.db, c.auth);
  return null;
}

/// Tests: replaces [pulseCloudFor].
PulseCloud? Function(CloudLogs? c)? debugPulseCloudFor;

class FirestorePulseCloud implements PulseCloud {
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  FirestorePulseCloud(this.db, this.auth);

  static const _timeout = Duration(seconds: 20);

  Future<String> _uid() async {
    final u = auth.currentUser ?? (await auth.signInAnonymously().timeout(_timeout)).user;
    if (u == null) throw StateError('no anonymous user');
    return u.uid;
  }

  DocumentReference<Map<String, dynamic>> _night(String id) => db.collection('nights').doc(id);

  static Timestamp _expiry() => Timestamp.fromDate(DateTime.now().add(const Duration(days: retentionDays)));

  @override
  Future<void> putMember(String nightId, String deviceId, PulseProfile p) async {
    final uid = await _uid();
    final name = p.name.trim().isEmpty ? '?' : p.name.trim();
    await _night(nightId).collection('pulse').doc(deviceId).set({
      'uid': uid,
      'deviceId': deviceId,
      'name': name.length > 24 ? name.substring(0, 24) : name,
      if (p.faceB64 != null) 'face': p.faceB64,
      if (p.song != null) 'song': p.song!.toJson(),
      'updatedAt': FieldValue.serverTimestamp(),
      'expireAt': _expiry(),
    }).timeout(_timeout);
  }

  @override
  Future<void> putChunk(String nightId, PulseChunk c) async {
    final uid = await _uid();
    await _night(nightId).collection('pulseData').doc(pulseDataId(c.deviceId, c.chunk)).set({
      'uid': uid,
      'deviceId': c.deviceId,
      'chunk': c.chunk,
      's': encodeChunk(c.chunk, c.samples),
      'updatedAt': FieldValue.serverTimestamp(),
      'expireAt': _expiry(),
    }).timeout(_timeout);
  }

  @override
  Future<void> deleteMine(String nightId, String deviceId) async {
    await _uid();
    final q = await _night(nightId)
        .collection('pulseData')
        .where('deviceId', isEqualTo: deviceId)
        .get(const GetOptions(source: Source.server))
        .timeout(_timeout);
    for (final d in q.docs) {
      await d.reference.delete().timeout(_timeout);
    }
    await _night(nightId).collection('pulse').doc(deviceId).delete().timeout(_timeout);
  }

  static PulseMember? _member(Map<String, dynamic> d) {
    final dev = d['deviceId'], name = d['name'], face = d['face'];
    if (dev is! String || name is! String) return null;
    return PulseMember(
        deviceId: dev, name: name, faceB64: face is String ? face : null, song: PulseSong.fromJson(d['song']));
  }

  static PulseChunk? _chunk(Map<String, dynamic> d) {
    final dev = d['deviceId'], chunk = d['chunk'], s = d['s'];
    if (dev is! String || chunk is! int || s is! List) return null;
    return PulseChunk(dev, chunk, decodeChunk(chunk, s));
  }

  @override
  Future<PulseNight> fetch(String nightId) async {
    await _uid();
    const src = GetOptions(source: Source.server);
    final m = await _night(nightId).collection('pulse').get(src).timeout(_timeout);
    final c = await _night(nightId).collection('pulseData').get(src).timeout(_timeout);
    return PulseNight.from([for (final d in m.docs) if (_member(d.data()) case final x?) x],
        [for (final d in c.docs) if (_chunk(d.data()) case final x?) x]);
  }

  @override
  Stream<PulseNight> watch(String nightId) async* {
    await _uid();
    var members = <PulseMember>[];
    var chunks = <PulseChunk>[];
    final out = StreamController<PulseNight>();
    void emit() => out.add(PulseNight.from(members, chunks));
    final a = _night(nightId).collection('pulse').snapshots().listen((q) {
      members = [for (final d in q.docs) if (_member(d.data()) case final x?) x];
      emit();
    }, onError: out.addError);
    final b = _night(nightId).collection('pulseData').snapshots().listen((q) {
      chunks = [for (final d in q.docs) if (_chunk(d.data()) case final x?) x];
      emit();
    }, onError: out.addError);
    out.onCancel = () {
      a.cancel();
      b.cancel();
    };
    yield* out.stream;
  }
}
