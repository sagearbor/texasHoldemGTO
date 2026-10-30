// Camera board reads through the night merge (lib/sync/night_merge.dart +
// lib/sync/board_consensus.dart): filing by time, late rivers, fixes,
// hole-card conflicts, and the drama line that a camera board unlocks.

import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/sync/board_consensus.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime(2026, 10, 30, 19).millisecondsSinceEpoch;
const handMs = 120000;
int startOf(int n) => t0 + (n - 1) * handMs;

const sage = Seat('p1', 'Sage'), john = Seat('p2', 'John'), joe = Seat('p3', 'Joe');

class Phone {
  final String id;
  final int offset;
  final List<NightEvent> events = [];
  Phone(this.id, {this.offset = 0});

  NightEvent add(EventKind k, int orgMs, [Map<String, Object?> data = const {}]) {
    final e = NightEvent(deviceId: id, seq: events.length + 1, kind: k, ms: orgMs - offset, data: data);
    events.add(e);
    return e;
  }

  void join(String name, int orgMs, {String? claim}) =>
      add(EventKind.join, orgMs, {'name': name, if (claim != null) 'claim': claim, 'offset': offset});

  /// A street as the camera read it: tokens, all at one confidence.
  void boardRead(int orgMs, String tokens, {double conf = 0.9, double suitConf = 0.6}) {
    final toks = tokens.split(' ');
    add(EventKind.boardRead, orgMs, {
      'c': toks,
      'q': [for (final _ in toks) conf],
      'u': [for (final _ in toks) suitConf],
    });
  }

  void play(int orgMs, PreAction a, {int e = 1}) => add(EventKind.play, orgMs, {'e': e, 'a': a.name});
  void cards(int orgMs, List<int> c, {int e = 1}) => add(EventKind.cards, orgMs, {'e': e, 'c': c});
  DeviceLog get log => DeviceLog(id, List.of(events));
}

Phone organizer({int hands = 3}) {
  final o = Phone('ORG');
  o.join('Sage', t0 - 60000, claim: 'p1');
  o.add(EventKind.seats, t0 - 30000, {
    'seats': [for (final s in [sage, john, joe]) s.toJson()]
  });
  for (var n = 1; n <= hands; n++) {
    o.add(EventKind.hand, startOf(n), {'n': n, 'd': 'p1'});
  }
  o.add(EventKind.end, startOf(hands + 1));
  return o;
}

MergedNight merge(List<Phone> phones, {MergeOptions opts = const MergeOptions()}) =>
    mergeNight(organizerDeviceId: 'ORG', logs: [for (final p in phones) p.log], opts: opts);

void main() {
  test('no reads: every hand has an empty board, nothing crashes', () {
    final m = merge([organizer()]);
    expect(m.hands.every((h) => h.agreedBoard.source == BoardSource.none), isTrue);
    expect(m.hands.every((h) => h.board == null), isTrue);
  });

  test('one phone reads flop, turn and river: the hand gets a camera board', () {
    final o = organizer();
    o.boardRead(startOf(2) + 30000, '7d 9c Kh');
    o.boardRead(startOf(2) + 60000, '7d 9c Kh Kd');
    o.boardRead(startOf(2) + 90000, '7d 9c Kh Kd 2s');
    final m = merge([o]);
    final h = m.hands[1];
    expect(h.agreedBoard.source, BoardSource.camera);
    expect(h.agreedBoard.phones, 1);
    expect(h.board, parseCards('7d 9c Kh Kd 2s'));
    expect(m.hands[0].board, isNull);
    expect(m.hands[2].board, isNull);
    // The organizer's own LoggedHands carry it, so board stats work.
    expect(m.loggedHandsFor('p1')[1].board, parseCards('7d 9c Kh Kd 2s'));
  });

  test('a face card from one phone leaves the board inexact and asking for a tap', () {
    final o = organizer();
    o.boardRead(startOf(1) + 30000, '7d 9c Fh');
    final h = merge([o]).hands[0];
    expect(h.board, isNull);
    expect(h.agreedBoard.tokens, '7d 9c Fh');
    expect(h.agreedBoard.needsConfirm, isTrue);
  });

  test("a player phone's reads are moved onto the organizer clock by its QR offset", () {
    final o = organizer();
    final j = Phone('JOHN', offset: 90000);
    j.join('John', t0 - 10000, claim: 'p2');
    j.boardRead(startOf(2) + 40000, 'Kh 9c 7d'); // seen reversed from across the table
    o.boardRead(startOf(2) + 30000, '7d 9c Kh');
    final m = merge([o, j]);
    expect(m.hands[1].agreedBoard.phones, 2);
    expect(m.hands[1].board, parseCards('7d 9c Kh'));
    expect(m.hands[1].agreedBoard.confidence, greaterThan(0.8));
  });

  test('a river read just after the next "next hand" tap belongs to the hand before', () {
    final o = organizer();
    o.boardRead(startOf(1) + 30000, '7d 9c Kh');
    o.boardRead(startOf(1) + 70000, '7d 9c Kh Kd');
    o.boardRead(startOf(2) + 5000, '7d 9c Kh Kd 2s'); // dealer tapped early
    final m = merge([o]);
    expect(m.hands[0].board, parseCards('7d 9c Kh Kd 2s'));
    expect(m.hands[1].board, isNull);
  });

  test('a flop read early in a hand stays with that hand', () {
    final o = organizer();
    o.boardRead(startOf(1) + 30000, '7d 9c Kh');
    o.boardRead(startOf(2) + 5000, 'As 2d 3c');
    final m = merge([o]);
    expect(m.hands[0].board, parseCards('7d 9c Kh'));
    expect(m.hands[1].board, parseCards('As 2d 3c'));
  });

  test('a one-tap fix from any phone beats the cameras; the organizer call beats both', () {
    final o = organizer();
    final j = Phone('JOHN');
    j.join('John', t0 - 10000, claim: 'p2');
    o.boardRead(startOf(1) + 30000, '7d 9c Fh');
    j.add(EventKind.boardFix, startOf(1) + 50000, {'n': 1, 'c': parseCards('7d 9c Kh')});
    var m = merge([o, j]);
    expect(m.hands[0].agreedBoard.source, BoardSource.fixed);
    expect(m.hands[0].board, parseCards('7d 9c Kh'));
    o.add(EventKind.board, startOf(1) + 60000, {'n': 1, 'c': parseCards('7d 9c Qh')});
    m = merge([o, j]);
    expect(m.hands[0].agreedBoard.source, BoardSource.called);
    expect(m.hands[0].board, parseCards('7d 9c Qh'));
  });

  test('a card a sharing player holds cannot be on the camera board', () {
    final o = organizer();
    final j = Phone('JOHN');
    j.join('John', t0 - 10000, claim: 'p2');
    j.add(EventKind.share, t0 - 9000, {'on': true});
    j.cards(startOf(1) + 10000, parseCards('Kh Kd'));
    j.play(startOf(1) + 20000, PreAction.raise);
    o.boardRead(startOf(1) + 30000, '7d 9c Kh');
    final m = merge([o, j]);
    expect(m.hands[0].agreedBoard.tokens, '7d 9c');
    expect(m.hands[0].agreedBoard.notes.single, contains('Kh'));
  });

  test('malformed reads are ignored', () {
    final o = organizer();
    o.add(EventKind.boardRead, startOf(1) + 30000, {'c': 'not a list'});
    o.add(EventKind.boardRead, startOf(1) + 31000, {'c': ['7d', 'zz', 'Kh']});
    o.add(EventKind.boardRead, startOf(1) + 32000, {'c': ['7d', '9c', 'Kh', '2s', '3s', '4s']});
    final m = merge([o]);
    expect(m.hands[0].agreedBoard.source, BoardSource.none);
  });

  test('a camera board unlocks the bad-beat line', () {
    final o = organizer();
    final j = Phone('JOHN'), k = Phone('JOE');
    j.join('John', t0 - 10000, claim: 'p2');
    k.join('Joe', t0 - 10000, claim: 'p3');
    for (final p in [j, k]) {
      p.add(EventKind.share, t0 - 9000, {'on': true});
    }
    j.cards(startOf(2) + 10000, parseCards('Kh Kd'));
    j.play(startOf(2) + 20000, PreAction.raise);
    k.cards(startOf(2) + 10000, parseCards('7s 6s'));
    k.play(startOf(2) + 20000, PreAction.call);
    o.boardRead(startOf(2) + 30000, '7h 6d 2c');
    o.boardRead(startOf(2) + 60000, '7h 6d 2c 9c');
    o.boardRead(startOf(2) + 90000, '7h 6d 2c 9c 3h');
    final lines = dramaLines(merge([o, j, k]));
    expect(lines.single.kind, 'badBeat');
    expect(lines.single.text, contains('John KK vs Joe 76s'));
  });
}
