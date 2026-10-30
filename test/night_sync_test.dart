// Join tickets, the durable local log, the one-tap player API and the
// uploader (offline first, retry, idempotent), against the fake cloud.

import 'dart:math';

import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:felt_notes/sync/tv_board.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime(2026, 10, 30, 19).millisecondsSinceEpoch;

/// A clock tests move by hand.
class Clock {
  int ms;
  Clock(this.ms);
  int call() => ms;
  void advance(int d) => ms += d;
}

const sage = Seat('p1', 'Sage'), john = Seat('p2', 'John'), joe = Seat('p3', 'Joe');

void main() {
  group('join ticket', () {
    test('QR payload round trip with clock and roster', () {
      const t = JoinTicket(
        nightId: 'ABCD2345',
        secret: 'WXYZ6789',
        organizerName: 'Sage & co',
        organizerMs: 1793404800123,
        roster: [Seat('p1', 'Sage'), Seat('p2', 'John ~ the, great')],
      );
      final back = JoinTicket.parse(t.encode())!;
      expect(back.nightId, 'ABCD2345');
      expect(back.secret, 'WXYZ6789');
      expect(back.organizerName, 'Sage & co');
      expect(back.organizerMs, 1793404800123);
      expect(back.roster.map((s) => s.pid), ['p1', 'p2']);
      expect(back.roster[1].name, 'John - the  great');
      expect(t.encode().length, lessThan(200)); // a small, easy-to-scan QR
    });

    test('typed / pasted codes, with spaces and lower case', () {
      final t = JoinTicket.parse(' abcd 2345 - wxyz 6789 ')!;
      expect(t.code, 'ABCD2345-WXYZ6789');
      expect(t.organizerMs, isNull);
      expect(clockOffsetFrom(t, t0), isNull);
    });

    test('rejects junk and look-alike characters', () {
      expect(JoinTicket.parse(''), isNull);
      expect(JoinTicket.parse('https://example.com'), isNull);
      expect(JoinTicket.parse('ABCD2345-WXYZ678'), isNull);
      expect(JoinTicket.parse('ABCD2345-WXYZ6780'), isNull); // 0 is not in the alphabet
      expect(JoinTicket.parse('feltnotes:join?t=ABC&s=WXYZ6789'), isNull);
    });

    test('offset = organizer clock - scanning clock', () {
      final t = const JoinTicket(nightId: 'ABCD2345', secret: 'WXYZ6789', organizerName: 'S').withClock(t0);
      expect(clockOffsetFrom(t, t0 - 90000), 90000);
    });
  });

  group('event log', () {
    test('survives a restart; seqs keep counting; ids are deviceId_seq', () async {
      final store = MemoryStore();
      final dev = await deviceIdFor(store, rng: Random(1));
      expect(isCode(dev, deviceIdLength), isTrue);
      expect(await deviceIdFor(store), dev);
      final log = await EventLog.open(store, 'ABCD2345', dev);
      await log.append(EventKind.join, t0, {'name': 'John'});
      await log.append(EventKind.play, t0 + 1, {'e': 1, 'a': 'call'});
      final again = await EventLog.open(store, 'ABCD2345', dev);
      expect(again.events.length, 2);
      expect(again.events.last.id, '${dev}_2');
      expect(again.events.last.data['a'], 'call');
      await again.append(EventKind.leave, t0 + 2);
      expect(again.lastSeq, 3);
      expect(storedNights(store), ['ABCD2345']);
    });

    test('unknown kinds from a newer app are skipped, not fatal', () {
      expect(NightEvent.decode('D', '{"s":1,"k":"teleport","t":5}'), isNull);
      expect(NightEvent.decode('D', 'not json'), isNull);
    });
  });

  group('player API', () {
    late MemoryStore store;
    late Clock clock;
    late LocalTableSync org;

    setUp(() async {
      store = MemoryStore();
      clock = Clock(t0);
      org = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'Sage', selfPid: 'p1', roster: const [sage, john, joe], now: clock.call, rng: Random(5));
    });

    Future<LocalTableSync> player({int skew = 0}) => LocalTableSync.join(
          store,
          org.qrTicket(),
          name: 'John',
          claimPid: 'p2',
          scannedAtMs: clock.ms - skew,
          now: () => clock.ms - skew,
        );

    test('joining records the clock offset and the claim', () async {
      final p = await player(skew: 42000);
      final j = p.localEvents.first;
      expect(j.kind, EventKind.join);
      expect(p.localEvents[1].kind, EventKind.share);
      expect(p.sharing, isTrue); // the default: on
      expect(j.data['offset'], 42000);
      expect(j.data['claim'], 'p2');
      expect(p.ticket.roster.length, 3);
      expect(() => p.startHand(1, 'p1'), throwsStateError);
    });

    test('second tap within 10 s corrects; later it is a new hand', () async {
      final p = await player();
      await p.tap(PreAction.call);
      clock.advance(4000);
      await p.tap(PreAction.raise);
      clock.advance(90000);
      await p.tap(PreAction.call);
      final es = [for (final e in p.localEvents) if (e.kind == EventKind.play) e.data['e']];
      expect(es, [1, 1, 2]);
    });

    test('cards then a tap within 3 min are one entry; undo withdraws it', () async {
      final p = await player();
      await p.setCards(parseCards('AsKd'));
      clock.advance(60000);
      await p.tap(PreAction.raise, facing: Facing.unopened);
      final plays = p.localEvents.where((e) => e.data.containsKey('e')).map((e) => e.data['e']);
      expect(plays, [1, 1]);
      await p.undoLast();
      expect(p.localEvents.last.kind, EventKind.undo);
      clock.advance(5000);
      await p.tap(PreAction.call);
      expect(p.localEvents.last.data['e'], 2);
    });

    test('resume reopens the night with role and ticket', () async {
      final p = await player();
      await p.tap(PreAction.call);
      final r = (await LocalTableSync.resume(store, p.nightId, now: clock.call))!;
      expect(r.role, NightRole.player);
      expect(r.ticket.nightId, org.nightId);
      expect(r.localEvents.length, 3); // join, share, play
    });

    test('nextDealer walks clockwise and wraps', () {
      expect(nextDealer(const [sage, john, joe], 'p1'), 'p2');
      expect(nextDealer(const [sage, john, joe], 'p3'), 'p1');
      expect(nextDealer(const [sage, john, joe], 'gone'), 'p1');
      expect(nextDealer(const [], 'p1'), isNull);
    });
  });

  group('uploader', () {
    late Clock clock;
    late FakeCloudLogs cloud;

    setUp(() {
      clock = Clock(t0);
      cloud = FakeCloudLogs(clock: clock.call, serverOffsetMs: 3000);
    });

    test('offline: fails and backs off; online later: everything arrives once', () async {
      final org = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'Sage', selfPid: 'p1', roster: const [sage, john], now: clock.call, cloud: cloud);
      await org.startHand(1, 'p1');
      final up = Uploader(log: org.log, cloud: cloud, ticket: org.ticket, name: 'Sage', now: clock.call);
      cloud.online = false;
      expect(await up.drainOnce(), UploadResult.failed);
      // The retry loop waits ~5 s, ~10 s, ~20 s ... (with +-20 % jitter).
      expect(up.backoff.next().inMilliseconds, inInclusiveRange(4000, 6000));
      expect(up.backoff.next().inMilliseconds, inInclusiveRange(8000, 12000));
      for (var i = 0; i < 20; i++) {
        up.backoff.next();
      }
      expect(up.backoff.next().inSeconds, inInclusiveRange(48, 72)); // capped at a minute
      cloud.online = true;
      expect(await up.drainOnce(), UploadResult.uploaded);
      expect(up.backoff.failures, 0);
      // The skew was measured on the first write and resent in the same drain.
      expect(up.pending, isFalse);
      expect(await up.drainOnce(), UploadResult.nothing);
      final logs = await cloud.fetch(org.nightId);
      expect(logs.single.events.length, org.localEvents.length);
      expect(logs.single.serverSkewMs, 3000);
      expect(org.log.meta['skew'], 3000);
    });

    test('sharing off: no taps or cards leave the phone; on again: they all go', () async {
      final org = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'Sage', selfPid: 'p1', now: clock.call, cloud: cloud);
      final p = await LocalTableSync.join(MemoryStore(), org.qrTicket(),
          name: 'John', scannedAtMs: clock.ms, sharing: false, now: clock.call, cloud: cloud);
      await p.setCards(parseCards('AsKd'));
      await p.tap(PreAction.raise);
      final up = Uploader(log: p.log, cloud: cloud, ticket: p.ticket, name: 'John', now: clock.call);
      await up.drainOnce();
      List<EventKind> kinds() => [for (final e in cloud.parts[org.nightId]!.values.single.events) e.kind];
      expect(kinds(), [EventKind.join, EventKind.share]); // name + "private", nothing else
      clock.advance(cardHoldMs);
      await up.drainOnce();
      expect(cloud.cards[org.nightId], isNull);
      await p.setSharing(true);
      expect(up.pending, isTrue);
      await up.drainOnce();
      expect(kinds(), contains(EventKind.play));
      // The log only ever says "had cards"; the cards are a separate document.
      final stub = cloud.parts[org.nightId]!.values.single.events.firstWhere((e) => e.kind == EventKind.cards);
      expect(stub.data, {'e': 1});
      expect(cloud.cards[org.nightId]![cardDocId(p.deviceId, 1)]!.$1, parseCards('AsKd'));
      // Off again: the part shrinks (delete + write) and the cards go.
      await p.setSharing(false);
      await up.drainOnce();
      expect(kinds(), isNot(contains(EventKind.play)));
      expect(kinds().last, EventKind.share);
      expect(cloud.cards[org.nightId], isEmpty);
      expect(up.pending, isFalse);
      final m = mergeNight(organizerDeviceId: org.deviceId, logs: await cloud.fetch(org.nightId));
      expect(m.devices.firstWhere((d) => d.deviceId == p.deviceId).private, isTrue);
    });

    test('cards wait until the hand is over: a later entry, or the hold time', () async {
      final org = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'Sage', selfPid: 'p1', now: clock.call, cloud: cloud);
      final p = await LocalTableSync.join(MemoryStore(), org.qrTicket(),
          name: 'John', scannedAtMs: clock.ms, now: clock.call, cloud: cloud);
      final up = Uploader(log: p.log, cloud: cloud, ticket: p.ticket, name: 'John', now: clock.call);
      await p.setCards(parseCards('QsQd'));
      await p.tap(PreAction.raise);
      await up.drainOnce();
      Map<String, (List<int>, int)> docs() => cloud.cards[org.nightId] ?? {};
      expect(docs(), isEmpty); // the hand may still be going
      expect(up.holdingCards, isTrue);
      expect(up.nextCardRelease, clock.ms + cardHoldMs);
      clock.advance(90000);
      await p.setCards(parseCards('7c2d')); // the next hand: the first one is over
      await up.drainOnce();
      expect(docs().keys, [cardDocId(p.deviceId, 1)]);
      clock.advance(cardHoldMs);
      await up.drainOnce();
      expect(docs().length, 2); // the hold ran out
      expect(up.holdingCards, isFalse);
      // The server holds a fresh card document back for 2 minutes.
      expect(await cloud.getCards(org.nightId, p.deviceId, 2), isNull);
      clock.advance(serverCardHoldMs);
      expect(await cloud.getCards(org.nightId, p.deviceId, 2), parseCards('7c2d'));
      // Undo withdraws an entry's cards from the cloud too.
      await p.undoLast();
      await up.drainOnce();
      expect(docs().length, 1);
    });

    test('a lost reply or a crash between writes converges, never duplicates', () async {
      final org = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'Sage', selfPid: 'p1', roster: const [sage, john], now: clock.call, cloud: cloud);
      final up = Uploader(log: org.log, cloud: cloud, ticket: org.ticket, name: 'Sage', now: clock.call);
      await org.startHand(1, 'p1');
      await up.drainOnce();
      // The server took the write but the phone never heard back.
      await org.log.setMeta('up.parts', null);
      await org.startHand(2, 'p2');
      expect(await up.drainOnce(), UploadResult.uploaded);
      expect(await up.drainOnce(), UploadResult.nothing);
      final logs = await cloud.fetch(org.nightId);
      expect(logs.single.events.length, org.localEvents.length);
      expect(mergeNight(organizerDeviceId: org.deviceId, logs: logs).hands.length, 2);
    });

    test('a long night splits into parts; re-uploads are idempotent', () async {
      final org = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'Sage', selfPid: 'p1', roster: const [sage, john], now: clock.call, cloud: cloud);
      final up = Uploader(log: org.log, cloud: cloud, ticket: org.ticket, name: 'Sage', now: clock.call);
      for (var n = 1; n <= 450; n++) {
        clock.advance(60000);
        await org.startHand(n, n.isOdd ? 'p1' : 'p2');
        if (n == 200) {
          await up.drainOnce();
          await up.drainOnce();
        }
      }
      await up.drainOnce();
      final docs = cloud.parts[org.nightId]!;
      expect(docs.keys.toSet(), {'${org.deviceId}_0', '${org.deviceId}_1'});
      expect(docs['${org.deviceId}_0']!.events.length, partSize);
      // Forget what was uploaded: the whole log goes up again, nothing doubles.
      await org.log.setMeta('up.parts', null);
      await up.drainOnce();
      final logs = await cloud.fetch(org.nightId);
      final m = mergeNight(organizerDeviceId: org.deviceId, logs: [...logs, ...logs]);
      expect(m.hands.length, 450);
    });

    test('the fake cloud refuses writes from a phone that never joined', () async {
      expect(
        () => cloud.putPart('ABCD2345', const LogPart(deviceId: 'X', part: 0, events: [], name: 'x'), clientMs: 0),
        throwsStateError,
      );
    });

    test('end to end: a basement night, phones upload at different times on the way home', () async {
      final org = await LocalTableSync.organize(MemoryStore(),
          organizerName: 'Sage', selfPid: 'p1', roster: const [sage, john, joe], now: clock.call, cloud: cloud);
      // John's phone is 2 minutes fast, Joe's 1 minute slow.
      final john_ = await LocalTableSync.join(MemoryStore(), org.qrTicket(),
          name: 'John', claimPid: 'p2', scannedAtMs: clock.ms + 120000, now: () => clock.ms + 120000, cloud: cloud);
      final joe_ = await LocalTableSync.join(MemoryStore(), org.qrTicket(),
          name: 'Joe', claimPid: 'p3', scannedAtMs: clock.ms - 60000, now: () => clock.ms - 60000, cloud: cloud);
      cloud.online = false; // the basement
      for (var n = 1; n <= 12; n++) {
        await org.startHand(n, const ['p1', 'p2', 'p3'][(n - 1) % 3]);
        clock.advance(40000);
        if (n == 3) {
          await john_.setCards(parseCards('KsKh'));
          await john_.tap(PreAction.raise);
          await joe_.setCards(parseCards('AcAd'));
          await joe_.tap(PreAction.raise);
        }
        if (n == 7) await john_.tap(PreAction.call);
        clock.advance(80000);
      }
      await joe_.leave();
      await org.endNight();
      final ups = [
        for (final s in [org, john_, joe_]) Uploader(log: s.log, cloud: cloud, ticket: s.ticket, name: s.myName, now: clock.call)
      ];
      for (final u in ups) {
        expect(await u.drainOnce(), UploadResult.failed);
      }
      // Joe gets signal first, then the organizer, then John next morning.
      cloud.online = true;
      await ups[2].drainOnce();
      var m = mergeNight(organizerDeviceId: org.deviceId, logs: await cloud.fetch(org.nightId));
      expect(m.hands, isEmpty); // no organizer timeline yet
      await ups[0].drainOnce();
      m = mergeNight(organizerDeviceId: org.deviceId, logs: await cloud.fetch(org.nightId));
      expect(m.hands.length, 12);
      expect(m.hands[2].players['p3']!.action, PreAction.raise);
      expect(m.hands[2].players.containsKey('p2'), isFalse); // John not in yet
      clock.advance(10 * 3600000);
      await ups[1].drainOnce();
      m = mergeNight(organizerDeviceId: org.deviceId, logs: await cloud.fetch(org.nightId));
      expect(m.hands[2].players['p2']!.action, PreAction.raise);
      expect(m.hands[6].players['p2']!.action, PreAction.call);
      expect(m.hands[6].players['p3']!.inferred, isTrue);
      expect(dramaLines(m), isEmpty); // no card values in the logs
      // The card documents, once the server's hold is over.
      clock.advance(serverCardHoldMs);
      final fetcher = CardFetcher(cloud, org.nightId, now: clock.call);
      expect(await fetcher.fill(m), isTrue);
      m = mergeNight(
          organizerDeviceId: org.deviceId, logs: injectCards(await cloud.fetch(org.nightId), fetcher.got));
      expect(dramaLines(m).single.text, startsWith('Cooler · Joe AA vs John KK'));
      // The organizer's own phone merges its local log with the cloud.
      org.addRemote(injectCards(await cloud.fetch(org.nightId), fetcher.got));
      expect(org.merged().hands[2].players['p2']!.cards, parseCards('KsKh'));
      // Billed operations for this 3-phone night stay tiny.
      expect(cloud.writes, lessThan(24));
    });
  });
}
