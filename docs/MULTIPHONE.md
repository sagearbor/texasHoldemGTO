# Multi-phone table nights (local-first design)

Status: **built on branch `multiphone-sync`, not deployed.** There is no
Firebase project. The default build is local-only: it never initialises
Firebase and works with no network. The cloud path is compiled in but only
switched on with `--dart-define=FELT_CLOUD=true` (section 7).

This replaces the earlier prototype design (a live shared hand counter in
Firestore). The owner's venue rules that out: a basement with no cell
service and flaky wifi.

| Piece | File | State |
|---|---|---|
| Event model, join ticket (QR payload), ids | `lib/sync/night_events.dart` | done, tested |
| Durable local log (the outbox) | `lib/sync/event_log.dart` | done, tested |
| `TableSync` interface + `LocalTableSync` | `lib/sync/table_sync.dart` | done, tested |
| Uploader (backoff, idempotent parts), `CloudLogs` interface, fake cloud | `lib/sync/cloud_logs.dart` | done, tested |
| Merge: hand alignment, default fold, live TV rows, drama lines | `lib/sync/night_merge.dart` | done, heavily tested |
| Firestore `CloudLogs` | `lib/sync/firestore_cloud_logs.dart` | written; compiles for android/ios/web; not run against a real project (none exists) |
| Build flag + Firebase options from defines | `lib/sync/cloud_config.dart` | done |
| QR join screens + stand-in player pad | `lib/ui/screens/table_night_screen.dart` | done; entry "Table night (beta)" on the Home game screen, debug builds or `FELT_TABLE_NIGHT=true` only |
| Security rules | `firestore.rules`, `firestore.indexes.json` | done, 45 emulator tests pass |
| Rules tests | `tool/firestore_rules/` (`./run.sh`) | local emulator, project id `demo-feltnotes` |
| Dart tests | `test/night_merge_test.dart` (32), `test/night_sync_test.dart` (16) | green |

## 1. The night, as the players see it

1. **Start.** The organizer opens "Table night", types their name and gets a
   QR. Each player photographs it once (ML Kit reads the QR on the phone;
   on the web, or without a camera, they paste the code
   `ABCD2345-WXYZ6789`). If the organizer already has a roster, the player
   taps "which one are you". That is the only moment phones need to be near
   each other.
2. **During the night nobody needs a network.**
   * The organizer does the dealer bookkeeping for everyone (the
     effortless-input screens): first-orbit dealer taps give the seat
     order, rotation is automatic, one tap per "next hand" (timestamped to
     the ms), add / remove players.
   * Each player taps **only for hands they play** (call or raise). Every
     other hand they were at the table for is a fold. Cards are optional
     and stay on the phone unless that player turns on sharing.
3. **After.** Each phone uploads its own log whenever it next has a
   connection: on the wifi if it works, in the car, the next morning. No
   phone relays anyone else's data. No end-of-night scan (people leave at
   different times).
4. **Recap / season.** Any phone fetches all logs of the night and merges
   them into one night: everyone's VPIP / PFR / style, the Night Recap,
   season stats, and lines like `Cooler · Joe AA vs John KK · 8:22pm`.
5. **Live TV.** The TV is the organizer's phone (mirrored). It always shows
   the organizer's own data (hand count, dealers, its own taps) and adds
   any player whose upload has arrived. Incomplete is fine and expected.

## 2. Data on each phone

Every phone has a device id (12 characters, made once per install) and, per
night, an **append-only event log** in `shared_preferences`
(`EventLog`). Each event is `deviceId_seq` (seq counts from 1 on that
phone), so ids never collide and re-sending is harmless. The log is the
source of truth; the cloud copy can always be rebuilt from it.

| Kind | Who | Data | Meaning |
|---|---|---|---|
| `join` | any | `name, claim?, offset?` | scanned the QR; `offset` = organizer clock - my clock (ms) |
| `play` | any | `e, a, f?` | one tap: entry no., call / raise / fold, facing |
| `cards` | any | `e, c?` | own hole cards for entry `e` |
| `undo` | any | `e` | withdraw entry `e` |
| `share` | any | `on` | card sharing on / off |
| `leave` | any | | gone for the night |
| `seats` | organizer | `seats: [[pid, name]..]` | clockwise table from the next hand on |
| `hand` | organizer | `n, d` | hand `n` starts now, dealer pid `d` |
| `unhand` | organizer | `n` | that "next hand" was a mis-tap |
| `board` | organizer | `n, c` | 3-5 community cards, if anyone called them |
| `end` | organizer | | night over |

Every event carries the phone's own clock (`ms`). An **entry** groups what a
player recorded for one hand: cards then a tap within 3 minutes are one
entry; a second tap within 10 s replaces the first (mis-tap); otherwise a
tap starts a new entry (`LocalTableSync.tap`).

### The QR (join ticket)

`feltnotes:join?t=<night id>&s=<secret>&n=<organizer>&c=<organizer clock, base36>&r=<pid~name,..>`

Under 200 characters with a 10-player roster, so it is a small, easy QR.
The organizer screen redraws it every second, so `c` is at most a second
old; the scanning phone stores `c - its clock at the photo` as its offset.
The typed code (`ABCD2345-WXYZ6789`) has no clock reading; such a phone's
offset comes from server time later (section 4).

## 3. What the organizer UI must call (for `effortless-input`)

The dealer bookkeeping UI is built on another branch. It needs nothing from
the network; it only calls `TableSync` (`lib/sync/table_sync.dart`), which
appends to the organizer's local log:

| UI moment | Call | Notes |
|---|---|---|
| start the night | `LocalTableSync.organize(store, organizerName:, selfPid:, roster:)` | `selfPid` = the organizer's own seat id |
| show the join QR | `qrTicket().encode()` every second | `OrganizerQrScreen` does this |
| first orbit done / player added / removed | `setSeats([Seat(pid, name), ...])` clockwise | full list each time; applies from the next `startHand` |
| "next hand" | `startHand(n, dealerPid)` | the UI owns numbering and rotation (`nextDealer(seats, dealer)` helps). **The call time is the hand boundary**, so call it when the deal starts |
| undo next hand | `undoHand(n)` | |
| board called (optional) | `recordBoard(n, cards)` | 3-5 cards; again to add turn / river |
| night over | `endNight()` | closes the last hand |
| organizer's own play | `tap(action)` / `setCards(cards)` | the organizer is also a player |
| TV | `watchMerged()` + `liveRows(merged, nowMs:, delayMs:)` | organizer data always, others as they arrive |
| recap / stats | `merged().loggedHandsFor(pid)` | plain `LoggedHand`s: every existing stat, recap and badge works unchanged |
| drama | `dramaLines(merged)` | |

Rules for pids: any stable string per seat for the night (players without
the app get one too). Players link to a pid by picking it from the QR's
roster, by having the same name (case and spacing ignored), or by a manual
`links` override passed to `mergeNight`. A phone the organizer never seated
still gets its hands counted (position unknown).

## 4. Merge: lining up everyone's taps

`mergeNight(organizerDeviceId:, logs:)` in `lib/sync/night_merge.dart` is
pure Dart and is what the TV, the recap and season stats call.

1. **Union** every copy of every event by `deviceId_seq`. Duplicate
   uploads, overlapping parts, out-of-order arrival and the phone's own
   local copy all collapse to one set. Merging twice gives the same night.
2. **Timeline** from the organizer's log: hand `n` runs from its
   `startHand` time to the next hand's (the last hand to `end`, or 8
   minutes). A repeated hand number replaces the earlier tap; `unhand`
   deletes one. Each hand keeps the seat list in force when it started,
   so dealer and positions are exact.
3. **Clock offset per phone:** the QR offset if it has one; otherwise
   server-time skew (each uploader measures `server time - its clock` once,
   on a quick round trip, and stores it with its log): `offset = skew(phone)
   - skew(organizer)`; otherwise zero, with a warning.
4. **Presence:** a phone is at the table from its `join` to its `leave`
   (organizer clock). It counts for a hand only if it was present then and
   the organizer had it seated (or never seated it at all). So late joiners
   start when the organizer adds them, and early leavers stop at their
   `leave` even if the organizer forgets to remove them, and vice versa.
5. **Assignment:** each entry's time (its first event, on the organizer
   clock) is filed under the hand whose interval holds it. One entry per
   phone per hand, so when skew pushes two taps into one hand an
   order-preserving dynamic program picks the assignment with the least
   total distance (the earlier tap moves back a hand). An entry farther
   than 2 minutes from every hand that phone sat in is reported as
   unassigned, never guessed.
6. **Default fold:** a present phone with no entry for a hand folded
   (`inferred: true`, so the UI can say "38 hands, 11 tapped"). An entry
   with cards but no tap is a fold with cards.

Accuracy in the tests (fabricated nights, hands 1-5 minutes, clocks up to
±5 minutes off, taps 10-90 % into the hand):

* QR-grade offsets (±2 s): **every** player-hand right in 40 random nights.
* Offsets wrong by up to 15 s (e.g. a typed code and a slow network):
  at least 98 % right.
* A tap is only at risk when it is closer to a hand boundary than the
  offset error, which with the QR is about a second.

### Drama lines

From hands where two players who share cards both played:
`Cooler · Joe AA vs John KK · 8:22pm` (both JJ+ or AK) and, when the board
was recorded, `Bad beat · John KK vs Joe 85s · 8:22pm` (the preflop
favourite, at least 65 %, listed first, lost). Without a board the app
cannot know who won, so no bad beats without one.

## 5. Cloud layout and rules

```
nights/{nightId}                     {secret, organizer, createdAt}
nights/{nightId}/members/{uid}       {name, deviceId, secret, joinedAt}
nights/{nightId}/logs/{deviceId}_{p} {uid, deviceId, part, count, events[], name, skew?, clientMs, updatedAt}
```

* **Auth:** Firebase anonymous auth (a uid per install, no account).
* **Night:** created by whichever phone gets online first (it holds the
  ticket, so it knows the id and secret). Immutable afterwards. A non-member
  may only learn that a night does not exist yet; nobody lists nights.
* **Members:** a phone joins by writing its member doc with the secret,
  which the rules compare to the night's. The device id is fixed per member.
* **Logs:** one document per phone per 400 events (a whole night is one
  document per phone). Only the member whose device id it is may write it;
  `count` must equal the events list and never shrink, so a stale
  re-upload cannot erase anything. Members read every log; nobody else
  reads anything.
* **Cards:** a player who does not share never uploads cards (the cloud
  copy says only "had cards"). Turning sharing off re-uploads with cards
  removed. So the rules need no card-level privacy: what is in the cloud is
  what players chose to show the table.
* `firestore.indexes.json` exempts `events` from indexing (it is never
  queried; saves storage).

The rules tests (`tool/firestore_rules/run.sh`, 45 cases) cover: creating
nights (id / secret format, unknown fields, server time, no overwrite,
update, delete or list), joining (secret check, own uid only, nonexistent
night, device-id format, rename allowed, device swap refused, member reads),
and logs (owner-only, idempotent re-upload, append, never shrink, 400 cap,
doc id = `deviceId_part`, uid / device spoofing, unknown fields, member-only
reads).

## 6. Cost: inside the Firestore free tier

Spark plan (no billing account, so it can never cost money; past a quota,
requests fail until midnight Pacific and the phones simply retry later from
their local logs). Per project per day: **50,000 reads, 20,000 writes,
20,000 deletes, 1 GiB stored; 10 GiB/month egress.** Anonymous auth: free.

One night: 10 phones (organizer + 9), 4 hours, 120 hands, each player plays
~30 % of hands. The uploader writes at most once per 2 minutes per phone
while online, and only when there is something new.

| Per night | Basement (upload at home) | Wifi works all night (worst case) |
|---|---|---|
| Night + member docs | 11 writes | 11 writes |
| Log uploads | ~2 per phone = 20 | organizer ~120, players ~36 each = ~445 |
| Rules lookups (1 billed read per write) | ~30 | ~455 |
| Skew measurement (1 read per phone) | 10 | 10 |
| TV listener (1 read per changed log doc, organizer only, when online) | ~10 | ~445 |
| Recap: every phone fetches the night once (11 docs) | 110 | 110 |
| **Total** | **~31 writes, ~160 reads** | **~456 writes, ~1,020 reads** |

Storage: an event is ~45 bytes; a night is ~30-90 KB. 1 GiB holds about
15,000-30,000 nights.

**The owner's group** (one night a week): under 0.1 % of a day's quota.

**The public app.** All users share one project's daily quota. Groups of 8,
4 nights a month each: nights per day ≈ users / 60. Weekend evenings
concentrate play, so allow 3× the average on a Saturday.

| Users | Nights / day (Sat peak) | Worst-case reads | Basement-case reads |
|---|---|---|---|
| 1,000 | ~50 | ~51,000 (at the limit) | ~8,000 |
| 3,000 | ~150 | over | ~24,000 |
| 8,000 | ~400 | over | ~64,000 (over) |

So: free for thousands of users when most nights upload in a few bursts
(which the basement guarantees), and about 1,000 users if every table has
wifi all night. Levers, cheapest first: raise the player upload interval
(2 → 10 minutes cuts worst-case writes ~4×; the TV just updates less
often); upload only on `leave` / app pause for players; then one project
per region or a paid plan. Storage needs a retention rule within a year or
two at those volumes (decision 4).

## 7. The build flag

`lib/sync/cloud_config.dart`:

* Default (`FELT_CLOUD` unset): `openCloud()` returns null. No
  `Firebase.initializeApp`, no network, no crash; table nights are stored
  on the phone and merged from local data.
* `--dart-define=FELT_CLOUD=true --dart-define=FELT_FB_PROJECT=demo-feltnotes
  --dart-define=FELT_FB_EMULATOR=10.0.2.2:8012`: talks only to a local
  emulator (a `demo-` project cannot reach a real one).
* A real project later adds `FELT_FB_API_KEY`, `FELT_FB_APP_ID`,
  `FELT_FB_SENDER` (public client ids, not secrets, but none are in the
  repo). No `google-services.json` / `GoogleService-Info.plist` / FlutterFire
  config is needed: options are passed in code.
* Firestore offline persistence is **off**: the local log is the outbox,
  and a queued SDK write would spoil the server-time skew measurement.

Packages added (all build on Flutter 3.22.2 / Dart 3.4.3, AGP 8.11.1,
Gradle 8.14, minSdk 24, compile/target 36, iOS 15.5; no existing pin
changed): `qr_flutter 4.1.0`, `google_mlkit_barcode_scanning 0.14.1` (same
`google_mlkit_commons 0.11.0` as the pinned text recognizer),
`firebase_core 3.8.1`, `firebase_auth 5.3.3`, `cloud_firestore 5.5.1`.
Verified: `flutter build apk --debug`, `flutter build appbundle`,
`flutter build ios --debug --no-codesign`, `flutter build web` (with and
without `FELT_CLOUD`).

## 8. Running the tests

```
flutter test test/night_merge_test.dart test/night_sync_test.dart
cd tool/firestore_rules && ./run.sh      # local emulator only, demo-feltnotes
```

`run.sh` uses `npx firebase-tools@13.35.1` with JDK 17, on ports 8012 /
4412 / 4512 so it does not clash with another emulator.

Not tested: `FirestoreCloudLogs` itself against the emulator from a device
(it needs a simulator or phone; the rules it relies on are tested from
Node with the same paths and fields).

## 9. Decisions still open for the owner

1. **Create the Firebase project** (Spark plan, no billing account) and
   pick **which Google account** owns it (personal vs a dedicated
   Felt Notes account). Nothing has been created.
2. **Turn it on:** enable Anonymous sign-in, deploy `firestore.rules` and
   `firestore.indexes.json`, register the Android / iOS / web apps, and
   decide where the three `FELT_FB_*` values live for release builds.
3. **App Check** (Play Integrity / DeviceCheck, free) before a public
   release, so nobody can burn the shared quota from a script.
4. **Retention:** delete nights after N days, or keep them for season
   stats (then a cap, e.g. 18 months).
5. **Privacy policy update:** names, taps and (only when shared) cards
   leave the phone, under an anonymous id.
6. **Upload interval vs TV liveliness:** 2 minutes is built; 10 minutes
   for players stretches the free tier ~4× (section 6).
7. **Boards:** bad-beat lines need the board. Keep the voice caller /
   board phone as the source, or accept coolers only.
8. **Season stats on a new phone:** device ids are per install. Moving to a
   new phone loses the link to old nights unless we add an optional
   account later.
9. **App size:** the release AAB grew from 43.6 MB (main, 0.2.1+7) to
   55.9 MB (+12.3 MB: Firebase SDKs plus the ML Kit barcode model), even
   though the default build never uses Firebase; the iOS build now
   compiles gRPC (slower clean builds). If that matters before a project
   exists, the Firebase packages can wait on a branch until decision 1,
   or the cloud side can use the Firestore REST API (no native SDK).
