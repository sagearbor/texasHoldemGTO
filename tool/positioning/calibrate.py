#!/usr/bin/env python3
"""Bluetooth distance test, offline: fit the path-loss model per phone pair.

Reads the JSONL files the app's "Bluetooth distance test" screen exports
(lib/nearby/distance_test_screen.dart; lines k = "sample" with obs, peer,
rssi, d_m, place, run) and fits, per (observer, peer) pair,

    RSSI = A - 10 * n * log10(d)

by least squares over every raw sample. Prints A (dBm at 1 m), n (the
path-loss exponent), the per-sample sigma (residual sd, dB), and the
spread of per-run medians at the same distance and placement (what is
left once fast fading averages out: phone placement / static error), plus
the mean residual per placement. Standard library only.

  python3 tool/positioning/calibrate.py ~/Downloads/bt-distance-*.jsonl
"""

import argparse
import glob
import json
import math
import os
import sys
from collections import defaultdict


def load_samples(paths):
    """Every sample line: dicts with obs, peer, rssi, d, place, run."""
    out = []
    files = []
    for p in paths:
        files += sorted(glob.glob(os.path.join(p, "*.jsonl"))) if os.path.isdir(p) else [p]
    for f in files:
        with open(f, encoding="utf-8") as fh:
            for raw in fh:
                try:
                    j = json.loads(raw)
                except ValueError:
                    continue  # a torn last line
                if j.get("k") != "sample" or j.get("d_m") is None or j.get("rssi") is None:
                    continue
                out.append({
                    "obs": j.get("obs_model") and f"{j['obs'][-4:]} ({j['obs_model']})" or j.get("obs", "?"),
                    "peer": j.get("peer_model") and f"{j['peer'][-4:]} ({j['peer_model']})" or j.get("peer", "?"),
                    "rssi": float(j["rssi"]),
                    "d": float(j["d_m"]),
                    "place": j.get("place", "?"),
                    "run": j.get("run"),
                })
    return out


def fit_path_loss(samples):
    """Least squares RSSI = A - 10 n log10(d). Returns (A, n, sigma) or None
    when the distances do not vary."""
    xs = [math.log10(s["d"]) for s in samples]
    ys = [s["rssi"] for s in samples]
    k = len(xs)
    if k < 2:
        return None
    mx, my = sum(xs) / k, sum(ys) / k
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx < 1e-12:
        return None
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    a = my - b * mx
    res = [y - (a + b * x) for x, y in zip(xs, ys)]
    sigma = math.sqrt(sum(r * r for r in res) / max(1, k - 2))
    return a, -b / 10.0, sigma


def _median(xs):
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def _sd(xs):
    if len(xs) < 2:
        return 0.0
    m = sum(xs) / len(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def run_median_spread(samples):
    """Per (distance, placement): the run medians and their sd. Only groups
    with 2+ runs say anything about static error."""
    runs = defaultdict(list)
    for s in samples:
        runs[(s["d"], s["place"], s["run"])].append(s["rssi"])
    groups = defaultdict(list)
    for (d, place, _), rs in runs.items():
        groups[(d, place)].append(_median(rs))
    return {g: (meds, _sd(meds)) for g, meds in sorted(groups.items())}


def placement_offsets(samples, fit):
    """Mean residual (dB) per placement against the pair's fit."""
    a, n, _ = fit
    acc = defaultdict(list)
    for s in samples:
        acc[s["place"]].append(s["rssi"] - (a - 10 * n * math.log10(s["d"])))
    return {p: sum(v) / len(v) for p, v in sorted(acc.items())}


def report(samples, out=sys.stdout):
    pairs = defaultdict(list)
    for s in samples:
        pairs[(s["obs"], s["peer"])].append(s)
    if not pairs:
        print("no samples found", file=out)
        return 1
    for (obs, peer), ss in sorted(pairs.items()):
        print(f"\n{obs} hearing {peer}: {len(ss)} samples, "
              f"distances {sorted({s['d'] for s in ss})}", file=out)
        fit = fit_path_loss(ss)
        if fit is None:
            print("  one distance only: cannot fit A and n (record at 2+ distances)", file=out)
        else:
            a, n, sigma = fit
            print(f"  A = {a:.1f} dBm at 1 m   n = {n:.2f}   per-sample sigma = {sigma:.1f} dB", file=out)
            for p, off in placement_offsets(ss, fit).items():
                print(f"  placement {p:10s} mean residual {off:+.1f} dB", file=out)
        for (d, place), (meds, sd) in run_median_spread(ss).items():
            tail = f"sd of run medians {sd:.1f} dB" if len(meds) > 1 else "(1 run)"
            print(f"  {d:.2f} m {place:10s} run medians {[round(m, 1) for m in meds]} {tail}", file=out)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="bt-distance-*.jsonl files or folders")
    a = ap.parse_args(argv)
    return report(load_samples(a.paths))


if __name__ == "__main__":
    sys.exit(main())
