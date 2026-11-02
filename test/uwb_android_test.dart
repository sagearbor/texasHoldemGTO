import 'package:felt_notes/nearby/ble_payload.dart';
import 'package:felt_notes/nearby/uwb_android.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('controller: the key that sorts first; both phones agree', () {
    expect(isController('D:AAAA', 'D:BBBB'), isTrue);
    expect(isController('D:BBBB', 'D:AAAA'), isFalse);
    expect(isController('D:ZZZZ', 'H:NIGHT'), isTrue); // 'D' < 'H'
  });

  test('peer rotation: at most two at once, never-ranged first, then the oldest', () {
    expect(pickPeers(['c', 'a', 'b'], active: {}, lastRangedMs: {}), ['a', 'b']);
    expect(pickPeers(['a', 'b', 'c'], active: {'a'}, lastRangedMs: {'a': 5}), ['b']);
    expect(pickPeers(['a', 'b', 'c'], active: {'a', 'b'}, lastRangedMs: {}), isEmpty);
    expect(pickPeers(['a', 'b', 'c'], active: {}, lastRangedMs: {'a': 100, 'b': 50}), ['c', 'b']);
    // Every pair gets a turn: simulate rotations.
    final last = <String, int>{};
    final turns = <String>[];
    for (var t = 0; t < 6; t++) {
      for (final p in pickPeers(['a', 'b', 'c', 'd', 'e'], active: {}, lastRangedMs: last, maxSessions: 1)) {
        last[p] = t;
        turns.add(p);
      }
    }
    expect(turns.take(5).toSet(), {'a', 'b', 'c', 'd', 'e'});
  });

  test('the UWB bit on an Android advert, apart from the iPhone one', () {
    final a = parseAdvertUuid(advertUuid(const PresenceAdvert('AAAAAAAAAAAA', 0, flags: flagUwb)))!;
    expect(a.uwb, isTrue);
    expect(a.ios, isFalse); // Android UWB: ranged by Android only
    final i = parseAdvertUuid(advertUuid(const PresenceAdvert('AAAAAAAAAAAA', 0, flags: flagUwb | flagIos)))!;
    expect(i.ios, isTrue); // iPhone NI: never paired with Android
  });

  group('capability', () {
    test('why not, in order', () {
      expect(const UwbCapability().whyNot, 'no UWB hardware');
      expect(const UwbCapability(feature: true, sdk: 30, library: true).whyNot, contains('older than 12'));
      expect(const UwbCapability(feature: true, sdk: 34, library: false).whyNot, 'UWB library missing');
      expect(const UwbCapability(feature: true, sdk: 34, library: true).whyNot, 'UWB permission not granted');
      expect(const UwbCapability(feature: true, sdk: 34, library: true, permission: true, available: false).whyNot,
          'UWB is off or unavailable');
      const ok = UwbCapability(feature: true, sdk: 34, library: true, permission: true, available: true);
      expect(ok.whyNot, isNull);
      expect(ok.usable, isTrue);
      expect(UwbCapability.fromMap({'feature': true, 'sdk': 35, 'lib': true, 'permission': true, 'available': null}).usable,
          isTrue);
      expect(UwbCapability.fromMap(null).hardware, isFalse);
    });
  });

  test('telemetry: minute and night summaries, failure histogram', () {
    final t = UwbTelemetry();
    t.onStage({'stage': 'exchange_start', 'peer': 'D:B'});
    t.onStage({'stage': 'exchange_failed', 'peer': 'D:C', 'why': 'not seen'});
    t.onStage({'stage': 'exchange_failed', 'peer': 'D:C', 'why': 'not seen'});
    t.onStage({'stage': 'session_error', 'peer': 'D:B', 'error': 'UwbSystemCallbackException'});
    t.onStage({'stage': 'first_result', 'peer': 'D:B', 'latency_ms': 900});
    t.onReading('D:B', 1.0);
    t.onReading('D:B', 1.2);
    t.onReading('D:B', 1.4);
    final m = t.takeMinute()!;
    expect(m['n'], 3);
    expect(m['peers'], 1);
    expect((m['fail'] as Map)['exchange_failed: not seen'], 2);
    expect(t.takeMinute(), isNull); // nothing new
    t.capability = const UwbCapability(feature: true, sdk: 34, library: true, permission: true, available: true);
    final n = t.night();
    expect(n['attempted'], 1);
    expect(n['ranged'], 1);
    expect(n['results'], 3);
    expect(n['median_cm'], 120);
    expect(n['first_ms'], 900);
    expect((n['fail'] as Map)['session_error: UwbSystemCallbackException'], 1);
    expect((n['cap'] as Map)['why'], isNull);
  });

  group('fake platform channel', () {
    const ch = MethodChannel('test/uwb');
    final calls = <String>[];
    void handle(Future<Object?> Function(MethodCall c) h) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) {
          calls.add(c.method);
          return h(c);
        });
    setUp(calls.clear);
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null));

    test('success: hardware without permission -> explain -> request -> usable', () async {
      var granted = false;
      handle((c) async {
        switch (c.method) {
          case 'uwbStatus':
            return {'feature': true, 'sdk': 35, 'lib': true, 'permission': granted, 'available': granted ? true : null};
          case 'uwbRequestPermission':
            granted = true;
            return true;
        }
        return null;
      });
      var explained = 0;
      final c = await AndroidUwb(ch).ensurePermission(() async {
        explained++;
        return true;
      });
      expect(explained, 1);
      expect(calls, ['uwbStatus', 'uwbRequestPermission', 'uwbStatus']);
      expect(c.usable, isTrue);
    });

    test('no hardware: no explanation, no prompt', () async {
      handle((c) async => {'feature': false, 'sdk': 35, 'lib': true, 'permission': false});
      final c = await AndroidUwb(ch).ensurePermission(() async => fail('must not ask'));
      expect(calls, ['uwbStatus']);
      expect(c.whyNot, 'no UWB hardware');
    });

    test('old Android: no prompt', () async {
      handle((c) async => {'feature': true, 'sdk': 30, 'lib': true, 'permission': false});
      final c = await AndroidUwb(ch).ensurePermission(() async => fail('must not ask'));
      expect(c.whyNot, contains('older than 12'));
    });

    test('owner says not now: no request', () async {
      handle((c) async => {'feature': true, 'sdk': 35, 'lib': true, 'permission': false});
      final c = await AndroidUwb(ch).ensurePermission(() async => false);
      expect(calls, ['uwbStatus']);
      expect(c.usable, isFalse);
    });

    test('denied by the system', () async {
      handle((c) async => c.method == 'uwbRequestPermission' ? false : {'feature': true, 'sdk': 35, 'lib': true, 'permission': false});
      final c = await AndroidUwb(ch).ensurePermission(() async => true);
      expect(c.whyNot, 'UWB permission not granted');
    });

    test('UWB switched off (isAvailable false)', () async {
      handle((c) async => {'feature': true, 'sdk': 35, 'lib': true, 'permission': true, 'available': false});
      final c = await AndroidUwb(ch).capability();
      expect(c.usable, isFalse);
      expect(c.whyNot, 'UWB is off or unavailable');
    });

    test('a native exception or a missing native side degrades to "no UWB"', () async {
      handle((c) async => throw PlatformException(code: 'uwb', message: 'boom'));
      expect((await AndroidUwb(ch).capability()).hardware, isFalse);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
      expect((await AndroidUwb(ch).capability()).hardware, isFalse); // MissingPluginException
      await AndroidUwb(ch).range('u', 'D:X'); // no throw
    });
  });
}
