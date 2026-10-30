import 'package:felt_notes/camera/watch_pipeline.dart';
import 'package:felt_notes/camera/watch_tracker.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> p(String s) => parseCards(s);

void main() {
  group('WatchHandTracker', () {
    test('first read fills the hand, high card first', () {
      final t = WatchHandTracker();
      final d = t.onRead(p('Kd As'), 1000);
      expect(d.action, WatchAction.fill);
      expect(d.cards, p('As Kd'));
      expect(d.speaks, isTrue);
      expect(spokenDecision(d), 'Ace of spades, king of diamonds');
    });

    test('the same cards again are a silent confirmation, never a new log', () {
      final t = WatchHandTracker();
      t.onRead(p('As Kd'), 0);
      for (final ms in [500, 4000, 30000, 90000, 200000]) {
        final d = t.onRead(p('Kd As'), ms);
        expect(d.action, WatchAction.confirm, reason: 'at $ms ms');
        expect(d.speaks, isFalse);
        expect(spokenDecision(d), isNull);
      }
      expect(t.cards, p('As Kd'));
    });

    test('different cards soon after are a correction', () {
      final t = WatchHandTracker(correctionMs: 12000);
      t.onRead(p('As Kd'), 0);
      final d = t.onRead(p('As Kh'), 8000);
      expect(d.action, WatchAction.correct);
      expect(d.previous, p('As Kd'));
      expect(t.cards, p('As Kh'));
      expect(spokenDecision(d), 'Corrected. Ace of spades, king of hearts');
      // The window restarts from the correction.
      expect(t.onRead(p('As Kc'), 19000).action, WatchAction.correct);
    });

    test('confirmations do not extend the correction window', () {
      final t = WatchHandTracker(correctionMs: 12000);
      t.onRead(p('As Kd'), 0);
      t.onRead(p('As Kd'), 10000);
      expect(t.onRead(p('7c 2d'), 14000).action, WatchAction.newHand);
    });

    test('different cards later start a new hand', () {
      final t = WatchHandTracker(correctionMs: 12000);
      t.onRead(p('As Kd'), 0);
      final d = t.onRead(p('7c 2d'), 60000);
      expect(d.action, WatchAction.newHand);
      expect(d.previous, p('As Kd'));
      expect(d.cards, p('7c 2d'));
      expect(spokenDecision(d), 'Seven of clubs, two of diamonds');
      // ...and those are now the current hand.
      expect(t.onRead(p('2d 7c'), 70000).action, WatchAction.confirm);
    });

    test('after Next hand the first read fills again', () {
      final t = WatchHandTracker();
      t.onRead(p('As Kd'), 0);
      t.handClosed();
      expect(t.cards, isNull);
      expect(t.onRead(p('7c 2d'), 1000).action, WatchAction.fill);
    });

    test('identical cards in two consecutive hands merge (documented, ~1/1326)', () {
      final t = WatchHandTracker();
      t.onRead(p('Qh Jh'), 0);
      // Next hand dealt the very same two cards; nobody tapped Next hand.
      expect(t.onRead(p('Qh Jh'), 120000).action, WatchAction.confirm);
      // With Next hand tapped in between they are logged again.
      t.handClosed();
      expect(t.onRead(p('Qh Jh'), 121000).action, WatchAction.fill);
    });

    test('a manual fix vetoes the misread for the rest of the hand', () {
      final t = WatchHandTracker(correctionMs: 12000);
      t.onRead(p('As Kd'), 0); // misread
      t.manualCards(p('As Kh'), 3000); // player fixes it
      // The same misread on later peeks is ignored, never a new hand.
      expect(t.onRead(p('As Kd'), 5000).action, WatchAction.ignore);
      expect(t.onRead(p('As Kd'), 60000).action, WatchAction.ignore);
      expect(t.cards, p('As Kh'));
      expect(t.onRead(p('Kh As'), 61000).action, WatchAction.confirm);
      // A really different pair later is the next hand, and the veto ends.
      expect(t.onRead(p('9c 9d'), 90000).action, WatchAction.newHand);
      expect(t.onRead(p('As Kd'), 200000).action, WatchAction.newHand);
    });

    test('the camera never "corrects" a manual pick', () {
      final t = WatchHandTracker(correctionMs: 12000);
      t.manualCards(p('Ts 9s'), 0);
      expect(t.onRead(p('Ts 9s'), 1000).action, WatchAction.confirm);
      expect(t.onRead(p('Td 9s'), 2000).action, WatchAction.ignore);
      expect(t.cards, p('Ts 9s'));
      // Long after the pick, different cards are the next hand.
      expect(t.onRead(p('Td 9s'), 30000).action, WatchAction.newHand);
    });

    group('with card episodes (cards up .. put down)', () {
      test('a different pair in the same episode is a correction, however late', () {
        final t = WatchHandTracker(correctionMs: 12000);
        t.onRead(p('As Kd'), 0, episode: 1);
        expect(t.onRead(p('As Kh'), 30000, episode: 1).action, WatchAction.correct);
      });

      test('a different pair after the cards went down is the next hand, however soon', () {
        // The owner's test footage: a new hand every ~5 s.
        final t = WatchHandTracker(correctionMs: 12000);
        t.onRead(p('7c 2d'), 0, episode: 1);
        final d = t.onRead(p('Jh 6c'), 5000, episode: 2);
        expect(d.action, WatchAction.newHand);
        expect(d.previous, p('7c 2d'));
        // The same cards again in a later episode: a re-peek, silent.
        expect(t.onRead(p('6c Jh'), 9000, episode: 3).action, WatchAction.confirm);
      });

      test('a corrected pair keeps its episode', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 4);
        t.onRead(p('As Kh'), 500, episode: 4);
        expect(t.onRead(p('As Kc'), 900, episode: 4).action, WatchAction.correct);
        expect(t.onRead(p('9s 9d'), 3000, episode: 5).action, WatchAction.newHand);
      });

      test('after a manual pick, time decides again (no episode on record)', () {
        final t = WatchHandTracker(correctionMs: 12000);
        t.manualCards(p('Ts 9s'), 0);
        expect(t.onRead(p('Td 9s'), 1000, episode: 7).action, WatchAction.ignore);
        expect(t.onRead(p('Td 9s'), 20000, episode: 8).action, WatchAction.newHand);
      });
    });

    group('missed hands still count (no hand drift)', () {
      Set<int> s(String c) => p(c).toSet();

      test('a look with a card not in the hand starts an unread hand', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 1, scene: 1);
        final d = t.onLookEnd(s('7c'), 6000, scene: 2);
        expect(d.action, WatchAction.newHandUnread);
        expect(d.startsHand, isTrue);
        expect(d.previous, p('As Kd'));
        expect(t.cards, isNull);
        expect(t.partial, s('7c'));
      });

      test('a look showing only the current cards is a re-peek', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 1, scene: 1);
        expect(t.onLookEnd(s('Kd'), 6000, scene: 2).action, WatchAction.confirm);
        expect(t.cards, p('As Kd'));
      });

      test('the two cards of a missed hand seen on two looks stay one hand', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 1, scene: 1);
        expect(t.onLookEnd(s('7c'), 6000, scene: 2).action, WatchAction.newHandUnread);
        expect(t.onLookEnd(s('2d'), 8000, scene: 2).action, WatchAction.ignore);
        // A third card: yet another hand.
        expect(t.onLookEnd(s('9h'), 15000, scene: 3).action, WatchAction.newHandUnread);
      });

      test('an agreed pair that fits the seen cards fills the unread hand', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 1, scene: 1);
        t.onLookEnd(s('7c'), 6000, scene: 2);
        expect(t.onRead(p('7c 2d'), 7000, episode: 2, scene: 2).action, WatchAction.fill);
      });

      test('an agreed pair that does not fit closes the unread hand', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 1, scene: 1);
        t.onLookEnd(s('7c'), 6000, scene: 2);
        expect(t.onRead(p('Qh Jh'), 12000, episode: 3, scene: 3).action, WatchAction.newHand);
      });

      test('in the same scene, a look with only one current card is a re-peek', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 1, scene: 4);
        expect(t.onLookEnd(s('As'), 3000, scene: 4).action, WatchAction.confirm);
        // One current card and one new one: new cards were dealt.
        expect(t.onLookEnd(s('As 7c'), 6000, scene: 4).action, WatchAction.newHandUnread);
      });
    });

    group('corrections across peeks of one hand (no split)', () {
      test('same scene, one card kept, the other a likely misread: a correction', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 1, scene: 2);
        // K♦ -> K♥: same rank, the suit was misread.
        expect(t.onRead(p('As Kh'), 9000, episode: 2, scene: 2).action, WatchAction.correct);
        // A♠ -> 4♠: same suit, the rank was misread.
        expect(t.onRead(p('4s Kh'), 12000, episode: 3, scene: 2).action, WatchAction.correct);
      });

      test('same scene, one card kept but the other unrelated: the next hand', () {
        // From the owner's footage: A♠ T♠ then T♠ T♥ was a new hand.
        final t = WatchHandTracker();
        t.onRead(p('As Ts'), 0, episode: 1, scene: 2);
        expect(t.onRead(p('Ts Th'), 9000, episode: 2, scene: 2).action, WatchAction.newHand);
      });

      test('same scene, no card kept: the next hand', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 1, scene: 2);
        expect(t.onRead(p('7c 2d'), 9000, episode: 2, scene: 2).action, WatchAction.newHand);
      });

      test('the view cleared in between: the next hand even with a shared card', () {
        final t = WatchHandTracker();
        t.onRead(p('As Kd'), 0, episode: 1, scene: 2);
        expect(t.onRead(p('As Kh'), 9000, episode: 2, scene: 3).action, WatchAction.newHand);
      });
    });

    test('a pair of the same card is ignored', () {
      final t = WatchHandTracker();
      expect(t.onRead([12, 12], 0).action, WatchAction.ignore);
      expect(t.cards, isNull);
    });
  });

  group('PeekVoter', () {
    test('needs two agreeing frames', () {
      final v = PeekVoter(minAgree: 2);
      expect(v.add(p('As Kd'), 0), isNull);
      expect(v.add(p('As Kd'), 100), p('As Kd'));
    });

    test('one card per frame is enough when they were also seen together', () {
      final v = PeekVoter(minAgree: 2);
      expect(v.add(p('As'), 0), isNull);
      expect(v.add(p('Kd'), 100), isNull, reason: 'never seen together');
      expect(v.add(p('As Kd'), 200), p('As Kd'));
    });

    test('a single conflicting misread among agreeing reads is outvoted', () {
      final v = PeekVoter(minAgree: 2);
      v.add(p('As Kd'), 0);
      expect(v.add(p('As Kh'), 100), isNull);
      expect(v.add(p('As Kd'), 200), p('As Kd'));
      expect(v.add(p('As Kd'), 300), p('As Kd'));
    });

    test('two competing reads with equal support give nothing', () {
      final v = PeekVoter(minAgree: 2);
      v.add(p('As Kd'), 0);
      v.add(p('As Kh'), 100);
      v.add(p('As Kh'), 200);
      expect(v.add(p('As Kd'), 300), isNull);
      expect(v.bestAgree, 2);
    });

    test('old reads leave the window', () {
      // Single cards only: the cross-peek pair memory does not apply.
      final v = PeekVoter(minAgree: 2, windowMs: 2500);
      v.add(p('As'), 0);
      v.add(p('Kd'), 50);
      // The single reads at 0 / 50 ms have left the window: one frame only.
      expect(v.add(p('As Kd'), 3000), isNull);
      expect(v.add(p('Kd As'), 3100), p('As Kd'));
    });

    test('without pair memory, old pair reads leave the window too', () {
      final v = PeekVoter(minAgree: 2, windowMs: 2500, memoryMs: 0);
      v.add(p('As Kd'), 0);
      expect(v.add(p('As Kd'), 3000), isNull);
      expect(v.add(p('As Kd'), 3100), p('As Kd'));
    });

    test('a pair seen once on each of two quick peeks agrees', () {
      final v = PeekVoter(minAgree: 2, windowMs: 2500, memoryMs: 90000);
      expect(v.add(p('As Kd'), 0), isNull);
      expect(v.add(p('As'), 300), isNull);
      // Next peek, 20 s later: one more frame with both cards.
      expect(v.add(p('Kd As'), 20000), p('As Kd'));
    });

    test('across peeks a rival pair seen as often blocks it', () {
      final v = PeekVoter(minAgree: 2, memoryMs: 90000);
      v.add(p('As Kd'), 0);
      v.add(p('As Kh'), 10000);
      v.add(p('As Kh'), 13000 + 3000);
      // Kh now has 2 frames (window passed though): it wins as a pair.
      expect(v.add(p('As Kd'), 30000), isNull);
    });

    test('memory is forgotten after a new hand or a long time', () {
      final v = PeekVoter(minAgree: 2, memoryMs: 90000);
      v.add(p('As Kd'), 0);
      v.reset();
      expect(v.add(p('As Kd'), 20000), isNull);
      expect(v.add(p('As Kd'), 200000), isNull);
    });

    test('empty frames do not vote', () {
      final v = PeekVoter(minAgree: 2);
      v.add(p('As Kd'), 0);
      expect(v.add([], 50), isNull);
      expect(v.add(p('As Kd'), 100), p('As Kd'));
    });
  });

  test('spoken card names', () {
    expect(spokenPair(p('Tc 2h')), 'Ten of clubs, two of hearts');
    expect(spokenPair(p('Jd Qs')), 'Queen of spades, jack of diamonds');
  });
}
