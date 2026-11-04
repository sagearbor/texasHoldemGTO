// "Show on the TV": the organizer's sheet offers the browser (Chrome cast /
// AirPlay), the phone's screen cast and the link; each falls back to a
// plain instruction when the native helper is missing.

import 'dart:async';

import 'package:felt_notes/ui/tv/cast/cast_discovery.dart';
import 'package:felt_notes/ui/tv/cast/cast_panel.dart';
import 'package:felt_notes/ui/tv/cast/cast_sender.dart';
import 'package:felt_notes/ui/tv/show_on_tv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _url = 'https://sagearbor.github.io/texasHoldemGTO/#/tv?c=ABC123';
const _code = 'ABCD2345-WXYZ6789';
const _realUrl = 'https://sagearbor.github.io/texasHoldemGTO/#/tv?c=$_code';
const _den = CastDevice(
    id: 'Chromecast-1._googlecast._tcp.local', name: 'PicframeTV den', host: '10.0.0.9', model: 'Chromecast');
const _kitchen = CastDevice(id: 'Chromecast-2._googlecast._tcp.local', name: 'Kitchen', host: '10.0.0.10');

/// Fake Cast: [found] devices, scripted launch result, records calls.
class FakeCast {
  List<CastDevice> found;
  Object? launchError;
  final log = <String>[];
  final Completer<void> launchGate = Completer<void>()..complete();
  FakeCast(this.found);

  CastServices get services => CastServices(
        searchFor: const Duration(milliseconds: 50),
        discover: (t) async* {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          yield* Stream.fromIterable(found);
        },
        show: (d, code, onPhase) async {
          log.add('show ${d.name} $code');
          onPhase(CastPhase.connecting);
          onPhase(CastPhase.launching);
          if (launchError != null) throw launchError!;
          onPhase(CastPhase.done);
          return 'sess';
        },
        stop: (d) async {
          log.add('stop ${d.name}');
          return true;
        },
        multicastLock: (on) async {
          log.add('lock $on');
          return true;
        },
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  String? clip;

  setUp(() {
    calls.clear();
    clip = null;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') clip = (c.arguments as Map)['text'] as String?;
      return null;
    });
  });

  void native(bool answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(tvCastChannel,
        (c) async {
      calls.add(c);
      return answer;
    });
  }

  Future<void> openSheet(WidgetTester tester, {TargetPlatform? platform, String url = _url, CastServices? cast}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => platform == null
              ? Center(child: ShowOnTvButton(url: url))
              : SingleChildScrollView(child: ShowOnTvSheet(url: url, platform: platform, cast: cast)),
        ),
      ),
    ));
    if (platform == null) {
      await tester.tap(find.byKey(const Key('show-on-tv')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('Android: Chrome + Cast, screen cast settings, copy link', (tester) async {
    native(true);
    await openSheet(tester, platform: TargetPlatform.android);
    expect(find.text('Open in Chrome, then ⋮ → Cast…'), findsOneWidget);
    expect(find.text("Cast this phone's screen"), findsOneWidget);
    await tester.tap(find.byKey(const Key('tv-open-browser')));
    await tester.pump();
    expect(calls.single.method, 'openUrl');
    expect((calls.single.arguments as Map)['url'], _url);
    await tester.tap(find.byKey(const Key('tv-cast-screen')));
    await tester.pump();
    expect(calls.last.method, 'castSettings');
    await tester.tap(find.byKey(const Key('tv-copy-link')));
    await tester.pump();
    expect(clip, _url);
    expect(find.text('TV link copied'), findsOneWidget);
  });

  testWidgets('native helper fails: copies the link and says how to cast', (tester) async {
    native(false);
    await openSheet(tester, platform: TargetPlatform.android);
    await tester.tap(find.byKey(const Key('tv-open-browser')));
    await tester.pumpAndSettle();
    expect(clip, _url);
    expect(find.textContaining('link copied'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byKey(const Key('tv-cast-screen')))).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tv-cast-screen')));
    await tester.pumpAndSettle();
    expect(find.text('Swipe down twice from the top → Screen cast'), findsOneWidget);
  });

  testWidgets('iOS: Safari + AirPlay instructions', (tester) async {
    native(true);
    await openSheet(tester, platform: TargetPlatform.iOS);
    expect(find.text('Open in Safari, then AirPlay'), findsOneWidget);
    expect(find.text("AirPlay this phone's screen"), findsOneWidget);
    expect(find.text("Cast this phone's screen"), findsNothing);
    await tester.tap(find.byKey(const Key('tv-open-browser')));
    await tester.pump();
    expect(calls.single.method, 'openUrl');
  });

  testWidgets('the button opens the sheet', (tester) async {
    native(true);
    await openSheet(tester);
    expect(find.text('Show the table on the TV'), findsOneWidget);
    expect(find.byKey(const Key('tv-copy-link')), findsOneWidget);
  });

  group('Cast to a TV', () {
    tearDown(() => activeCast.value = null);

    testWidgets('finds the TVs, casts the code, then offers Stop casting', (tester) async {
      native(true);
      final cast = FakeCast([_kitchen, _den]);
      await openSheet(tester, platform: TargetPlatform.android, url: _realUrl, cast: cast.services);
      expect(find.text('Cast to a TV'), findsOneWidget);
      // The fallbacks stay below.
      expect(find.text("Cast this phone's screen"), findsOneWidget);
      expect(find.byKey(const Key('tv-copy-link')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tv-cast-find')));
      await tester.pump();
      expect(find.text('Looking for TVs…'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Pick the TV'), findsOneWidget);
      expect(cast.log, ['lock true', 'lock false']);
      // Sorted by name.
      final names = tester.widgetList<ListTile>(find.byWidgetPredicate((w) =>
          w is ListTile &&
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('tv-cast-device-')));
      expect(names.map((t) => (t.title as Text).data), ['Kitchen', 'PicframeTV den']);

      await tester.tap(find.text('PicframeTV den'));
      await tester.pumpAndSettle();
      expect(cast.log.last, 'show PicframeTV den $_code');
      expect(find.text('Casting to PicframeTV den'), findsOneWidget);
      expect(activeCast.value?.device.name, 'PicframeTV den');

      await tester.tap(find.byKey(const Key('tv-cast-stop')));
      await tester.pumpAndSettle();
      expect(cast.log.last, 'stop PicframeTV den');
      expect(find.text('Cast to a TV'), findsOneWidget);
      expect(activeCast.value, isNull);
    });

    testWidgets('reopening the sheet remembers the TV it is casting to', (tester) async {
      native(true);
      activeCast.value = const ActiveCast(_den, _code);
      await openSheet(tester, platform: TargetPlatform.android, url: _realUrl, cast: FakeCast([]).services);
      expect(find.text('Casting to PicframeTV den'), findsOneWidget);
      expect(find.byKey(const Key('tv-cast-stop')), findsOneWidget);
    });

    testWidgets('no TV found suggests the screen-cast fallback', (tester) async {
      native(true);
      await openSheet(tester, platform: TargetPlatform.android, url: _realUrl, cast: FakeCast([]).services);
      await tester.tap(find.byKey(const Key('tv-cast-find')));
      await tester.pumpAndSettle();
      expect(find.text('No TV found on this Wi-Fi'), findsOneWidget);
      expect(find.textContaining("Cast this phone's screen\" below"), findsOneWidget);
    });

    testWidgets('a failed launch says why and offers a retry', (tester) async {
      native(true);
      final cast = FakeCast([_den])
        ..launchError = const CastException('The TV would not start Felt Notes (NOT_FOUND).');
      await openSheet(tester, platform: TargetPlatform.android, url: _realUrl, cast: cast.services);
      await tester.tap(find.byKey(const Key('tv-cast-find')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PicframeTV den'));
      await tester.pumpAndSettle();
      expect(find.text('Could not cast to PicframeTV den'), findsOneWidget);
      expect(find.textContaining('NOT_FOUND'), findsOneWidget);
      expect(activeCast.value, isNull);
    });

    testWidgets('not offered on iOS or without a real code', (tester) async {
      native(true);
      await openSheet(tester, platform: TargetPlatform.iOS, url: _realUrl, cast: FakeCast([_den]).services);
      expect(find.text('Cast to a TV'), findsNothing);
      await openSheet(tester, platform: TargetPlatform.android, url: _url, cast: FakeCast([_den]).services);
      expect(find.text('Cast to a TV'), findsNothing);
    });
  });
}
