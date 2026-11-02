import 'package:felt_notes/radar/radar_model.dart';
import 'package:felt_notes/radar/radar_screen.dart';
import 'package:felt_notes/radar/radar_settings.dart';
import 'package:felt_notes/radar/radar_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RadarSettings.config.value = const RadarConfig(seats: 6);
  });

  testWidgets('radar screen: count and ends on top, offline state without data', (t) async {
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: RadarScreen(live: false)));
    await t.pumpAndSettle();
    expect(find.text('Seat radar'), findsOneWidget);
    expect(find.byKey(const Key('radar-count')), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(find.text('Offline: distance from you only'), findsOneWidget);
    await t.tap(find.byKey(const Key('radar-more')));
    await t.pumpAndSettle();
    expect(find.text('7'), findsOneWidget);
    expect(RadarSettings.config.value.seats, 7);
    await t.tap(find.text('2 corners').first);
    await t.pumpAndSettle();
    expect(RadarSettings.config.value.leftEndSeats, 2);
    // The setup sheet.
    await t.tap(find.byTooltip('Table setup'));
    await t.pumpAndSettle();
    expect(find.text('Table setup (once)'), findsOneWidget);
    await t.tap(find.text('Rectangle'));
    await t.pumpAndSettle();
    expect(RadarSettings.config.value.shape, TableShape.rectangle);
  });

  testWidgets('radar view and legend: colours, names, tap for readings', (t) async {
    const cfg = RadarConfig(seats: 6);
    final lay = layoutTable(cfg);
    final est = RadarEstimate(lay, {
      'A': [0.8, 0.2, 0, 0, 0, 0],
      'B': [0, 0, 0, 0.5, 0.5, 0],
    }, organizerSlot: null);
    String? tapped;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          RadarView(estimate: est, names: const {'A': 'Asher', 'B': 'Bea'}, colours: radarColours(['A', 'B'])),
          RadarLegend(
              estimate: est,
              names: const {'A': 'Asher', 'B': 'Bea'},
              colours: radarColours(['A', 'B']),
              stale: const {'B'},
              onTap: (p) => tapped = p),
        ]),
      ),
    ));
    expect(find.text('Asher'), findsOneWidget);
    expect(find.textContaining('Bea'), findsOneWidget);
    expect(find.textContaining('left?'), findsOneWidget);
    expect(find.text('seat 1 · 80%'), findsOneWidget);
    await t.tap(find.byKey(const Key('radar-phone-A')));
    expect(tapped, 'A');
    expect(radarColours(['B', 'A'])['A'], radarPalette.first);
    expect(est.occupancy(2), 0);
  });
}
