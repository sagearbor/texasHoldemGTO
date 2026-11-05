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

  testWidgets('radar shapes: Puzzle and Overlap render at 412 dp and 1.3x text, legend says the seat', (t) async {
    t.view.physicalSize = const Size(412, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    RadarSettings.config.value = const RadarConfig(seats: 8, organizerSeat: 0);
    // Readings as the model expects them: phones at slots 2, 4, 6 and 7,
    // the camera at its end.
    const cfg = RadarConfig(seats: 8);
    final lay = layoutTable(cfg);
    const m = RadioModel();
    final at = {'AAAA': 2, 'BBBB': 4, 'CCCC': 6, 'DDDD': 7};
    final links = <RadarLink>[];
    for (final x in at.keys) {
      for (final y in [...at.keys, 'CAM']) {
        if (x == y) continue;
        final py = y == 'CAM' ? lay.camera : lay.slots[at[y]!];
        final r = -60 + m.shape(dist(lay.slots[at[x]!], py));
        links.add(RadarLink(x, y, r.roundToDouble(), 8));
        if (y == 'CAM') links.add(RadarLink(y, x, r.roundToDouble(), 8));
      }
    }
    final input = RadarInput(
        links: links,
        cameras: const {'CAM'},
        names: const {'AAAA': 'Asher', 'BBBB': 'Bartholomew-Long-Name', 'CCCC': 'Cy', 'DDDD': 'Dee'});
    await t.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(412, 1400), textScaler: TextScaler.linear(1.3)),
        child: RadarScreen(live: false, debugInput: input),
      ),
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byType(RadarView), findsOneWidget);
    expect(find.text('Puzzle'), findsOneWidget);
    expect(find.textContaining('seat 3 ·'), findsOneWidget, reason: 'Asher at slot 2 is seat 3');
    expect(find.text('Asher'), findsOneWidget);
    await t.tap(find.text('Overlap'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byType(RadarView), findsOneWidget);
    // A new picture tweens (no exception mid-way).
    await t.tap(find.text('Puzzle'));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
    await t.pumpAndSettle();
    RadarSettings.config.value = const RadarConfig(seats: 6);
  });
}
