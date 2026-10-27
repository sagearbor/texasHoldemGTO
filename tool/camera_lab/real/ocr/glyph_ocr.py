"""Stage 2: CV-assisted OCR. Find index-sized ink blobs on card paper, crop each tightly,
OCR the crop at several rotations with Apple Vision, then colour/suit from the blob + its pip.

Why: whole-frame Vision OCR drops isolated single glyphs (it's a text-LINE recogniser),
and revision 3 auto-orients, turning an upright '6' into '9'. Here we use revision 2
(VNREV=2, no auto-orientation) and do the rotations ourselves, and tile the glyph x3
('QQQ') which gives the line recogniser enough context to fire.

Run: SCRATCH=<scratch> cvenv/bin/python tool/camera_lab/real/ocr/glyph_ocr.py [rev]
"""
import json
import os
import subprocess
import sys
import time
from collections import Counter, defaultdict

import cv2
import numpy as np

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
DATA = os.path.join(REPO, "camera_data/cards-2deals_TH")
OUT = os.path.join(REPO, "tmp/overnight/cv-ocr")
SCR = os.environ.get("SCRATCH", "/tmp")
BIN = os.path.join(SCR, "vision_ocr")
REV = sys.argv[1] if len(sys.argv) > 1 else "2"
LEVEL = sys.argv[2] if len(sys.argv) > 2 else "accurate"
WORK = os.path.join(SCR, f"glyphs_rev{REV}")
RANKS = {"A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"}
CONFUSE = {"O": "Q", "0": "Q", "IO": "10", "1O": "10", "I0": "10", "LO": "10", "L0": "10"}
ANGLES = [0, 90, 180, 270, -25, 25, 155, 205]


def paper_mask(img):
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    m = ((hsv[..., 1] < 80) & (hsv[..., 2] > 120)).astype(np.uint8)
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    return m


def find_blobs(img, min_h, max_h):
    H, W = img.shape[:2]
    pm = paper_mask(img)
    lum = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    # local paper brightness -> ink = clearly darker than local background
    bg = cv2.dilate(lum, np.ones((31, 31), np.uint8))
    bg = cv2.GaussianBlur(bg, (0, 0), 15)
    b, g, r = [img[..., i].astype(np.int32) for i in range(3)]
    redink = (r - np.maximum(g, b)) > 70
    ink = ((lum.astype(np.float32) < bg * 0.6) | redink) & (cv2.dilate(pm, np.ones((41, 41), np.uint8)) > 0)
    ink = ink.astype(np.uint8)
    n, lab, st, cen = cv2.connectedComponentsWithStats(ink)
    blobs = []
    pm_d = pm
    for i in range(1, n):
        x, y, w, h, a = st[i]
        s = max(w, h)
        if not (min_h <= s <= max_h) or a < 0.08 * w * h or a > 0.85 * w * h and s > 30:
            continue
        if w > 3 * h or h > 4 * w:
            continue
        # ring around bbox must be mostly paper (glyph printed on white)
        m = int(0.35 * s)
        x0, y0, x1, y1 = max(0, x - m), max(0, y - m), min(W, x + w + m), min(H, y + h + m)
        ring = pm_d[y0:y1, x0:x1].astype(bool).copy()
        ringmask = np.ones_like(ring)
        ringmask[y - y0:y - y0 + h, x - x0:x - x0 + w] = False
        frac = ring[ringmask].mean() if ringmask.any() else 0
        if frac < 0.55:
            continue
        blobs.append(dict(id=i, x=int(x), y=int(y), w=int(w), h=int(h), area=int(a), cx=float(cen[i][0]),
                          cy=float(cen[i][1]), paper=float(frac)))
    return blobs, lab


def blob_colour(img, lab, bl):
    sub = img[bl["y"]:bl["y"] + bl["h"], bl["x"]:bl["x"] + bl["w"]].astype(np.int32)
    m = lab[bl["y"]:bl["y"] + bl["h"], bl["x"]:bl["x"] + bl["w"]] == bl["id"]
    px = sub[m]
    red = float(np.mean(px[:, 2] - np.maximum(px[:, 1], px[:, 0])))
    return ("red" if red > 45 else "black"), red


def blob_shape(lab, bl):
    m = (lab[bl["y"]:bl["y"] + bl["h"], bl["x"]:bl["x"] + bl["w"]] == bl["id"]).astype(np.uint8)
    cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    c = max(cnts, key=cv2.contourArea)
    area = cv2.contourArea(c)
    hull = cv2.convexHull(c)
    sol = area / max(1.0, cv2.contourArea(hull))
    (_, _), (rw, rh), _ = cv2.minAreaRect(c)
    ext = area / max(1.0, rw * rh)
    approx = cv2.approxPolyDP(hull, 0.06 * cv2.arcLength(hull, True), True)
    hi = cv2.convexHull(c, returnPoints=False)
    dd = 0.0
    try:
        df = cv2.convexityDefects(c, hi)
        if df is not None:
            dd = float(df.reshape(-1, 4)[:, 3].max()) / 256.0 / max(1.0, np.sqrt(area))
    except cv2.error:
        pass
    return dict(sol=round(sol, 3), ext=round(ext, 3), hullv=len(approx), defect=round(dd, 3))


def suit_from_shape(colour, f):
    if colour == "red":
        # diamond: convex, fills ~50-60% of min-area rect (rotated square rect ~1.0 though) -> use solidity
        # heart has a notch between its lobes -> deep convexity defect; diamond has none
        return "h" if f.get("defect", 0) > 0.07 else "d"
    return "c" if f["sol"] < 0.85 else "s"


def rotate(img, ang):
    h, w = img.shape[:2]
    M = cv2.getRotationMatrix2D((w / 2, h / 2), ang, 1.0)
    cos, sin = abs(M[0, 0]), abs(M[0, 1])
    nw, nh = int(h * sin + w * cos), int(h * cos + w * sin)
    M[0, 2] += nw / 2 - w / 2
    M[1, 2] += nh / 2 - h / 2
    return cv2.warpAffine(img, M, (nw, nh), borderValue=(255, 255, 255)), M


def make_crop(img, bl):
    s = max(bl["w"], bl["h"])
    m = int(0.25 * s)
    H, W = img.shape[:2]
    x0, y0 = max(0, bl["x"] - m), max(0, bl["y"] - m)
    x1, y1 = min(W, bl["x"] + bl["w"] + m), min(H, bl["y"] + bl["h"] + m)
    c = img[y0:y1, x0:x1]
    sc = 120.0 / s  # normalise glyph to ~120 px
    return cv2.resize(c, None, fx=sc, fy=sc, interpolation=cv2.INTER_CUBIC)


def rect_crops(img, lab, bl):
    """Deskew + de-squash: rotate so the blob's principal axis is vertical, stretch its short
    axis to ~0.75 of the long axis (undo foreshortening of bent/tilted cards). Returns
    [(equivalent CCW rotation angle, crop)] for both up/down orientations."""
    s = max(bl["w"], bl["h"])
    H, W = img.shape[:2]
    m = int(0.6 * s)
    x0, y0 = max(0, bl["x"] - m), max(0, bl["y"] - m)
    x1, y1 = min(W, bl["x"] + bl["w"] + m), min(H, bl["y"] + bl["h"] + m)
    sub = img[y0:y1, x0:x1]
    mk = (lab[y0:y1, x0:x1] == bl["id"]).astype(np.uint8) * 255
    ys, xs = np.nonzero(mk)
    if len(xs) < 10:
        return []
    pts = np.stack([xs - xs.mean(), ys - ys.mean()])
    ev, evec = np.linalg.eigh(np.cov(pts))
    u = evec[:, 1]  # principal axis (y-down image coords)
    phi = np.degrees(np.arctan2(u[1], u[0]))
    out = []
    for a in (90 + phi, 270 + phi):
        a = ((a + 180) % 360) - 180
        r, _ = rotate(sub, a)
        rm, _ = rotate(mk, a)
        rm = (rm > 127).astype(np.uint8)
        yy, xx = np.nonzero(rm)
        if len(xx) < 10:
            continue
        gx0, gx1, gy0, gy1 = xx.min(), xx.max(), yy.min(), yy.max()
        gh, gw = gy1 - gy0 + 1, gx1 - gx0 + 1
        pad = int(0.25 * gh)
        c = r[max(0, gy0 - pad):gy1 + pad, max(0, gx0 - pad):gx1 + pad]
        if c.size == 0:
            continue
        fx = max(1.0, 0.75 * gh / max(1, gw))
        sc = 120.0 / gh
        c = cv2.resize(c, None, fx=sc * fx, fy=sc, interpolation=cv2.INTER_CUBIC)
        out.append((round(a, 1), c))
    return out


def tile3(c):
    h, w = c.shape[:2]
    gap = np.full((h, max(4, w // 6), 3), 255, np.uint8)
    t = np.hstack([c, gap, c, gap, c])
    return cv2.copyMakeBorder(t, 30, 30, 30, 30, cv2.BORDER_CONSTANT, value=(255, 255, 255))


def parse_rank(text):
    s = text.strip().upper().replace(" ", "").rstrip(".,:;'")
    for k in (3, 2, 1):  # tiled 'QQQ' / '101010' / single
        if len(s) % k == 0 and len(s) >= k:
            part = s[: len(s) // k] if k > 1 else s
            if k > 1 and part * k != s:
                continue
            if part in RANKS:
                return part, "exact"
            if part in CONFUSE:
                return CONFUSE[part], "confusable"
    # tolerate partially-read tiles: majority of single chars
    if 1 <= len(s) <= 3 and len(set(s)) == 1 and s[0] in RANKS:
        return s[0], "exact"
    return None, None


def ocr(paths):
    res = {}
    env = dict(os.environ, VNREV=REV)
    for i in range(0, len(paths), 60):
        out = subprocess.run([BIN, LEVEL, "0", "1", "0"] + paths[i:i + 60], capture_output=True, text=True,
                             check=True, env=env).stdout
        for line in out.splitlines():
            d = json.loads(line)
            res[d["file"]] = d
    return res


def find_pip(img, lab, blobs, bl):
    """nearest same-colour blob 0.35-1.15x the glyph size within 1.8 glyph sizes."""
    s = max(bl["w"], bl["h"])
    colour = bl["colour"]
    best, bd = None, 1e9
    for b2 in blobs:
        if b2["id"] == bl["id"]:
            continue
        d = np.hypot(b2["cx"] - bl["cx"], b2["cy"] - bl["cy"])
        if (d < 1.8 * s and 0.35 * s < max(b2["w"], b2["h"]) < 1.15 * s and d < bd and b2["colour"] == colour
                and b2["inksol"] > bl["inksol"]):
            best, bd = b2, d
    return best


def pip_dir(bl, pip, ang):
    """Where is the pip relative to the glyph in the frame rotated CCW by ang degrees?
    'below' (upright reading), 'above' (glyph upside-down) or 'side' (glyph on its side)."""
    v = np.array([pip["cx"] - bl["cx"], pip["cy"] - bl["cy"]])
    th = np.deg2rad(ang)
    vy = -v[0] * np.sin(th) + v[1] * np.cos(th)
    n = np.linalg.norm(v) + 1e-6
    if vy > 0.6 * n:
        return "below"
    if vy < -0.6 * n:
        return "above"
    return "side"


def process(ph, labels, min_hero_frac=0.02, all_blobs_ocr=False):
    stem = ph[:-4]
    img = cv2.imread(os.path.join(DATA, ph))
    H, W = img.shape[:2]
    t0 = time.time()
    blobs, lab = find_blobs(img, 18, 420)
    for bl in blobs:
        bl["colour"], bl["redness"] = blob_colour(img, lab, bl)
        bl["size"] = max(bl["w"], bl["h"])
        m = (lab[bl["y"]:bl["y"] + bl["h"], bl["x"]:bl["x"] + bl["w"]] == bl["id"]).astype(np.uint8)
        hull = cv2.convexHull(cv2.findNonZero(m))
        bl["inksol"] = float(m.sum()) / max(1.0, cv2.contourArea(hull))  # ink pixels / hull area
    cands = []
    for bl in blobs:
        pip = find_pip(img, lab, blobs, bl)
        if pip is None and not all_blobs_ocr:
            continue
        if bl["size"] >= min_hero_frac * H:
            bl["area"] = "hero"
        elif bl["cy"] < 0.5 * H:
            bl["area"] = "board"
        elif all_blobs_ocr:
            bl["area"] = "other"
        else:
            continue
        bl["pip"] = pip
        bl["sibling"] = any(b2["id"] != bl["id"] and b2["colour"] == bl["colour"]
                            and 0.7 < b2["size"] / bl["size"] < 1.3
                            and np.hypot(b2["cx"] - bl["cx"], b2["cy"] - bl["cy"]) < 1.0 * bl["size"]
                            for b2 in blobs if pip is None or b2["id"] != pip["id"])
        cands.append(bl)
    t_cv = time.time() - t0
    os.makedirs(WORK, exist_ok=True)
    jobs = []
    for bl in cands:
        crop = make_crop(img, bl)
        for a in ANGLES:
            r, _ = rotate(crop, a) if a else (crop, None)
            p = os.path.join(WORK, f"{stem}_b{bl['id']}_a{a}.png")
            cv2.imwrite(p, tile3(r))
            jobs.append((bl, a, p))
        for k, (a, c) in enumerate(rect_crops(img, lab, bl)):
            p = os.path.join(WORK, f"{stem}_b{bl['id']}_r{k}.png")
            cv2.imwrite(p, tile3(c))
            jobs.append((bl, a, p))
    t1 = time.time()
    res = ocr([p for _, _, p in jobs]) if jobs else {}
    t_ocr = time.time() - t1
    ocr_ms = sum(d["ms"] for d in res.values())
    dets = []
    for bl in cands:
        score = Counter()
        texts = []
        for b_, a, p in jobs:
            if b_ is not bl:
                continue
            for o in res.get(p, {}).get("obs", []):
                r, kind = parse_rank(o["text"])
                if not r:
                    continue
                texts.append(f"{a}:{o['text']}")
                if r == "10" and not bl.get("sibling"):
                    continue
                w = o["conf"] * (1 if kind == "exact" else 0.5)
                pd = pip_dir(bl, bl["pip"], a) if bl["pip"] is not None else "below"
                if pd == "above":
                    # glyph upside-down in this frame: 6<->9 swap, other reads down-weighted
                    if r in ("6", "9"):
                        r = {"6": "9", "9": "6"}[r]
                    else:
                        w *= 0.5
                elif pd == "side":
                    w *= 0.2
                score[r] += w
        if not score:
            continue
        rank, sc = score.most_common(1)[0]
        suit, feats = "?", {}
        if bl["pip"] is not None:
            feats = blob_shape(lab, bl["pip"])
            suit = suit_from_shape(bl["colour"], feats)
        dets.append(dict(blob=bl["id"], pip=bl["pip"]["id"] if bl["pip"] is not None else None,
                         bbox=[bl["x"], bl["y"], bl["w"], bl["h"]], rank=rank, score=round(sc, 2), alt=dict(score.most_common(3)),
                         colour=bl["colour"], redness=round(bl["redness"], 1), suit=suit, feats=feats,
                         cx=bl["cx"], cy=bl["cy"], size=bl["size"], area=bl["area"], texts=texts[:10]))
    # suppression: (a) a blob used as the pip of a stronger glyph is not itself a glyph;
    # (b) a merged blob whose bbox contains a stronger glyph's centre is dropped.
    keep = []
    for d in dets:
        drop = False
        for e in dets:
            if e is d:
                continue
            if e["pip"] == d["blob"] and e["score"] >= d["score"]:
                drop = True
            x, y, w, h = d["bbox"]
            if e["size"] < d["size"] and x <= e["cx"] <= x + w and y <= e["cy"] <= y + h:
                drop = True
        d["suppressed"] = drop
        if not drop:
            keep.append(d)
    cards = defaultdict(lambda: dict(score=0.0, suits=Counter(), cols=Counter(), n=0))
    for d in keep:
        if d["area"] != "hero":
            continue
        e = cards[d["rank"]]
        e["score"] += d["score"]
        e["n"] += 1
        e["cols"][d["colour"]] += d["score"]
        if d["suit"] != "?":
            e["suits"][d["suit"]] += d["score"]
    hero = []
    for r, e in sorted(cards.items(), key=lambda kv: -kv[1]["score"]):
        col = e["cols"].most_common(1)[0][0]
        ok = "hd" if col == "red" else "cs"
        su = [s for s, _ in e["suits"].most_common() if s in ok]
        hero.append(dict(card=r + (su[0] if su else "?"), colour=col, score=round(e["score"], 2), blobs=e["n"]))
    board = [d for d in dets if d["area"] == "board"]
    an = img.copy()
    for bl in cands:
        cv2.rectangle(an, (bl["x"], bl["y"]), (bl["x"] + bl["w"], bl["y"] + bl["h"]), (0, 220, 0), 6)
    for d in dets:
        c = (0, 0, 255) if d["colour"] == "red" else (255, 60, 0)
        cv2.putText(an, f"{d['rank']}{d['suit']}", (int(d["cx"]) + 60, int(d["cy"])), cv2.FONT_HERSHEY_SIMPLEX,
                    4 if d["area"] == "hero" else 2, c, 10)
    cv2.imwrite(os.path.join(OUT, f"glyph_rev{REV}_{LEVEL}_{stem}.jpg"), cv2.resize(an, (1125, 1500)))
    for bl in cands:
        bl.pop("pip", None)
    return dict(hero=hero, dets=dets, board=board, n_blobs=len(blobs), n_cands=len(cands), n_crops=len(jobs),
                t_cv_s=round(t_cv, 2), t_ocr_wall_s=round(t_ocr, 1), ocr_ms_sum=round(ocr_ms),
                ocr_ms_per_crop=round(ocr_ms / max(1, len(jobs)), 1),
                truth=labels[ph]["hero"], board_truth=labels[ph].get("board"))


def main():
    labels = json.load(open(os.path.join(DATA, "labels.json")))
    out = {}
    for ph in sorted(k for k in labels if k.endswith(".jpg")):
        r = process(ph, labels)
        out[ph] = r
        print(ph, "truth", r["truth"], "pred", [(h["card"], h["score"]) for h in r["hero"][:4]],
              "board dets", [(d["rank"], d["colour"]) for d in r["board"]],
              f"blobs={r['n_blobs']} crops={r['n_crops']} cv={r['t_cv_s']}s ocr={r['t_ocr_wall_s']}s", flush=True)
    json.dump(out, open(os.path.join(OUT, f"glyph_rev{REV}_{LEVEL}.json"), "w"), indent=1, default=str)


if __name__ == "__main__":
    main()
