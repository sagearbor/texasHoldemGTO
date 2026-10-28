import 'dart:math';

import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/homegame/my_result.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/app_settings.dart';
import 'package:felt_notes/ui/chart_prefs.dart';
import 'package:felt_notes/ui/screens/about_screen.dart';
import 'package:felt_notes/ui/screens/charts_screen.dart';
import 'package:felt_notes/ui/screens/daily_screen.dart';
import 'package:felt_notes/ui/screens/dashboard_screen.dart';
import 'package:felt_notes/ui/screens/equity_screen.dart';
import 'package:felt_notes/ui/screens/help_screen.dart';
import 'package:felt_notes/ui/screens/home_game_screen.dart';
import 'package:felt_notes/ui/screens/review_sheet.dart';
import 'package:felt_notes/ui/screens/settings_screen.dart';
import 'package:felt_notes/ui/screens/stats_screen.dart';
import 'package:felt_notes/ui/screens/train_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:felt_notes/ui/widgets/playing_card.dart';
import 'package:felt_notes/ui/widgets/range_grid.dart';
import 'package:felt_notes/ui/widgets/solver_dice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ------------------------------------------------------------ contrast

/// WCAG relative luminance.
double _lum(Color c) {
  double lin(int v) {
    final s = v / 255;
    return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue);
}

/// WCAG contrast ratio of two opaque colours (1..21).
double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The colour painted behind [element]: the nearest opaque Material /
/// ColoredBox / Container / DecoratedBox ancestor, with any translucent
/// layers above it blended in.
Color backgroundOf(Element element) {
  final layers = <Color>[];
  Color? base;
  void consider(Color? c) {
    if (c == null || base != null) return;
    if (c.alpha == 255) {
      base = c;
    } else if (c.alpha > 0) {
      layers.add(c);
    }
  }

  element.visitAncestorElements((e) {
    final w = e.widget;
    if (w is Material && w.type != MaterialType.transparency) consider(w.color);
    if (w is ColoredBox) consider(w.color);
    if (w is DecoratedBox && w.decoration is BoxDecoration) {
      consider((w.decoration as BoxDecoration).color);
    }
    return base == null;
  });
  var c = base ?? Colors.white;
  for (final l in layers.reversed) {
    c = Color.alphaBlend(l, c);
  }
  return c;
}

/// Rendered colour of the text found by [f], and its background.
(Color, Color) textColors(WidgetTester tester, Finder f) {
  final rich = find.descendant(of: f, matching: find.byType(RichText)).evaluate().isNotEmpty
      ? find.descendant(of: f, matching: find.byType(RichText)).first
      : f;
  final p = tester.renderObject<RenderParagraph>(rich);
  final fg = p.text.style!.color!;
  final bg = backgroundOf(tester.element(rich));
  return (Color.alphaBlend(fg, bg), bg);
}

void expectReadable(WidgetTester tester, Finder f, {double min = 4.5, String? why}) {
  final (fg, bg) = textColors(tester, f);
  final r = contrast(fg, bg);
  expect(r, greaterThanOrEqualTo(min),
      reason: '${why ?? f.toString()}: $fg on $bg = ${r.toStringAsFixed(2)}:1');
}

void expectIconVisible(WidgetTester tester, Finder icon, {double min = 3, String? why}) {
  final w = tester.widget<Icon>(icon);
  final bg = backgroundOf(tester.element(icon));
  final fg = Color.alphaBlend(w.color ?? IconTheme.of(tester.element(icon)).color!, bg);
  final r = contrast(fg, bg);
  expect(r, greaterThanOrEqualTo(min),
      reason: '${why ?? icon.toString()}: $fg on $bg = ${r.toStringAsFixed(2)}:1');
}

// ------------------------------------------------------------------ tests

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({'seen_welcome_v1': true});
    AppSettings.resetMemory();
    ChartPrefs.colorBlind.value = false;
  });

  group('AppSettings', () {
    test('defaults keep the original look', () async {
      await AppSettings.load();
      expect(AppSettings.theme.value, ThemeChoice.dark);
      expect(AppSettings.cardStyle.value, CardStyle.fourColor);
      expect(AppSettings.solverDice.value, isTrue);
      expect(AppSettings.currency.value, '\$');
      expect(themeModeFor(AppSettings.theme.value), ThemeMode.dark);
    });

    test('every setting persists and loads', () async {
      await AppSettings.setTheme(ThemeChoice.light);
      await AppSettings.setCardStyle(CardStyle.twoColor);
      await AppSettings.setSolverDice(false);
      expect(await AppSettings.setCurrency(' € '), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppSettings.themeKey), 'light');
      expect(prefs.getString(AppSettings.cardStyleKey), 'twoColor');
      expect(prefs.getBool(AppSettings.solverDiceKey), isFalse);
      expect(prefs.getString(AppSettings.currencyKey), '€');

      AppSettings.resetMemory();
      await AppSettings.load();
      expect(AppSettings.theme.value, ThemeChoice.light);
      expect(AppSettings.cardStyle.value, CardStyle.twoColor);
      expect(AppSettings.solverDice.value, isFalse);
      expect(AppSettings.currency.value, '€');
    });

    test('bad stored values fall back to defaults', () async {
      SharedPreferences.setMockInitialValues({
        AppSettings.themeKey: 'neon',
        AppSettings.cardStyleKey: 'x',
        AppSettings.currencyKey: '12345',
      });
      await AppSettings.load();
      expect(AppSettings.theme.value, ThemeChoice.dark);
      expect(AppSettings.cardStyle.value, CardStyle.fourColor);
      expect(AppSettings.currency.value, '\$');
    });

    test('currency validation', () async {
      expect(AppSettings.normalizeCurrency('kr'), 'kr');
      expect(AppSettings.normalizeCurrency('CHF'), 'CHF');
      expect(AppSettings.normalizeCurrency('₹'), '₹');
      for (final bad in ['', '   ', 'EURO', '1', '\$1', '-', 'a b', null, 3]) {
        expect(AppSettings.normalizeCurrency(bad), isNull, reason: '$bad');
      }
      expect(await AppSettings.setCurrency('dollars'), isFalse);
      expect(AppSettings.currency.value, '\$');
    });

    test('theme choice maps to ThemeMode', () {
      expect(themeModeFor(ThemeChoice.system), ThemeMode.system);
      expect(themeModeFor(ThemeChoice.light), ThemeMode.light);
      expect(themeModeFor(ThemeChoice.dark), ThemeMode.dark);
    });

    test('My result uses the chosen currency', () async {
      expect(moneyLabel(40), '\$40');
      await AppSettings.setCurrency('€');
      expect(moneyLabel(12.5, signed: true), '+€12.50');
      expect(moneyLabel(-3), '-€3');
      expect(moneyLabel(3, symbol: ''), '3');
      expect(parseMoney('€40'), 40);
      expect(parseMoney('\$1,200'), 1200);
      await AppSettings.setCurrency('kr');
      expect(parseMoney('kr 15'), 15);
    });

    test('suit colours: 4-colour vs classic', () {
      expect(suitColor(0, CardStyle.fourColor), Felt.fourColorSuits[0]);
      expect(suitColor(1, CardStyle.fourColor), Felt.fourColorSuits[1]);
      expect(suitColor(0, CardStyle.twoColor), Felt.suitBlack);
      expect(suitColor(1, CardStyle.twoColor), Felt.suitRed);
      expect(suitColor(2, CardStyle.twoColor), Felt.suitRed);
      expect(suitColor(3, CardStyle.twoColor), Felt.suitBlack);
    });

    test('reset all data resets settings in memory', () async {
      await AppSettings.setTheme(ThemeChoice.light);
      await AppSettings.setCurrency('£');
      await ChartPrefs.setColorBlind(true);
      await resetAllData();
      expect(AppSettings.theme.value, ThemeChoice.dark);
      expect(AppSettings.currency.value, '\$');
      expect(ChartPrefs.colorBlind.value, isFalse);
    });
  });

  group('widgets honour settings', () {
    Color diamondColor(WidgetTester tester) {
      final f = find.descendant(
          of: find.byType(PlayingCard), matching: find.text(suitSymbols[1]));
      return tester.widget<Text>(f).style!.color!;
    }

    testWidgets('PlayingCard follows the deck style live', (tester) async {
      await tester.pumpWidget(MaterialApp(
          theme: Felt.light(),
          home: Scaffold(body: PlayingCard(card: makeCard(12, 1)))));
      expect(diamondColor(tester), Felt.fourColorSuits[1]);
      await AppSettings.setCardStyle(CardStyle.twoColor);
      await tester.pump();
      expect(diamondColor(tester), Felt.suitRed);
    });

    testWidgets('card picker uses the deck style', (tester) async {
      await AppSettings.setCardStyle(CardStyle.twoColor);
      await tester.pumpWidget(MaterialApp(
          theme: Felt.light(),
          home: Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () => pickCard(c, {}), child: const Text('pick'))))));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      final club = tester.widget<Text>(find.text('A${suitSymbols[0]}'));
      expect(club.style!.color, Felt.suitBlack);
      final diamond = tester.widget<Text>(find.text('A${suitSymbols[1]}'));
      expect(diamond.style!.color, Felt.suitRed);
    });

    testWidgets('solver dice can be hidden', (tester) async {
      final spot = lib.cash.firstWhere(
          (s) => allHandClasses.any((h) => SolverDice.applies(s, h)));
      final hand = allHandClasses.firstWhere((h) => SolverDice.applies(spot, h));
      Future<void> show() async {
        await tester.pumpWidget(MaterialApp(
            theme: Felt.dark(),
            home: Scaffold(
                body: SingleChildScrollView(
                    child: CoachPanel(spot: spot, hand: hand, chosen: 0, roll: 42)))));
      }

      await show();
      expect(find.byType(SolverDice), findsOneWidget);
      await AppSettings.setSolverDice(false);
      await tester.pump();
      expect(find.byType(SolverDice), findsNothing);
    });
  });

  group('settings screen', () {
    Future<(TrainerModel, HomeGameModel)> models(WidgetTester tester) async {
      final t = TrainerModel(lib);
      final h = HomeGameModel(lib);
      await tester.runAsync(() => Future.wait([t.load(), h.load()]));
      return (t, h);
    }

    Future<void> pumpApp(WidgetTester tester, Widget home,
        {required TrainerModel t, required HomeGameModel h, ThemeMode? mode}) async {
      tester.view.physicalSize = const Size(360 * 3, 760 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ValueListenableBuilder<ThemeChoice>(
        valueListenable: AppSettings.theme,
        builder: (_, c, __) => MaterialApp(
          theme: Felt.light(),
          darkTheme: Felt.dark(),
          themeMode: mode ?? themeModeFor(c),
          builder: (_, child) => AppScope(trainer: t, home: h, child: child!),
          home: home,
        ),
      ));
      await tester.pumpAndSettle();
    }

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('renders at 360px without overflow (${mode.name})', (tester) async {
        final (t, h) = await models(tester);
        await pumpApp(tester, const SettingsScreen(), t: t, h: h, mode: mode);
        for (final s in ['Appearance', 'Trainer', 'Home game', 'Data']) {
          await tester.scrollUntilVisible(find.text(s), 100,
              scrollable: find.byType(Scrollable).first);
          expect(find.text(s), findsOneWidget);
          expectReadable(tester, find.text(s), why: 'section $s');
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('changes apply and persist', (tester) async {
      final (t, h) = await models(tester);
      await pumpApp(tester, const SettingsScreen(), t: t, h: h);
      expect(Theme.of(tester.element(find.text('Appearance'))).brightness,
          Brightness.dark);

      await tester.tap(find.byKey(const Key('theme-light')));
      await tester.pumpAndSettle();
      expect(AppSettings.theme.value, ThemeChoice.light);
      expect(Theme.of(tester.element(find.text('Appearance'))).brightness,
          Brightness.light);

      await tester.tap(find.byKey(const Key('settings-colorblind')));
      await tester.tap(find.byKey(const Key('cards-twoColor')));
      await tester.pumpAndSettle();
      expect(ChartPrefs.colorBlind.value, isTrue);
      expect(AppSettings.cardStyle.value, CardStyle.twoColor);

      await tester.ensureVisible(find.byKey(const Key('difficulty-expert')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('difficulty-expert')));
      await tester.pumpAndSettle();
      expect(t.difficulty, Difficulty.expert);

      await tester.ensureVisible(find.byKey(const Key('settings-dice')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-dice')));
      await tester.pumpAndSettle();
      expect(AppSettings.solverDice.value, isFalse);

      await tester.ensureVisible(find.byKey(const Key('delay-30')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delay-30')));
      await tester.pumpAndSettle();
      expect(h.dashboardDelayMinutes, 30);

      await tester.ensureVisible(find.byKey(const Key('currency-£')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('currency-£')));
      await tester.pumpAndSettle();
      expect(AppSettings.currency.value, '£');
      expect(find.text('Example: +£42.50'), findsOneWidget);

      // Custom symbol through the dialog; an invalid one is refused.
      await tester.tap(find.byKey(const Key('currency-other')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('currency-field')), '12');
      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();
      expect(AppSettings.currency.value, '£');
      await tester.tap(find.byKey(const Key('currency-other')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('currency-field')), 'CHF');
      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();
      expect(AppSettings.currency.value, 'CHF');

      await tester.runAsync(() async {
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(AppSettings.themeKey), 'light');
        expect(prefs.getString(AppSettings.cardStyleKey), 'twoColor');
        expect(prefs.getBool(AppSettings.solverDiceKey), isFalse);
        expect(prefs.getString(AppSettings.currencyKey), 'CHF');
        expect(prefs.getBool(ChartPrefs.colorBlindKey), isTrue);
        expect(prefs.getString('trainer_difficulty_v1'), 'expert');
        expect(prefs.getInt('dashboard_delay_min'), 30);
      });

      await tester.ensureVisible(find.byKey(const Key('settings-data')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-data')));
      await tester.pumpAndSettle();
      expect(find.text('About & privacy'), findsOneWidget);
      expect(find.byType(AboutScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reachable from Help (top entry) and About (gear)', (tester) async {
      PackageInfo.setMockInitialValues(
          appName: 'Felt Notes',
          packageName: 'com.sagearbor.feltnotes.app',
          version: '0.1.2',
          buildNumber: '5',
          buildSignature: '');
      final (t, h) = await models(tester);
      await pumpApp(tester, const HelpScreen(), t: t, h: h);
      final top = tester.getTopLeft(find.byKey(const Key('help-settings'))).dy;
      expect(top, lessThan(tester.getTopLeft(find.text('Train').first).dy));
      await tester.tap(find.byKey(const Key('help-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('About & privacy'), 100,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(find.text('About & privacy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About & privacy'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });

  group('light and dark themes at 360px', () {
    late TrainerModel t;
    late HomeGameModel h;

    Future<void> setUpModels(WidgetTester tester) async {
      t = TrainerModel(lib);
      h = HomeGameModel(lib);
      await tester.runAsync(() => Future.wait([t.load(), h.load()]));
      for (var i = 0; i < 6; i++) {
        t.answer(i % 2);
        t.next();
      }
      h.start(name: 'Fri', players: ['Me', 'Alex', 'Sam'], heroSeat: 0, buttonSeat: 0);
      h.logHand(action: PreAction.fold);
      h.setDelay(0);
    }

    Future<void> pump(WidgetTester tester, Widget w, Brightness b) async {
      tester.view.physicalSize = const Size(360 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        theme: b == Brightness.light ? Felt.light() : Felt.dark(),
        builder: (_, child) => AppScope(trainer: t, home: h, child: child!),
        home: w,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    for (final b in Brightness.values) {
      testWidgets('key screens render without overflow (${b.name})', (tester) async {
        PackageInfo.setMockInitialValues(
            appName: 'Felt Notes',
            packageName: 'x',
            version: '1',
            buildNumber: '1',
            buildSignature: '');
        await setUpModels(tester);
        final screens = <String, Widget>{
          'train': TrainScreen(model: t),
          'charts': ChartsScreen(library: lib, onDrill: (_) {}),
          'equity': EquityScreen(library: lib),
          'stats': StatsScreen(model: t, onDrill: (_) {}),
          'home game': HomeGameScreen(model: h),
          'daily': DailyScreen(model: t),
          'help': const HelpScreen(),
          'about': const AboutScreen(),
          'settings': const SettingsScreen(),
        };
        for (final MapEntry(key: name, value: w) in screens.entries) {
          await pump(tester, w, b);
          expect(tester.takeException(), isNull, reason: '$name (${b.name})');
          // The app bar title is readable on its background.
          final title = find.descendant(
              of: find.byType(AppBar), matching: find.byType(Text));
          if (title.evaluate().isNotEmpty) {
            expectReadable(tester, title.first, why: '$name title (${b.name})');
          }
          // Sweep every visible paragraph: at least 3:1 against what is
          // painted behind it (lenient: catches white-on-cream / gold-on-
          // paper, not fine typography). Disabled/faded text is skipped.
          final bad = <String>[];
          for (final e in find.byType(RichText).evaluate()) {
            final p = e.renderObject as RenderParagraph;
            final c = p.text.style?.color;
            if (c == null || c.alpha < 200 || !p.hasSize) continue;
            if (e.findAncestorWidgetOfExactType<Opacity>() != null) continue;
            // Grid cells paint their colour in a sibling layer (white on
            // the action / heat colour, the same in both themes).
            if (e.findAncestorWidgetOfExactType<HeatGrid>() != null ||
                e.findAncestorWidgetOfExactType<RangeGrid>() != null ||
                e.findAncestorWidgetOfExactType<ActionFreqBar>() != null) {
              continue;
            }
            final bg = backgroundOf(e);
            final r = contrast(Color.alphaBlend(c, bg), bg);
            if (r < 3) bad.add('"${p.text.toPlainText()}" $c on $bg ${r.toStringAsFixed(2)}');
          }
          expect(bad, isEmpty, reason: '$name (${b.name})');
        }
      });
    }

    testWidgets('light: gold accents and help text are readable', (tester) async {
      await setUpModels(tester);
      await pump(tester, const HelpScreen(), Brightness.light);
      expectReadable(tester, find.text('Settings'), why: 'help settings title');
      expectIconVisible(tester, find.byIcon(Icons.settings_outlined),
          why: 'gold accent icon on a light card');
      await tester.tap(find.text('Train'));
      await tester.pumpAndSettle();
      expectReadable(tester,
          find.textContaining('You get a spot').first, why: 'help body line');

      // The Daily 10 card sits on translucent gold over the paper background.
      await pump(tester, TrainScreen(model: t), Brightness.light);
      expectReadable(tester, find.textContaining('Daily 10').first,
          why: 'daily card title');
      expectReadable(tester, find.textContaining('Same 10 hands').first,
          why: 'daily card subtitle');
      expectIconVisible(tester, find.byIcon(Icons.today), why: 'daily icon');

      // Plain gold would fail on the light card: the reason for goldDeep.
      expect(contrast(Felt.gold, Colors.white), lessThan(3));
      expect(contrast(Felt.goldDeep, Colors.white), greaterThan(4.5));
      expect(contrast(Felt.goldDeep, Felt.cream), greaterThan(4.5));
    });

    testWidgets('dark-only screens stay dark in light mode', (tester) async {
      await setUpModels(tester);
      await pump(tester, DashboardScreen(model: h), Brightness.light);
      final scaffold = find.byType(Scaffold).first;
      expect(Theme.of(tester.element(scaffold)).brightness, Brightness.dark);
      expect(tester.widget<Scaffold>(scaffold).backgroundColor, Felt.feltDark);
      expect(tester.takeException(), isNull);
    });

    testWidgets('light theme: core text is high-contrast', (tester) async {
      final light = Felt.light();
      final cs = light.colorScheme;
      expect(contrast(cs.onSurface, light.scaffoldBackgroundColor), greaterThan(7));
      expect(contrast(cs.onSurface, light.cardTheme.color!), greaterThan(7));
      expect(contrast(cs.onPrimary, cs.primary), greaterThan(4.5));
      expect(contrast(cs.primary, light.scaffoldBackgroundColor), greaterThan(4.5));
      final dark = Felt.dark();
      expect(contrast(dark.colorScheme.onSurface, dark.scaffoldBackgroundColor),
          greaterThan(7));
      expect(contrast(Felt.gold, Felt.feltCard), greaterThan(4.5));
    });
  });
}
