import 'package:felt_notes/settings/dev_settings.dart';
import 'package:felt_notes/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DevSettings.load();
  });

  test('locked by default; switches off; only the right password unlocks', () async {
    expect(DevSettings.unlocked.value, isFalse);
    expect(DevSettings.cardsToCloud, isFalse);
    expect(DevSettings.boardOn, isFalse);
    expect(await DevSettings.unlock('nope'), isFalse);
    expect(DevSettings.unlocked.value, isFalse);
    expect(await DevSettings.unlock('feltnotespw'), isTrue);
    await DevSettings.setCloudCards(true);
    await DevSettings.setBoard(true);
    // Stays unlocked and keeps its switches across a restart.
    await DevSettings.load();
    expect(DevSettings.unlocked.value, isTrue);
    expect(DevSettings.cardsToCloud, isTrue);
    expect(DevSettings.boardOn, isTrue);
  });

  test('a switch left on does nothing while locked', () async {
    SharedPreferences.setMockInitialValues({DevSettings.cloudCardsKey: true});
    await DevSettings.load();
    expect(DevSettings.cloudCards.value, isTrue);
    expect(DevSettings.cardsToCloud, isFalse);
  });

  testWidgets('Settings: the card switch is hidden until the password is entered', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.scrollUntilVisible(find.byKey(const Key('settings-advanced')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('settings-cloud-cards')), findsNothing);
    await tester.tap(find.byKey(const Key('settings-advanced')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dev-password')), 'wrong');
    await tester.tap(find.byKey(const Key('dev-unlock')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.text('Wrong password'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('dev-password')), 'feltnotespw');
    await tester.tap(find.byKey(const Key('dev-unlock')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('settings-cloud-cards')));
    await tester.pumpAndSettle();
    final sw = tester.widget<SwitchListTile>(find.byKey(const Key('settings-cloud-cards')));
    expect(sw.value, isFalse, reason: 'unlocked, but cards still stay on the phone until switched on');
    await tester.tap(find.byKey(const Key('settings-cloud-cards')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(DevSettings.cardsToCloud, isTrue);
    expect(find.byKey(const Key('settings-dev-board')), findsOneWidget);
  });
}
