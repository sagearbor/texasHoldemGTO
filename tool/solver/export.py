"""Writes the published dataset (data/solved/*.json) from a finished run."""
import json
import os
import time

import numpy as np

import ranges as rg
import validate


def _r(x, d=3):
    if x is None or not np.isfinite(x):
        return None
    v = round(float(x), d)
    return 0.0 if v == 0 else v


def _rows(mat, d=3):
    """mat: (A, 169) -> 169 rows of A values; rows renormalised after rounding."""
    out = []
    for k in range(169):
        row = [max(0.0, round(float(mat[a, k]), d)) for a in range(mat.shape[0])]
        s = sum(row)
        if s <= 0:
            row = [round(1.0 / len(row), d)] * len(row)
            s = sum(row)
        # push rounding residue onto the largest entry so rows sum to 1
        i = int(np.argmax(row))
        row[i] = round(row[i] + (1.0 - s), d)
        out.append(row)
    return out


def _nodes(g):
    out = {}
    for n in g.nodes:
        r0, r1 = g.reach_at(n)
        reach = r0 if n.player == 0 else r1
        out[n.name] = dict(player=n.player, actions=n.actions,
                           strategy=_rows(g._avg(n)),
                           reach=[_r(x) for x in reach])
    return out


NOTE_LIMP = ("Model: UTG limps an assumed loose-passive range; players behind "
             "fold to an iso-raise; after an overlimp or complete the BB checks "
             "and the 3-way pot is valued with a realisation model.")
NOTE_3B = ("Model: everyone else folds; the opening range is the approximate "
           "chart; called 4-bets are valued at all-in equity.")


def write(out_dir, games, Rt, aggs, stats, flops, bench, drift, fixed_point, tab, cfg):
    os.makedirs(out_dir, exist_ok=True)
    spots = {}
    post_expl = {pt: max(s["exploitPctPot"]) for pt, s in stats.items()}
    for gid, g in games.items():
        hero = g.hero
        evs = g.action_evs(hero)
        if gid.startswith("3b-"):
            sid = "cash-" + gid
            reach = [_r(x) for x in g.reach0]
            seats = None
        else:
            sid = "cash-" + gid
            reach = None
        leaves = sorted({t.info["potType"] for t in g.terms if t.info.get("potType")})
        spots[sid] = dict(
            game=gid,
            actions=hero.actions,
            strategy=_rows(g._avg(hero)),
            ev=[[_r(evs[a, k], 3) for a in range(len(hero.actions))] for k in range(169)],
            reach=reach,
            exploitabilityBb=_r(g.expl, 6),
            iterations=g.iters,
            flopLeaves=leaves,
            maxFlopExploitPctPot=_r(max([post_expl[p] for p in leaves if p in post_expl] or [float("nan")]), 3),
            nodes=_nodes(g),
        )
    for sid, sp in spots.items():
        sp["note"] = NOTE_LIMP if sid.startswith("cash-limp") else NOTE_3B
    validate.run(spots)
    pre = dict(
        name="Felt Notes solved preflop spots",
        license="CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)",
        attribution="Felt Notes (https://github.com/sagearbor/texasHoldemGTO)",
        generated=time.strftime("%Y-%m-%d"),
        format=("strategy[class][action] = frequency; ev[class][action] = bb won "
                "relative to the start of the hand; class index = row * 13 + col on the "
                "13x13 grid (row/col 0 = ace, suited above the diagonal)"),
        classes=[rg.class_name(k) for k in range(169)],
        inputs=dict(rfi=cfg["RFI"], limp=cfg["LIMP"]),
        spots=spots,
        fixedPoint=dict(rangeDriftRound0to1={k: _r(v, 4) for k, v in (drift or {}).items()},
                        realisationDriftPost1to2={k: _r(v, 4) for k, v in (fixed_point or {}).items()}),
    )
    with open(os.path.join(out_dir, "preflop.json"), "w") as f:
        json.dump(pre, f, separators=(",", ":"))
    pots = {}
    for pt, agg in aggs.items():
        P = cfg["POT_TYPES"][pt]
        side = {}
        for p in (0, 1):
            a = agg[p]
            tot = float(np.nansum(a["mass"]))
            side[str(p)] = dict(
                position="OOP" if p == P["oop"] else "IP",
                ev=[_r(x, 3) for x in a["ev"]],
                equity=[_r(x, 4) for x in a["eq"]],
                realisation=[_r(x, 3) for x in a["R"]],
                realisationUsed=[_r(x, 3) for x in Rt[pt][p]],
                share=[_r(x / tot if tot > 0 else 0, 5) for x in a["mass"]],
            )
        s = stats[pt]
        pots[pt] = dict(pot=P["pot"], stack=P["stack"], oopPlayer=P["oop"],
                        aggressor=P["aggr"], bets=P["bets"],
                        flops=[f["flop"] for f in flops],
                        exploitPctPot=[_r(x, 3) for x in s["exploitPctPot"]],
                        iterations=s["iters"], seconds=_r(s["seconds"], 0),
                        players=side)
    post = dict(
        name="Felt Notes solved flop EV tables",
        license="CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)",
        attribution="Felt Notes (https://github.com/sagearbor/texasHoldemGTO)",
        generated=time.strftime("%Y-%m-%d"),
        format=("players['0'|'1'] = preflop player 0 / 1 of the game that reaches "
                "the pot (see preflop.json nodes); ev = bb won from the flop pot net "
                "of own postflop bets, averaged over the weighted flop subset; "
                "realisation = ev / (equity x pot)"),
        flopSubset=flops,
        potTypes=pots,
        benchmarks=bench,
        settings=dict(postIters=cfg["POST_ITERS"], postTargetPctPot=cfg["POST_TARGET"],
                      benchIters=cfg["BENCH_ITERS"]),
    )
    with open(os.path.join(out_dir, "postflop.json"), "w") as f:
        json.dump(post, f, separators=(",", ":"))
