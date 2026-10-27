import 'dart:convert';

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotLibrary lib;
  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  Future<HomeGameModel> fresh() async {
    SharedPreferences.setMockInitialValues({});
    final m = HomeGameModel(lib);
    await m.load();
    m.start(name: 'x', players: ['me', 'b', 'c', 'd', 'e', 'f'], heroSeat: 0, buttonSeat: 0);
    return m;
  }

  test('position names', () {
    expect([for (var o = 0; o < 6; o++) positionName(6, o)],
        ['BTN', 'SB', 'BB', 'UTG', 'HJ', 'CO']);
    expect([for (var o = 0; o < 9; o++) positionName(9, o)],
        ['BTN', 'SB', 'BB', 'UTG', 'UTG+1', 'UTG+2', 'LJ', 'HJ', 'CO']);
    expect(positionName(2, 0), 'BTN/SB');
    expect(chartPosition('UTG+2'), 'UTG');
  });

  test('button rotates one seat per logged hand', () async {
    final m = await fresh();
    final seen = <String>[];
    for (var i = 0; i < 7; i++) {
      seen.add(m.active!.position);
      m.logHand(action: PreAction.fold);
    }
    expect(seen, ['BTN', 'CO', 'HJ', 'UTG', 'BB', 'SB', 'BTN']);
    expect(m.active!.positionsInOrder, ['UTG', 'HJ', 'CO', 'BTN', 'SB', 'BB']);
  });

  test('correcting position or dealer moves the button', () async {
    final m = await fresh();
    m.setPosition('BB');
    expect(m.active!.position, 'BB');
    expect(m.active!.players[m.active!.buttonSeat], 'e');
    m.setDealer(3);
    expect(m.active!.position, 'UTG');
  });

  test('players can join and leave mid-game', () async {
    final m = await fresh();
    m.logHand(action: PreAction.fold); // button now on b, me = CO
    expect(m.active!.position, 'CO');
    m.addPlayer('g', 6); // seat after f, before me
    expect(m.active!.tableSize, 7);
    expect(m.active!.players[m.active!.buttonSeat], 'b');
    expect(m.active!.position, 'CO');
    m.removePlayer(m.active!.players.indexOf('b')); // the dealer leaves
    expect(m.active!.players[m.active!.buttonSeat], 'c');
    m.removePlayer(m.active!.heroSeat); // can't remove yourself
    expect(m.active!.players.contains('me'), isTrue);
  });

  test('undo gives the button back', () async {
    final m = await fresh();
    m.logHand(action: PreAction.fold);
    m.logHand(action: PreAction.fold);
    m.undo();
    expect(m.active!.players[m.active!.buttonSeat], 'b');
    expect(m.active!.hands.length, 1);
  });

  test('session stats and coverage', () async {
    final m = await fresh();
    m.logHand(cards: parseCards('AsAh'), action: PreAction.raise, facing: Facing.unopened); // BTN
    m.logHand(cards: parseCards('7c2d'), action: PreAction.raise, facing: Facing.unopened); // CO miss
    m.logHand(cards: parseCards('KsQs'), action: PreAction.call, facing: Facing.raised);
    m.logHand(cards: parseCards('9h9d')); // cards only
    m.logHand(action: PreAction.fold); // fold, no cards
    m.logHand(); // skipped
    final st = computeStats(m.active!.hands, lib);
    expect(st.logged, 6);
    expect(st.dealt, 4);
    expect(st.recorded, 4);
    expect(st.vpip, 3);
    expect(st.pfr, 2);
    expect(st.premiums, 1);
    expect(st.graded, 2);
    expect(st.gtoScore, 0.5);
    expect(st.misses.single.$1.hand!.name, '72o');
    expect(st.coverage, closeTo(4 / 6, 1e-9));
  });

  test('persistence, delay setting and v0.1.0 migration', () async {
    final m = await fresh();
    m.logHand(action: PreAction.fold);
    m.setDelay(30);
    await Future<void>.delayed(const Duration(milliseconds: 10)); // let the save land
    final again = HomeGameModel(lib);
    await again.load();
    expect(again.active!.hands.length, 1);
    expect(again.dashboardDelayMinutes, 30);

    final old = {
      'id': '1', 'name': 'old', 'started': 0,
      'players': ['a', 'b', 'c'], 'hero': 0, 'btn': 0,
      'hands': [
        {'n': 1, 'c': null, 'p': 'BTN', 'a': 0, 'f': 0, 't': 0},
      ],
    };
    SharedPreferences.setMockInitialValues({'home_sessions_v1': jsonEncode([old])});
    final migrated = HomeGameModel(lib);
    await migrated.load();
    expect(migrated.active!.buttonSeat, 1);
  });
}
