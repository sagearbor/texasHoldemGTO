#!/usr/bin/env bash
# Reproduces data/solved/ (preflop.json, postflop.json) from scratch:
# builds the C++ solvers, then runs the preflop <-> postflop pipeline
# (tool/solver/solve_all.py). Needs clang++ (C++17) and python3 with numpy.
#
# Takes about 3-4 hours on an Apple M4 (10 cores); peak RAM about 7 GB (one
# postflop solve at a time); scratch under tmp/solve (postflop results are
# cached there, so an interrupted run resumes). Settings via env:
#   POST_ITERS (70)   DCFR iterations per flop solve
#   POST_TARGET (1.0) stop early below this exploitability, % of the pot
#   BENCH_ITERS (300) iterations for the A-high c-bet benchmark solves
#   POST2_FLOPS (0)   >0: re-solve the flops with the round-1 ranges on the
#                     N heaviest flops and report the realisation drift
#   THREADS (10)  MEM_GB (8)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tool/.cache tmp/solve
clang++ -O3 -march=native -ffast-math -std=c++17 -o tool/.cache/postflop tool/solver/postflop.cpp
clang++ -O3 -march=native -std=c++17 -o tool/.cache/equity tool/solver/equity.cpp
export POST_ITERS="${POST_ITERS:-70}" MEM_GB="${MEM_GB:-8}"
python3 tool/solver/solve_all.py 2>&1 | tee tmp/solve/pipeline.log
