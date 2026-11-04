import 'package:felt_notes/camera/watch_buzz.dart';
import 'package:felt_notes/camera/watch_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one buzz for a read, two for a correction, none otherwise', () {
    expect(buzzCount(WatchAction.fill), 1);
    expect(buzzCount(WatchAction.newHand), 1);
    expect(buzzCount(WatchAction.correct), 2);
    expect(buzzCount(WatchAction.confirm), 0);
    expect(buzzCount(WatchAction.ignore), 0);
    // A hand counted without cards: nothing was read, no buzz.
    expect(buzzCount(WatchAction.newHandUnread), 0);
  });

  test('the notification text never contains a card', () {
    for (final a in WatchAction.values) {
      for (final c in [null, 0.0, 0.5, 0.873, 1.0]) {
        // The percentage is the only number allowed in the title.
        final t = buzzTitle(a, c).replaceAll(RegExp(r' · \d{1,3}%$'), '');
        expect(t, startsWith('Felt Notes'));
        expect(RegExp(r'[♠♥♦♣]|\b(ace|king|queen|jack|ten|[2-9]|[AKQJT][shdc])\b', caseSensitive: false).hasMatch(t),
            isFalse, reason: t);
      }
    }
  });

  test('the title carries the certainty as a percentage when known', () {
    expect(buzzTitle(WatchAction.fill), 'Felt Notes: cards read');
    expect(buzzTitle(WatchAction.fill, 0.873), 'Felt Notes: cards read · 87%');
    expect(buzzTitle(WatchAction.newHand, 0.5), 'Felt Notes: cards read · 50%');
    expect(buzzTitle(WatchAction.correct, 0.42), 'Felt Notes: cards corrected · 42%');
    expect(buzzTitle(WatchAction.fill, 1.2), 'Felt Notes: cards read · 100%');
    expect(buzzTitle(WatchAction.fill, double.nan), 'Felt Notes: cards read');
  });
}
