"""Synthetic scenes for the card-corner detector (lib/camera/corner_detector.dart).

Whole playing cards (paper, rounded corners, corner indices at 2 or 4
corners, number-card pips, picture-card art) are rendered, fanned or laid
side by side like a hand held to peek, or in a row like a board, warped
into a real Watch still (felt, hands, chips, lights) with thumbs and
fingers over them, then lit, blurred, noised and JPEG-compressed.

Every corner index (rank over suit) gets: centre, height and width of the
rank+suit box, its "up" angle, rank, suit and how much of it is visible.
White-ish regions of the background still (real cards nobody labelled)
are returned as an ignore mask: the detector is neither rewarded nor
punished there.

  python render.py <bg_list.txt> <out_dir> <n> <seed>

bg_list.txt: one "<recording-tag> <jpg path>" per line (stills without
the owner's cards; EXIF orientation applied here).
Writes <out_dir>/scenes_<seed>.npz: det images (N, 288, 288, 3) BGR uint8
random 256x256 crops at detector scale, their targets, the background tag,
and index crops for the classifier (M, 32, 24, 3) with labels.
"""
import math
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'learned'))
from synth import glyph_mask, procedural_suit  # noqa: E402

RANKS = '23456789TJQKA'
SUITS = 'cdhs'
PX = 4  # card render pixels per mm
DET_SCALE = 0.4  # full-res (720 short side) -> detector input (288)
CROP_H, CROP_W = 32, 24  # classifier input (index-aligned)
CROP_SPAN_H, CROP_SPAN_W = 1.25, 0.95  # crop window in index heights

PIPS = {
    2: [(.5, .2), (.5, .8)],
    3: [(.5, .2), (.5, .5), (.5, .8)],
    4: [(.3, .2), (.7, .2), (.3, .8), (.7, .8)],
    5: [(.3, .2), (.7, .2), (.3, .8), (.7, .8), (.5, .5)],
    6: [(.3, .2), (.7, .2), (.3, .5), (.7, .5), (.3, .8), (.7, .8)],
    7: [(.3, .2), (.7, .2), (.3, .5), (.7, .5), (.3, .8), (.7, .8), (.5, .35)],
    8: [(.3, .2), (.7, .2), (.3, .5), (.7, .5), (.3, .8), (.7, .8), (.5, .35), (.5, .65)],
    9: [(.3, .2), (.7, .2), (.3, .4), (.7, .4), (.3, .6), (.7, .6), (.3, .8), (.7, .8), (.5, .5)],
    10: [(.3, .2), (.7, .2), (.3, .4), (.7, .4), (.3, .6), (.7, .6), (.3, .8), (.7, .8), (.5, .3), (.5, .7)],
}


def ink(red, rng):
    """BGR ink colour: black / grey, or red from bright to maroon and purple-ish."""
    if red:
        r = rng.uniform(100, 235)
        g = rng.uniform(10, 0.45 * r)
        b = rng.uniform(15, min(r * 0.75, 120)) if rng.random() < 0.3 else rng.uniform(15, 0.5 * r)
        return np.array([b, g, r], np.float32)
    v = rng.uniform(5, 75)
    return (np.array([v, v, v]) + rng.uniform(-6, 6, 3)).astype(np.float32)


def stamp(img, mask, x, y, color):
    H, W = img.shape[:2]
    h, w = mask.shape
    x, y = int(round(x)), int(round(y))
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    a = mask[y0 - y:y1 - y, x0 - x:x1 - x, None].astype(np.float32) / 255
    img[y0:y1, x0:x1] = img[y0:y1, x0:x1] * (1 - a) + color * a


def suit_mask(s, h, rng, procedural=None):
    if procedural if procedural is not None else rng.random() < 0.35:
        m = procedural_suit(s, int(h * 1.15), rng)
        ys, xs = np.nonzero(m > 60)
        m = m[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
        return cv2.resize(m, (max(3, int(m.shape[1] * h / m.shape[0])), max(3, int(h))), interpolation=cv2.INTER_AREA)
    return glyph_mask(s, h, rng)


def deck_style(rng):
    """One deck's look: shared by every card of a scene."""
    jumbo = rng.random() < 0.3
    return {
        'w': rng.choice([57.0, 63.0]),
        'rh': rng.uniform(0.16, 0.22) if jumbo else rng.uniform(0.085, 0.15),
        'sh': rng.uniform(0.55, 0.95),
        'gap': rng.uniform(-0.02, 0.18),
        'mx': rng.uniform(0.025, 0.08),
        'my': rng.uniform(0.025, 0.07),
        'four': rng.random() < 0.3,
        'paper': np.float32(rng.uniform(222, 252)) + rng.uniform(-6, 6, 3).astype(np.float32),
        'red': ink(True, rng),
        'black': ink(False, rng),
        'pip': rng.uniform(0.085, 0.13),
        'proc_suit': rng.random() < 0.35,
        'seed': int(rng.integers(1 << 30)),
    }


def render_card(rank, suit, st, rng):
    """Card image (BGR float), alpha, and its corner indices in card pixels:
    [(box corners TL,TR,BR,BL as 4x2, rank, suit)] with the box's 'up' along
    the first edge's normal (TL->BL is down)."""
    W, H = st['w'] * PX, 88.0 * PX
    cw, ch = int(W), int(H)
    img = np.ones((ch, cw, 3), np.float32) * st['paper']
    img += rng.normal(0, rng.uniform(0.5, 3), (ch, cw, 1))
    color = st['red'] if suit in 'dh' else st['black']
    # Same glyph shapes for the whole deck: seed the glyph rng per deck+card.
    grng = np.random.default_rng(st['seed'] + RANKS.index(rank) * 7 + SUITS.index(suit))
    rh = st['rh'] * H
    rm = glyph_mask(rank, rh, grng)
    sm = suit_mask(suit, rh * st['sh'], np.random.default_rng(st['seed'] + SUITS.index(suit)), st['proc_suit'])
    if rm is None or sm is None:
        return None
    gap = st['gap'] * rh
    iw = max(rm.shape[1], sm.shape[1])
    ih = rm.shape[0] + gap + sm.shape[0]
    ax = st['mx'] * W + iw / 2
    ay = st['my'] * H
    idx_img = np.zeros((int(math.ceil(ih)) + 2, iw + 2), np.uint8)
    stamp_mask(idx_img, rm, 1 + (iw - rm.shape[1]) / 2, 1)
    stamp_mask(idx_img, sm, 1 + (iw - sm.shape[1]) / 2, 1 + rm.shape[0] + gap)
    corners = []
    x0, y0 = ax - iw / 2 - 1, ay - 1
    placements = [(x0, y0, False)]
    placements.append((W - x0 - idx_img.shape[1], H - y0 - idx_img.shape[0], True))
    if st['four']:
        placements.append((W - x0 - idx_img.shape[1], y0, False))
        placements.append((x0, H - y0 - idx_img.shape[0], True))
    for (px, py, flip) in placements:
        m = idx_img[::-1, ::-1] if flip else idx_img
        stamp(img, m, px, py, color)
        bw, bh = m.shape[1], m.shape[0]
        box = np.float32([[px, py], [px + bw, py], [px + bw, py + bh], [px, py + bh]])
        if flip:
            box = box[[2, 3, 0, 1]]  # TL of the upside-down index is the card's BR
        corners.append((box, rank, suit))
    # Middle of the card.
    val = RANKS.index(rank) + 2
    if val <= 10:
        ph = st['pip'] * H
        pm = suit_mask(suit, ph, np.random.default_rng(st['seed'] + 100 + SUITS.index(suit)), st['proc_suit'])
        px_, py_ = rng.uniform(0.85, 1.15), rng.uniform(0.85, 1.05)
        if pm is not None:
            for (fx, fy) in PIPS[val]:
                m = pm[::-1, ::-1] if fy > 0.55 else pm
                cx, cy = (0.5 + (fx - 0.5) * 2 * px_) * W, (0.5 + (fy - 0.5) * 2 * py_) * H
                stamp(img, m, cx - m.shape[1] / 2, cy - m.shape[0] / 2, color)
    elif rank == 'A':
        ph = rng.uniform(0.2, 0.42) * H
        pm = suit_mask(suit, ph, rng)
        if pm is not None:
            stamp(img, pm, W / 2 - pm.shape[1] / 2, H / 2 - pm.shape[0] / 2, color)
    else:
        face_art(img, W, H, color, rng)
    # Rounded corners.
    alpha = np.zeros((ch, cw), np.uint8)
    r = int(rng.uniform(2.5, 4) * PX)
    cv2.rectangle(alpha, (r, 0), (cw - r, ch), 255, -1)
    cv2.rectangle(alpha, (0, r), (cw, ch - r), 255, -1)
    for (cx, cy) in [(r, r), (cw - r, r), (r, ch - r), (cw - r, ch - r)]:
        cv2.circle(alpha, (cx, cy), r, 255, -1, lineType=cv2.LINE_AA)
    if rng.random() < 0.5:  # edge line / shade
        edge = cv2.morphologyEx(alpha, cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8))
        img[edge > 0] *= rng.uniform(0.7, 0.95)
    return img, alpha, corners


def stamp_mask(dst, m, x, y):
    x, y = int(round(x)), int(round(y))
    h, w = m.shape
    h = min(h, dst.shape[0] - y)
    w = min(w, dst.shape[1] - x)
    if h > 0 and w > 0:
        dst[y:y + h, x:x + w] = np.maximum(dst[y:y + h, x:x + w], m[:h, :w])


def face_art(img, W, H, color, rng):
    x0, y0, x1, y1 = int(0.2 * W), int(0.16 * H), int(0.8 * W), int(0.84 * H)
    if rng.random() < 0.7:
        cv2.rectangle(img, (x0, y0), (x1, y1), tuple(float(c) for c in color), int(rng.uniform(1, 4)))
    pal = [np.array(c, np.float32) for c in [(40, 40, 200), (180, 60, 30), (40, 190, 230), (30, 30, 30), (200, 200, 200), (60, 140, 60)]]
    for _ in range(int(rng.integers(8, 30))):
        c = tuple(float(v) for v in pal[rng.integers(len(pal))] * rng.uniform(0.7, 1.1))
        p = (int(rng.uniform(x0, x1)), int(rng.uniform(y0, y1)))
        k = rng.integers(3)
        if k == 0:
            cv2.ellipse(img, p, (int(rng.uniform(3, 30)), int(rng.uniform(3, 30))), rng.uniform(0, 180), 0, 360, c, -1)
        elif k == 1:
            q = (int(rng.uniform(x0, x1)), int(rng.uniform(y0, y1)))
            cv2.line(img, p, q, c, int(rng.uniform(1, 6)))
        else:
            pts = np.int32([[rng.uniform(x0, x1), rng.uniform(y0, y1)] for _ in range(int(rng.integers(3, 6)))])
            cv2.fillPoly(img, [pts], c)


# ------------------------------------------------------------------ scene

def load_bg(path, rng):
    im = ImageOps.exif_transpose(Image.open(path)).convert('RGB')
    a = np.asarray(im)[:, :, ::-1].astype(np.float32)
    if rng.random() < 0.5:
        a = a[:, ::-1]
    return np.ascontiguousarray(a)


def card_regions(bgr):
    """White-ish (card-like) regions of a real still, generously dilated."""
    small = cv2.resize(bgr.astype(np.uint8), None, fx=0.25, fy=0.25, interpolation=cv2.INTER_AREA)
    hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
    white = cv2.inRange(hsv, (0, 0, 115), (180, 90, 255))
    white = cv2.morphologyEx(white, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    white = cv2.dilate(white, np.ones((15, 15), np.uint8))
    return cv2.resize(white, (bgr.shape[1], bgr.shape[0]), interpolation=cv2.INTER_NEAREST) > 0


def skin(rng):
    return np.array([rng.uniform(60, 150), rng.uniform(90, 175), rng.uniform(140, 235)], np.float32)


def add_blob(img, owner, oid, center, axes, angle, color, rng, soft=True):
    m = np.zeros(img.shape[:2], np.uint8)
    cv2.ellipse(m, (int(center[0]), int(center[1])), (max(2, int(axes[0])), max(2, int(axes[1]))), angle, 0, 360, 255, -1)
    if not m.any():
        return
    shade = 1 + 0.25 * (np.linspace(-1, 1, img.shape[1])[None, :] * rng.uniform(-1, 1))
    a = cv2.GaussianBlur(m, (0, 0), max(1.0, min(axes) * 0.08)).astype(np.float32)[:, :, None] / 255 if soft else (m[:, :, None] > 0)
    tex = color * shade[:, :, None] + rng.normal(0, 4, (1, 1, 3))
    img[:] = img * (1 - a) + tex * a
    owner[m > 127] = oid


def scene(bg_paths, rng):
    tag, path = bg_paths[rng.integers(len(bg_paths))]
    bg = load_bg(path, rng)
    if rng.random() < 0.15:  # the other orientation
        bg = np.ascontiguousarray(np.rot90(bg, 1 if rng.random() < 0.5 else 3))
    H, W = bg.shape[:2]
    s0 = 720.0 / min(H, W)
    if abs(s0 - 1) > 0.01:
        bg = cv2.resize(bg, (int(W * s0), int(H * s0)), interpolation=cv2.INTER_AREA)
        H, W = bg.shape[:2]
    ignore = card_regions(bg)
    img = bg.copy()
    owner = np.full((H, W), -1, np.int16)  # who is on top: card id, -2 skin, -1 table
    st = deck_style(rng)
    n = int(rng.choice([1, 2, 2, 2, 3, 4, 4, 4, 5]))
    mode = rng.choice(['fan', 'fan', 'fan', 'spread', 'row'])
    cards = []
    used = set()
    while len(cards) < n:
        c = (RANKS[rng.integers(13)], SUITS[rng.integers(4)])
        if c in used:
            continue
        used.add(c)
        rc = render_card(c[0], c[1], st, rng)
        if rc is not None:
            cards.append((c, rc))
    if not cards:
        return None
    cw, ch = cards[0][1][0].shape[1], cards[0][1][0].shape[0]
    idx_h_card = np.linalg.norm(cards[0][1][2][0][0][3] - cards[0][1][2][0][0][0])
    # Index height on screen: log-uniform 2..36% of the short side (the
    # owner's game-night peeks: up to ~30%, the phone low and close).
    target = 720 * math.exp(rng.uniform(math.log(0.02), math.log(0.36)))
    if mode == 'row':
        target = min(target, 720 * 0.08)
    s = target / idx_h_card
    G = rng.uniform(-70, 70) if mode != 'row' else rng.uniform(-15, 15)
    if rng.random() < 0.08:
        G += 180  # the far side of the table / upside down in hand
    cx, cy = rng.uniform(0.1, 0.9) * W, rng.uniform(0.1, 0.9) * H
    squash = rng.uniform(0.35, 0.8) if mode == 'row' else (rng.uniform(0.7, 1.0) if rng.random() < 0.4 else 1.0)
    shear = rng.uniform(-0.25, 0.25) if rng.random() < 0.4 else 0.0
    spread = rng.uniform(5, 24)
    dx = rng.uniform(0.18, 0.65) if mode == 'spread' else rng.uniform(1.05, 1.4)
    pivot_drop = rng.uniform(0.0, 0.45) * ch
    # Fingers behind the cards.
    group_mats = []
    for i in range(len(cards)):
        k = i - (len(cards) - 1) / 2
        if mode == 'fan':
            a = math.radians(k * spread)
            px, py = cw / 2, ch + pivot_drop
            R = np.float32([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]])
            T0 = np.float32([[1, 0, -px], [0, 1, -py], [0, 0, 1]])
            T1 = np.float32([[1, 0, px - cw / 2 + rng.uniform(-0.03, 0.03) * cw], [0, 1, py - ch / 2], [0, 0, 1]])
            Mi = T1 @ R @ T0
        else:
            a = math.radians(rng.uniform(-6, 6) if mode == 'spread' else rng.uniform(-3, 3))
            R = np.float32([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]])
            T0 = np.float32([[1, 0, -cw / 2], [0, 1, -ch / 2], [0, 0, 1]])
            T1 = np.float32([[1, 0, k * dx * cw], [0, 1, rng.uniform(-0.04, 0.04) * ch], [0, 0, 1]])
            Mi = T1 @ R @ T0
        group_mats.append(Mi)
    g = math.radians(G)
    Gm = np.float32([[math.cos(g), -math.sin(g), 0], [math.sin(g), math.cos(g), 0], [0, 0, 1]])
    S = np.float32([[s, shear * s, 0], [0, s * squash, 0], [0, 0, 1]])
    T = np.float32([[1, 0, cx], [0, 1, cy], [0, 0, 1]])
    persp = np.eye(3, dtype=np.float32)
    if rng.random() < 0.5:
        persp[2, 0] = rng.uniform(-1, 1) * 0.6 / (cw * s * 4)
        persp[2, 1] = rng.uniform(-1, 1) * 0.6 / (ch * s * 4)
    base = T @ Gm @ persp @ S
    hand_anchor = base @ np.float32([0, ch / 2 + pivot_drop * 0.6, 1])
    hand_anchor = hand_anchor[:2] / hand_anchor[2]
    if mode != 'row' and rng.random() < 0.8:
        for _ in range(int(rng.integers(1, 4))):
            col = skin(rng)
            add_blob(img, owner, -2, hand_anchor + rng.normal(0, 0.35, 2) * cw * s,
                     (cw * s * rng.uniform(0.25, 0.6), cw * s * rng.uniform(0.15, 0.3)), rng.uniform(0, 180), col, rng)
    indices = []
    for i, ((rank, suit), (cimg, calpha, corners)) in enumerate(cards):
        M = base @ group_mats[i]
        # Lighting on the card (shadow from the hand above).
        shade = np.clip(rng.uniform(0.75, 1.05) + rng.uniform(-0.2, 0.2) * np.linspace(-1, 1, cimg.shape[0])[:, None], 0.4, 1.2)
        cimg = cimg * shade[:, :, None]
        warped = cv2.warpPerspective(cimg, M, (W, H), flags=cv2.INTER_AREA if s < 1 else cv2.INTER_LINEAR)
        wa = cv2.warpPerspective(calpha, M, (W, H), flags=cv2.INTER_LINEAR).astype(np.float32)[:, :, None] / 255
        img[:] = img * (1 - wa) + warped * wa
        owner[wa[:, :, 0] > 0.5] = i
        for (box, r_, s_) in corners:
            pts = cv2.perspectiveTransform(box[None], M)[0]
            indices.append((i, pts, r_, s_))
    # Thumb / fingers in front.
    if mode != 'row' and rng.random() < 0.75:
        col = skin(rng)
        for _ in range(int(rng.integers(1, 3))):
            if rng.random() < 0.25 and indices:
                # Over (part of) an index.
                _, pts, _, _ = indices[rng.integers(len(indices))]
                c = pts.mean(0) + rng.normal(0, 1, 2) * np.linalg.norm(pts[3] - pts[0]) * 0.8
            else:
                c = hand_anchor + rng.normal(0, 0.3, 2) * cw * s
            add_blob(img, owner, -2, c, (cw * s * rng.uniform(0.2, 0.45), cw * s * rng.uniform(0.12, 0.22)),
                     rng.uniform(0, 180), col, rng)
    # Annotations.
    ann = []
    for (i, pts, r_, s_) in indices:
        poly = np.zeros((H, W), np.uint8)
        cv2.fillConvexPoly(poly, np.int32(np.round(pts)), 1)
        area_in = poly.sum()
        full_area = abs(cv2.contourArea(pts))
        if full_area < 4:
            continue
        vis = float((owner[poly > 0] == i).sum()) / full_area if area_in else 0.0
        top = (pts[0] + pts[1]) / 2
        bot = (pts[3] + pts[2]) / 2
        left = (pts[0] + pts[3]) / 2
        right = (pts[1] + pts[2]) / 2
        h = float(np.linalg.norm(top - bot))
        w = float(np.linalg.norm(right - left))
        up = top - bot
        ang = math.atan2(float(up[0]), float(-up[1]))  # 0 = upright, + clockwise
        c = pts.mean(0)
        ann.append((float(c[0]), float(c[1]), h, w, ang, RANKS.index(r_), SUITS.index(s_), min(1.0, vis)))
    # Photometric.
    img = photometric(img, rng)
    return img, ann, ignore & (owner == -1), tag


def photometric(img, rng):
    H, W = img.shape[:2]
    gx = np.linspace(-1, 1, W)[None, :] * rng.uniform(-0.3, 0.3)
    gy = np.linspace(-1, 1, H)[:, None] * rng.uniform(-0.3, 0.3)
    img = img * (rng.uniform(0.6, 1.25) + gx + gy)[:, :, None]
    img = img * np.array([rng.uniform(0.8, 1.05), rng.uniform(0.92, 1.05), rng.uniform(0.95, 1.2)], np.float32)
    img = np.clip(img, 0, 255)
    if rng.random() < 0.3:
        gamma = rng.uniform(0.75, 1.35)
        img = 255 * (img / 255) ** gamma
    if rng.random() < 0.75:
        sig = rng.uniform(0.4, 3.0) if rng.random() < 0.7 else rng.uniform(3.0, 6.0)
        img = cv2.GaussianBlur(img, (0, 0), sig)
    if rng.random() < 0.15:
        k = int(rng.integers(3, 11))
        ker = np.zeros((k, k), np.float32)
        ker[k // 2] = 1 / k
        R = cv2.getRotationMatrix2D((k / 2 - 0.5, k / 2 - 0.5), rng.uniform(0, 180), 1)
        ker = cv2.warpAffine(ker, R, (k, k))
        ker /= max(ker.sum(), 1e-6)
        img = cv2.filter2D(img, -1, ker)
    img = img + rng.normal(0, rng.uniform(0, 6), img.shape)
    img = np.clip(img, 0, 255).astype(np.uint8)
    q = int(rng.uniform(45, 92))
    ok, buf = cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, q])
    return cv2.imdecode(buf, cv2.IMREAD_COLOR)


# ------------------------------------------------------------------ crops

REF_SIZE = 48  # refiner input (square, image axes)
REF_SPAN = 2.0  # refiner window side in (detected) index heights


def sample_rot(img, cx, cy, sh, sw, ang, out_h, out_w):
    """out_h x out_w crop of the sh x sw window centred at (cx, cy) whose
    'up' is ang (radians, + clockwise). Bilinear samples on an n x n grid
    per output pixel, averaged, n = clamp(ceil(step / 1.5), 1, 4) for a
    source step of sh / out_h pixels: lib/camera/corner_detector.dart
    samples the same points."""
    step = sh / out_h
    n = int(min(4, max(1, math.ceil(step / 1.5))))
    ux, uy = math.sin(ang), -math.cos(ang)  # up
    rx, ry = -uy, ux  # right
    oh, ow = out_h * n, out_w * n
    ax, ay = sw / ow, sh / oh
    u = (np.arange(ow, dtype=np.float32) + 0.5 - ow / 2) * ax
    v = (np.arange(oh, dtype=np.float32) + 0.5 - oh / 2) * ay
    U, V = np.meshgrid(u, v)
    X = (cx + U * rx - V * ux - 0.5).astype(np.float32)
    Y = (cy + U * ry - V * uy - 0.5).astype(np.float32)
    big = cv2.remap(img, X, Y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    if n == 1:
        return big
    return big.reshape(out_h, n, out_w, n, 3).astype(np.float32).mean((1, 3)).round().astype(np.uint8)


def index_crop(img, cx, cy, h, ang, out_h=CROP_H, out_w=CROP_W):
    """Upright crop of the index centred at (cx, cy), height h, 'up' angle
    ang: CROP_SPAN_H h tall, CROP_SPAN_W h wide (IndexNet's input)."""
    return sample_rot(img, cx, cy, CROP_SPAN_H * h, CROP_SPAN_W * h, ang, out_h, out_w)


def ref_crop(img, cx, cy, h):
    """RefineNet's input: the square REF_SPAN h window around (cx, cy), image axes."""
    return sample_rot(img, cx, cy, REF_SPAN * h, REF_SPAN * h, 0.0, REF_SIZE, REF_SIZE)


def ref_target(cx, cy, h, a):
    """What RefineNet predicts for a window ref_crop(img, cx0, cy0, h0) of
    a true index (cx, cy, h, a): (dx, dy) / side, log(h / h0), sin a, cos a."""
    return lambda cx0, cy0, h0: (np.float32([(cx - cx0) / (REF_SPAN * h0), (cy - cy0) / (REF_SPAN * h0),
                                              math.log(h / h0), math.sin(a), math.cos(a)]))


def refine_samples(img, ann, rng):
    out = []
    for (cx, cy, h, w, ang, r, s, vis) in ann:
        if vis < 0.75 or h < 8:
            continue
        f = ref_target(cx, cy, h, ang)
        for _ in range(2):
            h0 = h * math.exp(rng.normal(-0.15, 0.25))
            cx0 = cx + rng.normal(0, 0.15) * h
            cy0 = cy + rng.normal(0, 0.15) * h
            out.append((ref_crop(img, cx0, cy0, h0), f(cx0, cy0, h0)))
    return out


def classifier_samples(img, ann, rng):
    """(crop, rank 0..12 or 13 = background, suit 0..3 or -1) samples."""
    out = []
    for (cx, cy, h, w, ang, r, s, vis) in ann:
        if h < 7:
            continue
        if vis >= 0.85:
            for _ in range(2):
                j = 0.12
                out.append((index_crop(img, cx + rng.normal(0, j) * h, cy + rng.normal(0, j) * h,
                                       h * math.exp(rng.normal(0, 0.12)), ang + rng.normal(0, 0.12)), r, s))
        elif vis < 0.45:
            out.append((index_crop(img, cx, cy, h, ang + rng.normal(0, 0.1)), 13, -1))
        # Off-centre: half an index away is not a read.
        if rng.random() < 0.5:
            d = rng.choice([-1, 1]) * rng.uniform(0.55, 0.9)
            ux, uy = math.sin(ang), -math.cos(ang)
            out.append((index_crop(img, cx + ux * d * h, cy + uy * d * h, h, ang), 13, -1))
    H, W = img.shape[:2]
    for _ in range(3):
        h = 720 * math.exp(rng.uniform(math.log(0.02), math.log(0.36)))
        out.append((index_crop(img, rng.uniform(0, W), rng.uniform(0, H), h, rng.uniform(-1.3, 1.3)), 13, -1))
    return out


def det_sample(img, ann, ignore, rng, size=256):
    """Random size x size crop at detector scale with targets."""
    small = cv2.resize(img, None, fx=DET_SCALE, fy=DET_SCALE, interpolation=cv2.INTER_AREA)
    ign = cv2.resize(ignore.astype(np.uint8), (small.shape[1], small.shape[0]), interpolation=cv2.INTER_NEAREST)
    H, W = small.shape[:2]
    # Prefer a crop that contains an index.
    vis = [a for a in ann if a[7] >= 0.6]
    if vis and rng.random() < 0.85:
        a = vis[rng.integers(len(vis))]
        x0 = int(np.clip(a[0] * DET_SCALE - rng.uniform(0.1, 0.9) * size, 0, W - size))
        y0 = int(np.clip(a[1] * DET_SCALE - rng.uniform(0.1, 0.9) * size, 0, H - size))
    else:
        x0, y0 = int(rng.integers(0, W - size + 1)), int(rng.integers(0, H - size + 1))
    crop = small[y0:y0 + size, x0:x0 + size]
    ig = ign[y0:y0 + size, x0:x0 + size]
    t = []
    for (cx, cy, h, w, ang, r, s, v) in ann:
        t.append((cx * DET_SCALE - x0, cy * DET_SCALE - y0, h * DET_SCALE, w * DET_SCALE, ang, r, s, v))
    return crop, ig, t


def main():
    bg_list, out_dir, n, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    os.makedirs(out_dir, exist_ok=True)
    bgs = [tuple(l.split(None, 1)) for l in open(bg_list).read().split('\n') if l.strip()]
    rng = np.random.default_rng(seed)
    det_imgs, det_ign, det_t, det_tag = [], [], [], []
    cls_x, cls_r, cls_s, cls_tag = [], [], [], []
    ref_x, ref_t, ref_tag = [], [], []
    tags = sorted({t for t, _ in bgs})
    made = 0
    while made < n:
        sc = scene(bgs, rng)
        if sc is None:
            continue
        img, ann, ignore, tag = sc
        for _ in range(1):
            c, ig, t = det_sample(img, ann, ignore, rng)
            det_imgs.append(c)
            det_ign.append(np.packbits(ig, axis=None))
            det_t.append(np.float32(t).reshape(-1, 8))
            det_tag.append(tags.index(tag))
        for (x, t) in refine_samples(img, ann, rng):
            ref_x.append(x)
            ref_t.append(t)
            ref_tag.append(tags.index(tag))
        for (x, r, s) in classifier_samples(img, ann, rng):
            cls_x.append(x)
            cls_r.append(r)
            cls_s.append(s)
            cls_tag.append(tags.index(tag))
        made += 1
    tl = np.zeros(len(det_t) + 1, np.int64)
    tl[1:] = np.cumsum([len(t) for t in det_t])
    np.savez_compressed(os.path.join(out_dir, f'scenes_{seed}.npz'),
                        det=np.stack(det_imgs), ign=np.stack(det_ign), t=np.concatenate(det_t) if tl[-1] else np.zeros((0, 8), np.float32),
                        toff=tl, dtag=np.int8(det_tag), tags=np.array(tags),
                        cx=np.stack(cls_x), cr=np.int8(cls_r), cs=np.int8(cls_s), ctag=np.int8(cls_tag),
                        rx=np.stack(ref_x), rt=np.stack(ref_t), rtag=np.int8(ref_tag))


if __name__ == '__main__':
    main()
