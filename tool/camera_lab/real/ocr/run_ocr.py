"""Real-photo OCR experiment: Apple Vision (VNRecognizeTextRequest) as on-device proxy.

Steps per photo:
  1. build variants: full image, lower-half crop, upper (board) crop, overlapping tiles of
     the lower half; each at rotations 0/90/180/270 and small deskews (+-20, +-40 deg).
  2. run the compiled Swift CLI (vision_ocr.swift) for several Vision configs.
  3. map every observation back to original-pixel coordinates.
  4. rank tokens = observations whose whole text is a card rank (filters caption text).
  5. colour (red/black) from the rank glyph's ink + the pip below it; small shape check
     for the suit (heart/diamond, club/spade) from the pip blob.
  6. vote -> top-2 distinct cards in the hero area; report board area separately.

Run:  cvenv/bin/python tool/camera_lab/real/ocr/run_ocr.py  (see results.md for outputs)
"""
import json
import os
import subprocess
import sys
import time
from collections import defaultdict

import cv2
import numpy as np

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
DATA = os.path.join(REPO, "camera_data/cards-2deals_TH")
OUT = os.path.join(REPO, "tmp/overnight/cv-ocr")
SCR = os.environ.get("SCRATCH", "/tmp")
BIN = os.path.join(SCR, "vision_ocr")
WORK = os.path.join(SCR, "ocr_variants")

RANKS = {"A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"}
# conservative confusable map (reported separately from exact hits)
CONFUSE = {"O": "Q", "0": "Q", "IO": "10", "1O": "10", "LO": "10", "I0": "10", "L0": "10", "TO": "10"}

CONFIGS = [
    ("accurate", 0, 1),  # no language correction + custom words
    ("accurate", 1, 0),  # default-ish
    ("accurate", 0, 0),
    ("fast", 0, 0),
]
ANGLES = [0, 90, 180, 270, -20, 20, -40, 40]


def rotate(img, ang):
    """Rotate counter-clockwise by ang degrees, expanding the canvas. Returns (img, M 2x3)."""
    h, w = img.shape[:2]
    c = (w / 2, h / 2)
    M = cv2.getRotationMatrix2D(c, ang, 1.0)
    cos, sin = abs(M[0, 0]), abs(M[0, 1])
    nw, nh = int(h * sin + w * cos), int(h * cos + w * sin)
    M[0, 2] += nw / 2 - c[0]
    M[1, 2] += nh / 2 - c[1]
    return cv2.warpAffine(img, M, (nw, nh), borderValue=(0, 0, 0)), M


def build_variants(path, stem, mode):
    img = cv2.imread(path)
    H, W = img.shape[:2]
    crops = {"full": (0, 0, W, H), "lower": (0, int(H * 0.45), W, H), "upper": (0, 0, W, int(H * 0.5))}
    # overlapping 1600px tiles over the lower 60%
    ts = 1600
    y0 = int(H * 0.4)
    for ty in range(y0, H - ts // 2, ts // 2):
        for tx in range(0, W - ts // 2, ts // 2):
            crops[f"t{tx}_{ty}"] = (tx, ty, min(W, tx + ts), min(H, ty + ts))
    vs = []
    os.makedirs(WORK, exist_ok=True)
    for cname, (x0, y0_, x1, y1) in crops.items():
        angs = ANGLES if mode == "full" else [0]
        if cname in ("full", "upper"):
            angs = [0, 90, 180, 270]
        for a in angs:
            sub = img[y0_:y1, x0:x1]
            rot, M = rotate(sub, a) if a else (sub, np.array([[1, 0, 0], [0, 1, 0]], float))
            p = os.path.join(WORK, f"{stem}_{cname}_{a}.png")
            if not os.path.exists(p):
                cv2.imwrite(p, rot)
            vs.append(dict(path=p, crop=cname, off=(x0, y0_), ang=a, M=M, rshape=rot.shape[:2]))
    return img, vs


def run_vision(paths, cfg):
    level, lc, cw = cfg
    res = {}
    for i in range(0, len(paths), 40):
        out = subprocess.run([BIN, level, str(lc), str(cw), "0"] + paths[i:i + 40],
                             capture_output=True, text=True, check=True).stdout
        for line in out.splitlines():
            d = json.loads(line)
            res[d["file"]] = d
    return res


def to_orig(v, box):
    """normalised box in rotated variant -> 4 corner points + centre in original pixels."""
    rh, rw = v["rshape"]
    x, y, w, h = box
    pts = np.array([[x * rw, y * rh], [(x + w) * rw, y * rh], [(x + w) * rw, (y + h) * rh], [x * rw, (y + h) * rh]])
    Minv = cv2.invertAffineTransform(v["M"])
    o = (Minv[:, :2] @ pts.T).T + Minv[:, 2]
    o += np.array(v["off"])
    return o


def ink_colour(rot, rect):
    """Classify ink in rect (in rotated variant pixels) as red/black. Returns (label, redness, n_ink)."""
    x0, y0, x1, y1 = [int(round(t)) for t in rect]
    h, w = rot.shape[:2]
    x0, y0, x1, y1 = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
    if x1 - x0 < 3 or y1 - y0 < 3:
        return "?", 0.0, 0
    patch = rot[y0:y1, x0:x1].astype(np.int32)
    b, g, r = patch[..., 0], patch[..., 1], patch[..., 2]
    lum = (r + g + b) / 3
    paper = np.percentile(lum, 90)
    ink = lum < paper * 0.65
    n = int(ink.sum())
    if n < 8:
        return "?", 0.0, n
    redness = float(np.mean(r[ink] - np.maximum(g[ink], b[ink])))
    return ("red" if redness > 35 else "black"), redness, n


def pip_shape(rot, rect, colour):
    """Very small suit-shape heuristic on the pip blob under the rank. Returns suit letter or '?'."""
    x0, y0, x1, y1 = [int(round(t)) for t in rect]
    h, w = rot.shape[:2]
    x0, y0, x1, y1 = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
    if x1 - x0 < 6 or y1 - y0 < 6:
        return "?", {}
    patch = rot[y0:y1, x0:x1]
    p = patch.astype(np.int32)
    if colour == "red":
        m = ((p[..., 2] - np.maximum(p[..., 1], p[..., 0])) > 60).astype(np.uint8)
    else:
        lum = p.mean(axis=2)
        m = (lum < np.percentile(lum, 90) * 0.5).astype(np.uint8)
    n, lab, st, _ = cv2.connectedComponentsWithStats(m)
    if n < 2:
        return "?", {}
    i = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA]))
    if st[i, cv2.CC_STAT_AREA] < 30:
        return "?", {}
    blob = (lab == i).astype(np.uint8)
    cnts, _ = cv2.findContours(blob, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    c = max(cnts, key=cv2.contourArea)
    area = cv2.contourArea(c)
    hull = cv2.convexHull(c)
    solidity = area / max(1.0, cv2.contourArea(hull))
    bx, by, bw, bh = cv2.boundingRect(c)
    extent = area / max(1.0, bw * bh)
    # top 20% row width relative to max width (heart: two lobes wide; diamond/spade: pointed)
    rows = blob[by:by + bh, bx:bx + bw].sum(axis=1)
    topw = rows[: max(1, bh // 5)].mean() / max(1, rows.max())
    f = dict(solidity=round(solidity, 3), extent=round(extent, 3), topw=round(float(topw), 3))
    if colour == "red":
        suit = "d" if extent < 0.6 and topw < 0.35 else "h"
    else:
        suit = "c" if solidity < 0.86 else "s"
    return suit, f


def norm_rank(t):
    s = t.strip().upper().replace(" ", "")
    if s in RANKS:
        return s, "exact"
    if s in CONFUSE:
        return CONFUSE[s], "confusable"
    return None, None


def analyse(stem, img, vs, results, cfg_name, rot_cache):
    H, W = img.shape[:2]
    dets = []
    all_obs = []
    for v in vs:
        d = results.get(v["path"])
        if not d:
            continue
        for o in d["obs"]:
            pts = to_orig(v, o["box"])
            cx, cy = pts.mean(axis=0)
            all_obs.append(dict(crop=v["crop"], ang=v["ang"], text=o["text"], conf=o["conf"],
                                cx=float(cx), cy=float(cy), cands=[c["t"] for c in o["cands"]]))
            # candidate rank tokens: whole observation or a single-char token inside it
            r, kind = norm_rank(o["text"])
            if r is None:
                continue
            if v["path"] not in rot_cache:
                rot_cache[v["path"]] = cv2.imread(v["path"])
            rot = rot_cache[v["path"]]
            rh, rw = rot.shape[:2]
            x, y, w, h = o["box"]
            bx0, by0, bw, bh = x * rw, y * rh, w * rw, h * rh
            col, red, nink = ink_colour(rot, (bx0, by0, bx0 + bw, by0 + bh))
            prect = (bx0 - 0.3 * bw if r != "10" else bx0, by0 + bh * 1.05,
                     bx0 + bw * 1.3 if r != "10" else bx0 + bw * 0.6, by0 + bh * 2.3)
            pcol, pred_, pn = ink_colour(rot, prect)
            colour = pcol if pcol != "?" else col
            suit, feats = pip_shape(rot, prect, colour) if colour in ("red", "black") else ("?", {})
            dets.append(dict(rank=r, kind=kind, conf=o["conf"], crop=v["crop"], ang=v["ang"],
                             cx=float(cx), cy=float(cy), size=float(np.linalg.norm(pts[0] - pts[2])),
                             glyph_col=col, glyph_red=round(red, 1), pip_col=pcol, colour=colour,
                             suit=suit, feats=feats, area="hero" if cy > 0.42 * H else "board"))
    return dets, all_obs


def vote(dets, area):
    """Cluster rank detections by position (same physical index), then pick top-2 cards."""
    ds = [d for d in dets if d["area"] == area]
    clusters = []
    for d in ds:
        for c in clusters:
            if c["rank"] == d["rank"] and np.hypot(c["cx"] - d["cx"], c["cy"] - d["cy"]) < 120:
                c["members"].append(d)
                break
        else:
            clusters.append(dict(rank=d["rank"], cx=d["cx"], cy=d["cy"], members=[d]))
    cards = defaultdict(lambda: dict(score=0.0, n=0, clusters=0, suits=defaultdict(float), cols=defaultdict(float)))
    for c in clusters:
        m = c["members"]
        score = sum(x["conf"] * (1.0 if x["kind"] == "exact" else 0.5) for x in m)
        e = cards[c["rank"]]
        e["score"] += score
        e["n"] += len(m)
        e["clusters"] += 1
        for x in m:
            e["cols"][x["colour"]] += x["conf"]
            if x["suit"] != "?":
                e["suits"][x["suit"]] += x["conf"]
    out = []
    for r, e in sorted(cards.items(), key=lambda kv: -kv[1]["score"]):
        col = max(e["cols"], key=e["cols"].get) if e["cols"] else "?"
        okc = {"red": "hd", "black": "cs"}.get(col, "hdcs")
        ss = {s: v for s, v in e["suits"].items() if s in okc}
        suit = max(ss, key=ss.get) if ss else "?"
        out.append(dict(rank=r, colour=col, suit=suit, score=round(e["score"], 2), n=e["n"],
                        clusters=e["clusters"], suits={k: round(v, 2) for k, v in e["suits"].items()}))
    return out


def main():
    labels = json.load(open(os.path.join(DATA, "labels.json")))
    photos = sorted(k for k in labels if k.endswith(".jpg"))
    os.makedirs(OUT, exist_ok=True)
    summary = {}
    for ph in photos:
        stem = ph[:-4]
        img, vs = build_variants(os.path.join(DATA, ph), stem, "full")
        per = {}
        rot_cache = {}
        for cfg in CONFIGS:
            cname = f"{cfg[0]}-lc{cfg[1]}-cw{cfg[2]}"
            t0 = time.time()
            res = run_vision([v["path"] for v in vs], cfg)
            wall = time.time() - t0
            dets, obs = analyse(stem, img, vs, res, cname, rot_cache)
            # timing of the single plain full-frame call and lower-crop call, per config
            t_full = res[[v["path"] for v in vs if v["crop"] == "full" and v["ang"] == 0][0]]["ms"]
            t_lower = res[[v["path"] for v in vs if v["crop"] == "lower" and v["ang"] == 0][0]]["ms"]
            vision_ms = sum(r["ms"] for r in res.values())
            per[cname] = dict(dets=dets, obs=obs, hero=vote(dets, "hero"), board=vote(dets, "board"),
                              n_variants=len(vs), vision_ms_total=round(vision_ms), wall_s=round(wall, 1),
                              ms_full=round(t_full), ms_lower=round(t_lower),
                              raw_full0=[o for o in res[[v["path"] for v in vs if v["crop"] == "full" and v["ang"] == 0][0]]["obs"]])
            print(ph, cname, "hero:", [(c["rank"], c["colour"], c["suit"], c["score"]) for c in per[cname]["hero"][:4]],
                  "board:", [(c["rank"], c["score"]) for c in per[cname]["board"][:4]], f"{wall:.1f}s", flush=True)
        summary[ph] = per
        # annotated image (best config)
        best = per["accurate-lc0-cw1"]
        an = img.copy()
        for o in best["obs"]:
            cv2.circle(an, (int(o["cx"]), int(o["cy"])), 10, (200, 200, 0), -1)
        for d in best["dets"]:
            c = (0, 0, 255) if d["colour"] == "red" else (255, 0, 0)
            cv2.putText(an, f"{d['rank']}{d['suit']}", (int(d["cx"]) - 30, int(d["cy"]) - 20),
                        cv2.FONT_HERSHEY_SIMPLEX, 2.2, c, 6)
            cv2.circle(an, (int(d["cx"]), int(d["cy"])), 22, (0, 255, 0), 5)
        cv2.imwrite(os.path.join(OUT, f"annot_{stem}.jpg"), cv2.resize(an, (1125, 1500)))
    json.dump(summary, open(os.path.join(OUT, "raw_results.json"), "w"), indent=1, default=str)


if __name__ == "__main__":
    main()
