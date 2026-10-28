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
| `preflop.json` | every solved preflop game: hero strategy and per-action EVs by hand class, every other decision node (3-bettor, limper) with its reach, exploitability, validation gates | {{size_pre}} |
| `postflop.json` | per pot type: per hand class flop EV, equity and realisation for both players (weighted over the flop subset), per-flop exploitability, the flop subset, the c-bet benchmark | {{size_post}} |

Hand classes are indexed `row * 13 + col` on the usual 13x13 grid (row/col
0 = ace; suited above the diagonal, offsuit below; `classes` in
`preflop.json` lists the names). EVs are in big blinds relative to the start
of the hand (folding a posted blind = minus the blind).

## Results

{{spot_table}}

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
* Facing a limper, nobody may still be to act behind the hero: the model
  folds those seats (the blinds never raise an overlimp or 3-bet an iso),
  so only the BB spot is solved in the real game.
* Pairs: the aggressive action's EV never drops by more than 0.1bb from a
  smaller pair to the next bigger one (a bigger pair dominates; an
  inversion is sampling noise from the flop subset).
* Facing a 3-bet, AA and KK 4-bet (together at least one full combo-weight).
* Flop benchmark (reported, see below): BTN vs BB single-raised pot on an
  A-high dry flop should c-bet often and mostly small.

{{gate_table}}

### Flop benchmark: A-high dry single-raised pot

{{bench}}

### Cross-check

{{crosscheck}}

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
   reach it in the round-0 preflop solution ({{post_iters}} iterations or
   {{post_target}}% of the pot, whichever first); these are the EV tables
   published in `postflop.json` (`realisationUsed` holds the final, corrected
   tables the preflop spots were solved with). Per class EVs are averaged over the subset with the flop
   weights, giving `R`. Where a class never reaches the flop, `R` comes from
   a weighted linear fit of `R` on equity; observed values are shrunk lightly
   toward that fit and clipped to [0.2, 2.0].
3. **Fixed point**: round 0 solves the preflop games with a prior realisation
   (in position 1.05, out of position 0.85, slightly higher for strong
   hands); its ranges feed the flop solves; round 1 re-solves the preflop
   games with the solved `R` tables. {{fixed_point}}

**Flop subset** (`tool/solver/flops.py`): the 22,100 flops are reduced to the
1,755 suit-isomorphism classes, split into 11 strata (unpaired rainbow and
two-tone by high card A / K / Q-J / T-or-lower, monotone, paired with a T+ or
lower pair), and each stratum is represented by its weighted medoid. Weights
are each stratum's share of all flops:

{{flop_table}}

**Inputs that are not solved** (assumptions):

* Opening ranges facing a 3-bet are the app's approximate 6-max RFI charts
  (2.5bb opens, 3bb from the SB).
* The UTG limper plays a fixed loose-passive range:
  `{{limp}}`. Its responses to an iso-raise are solved.

**Game simplifications**:

* 6-max, 100bb effective, blinds 0.5/1, no ante, **no rake**.
* Heads-up reduction: everyone not named in the spot folds. Facing a limper,
  players behind the hero fold to an iso-raise; after an overlimp or a
  complete the SB folds and the BB checks its option.
* Sizes: iso 4bb in position, 5bb from the blinds; limp-reraise to 4x;
  3-bet 7.5bb in position, 10bb from the blinds (9bb BB vs SB); 4-bet 22bb in
  position, 25bb out of position; 5-bet all-in. The SB 3-bets or folds (no
  flat) against the BTN.
* Flops: the bet menu above, a {{n_flops}}-flop subset, {{post_iters}} DCFR
  iterations per flop (0.2-3.3% of the pot exploitable; deep limped and
  single-raised pots are the loosest, per-flop numbers in `postflop.json`). The flop strategies are a by-product; the dataset publishes
  their EVs, not their actions, except for the benchmark.

## Limitations

* **No spot passes every gate, so the app ships none of them** and keeps
  its hand-authored charts. The BB-vs-limper game is the closest: it
  settled, but its per-class EVs are noisy (raise 66 +0.72bb, raise 77
  +0.11bb), which would teach "raise 66, check 77". More flops per pot
  type, so each class's realisation is measured rather than sampled, is
  the fix.
* **The facing-a-3-bet games did not reach a fixed point** in the rounds
  run (18-30% of the opener's hands still changed strategy in the last
  round, against a 5% gate), so all seven are published with
  `passed: false` and the app keeps its hand-authored charts for them. The
  limp games settled (2-4% in the last round). More rounds, heavier damping
  and more flops per round are the obvious next step.
* Facing a limper, only the BB passes: for the CO, BTN and SB the model
  folds the seats behind, which overrates overlimping (the BTN solution
  overlimps hands like K3o and Q5o), so they fail the seats-behind gate.
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
tool/solve_all.sh      # about {{hours}} hours on an Apple M4; resumes if interrupted
```

Needs clang++ (C++17) and python3 with numpy. Scratch goes to `tmp/solve`
(gitignored, under 1 GB) and is safe to delete afterwards.
