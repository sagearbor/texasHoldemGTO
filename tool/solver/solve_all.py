"""Felt Notes solved preflop spots: the whole pipeline (driven by
tool/solve_all.sh).

  round 0  preflop games solved with plain-equity flops (R = 1)
  post 1   every heads-up flop leaf of those games is solved on the flop
           subset (tool/solver/postflop.cpp, flop + turn + river) with the
           ranges that reach it; per-class EVs -> realisation tables R
  round 1  preflop games re-solved with the solved R tables
  post 2   (optional, POST2_FLOPS) the leaves are re-solved with round-1
           ranges on a smaller subset to measure the fixed-point drift
  output   data/solved/preflop.json, data/solved/postflop.json

Every postflop job is cached by a hash of its inputs under the work dir, so
the run resumes after an interruption. Work dir default: tmp/solve.
"""
import hashlib
import json
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import preflop as pf  # noqa: E402
import ranges as rg  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
WORK = os.environ.get("WORK", os.path.join(ROOT, "tmp", "solve"))
CACHE = os.path.join(ROOT, "tool", ".cache")
POSTFLOP = os.path.join(CACHE, "postflop")
EQUITY = os.path.join(CACHE, "equity")
OUT = os.environ.get("OUT", os.path.join(ROOT, "data", "solved"))
THREADS = int(os.environ.get("THREADS", "10"))
POST_ITERS = int(os.environ.get("POST_ITERS", "80"))
POST_TARGET = float(os.environ.get("POST_TARGET", "1.0"))
BENCH_ITERS = int(os.environ.get("BENCH_ITERS", "300"))
MEM_GB = float(os.environ.get("MEM_GB", "6.5"))
FP_ROUNDS = int(os.environ.get("FP_ROUNDS", "2"))
FP_FLOPS = int(os.environ.get("FP_FLOPS", "3"))
STOP_FREE_GB = 15.0

STACK = 100.0

# --------------------------------------------------------------- inputs
# Opening ranges: the app's 6-max RFI charts (lib/gto/spots.dart, kept in
# sync by test/solved_data_test.dart). They are an INPUT here.
RFI = {
    "UTG": "66+, 55:0.6, 44:0.3, A9s+, A8s:0.6, A5s-A3s, A2s:0.5, A7s-A6s:0.3, "
           "KTs+, K9s:0.5, QTs+, Q9s:0.3, JTs, J9s:0.3, T9s, 98s:0.5, 87s:0.3, "
           "76s:0.25, AJo+, ATo:0.5, KQo, KJo:0.3",
    "CO": "33+, 22:0.6, A2s+, K6s+, K5s:0.5, Q8s+, J8s+, T8s+, 97s+, 86s+, 75s+, "
          "65s, 54s:0.6, A9o+, A8o:0.4, KTo+, K9o:0.3, QTo+, JTo, J9o:0.2",
    "BTN": "22+, A2s+, K2s+, Q4s+, Q3s:0.5, J6s+, J5s:0.5, T6s+, 96s+, 85s+, "
           "74s+, 64s+, 53s+, 43s:0.6, A2o+, K8o+, K7o:0.5, Q9o+, Q8o:0.4, J9o+, "
           "J8o:0.3, T9o, T8o:0.4, 98o:0.5, 87o:0.25",
    "SB": "22+, A2s+, K3s+, Q5s+, J7s+, T7s+, 96s+, 86s+, 75s+, 64s+, 54s, "
          "43s:0.4, A2o+, K8o+, K7o:0.4, Q9o+, Q8o:0.3, J9o+, T9o, 98o:0.4",
}

# A loose-passive UTG limping range (population assumption, INPUT): small and
# medium pairs, suited aces and broadways, suited connectors, offsuit
# broadways, and a few big hands slow-played.
LIMP = ("22-TT, JJ:0.3, QQ+:0.15, A2s-AJs, AQs:0.4, AKs:0.2, K8s+, Q9s+, J9s+, "
        "T8s+, 97s+, 86s+, 75s+, 64s+, 54s, A8o-AJo, AQo:0.5, AKo:0.2, KTo+, "
        "QTo+, JTo, T9o:0.5")

# Facing-a-3-bet spots (ids match the app). size = 3-bet to; 4-bet 22bb in
# position, 25bb out of position; 5-bet = all-in.
THREE_BET = [
    dict(id="UTG-ip", hero="UTG", villain="BTN", three=7.5),
    dict(id="UTG-blinds", hero="UTG", villain="BB", three=10.0),
    dict(id="CO-BTN", hero="CO", villain="BTN", three=7.5),
    dict(id="CO-blinds", hero="CO", villain="BB", three=10.0),
    dict(id="BTN-SB", hero="BTN", villain="SB", three=10.0),
    dict(id="BTN-BB", hero="BTN", villain="BB", three=10.0),
    dict(id="SB-BB", hero="SB", villain="BB", three=9.0),
]
BLIND = {"SB": 0.5, "BB": 1.0}


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def free_gb():
    st = os.statvfs("/")
    return st.f_bavail * st.f_frsize / 1e9


# ---------------------------------------------------------- pot types
class PotType:
    """A heads-up flop reached from a preflop game.
    oop: which preflop player (0 / 1) is out of position postflop.
    aggr: preflop player who made the last raise (None for limped pots)."""

    def __init__(self, name, pot, stack, oop, aggr):
        self.name, self.pot, self.stack, self.oop, self.aggr = name, pot, stack, oop, aggr

    def bets(self):
        oop_aggr = self.aggr is not None and self.aggr == self.oop
        return {
            "flop-oop": "0.33,0.75" if oop_aggr else "-",
            "flop-ip": "0.33,0.75",
            "turn-oop": "0.75", "turn-ip": "0.75",
            "river-oop": "0.75", "river-ip": "0.75",
        }


POT_TYPES = {}


def pot_type(name, pot, stack, oop, aggr):
    POT_TYPES[name] = PotType(name, pot, stack, oop, aggr)
    return name


# ------------------------------------------------------------- games
PRIOR = {}


def prior_R(tab, ip):
    """Starting point of the fixed-point iteration only (replaced by the
    solved tables in round 1): IP realises 1.05, OOP 0.85 of its equity,
    stronger hands a little more (slope 0.6 on equity vs a random hand)."""
    key = ip
    if key not in PRIOR:
        e = (tab.N * tab.E).sum(1) / tab.N.sum(1)
        PRIOR[key] = np.clip((1.05 if ip else 0.85) + 0.6 * (e - 0.5), 0.2, 2.0)
    return PRIOR[key]


TAB = None


def R_of(Rt, name, player):
    t = Rt.get(name)
    if t is not None:
        return t[player]
    if name.startswith("4BP"):
        return None  # plain equity until solved (round 0; SPR under 2)
    P = POT_TYPES[name]
    return prior_R(TAB, ip=(player != P.oop))


def game_3bet(spot, tab, Rt):
    """Players: 0 = opener (hero), 1 = 3-bettor. Everyone else folds."""
    O, V = spot["hero"], spot["villain"]
    o = 3.0 if O == "SB" else 2.5
    pv = BLIND.get(V, 0.0)
    dead = sum(b for p, b in BLIND.items() if p not in (O, V))
    t = spot["three"]
    # the opener is in position unless the 3-bettor sits behind it on the
    # button, or the opener is the SB (vs the BB)
    hero_ip = V in BLIND and O != "SB"
    f = 22.0 if hero_ip else 25.0
    oop = 1 if hero_ip else 0
    srp = pot_type(f"SRP:{O}-{V}", 2 * o + dead, STACK - o, oop, 0)
    tbp = pot_type(f"3BP:{O}-{V}", 2 * t + dead, STACK - t, oop, 1)
    fbp = pot_type(f"4BP:{O}-{V}", 2 * f + dead, STACK - f, oop, 0)
    jam_node = pf.Node(0, ["Call", "Fold"], [pf.allin(tab, STACK, dead),
                                             pf.fold(1, f, STACK, dead)], "openerVsJam")
    v4 = pf.Node(1, ["Fold", "Call", "All-in"], [
        pf.fold(0, f, t, dead),
        pf.post(tab, fbp, f, dead, R_of(Rt, fbp, 0), R_of(Rt, fbp, 1)),
        jam_node], "threeBettorVs4bet")
    hero = pf.Node(0, [f"4-bet {int(f)}bb", "Call", "Fold"], [
        v4,
        pf.post(tab, tbp, t, dead, R_of(Rt, tbp, 0), R_of(Rt, tbp, 1)),
        pf.fold(1, o, t, dead)], "hero")
    vacts, vkids = ["Fold"], [pf.fold(0, o, pv, dead)]
    if V != "SB":
        vacts.append("Call")
        vkids.append(pf.post(tab, srp, o, dead, R_of(Rt, srp, 0), R_of(Rt, srp, 1)))
    vacts.append("3-bet")
    vkids.append(hero)
    root = pf.Node(1, vacts, vkids, "villainVsOpen")
    g = pf.Game(root, rg.parse(RFI[O]), [1.0] * 169, tab)
    g.hero = hero
    return g


def limp_reraise(tab, hero_inv, lrr, dead, hero_first_blind=0.0):
    """Hero raised to [hero_inv]; the limper re-raises to [lrr]."""
    jam = pf.Node(1, ["Call", "Fold"], [pf.allin(tab, STACK, dead),
                                        pf.fold(0, STACK, lrr, dead)], "limperVsJam")
    return pf.Node(0, ["Fold", "Call", "All-in"], [
        pf.fold(1, hero_inv, lrr, dead),
        pf.allin(tab, lrr, dead, kind="post4", info={"potType": "LRR"}),
        jam], "heroVsLimpReraise")


def game_limp(hero, tab, Rt, mwt):
    """Players: 0 = hero, 1 = the UTG limper (fixed limp range). Players
    between them fold; players behind hero fold to an iso-raise; after an
    overlimp / complete the SB folds and the BB checks its option."""
    L = rg.parse(LIMP)
    if hero == "BB":
        dead = 0.5
        iso = 5.0
        limped = pot_type("LIMP:BB-UTG", 2 + dead, STACK - 1, 0, None)
        isot = pot_type("ISO:BB-UTG", 2 * iso + dead, STACK - iso, 0, 0)
        utg = pf.Node(1, ["Fold", "Call", "Raise"], [
            pf.fold(0, iso, 1, dead),
            pf.post(tab, isot, iso, dead, R_of(Rt, isot, 0), R_of(Rt, isot, 1)),
            limp_reraise(tab, iso, 4 * iso, dead)], "limperVsIso")
        root = pf.Node(0, ["Raise 5bb", "Check"], [
            utg, pf.post(tab, limped, 1, dead, R_of(Rt, limped, 0), R_of(Rt, limped, 1))], "hero")
        g = pf.Game(root, [1.0] * 169, L, tab)
        g.hero = root
        return g
    sb = hero == "SB"
    iso = 5.0 if sb else 4.0
    dead = 1.0 if sb else 1.5
    isot = pot_type(f"ISO:{hero}-UTG", 2 * iso + dead, STACK - iso, 0 if sb else 1, 0)
    utg = pf.Node(1, ["Fold", "Call", "Raise"], [
        pf.fold(0, iso, 1, dead),
        pf.post(tab, isot, iso, dead, R_of(Rt, isot, 0), R_of(Rt, isot, 1)),
        limp_reraise(tab, iso, 4 * iso, dead)], "limperVsIso")
    # Multiway limped pot (hero, UTG, BB): realisation from the solved
    # heads-up limped pot by seat order: first to act uses the BB's (OOP)
    # table, last to act the limper's (IP) table.
    lt = Rt.get("LIMP:BB-UTG")
    r_oop = prior_R(tab, False) if lt is None else lt[0]
    r_ip = prior_R(tab, True) if lt is None else lt[1]
    if sb:
        passive = pf.mw(mwt, "MW:SB-UTG-BB", 1.0, 1.0, 3.0, r_oop, r_ip)
        fold_term = pf.Term(np.full((169, 169), -0.5), np.zeros((169, 169)), {"kind": "fold"})
        acts = [f"Iso {int(iso)}bb", "Complete", "Fold"]
    else:
        passive = pf.mw(mwt, f"MW:{hero}-UTG-BB", 1.0, 1.0, 3.5, r_ip, r_oop)
        fold_term = pf.Term(np.zeros((169, 169)), np.zeros((169, 169)), {"kind": "fold"})
        acts = [f"Iso {int(iso)}bb", "Overlimp", "Fold"]
    root = pf.Node(0, acts, [utg, passive, fold_term], "hero")
    g = pf.Game(root, [1.0] * 169, L, tab)
    g.hero = root
    return g


# ------------------------------------------------------------ helpers
def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{cmd[0]} failed ({r.returncode}): {r.stderr[-2000:]}")
    return r


def equity_tables():
    global TAB
    os.makedirs(CACHE, exist_ok=True)
    hu = os.path.join(CACHE, "eq_hu_100k.txt")
    if not os.path.exists(hu):
        log("HU equity table (100k samples per class pair)")
        run([EQUITY, "hu", "100000", hu])
    TAB = pf.Tables(hu)
    return TAB


def mw_table(third):
    key = hashlib.sha1(" ".join(f"{x:.4f}" for x in third).encode()).hexdigest()[:12]
    path = os.path.join(CACHE, f"eq_mw_{key}.txt")
    if not os.path.exists(path):
        rp = os.path.join(WORK, f"third_{key}.txt")
        with open(rp, "w") as f:
            f.write(" ".join(f"{x:.6f}" for x in third))
        log(f"3-way equity table {key}")
        run([EQUITY, "mw", "20000", rp, path])
    return pf.MWTable(path)


def solve_round(tab, Rt, label):
    """Solve every game; returns {id: game}."""
    games = {}
    t0 = time.time()
    g = game_limp("BB", tab, Rt, None)
    g.solve(iters=6000, target=2e-5, log=log)
    games["limp1-BB"] = g
    # BB's checking range vs one limper -> third hand of the 3-way pots
    s = g._avg(g.hero)
    third = list(s[1])
    mwt = mw_table(third)
    for hero in ["CO", "BTN", "SB"]:
        g = game_limp(hero, tab, Rt, mwt)
        g.solve(iters=6000, target=2e-5, log=log)
        games[f"limp1-{hero}"] = g
    for sp in THREE_BET:
        g = game_3bet(sp, tab, Rt)
        g.solve(iters=6000, target=2e-5, log=log)
        games[f"3b-{sp['id']}"] = g
    log(f"{label}: preflop solved in {time.time() - t0:.0f}s; "
        + ", ".join(f"{k} {g.expl:.6f}" for k, g in games.items()))
    return games


def leaf_jobs(games):
    """Postflop leaves: {potType: (rangeOOP, rangeIP)} (absolute weights)."""
    out = {}
    for gid, g in games.items():
        for term, r0, r1 in g.leaf_ranges():
            pt = term.info["potType"]
            if pt not in POT_TYPES:
                continue  # multiway pots are not solved postflop
            P = POT_TYPES[pt]
            ro, ri = (r0, r1) if P.oop == 0 else (r1, r0)
            out[pt] = (ro, ri)
    return out


def job_key(pt, flop, ro, ri, iters, target):
    P = POT_TYPES[pt]
    h = hashlib.sha1()
    h.update(json.dumps([pt, flop, P.pot, P.stack, P.bets(), iters, target,
                         [round(x, 3) for x in ro], [round(x, 3) for x in ri]]).encode())
    return h.hexdigest()[:16]


def run_postflop(pt, flop, ro, ri, iters, target):
    jobs = os.path.join(WORK, "jobs")
    os.makedirs(jobs, exist_ok=True)
    key = job_key(pt, flop, ro, ri, iters, target)
    out = os.path.join(jobs, f"{pt.replace(':', '_')}_{flop}_{key}.json")
    if os.path.exists(out):
        return json.load(open(out))
    if free_gb() < STOP_FREE_GB:
        raise RuntimeError(f"free disk {free_gb():.1f} GB < {STOP_FREE_GB} GB: stopping")
    P = POT_TYPES[pt]
    r0p, r1p = os.path.join(WORK, "r_oop.txt"), os.path.join(WORK, "r_ip.txt")
    with open(r0p, "w") as f:
        f.write(" ".join(f"{x:.4f}" for x in ro))
    with open(r1p, "w") as f:
        f.write(" ".join(f"{x:.4f}" for x in ri))
    cmd = [POSTFLOP, "--board", flop, "--pot", f"{P.pot}", "--stack", f"{P.stack}",
           "--r0", r0p, "--r1", r1p, "--iters", str(iters), "--target", str(target),
           "--threads", str(THREADS), "--mem", str(MEM_GB), "--river-allin", "0",
           "--reraise-allin", "111", "--raise", "3", "--out", out + ".part"]
    for k, v in P.bets().items():
        cmd += [f"--bets-{k}", v]
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"postflop {pt} {flop} failed: {r.stderr[-1500:]}")
    os.replace(out + ".part", out)
    d = json.load(open(out))
    log(f"  {pt:14s} {flop}  expl {d['exploitPctPot']:.2f}%  {d['iters']} it  {time.time() - t0:.0f}s")
    return d


def aggregate(pt, results, flops):
    """results: list of postflop JSON (same order as flops). Returns
    per preflop player p: dict(R, ev, eq, mass) over 169 classes."""
    P = POT_TYPES[pt]
    w = np.array([f["weight"] for f in flops])
    w = w / w.sum()
    out = {}
    for side in (0, 1):  # postflop side: 0 OOP, 1 IP
        evm = sum(wi * np.array(r["players"][side]["evMass"]) for wi, r in zip(w, results))
        mm = sum(wi * np.array(r["players"][side]["mass"]) for wi, r in zip(w, results))
        eqm = sum(wi * np.array(r["players"][side]["eqMass"]) for wi, r in zip(w, results))
        with np.errstate(invalid="ignore", divide="ignore"):
            ev = np.where(mm > 0, evm / mm, np.nan)
            eq = np.where(mm > 0, eqm / mm, np.nan)
            R = np.where(eqm > 0, evm / (P.pot * np.maximum(eqm, 1e-300)), np.nan)
        pre = P.oop if side == 0 else 1 - P.oop
        out[pre] = dict(R=R, ev=ev, eq=eq, mass=mm)
    return out


def r_table(agg, tab, ranges_by_player):
    """Smoothed realisation by class for preflop players 0 / 1: observed R
    (shrunk toward a linear fit of R on equity) where the class reaches the
    flop, the fit elsewhere; clipped to [0.2, 2.0]."""
    res = {}
    for p in (0, 1):
        a = agg[p]
        m = np.nan_to_num(a["mass"])
        ok = (m > 0) & np.isfinite(a["R"]) & np.isfinite(a["eq"])
        if ok.sum() < 5:
            res[p] = np.ones(169)
            continue
        x, y, wt = a["eq"][ok], a["R"][ok], m[ok]
        A = np.vstack([np.ones_like(x), x]).T * np.sqrt(wt)[:, None]
        coef, *_ = np.linalg.lstsq(A, y * np.sqrt(wt), rcond=None)
        # equity of every class vs the opponent's flop range (preflop, all-in)
        opp = ranges_by_player[1 - p]
        Wm = tab.N * opp[None, :]
        e_all = (Wm * tab.E).sum(1) / np.maximum(Wm.sum(1), 1e-12)
        fit = coef[0] + coef[1] * e_all
        m0 = 0.02 * m[ok].mean()
        Robs = np.where(ok, a["R"], fit)
        R = np.where(ok, (m * Robs + m0 * fit) / (m + m0), fit)
        res[p] = np.clip(R, 0.2, 2.0)
    return res


def solve_postflop(games, tab, flops, iters, target, label):
    jobs = leaf_jobs(games)
    Rt, aggs, stats = {}, {}, {}
    t0 = time.time()
    order = sorted(jobs)
    for pt in order:
        ro, ri = jobs[pt]
        res = [run_postflop(pt, f["flop"], ro, ri, iters, target) for f in flops]
        agg = aggregate(pt, res, flops)
        P = POT_TYPES[pt]
        by_player = {P.oop: np.array(ro), 1 - P.oop: np.array(ri)}
        Rt[pt] = r_table(agg, tab, by_player)
        aggs[pt] = agg
        stats[pt] = dict(
            exploitPctPot=[r["exploitPctPot"] for r in res],
            iters=[r["iters"] for r in res],
            seconds=sum(r["seconds"] for r in res),
            evOop=float(sum(f["weight"] * r["ev"][0] for f, r in zip(flops, res)) / sum(f["weight"] for f in flops)),
            pot=P.pot)
    log(f"{label}: postflop {len(order)} pot types x {len(flops)} flops in {time.time() - t0:.0f}s")
    return Rt, aggs, stats, jobs


def range_dist(a, b):
    a, b = np.array(a), np.array(b)
    cc = np.array([rg.class_combos(k) for k in range(169)])
    return float((np.abs(a - b) * cc).sum() / max((np.maximum(a, b) * cc).sum(), 1e-9))


# -------------------------------------------------------------- main
def main():
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    tab = equity_tables()
    fpath = os.path.join(WORK, "flops.json")
    if not os.path.exists(fpath):
        r = run([sys.executable, os.path.join(HERE, "flops.py")])
        with open(fpath, "w") as f:
            f.write(r.stdout)
    flops = json.load(open(fpath))
    log(f"flop subset: {len(flops)} flops")
    games0 = solve_round(tab, {}, "round 0")
    Rt1, aggs1, stats1, jobs1 = solve_postflop(games0, tab, flops, POST_ITERS, POST_TARGET, "post 1")
    games1 = solve_round(tab, Rt1, "round 1")
    jobs_r1 = leaf_jobs(games1)
    drift = {pt: max(range_dist(jobs1[pt][0], jobs_r1[pt][0]), range_dist(jobs1[pt][1], jobs_r1[pt][1]))
             for pt in jobs1 if pt in jobs_r1}
    log("range drift round0 -> round1: " + ", ".join(f"{k} {v:.3f}" for k, v in sorted(drift.items())))
    # Further fixed-point rounds on a small flop subset: each round re-solves
    # every pot type on the FP_FLOPS heaviest flops with the current ranges
    # and corrects the full-subset tables by the change seen there:
    #   R = R_full(round-0 ranges) + R_sub(current) - R_sub(round-0 ranges),
    # damped 50/50 with the previous round's tables.
    fixed_point = {"rounds": []}
    games, Rt = games1, Rt1
    games_prev = games0
    sub = sorted(flops, key=lambda f: -f["weight"])[:FP_FLOPS]
    Rbase = {}
    if FP_ROUNDS > 0:
        Rbase, _, _, _ = solve_postflop(games0, tab, sub, POST_ITERS, POST_TARGET, "fp base (subset)")
    prev_jobs = leaf_jobs(games1)
    for rnd in range(2, 2 + FP_ROUNDS):
        Rsub, _, _, _ = solve_postflop(games, tab, sub, POST_ITERS, POST_TARGET, f"fp {rnd} (subset)")
        Rnew = {}
        for pt in Rt1:
            Rnew[pt] = {}
            for p in (0, 1):
                corr = Rsub[pt][p] - Rbase[pt][p] if pt in Rsub and pt in Rbase else 0
                target = np.clip(Rt1[pt][p] + corr, 0.2, 2.0)
                Rnew[pt][p] = 0.5 * target + 0.5 * Rt[pt][p]
        dR = {pt: max(float(np.abs(Rnew[pt][p] - Rt[pt][p]).mean()) for p in (0, 1)) for pt in Rnew}
        Rt = Rnew
        games_prev = games
        games = solve_round(tab, Rt, f"round {rnd}")
        jobs_now = leaf_jobs(games)
        dr = {pt: max(range_dist(prev_jobs[pt][0], jobs_now[pt][0]),
                      range_dist(prev_jobs[pt][1], jobs_now[pt][1]))
              for pt in prev_jobs if pt in jobs_now}
        prev_jobs = jobs_now
        fixed_point["rounds"].append(dict(round=rnd, meanAbsDeltaR=dR, rangeDrift=dr))
        log(f"round {rnd}: max mean |dR| {max(dR.values()):.3f}; range drift "
            + ", ".join(f"{k} {v:.3f}" for k, v in sorted(dr.items())))
    games1, Rt1 = games, Rt
    jobs_r1 = leaf_jobs(games1)
    # benchmark: A-high dry SRP, BTN vs BB, converged further
    bench = []
    pt = "SRP:BTN-BB"
    if pt in jobs_r1:
        ro, ri = jobs_r1[pt]
        for flop in ["As7d2c", "Ah8c3d"]:
            d = run_postflop(pt, flop, ro, ri, BENCH_ITERS, 0.15)
            node = next(n for n in d["flop"] if n["path"] == "X")
            A = len(node["actions"])
            tot = sum(node["reach"])
            fr = {node["actions"][a]: sum(node["freq"][k * A + a] for k in range(169)) / tot for a in range(A)}
            bench.append(dict(flop=flop, potType=pt, node="BTN after BB checks", freq=fr,
                              exploitPctPot=d["exploitPctPot"], iters=d["iters"]))
            log(f"benchmark {flop}: {fr}  expl {d['exploitPctPot']:.3f}%")
    import export  # noqa: E402
    fixed_point["prevGames"] = games_prev
    export.write(OUT, games1, Rt1, aggs1, stats1, flops, bench, drift, fixed_point, tab,
                 dict(POST_ITERS=POST_ITERS, POST_TARGET=POST_TARGET, BENCH_ITERS=BENCH_ITERS,
                      RFI=RFI, LIMP=LIMP, THREE_BET=THREE_BET, POT_TYPES={k: vars(v) | {"bets": v.bets()} for k, v in POT_TYPES.items()}))
    log("done")


if __name__ == "__main__":
    main()
