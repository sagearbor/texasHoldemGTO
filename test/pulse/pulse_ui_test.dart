// Pulse on the phone: the profile flow (prefilled name, selfie, song
// search / preview / pick), the share switch turning Pulse on through the
// profile, and the dark Pulse screen with the watch status.

import 'dart:async';
import 'dart:typed_data';

import 'package:felt_notes/pulse/pulse_cloud.dart';
import 'package:felt_notes/pulse/pulse_firestore.dart';
import 'package:felt_notes/pulse/pulse_profile.dart';
import 'package:felt_notes/pulse/pulse_protocol.dart';
import 'package:felt_notes/pulse/pulse_service.dart';
import 'package:felt_notes/pulse/pulse_source.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:felt_notes/ui/app_settings.dart';
import 'package:felt_notes/ui/pulse/pulse_profile_screen.dart';
import 'package:felt_notes/ui/pulse/pulse_screen.dart';
import 'package:felt_notes/ui/pulse/pulse_widgets.dart';
import 'package:felt_notes/ui/pulse/song_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

const song = PulseSong(
  trackId: 7,
  title: 'Eye of the Tiger',
  artist: 'Survivor',
  previewUrl: 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview/x.m4a',
  artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/x/200x200bb.jpg',
  trackViewUrl: 'https://music.apple.com/us/album/x?i=7',
);

class FakePlayer implements SongPlayer {
  final played = <String>[];
  @override
  Future<bool> play(String url) async {
    played.add(url);
    return true;
  }

  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
}

class Watch implements PulseSource {
  final out = StreamController<PulseMessage>.broadcast(sync: true);
  WatchStatus st = const WatchStatus(supported: true, paired: true, appInstalled: false, reachable: false);
  int store = 0;
  @override
  Stream<PulseMessage> get messages => out.stream;
  @override
  Future<WatchStatus> status() async => st;
  @override
  Future<bool> start() async => true;
  @override
  Future<bool> stop() async => true;
  @override
  Future<bool> openWatchStore() async {
    store++;
    return true;
  }

  @override
  void dispose() {}
}

Uint8List face() => squareFace(img.encodeJpg(img.Image(width: 300, height: 200)..clear(img.ColorRgb8(10, 200, 30))))!;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PulseProfileStore.debugReset();
    AppSettings.playerName.value = 'Sage';
  });

  testWidgets('profile: name prefilled, selfie, song searched, previewed and picked; saved', (tester) async {
    final player = FakePlayer();
    final selfie = face();
    var searched = '';
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await Navigator.of(context).push<bool>(MaterialPageRoute(
              builder: (_) => PulseProfileScreen(
                  firstTime: true,
                  selfie: () async => selfie,
                  search: (t) async {
                    searched = t;
                    return [song];
                  },
                  player: player))),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Sage'), findsOneWidget, reason: 'the name the app knows');
    expect(find.text('SA'), findsNothing);
    expect(find.text('S'), findsOneWidget, reason: 'initials until a selfie');
    await tester.tap(find.byKey(const Key('pulse-selfie')));
    await tester.pumpAndSettle();
    expect(find.text('S'), findsNothing);
    await tester.tap(find.byKey(const Key('pulse-song')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('song-search')), 'tiger');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(searched, 'tiger');
    await tester.tap(find.byTooltip('Listen (30 s)'));
    await tester.pump();
    expect(player.played, [song.previewUrl]);
    await tester.tap(find.byKey(const ValueKey('pick-7')));
    await tester.pumpAndSettle();
    expect(find.text('Eye of the Tiger'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pulse-save')));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    final p = PulseProfileStore.profile.value!;
    expect((p.name, p.song, p.face?.length), ('Sage', song, selfie.length));
    // And it is on disk.
    PulseProfileStore.debugReset();
    expect((await PulseProfileStore.load())!.song, song);
  });

  testWidgets('skip the selfie: initials; an empty name cannot be saved', (tester) async {
    AppSettings.playerName.value = '';
    await tester.pumpWidget(const MaterialApp(home: PulseProfileScreen(firstTime: true)));
    final save = find.byKey(const Key('pulse-save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('pulse-name')), 'Joe Bloggs');
    await tester.pump();
    expect(find.text('JB'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
  });

  group('share switch and the Pulse screen', () {
    late FakeCloudLogs logs;
    late FakePulseCloud pulse;
    late Watch watch;
    late LocalTableSync amy;
    final svc = PulseService.instance;

    Future<void> setUpNight(WidgetTester tester) async {
      watch = Watch();
      svc.makeSource = () => watch;
      await tester.runAsync(() async {
        logs = FakeCloudLogs();
        pulse = FakePulseCloud(logs: logs);
        debugPulseCloudFor = (c) => c == null ? null : pulse;
        final host = await LocalTableSync.organize(MemoryStore(), organizerName: 'Sage', selfPid: 'host', cloud: logs);
        amy = await LocalTableSync.join(MemoryStore(), host.qrTicket(),
            name: 'Amy', scannedAtMs: DateTime.now().millisecondsSinceEpoch, sharing: false, cloud: logs);
        await svc.follow(amy);
      });
    }

    tearDown(() async {
      debugPulseCloudFor = null;
      await svc.follow(null);
    });

    testWidgets('off by default; on asks for the profile, then opens Pulse', (tester) async {
      await setUpNight(tester);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PulseShareTile())));
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('pulse-share'))).value, isFalse);
      await tester.tap(find.byKey(const Key('pulse-share')));
      await tester.pumpAndSettle();
      expect(find.text('Join Pulse'), findsWidgets, reason: 'first time: the profile');
      await tester.enterText(find.byKey(const Key('pulse-name')), 'Amy');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('pulse-save')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(svc.on, isTrue);
      expect(find.byType(PulseScreen), findsOneWidget);
      // The watch: paired but no app yet.
      expect(find.text('Felt Notes is not on the watch yet'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pulse-install')));
      await tester.pump();
      expect(watch.store, 1);
      // Heart rate arrives.
      watch.out.add(PulseHr([PulseSample(DateTime.now().millisecondsSinceEpoch, 77)]));
      await tester.pump();
      expect(find.text('77'), findsOneWidget);
      expect(find.text('Measuring'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Off from the Pulse screen: the switch says so.
      await tester.runAsync(() async {
        await svc.setOn(false);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('pulse-share'))).value, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('Pulse screen fits a phone', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await setUpNight(tester);
      await PulseProfileStore.save(PulseProfile(name: 'Amy', face: face(), song: song));
      await tester.pumpWidget(const MaterialApp(home: PulseScreen(keepAwake: false)));
      await tester.pump();
      expect(find.text('--'), findsOneWidget, reason: 'no heart rate yet');
      expect(find.textContaining('Eye of the Tiger'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
