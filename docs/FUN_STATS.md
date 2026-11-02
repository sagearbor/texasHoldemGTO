# Fun stats for the table TV

Stats we want to cast at game night. Tick a box when the app shows it for
real, from data nobody had to tap in.

**Rule: no tapping.** Players set the app up once (name, join the game) and
at most peek at their own cards. Everything else comes from:

* **Camera:** the recording phone sees cards in front of each seat, so it
  knows who folded and when (needs the fold detector, built from recordings).
* **Radar:** Bluetooth/UWB between joined phones puts each name on a seat,
  so camera seat stats become stats by name.
* **Peek:** Watch mode reads a player's own two cards when they look.

| Done | Stat | Meaning | Comes from |
|---|---|---|---|
| [ ] | VPIP | % of hands they play | camera + radar |
| [ ] | PFR | % of hands they raise first | camera (chips in) + radar |
| [ ] | Nit | plays almost nothing | camera + radar |
| [ ] | Rock | tight, never bluffs | camera + radar (+ showdowns) |
| [ ] | Loose | plays too many hands | camera + radar |
| [ ] | TAG | tight and aggressive | camera + radar |
| [ ] | LAG | loose and aggressive | camera + radar |
| [ ] | Maniac | raises everything | camera + radar |
| [ ] | Calling station | calls, never folds | camera + radar |
| [ ] | Limper | calls instead of raising | camera + radar |
| [ ] | 3-bet % | how often they re-raise | camera + radar |
| [ ] | Aggression | bets vs. calls | camera + radar |
| [ ] | Flop seen % | how often they see flops | camera + radar |
| [ ] | Hands played | count tonight | camera + radar |
| [ ] | Card dead | dealt junk all night | peek |
| [ ] | Heater | dealt great cards lately | peek |
| [ ] | Personal space | size of their radar shape | radar |
| [ ] | Closest neighbor | who they sit nearest | radar |

Raise and 3-bet detection need the camera to see chips going in, which is
harder than seeing cards leave; expect VPIP / Nit / Flop seen first.
