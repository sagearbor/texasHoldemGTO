// Fabricated table nights for the multi-phone merge (lib/sync/night_merge.dart).
//
// Cast: the organizer "Sage" (device ORG, pid p1) does the dealer bookkeeping;
// John (p2), Joe (p3) and Amy (p4) have the app; Bob (p5) has no phone.
// Hands start every 2 minutes from 7:00pm on the organizer's clock.

import 'dart:math';

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime(2026, 10, 30, 19).millisecondsSinceEpoch;
const handMs = 120000;
int startOf(int n) => t0 + (n - 1) * handMs;

/// Mid-hand on the organizer clock (+ [into] ms after the boundary).
int during(int n, [int into = 45000]) => startOf(n) + into;

const sage = Seat('p1', 'Sage'), john = Seat('p2', 'John'), joe = Seat('p3', 'Joe');
const amy = Seat('p4', 'Amy'), bob = Seat('p5', 'Bob');

/// One phone. Its clock reads organizer time minus [offset] (so [offset]
/// is exactly what the join QR measures: organizer - local).
class Phone {
  final String id;
  final int offset;
  final List<NightEvent> events = [];
  int _e = 0;
  Phone(this.id, {this.offset = 0});

  NightEvent add(EventKind k, int orgMs, [Map<String, Object?> data = const {}]) {
    final e = NightEvent(deviceId: id, seq: events.length + 1, kind: k, ms: orgMs - offset, data: data);
    events.add(e);
    return e;
  }

  /// [measured] is the offset the QR gave (defaults to the truth).
  void join(String name, int orgMs, {String? claim, int? measured, bool qr = true}) =>
      add(EventKind.join, orgMs, {
        'name': name,
        if (claim != null) 'claim': claim,
        if (qr) 'offset': measured ?? offset,
      });

  int play(int orgMs, PreAction a, {Facing? f}) {
    final e = ++_e;
    add(EventKind.play, orgMs, {'e': e, 'a': a.name, if (f != null) 'f': f.name});
    return e;
  }

  void cards(int orgMs, List<int> c, {int? entry}) =>
      add(EventKind.cards, orgMs, {'e': entry ?? ++_e, 'c': c});

  DeviceLog get log => DeviceLog(id, List.of(events));
}

/// The organizer's phone: seats [seats], then [hands] hands every 2 minutes,
/// button moving clockwise from seats[0].
Phone organizer({List<Seat> seats = const [sage, john, joe, amy, bob], int hands = 10, bool end = true}) {
  final o = Phone('ORG');
  o.join('Sage', t0 - 60000, claim: 'p1');
  o.add(EventKind.seats, t0 - 30000, {'seats': [for (final s in seats) s.toJson()]});
  for (var n = 1; n <= hands; n++) {
    o.add(EventKind.hand, startOf(n), {'n': n, 'd': seats[(n - 1) % seats.length].pid});
  }
  if (end) o.add(EventKind.end, startOf(hands + 1));
  return o;
}

MergedNight merge(List<Phone> phones, {MergeOptions opts = const MergeOptions(), Map<String, String> links = const {}}) =>
    mergeNight(organizerDeviceId: 'ORG', logs: [for (final p in phones) p.log], opts: opts, links: links);

PlayerHand? at(MergedNight m, int n, String pid) => m.hands.firstWhere((h) => h.n == n).players[pid];

void main() {
  group('timeline', () {
    test('hands, dealers and the end', () {
      final m = merge([organizer()]);
      expect(m.hands.map((h) => h.n), List.generate(10, (i) => i + 1));
      expect(m.hands.first.hand.dealer, 'p1');
      expect(m.hands[5].hand.dealer, 'p1'); // 5 seats: hand 6 is back to Sage
      expect(m.hands.last.hand.endMs, startOf(11));
      expect(m.warnings, isEmpty);
    });

    test('a mis-tapped next hand is undone and its time folds into the previous hand', () {
      final o = organizer(hands: 3);
      o.add(EventKind.hand, startOf(3) + 20000, {'n': 4, 'd': 'p4'});
      o.add(EventKind.unhand, startOf(3) + 25000, {'n': 4});
      final m = merge([o]);
      expect(m.hands.map((h) => h.n), [1, 2, 3]);
      expect(m.hands.last.hand.endMs, startOf(4));
    });

    test('a re-tapped hand number replaces the first tap', () {
      final o = organizer(hands: 2, end: false);
      o.add(EventKind.hand, startOf(2) + 30000, {'n': 2, 'd': 'p3'});
      final h = merge([o]).hands.last.hand;
      expect(h.startMs, startOf(2) + 30000);
      expect(h.dealer, 'p3');
    });

    test('the open last hand gets lastHandMs', () {
      final m = merge([organizer(hands: 2, end: false)], opts: const MergeOptions(lastHandMs: 300000));
      expect(m.hands.last.hand.endMs, startOf(2) + 300000);
    });

    test('positions follow the button; the board is attached', () {
      final o = organizer(hands: 2);
      o.add(EventKind.board, startOf(2) + 90000, {'n': 2, 'c': parseCards('Kh7d2c')});
      final m = merge([o]);
      // Hand 1: Sage deals. 5 seats: Sage BTN, John SB, Joe BB, Amy UTG, Bob CO.
      final h1 = m.hands.first.hand;
      expect([for (final s in h1.seats) h1.positionOf(s.pid)], ['BTN', 'SB', 'BB', 'UTG', 'CO']);
      expect(m.hands[1].hand.board, parseCards('Kh7d2c'));
      expect(m.hands[1].hand.positionOf('p2'), 'BTN');
    });

    test('a seats change applies from the next hand on', () {
      final o = Phone('ORG');
      o.join('Sage', t0 - 1000, claim: 'p1');
      o.add(EventKind.seats, t0 - 500, {'seats': [sage.toJson(), john.toJson()]});
      o.add(EventKind.hand, startOf(1), {'n': 1, 'd': 'p1'});
      o.add(EventKind.seats, startOf(1) + 60000, {'seats': [sage.toJson(), john.toJson(), amy.toJson()]});
      o.add(EventKind.hand, startOf(2), {'n': 2, 'd': 'p2'});
      final m = merge([o]);
      expect(m.hands[0].hand.seats.length, 2);
      expect(m.hands[1].hand.seats.length, 3);
      expect(m.hands[0].hand.positionOf('p1'), 'BTN/SB');
    });
  });

  group('alignment', () {
    test('taps land on their hands; everything else is a default fold', () {
      final o = organizer();
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      j.play(during(2), PreAction.call, f: Facing.unopened);
      j.play(during(5), PreAction.raise);
      final m = merge([o, j]);
      expect(at(m, 2, 'p2')!.action, PreAction.call);
      expect(at(m, 2, 'p2')!.inferred, isFalse);
      expect(at(m, 2, 'p2')!.facing, Facing.unopened);
      expect(at(m, 5, 'p2')!.action, PreAction.raise);
      for (final n in [1, 3, 4, 6, 7, 8, 9, 10]) {
        expect(at(m, n, 'p2')!.action, PreAction.fold, reason: 'hand $n');
        expect(at(m, n, 'p2')!.inferred, isTrue);
      }
      // Organizer is a player too (present from their join); Bob has no phone.
      expect(at(m, 1, 'p1')!.inferred, isTrue);
      expect(at(m, 1, 'p5'), isNull);
      expect(m.unassigned, isEmpty);
    });

    test('a phone 7 minutes slow is corrected by the QR offset', () {
      final o = organizer();
      final j = Phone('JOHN', offset: 7 * 60000)..join('John', t0 - 50000, claim: 'p2');
      j.play(during(3), PreAction.call);
      j.play(during(8), PreAction.raise);
      final m = merge([o, j]);
      expect(at(m, 3, 'p2')!.action, PreAction.call);
      expect(at(m, 8, 'p2')!.action, PreAction.raise);
      expect(m.devices.firstWhere((d) => d.deviceId == 'JOHN').offsetSource, OffsetSource.qr);
    });

    test('residual skew of 30 s (bad QR reading) still lands mid-hand taps', () {
      final o = organizer();
      final j = Phone('JOHN', offset: 3 * 60000)..join('John', t0 - 50000, claim: 'p2', measured: 3 * 60000 - 30000);
      for (final n in [1, 4, 6, 9]) {
        j.play(during(n, 60000), PreAction.call);
      }
      final m = merge([o, j]);
      for (final n in [1, 4, 6, 9]) {
        expect(at(m, n, 'p2')!.action, PreAction.call, reason: 'hand $n');
      }
      expect(at(m, 5, 'p2')!.inferred, isTrue);
    });

    test('skew that pushes two taps into one hand spreads them to neighbours', () {
      final o = organizer();
      // Clock 40 s fast vs what the QR measured: taps late in hand 3 and
      // early in hand 4 both read as hand 4.
      final j = Phone('JOHN', offset: 0)..join('John', t0 - 50000, claim: 'p2', measured: 40000);
      j.play(startOf(3) + 100000, PreAction.call); // reads as 3 + 140 s -> hand 4
      j.play(startOf(4) + 30000, PreAction.raise); // reads as 4 + 70 s -> hand 4
      final m = merge([o, j]);
      expect(at(m, 3, 'p2')!.action, PreAction.call);
      expect(at(m, 4, 'p2')!.action, PreAction.raise);
      expect(m.unassigned, isEmpty);
    });

    test('a tap long after the night is reported, not guessed', () {
      final o = organizer(hands: 3);
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      j.play(during(2), PreAction.call);
      j.play(startOf(4) + 20 * 60000, PreAction.raise);
      final m = merge([o, j]);
      expect(at(m, 2, 'p2')!.action, PreAction.call);
      expect(m.unassigned.length, 1);
      expect(m.unassigned.single.entry.action, PreAction.raise);
    });

    test('player data with no organizer data yet: nothing assigned, all reported', () {
      final j = Phone('JOHN')..join('John', t0, claim: 'p2');
      j.play(during(1), PreAction.call);
      final m = merge([j]);
      expect(m.hands, isEmpty);
      expect(m.unassigned.single.reason, contains('no hand'));
      expect(m.warnings, isNotEmpty);
    });

    test('a correction (same entry, two plays) keeps the last action', () {
      final o = organizer(hands: 3);
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      final e = j.play(during(2), PreAction.call);
      j.add(EventKind.play, during(2) + 4000, {'e': e, 'a': 'raise'});
      final m = merge([o, j]);
      expect(at(m, 2, 'p2')!.action, PreAction.raise);
    });

    test('an undone entry is ignored', () {
      final o = organizer(hands: 3);
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      final e = j.play(during(2), PreAction.call);
      j.add(EventKind.undo, during(2) + 9000, {'e': e});
      final m = merge([o, j]);
      expect(at(m, 2, 'p2')!.inferred, isTrue);
    });

    test('cards without a tap are a fold that had cards', () {
      final o = organizer(hands: 3);
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      j.cards(during(2, 10000), parseCards('7c2d'));
      final m = merge([o, j]);
      final p = at(m, 2, 'p2')!;
      expect(p.action, PreAction.fold);
      expect(p.cards, parseCards('7c2d'));
      expect(p.hadCards, isTrue);
      expect(p.inferred, isTrue);
    });

    test('cards then a tap in the same entry anchor at the first event', () {
      final o = organizer(hands: 4);
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      j.cards(startOf(3) + 100000, parseCards('AsKs'), entry: 1);
      j.add(EventKind.play, startOf(4) + 10000, {'e': 1, 'a': 'raise'}); // tapped during the next deal
      final m = merge([o, j]);
      expect(at(m, 3, 'p2')!.action, PreAction.raise);
      expect(at(m, 3, 'p2')!.cards, parseCards('AsKs'));
      expect(at(m, 4, 'p2')!.inferred, isTrue);
    });
  });

  group('who is at the table', () {
    test('late joiner: present only from the hand the organizer seated them', () {
      final o = Phone('ORG')..join('Sage', t0 - 1000, claim: 'p1');
      o.add(EventKind.seats, t0 - 500, {'seats': [sage.toJson(), john.toJson()]});
      for (var n = 1; n <= 4; n++) {
        o.add(EventKind.hand, startOf(n), {'n': n, 'd': n.isOdd ? 'p1' : 'p2'});
      }
      o.add(EventKind.seats, startOf(4) + 100000, {'seats': [sage.toJson(), john.toJson(), amy.toJson()]});
      for (var n = 5; n <= 8; n++) {
        o.add(EventKind.hand, startOf(n), {'n': n, 'd': ['p1', 'p2', 'p4'][(n - 5) % 3]});
      }
      o.add(EventKind.end, startOf(9));
      final a = Phone('AMY', offset: -20000)..join('Amy', startOf(4) + 90000, claim: 'p4');
      a.play(during(6), PreAction.call);
      final m = merge([o, a]);
      for (var n = 1; n <= 4; n++) {
        expect(at(m, n, 'p4'), isNull, reason: 'hand $n');
      }
      expect(at(m, 5, 'p4')!.inferred, isTrue);
      expect(at(m, 6, 'p4')!.action, PreAction.call);
      expect(at(m, 6, 'p4')!.position, isNotNull);
    });

    test('early leaver: no folds after they left, even if the organizer forgot', () {
      final o = organizer();
      final j = Phone('JOE')..join('Joe', t0 - 40000, claim: 'p3');
      j.play(during(2), PreAction.raise);
      j.add(EventKind.leave, startOf(6) + 100000);
      final m = merge([o, j]);
      expect(at(m, 6, 'p3')!.inferred, isTrue);
      for (var n = 7; n <= 10; n++) {
        expect(at(m, n, 'p3'), isNull, reason: 'hand $n');
      }
    });

    test('removed by the organizer: not counted after removal', () {
      final o = Phone('ORG')..join('Sage', t0 - 1000, claim: 'p1');
      o.add(EventKind.seats, t0 - 500, {'seats': [sage.toJson(), john.toJson(), joe.toJson()]});
      o.add(EventKind.hand, startOf(1), {'n': 1, 'd': 'p1'});
      o.add(EventKind.hand, startOf(2), {'n': 2, 'd': 'p2'});
      o.add(EventKind.seats, startOf(2) + 60000, {'seats': [sage.toJson(), john.toJson()]});
      o.add(EventKind.hand, startOf(3), {'n': 3, 'd': 'p1'});
      final j = Phone('JOE')..join('Joe', t0 - 400, claim: 'p3');
      final m = merge([o, j]);
      expect(at(m, 2, 'p3'), isNotNull);
      expect(at(m, 3, 'p3'), isNull);
    });

    test('a phone the organizer never seated still gets its hands (no position)', () {
      final o = organizer(hands: 4);
      final x = Phone('XAVI')..join('Xavi', t0 - 10000);
      x.play(during(3), PreAction.call);
      final m = merge([o, x]);
      final d = m.devices.firstWhere((d) => d.deviceId == 'XAVI');
      expect(d.linked, isFalse);
      expect(d.pid, 'dev:XAVI');
      expect(at(m, 3, 'dev:XAVI')!.action, PreAction.call);
      expect(at(m, 3, 'dev:XAVI')!.position, isNull);
      expect(at(m, 1, 'dev:XAVI')!.inferred, isTrue);
    });

    test('linking: by claim, by unique name, by override; a double claim keeps the first', () {
      final o = organizer(hands: 2);
      final byName = Phone('A1')..join('  amy ', t0 - 1000); // matches "Amy"
      final byLink = Phone('B1')..join('Bobby', t0 - 1000);
      final dup1 = Phone('C1')..join('John', t0 - 1000, claim: 'p2');
      final dup2 = Phone('C2')..join('John (old phone)', t0 - 1000, claim: 'p2');
      final m = mergeNight(
        organizerDeviceId: 'ORG',
        logs: [o.log, byName.log, byLink.log, dup1.log, dup2.log],
        links: {'B1': 'p5'},
      );
      String pidOf(String dev) => m.devices.firstWhere((d) => d.deviceId == dev).pid;
      expect(pidOf('A1'), 'p4');
      expect(pidOf('B1'), 'p5');
      expect(pidOf('C1'), 'p2');
      expect(pidOf('C2'), 'dev:C2');
      expect(m.warnings.any((w) => w.contains('Two phones')), isTrue);
      expect(m.nameOf('p4'), 'Amy');
    });
  });

  group('clocks', () {
    test('typed code (no QR clock): offset from server-time skew', () {
      final o = organizer();
      final j = Phone('JOHN', offset: 5 * 60000)..join('John', t0 - 50000, claim: 'p2', qr: false);
      j.play(during(4), PreAction.call);
      // Server clock = organizer clock + 1000; John is 5 min behind the organizer.
      final m = mergeNight(organizerDeviceId: 'ORG', logs: [
        DeviceLog('ORG', o.events, serverSkewMs: 1000),
        DeviceLog('JOHN', j.events, serverSkewMs: 1000 + 5 * 60000),
      ]);
      expect(m.devices.firstWhere((d) => d.deviceId == 'JOHN').offsetSource, OffsetSource.server);
      expect(at(m, 4, 'p2')!.action, PreAction.call);
    });

    test('no offset at all: assume equal clocks and warn', () {
      final o = organizer();
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2', qr: false);
      j.play(during(4), PreAction.call);
      final m = merge([o, j]);
      expect(m.warnings.single, contains('No clock offset for John'));
      expect(at(m, 4, 'p2')!.action, PreAction.call);
    });
  });

  group('idempotent', () {
    test('duplicate uploads, overlapping parts and shuffled order change nothing', () {
      final o = organizer();
      final j = Phone('JOHN', offset: 90000)..join('John', t0 - 50000, claim: 'p2');
      final a = Phone('AMY', offset: -45000)..join('Amy', t0 - 50000, claim: 'p4');
      final rng = Random(3);
      for (var n = 1; n <= 10; n++) {
        if (rng.nextDouble() < 0.4) j.play(during(n, 20000 + rng.nextInt(60000)), PreAction.call);
        if (rng.nextDouble() < 0.3) a.play(during(n, 20000 + rng.nextInt(60000)), PreAction.raise);
      }
      final once = merge([o, j, a]);
      final shuffled = [...j.events]..shuffle(rng);
      final again = mergeNight(organizerDeviceId: 'ORG', logs: [
        a.log,
        DeviceLog('JOHN', shuffled.sublist(0, 4)),
        o.log,
        DeviceLog('JOHN', shuffled),
        a.log,
        DeviceLog('ORG', o.events.sublist(3)),
        j.log,
      ]);
      String sig(MergedNight m) => [
            for (final h in m.hands)
              for (final p in (h.players.values.toList()..sort((x, y) => x.pid.compareTo(y.pid))))
                '${h.n}:${p.pid}:${p.action.name}:${p.inferred}'
          ].join(',');
      expect(sig(again), sig(once));
      expect(again.unassigned, isEmpty);
    });
  });

  group('outputs', () {
    late SpotLibrary lib;
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
    });

    test('loggedHandsFor feeds the existing stats (default fold counts)', () {
      final o = organizer();
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      j.play(during(2), PreAction.call);
      j.play(during(5), PreAction.raise);
      j.cards(during(5, 1000), parseCards('AhAd'), entry: 2);
      final hands = merge([o, j]).loggedHandsFor('p2');
      expect(hands.length, 10);
      expect(hands[4].cards, parseCards('AhAd'));
      expect(hands[4].dealer, 'Bob'); // hand 5: the button is on seat 5
      final s = computeStats(hands, lib);
      expect(s.recorded, 10);
      expect(s.vpip, 2);
      expect(s.pfr, 1);
    });

    test('live rows: organizer always, others as they arrive, hands under delay hidden', () {
      final o = organizer(hands: 6, end: false);
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      j.play(during(1), PreAction.raise);
      final now = startOf(6) + 30000; // hand 6 in progress
      final onlyOrg = liveRows(merge([o]), nowMs: now);
      expect(onlyOrg.map((r) => r.name), ['Sage']);
      expect(onlyOrg.single.hands, 5);
      final both = liveRows(merge([o, j]), nowMs: now, delayMs: 3 * handMs);
      final jr = both.firstWhere((r) => r.pid == 'p2');
      expect(jr.hands, 2); // hands 1-2 ended >= 6 min ago
      expect(jr.confirmed, 1);
      expect(jr.pfr, 1);
    });

    test('drama: a cooler between two sharers', () {
      final o = organizer(hands: 3);
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      final e = Phone('JOE')..join('Joe', t0 - 50000, claim: 'p3');
      j.add(EventKind.share, t0 - 40000, {'on': true});
      e.add(EventKind.share, t0 - 40000, {'on': true});
      j.cards(during(2, 5000), parseCards('KsKh'), entry: 1);
      j.add(EventKind.play, during(2, 20000), {'e': 1, 'a': 'raise'});
      e.cards(during(2, 6000), parseCards('AcAd'), entry: 1);
      e.add(EventKind.play, during(2, 30000), {'e': 1, 'a': 'raise'});
      final lines = dramaLines(merge([o, j, e]));
      expect(lines.single.text, 'Cooler · Joe AA vs John KK · ${clockLabel(startOf(2))}');
      expect(clockLabel(startOf(2)), '7:02pm');
    });

    test('drama: a bad beat needs the board', () {
      final o = organizer(hands: 3);
      o.add(EventKind.board, during(2, 70000), {'n': 2, 'c': parseCards('7h6d2s9c3h')});
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      final e = Phone('JOE')..join('Joe', t0 - 50000, claim: 'p3');
      j.cards(during(2, 5000), parseCards('KsKh'), entry: 1);
      j.add(EventKind.play, during(2, 20000), {'e': 1, 'a': 'raise'});
      e.cards(during(2, 6000), parseCards('8c5c'), entry: 1);
      e.add(EventKind.play, during(2, 30000), {'e': 1, 'a': 'call'});
      final lines = dramaLines(merge([o, j, e]), rng: Random(2));
      expect(lines.single.kind, 'badBeat');
      expect(lines.single.text, startsWith('Bad beat · John KK vs Joe 85s · '));
    });

    test('drama: nothing when only one player shows cards or someone folded', () {
      final o = organizer(hands: 2);
      final j = Phone('JOHN')..join('John', t0 - 50000, claim: 'p2');
      final e = Phone('JOE')..join('Joe', t0 - 50000, claim: 'p3');
      j.cards(during(1, 5000), parseCards('KsKh'), entry: 1);
      j.add(EventKind.play, during(1, 20000), {'e': 1, 'a': 'raise'});
      e.cards(during(1, 6000), parseCards('AcAd'), entry: 1); // never tapped: folded
      expect(dramaLines(merge([o, j, e])), isEmpty);
    });
  });

  group('a whole fabricated night', () {
    test('8 phones, random skew, late joiner, early leaver, partial uploads', () {
      final rng = Random(11);
      const seats = [sage, john, joe, amy, bob, Seat('p6', 'Cy'), Seat('p7', 'Di'), Seat('p8', 'Ed')];
      final o = Phone('ORG')..join('Sage', t0 - 60000, claim: 'p1');
      o.add(EventKind.seats, t0 - 30000, {'seats': [for (final s in seats.take(7)) s.toJson()]});
      // Uneven hand lengths, 1 to 5 minutes.
      final starts = <int>[t0];
      for (var n = 2; n <= 60; n++) {
        starts.add(starts.last + 60000 + rng.nextInt(4 * 60000));
      }
      final truth = <String, Map<int, PreAction>>{};
      final phones = <Phone>[o];
      for (var n = 1; n <= 60; n++) {
        if (n == 20) {
          o.add(EventKind.seats, starts[n - 1] - 10000, {'seats': [for (final s in seats) s.toJson()]});
        }
        o.add(EventKind.hand, starts[n - 1], {'n': n, 'd': seats[(n - 1) % 7].pid});
      }
      o.add(EventKind.end, starts.last + 3 * 60000);
      for (final s in seats.skip(1)) {
        if (s.pid == 'p5') continue; // Bob has no phone
        final skew = rng.nextInt(10 * 60000) - 5 * 60000;
        final p = Phone('D${s.pid}', offset: skew);
        final joinAt = s.pid == 'p8' ? starts[19] - 20000 : t0 - 20000;
        // QR reading accurate to +-1.5 s.
        p.join(s.name, joinAt, claim: s.pid, measured: skew + rng.nextInt(3000) - 1500);
        final leaveAfter = s.pid == 'p3' ? 40 : 60;
        truth[s.pid] = {};
        for (var n = s.pid == 'p8' ? 20 : 1; n <= leaveAfter; n++) {
          if (rng.nextDouble() < 0.3) {
            final len = (n < 60 ? starts[n] : starts[59] + 180000) - starts[n - 1];
            // Taps somewhere between 15 % and 85 % into the hand.
            final at = starts[n - 1] + (len * (0.15 + 0.7 * rng.nextDouble())).round();
            final a = rng.nextBool() ? PreAction.call : PreAction.raise;
            p.play(at, a);
            truth[s.pid]![n] = a;
          }
        }
        if (s.pid == 'p3') p.add(EventKind.leave, starts[40] - 5000);
        phones.add(p);
      }
      final m = merge(phones);
      expect(m.unassigned, isEmpty);
      var checked = 0;
      truth.forEach((pid, hands) {
        final first = pid == 'p8' ? 20 : 1, last = pid == 'p3' ? 40 : 60;
        for (var n = 1; n <= 60; n++) {
          final p = at(m, n, pid);
          if (n < first || n > last) {
            expect(p, isNull, reason: '$pid hand $n');
            continue;
          }
          expect(p, isNotNull, reason: '$pid hand $n');
          expect(p!.action, hands[n] ?? PreAction.fold, reason: '$pid hand $n');
          expect(p.inferred, hands[n] == null);
          checked++;
        }
      });
      expect(checked, greaterThan(300));
      // Bob (no phone) is seated but never listed.
      expect(m.hands.every((h) => !h.players.containsKey('p5')), isTrue);

      // The TV halfway through, with only the organizer and two phones in.
      final partial = merge([o, phones[1], phones[3]]);
      expect(partial.devices.length, 3);
      expect(partial.hands.length, 60);
    });

    /// One random night: [hands] hands of 1-5 min, [players] phones with
    /// clocks up to +-5 min off, QR offsets wrong by up to [residualMs],
    /// each player playing ~30 % of hands with taps 10-90 % into the hand.
    /// Returns (correct, total) over every (player, hand).
    (int, int) sweep(int seed, {int hands = 40, int players = 7, int residualMs = 2000}) {
      final rng = Random(seed);
      final seats = [for (var i = 0; i <= players; i++) Seat('p$i', 'P$i')];
      final o = Phone('ORG')..join('P0', t0 - 60000, claim: 'p0');
      o.add(EventKind.seats, t0 - 30000, {'seats': [for (final s in seats) s.toJson()]});
      final starts = <int>[t0];
      for (var n = 2; n <= hands + 1; n++) {
        starts.add(starts.last + 60000 + rng.nextInt(4 * 60000));
      }
      for (var n = 1; n <= hands; n++) {
        o.add(EventKind.hand, starts[n - 1], {'n': n, 'd': seats[(n - 1) % seats.length].pid});
      }
      o.add(EventKind.end, starts[hands]);
      final phones = [o];
      final truth = <String, Map<int, PreAction>>{};
      for (final s in seats.skip(1)) {
        final skew = rng.nextInt(10 * 60000) - 5 * 60000;
        final p = Phone('D${s.pid}', offset: skew)
          ..join(s.name, t0 - 20000, claim: s.pid, measured: skew + rng.nextInt(2 * residualMs + 1) - residualMs);
        truth[s.pid] = {};
        for (var n = 1; n <= hands; n++) {
          if (rng.nextDouble() < 0.3) {
            final len = starts[n] - starts[n - 1];
            final a = rng.nextBool() ? PreAction.call : PreAction.raise;
            p.play(starts[n - 1] + (len * (0.1 + 0.8 * rng.nextDouble())).round(), a);
            truth[s.pid]![n] = a;
          }
        }
        phones.add(p);
      }
      final m = merge(phones);
      var ok = 0, total = 0;
      truth.forEach((pid, t) {
        for (var n = 1; n <= hands; n++) {
          total++;
          if (at(m, n, pid)?.action == (t[n] ?? PreAction.fold)) ok++;
        }
      });
      return (ok, total);
    }

    test('40 random nights with QR-grade offsets (+-2 s): every hand right', () {
      for (var seed = 100; seed < 140; seed++) {
        final (ok, total) = sweep(seed);
        expect(ok, total, reason: 'seed $seed');
      }
    });

    test('40 random nights with offsets wrong by up to 15 s: at least 98 % right', () {
      var ok = 0, total = 0;
      for (var seed = 200; seed < 240; seed++) {
        final r = sweep(seed, residualMs: 15000);
        ok += r.$1;
        total += r.$2;
      }
      expect(ok / total, greaterThanOrEqualTo(0.98));
    });
  });
}
