// A simulated night on the REAL project for looking at the TV page: an
// organizer and three phones play a hand every 20 s (with a blind clock),
// for FELT_DEMO_MIN minutes (default 5). Prints the TV link; deletes the
// night at the end.
//
//   FELT_E2E=1 FELT_DEMO_MIN=5 flutter test tool/e2e/demo_night_test.dart
//
// Open the printed link (or http://localhost:<port>/texasHoldemGTO/#/tv?c=CODE
// for a local `flutter build web`).

import 'dart:io';
import 'dart:math';

import 'package:felt_notes/homegame/blind_clock.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rest_cloud_logs.dart';

void main() {
  final enabled = Platform.environment['FELT_E2E'] == '1';
  final minutes = int.tryParse(Platform.environment['FELT_DEMO_MIN'] ?? '') ?? 5;

  test('demo night for the TV', () async {
    final names = ['Sage', 'John', 'Joe', 'Amy'];
    final clouds = [for (final n in names) RestCloudLogs(n)];
    final seats = [for (final n in [...names, 'Dee']) Seat(n, n)];
    final org = await LocalTableSync.organize(MemoryStore(),
        organizerName: 'Sage', selfPid: 'Sage', roster: seats, cloud: clouds[0]);
    try {
      stdout.writeln('TV: https://sagearbor.github.io/texasHoldemGTO/#/tv?c=${org.ticket.code}');
      stdout.writeln('code: ${org.ticket.code}');
      final players = [
        for (var i = 1; i < names.length; i++)
          await LocalTableSync.join(MemoryStore(), org.qrTicket(),
              name: names[i], claimPid: names[i], scannedAtMs: DateTime.now().millisecondsSinceEpoch,
              sharing: names[i] != 'Amy', cloud: clouds[i])
      ];
      final all = [org, ...players];
      final ups = [
        for (var i = 0; i < all.length; i++)
          Uploader(log: all[i].log, cloud: clouds[i], ticket: all[i].ticket, name: names[i])
      ];
      final clock = BlindClock(mode: ClockMode.tournament)..start(DateTime.now().millisecondsSinceEpoch);
      await org.appendEvent(EventKind.clock, {'j': clock.toJson()});
      final rng = Random(7);
      final deck = List.generate(52, (i) => i);
      final end = DateTime.now().add(Duration(minutes: minutes));
      var n = 0;
      while (DateTime.now().isBefore(end)) {
        n++;
        await org.startHand(n, seats[(n - 1) % seats.length].pid);
        deck.shuffle(rng);
        var k = 0;
        for (final p in players) {
          if (rng.nextDouble() < 0.6) await p.setCards([deck[k++], deck[k++]]);
          if (rng.nextDouble() < 0.4) await p.tap(rng.nextBool() ? PreAction.raise : PreAction.call);
        }
        for (final u in ups) {
          await u.drainOnce();
        }
        stdout.writeln('hand $n up');
        await Future<void>.delayed(const Duration(seconds: 20));
      }
      await org.endNight();
      for (final u in ups) {
        await u.drainOnce();
      }
    } finally {
      final r = await Process.run('firebase',
          ['firestore:delete', 'nights/${org.nightId}', '--recursive', '--force', '--project', project]);
      stdout.writeln('cleanup: exit ${r.exitCode}');
      for (final c in clouds) {
        try {
          await c.deleteUser();
        } catch (_) {}
        c.close();
      }
    }
  }, skip: enabled ? false : 'set FELT_E2E=1 (talks to the real project)', timeout: Timeout(Duration(minutes: minutes + 3)));
}
