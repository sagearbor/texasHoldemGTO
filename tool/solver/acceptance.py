"""Acceptance checks for data/solved: the gate between the solver and the app.

Owned by the main branch, not by the solver pipeline. The pipeline may add its
own gates (validate.py), but a spot only reaches the app when it ALSO passes
every check here, run from main's copy of this file at merge time:

    python3 tool/solver/acceptance.py            # report, exit 1 if any spot fails
    python3 tool/solver/acceptance.py --write    # also set spots[*].accepted

The checks are poker facts and convergence tests, not desired answers: a
bigger pair is worth at least as much as a smaller one, suited beats the same
offsuit hand, a converged strategy only plays actions that are (close to)
best, and so on. They never say "hand X must do Y" except where every solver
agrees (AA never folds, 72o never iso-raises a limper).

Stdlib only. EVs are bb per hand; tolerances are in bb.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "..", "data", "solved")

# --- thresholds (change only on main, with a reason in the commit message) ---
MIN_FLOPS = 40            # flops per pot type: v1 used 11 and its EVs were noise
MAX_FLOP_EXPL_PCT = 1.0   # worst flop solve, % of the pot
MAX_NASH_GAP_BB = 0.001   # preflop exploitability within the model
MAX_FP_DELTA = 0.05       # share of hero's hands that moved in the last round
DOMINANCE_TOL = 0.05      # bb a dominating hand may trail by (rounding/noise)
BR_TOL = 0.05             # bb: a strategy's main action must be this close to best
BR_DEAD = 0.15            # bb: an action this much worse than best...
BR_DEAD_FREQ = 0.05       # ...may be played at most this often

RANKS = "AKQJT98765432"
TRASH = ["72o", "82o", "92o", "32o", "42o", "83o", "T2o", "J3o"]
# Offsuit junk the CO/BTN fold to a single limper with players behind (no
# overlimp, no iso). v1's BTN overlimped K3o and Q5o.
WEAK_OFFSUIT = ["K2o", "K3o", "K4o", "Q2o", "Q3o", "Q4o", "Q5o", "J2o", "J3o",
                "J4o", "J5o", "T2o", "T3o", "T4o", "T5o", "92o", "93o", "94o",
                "95o", "82o", "83o", "84o", "85o", "72o", "73o", "74o", "62o",
                "63o", "52o", "42o", "32o"]
# Dominance chains: each hand is worth at least as much as the next.
CHAINS = [
    ["AKs", "AQs", "AJs", "ATs"], ["AKo", "AQo", "AJo", "ATo"],
    ["KQs", "KJs", "KTs"], ["KQo", "KJo", "KTo"], ["QJs", "QTs"], ["QJo", "QTo"],
    [r + r for r in RANKS],
]


def _idx(classes):
    return {n: i for i, n in enumerate(classes)}


def _in_range(spot, k):
    reach = spot.get("reach")
    return reach is None or (reach[k] or 0) > 0


def _value(spot, k):
    """The hand's EV in the spot: its best action's EV (None if unknown)."""
    evs = [e for e in spot["ev"][k] if e is not None]
    return max(evs) if evs else None


def _fold(spot):
    acts = spot["actions"]
    return acts.index("Fold") if "Fold" in acts else None


def check_spot(sid, spot, I):
    """List of (check, ok, detail)."""
    out = []
    acts, strat, ev = spot["actions"], spot["strategy"], spot["ev"]
    fold = _fold(spot)
    names = list(I)

    # 1. well-formed
    bad = [names[k] for k in range(169) if abs(sum(strat[k]) - 1) > 0.01]
    out.append(("rows are probability distributions", not bad, ",".join(bad[:5]) or "ok"))

    # 2. convergence
    e = spot.get("exploitabilityBb")
    out.append(("preflop Nash gap < %gbb" % MAX_NASH_GAP_BB, e is not None and e < MAX_NASH_GAP_BB, str(e)))
    d = spot.get("fixedPointDelta")
    out.append(("fixed point settled (<= %d%% of hands moved)" % (MAX_FP_DELTA * 100),
                d is not None and d <= MAX_FP_DELTA, str(d)))
    fx = spot.get("maxFlopExploitPctPot")
    out.append(("every flop solve < %g%% of pot exploitable" % MAX_FLOP_EXPL_PCT,
                fx is not None and fx < MAX_FLOP_EXPL_PCT, str(fx)))

    # 3. strategy agrees with its own EVs (a converged equilibrium is a best
    # response to itself): the main action is ~best, clearly-worse actions rare
    viol = []
    for k in range(169):
        if not _in_range(spot, k) or any(x is None for x in ev[k]):
            continue
        best = max(ev[k])
        for a in range(len(acts)):
            gap = best - ev[k][a]
            if strat[k][a] >= 0.9 and gap > BR_TOL:
                viol.append(f"{names[k]} plays {acts[a]} {strat[k][a]:.2f} at -{gap:.2f}bb")
            elif gap > BR_DEAD and strat[k][a] > BR_DEAD_FREQ:
                viol.append(f"{names[k]} {acts[a]} {strat[k][a]:.2f} at -{gap:.2f}bb")
    out.append(("strategy is a best response to its own EVs", not viol, "; ".join(viol[:4]) or "ok"))

    # 4. dominance: bigger pair >= smaller pair, AK >= AQ ..., suited >= offsuit
    viol = []
    for chain in CHAINS:
        for hi, lo in zip(chain, chain[1:]):
            a, b = I[hi], I[lo]
            if not (_in_range(spot, a) and _in_range(spot, b)):
                continue
            va, vb = _value(spot, a), _value(spot, b)
            if va is not None and vb is not None and vb - va > DOMINANCE_TOL:
                viol.append(f"{lo} {vb:+.2f} > {hi} {va:+.2f}")
    for r1 in range(13):
        for r2 in range(r1 + 1, 13):
            s, o = RANKS[r1] + RANKS[r2] + "s", RANKS[r1] + RANKS[r2] + "o"
            a, b = I[s], I[o]
            if not (_in_range(spot, a) and _in_range(spot, b)):
                continue
            va, vb = _value(spot, a), _value(spot, b)
            if va is not None and vb is not None and vb - va > DOMINANCE_TOL:
                viol.append(f"{o} {vb:+.2f} > {s} {va:+.2f}")
    out.append(("dominated hands are never worth more", not viol, "; ".join(viol[:4]) or "ok"))

    # 5. hands every solver agrees on
    for h in ["AA", "KK"]:
        if fold is not None and _in_range(spot, I[h]):
            f = strat[I[h]][fold]
            out.append((f"{h} never folds", f <= 0.001, f"fold {f:.3f}"))
    if sid.startswith("cash-3b"):
        for h in ["QQ", "AKs"]:
            if fold is not None and _in_range(spot, I[h]):
                f = strat[I[h]][fold]
                out.append((f"{h} never folds to a 3-bet", f <= 0.01, f"fold {f:.3f}"))
        four = strat[I["AA"]][0] + strat[I["KK"]][0]
        out.append(("AA+KK mostly 4-bet", four >= 1.0, f"{four:.2f}"))
    if sid.startswith("cash-limp"):
        worst = max(strat[I[h]][0] for h in TRASH)
        out.append(("trash never raises a limper", worst <= 0.01, f"max {worst:.3f}"))
        for h in ["AA", "KK", "QQ", "AKs", "AKo"]:
            r = strat[I[h]][0]
            out.append((f"{h} raises a limper", r >= 0.9, f"raise {r:.2f}"))
        hero = sid.rsplit("-", 1)[-1]
        if hero in ("CO", "BTN", "HJ") and fold is not None:
            leaks = [f"{h} {1 - strat[I[h]][fold]:.2f}" for h in WEAK_OFFSUIT
                     if strat[I[h]][fold] < 0.9]
            out.append(("weak offsuit hands fold to a limper", not leaks, ", ".join(leaks[:6]) or "ok"))
    return out


def check_pairs(spots):
    """Seat ordering: the CO, with the BTN still behind, plays tighter."""
    out = {}
    co, btn = spots.get("cash-limp1-CO"), spots.get("cash-limp1-BTN")
    if co and btn and "Fold" in co["actions"]:
        f = co["actions"].index("Fold")
        play = lambda s: sum(_combos(k) * (1 - s["strategy"][k][f]) for k in range(169)) / 1326
        ok = play(co) < play(btn) - 0.005
        out["cash-limp1-CO"] = [("CO plays tighter than BTN vs a limper", ok,
                                 f"CO {play(co):.3f} BTN {play(btn):.3f}")]
    return out


def _combos(k):
    r, c = divmod(k, 13)
    return 6 if r == c else (4 if c > r else 12)


def check_dataset(post):
    out = []
    for pt, p in (post.get("potTypes") or {}).items():
        n = len(p.get("flops") or [])
        out.append((f"{pt}: at least {MIN_FLOPS} flops", n >= MIN_FLOPS, str(n)))
    return out


def run(write=False):
    pre_path = os.path.join(DATA, "preflop.json")
    pre = json.load(open(pre_path))
    post = json.load(open(os.path.join(DATA, "postflop.json")))
    I = _idx(pre["classes"])
    spots = pre["spots"]
    ds = check_dataset(post)
    ds_ok = all(ok for _, ok, _ in ds)
    pair = check_pairs(spots)
    any_fail = False
    for sid, sp in spots.items():
        res = check_spot(sid, sp, I) + pair.get(sid, [])
        ok = ds_ok and all(o for _, o, _ in res)
        any_fail |= not ok
        print(f"{'PASS' if ok else 'FAIL'} {sid}")
        for name, o, detail in res:
            if not o:
                print(f"    x {name}: {detail}")
        if write:
            sp["accepted"] = ok
            sp["acceptance"] = [dict(check=n, ok=bool(o), detail=d) for n, o, d in res]
    print("dataset:", "ok" if ds_ok else "; ".join(f"{n} ({d})" for n, o, d in ds if not o))
    if write:
        with open(pre_path, "w") as f:
            json.dump(pre, f, separators=(",", ":"))
    return not any_fail


if __name__ == "__main__":
    sys.exit(0 if run("--write" in sys.argv) else 1)
