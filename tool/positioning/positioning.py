#!/usr/bin/env python3
"""Seating experiment, offline: where was each phone at the table?

Reads what the phones logged (lib/nearby/sense.dart) and renders a timeline
of the table with each phone's estimated position as a circle sized by its
uncertainty, the "where are you sitting?" answers as ground-truth marks,
and a scrubber over time. Standard library only; --png also writes PNGs
when matplotlib happens to be installed.

Inputs (any mix, one or more paths; folders are searched for *.jsonl):
  * a phone's local sense log, <app support>/sense/<night>.jsonl, or a
    Record the table session.jsonl (lines k = device / scan / uwb / seat,
    or the same with a "sense_" prefix);
  * a night fetched from the cloud by fetch_night.dart: JSON
    {"logs": [{"deviceId": .., "events": [{"s", "k", "t", "x"}, ..]}]}
    with the minute summaries (sense / device / seat events).

Model, per window of --window seconds:
  RSSI_ij = A - 10 n log10(d_ij) + tx_j + rx_i + noise
with a per-phone transmit and receive bias (models differ by several dB)
fitted over the whole night, then classical MDS on the distances, UWB
distances (iPhone pairs) replacing RSSI ones where present. Positions are
aligned to the ground-truth seats when at least three phones gave one,
otherwise the host is put at the bottom and each window is aligned to the
previous one. The circle radius is the phone's RMS distance residual.

  python3 tool/positioning/positioning.py logs/ -o tmp/seating.html
  python3 tool/positioning/synth.py -o tmp/synth && \
    python3 tool/positioning/positioning.py tmp/synth -o tmp/seating.html
"""

import argparse
import glob
import html
import json
import math
import os
import sys
from collections import defaultdict
from datetime import datetime

# Path loss: RSSI at 1 m and the exponent (indoors, people around: 2..3).
A_1M = -59.0
PATH_N = 2.2
# The table diagram in the app (nearby_ui.dart): the oval spans
# x 0.15..0.85, y 0.18..0.82 of the picture; a typical table is about
# 2.4 m by 1.2 m. Host at the bottom.
TABLE_W, TABLE_H = 2.4, 1.2


# --------------------------------------------------------------- loading

def _iso_ms(t):
    try:
        return int(datetime.strptime(t.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z").timestamp() * 1000)
    except (ValueError, AttributeError):
        return None


class Data:
    """Everything read, keyed by install id."""

    def __init__(self):
        self.rssi = []  # (ms, observer, peer key, rssi, tx or None)
        self.uwb = []  # (ms, observer, peer key, meters)
        self.devices = {}  # install id -> {model, os, key, ...}
        self.seats = {}  # install id -> (x, y, ms) in table-diagram units
        self.key_to_id = {}  # 'H:<night>' / 'D:<id>' -> install id

    def resolve(self, key):
        if key in self.key_to_id:
            return self.key_to_id[key]
        if key.startswith("D:"):
            return key[2:]
        return key  # an unknown host: keep its key as its id

    def add_device(self, dev_id, info):
        self.devices.setdefault(dev_id, {}).update({k: v for k, v in info.items() if v is not None})
        key = info.get("key")
        if key:
            self.key_to_id[key] = dev_id
        self.key_to_id["D:" + dev_id] = dev_id


def load_jsonl(path, data):
    lines = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                lines.append(json.loads(raw))
            except ValueError:
                continue  # a torn last line
    me = None
    for j in lines:
        k = (j.get("k") or "").replace("sense_", "")
        if k == "device" and j.get("device"):
            me = j["device"]
            data.add_device(me, j)
        elif k == "role" and j.get("role") == "camera" and j.get("device"):
            # Record the table: a fixed anchor, never a seat.
            me = me or j["device"]
            data.add_device(j["device"], {"role": "camera"})
        elif k in ("nearby_host", "nearby_night") and j.get("device"):
            # Record the table: this phone's own ids.
            me = me or j["device"]
            if j.get("organizer") and j.get("night"):
                data.key_to_id["H:" + j["night"]] = j["device"]
            data.add_device(j["device"], {})
    if me is None:
        me = os.path.splitext(os.path.basename(path))[0]
    for j in lines:
        k = (j.get("k") or "").replace("sense_", "")
        ms = _iso_ms(j.get("t")) or 0
        if k == "scan":
            for p in j.get("peers", []):
                rs = p.get("rssi") or []
                if rs:
                    data.rssi.append((ms, me, p["p"], _median(rs), p.get("tx")))
        elif k == "uwb" and j.get("m") is not None:
            data.uwb.append((ms, me, j["p"], float(j["m"])))
        elif k == "seat":
            data.seats[me] = (float(j["x"]), float(j["y"]), ms)


def load_night(path, data):
    with open(path, encoding="utf-8") as f:
        night = json.load(f)
    for log in night.get("logs", []):
        dev = log["deviceId"]
        evs = log.get("events", [])
        for e in evs:
            if e.get("k") == "device":
                data.add_device(dev, e.get("x", {}))
        data.add_device(dev, {})
        for e in evs:
            k, ms, x = e.get("k"), e.get("t", 0), e.get("x", {})
            if k == "sense":
                for p in x.get("p", []):
                    data.rssi.append((ms, dev, p[0], float(p[1]), p[3] if len(p) > 3 else None))
                for u in x.get("u", []):
                    data.uwb.append((ms, dev, u[0], u[1] / 100.0))
            elif k == "seat":
                data.seats[dev] = (float(x["x"]), float(x["y"]), ms)


def load(paths):
    data = Data()
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(glob.glob(os.path.join(p, "**", "*.jsonl"), recursive=True))
            files += sorted(glob.glob(os.path.join(p, "**", "*.json"), recursive=True))
        else:
            files.append(p)
    # Device lines first everywhere, so host keys resolve in every file.
    for f in files:
        if f.endswith(".json"):
            load_night(f, data)
    for f in files:
        if f.endswith(".jsonl"):
            load_jsonl(f, data)
    return data


# ------------------------------------------------------------- linear algebra

def _median(xs):
    s = sorted(xs)
    n = len(s)
    return float(s[n // 2]) if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def _matvec(m, v):
    return [sum(a * b for a, b in zip(row, v)) for row in m]


def _top_eig(m, k=2, iters=300):
    """Top k eigenpairs of a symmetric matrix (power iteration, deflation)."""
    n = len(m)
    m = [row[:] for row in m]
    out = []
    for e in range(k):
        v = [1.0 / math.sqrt(n) * (1 + 0.01 * ((i * 7 + e * 3) % 5)) for i in range(n)]
        lam = 0.0
        for _ in range(iters):
            w = _matvec(m, v)
            norm = math.sqrt(sum(x * x for x in w))
            if norm < 1e-12:
                break
            v = [x / norm for x in w]
            lam = sum(a * b for a, b in zip(v, _matvec(m, v)))
        out.append((lam, v))
        for i in range(n):
            for j in range(n):
                m[i][j] -= lam * v[i] * v[j]
    return out


def mds(d):
    """Classical (Torgerson) MDS: an n x n distance matrix -> n 2-D points."""
    n = len(d)
    if n == 1:
        return [(0.0, 0.0)]
    sq = [[d[i][j] ** 2 for j in range(n)] for i in range(n)]
    rm = [sum(r) / n for r in sq]
    cm = [sum(sq[i][j] for i in range(n)) / n for j in range(n)]
    tm = sum(rm) / n
    b = [[-0.5 * (sq[i][j] - rm[i] - cm[j] + tm) for j in range(n)] for i in range(n)]
    pts = [[0.0, 0.0] for _ in range(n)]
    for axis, (lam, v) in enumerate(_top_eig(b, 2)):
        s = math.sqrt(max(lam, 0.0))
        for i in range(n):
            pts[i][axis] = v[i] * s
    return [tuple(p) for p in pts]


def procrustes(src, dst, scale=True):
    """Best rotation/reflection (+ scale) + translation taking src onto dst.
    Returns a function mapping a point."""
    n = len(src)
    if n == 0:
        return lambda p: p
    sx = sum(p[0] for p in src) / n
    sy = sum(p[1] for p in src) / n
    dx = sum(p[0] for p in dst) / n
    dy = sum(p[1] for p in dst) / n
    a = [(p[0] - sx, p[1] - sy) for p in src]
    b = [(p[0] - dx, p[1] - dy) for p in dst]
    best = None
    for refl in (1, -1):
        aa = [(x, refl * y) for x, y in a]
        # Rotation angle maximising the dot product.
        num = sum(ax * by - ay * bx for (ax, ay), (bx, by) in zip(aa, b))
        den = sum(ax * bx + ay * by for (ax, ay), (bx, by) in zip(aa, b))
        th = math.atan2(num, den)
        c, s = math.cos(th), math.sin(th)
        rot = [(c * x - s * y, s * x + c * y) for x, y in aa]
        ss = sum(x * x + y * y for x, y in rot)
        k = (sum(rx * bx + ry * by for (rx, ry), (bx, by) in zip(rot, b)) / ss) if (scale and ss > 1e-12) else 1.0
        if scale and k <= 0:
            k = 1.0
        err = sum((k * rx - bx) ** 2 + (k * ry - by) ** 2 for (rx, ry), (bx, by) in zip(rot, b))
        if best is None or err < best[0]:
            best = (err, refl, c, s, k)
    _, refl, c, s, k = best

    def f(p):
        x, y = p[0] - sx, refl * (p[1] - sy)
        return (k * (c * x - s * y) + dx, k * (s * x + c * y) + dy)

    return f


def refine(pts, est, src, iters=400):
    """Weighted stress descent from the MDS start: UWB distances count far
    more than RSSI ones (classical MDS cannot weight)."""
    n = len(pts)
    p = [list(x) for x in pts]
    w = {"uwb": 25.0, "rssi": 1.0}
    pairs = [(i, j, est[i][j], w[src[i][j]]) for i in range(n) for j in range(i + 1, n) if est[i][j] is not None]
    if not pairs:
        return pts
    tot = sum(x[3] for x in pairs)
    step = 0.4
    for _ in range(iters):
        g = [[0.0, 0.0] for _ in range(n)]
        for i, j, t, wt in pairs:
            dx, dy = p[i][0] - p[j][0], p[i][1] - p[j][1]
            d = math.hypot(dx, dy) or 1e-9
            k = wt * (d - t) / d
            g[i][0] += k * dx
            g[i][1] += k * dy
            g[j][0] -= k * dx
            g[j][1] -= k * dy
        for i in range(n):
            p[i][0] -= step * g[i][0] / tot * len(pairs) / n
            p[i][1] -= step * g[i][1] / tot * len(pairs) / n
    return [tuple(x) for x in p]


# --------------------------------------------------------------- the model

def rssi_to_m(rssi, tx_bias=0.0, rx_bias=0.0):
    return 10 ** ((A_1M + tx_bias + rx_bias - rssi) / (10 * PATH_N))


def m_to_rssi(d, tx_bias=0.0, rx_bias=0.0):
    return A_1M - 10 * PATH_N * math.log10(max(d, 0.05)) + tx_bias + rx_bias


def windows(data, window_s):
    w = window_s * 1000
    out = defaultdict(lambda: {"rssi": defaultdict(list), "uwb": defaultdict(list)})
    for ms, obs, peer, r, _ in data.rssi:
        out[ms // w]["rssi"][(obs, data.resolve(peer))].append(r)
    for ms, obs, peer, m in data.uwb:
        out[ms // w]["uwb"][tuple(sorted((obs, data.resolve(peer))))].append(m)
    return [(k * w, out[k]) for k in sorted(out)]


def _distances(win, ids, tx, rx):
    """Pairwise distance estimates (m) and their source, symmetric."""
    idx = {d: i for i, d in enumerate(ids)}
    n = len(ids)
    est = [[None] * n for _ in range(n)]
    src = [[None] * n for _ in range(n)]
    acc = defaultdict(list)
    for (obs, peer), rs in win["rssi"].items():
        if obs in idx and peer in idx and obs != peer:
            d = rssi_to_m(_median(rs), tx.get(peer, 0.0), rx.get(obs, 0.0))
            acc[tuple(sorted((obs, peer)))].append(d)
    for pair, ds in acc.items():
        i, j = idx[pair[0]], idx[pair[1]]
        g = math.exp(sum(math.log(x) for x in ds) / len(ds))  # geometric mean of both directions
        est[i][j] = est[j][i] = g
        src[i][j] = src[j][i] = "rssi"
    for pair, ms in win["uwb"].items():
        if pair[0] in idx and pair[1] in idx and pair[0] != pair[1]:
            i, j = idx[pair[0]], idx[pair[1]]
            est[i][j] = est[j][i] = _median(ms)
            src[i][j] = src[j][i] = "uwb"
    return est, src


def _complete(est):
    """Missing pairs: shortest path through known ones, else the mean."""
    n = len(est)
    d = [[0.0 if i == j else (est[i][j] if est[i][j] is not None else math.inf) for j in range(n)] for i in range(n)]
    for k in range(n):
        for i in range(n):
            for j in range(n):
                if d[i][k] + d[k][j] < d[i][j]:
                    d[i][j] = d[i][k] + d[k][j]
    known = [d[i][j] for i in range(n) for j in range(n) if i != j and d[i][j] < math.inf]
    mean = sum(known) / len(known) if known else 1.0
    return [[mean if d[i][j] == math.inf else d[i][j] for j in range(n)] for i in range(n)]


def fit_biases(data, wins, ids, rounds=8):
    """Per-phone transmit and receive bias (dB), alternating with MDS per
    window; the mean bias is pinned at 0 (the absolute level is A_1M)."""
    tx = {d: 0.0 for d in ids}
    rx = {d: 0.0 for d in ids}
    for _ in range(rounds):
        e_tx, e_rx = defaultdict(list), defaultdict(list)
        for _, win in wins:
            present = sorted({x for pair in win["rssi"] for x in pair} & set(ids))
            if len(present) < 3:
                continue
            est, _ = _distances(win, present, tx, rx)
            pts = mds(_complete(est))
            pos = dict(zip(present, pts))
            for (obs, peer), rs in win["rssi"].items():
                if obs in pos and peer in pos and obs != peer:
                    dhat = math.dist(pos[obs], pos[peer])
                    e = _median(rs) - m_to_rssi(dhat, tx[peer], rx[obs])
                    e_tx[peer].append(e)
                    e_rx[obs].append(e)
        for d in ids:
            if e_tx[d]:
                tx[d] += 0.5 * _median(e_tx[d])
            if e_rx[d]:
                rx[d] += 0.5 * _median(e_rx[d])
        mt = sum(tx.values()) / len(tx)
        mr = sum(rx.values()) / len(rx)
        for d in ids:
            tx[d] -= mt
            rx[d] -= mr
    # The overall level is not identifiable from RSSI alone (it trades off
    # against the table's scale). Where iPhone pairs also have UWB, their
    # true distances pin it.
    lev = []
    for _, win in wins:
        for (obs, peer), rs in win["rssi"].items():
            ms = win["uwb"].get(tuple(sorted((obs, peer))))
            if ms and obs in tx and peer in tx:
                lev.append(_median(rs) - m_to_rssi(_median(ms), tx[peer], rx[obs]))
    if lev:
        c = _median(lev)
        for d in ids:
            tx[d] += c / 2
            rx[d] += c / 2
    return tx, rx


def seat_to_m(x, y):
    """Table-diagram units (0..1, host at the bottom) to metres, y up."""
    return ((x - 0.5) * TABLE_W / 0.7, (0.5 - y) * TABLE_H / 0.64)


def estimate(data, window_s=60):
    wins = windows(data, window_s)
    ids = sorted({o for _, o, _, _, _ in data.rssi} | {data.resolve(p) for _, _, p, _, _ in data.rssi}
                 | {o for _, o, _, _ in data.uwb} | {data.resolve(p) for _, _, p, _ in data.uwb})
    tx, rx = fit_biases(data, wins, ids)
    gt = {d: seat_to_m(x, y) for d, (x, y, _) in data.seats.items()}
    host = None
    for key, dev in data.key_to_id.items():
        if key.startswith("H:"):
            host = dev
    frames, prev = [], None
    for start, win in wins:
        present = sorted({x for pair in win["rssi"] for x in pair} | {x for pair in win["uwb"] for x in pair})
        present = [d for d in present if d in ids]
        if len(present) < 2:
            continue
        est, src = _distances(win, present, tx, rx)
        full = _complete(est)
        pts = refine(mds(full), est, src)
        pos = dict(zip(present, pts))
        # Alignment: ground truth if 3+ phones gave a seat, else the
        # previous window, else the host at the bottom.
        anchors = [d for d in present if d in gt]
        if len(anchors) >= 3:
            # UWB already fixes the scale; RSSI alone does not.
            f = procrustes([pos[d] for d in anchors], [gt[d] for d in anchors], scale=not win["uwb"])
        elif prev is not None and len([d for d in present if d in prev]) >= 2:
            common = [d for d in present if d in prev]
            f = procrustes([pos[d] for d in common], [prev[d] for d in common], scale=False)
        else:
            cx = sum(p[0] for p in pts) / len(pts)
            cy = sum(p[1] for p in pts) / len(pts)
            ang = 0.0
            if host in pos:
                hx, hy = pos[host][0] - cx, pos[host][1] - cy
                ang = -math.pi / 2 - math.atan2(hy, hx)
            c, s = math.cos(ang), math.sin(ang)
            f = (lambda c, s, cx, cy: lambda p: (c * (p[0] - cx) - s * (p[1] - cy), s * (p[0] - cx) + c * (p[1] - cy)))(c, s, cx, cy)
        pos = {d: f(p) for d, p in pos.items()}
        # Uncertainty: RMS of measured vs fitted distance per phone, with
        # a floor per source (UWB is good to ~10 cm, RSSI is not).
        n = len(present)
        out = {}
        for i, d in enumerate(present):
            res, uwb_only = [], True
            for j in range(n):
                if i != j and est[i][j] is not None:
                    res.append(est[i][j] - math.dist(pos[d], pos[present[j]]))
                    uwb_only = uwb_only and src[i][j] == "uwb"
            rms = math.sqrt(sum(r * r for r in res) / len(res)) if res else 1.0
            floor = 0.1 if (res and uwb_only) else 0.3
            out[d] = {"x": pos[d][0], "y": pos[d][1], "r": max(floor, rms),
                      "src": "uwb" if (res and uwb_only) else ("rssi+uwb" if any(src[i][j] == "uwb" for j in range(n) if j != i) else "rssi")}
        frames.append({"t": start, "pos": out})
        prev = {d: (v["x"], v["y"]) for d, v in out.items()}
    return {"frames": frames, "tx": tx, "rx": rx, "gt": gt, "host": host, "ids": ids}


# --------------------------------------------------------------- rendering

PALETTE = ["#2a78d6", "#e8743b", "#19a979", "#d64d8a", "#8a6bd1", "#c9a227", "#3aa6b9", "#b5533c", "#5f7a3a", "#7d7d7d"]


def render_html(result, data, path):
    ids = result["ids"]
    meta = {}
    for i, d in enumerate(ids):
        dev = data.devices.get(d, {})
        label = dev.get("model") or d[:6]
        if d == result["host"]:
            label += " (host)"
        if dev.get("role") == "camera":
            label += " (camera)"  # an anchor, not a seat
        meta[d] = {"label": label, "color": PALETTE[i % len(PALETTE)],
                   "tx": round(result["tx"].get(d, 0.0), 1), "rx": round(result["rx"].get(d, 0.0), 1)}
    payload = {
        "frames": [{"t": f["t"], "pos": {d: {k: (round(v, 3) if isinstance(v, float) else v) for k, v in p.items()}
                                          for d, p in f["pos"].items()}} for f in result["frames"]],
        "gt": {d: [round(x, 3), round(y, 3)] for d, (x, y) in result["gt"].items()},
        "meta": meta,
        "table": [TABLE_W, TABLE_H],
    }
    doc = TEMPLATE.replace("__DATA__", json.dumps(payload)).replace("__TITLE__", html.escape("Seating experiment"))
    with open(path, "w", encoding="utf-8") as f:
        f.write(doc)


def render_png(result, data, path):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.patches import Circle, Ellipse
    except ImportError:
        print("matplotlib not installed: no PNG", file=sys.stderr)
        return
    if not result["frames"]:
        return
    f = result["frames"][-1]
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.add_patch(Ellipse((0, 0), TABLE_W, TABLE_H, color="#1e5c3a", alpha=0.3))
    for i, d in enumerate(result["ids"]):
        p = f["pos"].get(d)
        col = PALETTE[i % len(PALETTE)]
        if p:
            ax.add_patch(Circle((p["x"], p["y"]), p["r"], color=col, alpha=0.25))
            ax.plot(p["x"], p["y"], "o", color=col)
            ax.annotate(data.devices.get(d, {}).get("model") or d[:6], (p["x"], p["y"]))
        if d in result["gt"]:
            gx, gy = result["gt"][d]
            ax.plot(gx, gy, "x", color=col, markersize=12, mew=2)
    ax.set_aspect("equal")
    ax.set_xlim(-2.5, 2.5)
    ax.set_ylim(-2, 2)
    ax.set_title("Last window")
    fig.savefig(path, dpi=120)


TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root{--bg:#f7f5ef;--fg:#1b1b1b;--muted:#6b6b6b;--table:#1e5c3a;--rim:#7a5a0e;--card:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#0d1a13;--fg:#f6f1e4;--muted:#9aa59d;--table:#1e5c3a;--rim:#e2b857;--card:#15281d}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:16px}
h1{font-size:20px;margin:0 0 4px} .muted{color:var(--muted);font-size:13px}
svg{width:100%;height:auto;background:var(--card);border-radius:10px;display:block;margin:12px 0}
input[type=range]{width:100%} .row{display:flex;gap:12px;align-items:center;flex-wrap:wrap}
table{border-collapse:collapse;font-size:13px;width:100%} td,th{padding:4px 6px;text-align:left;border-bottom:1px solid rgba(127,127,127,.25)}
.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px;vertical-align:middle}
button{font:inherit;padding:4px 12px}
</style></head><body><main>
<h1>Seating experiment</h1>
<div class="muted">Circles: estimated phone position, radius = uncertainty (overlaps are real ambiguity). &times; = where the player said they sat. Host at the bottom. Log only: none of this drives the app.</div>
<svg id="v" viewBox="-2.6 -2.1 5.2 4.2" preserveAspectRatio="xMidYMid meet"></svg>
<div class="row"><button id="play">Play</button><span id="when"></span></div>
<input id="s" type="range" min="0" value="0" step="1">
<table id="legend"><thead><tr><th>Phone</th><th>Source</th><th>&plusmn; m</th><th>tx bias dB</th><th>rx bias dB</th></tr></thead><tbody></tbody></table>
</main>
<script>
const D = __DATA__;
const svg = document.getElementById('v'), s = document.getElementById('s'), when = document.getElementById('when');
const NS = 'http://www.w3.org/2000/svg';
s.max = Math.max(0, D.frames.length - 1);
function el(n, a) { const e = document.createElementNS(NS, n); for (const k in a) e.setAttribute(k, a[k]); return e; }
function draw(i) {
  svg.innerHTML = '';
  const [W, H] = D.table;
  svg.appendChild(el('ellipse', {cx: 0, cy: 0, rx: W / 2, ry: H / 2, fill: 'var(--table)', stroke: 'var(--rim)', 'stroke-width': 0.04, opacity: 0.85}));
  const f = D.frames[i];
  if (!f) { when.textContent = 'no data'; return; }
  when.textContent = new Date(f.t).toISOString().replace('T', ' ').slice(0, 19) + ' UTC  (' + (i + 1) + '/' + D.frames.length + ')';
  for (const [d, g] of Object.entries(D.gt)) {
    const c = (D.meta[d] || {}).color || '#888', x = g[0], y = -g[1];
    svg.appendChild(el('path', {d: `M${x-.09} ${y-.09}L${x+.09} ${y+.09}M${x-.09} ${y+.09}L${x+.09} ${y-.09}`, stroke: c, 'stroke-width': 0.035}));
  }
  const rows = [];
  for (const [d, p] of Object.entries(f.pos)) {
    const m = D.meta[d] || {label: d, color: '#888'};
    svg.appendChild(el('circle', {cx: p.x, cy: -p.y, r: p.r, fill: m.color, 'fill-opacity': 0.22, stroke: m.color, 'stroke-width': 0.02}));
    svg.appendChild(el('circle', {cx: p.x, cy: -p.y, r: 0.04, fill: m.color}));
    const t = el('text', {x: p.x + 0.07, y: -p.y - 0.07, 'font-size': 0.13, fill: 'currentColor'}); t.textContent = m.label; svg.appendChild(t);
    rows.push(`<tr><td><span class="dot" style="background:${m.color}"></span>${m.label}</td><td>${p.src}</td><td>${p.r.toFixed(2)}</td><td>${m.tx}</td><td>${m.rx}</td></tr>`);
  }
  document.querySelector('#legend tbody').innerHTML = rows.join('');
}
s.oninput = () => draw(+s.value);
let timer = null;
document.getElementById('play').onclick = (e) => {
  if (timer) { clearInterval(timer); timer = null; e.target.textContent = 'Play'; return; }
  e.target.textContent = 'Pause';
  timer = setInterval(() => { s.value = (+s.value + 1) % D.frames.length; draw(+s.value); }, 400);
};
svg.style.color = getComputedStyle(document.body).color;
draw(0);
</script></body></html>
"""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="sense JSONL files, session.jsonl, night JSON, or folders")
    ap.add_argument("-o", "--out", default="seating.html", help="HTML output")
    ap.add_argument("--window", type=int, default=60, help="seconds per frame (default 60)")
    ap.add_argument("--png", help="also write the last frame as a PNG (needs matplotlib)")
    a = ap.parse_args(argv)
    data = load(a.paths)
    if not data.rssi and not data.uwb:
        print("no readings found", file=sys.stderr)
        return 1
    result = estimate(data, a.window)
    render_html(result, data, a.out)
    if a.png:
        render_png(result, data, a.png)
    print(f"{len(result['frames'])} frames, {len(result['ids'])} phones -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
