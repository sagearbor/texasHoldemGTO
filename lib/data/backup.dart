/// Backup / restore of everything Felt Notes keeps in shared_preferences.
///
/// A backup is a plain JSON file the user owns:
///
///     {"app": "felt_notes", "schema": 1, "exportedAt": "...",
///      "keys": {"home_sessions_v1": [...], "trainer_history_v1": [...], ...}}
///
/// Only the keys listed in [backupKeys] are ever exported or imported, so a
/// backup can never carry (or plant) anything else in storage. Values stored
/// as JSON strings are embedded decoded, so the file is readable and diffable.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../homegame/blind_clock.dart';
import '../homegame/home_game.dart';
import '../trainer/trainer_model.dart';
import '../ui/app_settings.dart';

const backupApp = 'felt_notes';
const backupSchema = 1;

/// Newest trainer answers kept (matches TrainerModel's own cap).
const _maxHistory = 3000;
const _maxSeeds = 500;

/// How a key is stored in shared_preferences.
enum PrefKind { json, string, integer, boolean, stringList }

/// Every Felt Notes storage key. Add new keys here or they are not backed up.
const backupKeys = <String, PrefKind>{
  keyTrainerHistory: PrefKind.json,
  keyTrainerSeeds: PrefKind.json,
  keyTrainerDifficulty: PrefKind.string,
  keyDaily: PrefKind.json,
  keyHomeSessions: PrefKind.json,
  keyDashboardDelay: PrefKind.integer,
  keyHomeBadges: PrefKind.stringList,
  keyBlindClock: PrefKind.json,
  keyChartsColorBlind: PrefKind.boolean,
  keySeenWelcome: PrefKind.boolean,
  keyTheme: PrefKind.string,
  keyCardStyle: PrefKind.string,
  keySolverDice: PrefKind.boolean,
  keyCurrency: PrefKind.string,
};

const keyTrainerHistory = 'trainer_history_v1';
const keyTrainerSeeds = 'trainer_sr_seeds_v1';
const keyTrainerDifficulty = 'trainer_difficulty_v1';
const keyDaily = 'daily_v1';
const keyHomeSessions = 'home_sessions_v1';
const keyDashboardDelay = 'dashboard_delay_min';
const keyHomeBadges = 'home_badges_seen';
const keyBlindClock = 'blind_clock_v1';
const keyChartsColorBlind = 'charts_color_blind_v1';
const keySeenWelcome = 'seen_welcome_v1';
const keyTheme = AppSettings.themeKey;
const keyCardStyle = AppSettings.cardStyleKey;
const keySolverDice = AppSettings.solverDiceKey;
const keyCurrency = AppSettings.currencyKey;

/// Thrown for anything that is not a valid Felt Notes backup. [message] is
/// short and safe to show to the user.
class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);
  @override
  String toString() => 'BackupFormatException: $message';
}

/// What a backup holds, for the confirm dialog and the post-restore snackbar.
class BackupSummary {
  final int nights;
  final int hands;
  final int drills;
  final int dailyDays;
  const BackupSummary(
      {this.nights = 0, this.hands = 0, this.drills = 0, this.dailyDays = 0});

  bool get isEmpty => nights == 0 && drills == 0 && dailyDays == 0;

  /// "12 game nights, 840 drills".
  String get label {
    String n(int c, String one, String many) => '$c ${c == 1 ? one : many}';
    final parts = [
      n(nights, 'game night', 'game nights'),
      n(drills, 'drill', 'drills'),
      if (dailyDays > 0) n(dailyDays, 'Daily 10 day', 'Daily 10 days'),
    ];
    return parts.join(', ');
  }

  @override
  String toString() => label;
}

// ------------------------------------------------------------------ export

/// Every Felt Notes key currently in [prefs], as a versioned backup map.
Map<String, dynamic> exportAll(SharedPreferences prefs, {DateTime? now}) {
  final keys = <String, dynamic>{};
  for (final MapEntry(key: k, value: kind) in backupKeys.entries) {
    if (!prefs.containsKey(k)) continue;
    try {
      final v = _read(prefs, k, kind);
      if (v != null) keys[k] = v;
    } catch (_) {
      // A corrupt value is skipped rather than failing the whole backup.
    }
  }
  return {
    'app': backupApp,
    'schema': backupSchema,
    'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'keys': keys,
  };
}

/// [exportAll] as pretty JSON text, ready to save as a file.
String exportJson(SharedPreferences prefs, {DateTime? now}) =>
    const JsonEncoder.withIndent(' ').convert(exportAll(prefs, now: now));

/// "felt-notes-backup-2026-10-27.json".
String backupFileName(DateTime d) =>
    'felt-notes-backup-${d.year}-${_two(d.month)}-${_two(d.day)}.json';

String _two(int n) => n.toString().padLeft(2, '0');

Object? _read(SharedPreferences prefs, String k, PrefKind kind) {
  switch (kind) {
    case PrefKind.json:
      final s = prefs.getString(k);
      return s == null ? null : jsonDecode(s);
    case PrefKind.string:
      return prefs.getString(k);
    case PrefKind.integer:
      return prefs.getInt(k);
    case PrefKind.boolean:
      return prefs.getBool(k);
    case PrefKind.stringList:
      return prefs.getStringList(k);
  }
}

// ------------------------------------------------------------------ parse

/// Decodes backup [text]; throws [BackupFormatException] if it is not JSON.
Map<String, dynamic> parseBackup(String text) {
  final Object? j;
  try {
    j = jsonDecode(text.trim());
  } on FormatException {
    throw const BackupFormatException('This is not a Felt Notes backup (not JSON).');
  }
  if (j is! Map<String, dynamic>) {
    throw const BackupFormatException('This is not a Felt Notes backup.');
  }
  return j;
}

/// Checks the envelope and every value, and returns the keys that would be
/// written (unknown keys dropped). Throws [BackupFormatException].
Map<String, dynamic> validateBackup(Map<String, dynamic> json) {
  if (json['app'] != backupApp) {
    throw const BackupFormatException('This file is not a Felt Notes backup.');
  }
  final schema = json['schema'];
  if (schema is! int) {
    throw const BackupFormatException('The backup has no schema version.');
  }
  if (schema > backupSchema) {
    throw const BackupFormatException(
        'This backup was made by a newer Felt Notes. Update the app first.');
  }
  if (schema < 1) {
    throw const BackupFormatException('Unknown backup schema version.');
  }
  final keys = json['keys'];
  if (keys is! Map<String, dynamic>) {
    throw const BackupFormatException('The backup has no data section.');
  }
  final out = <String, dynamic>{};
  for (final MapEntry(key: k, value: v) in keys.entries) {
    final kind = backupKeys[k];
    if (kind == null) continue; // Never write keys we don't own.
    try {
      out[k] = _validate(k, kind, v);
    } on BackupFormatException {
      rethrow;
    } catch (_) {
      throw BackupFormatException('The backup is damaged ($k).');
    }
  }
  return out;
}

/// Normalised value for [k] (typed, deep-checked); throws on a bad shape.
Object _validate(String k, PrefKind kind, Object? v) {
  switch (k) {
    case keyTrainerDifficulty:
      return Difficulty.values.byName(v as String).name;
    case keyTheme:
      return AppSettings.parseTheme(v)?.name ?? (throw const FormatException('theme'));
    case keyCardStyle:
      return AppSettings.parseCardStyle(v)?.name ??
          (throw const FormatException('card style'));
    case keyCurrency:
      return AppSettings.normalizeCurrency(v) ??
          (throw const FormatException('currency'));
    case keyDashboardDelay:
      final m = v as int;
      if (!dashboardDelays.contains(m)) throw const FormatException('delay');
      return m;
  }
  switch (kind) {
    case PrefKind.string:
      return v as String;
    case PrefKind.integer:
      return v as int;
    case PrefKind.boolean:
      return v as bool;
    case PrefKind.stringList:
      return [for (final s in v as List) s as String];
    case PrefKind.json:
      break;
  }
  switch (k) {
    case keyTrainerHistory:
      return [
        for (final a in v as List) Answer.fromJson(a as Map<String, dynamic>).toJson()
      ];
    case keyTrainerSeeds:
      return [
        for (final s in v as List)
          {
            's': (s as Map)['s'] as String,
            'h': s['h'] as int,
            't': s['t'] as int,
          }
      ];
    case keyHomeSessions:
      final list = v as List;
      // Round-tripping through the model proves the app can load it.
      for (final s in list) {
        final h = HomeSession.fromJson(s as Map<String, dynamic>);
        if (h.players.length < 2 ||
            h.heroSeat < 0 ||
            h.heroSeat >= h.players.length) {
          throw const FormatException('bad seats');
        }
        for (final hand in h.hands) {
          final c = hand.cards;
          if (c != null && (c.length != 2 || c.any((x) => x < 0 || x > 51))) {
            throw const FormatException('bad cards');
          }
        }
      }
      return list;
    case keyDaily:
      final m = v as Map<String, dynamic>;
      final r = m['r'] as Map<String, dynamic>? ?? {};
      return {
        'r': {
          for (final e in r.entries) '${int.parse(e.key)}': e.value as String
        },
        'best': m['best'] as int? ?? 0,
      };
    case keyBlindClock:
      BlindClock.fromJson((v as Map).cast<String, dynamic>());
      return v;
  }
  throw FormatException('unhandled $k');
}

/// Counts what [json] holds (validating it first).
BackupSummary summarizeBackup(Map<String, dynamic> json) =>
    _summarize(validateBackup(json));

BackupSummary _summarize(Map<String, dynamic> keys) {
  final sessions = keys[keyHomeSessions] as List? ?? const [];
  var hands = 0;
  for (final s in sessions) {
    hands += ((s as Map)['hands'] as List).length;
  }
  final daily = keys[keyDaily] as Map?;
  return BackupSummary(
    nights: sessions.length,
    hands: hands,
    drills: (keys[keyTrainerHistory] as List? ?? const []).length,
    dailyDays: ((daily?['r'] as Map?) ?? const {}).length,
  );
}

/// What is on this device now, in the same terms as a backup.
BackupSummary summarizeDevice(SharedPreferences prefs) {
  try {
    return summarizeBackup(exportAll(prefs));
  } catch (_) {
    return const BackupSummary();
  }
}

// ------------------------------------------------------------------ import

/// Writes a backup into [prefs] and returns what the device now holds.
///
/// Replace (default): the device ends up exactly as the backup; Felt Notes
/// keys missing from the backup are removed.
///
/// [merge]: keeps what is on the device and adds the backup's data. Game
/// nights are matched by session id (the copy with more hands wins);
/// trainer answers, seeds and Daily results are unioned without duplicates;
/// settings already set on this device are kept.
///
/// Everything is validated before anything is written, so a bad file never
/// leaves storage half-restored. Call the models' reload() afterwards.
Future<BackupSummary> importAll(
  Map<String, dynamic> json,
  SharedPreferences prefs, {
  bool merge = false,
}) async {
  final incoming = validateBackup(json);
  final Map<String, dynamic> target;
  if (merge) {
    final local = validateBackup(exportAll(prefs));
    target = mergeKeys(local, incoming);
  } else {
    target = incoming;
  }
  for (final MapEntry(key: k, value: kind) in backupKeys.entries) {
    if (!target.containsKey(k)) {
      if (!merge) await prefs.remove(k);
      continue;
    }
    final v = target[k];
    switch (kind) {
      case PrefKind.json:
        await prefs.setString(k, jsonEncode(v));
      case PrefKind.string:
        await prefs.setString(k, v as String);
      case PrefKind.integer:
        await prefs.setInt(k, v as int);
      case PrefKind.boolean:
        await prefs.setBool(k, v as bool);
      case PrefKind.stringList:
        await prefs.setStringList(k, (v as List).cast<String>());
    }
  }
  return _summarize(target);
}

/// Merges two validated key maps (see [importAll]).
Map<String, dynamic> mergeKeys(
    Map<String, dynamic> local, Map<String, dynamic> incoming) {
  final out = <String, dynamic>{...incoming, ...local};

  // Game nights: one per id; more hands wins, ties keep the device copy.
  final sessions = mergeSessions(
    (local[keyHomeSessions] as List?)?.cast<Map<String, dynamic>>() ?? const [],
    (incoming[keyHomeSessions] as List?)?.cast<Map<String, dynamic>>() ??
        const [],
  );
  if (sessions.isNotEmpty) out[keyHomeSessions] = sessions;

  final history = mergeHistory(
    (local[keyTrainerHistory] as List?)?.cast<Map<String, dynamic>>() ??
        const [],
    (incoming[keyTrainerHistory] as List?)?.cast<Map<String, dynamic>>() ??
        const [],
  );
  if (history.isNotEmpty) out[keyTrainerHistory] = history;

  final seeds = _unionByTime(
    (local[keyTrainerSeeds] as List?)?.cast<Map<String, dynamic>>() ?? const [],
    (incoming[keyTrainerSeeds] as List?)?.cast<Map<String, dynamic>>() ??
        const [],
    (m) => '${m['s']}|${m['h']}|${m['t']}',
    _maxSeeds,
  );
  if (seeds.isNotEmpty) out[keyTrainerSeeds] = seeds;

  final ld = local[keyDaily] as Map<String, dynamic>?;
  final id = incoming[keyDaily] as Map<String, dynamic>?;
  if (ld != null && id != null) {
    final r = <String, String>{
      ...(id['r'] as Map).cast<String, String>(),
    };
    (ld['r'] as Map).cast<String, String>().forEach((day, marks) {
      final other = r[day];
      if (other == null || marks.length >= other.length) r[day] = marks;
    });
    final lb = ld['best'] as int, ib = id['best'] as int;
    out[keyDaily] = {'r': r, 'best': lb > ib ? lb : ib};
  }

  final lBadges = local[keyHomeBadges] as List?;
  final iBadges = incoming[keyHomeBadges] as List?;
  if (lBadges != null && iBadges != null) {
    out[keyHomeBadges] = {...lBadges.cast<String>(), ...iBadges.cast<String>()}
        .toList();
  }
  return out;
}

/// Sessions from both lists, one per id, in start order.
List<Map<String, dynamic>> mergeSessions(
    List<Map<String, dynamic>> local, List<Map<String, dynamic>> incoming) {
  int handsOf(Map<String, dynamic> s) => (s['hands'] as List).length;
  final byId = <String, Map<String, dynamic>>{};
  for (final s in local) {
    byId[s['id'] as String] = s;
  }
  for (final s in incoming) {
    final id = s['id'] as String;
    final have = byId[id];
    if (have == null || handsOf(s) > handsOf(have)) byId[id] = s;
  }
  final out = byId.values.toList();
  // Stable: start time, then id.
  out.sort((a, b) {
    final d = (a['started'] as int).compareTo(b['started'] as int);
    return d != 0 ? d : (a['id'] as String).compareTo(b['id'] as String);
  });
  // Only the newest open night can be the active one; close older ones so a
  // merge never leaves two "live" games.
  var seenOpen = false;
  for (var i = out.length - 1; i >= 0; i--) {
    if (out[i]['closed'] == true) continue;
    if (seenOpen) out[i] = {...out[i], 'closed': true};
    seenOpen = true;
  }
  return out;
}

/// Trainer answers from both lists, deduped by (spotId, hand, ts), in time
/// order, newest [_maxHistory] kept.
List<Map<String, dynamic>> mergeHistory(
        List<Map<String, dynamic>> local, List<Map<String, dynamic>> incoming) =>
    _unionByTime(local, incoming, (m) => '${m['s']}|${m['h']}|${m['t']}',
        _maxHistory);

List<Map<String, dynamic>> _unionByTime(
  List<Map<String, dynamic>> a,
  List<Map<String, dynamic>> b,
  String Function(Map<String, dynamic>) key,
  int cap,
) {
  final seen = <String>{};
  final out = <Map<String, dynamic>>[
    for (final m in [...a, ...b])
      if (seen.add(key(m))) m
  ];
  final idx = List.generate(out.length, (i) => i)
    ..sort((x, y) {
      final d = (out[x]['t'] as int).compareTo(out[y]['t'] as int);
      return d != 0 ? d : x.compareTo(y);
    });
  final sorted = [for (final i in idx) out[i]];
  return sorted.length > cap ? sorted.sublist(sorted.length - cap) : sorted;
}
