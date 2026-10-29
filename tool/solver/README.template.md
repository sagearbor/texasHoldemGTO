# Felt Notes solved preflop spots: open dataset

Solved 6-max, 100bb cash-game preflop spots (facing one limper, facing a
3-bet) whose flops are valued by our own heads-up flop + turn + river solves.
Everything here is produced by solver code in this repository
(`tool/solver/`), reproducible with one command (`tool/solve_all.sh`). No
third-party solver output is used anywhere in the data.

License: **CC BY 4.0** (see `LICENSE-DATA`). Credit "Felt Notes,
https://github.com/sagearbor/texasHoldemGTO".

Generated: {{generated}}. Total compute: {{compute}} on an Apple M4 (10 cores).

## Files

| File | What | Size |
|---|---|---|
| `preflop.json` | every solved preflop game: hero strategy and per-action EVs by hand class, every other decision node (limper, seats behind, 3-bettor) with its reach, exploitability, fixed-point and validation gates | {{size_pre}} |
| `postflop.json` | per pot type: per hand class flop EV, equity and realisation for both players (weighted over the flop set), per-flop exploitability, the flop set, the c-bet benchmark | {{size_post}} |

Hand classes are indexed `row * 13 + col` on the usual 13x13 grid (row/col
0 = ace; suited above the diagonal, offsuit below; `classes` in
`preflop.json` lists the names). EVs are in big blinds relative to the start
of the hand (folding a posted blind = minus the blind).

## Results

{{spot_table}}

`Nash gap` is the sum of every player's best-response gain against the
published strategies, in bb per hand dealt into the spot, *within the model
below* (the error of the model itself is not included). `Worst flop expl.`
is the largest exploitability of any flop solve feeding the spot (its own
pots and the pots it borrows tables from), % of the pot. `Fixed-point
delta` is the share of the hero's hands whose strategy would still move if
the preflop game were re-solved with the flop tables measured on the
published ranges (undamped; see Method).

Spots that fail a validation gate are published with `passed: false` and the
app keeps its previous hand-authored chart for them.

### Flop solves: exploitability

{{expl_table}}

### Acceptance checks (independent of the pipeline)

A spot reaches the app only if it passes the pipeline gates below **and**
`tool/solver/acceptance.py`, run from the main branch at merge time
(`--write` records `accepted` per spot). Those checks are poker facts and
convergence tests: at least 40 flops per pot type, every flop solve under
1% of the pot exploitable, the strategy is a best response to its own EVs,
a bigger pair / better kicker / suited version is never worth more than
0.05bb less, AA/KK never fold, trash never raises a limper, the CO/BTN fold
weak offsuit hands to a limper, and the CO plays tighter than the BTN.

### Validation gates

Checked in the pipeline (`tool/solver/validate.py`) and again on the shipped
file by `test/solved_data_test.dart`:

* AA and KK never fold (the BB facing a limper always raises them).
* Preflop Nash gap below 0.001bb per hand; in the multiway limp games every
  player's own best-response gain is below 0.001bb too.
* Every flop solve feeding the spot is under 1% of the pot exploitable.
* Fixed point: at most 5% of the hero's hands (combo- and reach-weighted)
  move when the game is re-solved with the flop tables measured on the
  published ranges, undamped.
* Trash (72o, 82o, 92o, 32o, 42o, 83o, T2o, J3o) never iso-raises a limper.
* Facing a limper, the CO and BTN fold offsuit junk (K2o-K3o, Q2o-Q4o,
  J2o-J4o, T2o-T4o, 92o-94o, 82o-84o, 72o-73o, 62o, 52o, 42o, 32o) at least
  95% of the time.
* SB facing a limper: 86s is not a 100% complete, and at least two suited
  connectors mix.
* CO facing a limper plays tighter than the BTN (more players behind it),
  and its iso range is no wider.
* Facing a limper, every seat behind the hero is a solved player that can
  raise over the hero's limp or complete and 3-bet its iso (the v1 model
  folded them, which overrated overlimping).
* Borrowed flop tables (see Method): re-solving with a second, equally
  plausible donor pot for every borrowed table moves at most 5% of the
  hero's hands.
* Pairs: the aggressive action's EV never drops by more than 0.1bb from a
  smaller pair to the next bigger one.
* Dominance: a bigger pair, a better kicker (AK > AQ > AJ > AT > A9, KQ > KJ >
  KT > K9, QJ > QT > Q9, JT > J9) or the suited version of a hand is never
  worth more than 0.05bb less (best action's EV).
* Facing a 3-bet, AA and KK 4-bet (together at least one full combo-weight),
  and QQ and AKs never fold.
* Flop benchmark (reported, see below): BTN vs BB single-raised pot on an
  A-high dry flop should c-bet often and mostly small.

{{gate_table}}

### Flop benchmark: A-high dry single-raised pot

{{bench}}

### Cross-check

{{crosscheck}}

## Method

One pipeline, three solvers, iterated:

1. **Facing-a-3-bet games** (`tool/solver/preflop.py`): two-player games
   over the 169 hand classes with exact card-removal pair counts, solved
   with Discounted CFR (alpha 1.5, beta 0, gamma 2) until the Nash gap is
   below 2e-5bb per hand. Everyone not in the spot folds. Terminal values:
   * fold: the pot goes to the other player;
   * all-in preflop: pot x all-in equity (169x169 Monte Carlo table, 100k
     deals per class pair);
   * heads-up flop: pot x realisation-adjusted share
     `s = e R1 / (e R1 + (1 - e) R2)`, where `e` is the all-in equity of the
     two classes and `R` is the solved realisation factor (flop EV / (equity x
     pot)) of that class for that player in that pot type (step 3).
2. **Facing-a-limper games** (`tool/solver/multiway.py`, trees in
   `tool/solver/limp.py`): the hero, the limper and **every seat behind the
   hero** are solved players (the CO game has five: CO, UTG, BTN, SB, BB).
   * Over the hero's overlimp or complete each seat behind may raise (BTN
     to 5bb, blinds to 6bb; the BB may check); once one raises, the seats
     after it fold; the limper folds or calls; the hero folds, calls, or (if
     the limper folded) re-raises to 4x, which the raiser folds, calls (all-in
     equity, SPR about 2) or jams. Nobody raises: a three-way limped pot
     with the BB.
   * Over the hero's iso (4bb, 5bb from the SB) the BTN folds, calls or
     3-bets to 12bb, the SB folds or 3-bets to 15bb, the BB folds, calls or
     3-bets to 15bb; once one calls or 3-bets, the seats after it fold.
     After a 3-bet the limper folds and the hero folds, calls or 4-bets
     (2.2x in position, 2.5x out of position), then the 3-bettor folds,
     calls or jams. After a cold call the limper folds or calls (three-way
     pot). Nobody behind acts: the limper folds, calls or re-raises to 4x.
   * Card removal is exact between the hero and each opponent and ignored
     between two opponents (a star-shaped deal model; with two players it is
     exactly the model of step 1).
   * Three-way flops: share `e_i R_i / sum_j e_j R_j` from a 169^3 three-way
     equity tensor (10k Monte Carlo deals per class triple) and the
     aggressor's / callers' realisation tables of the matching heads-up pot;
     limped three-way pots use the BB's table for the first seat to act, the
     limper's for the last and their mean in between. This keeps the pot
     whole, so the game is zero-sum overall; it is a model, not a multiway
     solve.
   * Heads-up pots the limp games reach: the hero vs the limper after an iso
     (`ISO:<hero>-UTG`) and the BB's limped pot are solved (step 3). The
     rest borrow the table of the matching open-raise pot: hero iso, BTN or
     BB calls -> `SRP:<hero>-<seat>`; a seat 3-bets the iso ->
     `3BP:<hero>-<seat>` (`4BP` after a 4-bet); a seat raises the limps and
     the hero or limper calls -> that seat's own `ISO:<seat>-UTG` pot
     (raiser = aggressor table). The borrowing gate re-solves each game with
     a second donor for every borrowed table (e.g. `SRP:UTG-BTN` for
     `SRP:CO-BTN`); hero strategy change: {{borrow}}.
   * CFR has no convergence guarantee with more than two players, so the
     Nash gap (sum of every player's best-response gain) is measured and
     gated like the heads-up games.
3. **Flop solves** (`tool/solver/postflop.cpp`): the full heads-up game from
   the flop to the river, every turn and river card dealt, exact hole-card
   combos with card removal, no card or action abstraction beyond the bet
   menu; Discounted CFR vectorised over combos, sorted-strength showdown
   evaluation; turn cards related by a suit symmetry of the flop are solved
   once (exact). Bet menu (fractions of the pot):
   * flop: the player in position may bet 33% or 75% after a check; the
     player out of position may bet 33% or 75% only if it made the last
     preflop raise (no donk bets);
   * turn and river: 75% for either player;
   * raises: to 3x the bet, one per street, then an all-in re-raise;
   * a bet or raise leaving less than 20% of the stack behind becomes all-in.
   Every solve runs until it is under {{post_target}}% of the pot exploitable
   (checked by a best-response pass). Per class EVs are averaged over the
   flop set with its weights, giving `R`; every class with any weight in the
   range is in the solve, so `R` is measured, not sampled. Classes with a
   tiny share of the range are shrunk lightly toward a weighted linear fit of
   `R` on equity, which also fills classes that never reach the flop;
   clipped to [0.2, 2.0].
4. **Fixed point** between the preflop games and the flop tables:
   * round 0: the preflop games with starting tables (the v1 dataset's
     published tables; any table works, only the starting point changes);
   * pass A: every pot solved on the {{n_sub}}-flop correction subset
     ({{sub_flops}}) with the round-0 ranges; round 1 re-solves the preflop
     games with those tables;
   * pass B: every pot solved on all {{n_flops}} flops with the round-1
     ranges; these are the EV tables published in `postflop.json`;
   * round k: the subset is re-solved with the current ranges and the
     all-flop tables corrected by the change seen there,
     `R = R_B(all) + R_sub(now) - R_B(sub)`, damped with the previous
     round, and the preflop games are re-solved (continuing CFR from the
     previous round's regrets);
   * check: after each round the correction is measured on the current
     ranges and applied **undamped**; the share of hero hands that moves is
     the published `fixedPointDelta`.

   {{fixed_point}}

**Flop set** (`tool/solver/flops.py`): the 22,100 flops are reduced to the
1,755 suit-isomorphism classes, split into 11 strata (unpaired rainbow and
two-tone by high card A / K / Q-J / T-or-lower, monotone, paired with a T+ or
lower pair); {{n_flops}} representatives are allocated to the strata by
weight and chosen as weighted k-medoids over rank features (including
which ranks are on the board). Each representative's starting weight is the
share of flops nearest to it; a bounded calibration (each weight within
0.25x-4x of its start) then makes the set reproduce the exact population
stratum shares, the distribution of the highest card, and the probability
that each rank appears on the flop (largest error 2e-4). Without that, a
subset over-represents some ranks and biases the realisation of the
matching pocket pairs: v1's 11 flops valued 66 above 77.

{{flop_table}}

**Inputs that are not solved** (assumptions):

* Opening ranges facing a 3-bet are the app's approximate 6-max RFI charts
  (2.5bb opens, 3bb from the SB).
* The UTG limper plays a fixed loose-passive range:
  `{{limp}}`. Its responses after the limp are solved.

**Game simplifications**:

* 6-max, 100bb effective, blinds 0.5/1, no ante, **no rake**.
* Facing a 3-bet: everyone not named in the spot folds. Sizes: 3-bet 7.5bb in
  position, 10bb from the blinds (9bb BB vs SB); 4-bet 22bb in position, 25bb
  out of position; 5-bet all-in. The SB 3-bets or folds (no flat) against
  the BTN.
* Facing a limper: the trees above (no cold 4-bets, no squeezes of a raise
  by the seats after the raiser, the SB never completes behind a limper it
  can raise, the limper folds to a 3-bet of an iso). The BB spot is folded
  to the BB.
* Flops: the bet menu above, {{n_flops}} flops, every solve under
  {{post_target}}% of the pot. The flop strategies are a by-product; the
  dataset publishes their EVs, not their actions, except for the benchmark.

## Limitations

{{limitations}}

## Reproduce

```bash
tool/solve_all.sh      # about {{hours}} hours on an Apple M4; resumes if interrupted
```

Needs clang++ (C++17) and python3 with numpy. Scratch goes to `tmp/solve`
(gitignored, about 1 GB) and is safe to delete afterwards. Round 0 starts
from `tmp/solve/start_R.json` if present (the v1 run used its own published
`realisationUsed` tables), otherwise from a prior.
