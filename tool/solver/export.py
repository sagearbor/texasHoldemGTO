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
           "chart; a 5-bet is all-in.")


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
    prev = (fixed_point or {}).get("prevGames")
    for sid, sp in spots.items():
        sp["note"] = NOTE_LIMP if sid.startswith("cash-limp") else NOTE_3B
        if prev and sp["game"] in prev:
            # share of the hero's hands (combo- and reach-weighted) whose
            # strategy moved between the last two fixed-point rounds
            g, gp = games[sp["game"]], prev[sp["game"]]
            a, b = g._avg(g.hero), gp._avg(gp.hero)
            reach = np.array([x or 0 for x in (sp["reach"] or [1.0] * 169)])
            w = np.array([rg.class_combos(k) for k in range(169)]) * reach
            tv = 0.5 * np.abs(a - b).sum(0)
            sp["fixedPointDelta"] = _r(float((w * tv).sum() / w.sum()), 4)
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
                        rounds=[dict(round=r["round"],
                                     meanAbsDeltaR={k: _r(v, 4) for k, v in r["meanAbsDeltaR"].items()},
                                     rangeDrift={k: _r(v, 4) for k, v in r["rangeDrift"].items()})
                                for r in (fixed_point or {}).get("rounds", [])]),
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
    readme(out_dir, pre, post, stats, cfg, drift, fixed_point)


TITLES = {
    "cash-limp1-BB": "BB vs UTG limp: raise 5bb / check",
    "cash-limp1-CO": "CO vs UTG limp: iso 4bb / overlimp / fold",
    "cash-limp1-BTN": "BTN vs UTG limp: iso 4bb / overlimp / fold",
    "cash-limp1-SB": "SB vs UTG limp: iso 5bb / complete / fold",
    "cash-3b-UTG-ip": "UTG open, BTN 3-bets 7.5bb",
    "cash-3b-UTG-blinds": "UTG open, BB 3-bets 10bb",
    "cash-3b-CO-BTN": "CO open, BTN 3-bets 7.5bb",
    "cash-3b-CO-blinds": "CO open, BB 3-bets 10bb",
    "cash-3b-BTN-SB": "BTN open, SB 3-bets 10bb",
    "cash-3b-BTN-BB": "BTN open, BB 3-bets 10bb",
    "cash-3b-SB-BB": "SB open 3bb, BB 3-bets 9bb",
}


HERE = os.path.dirname(os.path.abspath(__file__))


def _text(path):
    """Hand-written notes about a run (benchmark context, the cross-check)."""
    return open(path).read().strip() if os.path.exists(path) else ""


def _size(path):
    n = os.path.getsize(path)
    return f"{n / 1024:.0f} KB"


def readme(out_dir, pre, post, stats, cfg, drift, fixed_point):
    tpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "README.template.md")).read()
    rows = ["| Spot | id | Hero plays | Nash gap (bb/hand) | Flop expl. (% pot) | Passed |",
            "|---|---|---|---|---|---|"]
    for sid, sp in pre["spots"].items():
        strat = sp["strategy"]
        acts = sp["actions"]
        pas = acts.index("Fold") if "Fold" in acts else acts.index("Check")
        reach = sp["reach"] or [1.0] * 169
        w = [rg.class_combos(k) * (reach[k] or 0) for k in range(169)]
        tot = sum(w)
        parts = []
        for a, lab in enumerate(acts):
            share = sum(w[k] * strat[k][a] for k in range(169)) / tot
            parts.append(f"{lab} {share * 100:.0f}%")
        rows.append(f"| {TITLES.get(sid, sid)} | `{sid}` | {', '.join(parts)} | "
                    f"{sp['exploitabilityBb']:.6f} | {sp['maxFlopExploitPctPot']} | "
                    f"{'yes' if sp['passed'] else '**no**'} |")
    gates = ["| Spot | Failed gates |", "|---|---|"]
    for sid, sp in pre["spots"].items():
        bad = [f"{g['gate']} ({g['detail']})" for g in sp["gates"] if not g["ok"]]
        gates.append(f"| `{sid}` | {'; '.join(bad) if bad else 'none'} |")
    bench = post.get("benchmarks") or []
    if bench:
        b = ["| Flop | Check | Bet 33% | Bet 75% | Flop expl. (% pot) | Iterations |", "|---|---|---|---|---|---|"]
        for x in bench:
            fr = x["freq"]
            b.append(f"| {x['flop']} | {fr.get('X', 0) * 100:.0f}% | {fr.get('B33', 0) * 100:.0f}% | "
                     f"{fr.get('B75', 0) * 100:.0f}% | {x['exploitPctPot']:.2f} | {x['iters']} |")
        bench_txt = ("BTN (in position) after the BB checks, single-raised pot, ranges from "
                     "the solved BTN-vs-BB 3-bet game:\n\n" + "\n".join(b) + "\n\n" +
                     _text(os.environ.get("BENCH_NOTE_MD", os.path.join(HERE, "bench_note.md"))))
    else:
        bench_txt = "Not run."
    cc = os.environ.get("CROSSCHECK_MD", os.path.join(HERE, "crosscheck.md"))
    cross = open(cc).read().strip() if cc and os.path.exists(cc) else "Not run."
    flops = post["flopSubset"]
    ft = ["| Flop | Stratum | Weight |", "|---|---|---|"] + [
        f"| {f['flop']} | {f['stratum']} | {f['weight'] * 100:.1f}% |" for f in flops]
    secs = sum(s["seconds"] for s in stats.values())
    fp = ""
    if drift:
        fp += (f"Moving from the prior to the solved tables moved the flop ranges a lot "
               f"(median share of combos that changed at a flop leaf: "
               f"{float(np.median(list(drift.values()))):.2f}).")
    rounds = (fixed_point or {}).get("rounds", [])
    if rounds:
        fp += ("\n\n   Further rounds re-solve every pot type on the "
               f"{os.environ.get('FP_FLOPS', '3')} heaviest flops of the subset with the "
               "current ranges and correct the full tables by the change seen there "
               "(R = R_full + R_sub(now) - R_sub(round 0)), damped 50/50 with the "
               "previous round:\n\n   | Round | Largest mean change in R | Median range drift | Largest range drift |\n"
               "   |---|---|---|---|\n")
        for r in rounds:
            d = list(r["rangeDrift"].values())
            fp += (f"   | {r['round']} | {max(r['meanAbsDeltaR'].values()):.3f} | "
                   f"{float(np.median(d)):.3f} | {max(d):.3f} |\n")
        fp += ("\n   Range drift = share of a flop leaf's combos that changed between "
               "consecutive rounds. The published spots are the last round.")
    fill = {
        "generated": pre["generated"],
        "compute": os.environ.get("TOTAL_COMPUTE", f"{secs / 3600:.1f} h of flop solving"),
        "hours": os.environ.get("TOTAL_HOURS", f"{max(1, round(secs / 3600 + 0.5))}"),
        "size_pre": _size(os.path.join(out_dir, "preflop.json")),
        "size_post": _size(os.path.join(out_dir, "postflop.json")),
        "spot_table": "\n".join(rows),
        "gate_table": "\n".join(gates),
        "bench": bench_txt,
        "crosscheck": cross,
        "post_iters": str(cfg["POST_ITERS"]),
        "post_target": str(cfg["POST_TARGET"]),
        "fixed_point": fp,
        "flop_table": "\n".join(ft),
        "limp": cfg["LIMP"],
        "n_flops": str(len(flops)),
    }
    for k, v in fill.items():
        tpl = tpl.replace("{{" + k + "}}", v)
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write(tpl)
