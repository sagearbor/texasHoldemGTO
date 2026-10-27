import 'package:felt_notes/homegame/board_speech.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> cs(String s) => s.isEmpty ? <int>[] : parseCards(s);
String show(List<int> b) => b.map(cardToString).join(' ');

/// Expects [text] (said over [board]) to produce exactly [expected] board.
void ok(String text, String expected, {String board = '', String dead = '', Street? street}) {
  final r = parseBoardSpeech(text, board: cs(board), dead: cs(dead));
  expect(r.problem, isNull, reason: '"$text" -> $r');
  expect(show(r.board), show(cs(expected)), reason: '"$text" -> $r');
  if (street != null) expect(r.street, street, reason: '"$text" -> $r');
}

/// Expects [text] to be rejected; the board is left unchanged.
BoardParse bad(String text, {String board = '', String dead = '', String? why}) {
  final r = parseBoardSpeech(text, board: cs(board), dead: cs(dead));
  expect(r.ok, isFalse, reason: '"$text" -> $r');
  expect(show(r.board), show(cs(board)));
  if (why != null) expect(r.problem, contains(why), reason: '"$text" -> $r');
  return r;
}

void main() {
  group('flop phrasings', () {
    const flop = 'Kh7s4c';
    test('full words', () => ok('flop king of hearts seven of spades four of clubs', flop, street: Street.flop));
    test('letters and digits', () => ok('flop K hearts 7 spades 4 clubs', flop));
    test('no "of"', () => ok('flop king hearts seven spades four clubs', flop));
    test('ASR capitalised + commas', () => ok('Flop, King of Hearts, 7 of Spades, 4 of Clubs.', flop));
    test('singular suits', () => ok('flop king of heart seven of spade four of club', flop));
    test('plural ranks', () => ok('flop kings hearts sevens spades fours clubs', flop));
    test('"the flop is"', () => ok('the flop is king of hearts seven of spades four of clubs', flop));
    test('four heard as "for"', () => ok('flop king of hearts seven of spades for of clubs', flop));
    test('four heard as "fore"', () => ok('flop king hearts seven spades fore clubs', flop));
    test('hearts heard as "harts"', () => ok('flop king of harts seven of spades four of clubs', flop));
    test('compact typed', () => ok('Kh 7s 4c', flop));
    test('compact no spaces in words', () => ok('flop Kh7s4c'.replaceAll('Kh7s4c', 'Kh 7s 4c'), flop));
    test('suit symbols', () => ok('K♥ 7♠ 4♣', flop));
    test('symbols spaced', () => ok('flop K ♥ 7 ♠ 4 ♣', flop));
    test('ums and filler', () => ok('uh flop is um king of hearts then seven of spades and four of clubs', flop));
    test('no street word infers flop', () => ok('king of hearts seven of spades four of clubs', flop, street: Street.flop));
    test('"flap" mishearing', () => ok('flap king of hearts seven of spades four of clubs', flop));
    test('clover means clubs', () => ok('flop king of hearts seven of spades four of clover', flop));
    test('diamond singular', () => ok('flop ace diamond queen diamond 2 spades', 'AdQd2s'));
    test('deuce/trey', () => ok('flop deuce of clubs trey of hearts ace of spades', '2c3hAs'));
    test('"ten" as 10', () => ok('flop 10 of hearts jack of hearts queen of hearts', 'ThJhQh'));
    test('"tin" mishearing', () => ok('flop tin of hearts jack of hearts queen of hearts', 'ThJhQh'));
    test('"ate" mishearing', () => ok('flop ate of diamonds nine of clubs two of hearts', '8d9c2h'));
    test('"to" mishearing', () => ok('flop to of clubs five of hearts six of spades', '2c5h6s'));
    test('"too" mishearing', () => ok('flop too clubs five hearts six spades', '2c5h6s'));
    test('"queens" / "jacks"', () => ok('flop queens of spades jacks of clubs aces of hearts', 'QsJcAh'));
    test("apostrophe queen's", () => ok("flop queen's spades jack's clubs ace's hearts", 'QsJcAh'));
    test('paired: seven seven hearts spades', () => ok('flop seven seven hearts spades king clubs', '7h7sKc'));
    test('paired: seven of hearts and spades', () => ok('flop seven of hearts and spades king of clubs', '7h7sKc'));
    test('trips by suits', () => ok('flop seven of hearts, spades and clubs', '7h7s7c'));
    test('"ase" for ace', () => ok('flop ase of spades king of spades queen of spades', 'AsKsQs'));
    test('"a" as ace before a suit', () => ok('flop a hearts king hearts 2 clubs', 'AhKh2c'));
    test('partial flop, one card at a time', () => ok('king of hearts', 'Kh'));
    test('partial flop continues', () => ok('seven of spades', 'Kh7s', board: 'Kh'));
    test('flop word finishing partial flop', () => ok('flop four of clubs', 'Kh7s4c', board: 'Kh7s'));
  });

  group('turn and river', () {
    test('turn jack diamonds', () => ok('turn jack diamonds', 'Kh7s4cJd', board: 'Kh7s4c', street: Street.turn));
    test('river ten of hearts', () => ok('river ten of hearts', 'Kh7s4cJdTh', board: 'Kh7s4cJd', street: Street.river));
    test('the river is a deuce of clubs',
        () => ok('the river is a deuce of clubs', 'Kh7s4cJd2c', board: 'Kh7s4cJd', street: Street.river));
    test('ace spades with no street on a flop -> turn',
        () => ok('ace spades', 'Kh7s4cAs', board: 'Kh7s4c', street: Street.turn));
    test('ace spades with no street on a turn -> river',
        () => ok('ace spades', 'Kh7s4cJdAs', board: 'Kh7s4cJd', street: Street.river));
    test('turn card is the', () => ok('turn card is the nine of clubs', 'Kh7s4c9c', board: 'Kh7s4c'));
    test('"tern" mishearing', () => ok('tern jack of diamonds', 'Kh7s4cJd', board: 'Kh7s4c'));
    test('turn replaces an existing turn',
        () => ok('turn queen of diamonds', 'Kh7s4cQd2c', board: 'Kh7s4cJd2c'));
    test('river replaces an existing river',
        () => ok('river three of clubs', 'Kh7s4cJd3c', board: 'Kh7s4cJd2c'));
    test('flop with 3 cards replaces the flop', () => ok('flop ace of clubs ace of diamonds 2 of hearts', 'AcAd2h', board: 'Kh7s4c'));
    test('whole board in one breath',
        () => ok('flop king of hearts seven of spades four of clubs turn jack of diamonds river ten of hearts', 'Kh7s4cJdTh'));
    test('turn and river together', () => ok('turn jack diamonds river 10 hearts', 'Kh7s4cJdTh', board: 'Kh7s4c'));
    test('"turned" variant', () => ok('turned the eight of spades', 'Kh7s4c8s', board: 'Kh7s4c'));
    test('"rivers" variant', () => ok('rivers a five of diamonds', 'Kh7s4cJd5d', board: 'Kh7s4cJd'));
  });

  group('rejections', () {
    test('nothing', () => bad('', why: 'Nothing'));
    test('no cards', () => bad('what did he say', why: 'No cards'));
    test('duplicate in utterance', () => bad('flop king of hearts king of hearts four of clubs', why: 'twice'));
    test('card already on the board', () => bad('turn king of hearts', board: 'Kh7s4c', why: 'already on the board'));
    test('card in your hand', () => bad('flop ace of spades king of spades 2 of clubs', dead: 'AsAd', why: 'in your hand'));
    test('turn before flop', () => bad('turn jack of diamonds', board: 'Kh', why: 'flop first'));
    test('river before turn', () => bad('river jack of diamonds', board: 'Kh7s4c', why: 'turn first'));
    test('turn with two cards', () => bad('turn jack of diamonds queen of clubs', board: 'Kh7s4c', why: 'one card'));
    test('four-card flop', () => bad('flop 2c 3c 4c 5c', why: 'three cards'));
    test('board full', () => bad('nine of clubs', board: 'Kh7s4cJdTh', why: 'full'));
    test('too many for the space left', () => bad('nine of clubs eight of clubs', board: 'Kh7s4cJd', why: 'Only 1'));
    test('weak rank without suit is not a card', () => bad('for the turn', board: 'Kh7s4c'));
  });

  group('noise and confidence', () {
    test('clean phrase is fully confident', () {
      final r = parseBoardSpeech('flop king of hearts seven of spades four of clubs');
      expect(r.confidence, 1.0);
      expect(r.remainder, '');
    });
    test('homophones lower confidence', () {
      final r = parseBoardSpeech('flop king of hearts seven of spades for of clubs');
      expect(r.confidence, lessThan(1.0));
      expect(r.confidence, greaterThan(0.7));
    });
    test('unparsed words are returned as the remainder', () {
      final r = parseBoardSpeech('flop king of hearts banana seven of spades four of clubs');
      expect(show(r.board), 'Kh 7s 4c');
      expect(r.remainder, 'banana');
      expect(r.confidence, lessThan(0.9));
    });
    test('a rank with no suit ends up in the remainder', () {
      final r = parseBoardSpeech('turn queen', board: cs('Kh7s4c'));
      expect(r.ok, isFalse);
      expect(r.remainder, 'queen');
    });
    test('table chatter around the call', () {
      final r = parseBoardSpeech('okay here we go the flop is king of hearts seven of spades four of clubs nice');
      expect(show(r.board), 'Kh 7s 4c');
      expect(r.remainder, 'nice');
    });
    test('"for" in a sentence is not a four', () {
      final r = parseBoardSpeech('waiting for the turn jack of diamonds', board: cs('Kh7s4c'));
      expect(show(r.board), 'Kh 7s 4c Jd');
      expect(r.remainder, 'waiting for');
    });
    test('"to" before a rank is not a two', () {
      ok('turn to the jack of diamonds', 'Kh7s4cJd', board: 'Kh7s4c');
    });
    test('"as" lower-case is a word, not ace of spades', () {
      final r = parseBoardSpeech('as river ten of hearts', board: cs('Kh7s4cJd'));
      expect(show(r.board), 'Kh 7s 4c Jd Th');
    });
    test('typed "As" is ace of spades', () => ok('As Kd 2c', 'AsKd2c'));
    test('inferred street is a bit less confident', () {
      final r = parseBoardSpeech('ace spades', board: cs('Kh7s4c'));
      expect(r.streetSpoken, isFalse);
      expect(r.confidence, lessThan(1.0));
    });
    test('labels', () {
      expect(boardLabel(cs('Kh7s4cTd')), 'K♥ 7♠ 4♣ 10♦');
      expect(streetForLength(0), Street.flop);
      expect(streetForLength(3), Street.turn);
      expect(streetForLength(4), Street.river);
    });
  });
}
