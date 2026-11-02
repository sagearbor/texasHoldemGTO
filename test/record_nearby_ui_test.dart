import 'package:felt_notes/nearby/distance_test_screen.dart';
import 'package:felt_notes/nearby/nearby_ui.dart';
import 'package:felt_notes/record/record_screen.dart';
import 'package:felt_notes/ui/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
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

  testWidgets('distance test: distance first and big, Record waits for it', (t) async {
    SharedPreferences.setMockInitialValues({'bt_distance_unit_v1': 'feet'});
    PackageInfo.setMockInitialValues(
        appName: 'Felt Notes', packageName: 'x', version: '0.3.3', buildNumber: '26', buildSignature: '');
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: DistanceTestScreen()));
    await t.pump();
    await t.pump();
    // The just-in-time Bluetooth ask comes first; say not now.
    await t.tap(find.text('Not now'));
    await t.pumpAndSettle();
    expect(find.text('Bluetooth is not allowed.'), findsOneWidget);
    expect(find.text('1. True distance between the phones'), findsOneWidget);
    expect(find.text('3 ft'), findsOneWidget); // the remembered unit
    expect(find.text('Set the distance first'), findsOneWidget);
    await t.tap(find.byTooltip('Farther'));
    await t.pump();
    expect(find.text('3 ft 6 in'), findsOneWidget);
    expect(find.text('Set the distance first'), findsNothing);
    expect(find.text('Export 0 runs'), findsOneWidget);
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
