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


def _name(label, model, key):
    """How a phone is printed: its label from the app ("Asher's phone"),
    else the model with the short id, else the id."""
    key = key or "?"
    short = key[-4:]
    if label:
        return label
    return f"{short} ({model})" if model else key


def tx_level(tx):
    """The sender's advert power from the dBm its advert carries (same cut
    points as the app's txLevelOf: Pixels send about +1 / -7 / -15 / -21)."""
    if tx is None:
        return None
    if tx >= -3:
        return "high"
    if tx >= -11:
        return "medium"
    if tx >= -18:
        return "low"
    return "ultra_low"


def load_samples(paths):
    """Every kept sample line: dicts with obs, peer, rssi, d, place, run.
    Runs deleted in the app (a raw log with `deleted` markers) are left
    out; app exports already leave them out."""
    out = []
    files = []
    for p in paths:
        files += sorted(glob.glob(os.path.join(p, "*.jsonl"))) if os.path.isdir(p) else [p]
    for f in files:
        lines = []
        with open(f, encoding="utf-8") as fh:
            for raw in fh:
                try:
                    lines.append(json.loads(raw))
                except ValueError:
                    continue  # a torn last line
        deleted = set()
        for j in lines:
            runs = ([j["run"]] if isinstance(j.get("run"), int) else []) + list(j.get("runs") or [])
            if j.get("k") == "deleted":
                deleted.update(runs)
            elif j.get("k") == "undeleted":
                deleted.difference_update(runs)
        # A peer's label as it advertised it; the observer's own label is
        # on every line it wrote.
        for j in lines:
            if j.get("k") != "sample" or j.get("d_m") is None or j.get("rssi") is None or j.get("run") in deleted:
                continue
            out.append({
                "obs": _name(j.get("observerLabel"), j.get("obs_model"), j.get("obs")),
                "peer": _name(j.get("peer_label"), j.get("peer_model"), j.get("peer")),
                "rssi": float(j["rssi"]),
                "d": float(j["d_m"]),
                "place": j.get("place", "?"),
                "run": j.get("run"),
                "tx": j.get("tx"),
                "level": j.get("tx_level") or tx_level(j.get("tx")) or "unknown",
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


def level_fits(samples):
    """Per sender power level: (A, n, sigma) with n free, plus A refitted
    with the pair's pooled n so the levels' offset is like for like."""
    pooled = fit_path_loss(samples)
    by = defaultdict(list)
    for s in samples:
        by[s["level"]].append(s)
    out = {}
    for lv, ss in sorted(by.items()):
        free = fit_path_loss(ss)
        a_fixed = None
        if pooled is not None:
            n = pooled[1]
            a_fixed = sum(s["rssi"] + 10 * n * math.log10(s["d"]) for s in ss) / len(ss)
        out[lv] = (free, a_fixed, len(ss))
    return out


def low_fraction(samples):
    """Per distance: the share of samples heard from low-power adverts out
    of high + low (0.5 if every low advert got through, as the sender
    spends equal time at each)."""
    acc = defaultdict(lambda: [0, 0])
    for s in samples:
        if s["level"] in ("high", "low"):
            acc[s["d"]][s["level"] == "low"] += 1
    return {d: (lo / (hi + lo), hi, lo) for d, (hi, lo) in sorted(acc.items()) if hi + lo}


def report(samples, out=sys.stdout):
    pairs = defaultdict(list)
    for s in samples:
        pairs[(s["obs"], s["peer"])].append(s)
    if not pairs:
        print("no samples found", file=out)
        return 1
    # Both directions of a pair together too (two phones is the usual
    # test: A hearing B and B hearing A).
    both = defaultdict(list)
    for (obs, peer), ss in pairs.items():
        both[tuple(sorted((obs, peer)))] += ss
    for (x, y), ss in sorted(both.items()):
        if (y, x) in pairs and (x, y) in pairs:
            pairs[(x, f"{y} (both directions)")] = ss
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
        levels = level_fits(ss)
        if len(levels) > 1 or "unknown" not in levels:
            for lv, (free, a_fixed, k) in levels.items():
                f = "one distance only" if free is None else f"A = {free[0]:.1f}  n = {free[1]:.2f}  sigma = {free[2]:.1f} dB"
                print(f"  sender at {lv:9s} {k:6d} samples  {f}", file=out)
            if "high" in levels and "low" in levels and levels["high"][1] is not None:
                print(f"  high - low offset (same n): {levels['high'][1] - levels['low'][1]:.1f} dB", file=out)
            for d, (frac, hi, lo) in low_fraction(ss).items():
                print(f"  {d:.2f} m heard at low power: {frac:.0%} ({lo} low / {hi} high)", file=out)
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
