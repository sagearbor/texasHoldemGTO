import 'package:felt_notes/camera/watch_certainty.dart';
import 'package:felt_notes/camera/watch_pipeline.dart';
import 'package:felt_notes/camera/watch_tracker.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> p(String s) => parseCards(s);

void main() {
  group('watchCertainty', () {
    test('formula: weaker score x agreement x rival', () {
      expect(watchCertainty(0.9, 0.8, agree: 1), closeTo(0.8 * 0.7, 1e-9));
      expect(watchCertainty(0.9, 0.8, agree: 2), closeTo(0.8 * 0.85, 1e-9));
      expect(watchCertainty(0.9, 0.8, agree: 3), closeTo(0.8 * 0.925, 1e-9));
      expect(watchCertainty(0.9, 0.8, agree: 2, rival: 1), closeTo(0.8 * 0.85 * 0.75, 1e-9));
      expect(watchCertainty(1, 1, agree: 40), lessThanOrEqualTo(1));
      expect(watchCertainty(0, 1, agree: 5), 0);
    });

    test('unknown scores give no certainty', () {
      expect(watchCertainty(null, 0.9, agree: 3), isNull);
      expect(watchCertainty(0.9, null, agree: 3), isNull);
    });

    test('monotone in scores, agreement and rival', () {
      for (var a = 1; a <= 6; a++) {
        for (var r = 0; r < a; r++) {
          for (final s in [0.5, 0.7, 0.9]) {
            final c = watchCertainty(s, 0.95, agree: a, rival: r)!;
            expect(watchCertainty(s + 0.05, 0.95, agree: a, rival: r)!, greaterThanOrEqualTo(c));
            expect(watchCertainty(s, 0.95, agree: a + 1, rival: r)!, greaterThanOrEqualTo(c));
            if (r + 1 < a) expect(watchCertainty(s, 0.95, agree: a, rival: r + 1)!, lessThanOrEqualTo(c));
            expect(c, inInclusiveRange(0, 1));
          }
        }
      }
    });

    test('meanScore skips unknowns', () {
      expect(meanScore([0.5, null, 0.7]), closeTo(0.6, 1e-9));
      expect(meanScore([null]), isNull);
    });

    test('evidence logs its raw parts', () {
      const e = PairEvidence(scoreHigh: 0.91234, scoreLow: 0.8, agree: 2, rival: 1, via: 'window');
      expect(e.toJson(), {
        'certainty': 0.51,
        'scoreHigh': 0.912,
        'scoreLow': 0.8,
        'agree': 2,
        'rival': 1,
        'via': 'window',
      });
    });
  });

  group('PeekVoter evidence', () {
    test('window: mean score per card over its frames, agree, rival', () {
      final v = PeekVoter(minAgree: 2);
      expect(v.add(p('Kd As'), 0, [0.6, 0.9]), isNull);
      expect(v.lastEvidence, isNull);
      v.add(p('As Kh'), 100, [0.8, 0.55]);
      expect(v.add(p('As Kd'), 200, [0.7, 0.8]), p('As Kd'));
      final e = v.lastEvidence!;
      expect(e.via, 'window');
      expect(e.scoreHigh, closeTo((0.9 + 0.8 + 0.7) / 3, 1e-9), reason: 'As, high card');
      expect(e.scoreLow, closeTo((0.6 + 0.8) / 2, 1e-9), reason: 'Kd');
      expect(e.agree, 2);
      expect(e.rival, 1, reason: 'Kh once');
    });

    test('memory: across peeks, the remembered frames of the pair', () {
      final v = PeekVoter(minAgree: 2, windowMs: 2500, memoryMs: 90000);
      v.add(p('As Kd'), 0, [0.9, 0.7]);
      expect(v.add(p('Kd As'), 20000, [0.5, 0.8]), p('As Kd'));
      final e = v.lastEvidence!;
      expect(e.via, 'memory');
      expect(e.scoreHigh, closeTo(0.85, 1e-9));
      expect(e.scoreLow, closeTo(0.6, 1e-9));
      expect((e.agree, e.rival), (2, 0));
    });

    test('scores never change which pair is agreed', () {
      final reads = [
        ('As Kd', 0), ('As Kh', 100), ('As Kd', 200), ('', 400), ('As', 600), //
        ('Qc 7h', 9000), ('7h', 9100), ('Qc 7h', 30000), ('Qc 7d', 30100),
      ];
      final a = PeekVoter(minAgree: 2), b = PeekVoter(minAgree: 2);
      for (final (s, t) in reads) {
        final cards = s.isEmpty ? <int>[] : p(s);
        expect(b.add(cards, t, [for (final _ in cards) 0.1]), a.add(cards, t), reason: '$s @$t');
      }
    });

    test('no scores: evidence without a certainty', () {
      final v = PeekVoter(minAgree: 2);
      v.add(p('As Kd'), 0);
      v.add(p('As Kd'), 100);
      expect(v.lastEvidence!.agree, 2);
      expect(v.lastEvidence!.certainty, isNull);
    });
  });

  group('WatchDecision certainty', () {
    const e = PairEvidence(scoreHigh: 0.9, scoreLow: 0.9, agree: 2, via: 'window');

    test('rides on fill / correct / newHand only, without changing them', () {
      final t = WatchHandTracker(), plain = WatchHandTracker();
      final fill = t.onRead(p('As Kd'), 0, episode: 1, evidence: e);
      expect(fill.action, plain.onRead(p('As Kd'), 0, episode: 1).action);
      expect(fill.action, WatchAction.fill);
      expect(fill.certainty, closeTo(0.9 * 0.85, 1e-9));
      final confirm = t.onRead(p('As Kd'), 100, episode: 1, evidence: e);
      expect(confirm.action, WatchAction.confirm);
      expect(confirm.certainty, isNull);
      final correct = t.onRead(p('As Kh'), 200, episode: 1, evidence: e);
      expect(correct.action, WatchAction.correct);
      expect(correct.certainty, isNotNull);
      final next = t.onRead(p('7c 2d'), 9000, episode: 2, evidence: e);
      expect(next.action, WatchAction.newHand);
      expect(next.evidence, same(e));
    });

    test('existing constructors still work, certainty unknown', () {
      expect(const WatchDecision(WatchAction.fill, [1, 2]).certainty, isNull);
    });
  });
}
