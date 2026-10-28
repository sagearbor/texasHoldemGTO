# Felt Notes store listing

Source of truth for the Google Play and App Store listing text. Character
counts are checked by hand against store limits (Play: title 30, short 80,
full 4000; App Store: name 30, subtitle 30, promo text 170).

## Title (30 max)

Felt Notes: Poker Trainer

## Short description / Play (80 max)

GTO preflop drills, strategy charts, equity and home-game stats. Fully offline.

## App Store subtitle (30 max)

GTO drills and home-game stats

## Full description (~2500)

Felt Notes is a pocket poker coach for Texas Hold'em and a stats keeper for your home game. Drill decisions against solver strategy, see exactly which hands you keep getting wrong, and find out how your table really plays, without anyone keeping score. No account, no ads, and Felt Notes sends nothing anywhere.

TRAIN
You get a seat, the action before you and two cards. Tap what you'd do and get graded instantly: GTO play, a mixed hand where either choice is fine, or a mistake, with the chart and a short explanation built from the strategy data. Daily 10 (the same 10 spots for everyone each day, so you can compare with friends), spaced repetition, pot-odds and range-reading quizzes, difficulty levels and a 60-second leak test.

CHARTS AND MISTAKES
13x13 strategy grids for six-max 100bb cash spots, plus heads-up and 3-handed push/fold charts solved by Felt Notes, and river decisions from our own solver. Flip any chart to "My mistakes" to see your recent errors as a heatmap, then tap "Drill my weak hands".

PROGRESS
Your GTO score over time, by day or week, and a grade for every home-game night.

HOME GAME
Built so nobody has to keep score. Hands you don't touch count as folds; tap to call, swipe up to raise, without looking. The organizer taps who's dealing during the first orbit and Felt Notes learns the seats and moves the button from there. Optionally snap a photo of your own two cards (read on the phone) and let whoever calls the board say it out loud.

TV DASHBOARD AND NIGHT RECAP
Mirror a phone to the TV for a blind clock (cash or tournament), rotating moments, dealer luck and tonight's drama, always delayed so nobody reads a live hand off the screen. End the night with a swipeable recap, awards like Golden Arm and Dealer of Doom, and a share image for the group chat.

GLOSSARY
Every term in plain English: UTG, cutoff, iso, complete, squeeze, VPIP, push/fold and more.

PRIVATE BY DESIGN
No sign-up, no ads, no tracking, no analytics. Camera and microphone are optional. Card photos are read on the phone and never saved. The board mic uses your phone's built-in speech recognition (Apple or Google may process that audio); Felt Notes keeps no audio. Back up, restore or wipe your data from Settings.

The cash charts are approximate GTO baselines; push/fold charts are an exact equilibrium. Felt Notes is a learning tool and offers no real-money gambling.

## Release notes (0.1.x, first public release)

First release of Felt Notes.
- Preflop trainer with instant GTO grading and "Drill my leaks"
- 6-max 100bb and heads-up push/fold strategy charts
- Equity calculator: hand vs hand and hand vs range
- Stats: you-vs-GTO heatmap, weakest spots, teachable mistakes
- Home game logger with live stats and a delayed TV dashboard
- About & privacy screen with one-tap "Reset all data"

## Assets

| File | Use |
| --- | --- |
| `feature-graphic-1024x500.png` | Play feature graphic (`python3 tool/make_feature_graphic.py`) |
| `../assets/icon/play-512.png` | Play hi-res icon (`python3 tool/make_icons.py`) |
| `screenshots/android-phone/*.png` | Play phone screenshots, 1080x1920 (9:16); TV dashboard 1920x1080 |
| `screenshots/ios-6.7/*.png` | App Store 6.7"/6.9" iPhone slot, 1290x2796; TV dashboard 2796x1290 |

Screenshots are rendered from the real screens with seeded data:
`flutter test test_driver/store_screenshots_test.dart` (macOS: uses the Flutter
SDK's Roboto plus a system font for the card suits).

Order: 1 Train (graded answer), 2 Charts, 3 Equity, 4 Stats, 5 Home game,
6 TV dashboard.

## Contact and URLs

- Support / contact email: sagearbor+feltnotes@gmail.com
- Privacy policy URL: https://sagearbor.github.io/texasHoldemGTO/privacy.html
