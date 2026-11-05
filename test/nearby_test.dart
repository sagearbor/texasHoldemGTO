import 'dart:math';

import 'package:felt_notes/nearby/ble_payload.dart';
import 'package:felt_notes/nearby/sense.dart';
import 'package:felt_notes/nearby/table_mode_screen.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('advert UUID', () {
    test('game advert round trip', () {
      const a = GameAdvert('ABCD2345', 'WXYZ6789', flags: flagUwb | flagIos);
      final u = advertUuid(a);
      expect(u, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));
      expect(u.replaceAll('-', ''), startsWith(advertUuidPrefix));
      final b = parseAdvertUuid(u.toUpperCase()) as GameAdvert; // iOS prints upper case
      expect(b.nightId, 'ABCD2345');
      expect(b.secret, 'WXYZ6789');
      expect(b.uwb, isTrue);
      expect(b.ios, isTrue);
      expect(b.peerKey, 'H:ABCD2345');
    });

    test('presence advert round trip, every code', () {
      final r = Random(7);
      for (var i = 0; i < 200; i++) {
        final dev = randomCode(r, deviceIdLength), night = randomCode(r, nightIdLength);
        final u = advertUuid(PresenceAdvert(dev, nightTagOf(night)));
        final b = parseAdvertUuid(u) as PresenceAdvert;
        expect(b.deviceId, dev);
        expect(b.nightTag, nightTagOf(night));
        expect(b.flags, 0);
        expect(b.peerKey, 'D:$dev');
        final g = parseAdvertUuid(advertUuid(GameAdvert(night, dev.substring(0, 8)))) as GameAdvert;
        expect(g.nightId, night);
        expect(g.secret, dev.substring(0, 8));
      }
    });

    test('extreme codes fit (all 9s = 31 each)', () {
      final b = parseAdvertUuid(advertUuid(const PresenceAdvert('999999999999', 0xFFFFFF))) as PresenceAdvert;
      expect(b.deviceId, '999999999999');
      expect(b.nightTag, 0xFFFFFF);
    });

    test('anything else is not ours', () {
      expect(parseAdvertUuid('0000180d-0000-1000-8000-00805f9b34fb'), isNull); // heart rate
      expect(parseAdvertUuid('464e5431-9000-0000-0000-000000000000'), isNull); // unknown kind
      expect(parseAdvertUuid('464e5431'), isNull);
      expect(() => advertUuid(const GameAdvert('abcd2345', 'WXYZ6789')), throwsArgumentError);
    });
  });

  group('host name', () {
    test('manufacturer data round trip, cut on a character boundary', () {
      expect(parseNameData(nameData('Sage')), 'Sage');
      final long = nameData('Ångström Überlong Name Here', maxBytes: 10);
      expect(long.length, lessThanOrEqualTo(12));
      expect(parseNameData(long), isNotNull);
      expect(parseNameData([1, 2, 3]), isNull);
      expect(parseNameData(null), isNull);
      expect(localNameFor('  A very long host name '), 'A very long ');
    });
  });

  group('sightings', () {
    final game = advertUuid(const GameAdvert('ABCD2345', 'WXYZ6789'));
    final p1 = advertUuid(PresenceAdvert('AAAAAAAAAAAA', nightTagOf('ABCD2345')));
    BleSighting s(String u, int rssi, int ms, {String? name, int? tx}) =>
        BleSighting(uuids: [u], rssi: rssi, ms: ms, localName: name, txPower: tx);

    test('games: one per night, strongest signal, newest name, old ones dropped', () {
      final g = gamesIn([
        s(game, -80, 1000),
        s(game, -60, 2000, name: 'Sage'),
        s(p1, -40, 2000),
        s(advertUuid(const GameAdvert('ZZZZ2345', 'WXYZ6789')), -50, 10),
      ], sinceMs: 500);
      expect(g, hasLength(1));
      expect(g.single.rssi, -60);
      expect(g.single.hostName, 'Sage');
      expect(g.single.label, "Sage's game");
      expect(g.single.ticket.code, 'ABCD2345-WXYZ6789');
      expect(g.single.ticket.organizerName, 'Sage');
    });

    test('Android name payload wins over a local name; fromMap', () {
      final m = BleSighting.fromMap({
        'u': [game],
        'r': -55,
        't': 5,
        'tx': -7,
        'n': 'Pixel',
        'm': nameData('Sage').toList(),
      })!;
      expect(m.hostName, 'Sage');
      expect(m.txPower, -7);
      expect(BleSighting.fromMap({'u': 'x'}), isNull);
    });

    test('scanPeers groups readings and skips this phone', () {
      final peers = scanPeers([s(game, -60, 1), s(game, -64, 2, tx: -12), s(p1, -70, 3)], selfKey: 'D:AAAAAAAAAAAA');
      expect(peers.keys, ['H:ABCD2345']);
      expect(peers['H:ABCD2345']!.$1, [-60, -64]);
      expect(peers['H:ABCD2345']!.$2, -12);
      final line = scanLine(peers, scanMs: 4000);
      expect(line['scan_ms'], 4000);
      expect((line['peers'] as List).single, {'p': 'H:ABCD2345', 'rssi': [-60, -64], 'tx': -12});
    });
  });

  group('sense window', () {
    test('median per peer, UWB in cm, direction, then empty', () {
      final w = SenseWindow();
      expect(w.isEmpty, isTrue);
      w.addScan({'D:A': ([-60, -70], null), 'H:N': ([-50], -8)}, 1000);
      w.addScan({'D:A': ([-65], null)}, 31000);
      w.addUwb(const UwbSample('D:A', 1.20, 2000, direction: [0, 0, -1]));
      w.addUwb(const UwbSample('D:A', 1.40, 2500, direction: [0, 0, -1]));
      w.addUwb(const UwbSample('D:A', 1.30, 3000));
      final e = w.take(61000, extra: {'fg': true});
      expect(e['w'], 60000);
      expect(e['n'], 2);
      expect(e['p'], [
        ['D:A', -65, 3],
        ['H:N', -50, 1, -8],
      ]);
      expect(e['u'], [
        ['D:A', 130, 3, [0, 0, -100]],
      ]);
      expect(e['fg'], isTrue);
      expect(w.isEmpty, isTrue);
      expect(w.take(70000)['p'], isEmpty);
    });

    test('median, throttle', () {
      expect(median([3, 1, 2]), 2);
      expect(median([4, 1, 2, 3]), 2.5);
      final t = UwbThrottle(gapMs: 1000);
      expect(t.keep(const UwbSample('a', 1, 0)), isTrue);
      expect(t.keep(const UwbSample('a', 1, 500)), isFalse);
      expect(t.keep(const UwbSample('b', 1, 500)), isTrue);
      expect(t.keep(const UwbSample('a', 1, 1000)), isTrue);
    });
  });

  test('seat-finding signals have their own switch (on by default), apart from hands', () {
    final evs = [
      const NightEvent(deviceId: 'D', seq: 1, kind: EventKind.join, ms: 1, data: {'name': 'x'}),
      const NightEvent(deviceId: 'D', seq: 2, kind: EventKind.device, ms: 2),
      const NightEvent(deviceId: 'D', seq: 3, kind: EventKind.sense, ms: 3),
      const NightEvent(deviceId: 'D', seq: 4, kind: EventKind.seat, ms: 4),
    ];
    // Hands private, seat signals on (the defaults): the radar still works.
    expect(cloudEvents(evs, sharing: false), hasLength(4));
    // Seat signals off: only the join, whatever hand sharing says.
    expect(cloudEvents(evs, sharing: false, seat: false).map((e) => e.kind), [EventKind.join]);
    expect(cloudEvents(evs, sharing: true, seat: false).map((e) => e.kind), [EventKind.join]);
    expect(cloudEvents(evs, sharing: true), hasLength(4));
  });

  test('camera flag round trips with the others', () {
    final a = parseAdvertUuid(advertUuid(const PresenceAdvert('AAAAAAAAAAAA', 0, flags: flagCamera | flagIos)))!;
    expect(a.camera, isTrue);
    expect(a.ios, isTrue);
    expect(a.uwb, isFalse);
    final g = parseAdvertUuid(advertUuid(const GameAdvert('ABCD2345', 'WXYZ6789', flags: flagCamera)))!;
    expect(g.camera, isTrue);
    expect(parseAdvertUuid(advertUuid(const GameAdvert('ABCD2345', 'WXYZ6789')))!.camera, isFalse);
  });

  test('battery warning: under 20% and not charging', () {
    expect(batteryWarning(19, false), isTrue);
    expect(batteryWarning(19, null), isTrue);
    expect(batteryWarning(19, true), isFalse);
    expect(batteryWarning(20, false), isFalse);
    expect(batteryWarning(null, false), isFalse);
  });
}
