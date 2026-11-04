// Cast to a TV: the hand-written CASTV2 codec, mDNS TXT parsing, and the
// launch / stop state machines against a fake Chromecast.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:felt_notes/ui/tv/cast/cast_discovery.dart';
import 'package:felt_notes/ui/tv/cast/cast_message.dart';
import 'package:felt_notes/ui/tv/cast/cast_sender.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake Cast device: decodes what the sender writes and lets the test
/// script replies.
class FakeDevice implements CastSocket {
  final _in = StreamController<List<int>>();
  final _decoder = CastFrameDecoder();
  final sent = <CastMessage>[];
  bool closed = false;
  void Function(FakeDevice d, CastMessage m)? onMessage;

  FakeDevice([this.onMessage]);

  @override
  Stream<List<int>> get input => _in.stream;

  @override
  void add(List<int> bytes) {
    for (final m in _decoder.add(bytes)) {
      sent.add(m);
      onMessage?.call(this, m);
    }
  }

  void reply(String source, String namespace, Map<String, Object?> body, {String dest = 'sender-0'}) {
    final f = CastMessage.json(source, dest, namespace, body).frame();
    // Split the frame in two to exercise the decoder.
    scheduleMicrotask(() {
      _in.add(f.sublist(0, 3));
      _in.add(f.sublist(3));
    });
  }

  @override
  Future<void> close() async {
    closed = true;
    await _in.close();
  }

  List<CastMessage> on(String ns) => sent.where((m) => m.namespace == ns).toList();
}

Map<String, Object?> status(List<Map<String, Object?>> apps, {int requestId = 0}) => {
      'type': 'RECEIVER_STATUS',
      'requestId': requestId,
      'status': {
        'applications': apps,
        'volume': {'level': 1.0}
      },
    };

Map<String, Object?> ourApp({bool withNs = true, String transport = 'web-7'}) => {
      'appId': feltNotesCastAppId,
      'displayName': 'Felt Notes TV',
      'sessionId': 'sess-1',
      'transportId': transport,
      'namespaces': [
        {'name': 'urn:x-cast:com.google.cast.debugoverlay'},
        if (withNs) {'name': nsFeltNotes},
      ],
    };

void main() {
  group('CastMessage codec', () {
    test('encodes the exact protobuf bytes', () {
      const m = CastMessage(sourceId: 's', destinationId: 'd', namespace: 'n', payloadUtf8: '{}');
      expect(m.encode(), [
        0x08, 0x00, // protocol_version
        0x12, 1, 0x73, // source_id "s"
        0x1A, 1, 0x64, // destination_id "d"
        0x22, 1, 0x6E, // namespace "n"
        0x28, 0x00, // payload_type STRING
        0x32, 2, 0x7B, 0x7D, // payload_utf8 "{}"
      ]);
      final f = m.frame();
      expect(f.sublist(0, 4), [0, 0, 0, 17]);
      expect(f.length, 21);
    });

    test('round-trips long payloads (multi-byte varint lengths)', () {
      final big = {'code': 'X' * 300, 'type': 'BIG'};
      final m = CastMessage.json('sender-0', 'web-7', nsFeltNotes, big);
      final back = CastMessage.decode(m.encode());
      expect(back.sourceId, 'sender-0');
      expect(back.destinationId, 'web-7');
      expect(back.namespace, nsFeltNotes);
      expect(back.json, big);
      expect(back.type, 'BIG');
    });

    test('binary payloads and unknown fields', () {
      const m = CastMessage(sourceId: 'a', destinationId: 'b', namespace: 'c', payloadBinary: [1, 2, 3]);
      final bytes = [...m.encode(), 0x40, 0x05, 0x4D, 1, 2, 3, 4]; // field 8 varint, field 9 fixed32
      final back = CastMessage.decode(bytes);
      expect(back.payloadBinary, [1, 2, 3]);
      expect(back.payloadUtf8, isNull);
      expect(back.json, isNull);
    });

    test('rejects truncated data', () {
      final bytes = CastMessage.json('a', 'b', 'c', {'x': 1}).encode();
      expect(() => CastMessage.decode(bytes.sublist(0, bytes.length - 2)), throwsFormatException);
    });

    test('the frame decoder handles split and joined frames', () {
      final a = CastMessage.json('a', 'b', 'c', {'n': 1}).frame();
      final b = CastMessage.json('a', 'b', 'c', {'n': 2}).frame();
      final all = Uint8List.fromList([...a, ...b]);
      final d = CastFrameDecoder();
      final got = <CastMessage>[];
      for (var i = 0; i < all.length; i += 5) {
        got.addAll(d.add(all.sublist(i, (i + 5).clamp(0, all.length))));
      }
      expect(got.map((m) => m.json?['n']), [1, 2]);
      expect(CastFrameDecoder().add(all).length, 2);
    });

    test('a huge length prefix is a broken stream', () {
      expect(() => CastFrameDecoder().add([0x7F, 0, 0, 0, 1]), throwsFormatException);
    });
  });

  group('discovery parsing', () {
    test('TXT records and names', () {
      final txt = parseCastTxt('id=4f2c\ncd=AB\nmd=Chromecast\nfn=PicframeTV den ChrmCast\nca=201221\n');
      expect(txt['fn'], 'PicframeTV den ChrmCast');
      expect(txt['md'], 'Chromecast');
      expect(castDeviceName('Chromecast-4f2c._googlecast._tcp.local', txt), 'PicframeTV den ChrmCast');
      expect(castDeviceName('Chromecast-4f2c._googlecast._tcp.local', {}), 'Chromecast-4f2c');
      expect(castDeviceName('', {'md': 'Google TV'}), 'Google TV');
    });
  });

  group('castShowCode', () {
    test('connects, launches, waits for the namespace, sends the code, lets go', () async {
      final phases = <CastPhase>[];
      final dev = FakeDevice((d, m) {
        if (m.namespace == nsReceiver && m.type == 'LAUNCH') {
          final id = m.json!['requestId'] as int;
          // Starting: no transport yet, then up without our namespace,
          // then the page has registered it.
          d.reply('receiver-0', nsReceiver, status([], requestId: id));
          d.reply('receiver-0', nsReceiver, status([ourApp(withNs: false)]));
          d.reply('receiver-0', nsReceiver, status([ourApp()]));
        }
      });
      final session = await castShowCode(
        host: '10.0.0.5',
        port: 8009,
        code: 'ABCD2345-WXYZ6789',
        connector: (h, p) async {
          expect((h, p), ('10.0.0.5', 8009));
          return dev;
        },
        onPhase: phases.add,
        heartbeat: Duration.zero,
        settle: Duration.zero,
      );
      expect(session, 'sess-1');
      expect(phases, [CastPhase.connecting, CastPhase.launching, CastPhase.sending, CastPhase.done]);

      final conn = dev.on(nsConnection);
      expect(conn.map((m) => (m.destinationId, m.type)), [('receiver-0', 'CONNECT'), ('web-7', 'CONNECT')]);
      final launch = dev.on(nsReceiver).single;
      expect(launch.json, {'type': 'LAUNCH', 'appId': '2537B496', 'requestId': 1});
      final code = dev.on(nsFeltNotes).single;
      expect(code.destinationId, 'web-7');
      expect(code.sourceId, 'sender-0');
      expect(jsonDecode(code.payloadUtf8!), {'code': 'ABCD2345-WXYZ6789'});
      // The code goes after the app CONNECT.
      expect(dev.sent.indexOf(code), greaterThan(dev.sent.indexOf(conn.last)));
      // No STOP, no CLOSE: the receiver keeps running.
      expect(dev.sent.where((m) => m.type == 'STOP' || m.type == 'CLOSE'), isEmpty);
      expect(dev.closed, isTrue);
    });

    test('a receiver that never lists the namespace still gets the code after the grace', () async {
      final dev = FakeDevice((d, m) {
        if (m.type == 'LAUNCH' || m.type == 'GET_STATUS') {
          d.reply('receiver-0', nsReceiver, status([ourApp(withNs: false, transport: 't-2')]));
        }
      });
      await castShowCode(
          host: 'h',
          port: 1,
          code: 'C0DE',
          connector: (_, __) async => dev,
          heartbeat: Duration.zero,
          settle: Duration.zero,
          namespaceGrace: const Duration(milliseconds: 20));
      expect(dev.on(nsFeltNotes).single.destinationId, 't-2');
    });

    test('LAUNCH_ERROR is reported', () async {
      final dev = FakeDevice((d, m) {
        if (m.type == 'LAUNCH') d.reply('receiver-0', nsReceiver, {'type': 'LAUNCH_ERROR', 'reason': 'NOT_FOUND'});
      });
      await expectLater(
        castShowCode(host: 'h', port: 1, code: 'C', connector: (_, __) async => dev, heartbeat: Duration.zero),
        throwsA(isA<CastException>().having((e) => e.message, 'message', contains('registered in the Cast console'))),
      );
      expect(dev.on(nsFeltNotes), isEmpty);
      expect(dev.closed, isTrue);
    });

    test('a silent TV times out', () async {
      final dev = FakeDevice();
      await expectLater(
        castShowCode(
            host: 'h',
            port: 1,
            code: 'C',
            connector: (_, __) async => dev,
            heartbeat: Duration.zero,
            launchTimeout: const Duration(milliseconds: 30)),
        throwsA(isA<CastException>()),
      );
      expect(dev.closed, isTrue);
    });

    test('an unreachable TV', () async {
      await expectLater(
        castShowCode(host: 'h', port: 1, code: 'C', connector: (_, __) async => throw Exception('refused')),
        throwsA(isA<CastException>().having((e) => e.message, 'message', contains('Could not reach'))),
      );
    });

    test('answers PING with PONG and sends its own PINGs', () async {
      final dev = FakeDevice((d, m) {
        if (m.type == 'LAUNCH') {
          d.reply('receiver-0', nsHeartbeat, {'type': 'PING'});
          Timer(const Duration(milliseconds: 40), () => d.reply('receiver-0', nsReceiver, status([ourApp()])));
        }
      });
      await castShowCode(
          host: 'h',
          port: 1,
          code: 'C',
          connector: (_, __) async => dev,
          heartbeat: const Duration(milliseconds: 10),
          settle: Duration.zero);
      final beats = dev.on(nsHeartbeat);
      expect(beats.where((m) => m.type == 'PONG').single.destinationId, 'receiver-0');
      expect(beats.where((m) => m.type == 'PING'), isNotEmpty);
    });
  });

  group('castStop', () {
    test('stops our session', () async {
      final dev = FakeDevice((d, m) {
        if (m.type == 'GET_STATUS') d.reply('receiver-0', nsReceiver, status([ourApp()]));
        if (m.type == 'STOP') d.reply('receiver-0', nsReceiver, status([]));
      });
      expect(await castStop(host: 'h', port: 1, connector: (_, __) async => dev, heartbeat: Duration.zero), isTrue);
      final stop = dev.sent.singleWhere((m) => m.type == 'STOP');
      expect(stop.destinationId, 'receiver-0');
      expect(stop.json!['sessionId'], 'sess-1');
      expect(dev.closed, isTrue);
    });

    test('nothing to stop when another app is on the TV', () async {
      final dev = FakeDevice((d, m) {
        if (m.type == 'GET_STATUS') {
          d.reply(
              'receiver-0',
              nsReceiver,
              status([
                {'appId': 'E8C28D3C', 'sessionId': 'x', 'transportId': 'y', 'namespaces': []}
              ]));
        }
      });
      expect(await castStop(host: 'h', port: 1, connector: (_, __) async => dev, heartbeat: Duration.zero), isFalse);
      expect(dev.sent.where((m) => m.type == 'STOP'), isEmpty);
    });
  });
}
