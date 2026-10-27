// Renders store screenshots of the real screens with seeded, deterministic
// data and writes PNGs to store/screenshots/. Not part of `flutter test`
// (it lives in test_driver/, not test/). Run:
//
//   flutter test test_driver/store_screenshots_test.dart
//
// Fonts: flutter_test renders text with a box font unless real fonts are
// loaded, so this loads Roboto + Material Icons from the Flutter SDK cache and
// a system font for the card-suit glyphs (macOS paths; any font with ♣♦♥♠
// works, pass SUIT_FONT=/path/to/font.ttf to override).
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/main.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Output sets: Play phone (9:16, 1080x1920) and the App Store 6.7"/6.9"
/// slot (1290x2796). Logical size x 3 = pixels.
const sets = {
  'android-phone': Size(360, 640),
  'ios-6.7': Size(430, 932),
};

final _outRoot = '${Directory.current.path}/store/screenshots';

String get _flutterRoot =>
    Platform.environment['FLUTTER_ROOT'] ??
    '${Platform.environment['HOME']}/flutter';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) {
      loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  final mf = '$_flutterRoot/bin/cache/artifacts/material_fonts';
  await _loadFont('Roboto', [
    for (final w in ['Regular', 'Medium', 'Bold', 'Black', 'Light'])
      '$mf/Roboto-$w.ttf'
  ]);
  await _loadFont('MaterialIcons', ['$mf/MaterialIcons-Regular.otf']);
  await _loadFont('Symbols', [
    Platform.environment['SUIT_FONT'] ?? '',
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    '/System/Library/Fonts/Apple Symbols.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  ]);
}

ThemeData _withFonts(ThemeData base) => base.copyWith(
      textTheme: base.textTheme
          .apply(fontFamily: 'Roboto', fontFamilyFallback: const ['Symbols']),
      primaryTextTheme: base.primaryTextTheme
          .apply(fontFamily: 'Roboto', fontFamilyFallback: const ['Symbols']),
    );

/// Trainer with ~220 answered drills: mostly GTO, with a few real leaks.
TrainerModel _seedTrainer(SpotLibrary lib) {
  final rng = Random(7);
  final t = TrainerModel(lib, rng: Random(11));
  t.next();
  for (var i = 0; i < 220; i++) {
    final d = t.current!;
    final f = d.spot.freqs(d.hand);
    var best = 0;
    for (var a = 1; a < f.length; a++) {
      if (f[a] > f[best]) best = a;
    }
    // Leaky in the blinds and with small pairs; solid elsewhere.
    final leaky =
        d.spot.hero == 'SB' || d.hand.name.length == 2 && d.hand.row > 7;
    final pick =
        rng.nextDouble() < (leaky ? 0.55 : 0.88) ? best : rng.nextInt(f.length);
    t.answer(pick);
    t.next();
  }
  return t;
}

/// A 6-handed game night, 34 hands in, with cards and actions logged.
HomeGameModel _seedHome(SpotLibrary lib) {
  final h = HomeGameModel(lib);
  h.dashboardDelayMinutes = 0;
  h.start(
    name: 'Friday game',
    players: ['You', 'Maya', 'Leo', 'Priya', 'Sam', 'Jo'],
    heroSeat: 0,
    buttonSeat: 2,
  );
  final rng = Random(3);
  final used = <int>{};
  for (var i = 0; i < 34; i++) {
    used.clear();
    final cards = dealRandom(rng, 2, used);
    final hc = HandClass.fromCards(cards[0], cards[1]);
    final s = h.active!;
    final pos = s.position;
    final facing = rng.nextDouble() < 0.6 ? Facing.unopened : Facing.raised;
    PreAction action;
    if (facing == Facing.unopened && pos != 'BB') {
      final spot = lib.byId('cash-rfi-${chartPosition(pos)}');
      final raise = spot.freqs(hc)[0];
      action = rng.nextDouble() < (raise > 0.5 ? 0.9 : 0.12)
          ? PreAction.raise
          : PreAction.fold;
    } else {
      final strong = lib.vsRandom[hc.index] > 0.6;
      action = strong
          ? (rng.nextBool() ? PreAction.raise : PreAction.call)
          : (rng.nextDouble() < 0.15 ? PreAction.call : PreAction.fold);
    }
    // A few boring hands are logged with a single Fold tap, no cards.
    final skipCards = action == PreAction.fold && rng.nextDouble() < 0.3;
    h.logHand(cards: skipCards ? null : cards, action: action, facing: facing);
  }
  return h;
}

/// Seed whose first drill is a 6-max spot holding a mixed hand.
(TrainerModel, int) _trainDrill(SpotLibrary lib) {
  for (var seed = 0;; seed++) {
    final t = TrainerModel(lib, rng: Random(seed))..next();
    final d = t.current!;
    if (d.spot.format != SpotFormat.cash100) continue;
    final f = d.spot.freqs(d.hand);
    for (var a = 0; a < f.length; a++) {
      if (f[a] >= 0.35 && f[a] < 0.65 && d.spot.actions[a] != 'Fold') {
        return (t, a);
      }
    }
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  final key = GlobalKey();

  setUpAll(() async {
    await _loadFonts();
    lib = await SpotLibrary.load();
  });

  Future<void> shoot(WidgetTester tester, String set, String name) async {
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final img =
          await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      final f = File('$_outRoot/$set/$name.png');
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Future<void> pumpApp(
      WidgetTester tester, Size size, TrainerModel t, HomeGameModel h) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = size * 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _withFonts(Felt.dark()),
        builder: (_, child) => AppScope(trainer: t, home: h, child: child!),
        home: Shell(model: t, home: h),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  for (final e in sets.entries) {
    testWidgets('screenshots ${e.key}', (tester) async {
      SharedPreferences.setMockInitialValues({'seen_welcome_v1': true});
      binding.platformDispatcher.platformBrightnessTestValue = Brightness.dark;

      // 1. Train with a graded (mixed) answer.
      final (train, action) = _trainDrill(lib);
      train.sessionCount = 23;
      train.sessionGood = 20;
      train.streak = 3;
      final home = _seedHome(lib);
      await pumpApp(tester, e.value, train, home);
      train.answer(action);
      await shoot(tester, e.key, '1-train');

      // 2. Charts: the BTN open chart.
      await tab(tester, 'Charts');
      await tester.tap(find.text('BTN').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('BTN open').last);
      await shoot(tester, e.key, '2-charts');

      // 3. Equity: A♠K♠ vs Q♥Q♦ on J♠ T♠ 4♦.
      await tab(tester, 'Equity');
      Future<void> pick(String label) async {
        await tester.tap(find.byIcon(Icons.add).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      for (final c in ['A♠', 'K♠', 'Q♥', 'Q♦']) {
        await pick(c);
      }
      await tester.tap(find.text('Add player'));
      await tester.pumpAndSettle();
      for (final c in ['9♥', '8♥', 'J♠', 'T♠', '4♦']) {
        await pick(c);
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Calculate equity'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text('Player 3'), findsOneWidget);
      expect(find.textContaining('%'), findsWidgets,
          reason: 'equity bars rendered');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await shoot(tester, e.key, '3-equity');

      // 4. Stats with a few hundred drills.
      final seeded = _seedTrainer(lib);
      train.history
        ..clear()
        ..addAll(seeded.history);
      await tab(tester, 'Stats');
      train.next();
      await shoot(tester, e.key, '4-stats');

      // 5. Home game logger.
      await tab(tester, 'Home game');
      await shoot(tester, e.key, '5-home-game');

      // 6. TV dashboard, landscape like the TV it is mirrored to.
      await tester.tap(find.byIcon(Icons.tv));
      // Play: 1920x1080 at a TV-like 960x540 logical; iOS: phone flipped.
      if (e.key.startsWith('android')) {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(1920, 1080);
      } else {
        tester.view.physicalSize = e.value.flipped * 3;
      }
      await shoot(tester, e.key, '6-tv-dashboard');
      // Unmount everything so the dashboard's periodic timer is cancelled.
      await tester.pumpWidget(const SizedBox());
    });
  }
}
