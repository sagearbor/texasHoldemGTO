// "Show on the TV": the organizer's sheet offers the browser (Chrome cast /
// AirPlay), the phone's screen cast and the link; each falls back to a
// plain instruction when the native helper is missing.

import 'package:felt_notes/ui/tv/show_on_tv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _url = 'https://sagearbor.github.io/texasHoldemGTO/#/tv?c=ABC123';

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

  Future<void> openSheet(WidgetTester tester, {TargetPlatform? platform}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => platform == null
              ? const Center(child: ShowOnTvButton(url: _url))
              : ShowOnTvSheet(url: _url, platform: platform),
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
}
