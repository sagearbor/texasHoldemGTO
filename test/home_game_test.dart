import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('position names', () {
    expect([for (var o = 0; o < 6; o++) positionName(6, o)],
        ['BTN', 'SB', 'BB', 'UTG', 'HJ', 'CO']);
    expect([for (var o = 0; o < 9; o++) positionName(9, o)],
        ['BTN', 'SB', 'BB', 'UTG', 'UTG+1', 'UTG+2', 'LJ', 'HJ', 'CO']);
    expect(positionName(2, 0), 'BTN/SB');
    expect(positionName(3, 0), 'BTN');
    expect(chartPosition('UTG+2'), 'UTG');
    expect(chartPosition('LJ'), 'UTG');
  });

  test('button rotation moves hero position each hand', () {
    final s = HomeSession(
        id: '1', name: 't', started: 0,
        players: ['a', 'b', 'c', 'd', 'e', 'f'],
        heroSeat: 0, firstButtonSeat: 0);
    expect([for (var n = 1; n <= 7; n++) s.positionFor(n)],
        ['BTN', 'CO', 'HJ', 'UTG', 'BB', 'SB', 'BTN']);
  });

  test('session stats', () async {
    SharedPreferences.setMockInitialValues({});
    final lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(),
        await loadVsRandom());
    final m = HomeGameModel(lib);
    await m.load();
    m.start(name: 'x', players: ['me', 'b', 'c', 'd', 'e', 'f'], heroSeat: 0, buttonSeat: 0);
    // Hand 1: BTN, AA raise (GTO).
    m.logHand(cards: parseCards('AsAh'), action: PreAction.raise, facing: Facing.unopened);
    // Hand 2: CO, 72o raise (miss).
    m.logHand(cards: parseCards('7c2d'), action: PreAction.raise, facing: Facing.unopened);
    // Hand 3: HJ, KQs call facing a raise (not graded).
    m.logHand(cards: parseCards('KsQs'), action: PreAction.call, facing: Facing.raised);
    // Hand 4: cards only.
    m.logHand(cards: parseCards('9h9d'));
    final st = computeStats(m.active!.hands, lib);
    expect(st.dealt, 4);
    expect(st.recorded, 3);
    expect(st.vpip, 3);
    expect(st.pfr, 2);
    expect(st.premiums, 1);
    expect(st.graded, 2);
    expect(st.gtoScore, 0.5);
    expect(st.misses.single.$1.hand!.name, '72o');
    expect(st.avgStrength, greaterThan(0.5));
    m.undo();
    expect(m.active!.hands.length, 3);
    final again = HomeGameModel(lib);
    await again.load();
    expect(again.active!.hands.length, 3);
  });
}
