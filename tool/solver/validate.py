"""Validation gates for the solved preflop spots. A spot that fails any gate
is published with passed = false and the app keeps its old chart.
The same gates are re-checked on the shipped file by
test/solved_data_test.dart."""
import ranges as rg

IDX = {rg.class_name(k): k for k in range(169)}
TRASH = ["72o", "82o", "92o", "32o", "42o", "83o", "T2o", "J3o"]
CONNECTORS = ["54s", "65s", "76s", "87s", "98s", "T9s", "75s", "86s", "97s"]
MAX_EXPL_BB = 0.001  # bb per hand, preflop Nash gap within the model


def _f(spot, name, a):
    return spot["strategy"][IDX[name]][a]


def gates(sid, spot, all_spots):
    """List of (gate, ok, detail)."""
    out = []
    acts = spot["actions"]
    passive = acts.index("Fold") if "Fold" in acts else acts.index("Check")
    reach = spot.get("reach")
    for h in ["AA", "KK"]:
        if reach is not None and (reach[IDX[h]] or 0) <= 0:
            continue
        f = _f(spot, h, passive)
        if "Fold" in acts:
            out.append((f"{h} never folds", f <= 0.001, f"fold {f:.3f}"))
        else:
            out.append((f"{h} raises", _f(spot, h, 0) >= 0.999, f"raise {_f(spot, h, 0):.3f}"))
    e = spot["exploitabilityBb"]
    out.append(("preflop Nash gap < 0.001bb", e is not None and e < MAX_EXPL_BB, f"{e}"))
    if sid.startswith("cash-limp"):
        worst = max(_f(spot, h, 0) for h in TRASH)
        out.append(("trash never iso-raises", worst <= 0.01, f"max raise {worst:.3f}"))
        if "SB" in sid:
            c86 = _f(spot, "86s", 1)
            mixed = [h for h in CONNECTORS if max(spot["strategy"][IDX[h]]) <= 0.9]
            out.append(("SB: 86s not 100% complete", c86 < 0.99, f"86s complete {c86:.3f}"))
            out.append(("SB: suited connectors mix", len(mixed) >= 2, f"mixed: {mixed}"))
        if sid in ("cash-limp1-BTN",) and "cash-limp1-CO" in all_spots:
            co = all_spots["cash-limp1-CO"]

            def play(sp):
                return sum(rg.class_combos(k) * (1 - sp["strategy"][k][2]) for k in range(169)) / 1326

            def iso(sp):
                return sum(rg.class_combos(k) * sp["strategy"][k][0] for k in range(169)) / 1326
            out.append(("BTN plays at least as wide as CO vs a limper",
                        play(spot) >= play(co) - 0.005, f"BTN {play(spot):.3f} CO {play(co):.3f}"))
            out.append(("BTN iso range at least as wide as CO",
                        iso(spot) >= iso(co) - 0.005, f"BTN {iso(spot):.3f} CO {iso(co):.3f}"))
    if sid.startswith("cash-3b"):
        four = _f(spot, "AA", 0) + _f(spot, "KK", 0)
        out.append(("AA/KK mostly 4-bet", four >= 1.0, f"AA+KK 4-bet {four:.2f}"))
    return out


def run(spots):
    for sid, sp in spots.items():
        g = gates(sid, sp, spots)
        sp["gates"] = [dict(gate=a, ok=bool(b), detail=c) for a, b, c in g]
        sp["passed"] = all(b for _, b, _ in g)
    return spots
