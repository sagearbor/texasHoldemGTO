"""Camera feasibility lab: synthetic low-angle table photos + classical CV.

Renders a table seen from a phone propped at the edge (sharp angle): five
community cards in the background, the hero's two hole cards bent up close
to the lens. Then tries to find and read every card with OpenCV (white-card
contours -> perspective warp -> corner-index template match).

This is a shallow feasibility check on synthetic images, not a product:
real cards use different fonts/designs and real lighting is messier, so a
shipped version would want a trained detector. See tmp/camera-lab/ output.

Run (needs opencv-python-headless, numpy, pillow):
  python tool/camera_lab/card_lab.py --scenes 20 --out tmp/camera-lab
"""
import argparse
import os
import random

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

RANKS = '23456789TJQKA'
SUITS = 'cdhs'
SUIT_SYM = {'c': '♣', 'd': '♦', 'h': '♥', 's': '♠'}
RED = {'d', 'h'}
CW, CH = 250, 350  # canonical card size (5:7)
FONT = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf'


def font(size):
    return ImageFont.truetype(FONT, size) if os.path.exists(FONT) else ImageFont.load_default()


def render_card(code):
    r, s = code[0], code[1]
    col = (200, 30, 45) if s in RED else (20, 20, 20)
    im = Image.new('RGB', (CW, CH), (250, 249, 245))
    d = ImageDraw.Draw(im)
    label = '10' if r == 'T' else r
    for flip in (False, True):
        layer = Image.new('RGBA', (CW, CH), (0, 0, 0, 0))
        dl = ImageDraw.Draw(layer)
        dl.text((30, 12), label, font=font(56), fill=col, anchor='ma')
        dl.text((30, 74), SUIT_SYM[s], font=font(46), fill=col, anchor='ma')
        if flip:
            layer = layer.rotate(180)
        im.paste(layer, (0, 0), layer)
    d.text((CW / 2, CH / 2), SUIT_SYM[s], font=font(120), fill=col, anchor='mm')
    return np.array(im)[:, :, ::-1].copy()  # BGR


def felt(w, h, rng):
    base = np.zeros((h, w, 3), np.uint8)
    base[:] = (40, 95, 35)
    noise = rng.normal(0, 7, (h, w, 1)).astype(np.int16)
    img = np.clip(base.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    return cv2.GaussianBlur(img, (3, 3), 0)


def paste_warped(dst, card, quad):
    h, w = dst.shape[:2]
    src = np.float32([[0, 0], [CW, 0], [CW, CH], [0, CH]])
    M = cv2.getPerspectiveTransform(src, np.float32(quad))
    warped = cv2.warpPerspective(card, M, (w, h))
    mask = cv2.warpPerspective(np.full((CH, CW), 255, np.uint8), M, (w, h))
    dst[mask > 0] = warped[mask > 0]


def make_scene(rng, pyrng, scale=1.0):
    W, H = int(1280 * scale), int(720 * scale)
    deck = [r + s for r in RANKS for s in SUITS]
    pyrng.shuffle(deck)
    hero, board = deck[:2], deck[2:7]
    img = felt(W, H, rng)
    # Table plane (top-down units) -> image: far edge squeezed = low camera.
    plane = np.float32([[0, 0], [1600, 0], [1600, 1200], [0, 1200]])
    view = np.float32([[430, 150], [850, 150], [1700, 760], [-420, 760]]) * scale
    T = cv2.getPerspectiveTransform(plane, view)
    for i, code in enumerate(board):
        x0 = 520 + i * 120 + pyrng.uniform(-6, 6)
        y0 = 260 + pyrng.uniform(-8, 8)
        rect = np.float32([[x0, y0], [x0 + 100, y0], [x0 + 100, y0 + 140], [x0, y0 + 140]])
        quad = cv2.perspectiveTransform(rect[None], T)[0]
        paste_warped(img, render_card(code), quad)
    # Hole cards: bent up toward the lens, so nearly frontal and large,
    # slightly fanned the way people peek.
    cx = W / 2 + pyrng.uniform(-120, 120) * scale
    for k, code in enumerate(hero):
        w, h = (150 + pyrng.uniform(-10, 10)) * scale, 205 * scale
        ox = cx + (k - 0.5) * (w * 0.95)
        oy = H - (230 + pyrng.uniform(-10, 10)) * scale
        tilt = pyrng.uniform(-0.12, 0.12)
        top_narrow = w * 0.08
        quad = np.float32([[ox - w / 2 + top_narrow, oy], [ox + w / 2 - top_narrow, oy],
                           [ox + w / 2, oy + h], [ox - w / 2, oy + h]])
        c = quad.mean(0)
        R = np.array([[np.cos(tilt), -np.sin(tilt)], [np.sin(tilt), np.cos(tilt)]])
        quad = (quad - c) @ R.T + c
        paste_warped(img, render_card(code), quad)
    # Lighting gradient, blur and sensor noise.
    grad = np.linspace(0.75, 1.05, W)[None, :, None]
    img = np.clip(img * grad, 0, 255).astype(np.uint8)
    img = cv2.GaussianBlur(img, (3, 3), 0.8)
    img = np.clip(img + rng.normal(0, 4, img.shape), 0, 255).astype(np.uint8)
    return img, hero, board


# ---- detection ---------------------------------------------------------------

GLYPH = (40, 48)  # normalised glyph size (w, h)


def corner_glyphs(card_bgr):
    """Rank and suit glyphs from a card's top-left index, found as ink blobs
    so a few pixels of misalignment don't matter. Returns (rank, suit) masks."""
    region = card_bgr[0:150, 0:95]
    b = binarize(region)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(b)
    blobs = [i for i in range(1, n)
             if stats[i, cv2.CC_STAT_AREA] > 25 and stats[i, cv2.CC_STAT_HEIGHT] > 8
             and stats[i, cv2.CC_STAT_WIDTH] < 80 and stats[i, cv2.CC_STAT_HEIGHT] < 80]
    if len(blobs) < 2:
        return None
    blobs.sort(key=lambda i: stats[i, cv2.CC_STAT_TOP])
    # Merge blobs whose tops are close (the "1" and "0" of "10").
    rows = [[blobs[0]]]
    for i in blobs[1:]:
        if abs(stats[i, cv2.CC_STAT_TOP] - stats[rows[-1][0], cv2.CC_STAT_TOP]) < 12:
            rows[-1].append(i)
        else:
            rows.append([i])
    if len(rows) < 2:
        return None

    def crop(ids):
        x0 = min(stats[i, cv2.CC_STAT_LEFT] for i in ids)
        y0 = min(stats[i, cv2.CC_STAT_TOP] for i in ids)
        x1 = max(stats[i, cv2.CC_STAT_LEFT] + stats[i, cv2.CC_STAT_WIDTH] for i in ids)
        y1 = max(stats[i, cv2.CC_STAT_TOP] + stats[i, cv2.CC_STAT_HEIGHT] for i in ids)
        m = np.isin(lab[y0:y1, x0:x1], ids).astype(np.uint8) * 255
        return cv2.resize(m, GLYPH, interpolation=cv2.INTER_AREA), region[y0:y1, x0:x1]

    return crop(rows[0]), crop(rows[1])


def templates():
    ranks, suits = {}, {}
    for r in RANKS:
        ranks[r] = corner_glyphs(render_card(r + 's'))[0][0]
    for su in SUITS:
        suits[su] = corner_glyphs(render_card('A' + su))[1][0]
    return ranks, suits


def similarity(a, b):
    a, b = a.astype(np.float32) / 255, b.astype(np.float32) / 255
    return float((a * b).sum() / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-6))


def binarize(bgr):
    g = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    _, b = cv2.threshold(g, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    return b


def order(pts):
    s, d = pts.sum(1), np.diff(pts, axis=1).ravel()
    return np.float32([pts[np.argmin(s)], pts[np.argmin(d)], pts[np.argmax(s)], pts[np.argmax(d)]])


def find_cards(img):
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    white = cv2.inRange(hsv, (0, 0, 150), (180, 60, 255))
    white = cv2.morphologyEx(white, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    cnts, _ = cv2.findContours(white, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    quads = []
    for c in cnts:
        if cv2.contourArea(c) < 600:
            continue
        hull = cv2.convexHull(c)
        approx = cv2.approxPolyDP(hull, 0.02 * cv2.arcLength(hull, True), True)
        if len(approx) == 4:
            quads.append(order(approx.reshape(4, 2).astype(np.float32)))
        else:
            quads.append(order(cv2.boxPoints(cv2.minAreaRect(hull)).astype(np.float32)))
    return quads


def edge_len(a, b):
    return float(np.linalg.norm(a - b))


def split_quad(q, n):
    """Cuts a quad (tl, tr, br, bl) into n side-by-side quads."""
    tl, tr, br, bl = q
    out = []
    for k in range(n):
        a, b = k / n, (k + 1) / n
        out.append(np.float32([tl + (tr - tl) * a, tl + (tr - tl) * b,
                               bl + (br - bl) * b, bl + (br - bl) * a]))
    return out


def split_merged(quads, H):
    """Touching cards come out as one wide quad. Near (hole) cards are seen
    almost face-on, so expect a 5:7 aspect; far (board) cards are compared
    with the narrowest board quad."""
    near = [q for q in quads if q[:, 1].mean() > H * 0.55]
    far = [q for q in quads if q[:, 1].mean() <= H * 0.55]
    out = []
    for q in near:
        w, h = edge_len(q[0], q[1]), edge_len(q[0], q[3])
        out += split_quad(q, max(1, round(w / (h * 0.73))))
    if far:
        ref = min(edge_len(q[0], q[1]) for q in far)
        for q in far:
            out += split_quad(q, max(1, round(edge_len(q[0], q[1]) / ref)))
    return out


def read_card(img, quad, T_r, T_s):
    best = (-1, None)
    for rot in range(4):
        q = np.roll(quad, rot, axis=0)
        M = cv2.getPerspectiveTransform(q, np.float32([[0, 0], [CW, 0], [CW, CH], [0, CH]]))
        card = cv2.warpPerspective(img, M, (CW, CH))
        g = corner_glyphs(card)
        if g is None:
            continue
        (rank_m, _), (suit_m, suit_px) = g
        rs = {r: similarity(rank_m, t) for r, t in T_r.items()}
        r = max(rs, key=rs.get)
        hsv = cv2.cvtColor(suit_px, cv2.COLOR_BGR2HSV)
        red = (cv2.inRange(hsv, (0, 70, 50), (12, 255, 255)) | cv2.inRange(hsv, (165, 70, 50), (180, 255, 255))).mean() > 8
        ss = {su: similarity(suit_m, T_s[su]) for su in ('dh' if red else 'cs')}
        su = max(ss, key=ss.get)
        score = rs[r] + ss[su]
        if score > best[0]:
            best = (score, r + su)
    return best[1] or '??', best[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--scenes', type=int, default=20)
    ap.add_argument('--out', default='tmp/camera-lab')
    ap.add_argument('--scale', type=float, default=1.5, help='1 = 720p, 1.5 = 1080p, 3 = 4K')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    T_r, T_s = templates()
    hero_ok = board_ok = hero_n = board_n = 0
    for i in range(a.scenes):
        rng, pyrng = np.random.default_rng(i), random.Random(i)
        img, hero, board = make_scene(rng, pyrng, a.scale)
        H = img.shape[0]
        reads = []
        for q in split_merged(find_cards(img), H):
            code, score = read_card(img, q, T_r, T_s)
            near = q[:, 1].mean() > H * 0.55
            reads.append((near, code, score, q))
        got_hero = sorted(c for n, c, _, _ in reads if n)
        got_board = sorted(c for n, c, _, _ in reads if not n)
        hero_ok += sum(1 for c in hero if c in got_hero)
        board_ok += sum(1 for c in board if c in got_board)
        hero_n += 2
        board_n += 5
        vis = img.copy()
        for near, code, score, q in reads:
            ok = code in (hero if near else board)
            cv2.polylines(vis, [q.astype(np.int32)], True, (0, 220, 0) if ok else (0, 0, 255), 2)
            cv2.putText(vis, code, tuple(q[0].astype(int) + [0, -6]), cv2.FONT_HERSHEY_SIMPLEX,
                        0.7 * a.scale, (0, 255, 255), 2)
        cv2.imwrite(os.path.join(a.out, f'scene{i:02d}.jpg'), vis)
        print(f'scene {i:02d}: hero {sorted(hero)} -> {got_hero} | board {sorted(board)} -> {got_board}')
    print(f'\nHole cards read correctly: {hero_ok}/{hero_n} ({100 * hero_ok / hero_n:.0f}%)')
    print(f'Board cards read correctly: {board_ok}/{board_n} ({100 * board_ok / board_n:.0f}%)')


if __name__ == '__main__':
    main()
