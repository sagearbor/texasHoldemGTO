# Felt Notes solved preflop spots: open dataset

Solved 6-max, 100bb cash-game preflop spots (facing one limper, facing a
3-bet) whose flops are valued by our own heads-up flop + turn + river solves.
Everything here is produced by solver code in this repository
(`tool/solver/`), reproducible with one command (`tool/solve_all.sh`). No
third-party solver output is used anywhere in the data.

License: **CC BY 4.0** (see `LICENSE-DATA`). Credit "Felt Notes,
https://github.com/sagearbor/texasHoldemGTO".

Generated: 2026-10-28. Total compute: about 4.5 h of flop solving (all rounds) on an Apple M4 (10 cores).

## Files

| File | What | Size |
|---|---|---|
| `preflop.json` | every solved preflop game: hero strategy and per-action EVs by hand class, every other decision node (3-bettor, limper) with its reach, exploitability, validation gates | 224 KB |
| `postflop.json` | per pot type: per hand class flop EV, equity and realisation for both players (weighted over the flop subset), per-flop exploitability, the flop subset, the c-bet benchmark | 239 KB |

Hand classes are indexed `row * 13 + col` on the usual 13x13 grid (row/col
0 = ace; suited above the diagonal, offsuit below; `classes` in
`preflop.json` lists the names). EVs are in big blinds relative to the start
of the hand (folding a posted blind = minus the blind).

## Results

| Spot | id | Hero plays | Nash gap (bb/hand) | Flop expl. (% pot) | Passed |
|---|---|---|---|---|---|
| BB vs UTG limp: raise 5bb / check | `cash-limp1-BB` | Raise 5bb 12%, Check 88% | 0.000019 | 2.823 | yes |
| CO vs UTG limp: iso 4bb / overlimp / fold | `cash-limp1-CO` | Iso 4bb 27%, Overlimp 44%, Fold 29% | 0.000017 | 1.959 | **no** |
| BTN vs UTG limp: iso 4bb / overlimp / fold | `cash-limp1-BTN` | Iso 4bb 27%, Overlimp 44%, Fold 29% | 0.000017 | 1.959 | yes |
| SB vs UTG limp: iso 5bb / complete / fold | `cash-limp1-SB` | Iso 5bb 16%, Complete 44%, Fold 40% | 0.000018 | 2.247 | **no** |
| UTG open, BTN 3-bets 7.5bb | `cash-3b-UTG-ip` | 4-bet 25bb 19%, Call 46%, Fold 35% | 0.000018 | 3.307 | **no** |
| UTG open, BB 3-bets 10bb | `cash-3b-UTG-blinds` | 4-bet 22bb 18%, Call 36%, Fold 47% | 0.000018 | 1.899 | **no** |
| CO open, BTN 3-bets 7.5bb | `cash-3b-CO-BTN` | 4-bet 25bb 20%, Call 44%, Fold 37% | 0.000018 | 2.882 | **no** |
| CO open, BB 3-bets 10bb | `cash-3b-CO-blinds` | 4-bet 22bb 11%, Call 43%, Fold 46% | 0.000019 | 2.253 | **no** |
| BTN open, SB 3-bets 10bb | `cash-3b-BTN-SB` | 4-bet 22bb 13%, Call 48%, Fold 38% | 0.000018 | 1.141 | **no** |
| BTN open, BB 3-bets 10bb | `cash-3b-BTN-BB` | 4-bet 22bb 11%, Call 35%, Fold 54% | 0.000018 | 2.319 | **no** |
| SB open 3bb, BB 3-bets 9bb | `cash-3b-SB-BB` | 4-bet 25bb 16%, Call 35%, Fold 48% | 0.000031 | 3.092 | **no** |

`Nash gap` is the sum of both players' best-response gains against the
published strategies, in bb per hand dealt into the spot, *within the model
below* (the error of the model itself is not included). `Flop expl.` is the
worst exploitability of the flop solves feeding the spot, % of the pot.

Spots that fail a validation gate are published with `passed: false` and the
app keeps its previous hand-authored chart for them.

### Validation gates

Checked in the pipeline (`tool/solver/validate.py`) and again on the shipped
file by `test/solved_data_test.dart`:

* AA and KK never fold (the BB facing a limper always raises them).
* Preflop Nash gap below 0.001bb per hand.
* Fixed point: at most 5% of the hero's hands (combo- and reach-weighted)
  change strategy between the last two preflop/postflop rounds.
* Trash (72o, 82o, 92o, 32o, 42o, 83o, T2o, J3o) never iso-raises a limper.
* SB facing a limper: 86s is not a 100% complete, and at least two suited
  connectors mix.
* CO facing a limper plays tighter than the BTN (someone is still behind it).
* Facing a 3-bet, AA and KK 4-bet (together at least one full combo-weight).
* Flop benchmark (reported, see below): BTN vs BB single-raised pot on an
  A-high dry flop should c-bet often and mostly small.

| Spot | Failed gates |
|---|---|
| `cash-limp1-BB` | none |
| `cash-limp1-CO` | CO plays tighter than BTN vs a limper (players behind) (CO 0.710 BTN 0.710) |
| `cash-limp1-BTN` | none |
| `cash-limp1-SB` | SB: 86s not 100% complete (86s complete 1.000); SB: suited connectors mix (mixed: []) |
| `cash-3b-UTG-ip` | fixed point: under 5% of hero's hands move in the last round (0.1993) |
| `cash-3b-UTG-blinds` | fixed point: under 5% of hero's hands move in the last round (0.2288) |
| `cash-3b-CO-BTN` | fixed point: under 5% of hero's hands move in the last round (0.0821) |
| `cash-3b-CO-blinds` | fixed point: under 5% of hero's hands move in the last round (0.2978) |
| `cash-3b-BTN-SB` | fixed point: under 5% of hero's hands move in the last round (0.1836) |
| `cash-3b-BTN-BB` | fixed point: under 5% of hero's hands move in the last round (0.2019) |
| `cash-3b-SB-BB` | fixed point: under 5% of hero's hands move in the last round (0.18) |

### Flop benchmark: A-high dry single-raised pot

BTN (in position) after the BB checks, single-raised pot, ranges from the solved BTN-vs-BB 3-bet game:

| Flop | Check | Bet 33% | Bet 75% | Flop expl. (% pot) | Iterations |
|---|---|---|---|---|---|
| As7d2c | 1% | 94% | 5% | 0.13 | 300 |
| Ah8c3d | 4% | 94% | 1% | 0.13 | 275 |

Reference: full-tree solvers put BTN vs BB on A-high dry boards at roughly 80%+ c-bets, almost all with the small size. With the solved preflop ranges the pipeline gets 99% (A72r) and 96% (A83r) c-bets, about 94% of hands small: high frequency and mostly small, so the benchmark the earlier flop+turn attempt failed (about 50%) passes. Caveats: the ranges come from the last fixed-point round of the BTN-vs-BB 3-bet game, which had not settled (see Limitations); the BB flats about as often as in the app's chart (53% vs 52% of hands) but with a different mix, and the frequency overshoots the reference. With the chart ranges instead, the same tree gives 58% (44% small, 14% big), see the cross-check below, so the benchmark result is sensitive to the BB's flat range.

### Cross-check

TexasSolver (github.com/bupticybee/TexasSolver, AGPL) was built locally,
outside this repository, and used only as an independent check; none of its
code or output is in this dataset or the app. Test spot: BTN vs BB
single-raised pot on As7d2c, pot 5.5bb, 97.5bb behind, the app's BTN open
chart vs the chart BB flat range, a tree as close to ours as TexasSolver's
menu allows (flop 33% / 75% for the BTN, no BB donk, 75% turn and river
bets, pot-size raises, all-in options; TexasSolver rounds bets to whole
chips).

| Solver | Exploitability (% pot) | BTN after BB checks: check / bet 33% / bet 75% |
|---|---|---|
| TexasSolver, 125 iterations | 1.16 | 30% / 53% / 17% |
| Felt Notes postflop.cpp, raise 3x, 150 iterations | 0.47 | 42% / 44% / 14% |
| Felt Notes postflop.cpp, raise 6.4x (about pot), 125 iterations | 0.84 | 39% / 38% / 23% |

Both solvers agree on the shape (bet more often than not, small more than
big; big pairs and strong aces bet, weak kings and middle cards mix) and
differ by about 10 points in c-bet frequency, which is within what the
remaining tree differences (raise sizes, all-in options, chip rounding) and
convergence at about 1% of the pot move flop frequencies by. With these
chart ranges neither restricted tree reaches the 80%+ that full-tree solvers
report; with the pipeline's solved ranges our tree does (benchmark above).
The solver agrees with an independent one; the c-bet frequency is driven by
the ranges and the bet menu.

## Method

One pipeline, two solvers, iterated:

1. **Preflop games** (`tool/solver/preflop.py`): two-player games over the
   169 hand classes with exact card-removal pair counts, solved with
   Discounted CFR (alpha 1.5, beta 0, gamma 2) until the Nash gap is below
   2e-5bb per hand. Terminal values:
   * fold: the pot goes to the other player;
   * all-in preflop: pot x all-in equity (169x169 Monte Carlo table, 100k
     deals per class pair);
   * heads-up flop: pot x realisation-adjusted share
     `s = e R1 / (e R1 + (1 - e) R2)`, where `e` is the all-in equity of the
     two classes and `R` is the solved realisation factor (flop EV / (equity x
     pot)) of that class for that player in that pot type (step 2);
   * called 4-bets: solved heads-up flop like the rest (SPR under 2);
   * called limp-reraises (SPR about 2, rare): all-in equity;
   * three-way limped pots (after an overlimp or a complete): each player gets
     pot x three-way equity x the realisation of its seat in the solved
     heads-up limped pot (first to act: the BB's table, last to act: the
     limper's). This is a model, not a multiway solve.
2. **Flop solves** (`tool/solver/postflop.cpp`): the full heads-up game from
   the flop to the river, every turn and river card dealt, exact hole-card
   combos with card removal, no card or action abstraction beyond the bet
   menu; Discounted CFR vectorised over combos, sorted-strength showdown
   evaluation. Bet menu (fractions of the pot):
   * flop: the player in position may bet 33% or 75% after a check; the
     player out of position may bet 33% or 75% only if it made the last
     preflop raise (no donk bets);
   * turn and river: 75% for either player;
   * raises: to 3x the bet, one per street, then an all-in re-raise;
   * a bet or raise leaving less than 20% of the stack behind becomes all-in.
   Each pot type is solved on the flop subset with the exact ranges that
   reach it in the round-0 preflop solution (70 iterations or
   1.0% of the pot, whichever first); these are the EV tables
   published in `postflop.json` (`realisationUsed` holds the final, corrected
   tables the preflop spots were solved with). Per class EVs are averaged over the subset with the flop
   weights, giving `R`. Where a class never reaches the flop, `R` comes from
   a weighted linear fit of `R` on equity; observed values are shrunk lightly
   toward that fit and clipped to [0.2, 2.0].
3. **Fixed point**: round 0 solves the preflop games with a prior realisation
   (in position 1.05, out of position 0.85, slightly higher for strong
   hands); its ranges feed the flop solves; round 1 re-solves the preflop
   games with the solved `R` tables. Moving from the prior to the solved tables moved the flop ranges a lot (median share of combos that changed at a flop leaf: 0.51).

   Further rounds re-solve every pot type on the 3 heaviest flops of the subset with the current ranges and correct the full tables by the change seen there (R = R_full + R_sub(now) - R_sub(round 0)), damped 50/50 with the previous round:

   | Round | Largest mean change in R | Median range drift | Largest range drift |
   |---|---|---|---|
   | 2 | 0.563 | 0.453 | 0.624 |
   | 3 | 0.626 | 0.392 | 0.809 |

   Range drift = share of a flop leaf's combos that changed between consecutive rounds. The published spots are the last round.

**Flop subset** (`tool/solver/flops.py`): the 22,100 flops are reduced to the
1,755 suit-isomorphism classes, split into 11 strata (unpaired rainbow and
two-tone by high card A / K / Q-J / T-or-lower, monotone, paired with a T+ or
lower pair), and each stratum is represented by its weighted medoid. Weights
are each stratum's share of all flops:

| Flop | Stratum | Weight |
|---|---|---|
| 9s6h3h | T--twotone | 13.7% |
| Qs8h4h | QJ-twotone | 13.2% |
| AsTh5h | A-twotone | 10.8% |
| 9s5h5d | paired-low | 10.6% |
| 9s6h3d | T--rainbow | 9.1% |
| Ks9h5h | K-twotone | 9.0% |
| Qs8h4d | QJ-rainbow | 8.8% |
| AsTh5d | A-rainbow | 7.2% |
| QsQh8d | paired-high | 6.6% |
| Ks9h5d | K-rainbow | 6.0% |
| Qs8s4s | monotone | 5.2% |

**Inputs that are not solved** (assumptions):

* Opening ranges facing a 3-bet are the app's approximate 6-max RFI charts
  (2.5bb opens, 3bb from the SB).
* The UTG limper plays a fixed loose-passive range:
  `22-TT, JJ:0.3, QQ+:0.15, A2s-AJs, AQs:0.4, AKs:0.2, K8s+, Q9s+, J9s+, T8s+, 97s+, 86s+, 75s+, 64s+, 54s, A8o-AJo, AQo:0.5, AKo:0.2, KTo+, QTo+, JTo, T9o:0.5`. Its responses to an iso-raise are solved.

**Game simplifications**:

* 6-max, 100bb effective, blinds 0.5/1, no ante, **no rake**.
* Heads-up reduction: everyone not named in the spot folds. Facing a limper,
  players behind the hero fold to an iso-raise; after an overlimp or a
  complete the SB folds and the BB checks its option.
* Sizes: iso 4bb in position, 5bb from the blinds; limp-reraise to 4x;
  3-bet 7.5bb in position, 10bb from the blinds (9bb BB vs SB); 4-bet 22bb in
  position, 25bb out of position; 5-bet all-in. The SB 3-bets or folds (no
  flat) against the BTN.
* Flops: the bet menu above, a 11-flop subset, 70 DCFR
  iterations per flop (0.2-3.3% of the pot exploitable; deep limped and
  single-raised pots are the loosest, per-flop numbers in `postflop.json`). The flop strategies are a by-product; the dataset publishes
  their EVs, not their actions, except for the benchmark.

## Limitations

* **The facing-a-3-bet games did not reach a fixed point** in the rounds
  run (18-30% of the opener's hands still changed strategy in the last
  round, against a 5% gate), so all seven are published with
  `passed: false` and the app keeps its hand-authored charts for them. The
  limp games settled (2-4% in the last round). More rounds, heavier damping
  and more flops per round are the obvious next step.
* The CO-facing-a-limper game is identical to the BTN game in this model
  (players behind fold), so it fails its gate. The SB-facing-a-limper
  solution is pure (every suited connector completes 100%), so it fails the
  mixing gate.

* Multiway pots are not solved: three-way limped pots use the realisation
  model above, and the facing-two-limpers spots are not solved at all.
* The reduced bet menu (no turn/river small bets, no flop donks for the
  preflop caller) lowers how often the preflop raiser bets small on the
  flop compared with full-tree solvers; see the benchmark.
* An 11-flop subset is coarse; per-class realisation for rarely-played
  classes has noticeable sampling error.
* Exploitability numbers are within the model. The model error (abstraction,
  heads-up reduction, realisation model) is not bounded by them.

## Reproduce

```bash
tool/solve_all.sh      # about 4.5 hours on an Apple M4; resumes if interrupted
```

Needs clang++ (C++17) and python3 with numpy. Scratch goes to `tmp/solve`
(gitignored, under 1 GB) and is safe to delete afterwards.
