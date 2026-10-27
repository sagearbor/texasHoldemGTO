import 'dart:convert';

import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/data/backup.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/blind_clock.dart';
import 'package:felt_notes/homegame/blind_clock_controller.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> session(String id, int hands,
    {int started = 1000, bool closed = true, String name = 'Fri'}) {
  return HomeSession(
    id: id,
    name: name,
    started: started,
    players: ['me', 'Bob', 'Cy'],
    heroSeat: 0,
    buttonSeat: 1,
    closed: closed,
    buyIn: 20,
    hands: [
      for (var i = 0; i < hands; i++)
        LoggedHand(
          number: i + 1,
          cards: [i, i + 4],
          position: 'BTN',
          dealer: 'Bob',
          action: PreAction.raise,
          facing: Facing.unopened,
          ts: started + i,
          tag: i == 0 ? StoryTag.bluff : null,
          board: i == 0 ? [10, 20, 30] : null,
        ),
    ],
  ).toJson();
}

Map<String, dynamic> answer(String spot, int hand, int ts, {double f = 1}) =>
    Answer(spot, hand, 0, f, ts).toJson();

/// Every Felt Notes key, plus one foreign key that must never be exported.
Map<String, Object> fullStore() => {
      keyTrainerHistory: jsonEncode([
        answer('cash-rfi-BTN', 3, 100),
        answer('cash-rfi-CO', 7, 200, f: 0),
      ]),
      keyTrainerSeeds: jsonEncode([
        {'s': 'cash-rfi-UTG', 'h': 12, 't': 150}
      ]),
      keyTrainerDifficulty: 'expert',
      keyDaily: jsonEncode({
        'r': {'20380': 'GGYRGGGGGG', '20381': 'GY'},
        'best': 4,
      }),
      keyHomeSessions: jsonEncode([session('a', 3), session('b', 2, started: 2000)]),
      keyDashboardDelay: 5,
      keyHomeBadges: ['firstNight', 'tenHands'],
      keyBlindClock: jsonEncode(BlindClock().toJson()),
      keyChartsColorBlind: true,
      keySeenWelcome: true,
      'flutter.some_other_plugin': 'secret',
      'not_ours': 42,
    };

Map<String, dynamic> backupWith(Map<String, dynamic> keys,
        {Object app = 'felt_notes', Object schema = 1}) =>
    {'app': app, 'schema': schema, 'exportedAt': '2026-10-27T06:00:00Z', 'keys': keys};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('export', () {
    test('contains every Felt Notes key and nothing else', () async {
      SharedPreferences.setMockInitialValues(fullStore());
      final prefs = await SharedPreferences.getInstance();
      final b = exportAll(prefs, now: DateTime.utc(2026, 10, 27, 6));
      expect(b['app'], 'felt_notes');
      expect(b['schema'], 1);
      expect(b['exportedAt'], '2026-10-27T06:00:00.000Z');
      final keys = b['keys'] as Map<String, dynamic>;
      expect(keys.keys.toSet(), backupKeys.keys.toSet());
      expect(keys.containsKey('not_ours'), isFalse);
      // JSON values are embedded decoded, not as escaped strings.
      expect(keys[keyHomeSessions], isA<List>());
      expect(keys[keyDashboardDelay], 5);
      expect(keys[keyHomeBadges], ['firstNight', 'tenHands']);
    });

    test('skips missing and corrupt keys', () async {
      SharedPreferences.setMockInitialValues(
          {keyTrainerHistory: '{not json', keySeenWelcome: true});
      final prefs = await SharedPreferences.getInstance();
      final keys = exportAll(prefs)['keys'] as Map;
      expect(keys.keys, [keySeenWelcome]);
    });

    test('file name', () {
      expect(backupFileName(DateTime(2026, 3, 7)),
          'felt-notes-backup-2026-03-07.json');
    });
  });

  group('round trip', () {
    test('export -> wipe -> import restores identical storage', () async {
      final store = fullStore();
      SharedPreferences.setMockInitialValues(store);
      final prefs = await SharedPreferences.getInstance();
      final before = {for (final k in backupKeys.keys) k: prefs.get(k)};
      final text = exportJson(prefs);

      await prefs.clear();
      final summary = await importAll(parseBackup(text), prefs);

      final after = {for (final k in backupKeys.keys) k: prefs.get(k)};
      // JSON strings compare as decoded values (whitespace may differ).
      for (final k in backupKeys.keys) {
        final a = before[k], b = after[k];
        if (backupKeys[k] == PrefKind.json) {
          expect(jsonDecode(b as String), jsonDecode(a as String), reason: k);
        } else {
          expect(b, a, reason: k);
        }
      }
      expect(prefs.containsKey('not_ours'), isFalse);
      expect(summary.nights, 2);
      expect(summary.hands, 5);
      expect(summary.drills, 2);
      expect(summary.label, '2 game nights, 2 drills, 2 Daily 10 days');

      // A second export is the same backup.
      expect(exportAll(prefs, now: DateTime.utc(2026))['keys'],
          exportAll(prefs, now: DateTime.utc(2026))['keys']);
      expect(jsonDecode(exportJson(prefs))['keys'], jsonDecode(text)['keys']);
    });

    test('models load the restored data', () async {
      SharedPreferences.setMockInitialValues(fullStore());
      final prefs = await SharedPreferences.getInstance();
      final backup = exportAll(prefs);

      SharedPreferences.setMockInitialValues({keySeenWelcome: true});
      final lib = SpotLibrary(
          buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
      final t = TrainerModel(lib);
      final h = HomeGameModel(lib);
      await Future.wait([t.load(), h.load()]);
      expect(h.sessions, isEmpty);
      expect(t.history, isEmpty);

      final clock = BlindClockController(now: () => 0);
      await restoreBackup(backup, trainer: t, home: h, clock: clock);
      expect(h.sessions.map((s) => s.id), ['a', 'b']);
      expect(h.sessions.first.hands.first.tag, StoryTag.bluff);
      expect(h.dashboardDelayMinutes, 5);
      expect(t.history.length, 2);
      expect(t.difficulty, Difficulty.expert);
      expect(t.daily.results[20380], 'GGYRGGGGGG');
      expect(clock.loaded, isTrue);

      // Reloading twice does not duplicate anything.
      await restoreBackup(backup, trainer: t, home: h, clock: clock);
      expect(h.sessions.length, 2);
      expect(t.history.length, 2);
    });

    test('replace removes Felt Notes keys absent from the backup', () async {
      SharedPreferences.setMockInitialValues(fullStore());
      final prefs = await SharedPreferences.getInstance();
      await importAll(
          backupWith({
            keyHomeSessions: [session('z', 1)]
          }),
          prefs);
      expect(prefs.containsKey(keyTrainerHistory), isFalse);
      expect(prefs.containsKey(keyDashboardDelay), isFalse);
      expect(jsonDecode(prefs.getString(keyHomeSessions)!).length, 1);
      // Foreign keys are never touched.
      expect(prefs.get('not_ours'), 42);
    });
  });

  group('merge', () {
    test('sessions dedupe by id, the copy with more hands wins', () async {
      SharedPreferences.setMockInitialValues({
        keyHomeSessions: jsonEncode([
          session('a', 3, started: 1000),
          session('c', 4, started: 3000, closed: false, name: 'local'),
        ]),
        keyDashboardDelay: 30,
      });
      final prefs = await SharedPreferences.getInstance();
      final s = await importAll(
        backupWith({
          keyHomeSessions: [
            session('a', 7, started: 1000, name: 'longer'),
            session('b', 1, started: 2000),
            session('c', 2, started: 3000, closed: false, name: 'shorter'),
          ],
          keyDashboardDelay: 5,
        }),
        prefs,
        merge: true,
      );
      final out = (jsonDecode(prefs.getString(keyHomeSessions)!) as List)
          .cast<Map<String, dynamic>>();
      expect(out.map((e) => e['id']), ['a', 'b', 'c']);
      expect(out[0]['name'], 'longer');
      expect((out[0]['hands'] as List).length, 7);
      expect(out[2]['name'], 'local');
      expect(out[2]['closed'], isFalse);
      expect(s.nights, 3);
      expect(s.hands, 7 + 1 + 4);
      // The device's own setting is kept.
      expect(prefs.getInt(keyDashboardDelay), 30);
    });

    test('only the newest open night stays open', () {
      final out = mergeSessions([
        session('a', 1, started: 1, closed: false)
      ], [
        session('b', 1, started: 2, closed: false)
      ]);
      expect([for (final s in out) s['closed']], [true, false]);
    });

    test('trainer history dedupes by (spot, hand, ts)', () async {
      SharedPreferences.setMockInitialValues({
        keyTrainerHistory: jsonEncode([
          answer('x', 1, 10),
          answer('x', 2, 30),
        ]),
      });
      final prefs = await SharedPreferences.getInstance();
      final s = await importAll(
        backupWith({
          keyTrainerHistory: [
            answer('x', 1, 10), // duplicate
            answer('x', 1, 20), // same hand, other time: kept
            answer('y', 1, 10), // other spot: kept
          ],
          keyTrainerSeeds: [
            {'s': 'x', 'h': 1, 't': 5}
          ],
        }),
        prefs,
        merge: true,
      );
      final out = (jsonDecode(prefs.getString(keyTrainerHistory)!) as List)
          .cast<Map<String, dynamic>>();
      expect([for (final a in out) '${a['s']}${a['h']}@${a['t']}'],
          ['x1@10', 'y1@10', 'x1@20', 'x2@30']);
      expect(s.drills, 4);
      expect(prefs.getString(keyTrainerSeeds), isNotNull);
    });

    test('history merge keeps the newest 3000', () {
      final a = [for (var i = 0; i < 2000; i++) answer('x', 0, i)];
      final b = [for (var i = 1500; i < 3500; i++) answer('x', 0, i)];
      final out = mergeHistory(a, b);
      expect(out.length, 3000);
      expect(out.first['t'], 500);
      expect(out.last['t'], 3499);
    });

    test('daily results union, longer marks win, best is the max', () async {
      SharedPreferences.setMockInitialValues({
        keyDaily: jsonEncode({
          'r': {'1': 'GG', '2': 'GGGGGGGGGG'},
          'best': 3
        }),
        keyHomeBadges: ['a'],
      });
      final prefs = await SharedPreferences.getInstance();
      await importAll(
        backupWith({
          keyDaily: {
            'r': {'1': 'GGRY', '3': 'R'},
            'best': 7
          },
          keyHomeBadges: ['b', 'a'],
        }),
        prefs,
        merge: true,
      );
      final d = jsonDecode(prefs.getString(keyDaily)!);
      expect(d['r'], {'1': 'GGRY', '2': 'GGGGGGGGGG', '3': 'R'});
      expect(d['best'], 7);
      expect(prefs.getStringList(keyHomeBadges)!.toSet(), {'a', 'b'});
    });
  });

  group('rejects bad input', () {
    Future<void> rejects(Object input, String why) async {
      SharedPreferences.setMockInitialValues(fullStore());
      final prefs = await SharedPreferences.getInstance();
      final before = {for (final k in prefs.getKeys()) k: prefs.get(k)};
      await expectLater(
        () async {
          final j = input is String ? parseBackup(input) : input as Map<String, dynamic>;
          await importAll(j, prefs);
        },
        throwsA(isA<BackupFormatException>()),
        reason: why,
      );
      // Nothing was written.
      expect({for (final k in prefs.getKeys()) k: prefs.get(k)}, before,
          reason: why);
    }

    test('not JSON / not an object', () async {
      await rejects('hello', 'plain text');
      await rejects('[1,2]', 'a list');
      await rejects('', 'empty');
    });

    test('wrong app or schema', () async {
      await rejects(backupWith({}, app: 'other_app'), 'other app');
      await rejects(backupWith({}, schema: 2), 'newer schema');
      await rejects(backupWith({}, schema: 0), 'schema 0');
      await rejects(backupWith({}, schema: '1'), 'schema as string');
      await rejects({'app': 'felt_notes', 'schema': 1}, 'no keys');
    });

    test('malformed values', () async {
      await rejects(backupWith({keyTrainerHistory: 'nope'}), 'history string');
      await rejects(
          backupWith({
            keyTrainerHistory: [
              {'s': 'x', 'h': 'one', 'c': 0, 'f': 1, 't': 1}
            ]
          }),
          'history bad field');
      await rejects(
          backupWith({
            keyHomeSessions: [
              {'id': 'a'}
            ]
          }),
          'session missing fields');
      final badCards = session('a', 1);
      (badCards['hands'] as List)[0]['c'] = [99, 1];
      await rejects(backupWith({keyHomeSessions: [badCards]}), 'card 99');
      final badAction = session('a', 1);
      (badAction['hands'] as List)[0]['a'] = 9;
      await rejects(backupWith({keyHomeSessions: [badAction]}), 'action 9');
      await rejects(backupWith({keyDashboardDelay: '5'}), 'delay as string');
      await rejects(backupWith({keyHomeBadges: [1, 2]}), 'badges ints');
      await rejects(
          backupWith({
            keyDaily: {
              'r': {'today': 'G'}
            }
          }),
          'daily key not a day');
      await rejects(backupWith({keyBlindClock: 5}), 'clock not a map');
    });

    test('unknown keys are ignored, not written', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await importAll(
          backupWith({'evil_key': 'x', keySeenWelcome: true}), prefs);
      expect(prefs.getKeys(), {keySeenWelcome});
    });
  });
}
