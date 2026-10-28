"""Representative flop subset, weighted to the 1,755 strategically distinct
(suit-isomorphic) flops.

Every one of the 22,100 flops is mapped to its suit-isomorphism class (1,755
classes). Classes are split into 11 strata by structure (see stratum()), one
representative each: the weighted medoid of the stratum over rank features
(high, middle, low card, gaps; which two cards share a suit on two-tone
flops). Every class is assigned to its nearest
representative in its stratum, so each representative's weight is the share
of all 22,100 flops it stands for; weights sum to 1.

Usage: python3 flops.py  -> JSON list of {"flop": "As7d2c", "weight": w}
"""
import itertools
import json
import sys

RANKS = "23456789TJQKA"
SUITS = "cdhs"


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


def dist(a, b):
    fa, fb = features(a), features(b)
    w = (1.5, 0.8, 0.6, 0.5, 0.5, 4.0)
    d = sum(wi * abs(x - y) for wi, x, y in zip(w, fa, fb))
    if suited_pair(a) != suited_pair(b):
        d += 1.5
    return d


def to_str(key):
    # assign concrete suits: canonical suit labels 0..3 -> s, h, d, c order of appearance
    out = ""
    names = {}
    order = "shdc"
    for r, s in key:
        if s not in names:
            names[s] = order[len(names)]
        out += RANKS[r] + names[s]
    return out


def main():
    K = 11  # one representative per stratum
    counts = {}
    deck = [(r, s) for r in range(13) for s in range(4)]
    for c in itertools.combinations(deck, 3):
        k = canon(list(c))
        counts[k] = counts.get(k, 0) + 1
    assert len(counts) == 1755, len(counts)
    total = sum(counts.values())
    strata = {}
    for k, n in counts.items():
        strata.setdefault(stratum(k), []).append(k)
    sw = {s: sum(counts[k] for k in ks) for s, ks in strata.items()}
    # largest remainder allocation, min 1
    alloc = {s: max(1, int(K * w / total)) for s, w in sw.items()}
    rem = sorted(sw, key=lambda s: -(K * sw[s] / total - int(K * sw[s] / total)))
    i = 0
    while sum(alloc.values()) < K:
        alloc[rem[i % len(rem)]] += 1
        i += 1
    while sum(alloc.values()) > K:
        s = max(alloc, key=lambda s: alloc[s] - K * sw[s] / total)
        alloc[s] -= 1
    out = []
    for s, ks in sorted(strata.items()):
        m = alloc[s]
        # greedy weighted k-medoids init + a few swap passes
        meds = []
        for _ in range(m):
            best, bc = None, None
            for c in ks:
                if c in meds:
                    continue
                cost = sum(counts[k] * min([dist(k, x) for x in meds + [c]]) for k in ks)
                if bc is None or cost < bc:
                    best, bc = c, cost
            meds.append(best)
        for _ in range(3):
            changed = False
            for mi in range(len(meds)):
                cur = sum(counts[k] * min(dist(k, x) for x in meds) for k in ks)
                for c in ks:
                    if c in meds:
                        continue
                    trial = meds[:mi] + [c] + meds[mi + 1:]
                    cost = sum(counts[k] * min(dist(k, x) for x in trial) for k in ks)
                    if cost < cur - 1e-9:
                        meds, cur, changed = trial, cost, True
            if not changed:
                break
        w = {x: 0 for x in meds}
        for k in ks:
            near = min(meds, key=lambda x: (dist(k, x), x))
            w[near] += counts[k]
        for x in meds:
            out.append({"flop": to_str(x), "weight": w[x] / total, "stratum": s})
    out.sort(key=lambda d: -d["weight"])
    json.dump(out, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
