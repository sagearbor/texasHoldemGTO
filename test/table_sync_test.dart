import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/sync/fake_table_sync.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeTableBackend server;
  late FakeTableSync host, alice, bob, cy;
  late String code;

  /// Host + three friends, seated host, alice, bob, cy with the host dealing hand 1.
  Future<void> night() async {
    server = FakeTableBackend();
    host = FakeTableSync(server, 'h');
    alice = FakeTableSync(server, 'a');
    bob = FakeTableSync(server, 'b');
    cy = FakeTableSync(server, 'c');
    code = await host.createTable(name: 'Friday', hostName: 'Host');
    await alice.join(code.toLowerCase(), 'Alice');
    await bob.join(code, ' Bob ');
    await cy.join(code, 'Cy');
    await host.seatPlayers(code, ['h', 'a', 'b', 'c'], dealer: 'h');
  }

  group('joining', () {
    test('join codes avoid look-alike characters', () async {
      await night();
      expect(isValidJoinCode(code), isTrue);
      expect(code.contains(RegExp('[01OI]')), isFalse);
      expect(normalizeJoinCode(' ab-c 234'), 'ABC234');
      expect(isValidJoinCode('ABC10O'), isFalse);
    });

    test('players join with display names; host seats them', () async {
      await night();
      final t = await alice.table(code);
      expect(t.hostUid, 'h');
      expect(t.seatsAt(1), ['h', 'a', 'b', 'c']);
      expect(t.names['b'], 'Bob');
      expect((await bob.players(code)).map((p) => p.name), containsAll(['Host', 'Alice', 'Bob', 'Cy']));
    });

    test('only the host seats people, and only people who joined', () async {
      await night();
      expect(() => alice.seatPlayers(code, ['a', 'h']), throwsA(isA<SyncDenied>()));
      expect(() => host.seatPlayers(code, ['h', 'zz']), throwsA(isA<SyncDenied>()));
      final stranger = FakeTableSync(server, 'x');
      expect(() => stranger.entries(code), throwsA(isA<SyncDenied>()));
      expect(() => FakeTableSync(server, 'y').join('ZZZZZZ', 'Y'), throwsA(isA<SyncDenied>()));
    });
  });

  group('hand numbering from the shared button', () {
    test('every phone derives the same dealer and its own position', () async {
      await night();
      final t = await cy.table(code);
      expect([for (var n = 1; n <= 5; n++) t.nameOf(t.dealerOf(n))],
          ['Host', 'Alice', 'Bob', 'Cy', 'Host']);
      // 4-handed, host on the button: alice SB, bob BB, cy UTG.
      expect(t.positionOf('a', 1), 'SB');
      expect(t.positionOf('b', 1), 'BB');
      expect(t.positionOf('c', 1), 'UTG');
      expect(t.positionOf('c', 2), 'BB');
    });

    test('two phones tapping Next hand for the same deal advance it once', () async {
      await night();
      expect(await alice.advanceHand(code, from: 1), isTrue);
      expect(await bob.advanceHand(code, from: 1), isFalse);
      expect((await host.table(code)).currentHand, 2);
    });

    test('seat changes mid-night keep old hands\' dealers', () async {
      await night();
      for (var n = 1; n <= 3; n++) {
        await host.advanceHand(code, from: n);
      }
      // Hand 4: Cy deals. Bob leaves, Dee joins between Host and Alice.
      final dee = FakeTableSync(server, 'd');
      await dee.join(code, 'Dee');
      await host.seatPlayers(code, ['h', 'd', 'a', 'c']);
      final t = await dee.table(code);
      expect(t.nameOf(t.dealerOf(3)), 'Bob');
      expect(t.nameOf(t.dealerOf(4)), 'Cy');
      expect(t.nameOf(t.dealerOf(5)), 'Host');
      expect(t.nameOf(t.dealerOf(6)), 'Dee');
      expect(t.positionOf('b', 4), isNull);
    });

    test('a leaving dealer passes the button to the next seat', () async {
      await night();
      await host.advanceHand(code, from: 1); // hand 2: Alice deals
      await host.seatPlayers(code, ['h', 'b', 'c']);
      final t = await host.table(code);
      expect(t.nameOf(t.dealerOf(2)), 'Bob');
    });

    test('host can correct the dealer for the current hand', () async {
      await night();
      await host.setDealer(code, 'b');
      final t = await host.table(code);
      expect(t.nameOf(t.dealerOf(1)), 'Bob');
      expect(t.nameOf(t.dealerOf(2)), 'Cy');
      expect(() => alice.setDealer(code, 'a'), throwsA(isA<SyncDenied>()));
    });

    test('entries record the position derived for that hand', () async {
      await night();
      await alice.logEntry(code, handNo: 1, action: PreAction.raise, facing: Facing.unopened, hasCards: true);
      final e = (await host.entries(code)).single;
      expect(e.position, 'SB');
      expect(() => alice.logEntry(code, handNo: 2, hasCards: false), throwsA(isA<SyncDenied>()));
    });
  });

  group('late entry', () {
    test('the hand is fixed when you start, not when you save', () async {
      await night();
      final draft = EntryDraft(await bob.table(code));
      expect(draft.banner(await bob.table(code)), isNull);
      await host.advanceHand(code, from: 1);
      final now = await bob.table(code);
      expect(draft.banner(now), 'Saving to hand #1 (Host dealt). The table is on #2.');
      await bob.logEntry(code, handNo: draft.handNo, action: PreAction.call, hasCards: true);
      expect((await host.entries(code)).single.handNo, 1);
    });

    test('match by board, not by time', () async {
      await night();
      // Hands 1-5; the board caller recorded hands 2 and 4. Hand 3 was folded preflop.
      for (var n = 1; n <= 5; n++) {
        if (n == 2) await host.recordBoard(code, 2, parseCards('Ks 7d 2c 9h'));
        if (n == 4) await host.recordBoard(code, 4, parseCards('Ah Kd 7s'));
        if (n < 5) await host.advanceHand(code, from: n);
      }
      final t = await cy.table(code);
      final boards = await cy.boards(code);

      final all = handChoices(t, boards, logged: {5});
      expect(all.map((c) => c.handNo), [5, 4, 3, 2, 1]);
      expect(all.first.isCurrent, isTrue);
      expect(all.first.logged, isTrue);
      expect(all[1].dealerName, 'Cy');
      expect(all[1].board!.cards, parseCards('Ah Kd 7s'));
      expect(all[2].board, isNull);

      // "The hand with the king and the seven": both boards have them, so
      // both are offered, the one with matching suits first; a third card
      // settles it.
      expect(handChoices(t, boards, hint: parseCards('Ks 7d')).map((c) => c.handNo), [2, 4]);
      expect(handChoices(t, boards, hint: parseCards('Kd 7s')).map((c) => c.handNo), [4, 2]);
      expect(handChoices(t, boards, hint: parseCards('Kc 7c 9c')).map((c) => c.handNo), [2]);
      // Nothing matches fully: best partial first, then newest.
      final partial = handChoices(t, boards, hint: parseCards('Ah Qc'));
      expect(partial.first.handNo, 4);
      expect(partial.first.matched, 1);

      await cy.logEntry(code, handNo: 2, action: PreAction.fold, hasCards: false);
      expect((await host.entries(code)).single.position, 'BB');
    });

    test('only the board caller writes boards; turn and river overwrite', () async {
      await night();
      expect(() => alice.recordBoard(code, 1, parseCards('2c 3c 4c')), throwsA(isA<SyncDenied>()));
      await host.setBoardCaller(code, 'a');
      await alice.recordBoard(code, 1, parseCards('2c 3c 4c'));
      await alice.recordBoard(code, 1, parseCards('2c 3c 4c 5d 9s'));
      expect((await bob.boards(code)).single.cards.length, 5);
      expect(() => alice.recordBoard(code, 1, parseCards('2c 3c')), throwsA(isA<SyncDenied>()));
      expect(() => alice.recordBoard(code, 2, parseCards('2c 3c 4c')), throwsA(isA<SyncDenied>()));
    });
  });

  group('give-to-get', () {
    test('cards are private until revealed, and reveals need sharing', () async {
      await night();
      await alice.saveCards(code, 1, parseCards('As Ah'));
      await bob.saveCards(code, 1, parseCards('7c 2d'), reveal: true);
      await host.advanceHand(code, from: 1);

      expect((await alice.myCards(code)).single.cards, parseCards('As Ah'));
      expect(() => alice.revealedCards(code), throwsA(isA<SyncDenied>()));
      expect(() => cy.revealedCards(code), throwsA(isA<SyncDenied>()));

      await cy.startSharing(code);
      final cySees = await cy.revealedCards(code);
      expect(cySees.map((c) => c.uid), ['b']); // alice never revealed

      await alice.startSharing(code);
      expect(() => alice.saveCards(code, 2, parseCards('Kd Qd')), throwsA(isA<SyncDenied>()));
      await alice.saveCards(code, 2, parseCards('Kd Qd'), reveal: true);
      await alice.revealCards(code, 1);
      // Hand 2 is still being played: not visible yet.
      expect((await cy.revealedCards(code)).map((c) => c.id), ['a_1', 'b_1']);
      await host.advanceHand(code, from: 2);
      expect((await cy.revealedCards(code)).map((c) => c.id), ['a_1', 'b_1', 'a_2']);
      // You never get your own cards back through the reveal feed.
      expect((await alice.revealedCards(code)).map((c) => c.id), ['b_1']);
    });

    test('a reveal cannot be taken back by saving again', () async {
      await night();
      await bob.saveCards(code, 1, parseCards('7c 2d'), reveal: true);
      await bob.saveCards(code, 1, parseCards('7c 3d'));
      await host.startSharing(code);
      await host.advanceHand(code, from: 1);
      expect((await host.revealedCards(code)).single.revealed, isTrue);
    });
  });

  group('dashboard aggregates', () {
    test('VPIP/PFR/style from public actions, behind the delay', () async {
      await night();
      final start = server.now;
      // 12 hands: alice raises every hand, bob calls half, cy folds all.
      for (var n = 1; n <= 12; n++) {
        await alice.logEntry(code, handNo: n, action: PreAction.raise, facing: Facing.unopened, hasCards: true);
        await bob.logEntry(code,
            handNo: n, action: n.isEven ? PreAction.call : PreAction.fold, facing: Facing.raised, hasCards: false);
        await cy.logEntry(code, handNo: n, action: PreAction.fold, hasCards: true);
        server.now += 2 * 60000;
        await host.advanceHand(code, from: n);
      }
      final t = await host.table(code);
      final players = await host.players(code);
      final entries = await host.entries(code);

      // Right after the last hand (24 min in), a 15-minute delay counts only
      // entries written in the first 9 minutes: hands 1-5.
      final now = DateTime.fromMillisecondsSinceEpoch(server.now);
      final early = {for (final a in tableAggregates(t, players, entries, now: now)) a.uid: a};
      expect(early['a']!.recorded, 5);
      expect(early['a']!.style, 'Too early to tell');
      expect(early['h']!.logged, 0);

      final later = DateTime.fromMillisecondsSinceEpoch(start + 60 * 60000);
      final agg = {for (final a in tableAggregates(t, players, entries, now: later)) a.uid: a};
      expect(agg['a']!.recorded, 12);
      expect(agg['a']!.vpipPct, 1.0);
      expect(agg['a']!.pfrPct, 1.0);
      expect(agg['a']!.style, 'Maniac');
      expect(agg['b']!.vpipPct, 0.5);
      expect(agg['b']!.pfr, 0);
      expect(agg['b']!.style, 'Calling Station');
      expect(agg['c']!.style, 'Rock');

      // Zero delay still never counts the hand in play.
      await alice.logEntry(code, handNo: 13, action: PreAction.raise, hasCards: false);
      final instant = tableAggregates(t.copyWith(delayMin: 0), players, await host.entries(code), now: later);
      expect(instant.firstWhere((a) => a.uid == 'a').recorded, 12);
    });

    test('the dashboard sees actions but never hole cards', () async {
      await night();
      await alice.saveCards(code, 1, parseCards('As Ah'));
      await alice.logEntry(code, handNo: 1, action: PreAction.raise, hasCards: true);
      final e = (await host.entries(code)).single;
      expect(e.toJson().containsKey('cards'), isFalse);
      expect(e.hasCards, isTrue);
    });
  });

  group('migration to the local model', () {
    test('a synced hand becomes a normal LoggedHand', () async {
      await night();
      await alice.saveCards(code, 1, parseCards('As Ah'));
      await alice.logEntry(code, handNo: 1, action: PreAction.raise, facing: Facing.unopened, hasCards: true);
      final t = await alice.table(code);
      final h = loggedHandFrom(t, 'a', 1,
          entry: (await alice.entries(code)).single, cards: (await alice.myCards(code)).single);
      expect(h.number, 1);
      expect(h.position, 'SB');
      expect(h.dealer, 'Host');
      expect(h.hand!.name, 'AA');
      expect(h.action, PreAction.raise);
      // A hand you never logged still gets dealer and position.
      final skipped = loggedHandFrom(t, 'a', 2);
      expect(skipped.skipped, isTrue);
      expect(skipped.dealer, 'Alice');
      expect(skipped.position, 'BTN');
    });
  });

  test('table listener sees every advance', () async {
    await night();
    final seen = <int>[];
    final sub = bob.watchTable(code).listen((t) => seen.add(t.currentHand));
    await Future<void>.delayed(Duration.zero);
    await host.advanceHand(code, from: 1);
    await alice.advanceHand(code, from: 2);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen.toSet(), {1, 2, 3});
  });
}
