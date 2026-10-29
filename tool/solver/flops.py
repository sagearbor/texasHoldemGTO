"""Representative flop subset, weighted to the 1,755 strategically distinct
(suit-isomorphic) flops.

1. Every one of the 22,100 flops is mapped to its suit-isomorphism class
   (1,755 classes).
2. Classes are split into 11 strata by structure (see stratum()); the K
   representatives are allocated to the strata in proportion to their share
   of all flops (largest remainder, at least one each).
3. Inside a stratum the representatives are weighted k-medoids over rank
   features (high, middle, low card, gaps; which two cards share a suit on
   two-tone flops; which ranks are present); every class is assigned to its nearest representative,
   which gives each representative a starting weight (the share of all
   22,100 flops it stands for).
4. Calibration (bounded linear raking, Deville & Sarndal 1992) then adjusts
   those weights, each within 0.25x-4x of its starting value, so the subset
   reproduces three sets of exact population margins at once: the stratum
   shares, the probability that each rank appears on the flop, and the
   distribution of the flop's highest card. Without this a subset
   over-represents some ranks (v1's 11 flops put a 6 or a 9 on a third of
   the weight), and the per-class realisation of the matching pocket pairs
   (sets) and overcards is biased: v1 valued 66 above 77.

Usage: python3 flops.py [K]  -> JSON list of
  {"flop": "As7d2c", "weight": w, "stratum": s, "medoidWeight": w0}
"""
import itertools
import json
import sys

import numpy as np

np.seterr(all="ignore")  # Accelerate raises spurious matmul warnings

RANKS = "23456789TJQKA"


def canon(cards):
    """cards: list of (rank, suit). Canonical key under suit relabelling."""
    best = None
    for perm in itertools.permutations(range(4)):
        k = tuple(sorted(((r, perm[s]) for r, s in cards), reverse=True))
        if best is None or k < best:
            best = k
    return best


def stratum(key):
    """11 strata: unpaired rainbow / two-tone x high card (A, K, Q-J, T or
    lower), monotone, paired (pair T+ / pair 9 or lower, trips included)."""
    ranks = [r for r, _ in key]
    suits = [s for _, s in key]
    if len(set(ranks)) < 3:
        pr = max(r for r in ranks if ranks.count(r) >= 2)
        return "paired-high" if pr >= 8 else "paired-low"
    ns = len(set(suits))
    if ns == 1:
        return "monotone"
    hi = max(ranks)
    hg = "A" if hi == 12 else "K" if hi == 11 else "QJ" if hi >= 9 else "T-"
    return hg + ("-rainbow" if ns == 3 else "-twotone")


def suited_pair(key):
    """Which two of the (high, mid, low) cards share a suit on a two-tone
    flop: 0 = high+mid, 1 = high+low, 2 = mid+low, -1 otherwise."""
    s = [x for _, x in key]
    if len(set(s)) != 2:
        return -1
    return 0 if s[0] == s[1] else (1 if s[0] == s[2] else 2)


def features(key):
    r = sorted((x for x, _ in key), reverse=True)
    return (r[0], r[1], r[2], r[0] - r[1], r[1] - r[2], len(set(r)))


FW = np.array([1.5, 0.8, 0.6, 0.5, 0.5, 4.0])


def dist_matrix(keys):
    F = np.array([features(k) for k in keys], float)
    D = (np.abs(F[:, None, :] - F[None, :, :]) * FW).sum(-1)
    sp = np.array([suited_pair(k) for k in keys])
    D += 1.5 * (sp[:, None] != sp[None, :])
    # ranks present on one flop but not the other (2 each): keeps every
    # rank represented, so the calibration below has room to work
    M = np.array([[1.0 if any(x == r for x, _ in k) else 0.0 for r in range(13)] for k in keys])
    D += 2.0 * np.abs(M[:, None, :] - M[None, :, :]).sum(-1)
    return D


def to_str(key):
    # assign concrete suits: canonical suit labels -> s, h, d, c in order of appearance
    out = ""
    names = {}
    order = "shdc"
    for r, s in key:
        if s not in names:
            names[s] = order[len(names)]
        out += RANKS[r] + names[s]
    return out


def kmedoids(D, w, m):
    """Weighted k-medoids: greedy build, then swap passes until no gain."""
    n = len(w)
    meds = []
    near = np.full(n, np.inf)
    for _ in range(m):
        cost = (w[:, None] * np.minimum(near[:, None], D)).sum(0)
        cost[meds] = np.inf
        c = int(np.argmin(cost))
        meds.append(c)
        near = np.minimum(near, D[:, c])
    for _ in range(20):
        changed = False
        for mi in range(m):
            others = [x for j, x in enumerate(meds) if j != mi]
            base = D[:, others].min(1) if others else np.full(n, np.inf)
            cost = (w[:, None] * np.minimum(base[:, None], D)).sum(0)
            cost[others] = np.inf
            c = int(np.argmin(cost))
            cur = (w * np.minimum(base, D[:, meds[mi]])).sum()
            if cost[c] < cur - 1e-9 and c != meds[mi]:
                meds[mi] = c
                changed = True
        if not changed:
            break
    return meds


def margins(keys):
    """Indicator matrix (constraints x flops): stratum, highest card
    (A, K, Q, J, T, 9, 8, 7, 6 or lower), and, for each rank, whether it
    appears on the flop."""
    names = sorted({stratum(k) for k in keys})
    rows = []
    for s in names:
        rows.append([1.0 if stratum(k) == s else 0.0 for k in keys])
    for r in range(12, 3, -1):
        rows.append([1.0 if max(x for x, _ in k) == r else 0.0 for k in keys])
    rows.append([1.0 if max(x for x, _ in k) <= 4 else 0.0 for k in keys])
    for r in range(13):
        rows.append([1.0 if any(x == r for x, _ in k) else 0.0 for k in keys])
    return np.array(rows)


def calibrate(w0, X, target, lo=0.25, hi=4.0, iters=200):
    """Bounded linear calibration (Deville & Sarndal 1992, truncated linear
    distance): weights w = w0 * clip(1 + X'lam, lo, hi) with lam solved so
    X w = target. The bounds keep every flop within [lo, hi] x its medoid
    weight. Returns weights (normalised) and the largest margin error."""
    lam = np.zeros(X.shape[0])
    for _ in range(iters):
        g = 1 + X.T @ lam
        gc = np.clip(g, lo, hi)
        w = w0 * gc
        F = X @ w - target
        if np.abs(F).max() < 1e-12:
            break
        free = ((g > lo) & (g < hi)).astype(float)
        J = (X * (w0 * free)) @ X.T
        step = np.linalg.lstsq(J, F, rcond=1e-10)[0]
        lam = lam - step
    w = w0 * np.clip(1 + X.T @ lam, lo, hi)
    return w / w.sum(), float(np.abs(X @ (w / w.sum()) - target).max())


def build(K):
    counts = {}
    deck = [(r, s) for r in range(13) for s in range(4)]
    for c in itertools.combinations(deck, 3):
        k = canon(list(c))
        counts[k] = counts.get(k, 0) + 1
    assert len(counts) == 1755, len(counts)
    total = sum(counts.values())
    strata = {}
    for k in counts:
        strata.setdefault(stratum(k), []).append(k)
    sw = {s: sum(counts[k] for k in ks) for s, ks in strata.items()}
    alloc = {s: max(1, int(K * w / total)) for s, w in sw.items()}
    rem = sorted(sw, key=lambda s: -(K * sw[s] / total - int(K * sw[s] / total)))
    i = 0
    while sum(alloc.values()) < K:
        alloc[rem[i % len(rem)]] += 1
        i += 1
    while sum(alloc.values()) > K:
        s = max(alloc, key=lambda s: alloc[s] - K * sw[s] / total)
        alloc[s] -= 1
    reps, w0, strat = [], [], []
    for s, ks in sorted(strata.items()):
        ks = sorted(ks)
        D = dist_matrix(ks)
        w = np.array([counts[k] for k in ks], float)
        meds = kmedoids(D, w, alloc[s])
        near = np.argmin(D[:, meds], 1)
        for j, mi in enumerate(meds):
            reps.append(ks[mi])
            w0.append(w[near == j].sum() / total)
            strat.append(s)
    # population margins
    allk = list(counts)
    Xall = margins(allk)
    pw = np.array([counts[k] for k in allk], float) / total
    target = Xall @ pw
    X = margins(reps)
    w0 = np.array(w0)
    w, err = calibrate(w0, X, target)
    out = [{"flop": to_str(k), "weight": float(wi), "stratum": s, "medoidWeight": float(m)}
           for k, wi, s, m in zip(reps, w, strat, w0)]
    out.sort(key=lambda d: -d["weight"])
    return out, err


def main():
    K = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    out, err = build(K)
    print(f"calibration: max margin error {err:.2e}; weight range "
          f"{min(d['weight'] for d in out):.4f}-{max(d['weight'] for d in out):.4f}", file=sys.stderr)
    json.dump(out, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
