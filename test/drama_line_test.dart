import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/homegame/moments.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Local time on a fixed date, so the test passes in any time zone.
  int at(int hour, int minute) =>
      DateTime(2026, 10, 3, hour, minute).millisecondsSinceEpoch;

  LoggedHand hand(int n, String? cards, StoryTag? tag, int ts) => LoggedHand(
        number: n,
        cards: cards == null ? null : parseCards(cards),
        position: 'BTN',
        tag: tag,
        ts: ts,
      );

  test('12-hour wall clock', () {
    expect(clockLabel(at(20, 22)), '8:22pm');
    expect(clockLabel(at(9, 5)), '9:05am');
    expect(clockLabel(at(0, 7)), '12:07am');
    expect(clockLabel(at(12, 0)), '12:00pm');
    expect(clockLabel(at(23, 59)), '11:59pm');
  });

  test('one phone: tag, my name and cards, time', () {
    final h = hand(12, 'AsKd', StoryTag.badBeat, at(20, 22));
    expect(storyLine(h, hero: 'Sage'), 'Bad beat · Sage AKo · 8:22pm');
    // No cards logged: just the name.
    expect(storyLine(hand(3, null, StoryTag.cooler, at(21, 4)), hero: 'Sage'),
        'Cooler · Sage · 9:04pm');
  });

  test('shared cards from other phones: "John KK vs Joe AA"', () {
    final h = hand(7, 'KsKh', StoryTag.badBeat, at(20, 22));
    const joe = ShownHand('Joe', null);
    expect(storyLine(h, hero: 'John', others: [ShownHand('Joe', parseCards('AcAd'))]),
        'Bad beat · John KK vs Joe AA · 8:22pm');
    expect(storyLine(h, hero: 'John', others: const [joe]),
        'Bad beat · John KK vs Joe · 8:22pm');
    // The dashboard line takes the same lookup per hand.
    final line = dramaLine([h],
        hero: 'John',
        shared: (x) => x.number == 7 ? [ShownHand('Joe', parseCards('AcAd'))] : const []);
    expect(line, 'Bad beat · John KK vs Joe AA · 8:22pm');
    final m = dashboardMoments([h], SpotLibrary(const [], const []), hero: 'John',
        shared: (_) => [ShownHand('Joe', parseCards('AcAd'))]);
    expect(m.firstWhere((x) => x.label == "Tonight's drama").detail,
        'John KK vs Joe AA · 8:22pm');
  });

  test('drama line: newest first, only the hands it is given', () {
    final hands = [
      hand(1, 'AsKd', StoryTag.badBeat, at(20, 22)),
      hand(2, null, null, at(20, 25)),
      hand(3, '7c2d', StoryTag.bluff, at(20, 31)),
    ];
    expect(dramaLine(hands, hero: 'Sage'),
        'Bluff got through · Sage 72o · 8:31pm  |  Bad beat · Sage AKo · 8:22pm');
    // The TV passes only hands past its delay cutoff.
    final cutoff = at(20, 30);
    expect(dramaLine([for (final h in hands) if (h.ts <= cutoff) h], hero: 'Sage'),
        'Bad beat · Sage AKo · 8:22pm');
  });
}
