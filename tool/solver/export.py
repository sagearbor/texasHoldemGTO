"""Writes the published dataset (data/solved/*.json, README.md) from a
finished run."""
import json
import os
import time

import numpy as np

import preflop as pf
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
        i = int(np.argmax(row))
        row[i] = round(row[i] + (1.0 - s), d)
        out.append(row)
    return out


def _seat_names(gid, g):
    if isinstance(g, pf.Game):
        return None
    return list(g.seats)


def _node_reach(g, n):
    if isinstance(g, pf.Game):
        r0, r1 = g.reach_at(n)
        return r0 if n.player == 0 else r1
    r = g.reach_at(n)
    return g.prior_range[n.player] * r[n.player]


def _nodes(gid, g):
    seats = _seat_names(gid, g)
    out = {}
    for n in g.nodes:
        reach = _node_reach(g, n)
        d = dict(player=n.player, actions=n.actions, strategy=_rows(g._avg(n)),
                 reach=[_r(x) for x in reach])
        if seats:
            d["seat"] = seats[n.player]
        out[n.name] = d
    return out


def _share(g, n, reach):
    s = g._avg(n)
    w = np.array([rg.class_combos(k) for k in range(169)]) * reach
    tot = w.sum()
    return {a: (_r(float((w * s[i]).sum() / tot), 4) if tot > 0 else None) for i, a in enumerate(n.actions)}


def seats_behind(g):
    """For a limp game: every seat behind the hero, the nodes where it acts
    over the hero's limp / complete and over the iso, and how often it
    raises there (combo-weighted over the hands that reach the node)."""
    out = []
    for seat in g.seats[2:]:
        p = g.seats.index(seat)
        d = dict(seat=seat)
        for n in g.nodes:
            if n.player != p:
                continue
            if n.name == f"{seat}VsLimps":
                d["vsLimps"] = dict(node=n.name, actions=n.actions, freq=_share(g, n, _node_reach(g, n)))
            if n.name == f"{seat}VsIso":
                d["vsIso"] = dict(node=n.name, actions=n.actions, freq=_share(g, n, _node_reach(g, n)))
        out.append(d)
    return out


NOTE_LIMP = ("Model: UTG limps an assumed loose-passive range; every seat behind "
             "the hero acts (raises over a limp, calls or 3-bets an iso); "
             "three-way pots are valued with a realisation model.")
NOTE_LIMP_BB = ("Model: UTG limps an assumed loose-passive range and everyone else "
                "folds; the BB raises or checks.")
NOTE_3B = ("Model: everyone else folds; the opening range is the approximate "
           "chart; a 5-bet is all-in.")


def make_spots(games, stats, fixed_point):
    """The published spot dicts (gates applied)."""
    spots = {}
    post_expl = {pt: max(s["exploitPctPot"] + s.get("subsetExploitPctPot", [])) for pt, s in stats.items()}
    check = fixed_point.get("checkDelta", {})
    borrow = fixed_point.get("borrowGate", {})
    for gid, g in games.items():
        hero = g.hero
        evs = g.action_evs(hero)
        sid = "cash-" + gid
        if isinstance(g, pf.Game):
            reach = [_r(x) for x in g.reach0]
            leaves = sorted({t.info["potType"] for t in g.terms if t.info.get("potType") in stats})
        else:
            reach = None
            leaves = sorted(set(g.solved_pots) | set(g.borrowed))
        sp = dict(
            game=gid,
            actions=hero.actions,
            strategy=_rows(g._avg(hero)),
            ev=[[_r(evs[a, k], 3) for a in range(len(hero.actions))] for k in range(169)],
            reach=reach,
            exploitabilityBb=_r(g.expl, 6),
            iterations=g.iters,
            flopLeaves=leaves,
            maxFlopExploitPctPot=_r(max([post_expl[p] for p in leaves if p in post_expl] or [float("nan")]), 3),
            fixedPointDelta=_r(check.get(gid), 4),
            nodes=_nodes(gid, g),
        )
        if not isinstance(g, pf.Game):
            sp["players"] = list(g.seats)
            sp["nashGapByPlayer"] = [_r(x, 7) for x in getattr(g, "br_gain", [])]
            sp["seatsBehind"] = seats_behind(g)
            sp["borrowedTables"] = list(g.borrowed)
            if gid in borrow:
                sp["borrowGateDelta"] = _r(borrow[gid], 4)
            sp["note"] = NOTE_LIMP_BB if gid.endswith("-BB") else NOTE_LIMP
        else:
            sp["note"] = NOTE_3B
        spots[sid] = sp
    validate.run(spots)
    return spots


def write(out_dir, games, Rt, aggs, stats, flops, sub, bench, fixed_point, tab, cfg):
    os.makedirs(out_dir, exist_ok=True)
    spots = make_spots(games, stats, fixed_point)
    check = fixed_point.get("checkDelta", {})
    borrow = fixed_point.get("borrowGate", {})
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
        fixedPoint=dict(
            rounds=[dict(round=r["round"], damp=r.get("damp"),
                         heroDelta={k: _r(v, 4) for k, v in r.get("heroDelta", {}).items()},
                         checkDelta={k: _r(v, 4) for k, v in r.get("checkDelta", {}).items()},
                         meanAbsDeltaR={k: _r(v, 4) for k, v in r.get("meanAbsDeltaR", {}).items()},
                         rangeDrift={k: _r(v, 4) for k, v in r.get("rangeDrift", {}).items()})
                    for r in fixed_point.get("rounds", [])],
            finalCheckDelta={k: _r(v, 4) for k, v in check.items()},
            borrowGateDelta={k: _r(v, 4) for k, v in borrow.items()}),
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
                        subsetExploitPctPot=[_r(x, 3) for x in s.get("subsetExploitPctPot", [])],
                        iterations=s["iters"], seconds=_r(s["seconds"], 0),
                        players=side)
    post = dict(
        name="Felt Notes solved flop EV tables",
        license="CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)",
        attribution="Felt Notes (https://github.com/sagearbor/texasHoldemGTO)",
        generated=time.strftime("%Y-%m-%d"),
        format=("players['0'|'1'] = preflop player 0 / 1 of the game that reaches "
                "the pot (see preflop.json nodes); ev = bb won from the flop pot net "
                "of own postflop bets, averaged over the weighted flop set; "
                "realisation = ev / (equity x pot); exploitPctPot = the solves on "
                "every flop, subsetExploitPctPot = the fixed-point correction solves"),
        flopSubset=flops,
        correctionSubset=[f["flop"] for f in sub],
        potTypes=pots,
        benchmarks=bench,
        settings=dict(postIters=cfg["POST_ITERS"], postTargetPctPot=cfg["POST_TARGET"],
                      benchIters=cfg["BENCH_ITERS"], flops=cfg["FLOPS_K"], subset=cfg["SUB_N"]),
    )
    with open(os.path.join(out_dir, "postflop.json"), "w") as f:
        json.dump(post, f, separators=(",", ":"))
    readme(out_dir, pre, post, stats, cfg, fixed_point)


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
    return open(path).read().strip() if os.path.exists(path) else ""


def _size(path):
    return f"{os.path.getsize(path) / 1024:.0f} KB"


def _pct(xs):
    xs = [x for x in xs if x is not None]
    return f"{min(xs):.2f}-{max(xs):.2f}" if xs else "-"


def readme(out_dir, pre, post, stats, cfg, fixed_point):
    tpl = open(os.path.join(HERE, "README.template.md")).read()
    rows = ["| Spot | id | Hero plays | Nash gap (bb/hand) | Worst flop expl. (% pot) | Fixed-point delta | Passed |",
            "|---|---|---|---|---|---|---|"]
    for sid, sp in pre["spots"].items():
        strat, acts = sp["strategy"], sp["actions"]
        reach = sp["reach"] or [1.0] * 169
        w = [rg.class_combos(k) * (reach[k] or 0) for k in range(169)]
        tot = sum(w)
        parts = [f"{lab} {sum(w[k] * strat[k][a] for k in range(169)) / tot * 100:.0f}%"
                 for a, lab in enumerate(acts)]
        rows.append(f"| {TITLES.get(sid, sid)} | `{sid}` | {', '.join(parts)} | "
                    f"{sp['exploitabilityBb']:.6f} | {sp['maxFlopExploitPctPot']} | "
                    f"{sp.get('fixedPointDelta')} | {'yes' if sp['passed'] else '**no**'} |")
    gates = ["| Spot | Failed gates |", "|---|---|"]
    for sid, sp in pre["spots"].items():
        bad = [f"{g['gate']} ({g['detail']})" for g in sp["gates"] if not g["ok"]]
        gates.append(f"| `{sid}` | {'; '.join(bad) if bad else 'none'} |")
    ex = ["| Pot type | Pot (bb) | Flops | Exploitability, % pot (min-max) | Correction solves | Iterations (median) | Compute (h) |",
          "|---|---|---|---|---|---|---|"]
    for pt, p in sorted(post["potTypes"].items()):
        s = stats[pt]
        ex.append(f"| `{pt}` | {p['pot']:g} | {len(p['flops'])} | {_pct(p['exploitPctPot'])} | "
                  f"{_pct(p['subsetExploitPctPot'])} | {int(np.median(s['iters']))} | {s['seconds'] / 3600:.1f} |")
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
    cross = _text(os.environ.get("CROSSCHECK_MD", os.path.join(HERE, "crosscheck.md"))) or "Not run."
    flops = post["flopSubset"]
    ft = ["| Flop | Stratum | Weight | Medoid weight |", "|---|---|---|---|"] + [
        f"| {f['flop']} | {f['stratum']} | {f['weight'] * 100:.2f}% | {f.get('medoidWeight', f['weight']) * 100:.2f}% |"
        for f in flops]
    fp = ["| Round | Damping | Hero delta vs previous round (max) | Undamped check (max) | Largest mean change in R |",
          "|---|---|---|---|---|"]
    for r in pre["fixedPoint"]["rounds"]:
        hd = [v for v in r["heroDelta"].values() if v is not None]
        cd = [v for v in r["checkDelta"].values() if v is not None]
        dr = [v for v in r["meanAbsDeltaR"].values() if v is not None]
        fp.append(f"| {r['round']} | {r['damp']} | {max(hd) if hd else '-'} | {max(cd) if cd else '-'} | "
                  f"{max(dr) if dr else '-'} |")
    secs = sum(s["seconds"] for s in stats.values())
    fill = {
        "generated": pre["generated"],
        "compute": os.environ.get("TOTAL_COMPUTE", f"{secs / 3600:.0f} h of flop solving "
                                                   f"({cfg.get('wall_hours', secs / 3600):.0f} h wall clock)"),
        "hours": os.environ.get("TOTAL_HOURS", f"{max(1, round(cfg.get('wall_hours', secs / 3600)))}"),
        "size_pre": _size(os.path.join(out_dir, "preflop.json")),
        "size_post": _size(os.path.join(out_dir, "postflop.json")),
        "spot_table": "\n".join(rows),
        "gate_table": "\n".join(gates),
        "expl_table": "\n".join(ex),
        "bench": bench_txt,
        "crosscheck": cross,
        "post_iters": str(cfg["POST_ITERS"]),
        "post_target": str(cfg["POST_TARGET"]),
        "fixed_point": "\n".join(fp),
        "flop_table": "\n".join(ft),
        "limp": cfg["LIMP"],
        "n_flops": str(len(flops)),
        "n_sub": str(len(post.get("correctionSubset", []))),
        "n_subA": str(cfg.get("SUB_A", "")),
        "sub_flops": ", ".join(post.get("correctionSubset", [])),
        "borrow": ", ".join(f"`{k}` {v}" for k, v in pre["fixedPoint"]["borrowGateDelta"].items()) or "-",
    }
    for k, v in fill.items():
        tpl = tpl.replace("{{" + k + "}}", v)
    extra = os.path.join(HERE, "limitations.md")
    tpl = tpl.replace("{{limitations}}", _text(extra))
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write(tpl)
