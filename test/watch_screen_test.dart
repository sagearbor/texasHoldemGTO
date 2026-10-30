import 'package:felt_notes/camera/watch_screen.dart';
import 'package:felt_notes/camera/watch_tracker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Host implements WatchHost {
  @override
  final WatchHandTracker watchTracker = WatchHandTracker();
  @override
  int get watchHandNumber => 1;
  @override
  void watchSetCards(List<int> cards) {}
  @override
  bool watchNewHand(List<int> cards, {int? episode, int? scene}) => true;
  @override
  void watchNextHand() {}
  @override
  Future<void> watchFixCards(BuildContext context) async {}
}

void main() {
  testWidgets('setup screen: instructions, voice on by default, no camera in tests', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await WatchSettings.load();
    await tester.pumpWidget(MaterialApp(home: WatchScreen(host: _Host())));
    // The camera lookup fails (no plugin in tests); let it finish.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.text('Watch my cards'), findsOneWidget);
    expect(find.textContaining('Prop the phone up'), findsOneWidget);
    expect(find.textContaining('Camera unavailable'), findsOneWidget);
    expect(WatchSettings.voice.value, isTrue);
    await tester.scrollUntilVisible(find.text('Start watching'), 200);
    // No camera: Start stays disabled.
    final start = tester.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('Start watching'), matching: find.bySubtype<ButtonStyleButton>()));
    expect(start.onPressed, isNull);
  });
}
