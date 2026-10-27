"""Classical (no learned weights) card reader for real phone photos.

Hero cards (the two held hole cards):
  1. paper mask   = low saturation & not dark (HSV), the card stock.
  2. ink mask     = adaptive threshold on min(B,G,R): darker than local mean.
                    min-channel makes both red and black ink dark.
  3. glyph blobs  = ink connected components of index size, mostly surrounded
                    by paper (rejects wood grain, skin, photo faces).
  4. index pairs  = two same-colour blobs of similar size about one glyph
                    apart (rank above suit). The rank->suit vector gives the
                    index orientation, so cards at any rotation (incl. the
                    upside-down bottom-right index) are rotated upright.
  5. classify     = normalised cross-correlation against glyph templates;
                    colour (red/black) gates the suit to {d,h} or {c,s}.
  6. aggregate    = group index reads by card code, keep the best two.

Board (community cards, far and blurry):
  each face-up card is a paper frame around a photo, so count rectangular
  non-paper holes enclosed by paper of board-card size. Colour from strongly
  red pixels in small enclosed holes (the index glyphs) next to each photo.

Only OpenCV/numpy primitives that exist in OpenCV Android/iOS (cvtColor,
inRange, adaptiveThreshold, connectedComponentsWithStats, floodFill,
warpAffine, minAreaRect, resize, GaussianBlur) or are trivial to port to Dart.
"""
import math

import cv2
import numpy as np

from glyphs import BLACK_SUITS, RED_SUITS, classify

PAPER_S_MAX = 62
PAPER_V_MIN = 90
RED_S_MIN = 110
BOARD_SOLIDITY = 0.75
BOARD_OPEN = 3
BOARD_VSTD_MIN = 12
BOARD_RED_FRAC = 0.01


def resize_w(img, w):
    if img.shape[1] == w:
        return img
    h = int(round(img.shape[0] * w / img.shape[1]))
    return cv2.resize(img, (w, h), interpolation=cv2.INTER_AREA)


def paper_mask(hsv):
    return ((hsv[..., 1] < PAPER_S_MAX) & (hsv[..., 2] > PAPER_V_MIN)).astype(np.uint8)


def redness(bgr_pixels):
    b, g, r = bgr_pixels[:, 0].astype(np.int16), bgr_pixels[:, 1].astype(np.int16), bgr_pixels[:, 2].astype(np.int16)
    return r - np.maximum(g, b)


# ---------------------------------------------------------------- hero glyphs

def find_glyph_blobs(img, paper=None, min_frac=0.016, max_frac=0.14):
    """Ink blobs of corner-index size that sit on card stock."""
    H, W = img.shape[:2]
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    if paper is None:
        paper = paper_mask(hsv)
    minc = img.min(axis=2)
    block = int(W * 0.03) | 1
    near_paper = cv2.dilate(paper, np.ones((int(W * 0.02) | 1,) * 2, np.uint8))
    # Red ink gets its own mask so a red glyph touching a dark edge (hand,
    # shadow, photo border) stays a separate blob.
    hue, sat, val = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    red_ink = (((hue <= 8) | (hue >= 166)) & (sat > RED_S_MIN) & (val > 60)).astype(np.uint8)
    dark = cv2.adaptiveThreshold(minc, 255, cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY_INV, block, 18)
    dark = (dark > 0) & (red_ink == 0)
    n1, lab1, st1, cen1 = cv2.connectedComponentsWithStats((red_ink & near_paper) * 255, connectivity=8)
    n2, lab2, st2, cen2 = cv2.connectedComponentsWithStats((dark & (near_paper > 0)).astype(np.uint8) * 255,
                                                           connectivity=8)
    lab = np.where(lab2 > 0, lab2 + n1, lab1).astype(np.int32)
    lab[(lab1 > 0)] = lab1[(lab1 > 0)]
    st = np.vstack([st1, st2])
    cen = np.vstack([cen1, cen2])
    n = n1 + n2
    skip = {0, n1}
    lo, hi = W * min_frac, W * max_frac
    blobs = []
    for i in range(1, n):
        if i in skip:
            continue
        x, y, w, h, a = st[i]
        md = max(w, h)
        if md < lo or md > hi or a < 0.12 * w * h or min(w, h) < 0.12 * md:
            continue
        pad = int(md * 0.3) + 2
        x0, y0, x1, y1 = max(0, x - pad), max(0, y - pad), min(W, x + w + pad), min(H, y + h + pad)
        sub_lab = lab[y0:y1, x0:x1]
        ring = sub_lab != i
        # Ring = expanded box minus the blob's own pixels and its own bbox core.
        core = np.zeros_like(ring)
        core[y - y0:y - y0 + h, x - x0:x - x0 + w] = True
        ring &= ~core
        if ring.sum() == 0:
            continue
        paper_frac = paper[y0:y1, x0:x1][ring].mean()
        if paper_frac < 0.5:
            continue
        m = (lab[y:y + h, x:x + w] == i)
        px_hsv = hsv[y:y + h, x:x + w][m]
        ring_paper = ring & (paper[y0:y1, x0:x1] > 0)
        paper_v = float(np.median(hsv[y0:y1, x0:x1][ring_paper][:, 2])) if ring_paper.any() else 255.0
        hue, sat, val = (float(np.median(px_hsv[:, k])) for k in range(3))
        # Ink purity: printed index ink is either clearly dark (black) or a
        # saturated pure red. Photo faces (orange rock, hue ~10) and caption
        # text (thin, grey at this scale) fail both tests.
        is_red = (hue <= 7 or hue >= 168) and sat > RED_S_MIN + 30
        is_black = val < 0.5 * paper_v and not is_red
        if not (is_red or is_black):
            continue
        red = 100.0 if is_red else 0.0
        blobs.append(dict(id=i, bbox=(x, y, w, h), c=np.array(cen[i]), md=md, area=a,
                          mask=(m.astype(np.uint8) * 255), red=red, hsv=(hue, sat, val), paper_v=paper_v,
                          paper_frac=float(paper_frac)))
    return blobs, lab


def upright_masks(blobs, lab, a, b):
    """Rotate blob a (rank) and blob b (suit) so the a->b vector points down."""
    d = b['c'] - a['c']
    phi = math.atan2(d[1], d[0])
    alpha = math.pi / 2 - phi
    ca, sa = math.cos(alpha), math.sin(alpha)
    out = []
    for blob in (a, b):
        x, y, w, h = blob['bbox']
        m = blob['mask']
        s = int(math.hypot(w, h)) + 4
        cx, cy = w / 2, h / 2
        M = np.float32([[ca, -sa, s / 2 - (ca * cx - sa * cy)],
                        [sa, ca, s / 2 - (sa * cx + ca * cy)]])
        out.append(cv2.warpAffine(m, M, (s, s), flags=cv2.INTER_LINEAR))
    return out, math.degrees(alpha)


# Residual rotations tried after aligning the index to the rank->suit vector.
# RANK_ROT_SEARCH rotates rank+suit jointly; SUIT_ROT_SEARCH re-rotates the
# suit alone (a compact symbol whose orientation the rank->suit vector
# estimates poorly when the rank glyph is slanted by perspective). On these
# photos a rank rotation search let 6/Q confusions win, the suit search fixed
# a heart read as a diamond -> defaults below (chosen in-sample, see results.md).
RANK_ROT_SEARCH = (0,)
SUIT_ROT_SEARCH = (-30, -20, -10, 0, 10, 20, 30)
ROT_SEARCH = (-30, -20, -10, 0, 10, 20, 30)  # for the rank-rotation variant
ROT_PENALTY = 0.002  # per degree


def classify_suit(mask, bank, allowed, search=SUIT_ROT_SEARCH):
    agg, best_mask = {}, {}
    for d in search:
        m = rotate_mask(mask, d)
        _, _, sc = classify(m, bank, 'suit', allowed)
        for k, v in sc.items():
            v -= ROT_PENALTY * abs(d)
            if v > agg.get(k, -9):
                agg[k], best_mask[k] = v, m
    if not agg:
        return None, -1.0, {}, mask
    b = max(agg, key=agg.get)
    return b, agg[b], agg, best_mask[b]


def rotate_mask(m, deg):
    if deg == 0:
        return m
    h, w = m.shape
    s = int(math.hypot(w, h)) + 2
    M = cv2.getRotationMatrix2D((w / 2, h / 2), deg, 1.0)
    M[0, 2] += (s - w) / 2
    M[1, 2] += (s - h) / 2
    return cv2.warpAffine(m, M, (s, s))


def read_indices(img, bank, min_frac=0.016, score_min=0.45, rot_search=RANK_ROT_SEARCH, exclude=None,
                 suit_search=SUIT_ROT_SEARCH):
    """All corner-index reads in the image.

    exclude: list of convex polygons (e.g. board-card areas) whose glyphs
    are ignored. Returns (reads, blobs, cands): reads = greedy non-
    overlapping best pairs; cands = every scored pair (for template harvest).
    """
    blobs, lab = find_glyph_blobs(img, min_frac=min_frac)
    if exclude:
        blobs = [b for b in blobs
                 if all(cv2.pointPolygonTest(p, (float(b['c'][0]), float(b['c'][1])), False) < 0 for p in exclude)]
    cands = []
    for i, a in enumerate(blobs):
        for j, b in enumerate(blobs):
            if i == j:
                continue
            ratio = a['md'] / b['md']
            if not 0.55 < ratio < 2.2:
                continue
            dist = np.linalg.norm(a['c'] - b['c'])
            mean_md = (a['md'] + b['md']) / 2
            if not 0.55 * mean_md < dist < 1.9 * mean_md:
                continue
            red_a, red_b = a['red'] > 35, b['red'] > 35
            if red_a != red_b:
                continue
            (rm0, sm0), rot = upright_masks(blobs, lab, a, b)
            # The rank->suit vector is only roughly the card axis (perspective,
            # bent cards), so optionally search a few residual rotations,
            # shared by rank and suit, with a small prior for the raw angle.
            best = None
            for dr in rot_search:
                rm, sm = rotate_mask(rm0, dr), rotate_mask(sm0, dr)
                r, rs, rsc = classify(rm, bank, 'rank')
                s, ss, ssc, sm = classify_suit(sm, bank, RED_SUITS if red_a else BLACK_SUITS, suit_search)
                if r is None or s is None:
                    continue
                jscore = 0.5 * (rs + ss) - ROT_PENALTY * abs(dr)
                if best is None or jscore > best[0]:
                    best = (jscore, r, rs, rm, s, ss, sm, rsc, ssc)
            if best is None:
                continue
            _, r, rs, rm, s, ss, sm, rsc, ssc = best
            cands.append(dict(code=r + s, score=0.5 * (rs + ss), rank_score=rs, suit_score=ss, i=i, j=j,
                              red=red_a, rot=rot, rank_mask=rm, suit_mask=sm, rank_scores=rsc,
                              suit_scores=ssc, center=(a['c'] + b['c']) / 2, rank_bbox=a['bbox'],
                              suit_bbox=b['bbox'], md=mean_md))
    # Greedy: each blob used once, best pairs first.
    cands.sort(key=lambda c: -c['score'])
    used, reads = set(), []
    for c in cands:
        if c['i'] in used or c['j'] in used or c['score'] < score_min:
            continue
        used.update((c['i'], c['j']))
        reads.append(c)
    # Size gate: index glyphs of the held cards are the biggest in the frame;
    # caption text and distant cards are much smaller.
    if reads:
        big = max(r['md'] for r in reads)
        reads = [r for r in reads if r['md'] > 0.45 * big]
    return reads, blobs, cands


def hero_from_reads(reads, k=2):
    by = {}
    for r in reads:
        by.setdefault(r['code'], []).append(r['score'])
    agg = {c: max(v) + 0.05 * (len(v) - 1) for c, v in by.items()}
    best = sorted(agg, key=lambda c: -agg[c])[:k]
    return best, agg


# ---------------------------------------------------------------------- board

def find_board(img, hero_reads=None, log=None):
    """Count face-up community cards by their framed photo holes.

    Returns list of dicts: rect (minAreaRect), box pts, colour ('red'/'black'/'?').
    """
    H, W = img.shape[:2]
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    paper = paper_mask(hsv)
    paper = cv2.morphologyEx(paper, cv2.MORPH_OPEN, np.ones((BOARD_OPEN, BOARD_OPEN), np.uint8))
    inv = cv2.copyMakeBorder((1 - paper) * 255, 1, 1, 1, 1, cv2.BORDER_CONSTANT, value=255)
    ff = inv.copy()
    cv2.floodFill(ff, np.zeros((ff.shape[0] + 2, ff.shape[1] + 2), np.uint8), (0, 0), 128)
    holes = (ff == 255)[1:-1, 1:-1].astype(np.uint8)
    n, lab, st, cen = cv2.connectedComponentsWithStats(holes, connectivity=4)
    img_area = H * W
    hero_top = None
    if hero_reads:
        hero_top = min(r['center'][1] - 1.5 * r['md'] for r in hero_reads)
    cards = []
    for i in range(1, n):
        x, y, w, h, a = st[i]
        if not 0.0002 * img_area < a < 0.006 * img_area:
            continue
        cnt, _ = cv2.findContours((lab[y:y + h, x:x + w] == i).astype(np.uint8), cv2.RETR_EXTERNAL,
                                  cv2.CHAIN_APPROX_SIMPLE)
        cnt = max(cnt, key=cv2.contourArea) + np.array([x, y])
        x0, y0 = max(0, x - 6), max(0, y - 6)
        x1, y1 = min(W, x + w + 6), min(H, y + h + 6)
        rect = cv2.minAreaRect(cnt)
        (rw, rh) = rect[1]
        if rw * rh <= 0:
            continue
        # Perspective turns the photo rectangle into a parallelogram, so use
        # convex-hull solidity rather than min-area-rect fill.
        hull_a = cv2.contourArea(cv2.convexHull(cnt))
        # Pale photo regions (sky) leave paper islands inside the hole; judge
        # the outline (filled contour), not the raw pixel count.
        fill = cv2.contourArea(cnt) / max(hull_a, 1.0)
        aspect = max(rw, rh) / max(1e-6, min(rw, rh))
        if fill < BOARD_SOLIDITY or aspect > 4.0:
            _log(log, i, a, cen[i], 'shape fill=%.2f asp=%.2f' % (fill, aspect))
            continue
        # The frame must be card stock all around: sample a ring outside the hole.
        ring = cv2.dilate((lab[y0:y1, x0:x1] == i).astype(np.uint8), np.ones((9, 9), np.uint8))
        ring_px = ring.astype(bool) & (lab[y0:y1, x0:x1] != i)
        frame_paper = paper[y0:y1, x0:x1][ring_px].mean() if ring_px.any() else 0
        if frame_paper < 0.8:
            _log(log, i, a, cen[i], 'frame=%.2f' % frame_paper)
            continue
        # A solid red/black index glyph of a held card is also an enclosed
        # hole; a photo is not a single flat ink colour.
        hp = hsv[y:y + h, x:x + w][lab[y:y + h, x:x + w] == i]
        red_ink = ((hp[:, 0] <= 8) | (hp[:, 0] >= 166)) & (hp[:, 1] > RED_S_MIN)
        dark_ink = hp[:, 2] < 60
        if max(red_ink.mean(), dark_ink.mean()) > 0.7:
            _log(log, i, a, cen[i], 'flat ink')
            continue
        # Card faces are colour photos; holes in the carved grey table runner
        # or between dark objects are unsaturated.
        if np.median(hp[:, 1]) < 60:
            _log(log, i, a, cen[i], 'grey S=%d' % np.median(hp[:, 1]))
            continue
        # A photo is textured even when blurred; an enclosed index glyph of a
        # held card (e.g. the loop of a pale red 6) is one flat tone.
        if hp[:, 2].std() < BOARD_VSTD_MIN:
            _log(log, i, a, cen[i], 'flat tone')
            continue
        # Board cards lie on the table beyond the held cards (higher in frame).
        if hero_top is not None and cen[i][1] > hero_top:
            _log(log, i, a, cen[i], 'below hero')
            continue
        cards.append(dict(id=i, rect=rect, box=cv2.boxPoints(rect), area=a, center=np.array(cen[i]),
                          fill=fill, aspect=aspect, hull=cv2.convexHull(cnt),
                          vstd=float(hp[:, 2].std()), hstd=float(np.minimum(hp[:, 0], 180 - hp[:, 0]).std()),
                          smed=float(np.median(hp[:, 1]))))
    # Board cards form one row of near-equal photos: keep the dominant size cluster.
    if len(cards) > 1:
        med = np.median([c['area'] for c in cards])
        cards = [c for c in cards if 0.35 * med < c['area'] < 2.8 * med]
    big_ids = [i for i in range(1, n) if st[i][4] > 0.25 * min([c['area'] for c in cards] or [0])]
    big_holes = np.isin(lab, big_ids).astype(np.uint8) if cards else None
    for c in cards:
        c['colour'], c['red_px'], c['dark_px'] = board_colour(img, hsv, paper, lab, c, big_holes, [tuple(o['rect'][0]) for o in cards])
        c['zone'] = c.pop('_zone', None)
    cards.sort(key=lambda c: c['center'][0])
    return cards


def _log(log, i, a, c, why):
    if log is not None:
        log.append((int(c[0]), int(c[1]), int(a), why))


def board_colour(img, hsv, paper, lab, card, big_holes, centers):
    """Red/black from the blurred index on the card's white frame.

    Board indices are out of focus: a red index becomes a pink/red smudge on
    bright paper. The frame region of a card = card stock (paper, closed to
    swallow the smudges) that is outside every photo and closer to this
    card's photo than to any other (cards overlap/touch). Caption text is
    black on every card, so only red smudges are informative: red if enough
    pure-red-hued pixels, else black.
    """
    H, W = paper.shape
    (cx, cy), (rw, rh), ang = card['rect']
    R = 1.0 * max(rw, rh)
    x0, x1 = int(max(0, cx - R)), int(min(W, cx + R))
    y0, y1 = int(max(0, cy - R)), int(min(H, cy + R))
    yy, xx = np.mgrid[y0:y1, x0:x1]
    d_self = np.hypot(xx - cx, yy - cy)
    nearest = np.ones_like(d_self, bool)
    for (ox, oy) in centers:
        if (ox, oy) == (cx, cy):
            continue
        nearest &= d_self <= np.hypot(xx - ox, yy - oy)
    # card stock = paper plus the small enclosed non-paper blobs on it
    # (index smudges, caption text); big enclosed blobs are photos.
    stock = paper[y0:y1, x0:x1] | ((lab[y0:y1, x0:x1] > 0) & (big_holes[y0:y1, x0:x1] == 0))
    photos = cv2.dilate(big_holes[y0:y1, x0:x1], np.ones((5, 5), np.uint8))
    sel = (d_self < R) & nearest & (stock > 0) & (photos == 0)
    full = np.zeros(paper.shape, bool)
    full[y0:y1, x0:x1] = sel
    card['_zone'] = full
    hp = hsv[y0:y1, x0:x1][sel]
    if len(hp) == 0:
        return '?', 0, 0
    pv = float(np.median(hp[:, 2]))
    h, sat, v = hp[:, 0].astype(int), hp[:, 1].astype(int), hp[:, 2].astype(int)
    red_px = int((((h <= 8) | (h >= 165)) & (sat > 80) & (v > 0.75 * pv)).sum())
    dark_px = int(((v < 0.75 * pv) & (sat < 70)).sum())
    return ('red' if red_px >= max(4, BOARD_RED_FRAC * card['area']) else 'black'), red_px, dark_px
