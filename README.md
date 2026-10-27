# Felt Notes

GTO poker trainer and (soon) home-game stats tracker. Flutter app for web
(GitHub Pages), Android and iOS.

**Live web app:** https://sagearbor.github.io/texasHoldemGTO/

## What's in it
- **Train**: preflop drills with instant GTO feedback and coaching written
  from solver data (no AI). Modes: all spots, 6-max 100bb, push/fold, and
  "drill my leaks".
- **Charts**: 13×13 strategy grids for 19 6-max 100bb spots (approximate
  GTO baselines) and heads-up push/fold Nash for 3–25bb (solved in-repo).
- **Equity**: hand vs hand (up to 6 players) and hand vs range calculator.
- **Stats**: "you vs GTO" heatmap by hand, weakest spots, most teachable
  mistakes.
- **Home game** (single phone, no account): log your own hole cards each
  hand, plus an optional one-tap preflop action. Seats are fixed, so your
  position follows the dealer button. Live VPIP/PFR, player style, card luck,
  preflop GTO grade, and a big-type **TV dashboard** (mirror the phone to the TV).

## Development
```bash
flutter test
flutter run -d chrome
dart run tool/solve_pushfold.dart 6000   # regenerate assets/data/pushfold.json
```

Engine code (`lib/poker`, `lib/gto`) is pure Dart with no Flutter imports
except `spots.dart` asset loading.
