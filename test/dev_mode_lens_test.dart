import 'package:camera/camera.dart';
import 'package:felt_notes/app_data.dart';
import 'package:felt_notes/camera/lens.dart';
import 'package:felt_notes/camera/lens_camera.dart';
import 'package:felt_notes/ui/dev_mode.dart';
import 'package:felt_notes/ui/screens/about_screen.dart';
import 'package:felt_notes/ui/screens/settings_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _back0 = CameraDescription(name: '0', lensDirection: CameraLensDirection.back, sensorOrientation: 90);
const _back2 = CameraDescription(name: 'uw', lensDirection: CameraLensDirection.back, sensorOrientation: 90);
const _front = CameraDescription(name: '1', lensDirection: CameraLensDirection.front, sensorOrientation: 270);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DevMode.load();
    await CameraLens.load();
  });

  group('developer mode', () {
    test('7 quick taps complete the gesture, then it starts again', () {
      final c = TapCounter();
      final t0 = DateTime(2026, 11, 5, 20);
      for (var i = 0; i < 6; i++) {
        expect(c.tap(t0.add(Duration(milliseconds: 300 * i))), isFalse);
      }
      expect(c.tap(t0.add(const Duration(milliseconds: 1800))), isTrue);
      expect(c.count, 0);
      expect(c.tap(t0.add(const Duration(seconds: 3))), isFalse);
    });

    test('a slow tap starts the count over', () {
      final c = TapCounter();
      final t0 = DateTime(2026, 11, 5, 20);
      for (var i = 0; i < 6; i++) {
        c.tap(t0.add(Duration(milliseconds: 100 * i)));
      }
      expect(c.tap(t0.add(const Duration(seconds: 10))), isFalse);
      expect(c.count, 1);
    });

    test('off by default, toggles and persists, reset all data turns it off', () async {
      expect(DevMode.on.value, isFalse);
      expect(await DevMode.toggle(), isTrue);
      expect((await SharedPreferences.getInstance()).getBool(DevMode.key), isTrue);
      DevMode.on.value = false;
      await DevMode.load();
      expect(DevMode.on.value, isTrue);
      await resetAllData();
      expect(DevMode.on.value, isFalse);
    });

    Future<void> pumpSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360 * 3, 760 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: Felt.dark(), home: const SettingsScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('Settings hides Diagnostics unless developer mode is on', (tester) async {
      await pumpSettings(tester);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Data'), 100, scrollable: list);
      expect(find.text('Diagnostics'), findsNothing);
      expect(find.byKey(const Key('settings-dev-mode')), findsNothing);
      expect(find.byKey(const Key('settings-bt-distance')), findsNothing);
      expect(find.byKey(const Key('settings-watch-log')), findsNothing);

      DevMode.on.value = true;
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('settings-dev-mode')), 100, scrollable: list);
      expect(find.text('Diagnostics'), findsOneWidget);

      // The switch there turns it off again.
      await tester.tap(find.byKey(const Key('settings-dev-mode')));
      await tester.pumpAndSettle();
      expect(DevMode.on.value, isFalse);
      expect(find.text('Diagnostics'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the version in About 7 times switches it on and off', (tester) async {
      PackageInfo.setMockInitialValues(
          appName: 'Felt Notes',
          packageName: 'com.sagearbor.feltnotes.app',
          version: '0.3.3',
          buildNumber: '33',
          buildSignature: '');
      await tester.pumpWidget(MaterialApp(theme: Felt.dark(), home: const AboutScreen()));
      await tester.pumpAndSettle();
      final v = find.byKey(const Key('about-version'));
      expect(v, findsOneWidget);
      Future<void> sevenTaps() async {
        for (var i = 0; i < 7; i++) {
          await tester.tap(v);
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(seconds: 1));
      }

      await sevenTaps();
      expect(DevMode.on.value, isTrue);
      expect(find.text('Developer mode on'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await sevenTaps();
      expect(DevMode.on.value, isFalse);
      expect(find.text('Developer mode off'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });

  group('camera lens', () {
    test('automatic keeps each feature default; normal and widest override', () {
      expect(useWidest(LensChoice.auto, featureDefault: true), isTrue); // Record
      expect(useWidest(LensChoice.auto, featureDefault: false), isFalse); // Watch / Snap
      for (final d in [true, false]) {
        expect(useWidest(LensChoice.normal, featureDefault: d), isFalse);
        expect(useWidest(LensChoice.widest, featureDefault: d), isTrue);
      }
    });

    test('Android zoom: the minimum only when widest and below 1', () {
      expect(androidZoomFor(widest: true, minZoom: 0.6), 0.6);
      expect(androidZoomFor(widest: true, minZoom: 1.0), 1.0);
      expect(androidZoomFor(widest: false, minZoom: 0.5), 1.0);
    });

    test('lens labels', () {
      expect(lensLine(const LensInfo('ultra_wide', '0', zoom: 0.5, minZoom: 0.5), widest: true),
          'Lens: ultra-wide (zoom 0.50)');
      expect(lensLine(const LensInfo('wide', '0', zoom: 1.0, minZoom: 1.0), widest: true),
          'Lens: normal (zoom 1.00) · this phone has no wider lens');
      expect(lensLine(const LensInfo('wide', '0'), widest: false), 'Lens: normal');
      expect(lensLine(const LensInfo('front', '1'), widest: false), 'Lens: front');
      expect(snapLensLine(LensChoice.auto), 'Lens: normal (your camera app)');
      expect(snapLensLine(LensChoice.widest), contains('0.5×'));
      expect(const LensInfo('ultra_wide', 'uw', zoom: 0.5, minZoom: 0.5).toJson(),
          {'kind': 'ultra_wide', 'camera': 'uw', 'zoom': 0.5, 'min_zoom': 0.5});
    });

    test('picking the camera', () {
      const cams = [_back0, _front, _back2];
      // iOS lists the ultra-wide: picked by id when widest.
      expect(pickCamera(cams, direction: CameraLensDirection.back, widest: true, ultraWideName: 'uw'),
          (_back2, 'ultra_wide'));
      expect(pickCamera(cams, direction: CameraLensDirection.back, widest: false, ultraWideName: 'uw'),
          (_back0, 'wide'));
      // Android (no id): the logical back camera; zoom does the rest.
      expect(pickCamera(cams, direction: CameraLensDirection.back, widest: true), (_back0, 'wide'));
      expect(pickCamera(cams, direction: CameraLensDirection.front, widest: true, ultraWideName: 'uw'),
          (_front, 'front'));
      // No back camera: Watch falls back to any, Record has none.
      expect(pickCamera(const [_front], direction: CameraLensDirection.back, widest: true, fallbackToAny: true),
          (_front, 'front'));
      expect(pickCamera(const [_front], direction: CameraLensDirection.back, widest: true), isNull);
      expect(pickCamera(const [], direction: CameraLensDirection.back, widest: true, fallbackToAny: true), isNull);
    });

    test('setting persists, defaults to automatic', () async {
      expect(CameraLens.choice.value, LensChoice.auto);
      await CameraLens.set(LensChoice.widest);
      expect((await SharedPreferences.getInstance()).getString(CameraLens.key), 'widest');
      CameraLens.choice.value = LensChoice.auto;
      await CameraLens.load();
      expect(CameraLens.choice.value, LensChoice.widest);
      SharedPreferences.setMockInitialValues({CameraLens.key: 'bogus'});
      await CameraLens.load();
      expect(CameraLens.choice.value, LensChoice.auto);
    });

    testWidgets('Settings → Camera lens chips', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 760 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: Felt.light(), home: const SettingsScreen()));
      await tester.pumpAndSettle();
      final chip = find.byKey(const Key('lens-widest'));
      await tester.scrollUntilVisible(chip, 100, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      expect(find.text('Automatic (recommended)'), findsOneWidget);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(CameraLens.choice.value, LensChoice.widest);
      expect(find.textContaining('Every camera feature uses the ultra-wide'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
