// Street-by-street equity and the hand of the night (lib/sync/street_equity.dart).

import 'dart:math';

import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart';
import 'package:felt_notes/sync/street_equity.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime(2026, 10, 30, 19).millisecondsSinceEpoch;
int startOf(int n) => t0 + (n - 1) * 120000;

NightEvent ev(String dev, int seq, EventKind k, int ms, [Map<String, Object?> d = const {}]) =>
    NightEvent(deviceId: dev, seq: seq, kind: k, ms: ms, data: d);

void main() {
  test('equityByStreet: KK vs 76s on 7 6 2 9 3 swings from favourite to loser', () {
    final s = equityByStreet([parseCards('Kh Kd'), parseCards('7s 6s')], parseCards('7h 6d 2c 9c 3h'), rng: Random(7));
    expect(s.map((e) => e.street), ['preflop', 'flop', 'turn', 'river']);
    expect(s[0].equity[0], greaterThan(0.75));
    expect(s[1].equity[0], lessThan(0.35)); // two pair against an overpair
    expect(s[3].equity[0], 0); // river: 76 won
    expect(s[3].equity[1], 1);
  });

  test('equityByStreet stops at the streets the board reached', () {
    final s = equityByStreet([parseCards('Kh Kd'), parseCards('7s 6s')], parseCards('7h 6d 2c'));
    expect(s.length, 2);
    expect(s.last.board, parseCards('7h 6d 2c'));
  });

  test('swingLines and handOfTheNight from a merged night with a camera board', () {
    final org = [
      ev('ORG', 1, EventKind.join, t0 - 60000, {'name': 'Sage', 'claim': 'p1', 'offset': 0}),
      ev('ORG', 2, EventKind.seats, t0 - 30000, {
        'seats': [
          ['p1', 'Sage'],
          ['p2', 'John'],
          ['p3', 'Joe']
        ]
      }),
      ev('ORG', 3, EventKind.hand, startOf(1), {'n': 1, 'd': 'p1'}),
      ev('ORG', 4, EventKind.boardRead, startOf(1) + 30000, {
        'c': ['7h', '6d', '2c'],
        'q': [0.9, 0.9, 0.9],
        'u': [0.7, 0.7, 0.7]
      }),
      ev('ORG', 5, EventKind.boardRead, startOf(1) + 60000, {
        'c': ['7h', '6d', '2c', '9c', '3h'],
        'q': [0.9, 0.9, 0.9, 0.9, 0.9],
        'u': [0.7, 0.7, 0.7, 0.7, 0.7]
      }),
      ev('ORG', 6, EventKind.hand, startOf(2), {'n': 2, 'd': 'p2'}),
      ev('ORG', 7, EventKind.end, startOf(3)),
    ];
    final john = [
      ev('JOHN', 1, EventKind.join, t0 - 10000, {'name': 'John', 'claim': 'p2', 'offset': 0}),
      ev('JOHN', 2, EventKind.share, t0 - 9000, {'on': true}),
      ev('JOHN', 3, EventKind.cards, startOf(1) + 10000, {'e': 1, 'c': parseCards('Kh Kd')}),
      ev('JOHN', 4, EventKind.play, startOf(1) + 20000, {'e': 1, 'a': PreAction.raise.name}),
    ];
    final joe = [
      ev('JOE', 1, EventKind.join, t0 - 10000, {'name': 'Joe', 'claim': 'p3', 'offset': 0}),
      ev('JOE', 2, EventKind.share, t0 - 9000, {'on': true}),
      ev('JOE', 3, EventKind.cards, startOf(1) + 10000, {'e': 1, 'c': parseCards('7s 6s')}),
      ev('JOE', 4, EventKind.play, startOf(1) + 20000, {'e': 1, 'a': PreAction.call.name}),
    ];
    final night = mergeNight(
      organizerDeviceId: 'ORG',
      logs: [DeviceLog('ORG', org), DeviceLog('JOHN', john), DeviceLog('JOE', joe)],
    );
    final lines = swingLines(night, rng: Random(3));
    expect(lines.length, 1);
    expect(lines.single.handNo, 1);
    expect(lines.single.text, startsWith('Joe 76s'));
    expect(lines.single.text, contains('vs John KK'));
    expect(lines.single.swing, greaterThan(0.4));
    expect(handOfTheNight(night, rng: Random(3))!.handNo, 1);
  });

  test('no sharers, no board: nothing', () {
    final org = [
      ev('ORG', 1, EventKind.join, t0 - 60000, {'name': 'Sage', 'claim': 'p1', 'offset': 0}),
      ev('ORG', 2, EventKind.hand, startOf(1), {'n': 1, 'd': 'p1'}),
    ];
    final night = mergeNight(organizerDeviceId: 'ORG', logs: [DeviceLog('ORG', org)]);
    expect(swingLines(night), isEmpty);
    expect(handOfTheNight(night), isNull);
  });
}
