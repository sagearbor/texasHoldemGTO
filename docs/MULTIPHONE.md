# Multi-phone table nights and the table TV (local-first design)

Status: **built on branch `table-tv`** (on top of `multiphone-sync`), wired
into the hand logger, running against the real Firebase project
`felt-notes-poker` (Spark plan, billing disabled, so it can never cost
money). Rules deployed. Not merged to main, not in a store build yet.

The venue is a basement with no cell service and flaky wifi, so every phone
works offline and uploads its own log whenever it can. The organizer's
phone keeps using the normal hand logger; a bridge mirrors it into the
night's log.

| Piece | File | State |
|---|---|---|
| Event model, join ticket (QR payload), ids | `lib/sync/night_events.dart` | done, tested |
| Durable local log (the outbox) | `lib/sync/event_log.dart` | done, tested |
| `TableSync` + `LocalTableSync` (player taps, organizer calls) | `lib/sync/table_sync.dart` | done, tested |
| Hand logger → night log, by state | `lib/sync/organizer_bridge.dart` | done, tested through `HomeGameModel` |
| What leaves the phone, uploader, card release, fake cloud | `lib/sync/cloud_logs.dart` | done, tested |
| Merge: hand alignment, default fold, private players, drama lines | `lib/sync/night_merge.dart` | done, heavily tested |
| TV board (visibility rules), card fetcher | `lib/sync/tv_board.dart` | done, tested |
| Firestore `CloudLogs` | `lib/sync/firestore_cloud_logs.dart` | done; web build verified in Chrome against the real project |
| Firebase client config | `lib/sync/firebase_options.dart`, `cloud_config.dart` | done (public client ids) |
| App-wide night (resume, lifecycle flush, clock mirror) | `lib/sync/table_night_service.dart` | done |
| Screens: join, player pad, organizer sheet (QR, TV link, sharing) | `lib/ui/screens/table_night_screen.dart` | done |
| TV page `/#/tv?c=CODE` and in-app | `lib/ui/tv/` | done, widget-tested at 1920×1080, 1280×720, 390×844 |
| Security rules | `firestore.rules`, `firestore.indexes.json`, `firebase.json` | deployed; 67 emulator tests |
| End-to-end against the real project | `tool/e2e/` (`FELT_E2E=1 flutter test tool/e2e/live_night_test.dart`) | passes; cleans up after itself |
| Retention sweep (no TTL on Spark) | `tool/sweep_expired_nights.sh` | done; owner schedules it |
| Store privacy answers | `docs/PRIVACY_FORMS.md`, `web/privacy.html` | drafted |

## 1. The night, as the players see it

1. **Start.** The organizer starts a game night as usual with "Let other
   phones and a TV join" on (default on, remembered). The QR sheet opens:
   a QR redrawn every second, the code `ABCD2345-WXYZ6789`, the TV link and
   the sharing switch. It comes back from the QR icon on the hand logger.
2. **Join.** A player: Home game → Join a table night → photograph the QR
   (ML Kit reads it on the phone; or type the code), tap their name from
   the organizer's list, check the sharing switch (on by default), Join.
   That is the only moment phones need to be near each other.
3. **During the night nobody needs a network.** The organizer runs the
   hand logger exactly as before (first-orbit dealer taps, Next hand, own
   taps and cards, board caller, blind clock). Each player has the table
   pad: **Call** or **Raise** only for hands they play; every other hand
   they were dealt is a fold. Cards are optional.
4. **TV.** Any browser opens `https://sagearbor.github.io/texasHoldemGTO/#/tv?c=CODE`
   (laptop, tablet, spare phone, smart-TV browser; cast or HDMI it), or the
   app's "Show a table night on this screen". It updates live while phones
   have a connection and says plainly when it is stale.
5. **After.** Phones that were offline upload on the way home. A player's
   pad shows "my night so far" (VPIP / PFR) once the organizer's hands are
   in. Leaving early: "I'm leaving" on the pad.

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
| `cards` | any | `e, c, h?, done?` | own hole cards for entry `e` (cloud copy: `{e}` only) |
| `undo` | any | `e` | withdraw entry `e` |
| `share` | any | `on` | sharing with the table on / off (recorded at join) |
| `leave` | any | | gone for the night |
| `seats` | organizer | `seats: [[pid, name]..]` | clockwise table from the next hand on |
| `hand` | organizer | `n, d` | hand `n` starts now, dealer pid `d` |
| `unhand` | organizer | `n` | that "next hand" was a mis-tap |
| `board` | organizer | `n, c` | 3-5 community cards, if anyone called them |
| `end` | organizer | | night over |
| `clock` | organizer | `j` | the blind clock (BlindClock json) |

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

## 3. How the hand logger feeds the night (`OrganizerBridge`)

The hand logger has no sync code. `TableNightService` listens to
`HomeGameModel` and, on every change, `OrganizerBridge.reconcile(session)`
compares the session with what the log already says and appends only the
difference:

| Session state | Log events |
|---|---|
| `players` (seat order; names are the pids) | `seats` when the list changes, before any hand event |
| each logged hand (`start`, `dealer`) and the hand being played | `hand {n, d}` with the session's own start time; `unhand` after Undo |
| first orbit finished | every hand re-sent once so it takes the final seats |
| `board` / `currentBoard` (3-5 cards) | `board {n, c}`; an empty board clears an undone one |
| the organizer's own closed hands (tap, facing, cards) | one entry per hand: `cards {e, h, c, done}` + `play {e, h, a, f}`; a change = `undo` + a new entry |
| night ended | `end` at the last hand's time |
| blind clock changes (`BlindClockController`) | `clock {j}` (whole clock json) |

Entries carry the hand number `h`, so the log alone says which entry is
whose: a crash halfway through writing one heals on the next pass (tested).
The organizer's cards are only written for hands already closed (the hand
being played never leaves the phone), marked `done` so they may go up at
once. Buy-in / cash-out are never mirrored.

Rules for pids: the names in the hand logger (unique within a night).
Players link to a pid by picking it from the QR's roster, by having the
same name (case and spacing ignored), or by a manual `links` override
passed to `mergeNight`. A phone the organizer never seated still gets its
hands counted (position unknown). Players with no app are on the TV as
"no phone at the table".

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
6. **Private phones** (latest `share` is off, and not the phone doing the
   merge) are left out of every hand instead of folding them all.
7. **Default fold:** a present phone with no entry for a hand folded
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

## 5. Cloud layout, what leaves the phone, and the rules

```
nights/{nightId}                      {secret, organizer, createdAt, expireAt}
nights/{nightId}/members/{uid}        {name, deviceId, secret, joinedAt, expireAt}
nights/{nightId}/logs/{deviceId}_{p}  {uid, deviceId, part, count, events[], name, skew?, clientMs, updatedAt, expireAt}
nights/{nightId}/cards/{deviceId}_{e} {uid, deviceId, e, c: [a, b], at, expireAt}
```

* **Auth:** Firebase anonymous auth (a uid per install, no account).
* **Night:** created by whichever phone gets online first (it holds the
  ticket, so it knows the id and secret). Immutable. A non-member may only
  learn that a night does not exist yet; nobody lists nights.
* **Members:** a phone (or the TV) joins by writing its member doc with
  the secret. The device id is fixed per member (a phone whose sign-in
  survived a reinstall signs in afresh and joins again).
* **Logs:** one document per phone per 400 events. Only the owner writes
  it; `count` must equal the events list and never shrink in place (a
  stale re-upload cannot erase events); the owner may delete it (sharing
  turned off). Members read every log.
* **What a log holds** (`cloudEvents`): sharing **on**: everything, except
  that a `cards` event is cut down to `{e}` ("had cards"). Sharing **off**:
  only `join`, `share`, `leave` and the organizer's bookkeeping (`seats`,
  `hand`, `unhand`, `board`, `end`, `clock`); no `play`, `cards` or `undo`.
  Switching off rewrites the log (delete + write when it shrinks) and
  deletes the card documents, so what was shared is gone.
* **Cards** never sit in a log. A phone writes a card document for an
  entry only once that hand is over (`releasedCards`): a later live entry
  exists, or the organizer's own closed hand (`done`), or 6 minutes passed
  since the cards were entered. The rules then keep it unreadable to
  everyone, owner included, until **2 minutes after it was written** (server
  time, `at == request.time` so it cannot be back-dated), and nobody can
  list card documents: the TV asks for them one by one.
* **The TV** shows a card only for a hand that is over (a later hand has
  started, or the night ended) **and** ended at least 3 minutes ago, and
  only asks Firestore for it then (`CardFetcher`: missing or held cards are
  retried after 1, 2, 4 ... 10 minutes). Stats (hands, VPIP, PFR, recent
  actions) count finished hands at once.
* `firestore.indexes.json` exempts `events` from indexing.

### What a technically savvy player at the table could see

A member is anyone holding the code. Reading Firestore directly (not
through the app), they could see: names; when each hand started and who
dealt; who tapped call / raise in which hand, **as it happens** (the same
thing they see across the table); that someone entered cards for an entry
(not which); the blind clock; the board. They could **not** see anyone's
hole cards for a hand still being played, except in one case: a player
who entered cards and then made no further entry for 6 minutes while that
same hand was still going (a hand longer than 8 minutes in total). Even
then the cards were entered by that player knowing the hand runs on.
Sharing off removes all of a player's taps and cards. A non-member sees
nothing.

The rules tests (`tool/firestore_rules/run.sh`, 67 cases) cover nights,
joining, logs (ownership, idempotent re-upload, never shrink, owner
delete, 400 cap, spoofing, unknown fields, expiry window) and cards (hold
before reading, no listing, no back-dating, card range, owner-only write
and delete, TV member).

## 6. Clock skew, late joiners, leaving, dead phones

* **Skew:** the QR carries the organizer's clock; each phone stores the
  offset at the photo (±1-2 s). A typed code falls back to server time:
  every uploader measures `server - device` on its first write and the
  merge uses the difference. On the real project the organizer's measured
  skew was -15 ms.
* **Duplicates / lost replies:** the uploader works from state, not a
  watermark: it computes what each part should hold now and writes only
  parts whose fingerprint differs from the last accepted write. A lost
  reply means one identical rewrite; the merge unions by `deviceId_seq`.
* **Offline:** failures back off 5 s, 10 s ... capped at 1 minute (failed
  requests cost nothing); going to the background or coming back flushes
  at once.
* **Late joiner:** counts from the first hand after the organizer seats
  them (or every hand, if never seated).
* **Leaving:** a player's `leave` stops their hands even if the organizer
  forgets to unseat them; the TV shows "left" with their stats.
* **Organizer's phone dies:** the TV keeps the last state; after 5 minutes
  without an organizer upload the status turns amber ("organizer's phone
  quiet · last update 7 min ago"). The organizer's log is on the phone:
  when it comes back the hand logger resumes and the bridge catches up.
* **TV reload / dropped connection:** the code is in the URL (and
  remembered); the listener reconnects by itself (5 s ... 1 min) and the
  last board stays up with a red "TV offline, retrying".

## 7. Cost: inside the Spark free tier

Spark: no billing account, so nothing can ever be charged; past a quota,
requests fail until midnight Pacific and phones keep their logs. Per day:
**50,000 reads, 20,000 writes, 20,000 deletes, 1 GiB stored, 10 GiB/month
egress.** Anonymous auth is free.

**One night, 8 players (organizer + 7 phones) + 1 TV, 4 hours, ~100
hands, wifi working all night (the worst case):**

| | Writes | Reads |
|---|---|---|
| Night + 9 member docs | 10 | 10 |
| Organizer log (≤ 1 upload per 20 s, only when changed: ~1.5 per hand) | ~150 | ~150 rules lookups |
| Player logs (each plays ~30 % of hands: ~30 taps, coalesced) | ~210 | ~210 |
| Player card documents (if every played hand has cards) | ~210 | ~210 |
| TV listening (1 read per changed log) + card gets (~2 tries each) | | ~360 + ~420 |
| Players' "my night so far" refreshes (~10 each × 9 docs) | | ~630 |
| Skew measurements, TV reloads | | ~30 |
| **Total** | **~580 (3 % of a day)** | **~2,050 (4 % of a day)** |

Storage: ~100 KB a night. Egress: the TV's listener receives whole log
docs on change, ~8 MB a night per TV. Phones do not listen live. The real-project test
night (4 phones + TV, 4 hands) used ~66 reads and 23 writes.

**The owner's group** (one night a week): far inside the free tier. **The
public app:** all users share one project: about 20 such nights on the
same day reach 50,000 reads (about 25). Levers, cheapest first: players refresh less
(the biggest read item), raise the player upload interval, App Check against scripted abuse, then one project per
region or a paid plan (the owner's call: never enable billing here).

## 8. Build, run, test

* Cloud is **on** by default (`lib/sync/cloud_config.dart`); Firebase is
  started only the first time a table night needs it, never at launch.
  `--dart-define=FELT_CLOUD=false` builds a local-only app;
  `--dart-define=FELT_FB_PROJECT=demo-feltnotes --dart-define=FELT_FB_EMULATOR=10.0.2.2:8012`
  points at a local emulator.
* No `google-services.json` / `GoogleService-Info.plist`: options are
  passed in code (`firebase_options.dart`, public client ids).
* Firestore offline persistence is off: the local log is the outbox.
* Packages: `firebase_core 3.8.1`, `firebase_auth 5.3.3`,
  `cloud_firestore 5.5.1`, `qr_flutter 4.1.0`,
  `google_mlkit_barcode_scanning 0.14.1` (all build on Flutter 3.22.2).

```
TZ=UTC flutter test                                   # all unit + widget tests
cd tool/firestore_rules && ./run.sh                   # 67 rules tests, local emulator
FELT_E2E=1 flutter test tool/e2e/live_night_test.dart # real project, ~3 min, cleans up
firebase deploy --only firestore:rules,firestore:indexes --project felt-notes-poker
tool/sweep_expired_nights.sh [--dry-run]              # retention (owner credentials)
```

## 9. Decisions and follow-ups for the owner

1. **Retention:** Firestore TTL needs billing, so expired nights are
   deleted by `tool/sweep_expired_nights.sh` (owner credentials). Schedule
   it (cron / launchd, weekly) or the privacy promise ("nothing past 90
   days") is not kept.
2. **App Check** (free) before the public uses table nights, so nobody
   can burn the shared quota from a script.
3. **Store forms:** `docs/PRIVACY_FORMS.md`, in the same release.
4. **Season stats on a player's phone:** the pad shows the night's stats,
   but a player's own home-game history does not yet get the night (an
   import from `merged().loggedHandsFor(pid)` is the obvious next step).
5. **Boards:** bad-beat lines need the board (the organizer's board caller).
