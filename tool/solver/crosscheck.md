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
