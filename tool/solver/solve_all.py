"""Felt Notes solved preflop spots: the whole pipeline (driven by
tool/solve_all.sh).

  round 0  preflop games solved with starting realisation tables
           (START_R: a previous run's published tables, or a prior)
  pass A   every heads-up flop leaf solved on the SUB flops (a subset of
           the full flop set) with the round-0 ranges
  round 1  preflop games re-solved with the pass-A tables
  pass B   every leaf solved on ALL flops (FLOPS_K, default 54) with the
           round-1 ranges: the published EV tables
  round k  (k >= 2) R = R_B(all flops) + R_sub(round k-1 ranges) -
           R_B(sub flops), damped with the previous round; repeated until
           the hero strategies settle (or FP_MAX rounds)
  check    one more correction from the published ranges, UNDAMPED, and a
           preflop re-solve: fixedPointDelta = share of the hero's hands
           whose strategy that moves (gate: at most 5%)
  output   data/solved/preflop.json, data/solved/postflop.json, README

Every flop solve runs to POST_TARGET % of the pot (default 0.97) and is
cached by a hash of its inputs under the work dir, so the run resumes after
an interruption (preflop solves are deterministic and re-run in minutes).
"""
import hashlib
import json
import os
import pickle
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import limp  # noqa: E402
import preflop as pf  # noqa: E402
import ranges as rg  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
WORK = os.environ.get("WORK", os.path.join(ROOT, "tmp", "solve"))
CACHE = os.path.join(ROOT, "tool", ".cache")
POSTFLOP = os.path.join(CACHE, "postflop")
EQUITY = os.path.join(CACHE, "equity")
OUT = os.environ.get("OUT", os.path.join(ROOT, "data", "solved"))
THREADS = int(os.environ.get("THREADS", "10"))
POST_ITERS = int(os.environ.get("POST_ITERS", "1000"))
POST_TARGET = float(os.environ.get("POST_TARGET", "0.97"))
BENCH_ITERS = int(os.environ.get("BENCH_ITERS", "600"))
MEM_GB = float(os.environ.get("MEM_GB", "9.5"))
FLOPS_K = int(os.environ.get("FLOPS_K", "54"))
SUB_N = int(os.environ.get("SUB_N", "12"))    # pass A flops (heaviest per stratum)
CORR_N = int(os.environ.get("CORR_N", "14"))  # fixed-point correction flops (calibrated)
FP_MAX = int(os.environ.get("FP_MAX", "16"))
FP_MIN = int(os.environ.get("FP_MIN", "4"))
ALL_EVERY = int(os.environ.get("ALL_EVERY", "4"))
FP_STOP = float(os.environ.get("FP_STOP", "0.03"))
START_R = os.environ.get("START_R", os.path.join(WORK, "start_R.json"))
STOP_FREE_GB = 12.0
PRE_ITERS, PRE_TARGET = 12000, 2e-5

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

# A loose-passive UTG limping range (population assumption, INPUT).
LIMP = ("22-TT, JJ:0.3, QQ+:0.15, A2s-AJs, AQs:0.4, AKs:0.2, K8s+, Q9s+, J9s+, "
        "T8s+, 97s+, 86s+, 75s+, 64s+, 54s, A8o-AJo, AQo:0.5, AKo:0.2, KTo+, "
        "QTo+, JTo, T9o:0.5")

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


# the solved heads-up pots of the limp games (players: 0 = hero, 1 = UTG)
pot_type("LIMP:BB-UTG", 2.5, STACK - 1, 0, None)
pot_type("ISO:BB-UTG", 10.5, STACK - 5, 0, 0)
pot_type("ISO:SB-UTG", 11.0, STACK - 5, 0, 0)
pot_type("ISO:BTN-UTG", 9.5, STACK - 4, 1, 0)
pot_type("ISO:CO-UTG", 9.5, STACK - 4, 1, 0)


# ------------------------------------------------------------- games
PRIOR = {}
TAB = None
TRI = None


def prior_R(ip):
    """Only for tables that were never solved: IP realises 1.05, OOP 0.85
    of its equity, stronger hands a little more."""
    if ip not in PRIOR:
        e = (TAB.N * TAB.E).sum(1) / TAB.N.sum(1)
        PRIOR[ip] = np.clip((1.05 if ip else 0.85) + 0.6 * (e - 0.5), 0.2, 2.0)
    return PRIOR[ip]


def R_of(Rt, name, player):
    t = Rt.get(name)
    if t is not None:
        return t[player]
    if name.startswith("4BP"):
        return None
    P = POT_TYPES[name]
    return prior_R(player != P.oop)


def R_default(name, p):
    if name in POT_TYPES:
        r = R_of({}, name, p)
        return np.ones(169) if r is None else r
    return np.ones(169)


def game_3bet(spot, tab, Rt):
    """Players: 0 = opener (hero), 1 = 3-bettor. Everyone else folds."""
    O, V = spot["hero"], spot["villain"]
    o = 3.0 if O == "SB" else 2.5
    pv = BLIND.get(V, 0.0)
    dead = sum(b for p, b in BLIND.items() if p not in (O, V))
    t = spot["three"]
    hero_ip = V in BLIND and O != "SB"
    f = 22.0 if hero_ip else 25.0
    oop = 1 if hero_ip else 0
    srp = f"SRP:{O}-{V}"
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
    g.hero = root.kids[-1]
    g.n = 2
    return g


# register the 3-bet pot types up front (the limp games borrow their tables)
for _sp in THREE_BET:
    _O, _V, _t = _sp["hero"], _sp["villain"], _sp["three"]
    _o = 3.0 if _O == "SB" else 2.5
    _dead = sum(b for p, b in BLIND.items() if p not in (_O, _V))
    _ip = _V in BLIND and _O != "SB"
    _f = 22.0 if _ip else 25.0
    if _V != "SB":
        pot_type(f"SRP:{_O}-{_V}", 2 * _o + _dead, STACK - _o, 1 if _ip else 0, 0)
    pot_type(f"3BP:{_O}-{_V}", 2 * _t + _dead, STACK - _t, 1 if _ip else 0, 1)
    pot_type(f"4BP:{_O}-{_V}", 2 * _f + _dead, STACK - _f, 1 if _ip else 0, 0)


def game_limp(hero, tab, Rt, alt=False):
    b = limp.Builder(hero, Rt, R_default, alt=alt)
    g = b.build(tab, TRI, rg.parse(LIMP))
    return g


def solve_game(g, label, warm=None):
    if warm is not None:
        load_state(g, warm)
    g.solve(iters=PRE_ITERS, target=PRE_TARGET, check=250)
    if g.expl is None or g.expl >= PRE_TARGET:
        log(f"  {label}: nash gap {g.expl:.6f} after {g.iters} it (target {PRE_TARGET})")
    return g


def game_state(g):
    return {nd.name: (nd.R.copy(), nd.S.copy()) for nd in g.nodes}


def load_state(g, st):
    """Warm start: the previous round's regrets (so the current strategy
    starts where the last round ended); the average restarts from zero."""
    for nd in g.nodes:
        if nd.name in st and st[nd.name][0].shape == nd.R.shape:
            nd.R[:] = st[nd.name][0]
            nd.S[:] = 0


def solve_round(tab, Rt, label, warm=None, alt=False, only=None):
    """Solve every game; returns {id: game}. warm: {id: state} from the
    previous round (CFR continues from it: continuity between rounds)."""
    games = {}
    t0 = time.time()
    specs = [(f"limp1-{h}", lambda h=h: game_limp(h, tab, Rt, alt)) for h in ["BB", "SB", "BTN", "CO"]]
    specs += [(f"3b-{sp['id']}", lambda sp=sp: game_3bet(sp, tab, Rt)) for sp in THREE_BET]
    for gid, mk in specs:
        if only is not None and gid not in only:
            continue
        g = mk()
        solve_game(g, gid, (warm or {}).get(gid))
        games[gid] = g
    log(f"{label}: preflop solved in {time.time() - t0:.0f}s; "
        + ", ".join(f"{k} {g.expl:.6f}" for k, g in games.items()))
    return games


PROBE_EPS = 0.01   # probe weight, relative to the class's reach at its decision
PROBE_POT = float(os.environ.get("PROBE_POT", "0.04"))  # probe classes within 4% of the pot of their best action


def _abs_reach(g, node):
    """Absolute reach (input range x strategy) of node's actor at node."""
    if isinstance(g, pf.Game):
        r0, r1 = g.reach_at(node)
        return np.asarray(r0 if node.player == 0 else r1)
    return g.prior_range[node.player] * g.reach_at(node)[node.player]


def _probes(g, term, pot):
    """For players 0 and 1 of a heads-up leaf: probe weights for classes
    that reach their last decision before the leaf (only the published
    hero's decision and the action that enters the leaf) and whose EV for the
    action taken there is close to their best action (within PROBE_POT x the
    flop pot). Without probes a class that never takes the action is never
    measured, gets an extrapolated R, and a too-low guess confirms itself
    (v2's first pass valued KJs below KTs that way)."""
    path = g._path_to(g.root, term, [])
    out = {}
    cache = getattr(g, "_ev_cache", None)
    if cache is None:
        cache = g._ev_cache = {}
    final = path[-1][0].player if path else None
    for p in (0, 1):
        last = [(nd, a) for nd, a in path if nd.player == p]
        if not last or not (last[-1][0] is g.hero or p == final):
            out[p] = np.zeros(169)
            continue
        nd, a = last[-1]
        if id(nd) not in cache:
            cache[id(nd)] = (np.nan_to_num(g.action_evs(nd), nan=-1e9), _abs_reach(g, nd))
        ev, reach = cache[id(nd)]
        gap = ev.max(0) - ev[a]
        ok = (reach >= 0.01) & (gap < PROBE_POT * pot)
        out[p] = np.where(ok, PROBE_EPS * reach, 0.0)
    return out


def leaf_jobs(games, probe=True):
    """Solved heads-up flop leaves: {potType: (rangeOOP, rangeIP)}, with
    probe weights (see _probes) unless probe=False."""
    out = {}
    for gid, g in games.items():
        for item in g.leaf_ranges():
            term = item[0]
            pt = term.info.get("potType")
            if pt not in POT_TYPES:
                continue
            if len(item) == 3:
                r0, r1 = item[1], item[2]
            else:
                rs = item[1]
                if tuple(term.active) != (0, 1):
                    continue
                r0, r1 = rs[0], rs[1]
            r0, r1 = np.asarray(r0, float), np.asarray(r1, float)
            if probe:
                pr = _probes(g, term, POT_TYPES[pt].pot)
                r0, r1 = np.maximum(r0, pr[0]), np.maximum(r1, pr[1])
            P = POT_TYPES[pt]
            ro, ri = (r0, r1) if P.oop == 0 else (r1, r0)
            out[pt] = (ro, ri)
    return out


# ------------------------------------------------------------ helpers
def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{cmd[0]} failed ({r.returncode}): {r.stderr[-2000:]}")
    return r


def equity_tables():
    global TAB, TRI
    os.makedirs(CACHE, exist_ok=True)
    hu = os.path.join(CACHE, "eq_hu_100k.txt")
    if not os.path.exists(hu):
        log("HU equity table (100k samples per class pair)")
        run([EQUITY, "hu", "100000", hu])
    tri = os.path.join(CACHE, "eq_tri_10k.bin")
    if not os.path.exists(tri):
        log("3-way equity tensor (10k samples per class triple)")
        run([EQUITY, "tri", "10000", tri])
    TAB = pf.Tables(hu)
    TRI = np.fromfile(tri, dtype=np.float32).reshape(169, 169, 169)
    return TAB


def job_key(pt, flop, ro, ri, target):
    P = POT_TYPES[pt]
    h = hashlib.sha1()
    h.update(json.dumps([pt, flop, P.pot, P.stack, P.bets(), POST_ITERS, target,
                         [round(float(x), 4) for x in ro], [round(float(x), 4) for x in ri]]).encode())
    return h.hexdigest()[:16]


def run_postflop(pt, flop, ro, ri, target=None, iters=None):
    target = POST_TARGET if target is None else target
    iters = POST_ITERS if iters is None else iters
    jobs = os.path.join(WORK, "jobs")
    os.makedirs(jobs, exist_ok=True)
    key = job_key(pt, flop, ro, ri, target)
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
    log(f"  {pt:14s} {flop}  expl {d['exploitPctPot']:.3f}%  {d['iters']} it  {time.time() - t0:.0f}s")
    if d["exploitPctPot"] >= target:
        log(f"  WARNING {pt} {flop} did not reach {target}% in {iters} iterations")
    return d


def aggregate(pt, results, flops):
    """Per preflop player p: dict(R, ev, eq, mass) over 169 classes,
    weighted over [flops]."""
    P = POT_TYPES[pt]
    w = np.array([f["weight"] for f in flops])
    w = w / w.sum()
    out = {}
    for side in (0, 1):
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
    """Realisation by class for preflop players 0 / 1: the measured R where
    the class reaches the flop (every class with any weight in the range is
    in the flop solve), a weighted linear fit of R on equity vs the
    opponent's range elsewhere; clipped to [0.2, 2.0]. Probe classes (tiny
    weight, see _probes) are measured as accurately as the rest: CFR's
    regrets for a combo don't depend on its own weight. A negligible prior
    (1e-5 of the mean class mass) only guards against empty classes."""
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
        opp = ranges_by_player[1 - p]
        Wm = tab.N * opp[None, :]
        e_all = (Wm * tab.E).sum(1) / np.maximum(Wm.sum(1), 1e-12)
        fit = coef[0] + coef[1] * e_all
        m0 = 1e-5 * m[ok].mean()
        Robs = np.where(ok, a["R"], fit)
        R = np.where(ok, (m * Robs + m0 * fit) / (m + m0), fit)
        res[p] = np.clip(R, 0.2, 2.0)
    return res


def solve_postflop(jobs, tab, flops, label):
    """jobs: {potType: (ro, ri)}. Returns Rt, aggs, stats, results."""
    Rt, aggs, stats, allres = {}, {}, {}, {}
    t0 = time.time()
    # cheap pot types first (a crash late in a pass loses less)
    order = sorted(jobs, key=lambda pt: (-POT_TYPES[pt].pot, pt))
    for pt in order:
        ro, ri = jobs[pt]
        res = [run_postflop(pt, f["flop"], ro, ri) for f in flops]
        agg = aggregate(pt, res, flops)
        P = POT_TYPES[pt]
        by_player = {P.oop: np.array(ro), 1 - P.oop: np.array(ri)}
        Rt[pt] = r_table(agg, tab, by_player)
        aggs[pt] = agg
        allres[pt] = res
        stats[pt] = dict(
            exploitPctPot=[r["exploitPctPot"] for r in res],
            iters=[r["iters"] for r in res],
            seconds=sum(r["seconds"] for r in res),
            pot=P.pot)
    log(f"{label}: postflop {len(order)} pot types x {len(flops)} flops in {time.time() - t0:.0f}s")
    return Rt, aggs, stats, allres


def range_dist(a, b):
    a, b = np.array(a), np.array(b)
    cc = np.array([rg.class_combos(k) for k in range(169)])
    return float((np.abs(a - b) * cc).sum() / max((np.maximum(a, b) * cc).sum(), 1e-9))


def hero_reach(g):
    """The hero's input range at its decision (the opener's chart in the
    3-bet games, every hand in the limp games)."""
    return np.asarray(g.reach0) if isinstance(g, pf.Game) else np.ones(169)


def hero_delta(g, gp):
    """Share of the hero's hands (combo- and reach-weighted) whose strategy
    differs between two solutions (total variation)."""
    a, b = g._avg(g.hero), gp._avg(gp.hero)
    w = np.array([rg.class_combos(k) for k in range(169)]) * hero_reach(g)
    tv = 0.5 * np.abs(a - b).sum(0)
    return float((w * tv).sum() / w.sum())


def blend(Ra, Rb, lam):
    return {pt: {p: lam * Ra[pt][p] + (1 - lam) * Rb[pt][p] for p in (0, 1)} for pt in Ra}


def correct(R_full, R_sub_now, R_sub_base):
    out = {}
    for pt in R_full:
        out[pt] = {}
        for p in (0, 1):
            c = R_sub_now[pt][p] - R_sub_base[pt][p] if pt in R_sub_now and pt in R_sub_base else 0
            out[pt][p] = np.clip(R_full[pt][p] + c, 0.2, 2.0)
    return out


def load_start_R():
    """Starting tables (round 0 only): {potType: {0: R, 1: R}}."""
    if not os.path.exists(START_R):
        # fall back to the published dataset's tables, if any
        pub = os.path.join(OUT, "postflop.json")
        if not os.path.exists(pub):
            return {}
        pts = json.load(open(pub))["potTypes"]
        d = {pt: {p: v["players"][p]["realisationUsed"] for p in ("0", "1")} for pt, v in pts.items()}
        return {pt: {int(p): np.array([x if x is not None else 1.0 for x in v[p]]) for p in v} for pt, v in d.items()}
    d = json.load(open(START_R))
    return {pt: {int(p): np.array([x if x is not None else 1.0 for x in v[p]]) for p in v} for pt, v in d.items()}


def subset(flops, n):
    """n flops of the full set for the fixed-point correction rounds: per
    stratum in proportion to weight (at least one each), heaviest first;
    weights renormalised. The correction is a difference of two solves on
    the same subset, so its bias largely cancels."""
    by = {}
    for f in flops:
        by.setdefault(f["stratum"], []).append(f)
    tot = sum(f["weight"] for f in flops)
    alloc = {s: max(1, int(n * sum(f["weight"] for f in fs) / tot)) for s, fs in by.items()}
    while sum(alloc.values()) < n:
        s = max(by, key=lambda s: n * sum(f["weight"] for f in by[s]) / tot - alloc[s])
        alloc[s] += 1
    while sum(alloc.values()) > n:
        s = max(alloc, key=lambda s: alloc[s] - n * sum(f["weight"] for f in by[s]) / tot)
        alloc[s] -= 1
    out = []
    for s, fs in by.items():
        out += sorted(fs, key=lambda f: -f["weight"])[:alloc[s]]
    return sorted(out, key=lambda f: -f["weight"])


def correction_subset(flops, n):
    """n of the flops for the fixed-point correction rounds, chosen greedily
    so that, after a bounded calibration of their weights (0.2x-5x), the
    subset reproduces the population margins of flops.py (strata, highest
    card, each rank on the board) as closely as n flops can."""
    import itertools
    import flops as fl
    counts = {}
    deck = [(r, s) for r in range(13) for s in range(4)]
    for c in itertools.combinations(deck, 3):
        k = fl.canon(list(c))
        counts[k] = counts.get(k, 0) + 1
    allk = list(counts)
    tot = sum(counts.values())
    target = fl.margins(allk) @ (np.array([counts[k] for k in allk]) / tot)

    def key(s):
        return fl.canon([(fl.RANKS.index(s[i]), "shdc".index(s[i + 1])) for i in (0, 2, 4)])
    X = fl.margins([key(f["flop"]) for f in flops])
    w0 = np.array([f["weight"] for f in flops])
    chosen = []
    for _ in range(n):
        best = None
        for j in range(len(flops)):
            if j in chosen:
                continue
            c = chosen + [j]
            _, e = fl.calibrate(w0[c] / w0[c].sum(), X[:, c], target, 0.2, 5.0)
            if best is None or e < best[0]:
                best = (e, j)
        chosen.append(best[1])
    w, err = fl.calibrate(w0[chosen] / w0[chosen].sum(), X[:, chosen], target, 0.2, 5.0)
    out = [dict(flops[j], weight=float(wi)) for j, wi in zip(chosen, w)]
    return out, err


def save_tables(path, Rt):
    json.dump({pt: {str(p): [float(x) for x in v[p]] for p in v} for pt, v in Rt.items()}, open(path, "w"))


# -------------------------------------------------------------- main
def main():
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    tab = equity_tables()
    fpath = os.path.join(WORK, f"flops{FLOPS_K}.json")
    if not os.path.exists(fpath):
        r = run([sys.executable, os.path.join(HERE, "flops.py"), str(FLOPS_K)])
        with open(fpath, "w") as f:
            f.write(r.stdout)
    flops = json.load(open(fpath))
    subA = subset(flops, SUB_N)
    sub, sub_err = correction_subset(flops, CORR_N)
    log(f"flop set: {len(flops)} flops; pass A subset: {' '.join(f['flop'] for f in subA)}; "
        f"correction subset ({sub_err:.3f} largest margin error): {' '.join(f['flop'] for f in sub)}")
    t_start = time.time()

    # round 0 -> pass A (subset) -> round 1
    R0 = load_start_R()
    games0 = solve_round(tab, R0, "round 0")
    jobsA = leaf_jobs(games0, probe=False)
    RA, _, statsA, _ = solve_postflop(jobsA, tab, subA, "pass A (subset)")
    games1 = solve_round(tab, RA, "round 1", warm={k: game_state(g) for k, g in games0.items()})

    # pass B: all flops with the round-1 ranges
    jobsB = leaf_jobs(games1)
    RB, aggsB, statsB, resB = solve_postflop(jobsB, tab, flops, "pass B (all flops)")
    names = [f["flop"] for f in flops]
    idx = [names.index(f["flop"]) for f in sub]
    RBsub = {}
    for pt, res in resB.items():
        P = POT_TYPES[pt]
        ro, ri = jobsB[pt]
        RBsub[pt] = r_table(aggregate(pt, [res[i] for i in idx], sub), tab,
                            {P.oop: np.array(ro), 1 - P.oop: np.array(ri)})
    save_tables(os.path.join(WORK, "R_passB.json"), RB)

    # fixed-point rounds
    rounds = []
    Rt = RB
    games = solve_round(tab, Rt, "round 2", warm={k: game_state(g) for k, g in games1.items()})
    d12 = {k: hero_delta(games[k], games1[k]) for k in games}
    rounds.append(dict(round=2, damp=1.0, heroDelta=d12,
                       rangeDrift={pt: max(range_dist(jobsB[pt][0], j[0]), range_dist(jobsB[pt][1], j[1]))
                                   for pt, j in leaf_jobs(games).items() if pt in jobsB}))
    log("round 2 hero delta: " + ", ".join(f"{k} {v:.3f}" for k, v in d12.items()))
    stats_all = {pt: dict(exploitPctPot=list(sb["exploitPctPot"]), iters=list(sb["iters"]),
                          seconds=sb["seconds"] + statsA.get(pt, {}).get("seconds", 0),
                          subsetExploitPctPot=list(statsA.get(pt, {}).get("exploitPctPot", [])), pot=sb["pot"])
                 for pt, sb in statsB.items()}
    # Fixed-point rounds: fictitious-play averaging. The measured tables are
    # not a continuous function of the ranges (a class that leaves a range
    # is measured as a probe the opponent doesn't expect, and realises much
    # more: e.g. AA calling a 3-bet in 3BP:CO-BB measured 1.16 / 0.64 / 1.18
    # in three consecutive rounds as it moved in and out), so damped
    # iteration oscillates. Instead every round measures the tables on the
    # current ranges (target_k) and the preflop games are re-solved with the
    # running average of all targets so far, R_k = mean(target_2..target_k)
    # (method of successive averages / fictitious play), continuing CFR from
    # the previous round's regrets. Every round re-measures the "fast" pots
    # (3BP, 4BP, ISO, LIMP) on the correction subset; the single-raised
    # pots (most of the compute; they only shape the 3-bettor's flat-or-3-bet
    # split) every ALL_EVERY rounds. Stops when the published strategies
    # move by at most FP_STOP between consecutive rounds (after FP_MIN
    # averaged rounds). The undamped check (a re-solve with the latest
    # single measurement) is reported too.
    rnd = 2
    measure_all, since_all = True, 0
    Rs_last, targets = {}, []
    chk, dchk, dd = None, {}, {}
    while True:
        jobs_now = leaf_jobs(games)
        pts = [pt for pt in jobs_now if measure_all or not pt.startswith("SRP:")]
        Rs, _, st, _ = solve_postflop({pt: jobs_now[pt] for pt in pts}, tab, sub,
                                      f"fp {rnd + 1} (subset, {'all pots' if measure_all else 'fast pots'})")
        for pt, s in st.items():
            stats_all[pt]["subsetExploitPctPot"] += s["exploitPctPot"]
            stats_all[pt]["seconds"] += s["seconds"]
        Rs_last.update(Rs)
        target = correct(RB, Rs_last, RBsub)
        targets.append(target)
        chk = solve_round(tab, target, f"check {rnd}", warm={k: game_state(g) for k, g in games.items()})
        dchk = {k: hero_delta(chk[k], games[k]) for k in games}
        log(f"undamped check after round {rnd} ({'all pots' if measure_all else 'fast pots'}): "
            + ", ".join(f"{k} {v:.3f}" for k, v in dchk.items()))
        rounds[-1]["checkDelta"] = dchk
        rounds[-1]["allPotsMeasured"] = measure_all
        settled = (len(targets) > FP_MIN and dd and max(dd.values()) <= FP_STOP)
        if settled or rnd >= FP_MAX + 1:
            break
        since_all = 0 if measure_all else since_all + 1
        measure_all = since_all + 1 >= ALL_EVERY
        rnd += 1
        Rt_new = {pt: {p: np.mean([t[pt][p] for t in targets], axis=0) for p in (0, 1)} for pt in Rt}
        dR = {pt: max(float(np.abs(Rt_new[pt][p] - Rt[pt][p]).mean()) for p in (0, 1)) for pt in Rt}
        Rt = Rt_new
        save_tables(os.path.join(WORK, f"R_round{rnd}.json"), Rt)
        prev = games
        games = solve_round(tab, Rt, f"round {rnd}", warm={k: game_state(g) for k, g in games.items()})
        dd = {k: hero_delta(games[k], prev[k]) for k in games}
        rounds.append(dict(round=rnd, damp=round(1.0 / len(targets), 3), heroDelta=dd, meanAbsDeltaR=dR,
                           rangeDrift={pt: max(range_dist(jobs_now[pt][0], j[0]), range_dist(jobs_now[pt][1], j[1]))
                                       for pt, j in leaf_jobs(games).items() if pt in jobs_now}))
        log(f"round {rnd} (average of {len(targets)} targets): max mean |dR| {max(dR.values()):.3f}; hero delta "
            + ", ".join(f"{k} {v:.3f}" for k, v in dd.items()))
        with open(os.path.join(WORK, "fp_progress.json"), "w") as f:
            json.dump(dict(round=rnd, heroDelta=dd, checkDelta=dchk), f)
    save_tables(os.path.join(WORK, "R_final.json"), Rt)
    with open(os.path.join(WORK, "games_final.pkl"), "wb") as f:
        pickle.dump({k: game_state(g) for k, g in games.items()}, f)

    # borrowing gate: alternative donors for every borrowed table
    alt = {}
    for h in ["SB", "BTN", "CO"]:
        gid = f"limp1-{h}"
        ga = game_limp(h, tab, Rt, alt=True)
        solve_game(ga, gid + " alt", game_state(games[gid]))
        alt[gid] = hero_delta(ga, games[gid])
    log("borrowing gate (alternative donors): " + ", ".join(f"{k} {v:.3f}" for k, v in alt.items()))

    # benchmark: A-high dry SRP, BTN vs BB, converged further
    bench = []
    jobs_f = leaf_jobs(games)
    pt = "SRP:BTN-BB"
    if pt in jobs_f:
        ro, ri = jobs_f[pt]
        for flop in ["As7d2c", "Ah8c3d"]:
            d = run_postflop(pt, flop, ro, ri, target=0.15, iters=BENCH_ITERS)
            node = next(n for n in d["flop"] if n["path"] == "X")
            A = len(node["actions"])
            tot = sum(node["reach"])
            fr = {node["actions"][a]: sum(node["freq"][k * A + a] for k in range(169)) / tot for a in range(A)}
            bench.append(dict(flop=flop, potType=pt, node="BTN after BB checks", freq=fr,
                              exploitPctPot=d["exploitPctPot"], iters=d["iters"]))
            log(f"benchmark {flop}: {fr}  expl {d['exploitPctPot']:.3f}%")
    import export  # noqa: E402
    fixed_point = dict(rounds=rounds, check=chk, checkDelta=dd, undampedCheckDelta=dchk, borrowGate=alt)
    export.write(OUT, games, Rt, aggsB, stats_all, flops, sub, bench, fixed_point, tab,
                 dict(POST_ITERS=POST_ITERS, POST_TARGET=POST_TARGET, BENCH_ITERS=BENCH_ITERS,
                      RFI=RFI, LIMP=LIMP, THREE_BET=THREE_BET, FLOPS_K=FLOPS_K, SUB_N=CORR_N, SUB_A=SUB_N,
                      wall_hours=(time.time() - t_start) / 3600,
                      POT_TYPES={k: vars(v) | {"bets": v.bets()} for k, v in POT_TYPES.items()}))
    log("done")


if __name__ == "__main__":
    main()
