import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/homegame/recap.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/screens/recap_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:felt_notes/ui/widgets/share_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Width and height from a PNG's IHDR chunk.
(int, int) pngSize(Uint8List b) {
  final d = ByteData.sublistView(b);
  return (d.getUint32(16), d.getUint32(20));
}

bool isPng(Uint8List b) =>
    b.length > 24 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47 &&
    String.fromCharCodes(b.sublist(12, 16)) == 'IHDR';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  HomeSession bigNight() => HomeSession(
        id: '1',
        name: 'Game night with a rather long name 10/26',
        started: DateTime(2026, 10, 26, 20).millisecondsSinceEpoch,
        players: ['Me', 'Alexandria Longname', 'Sam', 'Jo'],
        heroSeat: 0,
        buttonSeat: 0,
        closed: true,
        hands: [
          for (var i = 1; i <= 40; i++)
            LoggedHand(
              number: i,
              cards: parseCards(['AsAh', '7c2d', 'KsQs', '8h3s', 'Td9d'][i % 5]),
              position: ['BTN', 'CO', 'HJ', 'UTG', 'BB', 'SB'][i % 6],
              dealer: ['Me', 'Alexandria Longname', 'Sam', 'Jo'][i % 4],
              action: i % 3 == 0 ? PreAction.raise : PreAction.fold,
              facing: Facing.unopened,
              ts: i * 120000,
            ),
        ],
      );

  TrainerModel trainer() {
    final m = TrainerModel(lib);
    final a = lib.cash[0].id, b = lib.cash[1].id;
    for (var i = 0; i < 30; i++) {
      m.history.add(Answer(i.isEven ? a : b, i % 169, 0, i % 7 == 0 ? 0.0 : 1.0, 1000 + i));
    }
    return m;
  }

  group('share card', () {
    testWidgets('night card renders to a 1080x1350 PNG', (tester) async {
      final r = nightRecap(bigNight(), lib);
      expect(r.awards, isNotEmpty);
      final png = (await tester.runAsync(() => renderShareCardPng(NightShareCard(r))))!;
      expect(isPng(png), isTrue);
      expect(pngSize(png), (1080, 1350));
      expect(png.length, greaterThan(5000));
      // Keep a copy for eyeballing when SHARE_CARD_OUT is set.
      final out = Platform.environment['SHARE_CARD_OUT'];
      if (out != null) File('$out/night.png').writeAsBytesSync(png);
    });

    testWidgets('thin night still renders', (tester) async {
      final s = HomeSession(
          id: '2',
          name: 'Short',
          started: 0,
          players: ['Me', 'A'],
          heroSeat: 0,
          buttonSeat: 0,
          hands: [LoggedHand(number: 1, cards: null, position: 'BTN', ts: 0)]);
      final png =
          (await tester.runAsync(() => renderShareCardPng(NightShareCard(nightRecap(s, lib)))))!;
      expect(pngSize(png), (1080, 1350));
    });

    testWidgets('trainer report card renders to a 1080x1350 PNG', (tester) async {
      final rep = TrainerReport.from(trainer());
      final png = (await tester.runAsync(() => renderShareCardPng(TrainerShareCard(rep))))!;
      expect(isPng(png), isTrue);
      expect(pngSize(png), (1080, 1350));
      final out = Platform.environment['SHARE_CARD_OUT'];
      if (out != null) File('$out/trainer.png').writeAsBytesSync(png);
    });

    test('trainer report numbers', () {
      final rep = TrainerReport.from(trainer(), now: DateTime(2026));
      expect(rep.drilled, 30);
      // Misses at i = 0, 7, 14, 21, 28.
      expect(rep.accuracy, closeTo(25 / 30, 1e-9));
      expect(rep.bestStreak, 6);
      expect(rep.currentStreak, 1);
      expect(rep.bestSpot, isNotNull);
      expect(rep.worstSpot, isNotNull);
      expect(rep.bestSpot!.$2, greaterThanOrEqualTo(rep.worstSpot!.$2));
      expect(rep.last7, isNull); // all answers are from 1970
      expect(rep.toText(), contains('sagearbor.github.io/texasHoldemGTO'));
    });

    test('top award skips dealer awards', () {
      final r = nightRecap(bigNight(), lib);
      final top = topAward(r);
      expect(top, isNotNull);
      if (r.awards.any((a) => a.id != AwardId.goldenArm && a.id != AwardId.dealerOfDoom)) {
        expect(top!.id, isNot(anyOf(AwardId.goldenArm, AwardId.dealerOfDoom)));
      }
    });

    testWidgets('recap screen has a Share image button', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final m = HomeGameModel(lib)..sessions.add(bigNight());
      await tester.pumpWidget(
          MaterialApp(theme: Felt.dark(), home: RecapScreen(model: m, session: m.sessions.first)));
      await tester.pump();
      expect(find.text('Share image'), findsOneWidget);
      expect(find.text('Copy recap'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
