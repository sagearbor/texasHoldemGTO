import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/ui/chart_prefs.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:felt_notes/ui/widgets/range_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChartPrefs.colorBlind.value = false;
  });

  Spot threeWay() => lib.cash.firstWhere((s) => s.actions.length == 3);

  Future<void> pump(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: Felt.dark(),
        home: Scaffold(
            appBar: AppBar(actions: const [ChartOptionsMenu()]), body: ListView(children: [w]))));
    await tester.pump();
  }

  Iterable<ActionPatternPainter> painters(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((c) => c.foregroundPainter)
      .whereType<ActionPatternPainter>();

  group('colour-blind charts', () {
    test('setting persists and loads', () async {
      await ChartPrefs.setColorBlind(true);
      expect((await SharedPreferences.getInstance()).getBool(ChartPrefs.colorBlindKey), isTrue);
      ChartPrefs.colorBlind.value = false;
      await ChartPrefs.load();
      expect(ChartPrefs.colorBlind.value, isTrue);
      await ChartPrefs.setColorBlind(false);
      await ChartPrefs.load();
      expect(ChartPrefs.colorBlind.value, isFalse);
    });

    test('colour-blind palette drops red / green', () {
      expect(chartColor('Raise 2.5bb', Brightness.dark), Felt.aggressive);
      expect(chartColor('Raise 2.5bb', Brightness.dark, colorBlind: true), cbAggressive);
      expect(chartColor('Call', Brightness.dark, colorBlind: true), cbCall);
      expect(chartColor('Fold', Brightness.dark, colorBlind: true), Felt.foldDark);
      expect(actionKind('3-bet'), ActionKind.aggressive);
      expect(actionKind('All-in'), ActionKind.aggressive);
    });

    testWidgets('grid, legend and bar get patterns when the setting is on', (tester) async {
      final s = threeWay();
      await pump(
          tester,
          Column(children: [
            RangeGrid(spot: s),
            ActionLegend(spot: s),
            ActionFreqBar(spot: s, hand: HandClass.byIndex(0)),
          ]));
      expect(painters(tester), isEmpty);
      expect(find.text('Call'), findsOneWidget);

      // Toggle through the app-bar menu, like a user would.
      await tester.tap(find.byTooltip('Chart options'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckedPopupMenuItem<String>));
      await tester.pumpAndSettle();
      expect(ChartPrefs.colorBlind.value, isTrue);
      expect((await SharedPreferences.getInstance()).getBool(ChartPrefs.colorBlindKey), isTrue);

      final kinds = painters(tester).map((p) => p.kind).toSet();
      expect(kinds, containsAll([ActionKind.aggressive, ActionKind.call]));
      expect(kinds, isNot(contains(ActionKind.fold)));
      expect(find.text('Call (dots)'), findsOneWidget);
      expect(find.text('Fold (plain)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('explicit patterns flag overrides the setting', (tester) async {
      await pump(tester, RangeGrid(spot: threeWay(), patterns: true));
      expect(painters(tester), isNotEmpty);
    });

    testWidgets('cells have screen-reader labels', (tester) async {
      final handle = tester.ensureSemantics();
      final s = lib.cash.first; // an open-raise spot
      await pump(tester, RangeGrid(spot: s, onTap: (_) {}));
      expect(find.bySemanticsLabel(RegExp(r'^AA: raise .*100%$')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^72o: fold 100%$')), findsOneWidget);
      expect(cellSemantics(s, HandClass.byIndex(0)), startsWith('AA: '));
      handle.dispose();
    });
  });
}
