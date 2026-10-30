// The organizer's hand logger mirrored into the table night log: driven
// through the real HomeGameModel (undo, first orbit, dealer fixes, board,
// end), checked by merging the log back and comparing with the session.

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart';
import 'package:felt_notes/sync/organizer_bridge.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  late HomeGameModel m;
  late LocalTableSync sync;
  late OrganizerBridge bridge;

  Future<void> start({List<String> players = const ['Sage', 'Ann', 'Bob', 'Cat'], bool learn = false}) async {
    SharedPreferences.setMockInitialValues({});
    m = HomeGameModel(lib);
    await m.load();
    m.start(name: 'x', players: players, heroSeat: 0, buttonSeat: learn ? -1 : 0, learnSeats: learn);
    final s = m.active!;
    sync = await LocalTableSync.organize(MemoryStore(),
        organizerName: s.heroName, selfPid: s.heroName, roster: rosterOf(s));
    bridge = OrganizerBridge(sync);
    await bridge.reconcile(s);
  }

  /// The model stamps hands with DateTime.now(): keep hands a few ms apart
  /// so every hand has a real interval.
  Future<void> step(void Function() op) async {
    await Future<void>.delayed(const Duration(milliseconds: 4));
    op();
    await bridge.reconcile(m.active ?? m.sessions.last);
  }

  MergedNight merged() => mergeNight(organizerDeviceId: sync.deviceId, logs: [DeviceLog(sync.deviceId, sync.localEvents)]);

  /// Every closed hand in the log matches the session, hand by hand.
  void expectMirrors(HomeSession s) {
    final night = merged();
    final closed = [for (final h in night.hands) if (night.timeline.isOver(h.hand)) h];
    expect(closed.length, s.hands.length);
    for (var i = 0; i < s.hands.length; i++) {
      final h = s.hands[i], mh = closed[i];
      expect(mh.n, h.number);
      expect(mh.hand.dealer, h.dealer, reason: 'dealer of hand ${h.number}');
      final me = mh.players[s.heroName]!;
      expect(me.action, h.action ?? PreAction.fold, reason: 'action of hand ${h.number}');
      expect(me.inferred, h.assumed || h.action == null, reason: 'hand ${h.number}');
      expect(me.cards, h.cards, reason: 'cards of hand ${h.number}');
      if (!s.learning) expect(me.position, h.position, reason: 'position of hand ${h.number}');
    }
    expect(night.unassigned, isEmpty);
  }

  test('hands, dealers, own taps and cards mirror the session; idempotent', () async {
    await start();
    await step(() {
      m.setPending(PreAction.raise, facing: Facing.unopened);
      m.nextHand(cards: parseCards('AsKs'));
    });
    await step(() => m.nextHand());
    await step(() {
      m.setPending(PreAction.call);
      m.nextHand(cards: parseCards('7d7c'));
    });
    await step(() => m.nextHand());
    expectMirrors(m.active!);
    final n = sync.localEvents.length;
    await bridge.reconcile(m.active!);
    await bridge.reconcile(m.active!);
    expect(sync.localEvents.length, n, reason: 'nothing new to say');
    // The hand being played is in the timeline, but none of its cards.
    final night = merged();
    expect(night.hands.length, 5);
    expect(night.timeline.isOver(night.hands.last.hand), isFalse);
    expect(sync.localEvents.where((e) => e.kind == EventKind.cards).length, 2);
  });

  test('undo, a changed tap and a dealer fix converge to the session', () async {
    await start();
    await step(() {
      m.setPending(PreAction.raise);
      m.nextHand(cards: parseCards('QsQh'));
    });
    await step(() => m.nextHand());
    await step(() => m.undo()); // hand 2 reopens
    await step(() => m.setPending(PreAction.call));
    await step(() => m.nextHand(cards: parseCards('9s8s')));
    await step(() => m.undo()); // hand 2 again: now a fold after all
    await step(() => m.setPending(null));
    await step(() => m.nextHand());
    await step(() => m.setDealer(3)); // the dealer of the hand being played was wrong
    await step(() => m.nextHand());
    expectMirrors(m.active!);
    expect(merged().hands[2].hand.dealer, 'Cat');
  });

  test('first orbit: seats learned from the dealer taps, positions right afterwards', () async {
    await start(players: const ['Sage', 'Ann', 'Bob', 'Cat'], learn: true);
    final s = m.active!;
    // Dealers in the order Bob, Sage, Cat, Ann: that becomes the seating.
    for (final name in ['Bob', 'Sage', 'Cat', 'Ann']) {
      await step(() => m.dealerTap(s.players.indexOf(name)));
    }
    expect(s.learning, isFalse);
    await step(() {
      m.setPending(PreAction.raise);
      m.nextHand();
    });
    await step(() => m.nextHand());
    expectMirrors(s);
    expect(merged().timeline.seatsNow.map((x) => x.pid), s.players);
  });

  test('board, a new player, end of night', () async {
    await start();
    await step(() => m.setCurrentBoard(parseCards('Ah Kd 7c 2s 9h')));
    expect(merged().hands.single.hand.board, parseCards('Ah Kd 7c 2s 9h'));
    await step(() => m.nextHand());
    await step(() => m.dealerArrives('Dee'));
    await step(() => m.nextHand());
    expect(merged().hands.last.hand.seats.map((x) => x.pid), contains('Dee'));
    await step(() => m.end());
    final night = merged();
    expect(night.timeline.endMs, isNotNull);
    expect(night.hands.length, 2); // the abandoned hand in progress is dropped
    expectMirrors(m.sessions.last);
  });

  test('a crash halfway through writing an entry heals on the next pass', () async {
    await start();
    await step(() {
      m.setPending(PreAction.raise);
      m.nextHand(cards: parseCards('AhAd'));
    });
    // Simulate a phone killed after half of a re-write: a stray entry for
    // hand 1 with cards but no tap.
    await sync.appendEvent(EventKind.cards, {'e': 9, 'h': 1, 'c': parseCards('2c3c'), 'done': true},
        ms: m.active!.hands.first.start! + 1);
    await bridge.reconcile(m.active!);
    expectMirrors(m.active!);
    expect(merged().hands.first.players['Sage']!.cards, parseCards('AhAd'));
  });

  test('a player phone lines up against the mirrored timeline', () async {
    await start();
    final player = await LocalTableSync.join(MemoryStore(), sync.qrTicket(roster: rosterOf(m.active!)),
        name: 'Ann', claimPid: 'Ann', scannedAtMs: DateTime.now().millisecondsSinceEpoch);
    await step(() => m.nextHand());
    await Future<void>.delayed(const Duration(milliseconds: 4));
    await player.tap(PreAction.raise); // during hand 2
    await step(() => m.nextHand());
    final night = mergeNight(
        organizerDeviceId: sync.deviceId,
        logs: [DeviceLog(sync.deviceId, sync.localEvents), DeviceLog(player.deviceId, player.localEvents)]);
    expect(night.hands[1].players['Ann']!.action, PreAction.raise);
    expect(night.hands[0].players['Ann']!.inferred, isTrue);
  });

  test('the blind clock is recorded only when it changes', () async {
    await start();
    await bridge.recordClock({'lvl': 0, 'a': 5});
    await bridge.recordClock({'lvl': 0, 'a': 5});
    await bridge.recordClock({'lvl': 1, 'a': 9});
    expect(sync.localEvents.where((e) => e.kind == EventKind.clock).length, 2);
    expect(merged().timeline.clock, {'lvl': 1, 'a': 9});
  });
}
