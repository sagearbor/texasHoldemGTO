import 'package:felt_notes/nearby/ble_payload.dart';
import 'package:felt_notes/nearby/nearby_service.dart' show advertStatusOf;
import 'package:felt_notes/nearby/pulse.dart';
import 'package:felt_notes/radar/radar_model.dart';
import 'package:felt_notes/sync/night_events.dart';
import 'package:felt_notes/sync/night_merge.dart' show DeviceLog;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('advert carries the pulse counter', () {
    test('byte 15, round trip; counter 0 is the old advert exactly', () {
      const old = GameAdvert('ABCD2345', 'WXYZ6789', flags: flagIos);
      final u0 = advertUuid(old);
      expect(u0.replaceAll('-', '').substring(30), '00', reason: 'builds 38-44 send byte 15 = 0');
      final u7 = advertUuid(const GameAdvert('ABCD2345', 'WXYZ6789', flags: flagIos, pulse: 7));
      expect(u7.substring(0, u7.length - 2), u0.substring(0, u0.length - 2), reason: 'only byte 15 changes');
      final b = parseAdvertUuid(u7) as GameAdvert;
      expect((b.nightId, b.secret, b.ios, b.pulse), ('ABCD2345', 'WXYZ6789', true, 7));
      expect((parseAdvertUuid(u0) as GameAdvert).pulse, 0);
      // What an old build sees: the same game (night, secret) either way.
      expect(gamesIn([
        BleSighting(uuids: [u0], rssi: -60, ms: 1),
        BleSighting(uuids: [u7], rssi: -55, ms: 2),
      ]).single.advert.nightId, 'ABCD2345');
    });
  });

  group('build 45 discovery (Nov 5 morning: the son never saw the host)', () {
    test("the owner's two host nights parse and list at every pulse counter, one game each", () {
      for (final night in ['8D78KJ6H', 'Q96XDUG8']) {
        final sightings = [
          for (var c = 0; c < 256; c++)
            BleSighting(
                uuids: [advertUuid(GameAdvert(night, 'WXYZ6789', pulse: c))],
                rssi: -70 + c % 9,
                ms: 1000 + c,
                nameBytes: nameData('Sage')),
        ];
        for (final s in sightings) {
          expect((s.advert as GameAdvert).nightId, night);
        }
        final g = gamesIn(sightings, sinceMs: 0);
        expect(g, hasLength(1), reason: 'keyed by night, not by the raw UUID');
        expect(g.single.label, "Sage's game");
        expect(g.single.ticket.nightId, night);
        // A single sighting with a non-zero counter is enough.
        expect(gamesIn([sightings[200]]), hasLength(1));
      }
    });

    test('advert status for the logs and sense events', () {
      expect(advertStatusOf(null, failed: false), 'none');
      expect(advertStatusOf('u', failed: false), 'ok');
      expect(advertStatusOf('u', failed: true), 'fail');
      expect(advertStatusOf('u', failed: true, code: 2), 'fail:2');
    });
  });

  group('host state machine', () {
    test('at most one pulse per 20 s; a request in the gap waits and starts once', () {
      final h = PulseHost();
      expect(h.counter, 0);
      expect(h.request(1000, 'radar'), isTrue);
      expect(h.counter, 1);
      expect(h.request(5000, 'button'), isFalse, reason: 'within 20 s');
      expect(h.request(6000, 'join'), isFalse);
      expect(h.counter, 1);
      expect(h.dueInMs(6000), 15000);
      expect(h.takePending(20000), isNull, reason: 'still in the gap');
      expect(h.takePending(21000), 'button', reason: 'the first reason waiting');
      expect(h.counter, 2);
      expect(h.takePending(50000), isNull, reason: 'only once');
      expect(h.request(41000, 'button'), isTrue);
      expect(h.counter, 3);
    });

    test('the counter wraps 255 -> 1, never 0', () {
      final h = PulseHost()..counter = 254;
      h.request(0, 'a');
      expect(h.counter, 255);
      h.request(30000, 'b');
      expect(h.counter, 1);
    });
  });

  group('joiner', () {
    test('a new non-zero counter starts a burst, once; a gap between bursts', () {
      final f = PulseFollower();
      expect(f.heard(0, 0), isFalse, reason: 'old host or never pulsed');
      expect(f.heard(3, 1000), isTrue, reason: 'first heard after joining counts');
      expect(f.heard(3, 2000), isFalse, reason: 'same pulse');
      expect(f.heard(4, 10000), isFalse, reason: 'within 20 s of the last burst');
      expect(f.heard(4, 40000), isFalse, reason: 'already seen');
      expect(f.heard(5, 40000), isTrue);
      f.reset();
      expect(f.heard(5, 41000), isTrue, reason: 'a new night');
    });
  });

  group('burst summary', () {
    test('count, median and MAD per peer; the radar reads it like any window', () {
      final b = PulseBurst(4, 1000, why: 'button');
      // About 10 readings a second per pair for 5 s; one outlier (a hand
      // over the phone).
      b.add({
        'D:AAAAAAAAAAAA': ([for (var i = 0; i < 49; i++) -60 + (i % 5) - 2, -80], -7),
        'H:ABCD2345': ([-50, -52, -51], null),
      });
      expect(b.readings, 53);
      final s = b.summary(6000, extra: {'fg': true});
      expect(s['pulse'], 4);
      expect(s['why'], 'button');
      expect(s['w'], 5000);
      expect(s['fg'], isTrue);
      final p = s['p'] as List;
      expect(p.first, ['D:AAAAAAAAAAAA', -60, 50, -7]);
      expect(p.last, ['H:ABCD2345', -51, 3]);
      final m = {for (final x in s['mad'] as List) x[0]: x[1]};
      expect(m['D:AAAAAAAAAAAA'], 10, reason: 'MAD 1 dB (x10), the outlier does not move it');
      expect(m['H:ABCD2345'], 10);
      expect(mad([1, 2, 3, 4, 100]), 1);

      // Into the radar: a pulse event counts with its readings.
      final logs = [
        DeviceLog('BBBBBBBBBBBB', [
          NightEvent(deviceId: 'BBBBBBBBBBBB', seq: 1, kind: EventKind.sense, ms: 6000, data: s),
        ]),
      ];
      final inp = radarInputFrom(logs);
      final l = inp.links.firstWhere((l) => l.to == 'AAAAAAAAAAAA');
      expect((l.rssi, l.n), (-60.0, 50));
    });
  });
}
