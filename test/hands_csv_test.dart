import 'package:felt_notes/data/hands_csv.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('csvField escapes commas, quotes and line breaks', () {
    expect(csvField('plain'), 'plain');
    expect(csvField(''), '');
    expect(csvField('a,b'), '"a,b"');
    expect(csvField('say "hi"'), '"say ""hi"""');
    expect(csvField('two\nlines'), '"two\nlines"');
    expect(csvField('cr\r'), '"cr\r"');
    expect(csvField('UTG+1'), 'UTG+1');
  });

  test('csvField keeps formula-looking text as text', () {
    expect(csvField('=SUM(A1)'), "'=SUM(A1)");
    expect(csvField('+1'), "'+1");
    expect(csvField('-x'), "'-x");
    expect(csvField('@me'), "'@me");
    expect(csvField('=HYPERLINK("x","y")'), '"\'=HYPERLINK(""x"",""y"")"');
  });

  test('one row per hand with every column', () {
    final started = DateTime(2026, 10, 23, 20, 0).millisecondsSinceEpoch;
    final s = HomeSession(
      id: '1',
      name: 'Fri, Bob\'s "place"',
      started: started,
      players: ['me', 'Bob', '=evil'],
      heroSeat: 0,
      buttonSeat: 0,
      hands: [
        LoggedHand(
          number: 1,
          cards: parseCards('AsKd'),
          position: 'BTN',
          dealer: '=evil',
          action: PreAction.raise,
          facing: Facing.unopened,
          ts: DateTime(2026, 10, 23, 20, 5, 9).millisecondsSinceEpoch,
          tag: StoryTag.badBeat,
          board: parseCards('Qh7c2s'),
        ),
        LoggedHand(
          number: 2,
          cards: null,
          position: 'SB',
          ts: DateTime(2026, 10, 23, 20, 9).millisecondsSinceEpoch,
        ),
      ],
    );
    final csv = homeHandsCsv([s]);
    final lines = csv.split('\r\n');
    expect(lines.length, 4); // header, 2 hands, trailing empty
    expect(lines.last, '');
    expect(lines[0],
        'night,night_date,hand,position,dealer,cards,action,facing,board,tag,timestamp');
    expect(lines[1],
        '"Fri, Bob\'s ""place""",2026-10-23,1,BTN,\'=evil,As Kd,Raise,Unopened,'
        'Qh 7c 2s,Bad beat,2026-10-23T20:05:09');
    expect(lines[2],
        '"Fri, Bob\'s ""place""",2026-10-23,2,SB,,,,,,,2026-10-23T20:09:00');
  });

  test('no sessions gives just the header', () {
    expect(homeHandsCsv([]).split('\r\n').first, startsWith('night,'));
    expect(handsCsvFileName(DateTime(2026, 1, 2)), 'felt-notes-hands-2026-01-02.csv');
  });
}
