// A [CloudLogs] over the Firestore REST API with its own anonymous
// sign-in, so a test can play several phones and a TV at once against the
// real project, through the same rules the apps hit. Same paths and fields
// as lib/sync/firestore_cloud_logs.dart. Test tooling only (dart:io).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart';

const webApiKey = 'AIzaSyDNBvjDiJW_2hf7KoftFMOCl75b07QDsdY';
const project = 'felt-notes-poker';
const _docs = 'projects/$project/databases/(default)/documents';
const _base = 'https://firestore.googleapis.com/v1';

class RestError implements Exception {
  final int status;
  final String body;
  RestError(this.status, this.body);
  bool get denied => status == 403;
  @override
  String toString() => 'RestError($status: ${body.length > 200 ? body.substring(0, 200) : body})';
}

class RestCloudLogs implements CloudLogs {
  final String label;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  String? _token;
  String? uid;

  /// Simulate the basement: every call fails while false.
  bool online = true;

  /// Billed operations as Firestore counts them (rules lookups included).
  int reads = 0, writes = 0, deletes = 0;

  RestCloudLogs(this.label);

  Future<Map<String, dynamic>> _call(String method, String url, {Object? body, bool auth = true}) async {
    if (!online) throw StateError('$label offline');
    final req = await _http.openUrl(method, Uri.parse(url));
    req.headers.contentType = ContentType.json;
    if (auth) req.headers.set('Authorization', 'Bearer ${await _idToken()}');
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 300) throw RestError(res.statusCode, text);
    return text.isEmpty ? {} : (jsonDecode(text) as Map).cast<String, dynamic>();
  }

  Future<String> _idToken() async {
    if (_token != null) return _token!;
    final r = await _call('POST', 'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$webApiKey',
        body: {'returnSecureToken': true}, auth: false);
    _token = r['idToken'] as String;
    uid = r['localId'] as String;
    return _token!;
  }

  /// Removes this anonymous user (test cleanup).
  Future<void> deleteUser() async {
    if (_token == null) return;
    await _call('POST', 'https://identitytoolkit.googleapis.com/v1/accounts:delete?key=$webApiKey',
        body: {'idToken': _token}, auth: false);
  }

  // ---------------------------------------------------------------- values

  static Map<String, dynamic> _v(Object? x) => switch (x) {
        null => {'nullValue': null},
        final String s => {'stringValue': s},
        final int i => {'integerValue': '$i'},
        final bool b => {'booleanValue': b},
        final DateTime d => {'timestampValue': d.toUtc().toIso8601String()},
        final List l => {
            'arrayValue': {'values': [for (final e in l) _v(e)]}
          },
        _ => throw ArgumentError('$x'),
      };

  static Object? _unv(Map<String, dynamic> v) {
    if (v.containsKey('stringValue')) return v['stringValue'];
    if (v.containsKey('integerValue')) return int.parse(v['integerValue'] as String);
    if (v.containsKey('booleanValue')) return v['booleanValue'];
    if (v.containsKey('timestampValue')) return DateTime.parse(v['timestampValue'] as String);
    if (v.containsKey('arrayValue')) {
      return [for (final e in (v['arrayValue']['values'] as List? ?? const [])) _unv((e as Map).cast())];
    }
    return null;
  }

  static Map<String, Object?> _fields(Map<String, dynamic> doc) => {
        for (final e in ((doc['fields'] as Map?) ?? const {}).entries) e.key as String: _unv((e.value as Map).cast())
      };

  DateTime _expiry() => DateTime.now().add(const Duration(days: retentionDays));

  /// One write with server timestamps in [serverTime]; returns the server
  /// time of the first transform.
  Future<int?> _set(String path, Map<String, Object?> fields, {List<String> serverTime = const []}) async {
    final r = await _call('POST', '$_base/$_docs:commit', body: {
      'writes': [
        {
          'update': {
            'name': '$_docs/$path',
            'fields': {for (final e in fields.entries) e.key: _v(e.value)},
          },
          if (serverTime.isNotEmpty)
            'updateTransforms': [
              for (final f in serverTime) {'fieldPath': f, 'setToServerValue': 'REQUEST_TIME'}
            ],
        }
      ]
    });
    writes++;
    final tr = ((r['writeResults'] as List?)?.first as Map?)?['transformResults'] as List?;
    final ts = tr == null || tr.isEmpty ? null : (tr.first as Map)['timestampValue'] as String?;
    return ts == null ? null : DateTime.parse(ts).millisecondsSinceEpoch;
  }

  Future<void> _delete(String path) async {
    await _call('POST', '$_base/$_docs:commit', body: {
      'writes': [
        {'delete': '$_docs/$path'}
      ]
    });
    deletes++;
  }

  /// A raw document read (null when missing); throws RestError(403) when
  /// the rules refuse.
  Future<Map<String, Object?>?> getDoc(String path) async {
    try {
      reads++;
      return _fields(await _call('GET', '$_base/$_docs/$path'));
    } on RestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// A raw collection listing; throws RestError(403) when refused.
  Future<List<Map<String, dynamic>>> list(String path) async {
    final r = await _call('GET', '$_base/$_docs/$path?pageSize=300');
    final docs = [for (final d in (r['documents'] as List? ?? const [])) (d as Map).cast<String, dynamic>()];
    reads += docs.isEmpty ? 1 : docs.length;
    return docs;
  }

  // ------------------------------------------------------------ CloudLogs

  @override
  Future<void> join(JoinTicket ticket, {required String deviceId, required String name}) async {
    await _idToken();
    var exists = false;
    try {
      exists = await getDoc('nights/${ticket.nightId}') != null;
    } on RestError catch (e) {
      if (!e.denied) rethrow;
      exists = true;
    }
    if (!exists) {
      try {
        await _set('nights/${ticket.nightId}',
            {'secret': ticket.secret, 'organizer': ticket.organizerName, 'expireAt': _expiry()},
            serverTime: ['createdAt']);
      } on RestError catch (e) {
        if (!e.denied) rethrow;
      }
    }
    await _set('nights/${ticket.nightId}/members/$uid',
        {'name': name.isEmpty ? '?' : name, 'deviceId': deviceId, 'secret': ticket.secret, 'expireAt': _expiry()},
        serverTime: ['joinedAt']);
    reads++; // the rules' get() of the night
  }

  @override
  Future<int?> putPart(String nightId, LogPart part, {required int clientMs, bool measure = false}) async {
    await _idToken();
    reads++; // the rules' get() of the member doc
    return _set(
        'nights/$nightId/logs/${part.docId}',
        {
          'uid': uid,
          'deviceId': part.deviceId,
          'part': part.part,
          'count': part.events.length,
          'events': [for (final e in part.events) e.encode()],
          'name': part.name.isEmpty ? '?' : part.name,
          if (part.skewMs != null) 'skew': part.skewMs,
          'clientMs': clientMs,
          'expireAt': _expiry(),
        },
        serverTime: ['updatedAt']);
  }

  @override
  Future<void> deletePart(String nightId, String deviceId, int part) async {
    reads++;
    await _delete('nights/$nightId/logs/${deviceId}_$part');
  }

  @override
  Future<void> putCards(String nightId, String deviceId, int entry, List<int> cards) async {
    await _idToken();
    reads++;
    await _set(
        'nights/$nightId/cards/${cardDocId(deviceId, entry)}',
        {'uid': uid, 'deviceId': deviceId, 'e': entry, 'c': cards, 'expireAt': _expiry()},
        serverTime: ['at']);
  }

  @override
  Future<void> deleteCards(String nightId, String deviceId, int entry) async {
    reads++;
    await _delete('nights/$nightId/cards/${cardDocId(deviceId, entry)}');
  }

  @override
  Future<List<int>?> getCards(String nightId, String deviceId, int entry) async {
    try {
      final d = await getDoc('nights/$nightId/cards/${cardDocId(deviceId, entry)}');
      final c = d?['c'];
      return c is List && c.length == 2 ? c.cast<int>() : null;
    } on RestError catch (e) {
      if (e.denied) return null;
      rethrow;
    }
  }

  static LogPart? _part(Map<String, dynamic> doc) {
    final d = _fields(doc);
    final dev = d['deviceId'];
    if (dev is! String) return null;
    final at = d['updatedAt'];
    return LogPart(
      deviceId: dev,
      part: (d['part'] as int?) ?? 0,
      name: (d['name'] as String?) ?? '',
      skewMs: d['skew'] as int?,
      uploadedAtMs: at is DateTime ? at.millisecondsSinceEpoch : null,
      events: [
        for (final s in (d['events'] as List? ?? const []).whereType<String>())
          if (NightEvent.decode(dev, s) case final e?) e
      ],
    );
  }

  @override
  Future<List<DeviceLog>> fetch(String nightId) async =>
      logsFromParts([for (final d in await list('nights/$nightId/logs')) if (_part(d) case final p?) p]);

  /// Polling stand-in for a snapshot listener (the REST API has none).
  @override
  Stream<List<DeviceLog>> watch(String nightId) async* {
    while (true) {
      yield await fetch(nightId);
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  void close() => _http.close(force: true);
}
