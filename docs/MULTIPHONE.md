# Multi-phone table nights (prototype design)

Status: **prototype on a branch, not in the app.** Nothing here is deployed.
There is no Firebase project, no Firebase plugin in `pubspec.yaml`, and no
config file. What exists:

| Piece | File | State |
|---|---|---|
| Data model, hand numbering, late-entry matching, aggregates | `lib/sync/table_sync.dart` | done, unit-tested |
| In-memory backend that enforces the same rules | `lib/sync/fake_table_sync.dart` | done, used by tests |
| Firestore implementation | `lib/sync/firestore_table_sync.dart` | documented stub (every method throws; comments give the exact Firestore call) |
| Security rules | `firestore.rules` | done, 79 tests pass on the local emulator |
| Rules tests | `tool/firestore_rules/` (`./run.sh`) | local emulator, project id `demo-feltnotes` |
| Dart tests | `test/table_sync_test.dart` | 18 tests |

## 1. The question

> If friends each log their own hands on their own phone, how do the hands
> line up? People enter during the next deal, so timestamps are not enough,
> and only one person should record the flop, turn and river.

The answer has four parts:

1. **One shared hand counter, owned by the table.** The host's phone creates
   a "table night". The table document holds the seat order and the dealer
   button, and a `currentHand` number. Every phone works out the hand
   number, the dealer and its own position from that one document. No phone
   ever numbers hands on its own and nothing is matched by clock.
2. **An entry is pinned to a hand when you start it, not when you save it.**
   The moment you tap your first card or action, the form remembers "hand
   #42, Bob's deal". If you finish typing during the next deal the form
   says *Saving to hand #42 (Bob dealt). The table is on #43* and files it
   under #42.
3. **Late entries pick the hand from a list**: hand number, dealer, and the
   board if the board caller recorded it. You can type the board cards you
   remember ("king, seven") and the list narrows to the hands whose board
   has them ("match by board"). Time is never used to guess.
4. **One board caller.** Only the board caller (the host by default; the host
   can hand the job to anyone) may write boards. Everyone else only ever
   writes their own entries.

## 2. Data model (Firestore)

```
tables/{code}                      written by the host (members may only do "next hand")
  hostUid, name, createdAt, closed
  currentHand: int                 the hand being dealt now; hands below it are over
  boardCaller: uid
  delayMin: int                    TV dashboard delay (existing dashboardDelays)
  rotation: [ {from, seats[], button} ... ]   append-only seat history
  names: {uid: display name}

tables/{code}/players/{uid}        written by that phone only
  name, sharing: bool (false -> true only), joinedAt

tables/{code}/entries/{uid}_{n}    your public action for hand n (never cards)
  uid, handNo, action?, facing?, position, hasCards, ts (server time)

tables/{code}/boards/{n}           written by the board caller (or host)
  handNo, cards[3..5], by, ts

tables/{code}/cards/{uid}_{n}      your hole cards
  uid, handNo, cards[2], revealed: bool
```

Cards are the app's existing ints (`rank * 4 + suit`, `lib/poker/cards.dart`).
Actions are the existing `PreAction` / `Facing` enums, stored by name.

**Join code.** 6 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no
0/O/1/I, since codes are read out across a table): 32^6, about a billion
codes. The code is the document id. Anyone signed in can `get` a table by
its code; nobody can `list` tables, so codes cannot be enumerated. A QR code
would encode `https://<pages-site>/#/join?c=ABC234` (needs a QR package;
see decisions).

**Auth.** Firebase anonymous auth: each phone gets a uid with no account,
email or password. The display name is just a field.

### Hand numbering from the rotation

The host's table document holds an append-only list of seat segments. A
segment says "from hand `from`, these uids sit clockwise in `seats`, and
`seats[button]` deals hand `from`". The button moves one seat per hand, so
for any hand `h`:

```
seg     = last segment with seg.from <= h
dealer  = seg.seats[(seg.button + h - seg.from) % seg.seats.length]
position of uid = positionName(n, (seatOf(uid) - buttonSeat) % n)   // existing function
```

When someone sits down, leaves or the host corrects the dealer, the host
appends a new segment starting at the current hand (`TableState.reseat`).
Old segments are never edited, so hand #12 keeps Bob as its dealer even
after Bob goes home. If the dealer leaves, the button passes to the next
seated player clockwise.

**Next hand.** Any seated phone may raise `currentHand` by exactly one. The
rules only accept `new == old + 1`, so when two phones tap "Next hand" for
the same deal, the second write is rejected and the app treats that as
"already advanced" (`advanceHand` returns false). No transaction is needed.
The host may set any value that is not lower (to fix a missed tap).

### What each phone writes

| Who | Writes |
|---|---|
| host | the table document (seats, dealer fixes, board caller, close) |
| board caller | `boards/{n}`: 3 cards, then overwritten with 4 and 5 |
| every player | own `players/{uid}`, own `entries/{uid}_{n}`, own `cards/{uid}_{n}` |
| any member | `currentHand + 1` |

### Voice board entry

The voice feature being built separately only needs to produce
`(handNo, List<int> cards)` with 3, 4 or 5 cards and call
`TableSync.recordBoard(code, handNo, cards)`. Calling it again with more
cards adds the turn and river. The hand number to use is the board
caller's own `EntryDraft` for the hand (so a river called late still lands
on the right hand).

## 3. Privacy and give-to-get

Rules (`firestore.rules`, `match /cards/{cardId}`):

* Your cards are always readable by you.
* Someone else may read your cards only if **all** of:
  * you marked that hand `revealed`,
  * the hand is over (`handNo < currentHand`), so nobody sees cards in a hand
    still being played,
  * the reader is a member of the table **and is sharing** (`players/{me}.sharing`).
* `sharing` can be turned on but never off for that night.
* Once you share, every cards document you write must be `revealed: true`
  (that is the "give"). A non-sharer may still reveal a single hand (giving
  without getting).
* `revealed` can never go back to false, and revealed cards cannot be
  deleted.
* Entries (actions) never contain cards; unknown fields are rejected.

Firestore rules are not filters, so a query must prove it only asks for
allowed documents. The reveal feed is therefore:

```
cards.where('revealed', '==', true).where('handNo', '<', currentHand)
```

The emulator tests confirm that this query succeeds for a sharer, and that
the same query with a bound above `currentHand`, or without
`revealed == true`, is rejected.

What this does **not** protect against (and cannot, without a referee):

* A player can type fake cards. Give-to-get is enforced on visibility, not on
  honesty.
* "Private" means private from other players. Whoever administers the
  Firebase project can read everything in the console. If that matters, the
  recommended setting is to keep unrevealed cards on the phone only (see
  decision 1), so the cloud only ever holds cards people chose to show.
* Actions are readable by members as soon as they are written (they are
  public at the table anyway). The rules could delay them until the hand is
  over, but then the dashboard's single listener would need a moving query
  bound and would re-read the whole night every hand, which breaks the cost
  budget. The dashboard delay is applied by the app instead.

## 4. TV dashboard aggregates

`tableAggregates(table, players, entries, now:)` gives per player: entries
counted, hands with an action, VPIP, PFR and the same style label the app
already uses (`playStyle`, shared with `SessionStats`). It counts an entry
only when its hand is over **and** it was written at least `delayMin` minutes
ago (server timestamp, enforced by the rules), so the TV never shows the hand
that just finished. It needs only the public entries; no cards.

The dashboard is the host's phone mirrored to the TV (as today), so only that
one phone listens to `entries`.

## 5. Cost: stays inside the free tier

Firestore free tier (Spark plan, no billing account), **per project per
day**: 50,000 document reads, 20,000 writes, 20,000 deletes, 1 GiB stored.
Anonymous auth is free. On Spark there is no card on file, so going over a
quota cannot cost money: requests fail until the daily reset (midnight
Pacific) and the app keeps logging locally, as it does today.

Assumptions for one night: 8 players + the dashboard, 4 hours, 30 hands an
hour = 120 hands, everyone logs every hand (an upper bound; real logging is
patchier), 70% of hands see a flop.

**Writes**

| What | Count |
|---|---|
| Next hand | 120 |
| Seat changes, dealer fixes, joins, sharing | ~30 |
| Entries: 8 x 120, +20% edits | ~1,150 |
| Cards: 8 x 120 (full mode) | 960 |
| Reveal flips | ~200 |
| Boards: flop/turn/river on ~85 hands | ~250 |
| **Total** | **~2,700 (13% of 20,000)** |

**Reads**

| What | Count |
|---|---|
| Rules lookups (`get`/`exists` on table and player docs, billed as reads), ~2 per write | ~5,400 |
| Table listener on 9 devices x ~150 table updates | ~1,350 |
| Boards: listener only while the late-entry picker is open or on the board caller's phone, last 12 hands | ~1,500 |
| Dashboard listener on `entries` (1 device) | ~1,150 |
| Reveal feed: on demand, incremental (`handNo >= lastSeen`), 8 sharers | up to ~7,700 |
| Reconnects (a listener away more than 30 minutes re-reads its result set) and slack | ~3,000 |
| **Total** | **~20,000 (40% of 50,000)** |

**Lean mode** (recommended): unrevealed cards never leave the phone, and
nobody listens to boards except the board caller.

| | Writes | Reads |
|---|---|---|
| Full | ~2,700 | ~20,000 |
| Lean | ~1,800 | ~10,000 |

Storage: about 3,000 small documents (a few hundred bytes each) per night,
roughly 1-2 MB with indexes. Deleting a closed night costs ~3,000 of the
20,000 daily deletes.

**The real limit is shared, not per night.** The free quota belongs to the
project, and every friend group using the published app would use the same
project. At these numbers one project carries about 2 (full) to 5 (lean)
table nights per day across all users. That is plenty for the owner's own
games and a few friends' groups; it is not a public multiplayer service.
Ways to stretch it, cheapest first: lean mode; one project per friend group
(the owner can create several free projects); and only then a paid plan.

Listeners per device: **1** (table doc) on every player phone, **+1**
(entries) on the dashboard phone, **+1** (boards) on the board caller's phone
or while the picker is open. Everything else is a one-shot read.

## 6. UX flows

### Host: start a table night

```
+------------------------------+
| New game night               |
|  Name   [ Friday at Sam's  ] |
|  ( ) Just my phone           |
|  (o) Table night (phones)    |
|          [ Start ]           |
+------------------------------+
            |
            v
+------------------------------+
| Table night: Friday at Sam's |
|                              |
|      Join code  ABC 234      |
|        [ QR code ]           |
|                              |
|  Joined (tap to seat):       |
|   Host (you)       seat 1    |
|   Alice            seat 2    |
|   Bob              seat 3    |
|   Cy           [ seat ]      |
|  Dealer for hand 1: [Host v] |
|  Board caller:      [Host v] |
|        [ Deal hand 1 ]       |
+------------------------------+
```

### Player: join

```
+------------------------------+
| Join a table                 |
|  Code  [ A B C 2 3 4 ]       |
|  Name  [ Alice        ]      |
|          [ Join ]            |
|                              |
| Waiting for the host to      |
| seat you...                  |
+------------------------------+
```

### Logging a hand (any phone)

```
+------------------------------+
| Hand #42 . Bob deals . you CO|
|  [A s][K d]   (tap cards)    |
|  Facing: (o) unopened ( ) raise
|  [ Fold ] [ Call ] [ Raise ] |
|                              |
|  ! Saving to hand #42 (Bob   |
|    dealt). Table is on #43.  |   <- only once the table moved on
|        [ Save ]              |
|  [ Next hand -> #43 ]        |   <- any phone; duplicates ignored
+------------------------------+
```

### Late entry: which hand was it?

```
+------------------------------+
| Log an earlier hand          |
| Board had: [K][7][ ][ ][ ]   |
|                              |
|  #40  Alice dealt  Ks 7d 2c 9h|  <- both have K and 7;
|  #38  Host dealt   Kd 7s Ah  |     matching suits first
|  ---- all recent hands ----  |
|  #43  Cy dealt     (no board)|
|  #42  Bob dealt    Qh Jh 4c  |  logged
|  #41  Alice dealt  (no flop) |
+------------------------------+
```

### Board caller

```
+------------------------------+
| Board for hand #42 (Bob)     |
|  [Qh][Jh][4c][  ][  ]        |
|  [ mic: "queen jack four" ]  |   <- voice entry, same data
|  [ Turn ] [ River ]          |
+------------------------------+
```

### Sharing (give-to-get)

```
+------------------------------+
| Share your cards tonight?    |
| Others' shown hands are only |
| visible to people who share  |
| too. Once on, every hand you |
| enter is shown after it ends.|
| You can't turn it off until  |
| the next night.              |
|   [ Not now ]  [ Share ]     |
+------------------------------+
```

### TV dashboard (host phone mirrored)

```
+--------------------------------------+
| Friday at Sam's    hand 43  (15 min) |
|  Alice   VPIP 52%  PFR 31%  Maniac   |
|  Bob     VPIP 33%  PFR 8%   Loose-Pas|
|  Cy      VPIP 14%  PFR 10%  Rock     |
|  Host    too early to tell (6 hands) |
+--------------------------------------+
```

## 7. Migration from the single-phone model

Nothing existing changes. "Just my phone" stays the default and needs no
sign-in or network.

* A table night is still a local `HomeSession` on each phone, with two new
  optional fields (`tableCode`, `myUid`). Old saved nights simply lack them.
* In a table night, `logHand` takes the hand number from `currentHand` (or
  the entry's draft) instead of `hands.length + 1`, takes dealer and
  position from the rotation instead of the local `buttonSeat`, writes the
  local `LoggedHand` as today, and also calls `logEntry` / `saveCards`.
* `loggedHandFrom(table, uid, n, entry:, cards:)` builds the normal
  `LoggedHand`, so stats, recap, dealer luck, milestones and the share card
  keep working unchanged. Hands you skipped still get their dealer.
* Local first: the Firestore SDK queues writes offline. Because the hand
  number is fixed when the entry starts, a write sent minutes later still
  lands on the right hand.
* Undo becomes "edit or delete my entry for #n" (own docs only); the host's
  "set dealer" replaces the local dealer picker.

## 8. Running the tests

```
flutter test test/table_sync_test.dart
cd tool/firestore_rules && ./run.sh      # local emulator only, demo-feltnotes
```

`run.sh` uses `npx firebase-tools@13.35.1` with JDK 17 (the installed
firebase-tools 15 wants JDK 21), on ports 8012 / 4412 / 4512 so it does not
clash with another emulator. A `demo-` project id cannot reach any real
project.

## 9. Decisions for the owner

1. **Where unrevealed cards live.** Recommended: on the phone only (lean
   mode; the cloud only sees cards people choose to show; half the reads).
   Alternative: in `cards/` readable only by the owner (backs them up, lets a
   player switch phones mid-night).
2. **Give-to-get granularity.** Built: one-way per-night "share" switch;
   from then on, every hand a sharer enters is revealed (earlier hidden hands
   stay hidden unless the app flips them when sharing starts). Stricter alternative: per hand
   (see #42 only if you showed #42), which needs one query per hand.
3. **Who taps "Next hand".** Built: any phone (duplicates ignored).
   Alternatives: host or board caller only, or advance automatically when
   the board caller starts the next hand.
4. **Is it worth adding Firebase at all?** It adds firebase_core /
   firebase_auth / cloud_firestore (versions known to build here:
   ^3.8.1 / ^5.3.3 / ^5.5.1), a Firebase project, config files per platform,
   and a privacy-policy update (anonymous ids and game data leave the
   phone). The single-phone app keeps working either way.
5. **One shared project, or one per friend group.** One project carries
   about 2-5 nights per day for all users combined (section 5).
6. **App Check.** Recommended before any public release, so nobody can burn
   the shared quota from a script (free with Play Integrity / DeviceCheck).
7. **Retention.** Delete a table night after N days (host phone deletes it;
   ~3,000 deletes), or keep it for a "season" view.
8. **QR code.** Needs a QR package compatible with Flutter 3.22 and a join
   link route; the 6-character code alone works without it.
