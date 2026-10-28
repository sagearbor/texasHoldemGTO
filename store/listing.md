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

## Full description (~1500)

Felt Notes is a pocket poker coach for Texas Hold'em. Drill preflop decisions, look up the strategy for any spot, and track how you really play at your home game. No account, no ads, and nothing ever leaves your phone.

TRAIN
You get a seat, the action before you and two cards. Tap what you would do and get graded instantly: GTO play, a mixed hand where either choice is fine, or a mistake. Every answer comes with the chart for that spot and a short explanation built from the strategy data. Drill all spots, 6-max 100bb cash, heads-up push/fold, or let "Drill my leaks" keep serving the hands you get wrong.

CHARTS
13x13 strategy grids for 19 six-max 100bb spots: opens, calls, 3-bets and blind defence. Heads-up push/fold charts from 3 to 25 big blinds, solved by Felt Notes. Tap any hand for its frequencies and the reasoning.

EQUITY
Hand vs hand for up to six players with any board, or your hand against a whole range such as a button open.

STATS
A you-vs-GTO heatmap of every starting hand, your weakest spots with one-tap drills, and your most teachable repeat mistakes.

HOME GAME
At your weekly game, log your own two cards (or just tap Fold) each hand. Felt Notes follows the dealer button, works out your position and shows live VPIP, PFR, playing style, card luck and a preflop GTO grade. Mirror your phone to the TV for a big-type dashboard that only shows hands from a while ago, so nobody reads the last hand off the screen.

PRIVATE BY DESIGN
No sign-up, no ads, no tracking, no analytics. Everything is stored on this device and can be wiped from About & privacy.

The 6-max charts are approximate GTO baselines; the push/fold charts are an exact equilibrium. Felt Notes is a learning tool and offers no real-money gambling.

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
