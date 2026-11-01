import 'package:felt_notes/nearby/nearby_ui.dart';
import 'package:felt_notes/record/record_screen.dart';
import 'package:felt_notes/ui/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Record the table opens on setup and waits for a lens before it can start', (t) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: RecordScreen()));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Record the table'), findsOneWidget);
    expect(find.text('Players at the table (with you)'), findsOneWidget);
    // No lens: nothing to start yet.
    final start = t.widget<FilledButton>(find.ancestor(
        of: find.text('Check framing, then record'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(start.onPressed, isNull);
    await t.tap(find.byTooltip('More'));
    await t.pump();
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('no nearby game, no card', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: NearbyGameBanner())));
    expect(find.byKey(const Key('nearby-game')), findsNothing);
  });

  test('player name: trimmed, 1 to 24 characters, empty clears', () async {
    expect(AppSettings.normalizePlayerName('  Sage   Arbor '), 'Sage Arbor');
    expect(AppSettings.normalizePlayerName(''), isNull);
    expect(AppSettings.normalizePlayerName('x' * 25), isNull);
    expect(await AppSettings.setPlayerName('Sage'), isTrue);
    expect(AppSettings.playerName.value, 'Sage');
    expect((await SharedPreferences.getInstance()).getString(AppSettings.playerNameKey), 'Sage');
    expect(await AppSettings.setPlayerName('x' * 30), isFalse);
    expect(AppSettings.playerName.value, 'Sage');
    expect(await AppSettings.setPlayerName('  '), isTrue);
    expect(AppSettings.playerName.value, '');
  });
}
