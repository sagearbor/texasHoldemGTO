# Board cam: the community cards from propped phones

Short version of the design (full write-up with the harness numbers:
`tmp/board-consensus-design.html`, not tracked). Branch `board-cam`.

## What a propped phone can see

A phone at table height sees the board 60-90 cm away at an 8-12 degree
elevation. On the owner's footage, downscaled to the app's 1280 x 720
stream, a board card is about 190 x 40 px, a pip 20 x 6 px and the corner
index 5 px tall. The index (what the hole-card reader classifies) is
unreadable; the face of the card is not. So the board reader
(`lib/camera/board_reader.dart`) does not read glyphs:

* **paper row**: card stock (very bright, low saturation) becomes
  connected components at full stream resolution; low, wide ones with
  ink enclosed inside, in one tight row of similar heights, are the
  board. Held hole cards are far too big, face-down cards are patterned,
  a silver tray or a glass has no pips, anything touching the frame edge
  is dropped;
* **pip count** gives the rank (A, 2-10); **ink colour** gives red /
  black for certain (black ink is *dark* whatever its hue: under a warm
  lamp it is brown; red ink is bright pink after white balance); a
  **picture** gives "face card" (J / Q / K are not told apart); **pip
  shape** (fill of its box) gives a weak suit.

Every read is a partial card: `7d`, `9b` (a nine, black), `Fr` (a red
face card), `??`. Downstream code uses the board only when every card is
exact; otherwise it shows what it knows and asks for one tap.

`lib/camera/board_watch.dart` is event driven: one look per second on the
whole frame until a street is read, then only on the strip around the
board; four looks a second while a new count (3 / 4 / 5) is being read;
2-4 small crops per street voted card by card; "board swept" after 4 s of
nothing (a hand boundary). Rotation and mirror are handled as in the
hole-card pipeline; the harness simulates a portrait-propped phone with
`--rotate 90 --unrotate`.

Harness: `dart run tool/watch_lab.dart VIDEO --board-labels
camera_data/watch/VIDEO.board.json [--board-dump DIR]`; one-frame probe:
`tool/board_probe.dart`.

## Consensus (`lib/sync/board_consensus.dart`)

Each street a phone reads is a `boardRead {c, q, u}` event (tokens, rank
confidences, suit confidences) in its own log, on its own clock; the
merge moves it onto the organizer's clock with the QR / server offset and
files it under the hand whose interval holds it (a 4-5 card read in the
first 15 s of a hand, when the previous hand stopped a street short, is
the previous hand's late turn / river). Offline it simply uploads later.

Precedence: the organizer's `board` call wins outright; then a one-tap
`boardFix {n, c}` from any phone; then the cameras' vote. The vote is
card by card (phones across the table see the board reversed; a phone
that saw the pips but not their shape still knows the rank): reads are
matched into slots by compatibility ("Fr" and "Kh" share a slot, "7d" and
"7h" too, "Kh" and "2s" never), and each slot votes rank, colour and suit
separately, weighted by that attribute's confidence and by how much of
the street the phone saw.

| phones | rule |
|---|---|
| 1 | its read, confidence capped at 0.8; a face card or unknown suit flags `needsConfirm` |
| 2 agree | confirmed |
| 2 disagree | the attribute is unknown and contested unless one side holds 75 % of the weight; two entirely different cards in a slot leave it blank |
| 3+ | weighted majority, contested under 60 % |

A card a sharing player holds is dropped from a camera board (noted on a
human board). Board cards are public and may be shown live; hole cards
keep their rule. `MergedHand.agreedBoard` carries source, confidence and
notes; `MergedHand.board` is the exact board or null, and feeds
`loggedHandsFor` (so `board_stats`, recap, awards work) and `dramaLines`.

## Teaching and dashboards

Existing pieces that light up once the board flows in: `board_stats`
(flops seen, made hands), `dramaLines` (bad beats need a 5-card board),
`handsEquity` (street-by-street equity for shown-down hands, the "cooler
dashboard"), `evaluator` (made-hand names), preflop `spots` + `coach`
(the grade stays preflop; the board adds context). `river.dart` drills
are on preset boards only.

The data is thin postflop: actions are logged preflop only (fold / call /
raise, facing), no sizes, nothing postflop. "What you should have done on
the turn" cannot be graded without a postflop action logger; that is the
biggest unlock after the board itself.

`lib/sync/street_equity.dart` has `equityByStreet`, `swingLines` and
`handOfTheNight` ready for those views; `tv_board.dart` already hands the
TV the agreed board.

Ranked: (built) agreed board in the merge, drama lines, board stats,
equity-by-street functions;
(next week) TV board strip with tap-to-fix, camera reader in log-only
mode on the organizer's phone for real-night tuning data; (later) equity
by street on the TV and in the recap, camera reads driving the TV board,
postflop action logger, river drill from tonight's board texture,
full-resolution stills per street, postflop GTO (needs solved spots that
do not exist).

## Where it stands (harness, 2026-10-29)

End to end the watcher does not yet produce a usable board: in 130 s of
poker-mock1 it emitted two streets, neither matching the 8 labelled
streets, and none in simulated portrait; poker-mock2 (no boards)
correctly produced nothing in both orientations. Per frame
(`tool/board_probe.dart`) the row is found in most labelled frames, the
count is wrong when cards overlap or a glossy placemat edge joins the
row, colour is right, rank is within one pip but unstable from look to
look (so the agreement vote never settles), face cards are caught about
half the time, suits are near chance. Next: track each card's box
across looks instead of re-detecting, vote per pip, then log-only on a
real night. The consensus and merge layers are complete and tested
independently of the reader.

## Risks

Thresholds come from one warm-lit room with blown-out white cards; a
dimmer room needs an adaptive paper gate. A whole-frame look at 720p is
tens to hundreds of ms in Dart and must be measured on the phone (the
strip ROI makes the steady state cheap). Overlapping cards read as one
wide blob and the street is missed. Suits are weak at this angle; a
phone propped 10 cm higher (on a mug) roughly doubles the pip height.
