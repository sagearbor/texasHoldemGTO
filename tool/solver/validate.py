"""Validation gates for the solved preflop spots. A spot that fails any gate
is published with passed = false and the app keeps its old chart.
The same gates are re-checked on the shipped file by
test/solved_data_test.dart. (Independently, main's acceptance.py must also
pass for a spot to reach the app.)"""
import ranges as rg

IDX = {rg.class_name(k): k for k in range(169)}
TRASH = ["72o", "82o", "92o", "32o", "42o", "83o", "T2o", "J3o"]
CONNECTORS = ["54s", "65s", "76s", "87s", "98s", "T9s", "75s", "86s", "97s"]
MAX_EXPL_BB = 0.001  # bb per hand, preflop Nash gap within the model
MAX_FP_DELTA = 0.05  # share of hero's hands whose strategy moves
DOM_TOL = 0.05  # bb
_R = "AKQJT98765432"
# Each hand is worth at least as much as the next (its best action's EV).
CHAINS = [[r + r for r in _R],
          ["AKs", "AQs", "AJs", "ATs", "A9s"], ["AKo", "AQo", "AJo", "ATo", "A9o"],
          ["KQs", "KJs", "KTs", "K9s"], ["KQo", "KJo", "KTo", "K9o"],
          ["QJs", "QTs", "Q9s"], ["QJo", "QTo", "Q9o"], ["JTs", "J9s"], ["JTo", "J9o"]]
CHAINS += [[a + b + "s", a + b + "o"] for i, a in enumerate(_R) for b in _R[i + 1:]]
BEHIND = {"CO": ["BTN", "SB", "BB"], "BTN": ["SB", "BB"], "SB": ["BB"]}


def _f(spot, name, a):
    return spot["strategy"][IDX[name]][a]


def gates(sid, spot, all_spots):
    """List of (gate, ok, detail)."""
    out = []
    acts = spot["actions"]
    passive = acts.index("Fold") if "Fold" in acts else acts.index("Check")
    reach = spot.get("reach")

    def inrange(h):
        return reach is None or (reach[IDX[h]] or 0) > 0

    for h in ["AA", "KK"]:
        if not inrange(h):
            continue
        f = _f(spot, h, passive)
        if "Fold" in acts:
            out.append((f"{h} never folds", f <= 0.001, f"fold {f:.3f}"))
        else:
            out.append((f"{h} raises", _f(spot, h, 0) >= 0.999, f"raise {_f(spot, h, 0):.3f}"))
    e = spot["exploitabilityBb"]
    out.append(("preflop Nash gap < 0.001bb", e is not None and e < MAX_EXPL_BB, f"{e}"))
    d = spot.get("fixedPointDelta")
    out.append((f"fixed point: under {MAX_FP_DELTA:.0%} of hero's hands move between the last two rounds",
                d is not None and d <= MAX_FP_DELTA, f"{d}"))
    fx = spot.get("maxFlopExploitPctPot")
    out.append(("every flop solve feeding the spot < 1% of the pot exploitable",
                fx is not None and fx < 1.0, f"{fx}"))
    ev = spot.get("ev")
    if ev is not None:
        # A bigger pair dominates a smaller one, so its EV for the aggressive
        # action can't be clearly lower; a big inversion is model noise.
        pairs = [r * 2 for r in reversed(rg.RANKS)]  # AA first
        worst, at = 0.0, ""
        for hi, lo in zip(pairs, pairs[1:]):
            a, b = ev[IDX[hi]][0], ev[IDX[lo]][0]
            if a is not None and b is not None and b - a > worst:
                worst, at = b - a, f"{lo} {b:+.3f} vs {hi} {a:+.3f}"
        out.append(("pairs: aggressive EV never drops more than 0.1bb with a bigger pair",
                    worst <= 0.1, at or "monotone"))

        def val(h):
            x = [y for y in ev[IDX[h]] if y is not None]
            return max(x) if x else None

        bad = []
        for chain in CHAINS:
            for hi, lo in zip(chain, chain[1:]):
                if not (inrange(hi) and inrange(lo)):
                    continue
                a, b = val(hi), val(lo)
                if a is not None and b is not None and b - a > DOM_TOL:
                    bad.append(f"{lo} {b:+.3f} > {hi} {a:+.3f}")
        out.append(("dominance: a bigger pair / better kicker / suited hand is never worth 0.05bb less",
                    not bad, "; ".join(bad[:4]) or "monotone"))
    if sid.startswith("cash-limp"):
        worst = max(_f(spot, h, 0) for h in TRASH)
        out.append(("trash never iso-raises", worst <= 0.01, f"max raise {worst:.3f}"))
        hero = sid.rsplit("-", 1)[-1]
        if hero != "BB":
            # Every seat behind the hero must be a solved player with a raise
            # over the hero's limp / complete and a 3-bet over its iso (v1
            # folded them, which overrated overlimping).
            sb = spot.get("seatsBehind") or []
            have = {x["seat"]: x for x in sb}
            miss = []
            for seat in BEHIND[hero]:
                x = have.get(seat)
                if not x or "vsLimps" not in x or "Raise" not in x["vsLimps"]["actions"]:
                    miss.append(f"{seat} raise over the limp")
                if not x or "vsIso" not in x or "3-bet" not in x["vsIso"]["actions"]:
                    miss.append(f"{seat} 3-bet over the iso")
            det = "; ".join(f"{x['seat']} raises {x['vsLimps']['freq'].get('Raise')}, 3-bets "
                            f"{x['vsIso']['freq'].get('3-bet')}" for x in sb if "vsLimps" in x and "vsIso" in x)
            out.append(("every seat behind the hero is solved (raises a limp, 3-bets an iso)",
                        not miss, ("missing: " + ", ".join(miss)) if miss else det))
            bg = spot.get("borrowGateDelta")
            out.append((f"borrowed flop tables: under {MAX_FP_DELTA:.0%} of hero's hands move with the alternative donors",
                        bg is not None and bg <= MAX_FP_DELTA, f"{bg}"))
            ng = spot.get("nashGapByPlayer") or []
            out.append(("multiway: every player's best-response gain < 0.001bb",
                        bool(ng) and all(x is not None and x < MAX_EXPL_BB for x in ng), f"{ng}"))
        if hero in ("CO", "BTN"):
            junk = ["K2o", "K3o", "Q2o", "Q3o", "Q4o", "J2o", "J3o", "J4o", "T2o", "T3o", "T4o",
                    "92o", "93o", "94o", "82o", "83o", "84o", "72o", "73o", "62o", "52o", "42o", "32o"]
            leak = [f"{h} {1 - _f(spot, h, 2):.2f}" for h in junk if _f(spot, h, 2) < 0.95]
            out.append(("CO/BTN fold offsuit junk to a limper (95%+)", not leak, ", ".join(leak[:6]) or "ok"))
        if hero == "SB":
            c86 = _f(spot, "86s", 1)
            mixed = [h for h in CONNECTORS if max(spot["strategy"][IDX[h]]) <= 0.9]
            out.append(("SB: 86s not 100% complete", c86 < 0.99, f"86s complete {c86:.3f}"))
            out.append(("SB: suited connectors mix", len(mixed) >= 2, f"mixed: {mixed}"))
        if sid == "cash-limp1-CO" and "cash-limp1-BTN" in all_spots:
            co, btn = all_spots["cash-limp1-CO"], all_spots["cash-limp1-BTN"]

            def play(sp):
                return sum(rg.class_combos(k) * (1 - sp["strategy"][k][2]) for k in range(169)) / 1326

            def iso(sp):
                return sum(rg.class_combos(k) * sp["strategy"][k][0] for k in range(169)) / 1326
            out.append(("CO plays tighter than BTN vs a limper (players behind)",
                        play(co) < play(btn) - 0.005, f"CO {play(co):.3f} BTN {play(btn):.3f}"))
            out.append(("CO iso range no wider than BTN",
                        iso(co) <= iso(btn) + 0.002, f"CO {iso(co):.3f} BTN {iso(btn):.3f}"))
    if sid.startswith("cash-3b"):
        four = _f(spot, "AA", 0) + _f(spot, "KK", 0)
        out.append(("AA/KK mostly 4-bet", four >= 1.0, f"AA+KK 4-bet {four:.2f}"))
        for h in ["QQ", "AKs"]:
            f = _f(spot, h, passive)
            out.append((f"{h} never folds to a 3-bet", f <= 0.01, f"fold {f:.3f}"))
    return out


def run(spots):
    for sid, sp in spots.items():
        g = gates(sid, sp, spots)
        sp["gates"] = [dict(gate=a, ok=bool(b), detail=c) for a, b, c in g]
        sp["passed"] = all(b for _, b, _ in g)
    return spots
