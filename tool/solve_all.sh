#!/usr/bin/env bash
# Reproduces data/solved/ (preflop.json, postflop.json, README.md) from
# scratch: builds the C++ solvers, then runs the preflop <-> postflop
# pipeline (tool/solver/solve_all.py). Needs clang++ (C++17) and python3
# with numpy.
#
# Takes about 2 days on an Apple M4 (10 cores); peak RAM about 8 GB (one
# flop solve at a time); scratch under tmp/solve (every flop solve is cached
# there, so an interrupted run resumes). Settings via env:
#   FLOPS_K (54)        flops per pot type
#   POST_TARGET (0.97)  every flop solve runs to this exploitability, % pot
#   POST_ITERS (1000)   iteration cap per flop solve
#   SUB_N (12)          flops in the fixed-point correction subset
#   FP_MAX (14) FP_DAMP_MIN (0.25) ALL_EVERY (4) FP_STOP (0.03)   fixed-point rounds
#   START_R             starting realisation tables (round 0 only; JSON
#                       {potType: {"0": [...], "1": [...]}}); default
#                       tmp/solve/start_R.json if present, else a prior
#   THREADS (10)  MEM_GB (9.5)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tool/.cache tmp/solve
clang++ -O3 -march=native -ffast-math -std=c++17 -o tool/.cache/postflop tool/solver/postflop.cpp
clang++ -O3 -march=native -std=c++17 -o tool/.cache/equity tool/solver/equity.cpp
python3 tool/solver/solve_all.py 2>&1 | tee -a tmp/solve/pipeline.log
