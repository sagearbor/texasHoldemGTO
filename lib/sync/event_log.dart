/// The durable local log (the outbox). It is the source of truth on each
/// phone: the cloud copy is only ever rebuilt from it.
library;

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'night_events.dart';

/// The bit of persistence the log needs. [SharedPrefsStore] in the app,
/// [MemoryStore] in tests.
abstract class KeyValueStore {
  String? get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
  Iterable<String> keys();
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> data = {};
  @override
  String? get(String key) => data[key];
  @override
  Future<void> set(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
  @override
  Iterable<String> keys() => data.keys;
}

class SharedPrefsStore implements KeyValueStore {
  final SharedPreferences prefs;
  SharedPrefsStore(this.prefs);
  static Future<SharedPrefsStore> open() async => SharedPrefsStore(await SharedPreferences.getInstance());
  @override
  String? get(String key) => prefs.getString(key);
  @override
  Future<void> set(String key, String value) => prefs.setString(key, value);
  @override
  Future<void> remove(String key) => prefs.remove(key);
  @override
  Iterable<String> keys() => prefs.getKeys();
}

const _deviceKey = 'sync.deviceId';
String _logKey(String night) => 'sync.night.$night.log';
String _metaKey(String night) => 'sync.night.$night.meta';

/// This install's id, made once.
Future<String> deviceIdFor(KeyValueStore store, {Random? rng}) async {
  final have = store.get(_deviceKey);
  if (have != null && isCode(have, deviceIdLength)) return have;
  final id = randomCode(rng ?? Random.secure(), deviceIdLength);
  await store.set(_deviceKey, id);
  return id;
}

/// Night ids this phone has a log for (newest last by key order is not
/// guaranteed; callers sort by meta).
List<String> storedNights(KeyValueStore store) => [
      for (final k in store.keys())
        if (k.startsWith('sync.night.') && k.endsWith('.meta'))
          k.substring('sync.night.'.length, k.length - '.meta'.length)
    ];

/// One phone's append-only log for one night, plus small upload metadata.
class EventLog {
  final KeyValueStore _store;
  final String nightId;
  final String deviceId;
  final List<NightEvent> _events;

  /// Free-form metadata (ticket, role, upload watermark, server skew).
  final Map<String, Object?> meta;

  EventLog._(this._store, this.nightId, this.deviceId, this._events, this.meta);

  static Future<EventLog> open(KeyValueStore store, String nightId, String deviceId) async {
    final events = <NightEvent>[];
    final raw = store.get(_logKey(nightId));
    if (raw != null) {
      for (final s in (jsonDecode(raw) as List).cast<String>()) {
        final e = NightEvent.decode(deviceId, s);
        if (e != null) events.add(e);
      }
    }
    final m = store.get(_metaKey(nightId));
    final meta = m == null ? <String, Object?>{} : (jsonDecode(m) as Map).cast<String, Object?>();
    return EventLog._(store, nightId, deviceId, events, meta);
  }

  List<NightEvent> get events => List.unmodifiable(_events);
  int get lastSeq => _events.isEmpty ? 0 : _events.last.seq;

  /// Appends and persists before returning: once this completes the event
  /// survives the app being killed.
  Future<NightEvent> append(EventKind kind, int ms, [Map<String, Object?> data = const {}]) async {
    final e = NightEvent(deviceId: deviceId, seq: lastSeq + 1, kind: kind, ms: ms, data: data);
    _events.add(e);
    await _persist();
    return e;
  }

  Future<void> setMeta(String key, Object? value) async {
    if (value == null) {
      meta.remove(key);
    } else {
      meta[key] = value;
    }
    await _store.set(_metaKey(nightId), jsonEncode(meta));
  }

  Future<void> _persist() async {
    await _store.set(_logKey(nightId), jsonEncode([for (final e in _events) e.encode()]));
    if (_store.get(_metaKey(nightId)) == null) await _store.set(_metaKey(nightId), jsonEncode(meta));
  }

  /// Is card sharing on, per the latest share event.
  bool get sharing {
    for (final e in _events.reversed) {
      if (e.kind == EventKind.share) return e.data['on'] == true;
    }
    return false;
  }
}
