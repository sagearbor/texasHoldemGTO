// End-to-end check against the REAL Firebase project (felt-notes-poker):
// an organizer and three phones (one private, one late) write a short
// night through the deployed rules, with the app's own uploader, merge and
// TV board code, while a TV reads. Checks what a member can and cannot
// see straight from Firestore. Deletes the test night (and its anonymous
// users) at the end.
//
//   FELT_E2E=1 flutter test tool/e2e/live_night_test.dart
//
// Takes about 3 minutes (the server's 2-minute card hold is real time).
// Needs the firebase CLI logged in as the project owner, for the cleanup
// (the rules let nobody delete a night).

import 'dart:io';

import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:felt_notes/sync/tv_board.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rest_cloud_logs.dart';

int now() => DateTime.now().millisecondsSinceEpoch;

void log(String s) => stdout.writeln('  · $s');

void main() {
  final enabled = Platform.environment['FELT_E2E'] == '1';

  test('a live night on felt-notes-poker: phones write, the TV reads, the rules hold', () async {
    final clouds = {
      for (final n in ['org', 'john', 'joe', 'kim', 'tv', 'stranger']) n: RestCloudLogs(n)
    };
    LocalTableSync? org;
    try {
      const sage = Seat('Sage', 'Sage'), john = Seat('John', 'John'), joe = Seat('Joe', 'Joe');
      org = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'E2E Sage', selfPid: 'Sage', roster: const [sage, john, joe], cloud: clouds['org']);
      final night = org.nightId;
      log('night $night');
      final johnP = await LocalTableSync.join(MemoryStore(), org.qrTicket(),
          name: 'John', claimPid: 'John', scannedAtMs: now(), cloud: clouds['john']);
      final joeP = await LocalTableSync.join(MemoryStore(), org.qrTicket(),
          name: 'Joe', claimPid: 'Joe', scannedAtMs: now(), sharing: false, cloud: clouds['joe']);
      Uploader up(LocalTableSync s, String c) =>
          Uploader(log: s.log, cloud: clouds[c]!, ticket: s.ticket, name: s.myName);
      final ups = [up(org, 'org'), up(johnP, 'john'), up(joeP, 'joe')];
      Future<void> uploadAll() async {
        for (final u in ups) {
          expect(await u.drainOnce(), isNot(UploadResult.failed), reason: '${u.name}: ${u.lastError}');
        }
      }

      // ---- hand 1: John raises with KK (cards entered), Joe (private) calls.
      await org.startHand(1, 'Sage');
      await johnP.setCards(parseCards('KsKh'));
      await johnP.tap(PreAction.raise);
      await joeP.tap(PreAction.call);
      // John's phone starts in the basement: it fails, then catches up.
      clouds['john']!.online = false;
      expect(await ups[1].drainOnce(), UploadResult.failed);
      clouds['john']!.online = true;
      await uploadAll();
      expect(org.log.meta['skew'], isA<int>(), reason: 'server clock measured');
      log('organizer skew vs server: ${org.log.meta['skew']} ms');

      // ---- the TV joins with the code only.
      final tv = clouds['tv']!;
      await tv.join(JoinTicket.parse(org.ticket.code)!, deviceId: 'TVTVTVTV2345', name: 'TV', create: false);
      Future<MergedNight> tvView([Map<String, List<int>> cards = const {}]) async {
        final logs = await tv.fetch(night);
        return mergeNight(organizerDeviceId: organizerOf(logs)!, logs: injectCards(logs, cards));
      }

      var b = buildTvBoard(await tvView(), nowMs: now());
      expect(b.handNow, 1);
      expect(b.rows.firstWhere((r) => r.name == 'Joe').status, TvStatus.private);
      expect(b.recent, isEmpty);

      // ---- what a member can read straight from Firestore.
      final joeDoc = (await tv.list('nights/$night/logs'))
          .firstWhere((d) => (d['name'] as String).endsWith('/${joeP.deviceId}_0'));
      final joeEvents = (joeDoc['fields']['events']['arrayValue']['values'] as List)
          .map((v) => NightEvent.decode(joeP.deviceId, v['stringValue'] as String)!.kind)
          .toSet();
      expect(joeEvents, {EventKind.join, EventKind.share}, reason: "private Joe's call never left his phone");
      await expectLater(tv.list('nights/$night/cards'), throwsA(isA<RestError>()), reason: 'cards cannot be listed');
      expect(await tv.getCards(night, johnP.deviceId, 1), isNull, reason: "John's hand 1 is still being played");
      final stranger = clouds['stranger']!;
      await expectLater(stranger.list('nights/$night/logs'), throwsA(isA<RestError>()), reason: 'non-members see nothing');
      await expectLater(
          stranger.join(JoinTicket(nightId: night, secret: 'WRNG2222', organizerName: ''),
              deviceId: 'STRANGER2345', name: 'x'),
          throwsA(isA<RestError>()),
          reason: 'a wrong secret cannot join');
      await expectLater(stranger.getCards(night, johnP.deviceId, 1), completion(isNull));

      // ---- hand 2: the next entry releases John's hand-1 cards.
      await org.startHand(2, 'John');
      await johnP.setCards(parseCards('7c2d'));
      await johnP.tap(PreAction.call);
      await uploadAll();
      final cardsAt = now();
      expect(await tv.getCards(night, johnP.deviceId, 1), isNull, reason: 'server hold: 2 minutes');
      expect(await clouds['john']!.getCards(night, johnP.deviceId, 1), isNull, reason: 'not even the owner reads early');
      b = buildTvBoard(await tvView(), nowMs: now());
      expect(b.rows.firstWhere((r) => r.name == 'John').hands, 1);
      expect(b.recent.single.cardsOpen, isFalse);

      // ---- duplicate upload after a lost reply: nothing doubles.
      await johnP.log.setMeta('up.parts', null);
      await johnP.log.setMeta('up.cards', null);
      await uploadAll();
      final johnLog = (await tv.fetch(night)).firstWhere((l) => l.deviceId == johnP.deviceId);
      expect(johnLog.events.length, johnP.localEvents.length);

      // ---- a late joiner, and Joe switches sharing on.
      final kim = await LocalTableSync.join(MemoryStore(), org.qrTicket(),
          name: 'Kim', scannedAtMs: now(), cloud: clouds['kim']);
      ups.add(up(kim, 'kim'));
      await org.setSeats(const [sage, john, joe, Seat('Kim', 'Kim')]);
      await joeP.setSharing(true);
      await org.startHand(3, 'Joe');
      await kim.tap(PreAction.raise);
      await org.startHand(4, 'Kim');
      await uploadAll();
      b = buildTvBoard(await tvView(), nowMs: now());
      expect(b.rows.firstWhere((r) => r.name == 'Joe').status, TvStatus.sharing);
      expect(b.rows.firstWhere((r) => r.name == 'Joe').vpip, 1, reason: "Joe's hand-1 call arrives once he shares");
      expect(b.rows.firstWhere((r) => r.name == 'Kim').pfr, 1);
      expect(b.rows.firstWhere((r) => r.name == 'Kim').hands, 1, reason: 'Kim counts from the hand she was seated');

      // ---- the organizer's phone dies: the TV keeps the last state.
      clouds['org']!.online = false;
      b = buildTvBoard(await tvView(), nowMs: now() + const TvOptions().staleMs + 60000);
      expect(b.staleAt(now() + const TvOptions().staleMs + 60000), isTrue);
      expect(b.finished, 3);

      // ---- after the server hold the TV gets John's KK (hand 1 is over).
      final wait = cardsAt + serverCardHoldMs + 5000 - now();
      log('waiting ${(wait / 1000).round()} s for the server card hold');
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      final fetch = CardFetcher(tv, night);
      expect(await fetch.fill(await tvView(), opts: const TvOptions(cardDelayMs: 0)), isTrue);
      b = buildTvBoard(await tvView(fetch.got), nowMs: now(), opts: const TvOptions(cardDelayMs: 0));
      final h1 = b.recent.firstWhere((h) => h.n == 1);
      expect(h1.plays.firstWhere((p) => p.name == 'John').cards, parseCards('KsKh'));
      expect(b.recent.firstWhere((h) => h.n == 2).plays.firstWhere((p) => p.name == 'John').cards, isNull,
          reason: "hand 2's cards were never released (no later entry, hold not over)");

      // ---- Joe switches off again: his log shrinks, his data is gone.
      await joeP.setSharing(false);
      clouds['org']!.online = true;
      await org.endNight();
      await uploadAll();
      b = buildTvBoard(await tvView(fetch.got), nowMs: now());
      expect(b.rows.firstWhere((r) => r.name == 'Joe').status, TvStatus.private);
      expect(b.ended, isTrue);

      final reads = clouds.values.fold(0, (a, c) => a + c.reads);
      final writes = clouds.values.fold(0, (a, c) => a + c.writes);
      final dels = clouds.values.fold(0, (a, c) => a + c.deletes);
      log('billed ops for this night: ~$reads reads, $writes writes, $dels deletes');
    } finally {
      if (org != null) {
        final r = await Process.run('firebase',
            ['firestore:delete', 'nights/${org.nightId}', '--recursive', '--force', '--project', project]);
        log('cleanup nights/${org.nightId}: exit ${r.exitCode}');
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      }
      for (final c in clouds.values) {
        try {
          await c.deleteUser();
        } catch (_) {}
        c.close();
      }
    }
  }, skip: enabled ? false : 'set FELT_E2E=1 (talks to the real project)', timeout: const Timeout(Duration(minutes: 6)));
}
