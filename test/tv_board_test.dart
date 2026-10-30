// The table TV: what it may show and when (cards only after the hand is
// over plus the delay, private players, phones that never uploaded,
// staleness), the card fetcher against the fake cloud's server hold, and
// the TV page itself rendering live from a fake cloud at TV and phone size.

import 'package:felt_notes/homegame/blind_clock.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:felt_notes/sync/tv_board.dart';
import 'package:felt_notes/ui/tv/tv_controller.dart';
import 'package:felt_notes/ui/tv/tv_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final t0 = DateTime(2026, 10, 30, 19).millisecondsSinceEpoch;

class Clock {
  int ms;
  Clock(this.ms);
  int call() => ms;
  void advance(int d) => ms += d;
}

const sage = Seat('Sage', 'Sage'), john = Seat('John', 'John'), joe = Seat('Joe', 'Joe'), amy = Seat('Amy', 'Amy');

/// Organizer + John + Joe (Joe private) on one fake cloud; Amy is seated
/// but has no phone.
class Table {
  final clock = Clock(t0);
  late final FakeCloudLogs cloud = FakeCloudLogs(clock: clock.call);
  late LocalTableSync org, johnP, joeP;
  late List<Uploader> ups;
  int hand = 0;

  Future<void> setUp({bool joeShares = false}) async {
    org = await LocalTableSync.organize(MemoryStore(),
        organizerName: 'Sage', selfPid: 'Sage', roster: const [sage, john, joe, amy], now: clock.call, cloud: cloud);
    johnP = await LocalTableSync.join(MemoryStore(), org.qrTicket(),
        name: 'John', claimPid: 'John', scannedAtMs: clock.ms, now: clock.call, cloud: cloud);
    joeP = await LocalTableSync.join(MemoryStore(), org.qrTicket(),
        name: 'Joe', claimPid: 'Joe', scannedAtMs: clock.ms, sharing: joeShares, now: clock.call, cloud: cloud);
    ups = [
      for (final s in [org, johnP, joeP]) Uploader(log: s.log, cloud: cloud, ticket: s.ticket, name: s.myName, now: clock.call)
    ];
  }

  Future<void> nextHand() async {
    hand++;
    await org.startHand(hand, const ['Sage', 'John', 'Joe', 'Amy'][(hand - 1) % 4]);
  }

  Future<void> upload() async {
    for (final u in ups) {
      await u.drainOnce();
    }
  }

  Future<MergedNight> tvView([Map<String, List<int>> cards = const {}]) async {
    final logs = await cloud.fetch(org.nightId);
    return mergeNight(organizerDeviceId: organizerOf(logs)!, logs: injectCards(logs, cards));
  }
}

void main() {
  test('cards: hidden while the hand is played, and for the delay after it', () async {
    final t = Table();
    await t.setUp();
    await t.nextHand();
    t.clock.advance(20000);
    await t.johnP.setCards(parseCards('AsAh'));
    await t.johnP.tap(PreAction.raise);
    await t.upload();
    var b = buildTvBoard(await t.tvView(), nowMs: t.clock.ms);
    expect(b.recent, isEmpty, reason: 'hand 1 is still being played');
    expect(b.rows.firstWhere((r) => r.name == 'John').hands, 0, reason: 'stats count finished hands only');
    // Hand 2 starts: hand 1 is over. Stats update at once, cards do not.
    t.clock.advance(100000);
    await t.nextHand();
    await t.upload();
    final fetch = CardFetcher(t.cloud, t.org.nightId, now: t.clock.call);
    var m = await t.tvView();
    b = buildTvBoard(m, nowMs: t.clock.ms);
    expect(b.rows.firstWhere((r) => r.name == 'John').hands, 1);
    expect(b.rows.firstWhere((r) => r.name == 'John').vpip, 1);
    expect(b.recent.single.cardsOpen, isFalse);
    expect(await fetch.fill(m), isFalse, reason: 'the TV does not even ask yet');
    expect(t.cloud.reads, isNonZero);
    // The phone is holding the cards (no later entry, hold not over).
    expect(t.cloud.cards[t.org.nightId], isNull);
    // After the delay the TV asks; the phone's hold ends a bit later.
    t.clock.advance(const TvOptions().cardDelayMs);
    m = await t.tvView();
    expect(await fetch.fill(m), isFalse, reason: 'not uploaded yet: retried later, not shown');
    t.clock.advance(cardHoldMs);
    await t.upload();
    expect(await fetch.fill(m), isFalse, reason: 'inside the retry gap');
    t.clock.advance(serverCardHoldMs + 60000);
    expect(await fetch.fill(m), isTrue);
    b = buildTvBoard(await t.tvView(fetch.got), nowMs: t.clock.ms);
    expect(b.recent.single.cardsOpen, isTrue);
    expect(b.recent.single.plays.single.cards, parseCards('AsAh'));
    expect(b.rows.firstWhere((r) => r.name == 'John').recent, ['Raise #1']);
  });

  test('a TV that already holds cards still hides them for an unfinished hand', () {
    // Even if card values reached the merge somehow (the organizer's own
    // phone has its own cards locally), the board only shows them late.
    const dev = 'SAGEPHN23456';
    final evs = [
      NightEvent(deviceId: dev, seq: 1, kind: EventKind.join, ms: t0, data: const {'name': 'Sage', 'claim': 'Sage', 'offset': 0}),
      NightEvent(deviceId: dev, seq: 2, kind: EventKind.seats, ms: t0, data: {'seats': [sage.toJson(), john.toJson()]}),
      NightEvent(deviceId: dev, seq: 3, kind: EventKind.hand, ms: t0, data: const {'n': 1, 'd': 'Sage'}),
      NightEvent(deviceId: dev, seq: 4, kind: EventKind.cards, ms: t0 + 1, data: {'e': 1, 'c': parseCards('KsKd')}),
      NightEvent(deviceId: dev, seq: 5, kind: EventKind.play, ms: t0 + 1, data: const {'e': 1, 'a': 'raise'}),
    ];
    final m = mergeNight(organizerDeviceId: dev, logs: [DeviceLog(dev, evs)]);
    expect(m.hands.single.players['Sage']!.cards, isNotNull);
    final hours = buildTvBoard(m, nowMs: t0 + 3 * 3600000);
    expect(hours.recent, isEmpty, reason: 'no later hand and no end: still being played');
    expect(hours.drama, isEmpty);
  });

  test('private players: name and "private" only, never folded into stats', () async {
    final t = Table();
    await t.setUp();
    for (var i = 0; i < 12; i++) {
      await t.nextHand();
      t.clock.advance(30000);
      if (i.isEven) await t.joeP.tap(PreAction.call);
      t.clock.advance(90000);
    }
    await t.nextHand();
    await t.upload();
    final b = buildTvBoard(await t.tvView(), nowMs: t.clock.ms);
    final joeRow = b.rows.firstWhere((r) => r.name == 'Joe');
    expect(joeRow.status, TvStatus.private);
    expect(joeRow.hands, 0);
    expect(joeRow.recent, isEmpty);
    // Nothing of Joe's is in the cloud except his name and the switch.
    final joeDoc = t.cloud.parts[t.org.nightId]!.values.firstWhere((p) => p.deviceId == t.joeP.deviceId);
    expect({for (final e in joeDoc.events) e.kind}, {EventKind.join, EventKind.share});
    // Amy is seated with no phone; John shares and folded everything.
    expect(b.rows.firstWhere((r) => r.name == 'Amy').status, TvStatus.noPhone);
    final johnRow = b.rows.firstWhere((r) => r.name == 'John');
    expect(johnRow.status, TvStatus.sharing);
    expect(johnRow.hands, 12);
    expect(johnRow.vpip, 0);
    // Joe sits out of every merged hand rather than counting as 12 folds.
    expect((await t.tvView()).hands.every((h) => !h.players.containsKey('Joe')), isTrue);
    expect(b.rows.first.status, TvStatus.sharing, reason: 'sharing players are listed first');
  });

  test('turning sharing on later shows the whole night; off again hides it', () async {
    final t = Table();
    await t.setUp();
    await t.nextHand();
    t.clock.advance(30000);
    await t.joeP.tap(PreAction.raise);
    t.clock.advance(90000);
    await t.nextHand();
    await t.upload();
    expect(buildTvBoard(await t.tvView(), nowMs: t.clock.ms).rows.firstWhere((r) => r.name == 'Joe').status,
        TvStatus.private);
    await t.joeP.setSharing(true);
    await t.upload();
    var joeRow = buildTvBoard(await t.tvView(), nowMs: t.clock.ms).rows.firstWhere((r) => r.name == 'Joe');
    expect(joeRow.status, TvStatus.sharing);
    expect(joeRow.pfr, 1);
    await t.joeP.setSharing(false);
    await t.upload();
    joeRow = buildTvBoard(await t.tvView(), nowMs: t.clock.ms).rows.firstWhere((r) => r.name == 'Joe');
    expect(joeRow.status, TvStatus.private);
    expect(joeRow.pfr, 0);
  });

  test('the organizer phone dies: the TV keeps the last state and says it is stale', () async {
    final t = Table();
    await t.setUp();
    for (var i = 0; i < 3; i++) {
      await t.nextHand();
      t.clock.advance(120000);
    }
    await t.upload();
    final m = await t.tvView();
    var b = buildTvBoard(m, nowMs: t.clock.ms);
    expect(b.staleAt(t.clock.ms), isFalse);
    expect(b.handNow, 3);
    t.clock.advance(const TvOptions().staleMs + 1000); // no uploads since
    b = buildTvBoard(m, nowMs: t.clock.ms);
    expect(b.staleAt(t.clock.ms), isTrue);
    expect(b.finished, 2, reason: 'the last state is still on screen');
    // An ended night is never "stale".
    await t.org.endNight();
    await t.upload();
    b = buildTvBoard(await t.tvView(), nowMs: t.clock.ms + 3600000);
    expect(b.ended, isTrue);
    expect(b.staleAt(t.clock.ms + 3600000), isFalse);
    expect(b.finished, 3);
  });

  test('late joiner and a phone that leaves', () async {
    final t = Table();
    await t.setUp();
    await t.nextHand();
    t.clock.advance(120000);
    await t.johnP.leave();
    await t.nextHand();
    t.clock.advance(120000);
    final kim = await LocalTableSync.join(MemoryStore(), t.org.qrTicket(),
        name: 'Kim', scannedAtMs: t.clock.ms, now: t.clock.call, cloud: t.cloud);
    await t.org.setSeats(const [sage, john, joe, amy, Seat('Kim', 'Kim')]);
    t.ups.add(Uploader(log: kim.log, cloud: t.cloud, ticket: kim.ticket, name: 'Kim', now: t.clock.call));
    await t.nextHand();
    t.clock.advance(30000);
    await kim.tap(PreAction.call);
    t.clock.advance(90000);
    await t.nextHand();
    await t.upload();
    final b = buildTvBoard(await t.tvView(), nowMs: t.clock.ms);
    final johnRow = b.rows.firstWhere((r) => r.name == 'John');
    expect(johnRow.status, TvStatus.left);
    expect(johnRow.hands, 1);
    final kimRow = b.rows.firstWhere((r) => r.name == 'Kim');
    expect(kimRow.hands, 1);
    expect(kimRow.vpip, 1);
  });

  test('ticket from a code, a TV link or a QR payload', () {
    expect(ticketFromTvInput('abcd2345-wxyz6789')!.nightId, 'ABCD2345');
    expect(ticketFromTvInput('https://sagearbor.github.io/texasHoldemGTO/#/tv?c=ABCD2345-WXYZ6789')!.secret,
        'WXYZ6789');
    expect(ticketFromTvInput('nope'), isNull);
  });

  group('TV page', () {
    Future<(Table, TvController)> live(WidgetTester tester, Size size) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final t = Table();
      await tester.runAsync(() async {
        await t.setUp();
        await t.org.appendEvent(EventKind.clock, {'j': (BlindClock()..start(t.clock.ms)).toJson()});
        for (var i = 0; i < 6; i++) {
          await t.nextHand();
          t.clock.advance(20000);
          if (i == 2) {
            await t.johnP.setCards(parseCards('KsKh'));
            await t.johnP.tap(PreAction.raise);
          }
          t.clock.advance(100000);
        }
        await t.upload();
      });
      final c = TvController(t.org.ticket, now: t.clock.call, open: () async => t.cloud);
      await tester.pumpWidget(MaterialApp(home: TvScreen(ticket: t.org.ticket, controller: c)));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return (t, c);
    }

    for (final size in const [Size(1920, 1080), Size(1280, 720), Size(390, 844)]) {
      testWidgets('renders live at ${size.width.toInt()}x${size.height.toInt()} without overflow', (tester) async {
        final (_, c) = await live(tester, size);
        expect(c.link, TvLink.live);
        expect(find.text("Sage's table"), findsOneWidget);
        expect(find.textContaining('Hand 6'), findsOneWidget);
        expect(find.text('John'), findsOneWidget);
        expect(find.textContaining('private'), findsWidgets); // Joe
        expect(find.textContaining('live · updated'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      });
    }
  });
}
