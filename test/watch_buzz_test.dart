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
      final t = buzzTitle(a);
      expect(t, startsWith('Felt Notes'));
      expect(RegExp(r'[♠♥♦♣]|\b(ace|king|queen|jack|ten|[2-9]|[AKQJT][shdc])\b', caseSensitive: false).hasMatch(t),
          isFalse, reason: t);
    }
  });
}
