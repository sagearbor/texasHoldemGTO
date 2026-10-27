"""Synthetic training crops for a corner-index glyph classifier.

Classes: 13 ranks + 4 suits + 'bg' (18). Each sample is a 32x32 single-channel
"ink" crop (green channel, so red and black ink are both dark), centred on one
glyph in card-index context and normalised the same way the real-photo
pipeline normalises blob crops (see common.py: glyph_crop).

Nothing here touches the real card pixels: backgrounds come from
bg_patches.npy (built by bgbank.py from masked, card-free regions).

  python synth.py <bg_patches.npy> <out.npz> <n> [seed]
"""
import math
import os
import sys
from multiprocessing import Pool

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from common import CLASSES, RANK_LABEL, SUIT_CHAR, crop_from_mask

F = '/System/Library/Fonts/'
FS = F + 'Supplemental/'
RANK_FONTS = [
    (F + 'Times.ttc', 0), (F + 'Times.ttc', 1), (F + 'Times.ttc', 2),
    (FS + 'Times New Roman.ttf', 0), (FS + 'Times New Roman Bold.ttf', 0),
    (FS + 'Georgia.ttf', 0), (FS + 'Georgia Bold.ttf', 0),
    (FS + 'Baskerville.ttc', 0), (FS + 'Baskerville.ttc', 2), (FS + 'BigCaslon.ttf', 0),
    (FS + 'Bodoni 72.ttc', 0), (FS + 'Bodoni 72.ttc', 2), (FS + 'Didot.ttc', 0),
    (FS + 'Hoefler Text.ttc', 0), (FS + 'Iowan Old Style.ttc', 0), (F + 'Palatino.ttc', 0),
    (F + 'Palatino.ttc', 2), (F + 'NewYork.ttf', 0), (FS + 'Charter.ttc', 0),
    (FS + 'Cochin.ttc', 0), (FS + 'Athelas.ttc', 0), (F + 'ヒラギノ明朝 ProN.ttc', 0),
    (FS + 'Songti.ttc', 1), (FS + 'Courier New.ttf', 0), (FS + 'Courier New Bold.ttf', 0),
    (FS + 'AmericanTypewriter.ttc', 0),
    # sans
    (FS + 'Arial.ttf', 0), (FS + 'Arial Bold.ttf', 0), (FS + 'Arial Narrow.ttf', 0),
    (FS + 'Arial Black.ttf', 0), (F + 'Helvetica.ttc', 0), (F + 'Helvetica.ttc', 1),
    (F + 'HelveticaNeue.ttc', 0), (F + 'Avenir Next.ttc', 0), (F + 'Avenir Next.ttc', 2),
    (FS + 'Futura.ttc', 0), (FS + 'GillSans.ttc', 0), (F + 'Optima.ttc', 0),
    (F + 'SFNS.ttf', 0), (FS + 'DIN Alternate Bold.ttf', 0), (FS + 'DIN Condensed Bold.ttf', 0),
    (FS + 'Impact.ttf', 0), (F + 'Menlo.ttc', 0), (FS + 'Verdana.ttf', 0), (FS + 'Tahoma.ttf', 0),
]
SUIT_FONTS = [
    (F + 'Supplemental/Arial Unicode.ttf', 0), (F + 'Apple Symbols.ttf', 0), (F + 'Menlo.ttc', 0),
    (F + 'Menlo.ttc', 1), (FS + 'Arial.ttf', 0), (FS + 'Arial Black.ttf', 0), (FS + 'Arial Bold.ttf', 0),
    (FS + 'Times New Roman.ttf', 0), (FS + 'Times New Roman Bold.ttf', 0), (FS + 'Courier New.ttf', 0),
    (FS + 'Impact.ttf', 0), (F + 'ヒラギノ明朝 ProN.ttc', 0), (F + 'ヒラギノ角ゴシック W3.ttc', 0),
    (F + 'ヒラギノ角ゴシック W6.ttc', 0), (F + 'ヒラギノ角ゴシック W9.ttc', 0), (FS + 'Songti.ttc', 1),
    (FS + 'AppleGothic.ttf', 0), (FS + 'AppleMyungjo.ttf', 0), (F + 'SFNS.ttf', 0),
    (F + 'AppleSDGothicNeo.ttc', 0), (F + 'AppleSDGothicNeo.ttc', 6),
]
RANK_FONTS = [f for f in RANK_FONTS if os.path.exists(f[0])]
SUIT_FONTS = [f for f in SUIT_FONTS if os.path.exists(f[0])]
WORDS = 'the of Bryce Canyon this trail along process weathering formations Navajo Loop sunset point most famous hoodoos'.split()
_font_cache = {}


def font(spec, size):
    k = (spec, size)
    if k not in _font_cache:
        _font_cache[k] = ImageFont.truetype(spec[0], size, index=spec[1])
    return _font_cache[k]


def procedural_suit(s, size, rng):
    """Filled suit drawn from primitives (adds shape variety beyond fonts)."""
    S = size
    im = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(im)
    r = S * rng.uniform(0.23, 0.28)
    cx = S / 2
    if s == 'd':
        w = S * rng.uniform(0.3, 0.42)
        d.polygon([(cx, S * 0.05), (cx + w, S / 2), (cx, S * 0.95), (cx - w, S / 2)], fill=255)
    elif s == 'h':
        cy = S * 0.33
        d.ellipse([cx - 2 * r, cy - r, cx, cy + r], fill=255)
        d.ellipse([cx, cy - r, cx + 2 * r, cy + r], fill=255)
        d.polygon([(cx - 1.95 * r, cy + r * 0.3), (cx + 1.95 * r, cy + r * 0.3), (cx, S * 0.93)], fill=255)
    elif s == 's':
        cy = S * 0.58
        d.ellipse([cx - 2 * r, cy - r, cx, cy + r], fill=255)
        d.ellipse([cx, cy - r, cx + 2 * r, cy + r], fill=255)
        d.polygon([(cx - 1.95 * r, cy - r * 0.3), (cx + 1.95 * r, cy - r * 0.3), (cx, S * 0.05)], fill=255)
        d.polygon([(cx, cy), (cx - r * 0.7, S * 0.95), (cx + r * 0.7, S * 0.95)], fill=255)
    else:  # club
        rr = r * 0.95
        for (x, y) in [(cx, S * 0.27), (cx - 1.05 * rr, S * 0.55), (cx + 1.05 * rr, S * 0.55)]:
            d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=255)
        d.polygon([(cx, S * 0.45), (cx - r * 0.65, S * 0.95), (cx + r * 0.65, S * 0.95)], fill=255)
    return np.array(im)


def glyph_mask(cls, h, rng):
    """Binary-ish uint8 mask (0..255) of one glyph, roughly h px tall, tightly cropped."""
    if cls in SUIT_CHAR and rng.random() < 0.3:
        m = procedural_suit(cls, int(h * 1.1), rng)
    else:
        text = SUIT_CHAR.get(cls) or RANK_LABEL[cls]
        spec = SUIT_FONTS[rng.integers(len(SUIT_FONTS))] if cls in SUIT_CHAR else RANK_FONTS[rng.integers(len(RANK_FONTS))]
        f = font(spec, int(h * 1.35))
        im = Image.new('L', (int(h * 4), int(h * 3)), 0)
        d = ImageDraw.Draw(im)
        sw = int(rng.choice([0, 0, 0, 1, 2])) if h > 30 else 0
        d.text((h // 2, h // 3), text, font=f, fill=255, stroke_width=sw, stroke_fill=255)
        m = np.array(im)
    ys, xs = np.nonzero(m > 60)
    if len(ys) == 0:
        return None
    m = m[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    # Aspect jitter (condensed / extended faces), scale to target height.
    # Card decks often use condensed index faces (tall, narrow glyphs).
    sx = (rng.uniform(0.5, 0.8) if rng.random() < 0.4 else rng.uniform(0.75, 1.25)) * (0.75 if cls == 'T' and rng.random() < 0.5 else 1.0)
    nh = max(4, int(h))
    nw = max(3, int(m.shape[1] * nh / m.shape[0] * sx))
    return cv2.resize(m, (nw, nh), interpolation=cv2.INTER_AREA)


def paper(H, W, rng):
    base = np.array([rng.uniform(225, 255), rng.uniform(225, 255), rng.uniform(220, 255)])
    img = np.ones((H, W, 3), np.float32) * base
    img += rng.normal(0, rng.uniform(0.5, 4), (H, W, 1))
    return img


def ink_color(red, rng):
    if red:
        return np.array([rng.uniform(20, 80), rng.uniform(10, 60), rng.uniform(150, 230)])  # BGR
    v = rng.uniform(5, 60)
    return np.array([v, v, v]) + rng.uniform(-5, 5, 3)


def stamp(img, mask, x, y, color):
    H, W = img.shape[:2]
    h, w = mask.shape
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    a = mask[y0 - y:y1 - y, x0 - x:x1 - x, None].astype(np.float32) / 255
    img[y0:y1, x0:x1] = img[y0:y1, x0:x1] * (1 - a) + color * a


def bg_patch(bank, H, W, rng):
    p = bank[rng.integers(len(bank))]
    if rng.random() < 0.5:
        p = p[:, ::-1]
    return cv2.resize(p, (W, H)).astype(np.float32)


def scene(cls, bank, rng):
    """Card-index scene in a 160x160 canvas; returns (bgr float, target mask) where
    target mask marks the glyph to classify (None-target for 'bg')."""
    S = 160
    img = paper(S, S, rng)
    tgt = np.zeros((S, S), np.uint8)
    h = rng.uniform(30, 46)
    suits = 'cdhs'
    if cls == 'bg':
        kind = rng.integers(6)
        if kind == 0:  # pure table / hand / clutter
            img = bg_patch(bank, S, S, rng)
        elif kind == 1:  # body text letters on paper
            d_img = Image.new('L', (S, S), 0)
            dd = ImageDraw.Draw(d_img)
            spec = RANK_FONTS[rng.integers(len(RANK_FONTS))]
            f = font(spec, int(rng.uniform(14, 40)))
            y = rng.uniform(-10, 40)
            while y < S:
                dd.text((rng.uniform(-40, 10), y), ' '.join(rng.choice(WORDS, 4)), font=f, fill=255)
                y += f.size * 1.2
            stamp(img, np.array(d_img), 0, 0, ink_color(rng.random() < 0.2, rng))
        elif kind == 2:  # photo print edge on paper
            x0, y0 = int(rng.uniform(20, 120)), int(rng.uniform(20, 120))
            img[y0:, x0:] = bg_patch(bank, S - y0, S - x0, rng)
        elif kind == 3:  # card edge against table
            img = bg_patch(bank, S, S, rng)
            pts = np.int32([[rng.uniform(40, 120), 0], [S, 0], [S, S], [rng.uniform(40, 120), S]])
            m = np.zeros((S, S), np.uint8)
            cv2.fillPoly(m, [pts], 255)
            pp = paper(S, S, rng)
            img[m > 0] = pp[m > 0]
        elif kind == 4:  # random blobs / strokes on paper (shadows, dirt, fingers)
            for _ in range(rng.integers(1, 4)):
                c = ink_color(rng.random() < 0.4, rng) if rng.random() < 0.5 else np.array(rng.uniform(60, 200, 3))
                m = np.zeros((S, S), np.uint8)
                if rng.random() < 0.5:
                    cv2.ellipse(m, (int(rng.uniform(40, 120)), int(rng.uniform(40, 120))),
                                (int(rng.uniform(8, 40)), int(rng.uniform(8, 40))), rng.uniform(0, 180), 0, 360, 255, -1)
                else:
                    cv2.line(m, tuple(int(v) for v in rng.uniform(0, S, 2)), tuple(int(v) for v in rng.uniform(0, S, 2)),
                             255, int(rng.uniform(3, 14)))
                stamp(img, m, 0, 0, c)
        else:  # fragments of glyphs (cut off)
            g = glyph_mask(rng.choice(list(CLASSES[:-1])), h * rng.uniform(1.5, 3), rng)
            if g is not None:
                stamp(img, g, int(rng.uniform(-g.shape[1] * 0.8, S * 0.3)), int(rng.uniform(-g.shape[0] * 0.8, S * 0.3)),
                      ink_color(rng.random() < 0.5, rng))
        # crop-centre "target": somewhere in middle
        cx, cy = rng.uniform(60, 100, 2)
        hh = rng.uniform(16, 46)
        tgt[int(cy - hh / 2):int(cy + hh / 2), int(cx - hh * 0.35):int(cx + hh * 0.35)] = 255
        return img, tgt, True
    is_suit = cls in suits
    suit = cls if is_suit else suits[rng.integers(4)]
    red = suit in 'dh'
    col = ink_color(red, rng)
    rank = cls if not is_suit else CLASSES[rng.integers(13)]
    rm = glyph_mask(rank, h, rng)
    sm = glyph_mask(suit, h * rng.uniform(0.6, 1.0), rng)
    if rm is None or sm is None:
        return None
    cx = S / 2 + rng.uniform(-4, 4)
    gap = h * rng.uniform(0.05, 0.4)
    if is_suit:
        sy = int(S / 2 - sm.shape[0] / 2)
        ry = int(sy - gap - rm.shape[0])
    else:
        ry = int(S / 2 - rm.shape[0] / 2)
        sy = int(ry + rm.shape[0] + gap)
    rx = int(cx - rm.shape[1] / 2 + rng.uniform(-6, 6))
    sx = int(cx - sm.shape[1] / 2 + rng.uniform(-6, 6))
    # Card edge to the left / top (with table beyond), photo print to the right/below.
    if rng.random() < 0.6:
        edge = int(min(rx, sx) - rng.uniform(8, 30))
        if edge > 0:
            img[:, :edge] = bg_patch(bank, S, edge, rng)
    if rng.random() < 0.5:
        top = int(min(ry, sy) - rng.uniform(8, 30))
        if top > 0:
            img[:top] = bg_patch(bank, top, S, rng)
    if rng.random() < 0.4:
        px = int(max(rx + rm.shape[1], sx + sm.shape[1]) + rng.uniform(6, 30))
        py = int(rng.uniform(0, S))
        if px < S:
            img[py:, px:] = bg_patch(bank, S - py, S - px, rng)
    stamp(img, rm, rx, ry, col)
    stamp(img, sm, sx, sy, col)
    m = rm if not is_suit else sm
    x, y = (rx, ry) if not is_suit else (sx, sy)
    tgt[max(0, y):y + m.shape[0], max(0, x):x + m.shape[1]] = (m[max(0, -y):, max(0, -x):] > 100) * 255
    return img, tgt, False


def degrade(img, tgt, bank, rng):
    S = img.shape[0]
    # Geometric: perspective + rotation (residual after pair-based orientation).
    ang = rng.normal(0, 12) if rng.random() < 0.85 else rng.uniform(-40, 40)
    sc = rng.uniform(0.8, 1.15)
    M = cv2.getRotationMatrix2D((S / 2, S / 2), ang, sc)
    H = np.vstack([M, [0, 0, 1]])
    j = S * rng.uniform(0, 0.12)
    src = np.float32([[0, 0], [S, 0], [S, S], [0, S]])
    dst = src + rng.uniform(-j, j, (4, 2)).astype(np.float32)
    P = cv2.getPerspectiveTransform(src, dst) @ H
    border = bg_patch(bank, S, S, rng)
    img = cv2.warpPerspective(img, P, (S, S), borderMode=cv2.BORDER_REFLECT)
    tgt = cv2.warpPerspective(tgt, P, (S, S))
    # Lighting gradient + colour cast (warm indoor light) + shadow.
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) / S
    g = 1 + rng.uniform(-0.35, 0.35) * (xx - 0.5) + rng.uniform(-0.35, 0.35) * (yy - 0.5)
    img = img * g[..., None] * rng.uniform(0.55, 1.1)
    img = img * np.array([rng.uniform(0.7, 1.0), rng.uniform(0.85, 1.0), 1.0])
    if rng.random() < 0.25:  # cast shadow edge
        a, b = rng.uniform(-1, 1, 2)
        sh = ((xx - 0.5) * a + (yy - 0.5) * b + rng.uniform(-0.3, 0.3)) > 0
        img[sh] *= rng.uniform(0.5, 0.85)
    # Occlusion by a thumb / other card.
    if rng.random() < 0.2:
        m = np.zeros((S, S), np.uint8)
        side = rng.integers(4)
        c = [(0, S / 2), (S, S / 2), (S / 2, 0), (S / 2, S)][side]
        cv2.ellipse(m, (int(c[0] + rng.uniform(-30, 30)), int(c[1] + rng.uniform(-30, 30))),
                    (int(rng.uniform(30, 70)), int(rng.uniform(30, 70))), rng.uniform(0, 180), 0, 360, 255, -1)
        occ = bg_patch(bank, S, S, rng) if rng.random() < 0.5 else np.ones((S, S, 3), np.float32) * [
            rng.uniform(90, 160), rng.uniform(110, 170), rng.uniform(170, 230)]
        img[m > 0] = occ[m > 0]
        tgt = tgt.copy()
        tgt_vis = tgt.copy(); tgt_vis[m > 0] = 0
        if tgt.sum() > 0 and tgt_vis.sum() < 0.6 * tgt.sum():
            return None  # too occluded to keep its label
    img = np.clip(img, 0, 255).astype(np.uint8)
    # Resolution: shrink to the real glyph size range (12..60 px tall), blur, noise, JPEG.
    f = rng.uniform(0.3, 1.2)
    small = cv2.resize(img, None, fx=f, fy=f, interpolation=cv2.INTER_AREA)
    tsm = cv2.resize(tgt, (small.shape[1], small.shape[0]), interpolation=cv2.INTER_NEAREST)
    r = rng.random()
    if r < 0.35:
        k = rng.uniform(0.3, 2.5) * max(f, 0.4)
        small = cv2.GaussianBlur(small, (0, 0), k)
    elif r < 0.6:  # defocus disk
        rad = int(rng.integers(1, 5))
        disk = np.zeros((2 * rad + 1, 2 * rad + 1), np.float32)
        cv2.circle(disk, (rad, rad), rad, 1, -1)
        small = cv2.filter2D(small, -1, disk / disk.sum())
    elif r < 0.7:  # motion blur
        L = int(rng.integers(3, 9))
        k = np.zeros((L, L), np.float32)
        k[L // 2] = 1
        k = cv2.warpAffine(k, cv2.getRotationMatrix2D((L / 2, L / 2), rng.uniform(0, 180), 1), (L, L))
        small = cv2.filter2D(small, -1, k / max(k.sum(), 1e-3))
    small = np.clip(small + rng.normal(0, rng.uniform(1, 9), small.shape), 0, 255).astype(np.uint8)
    q = int(rng.uniform(25, 95))
    small = cv2.imdecode(cv2.imencode('.jpg', small, [cv2.IMWRITE_JPEG_QUALITY, q])[1], cv2.IMREAD_COLOR)
    return small, tsm


def sample(args):
    seed, bank_path = args
    rng = np.random.default_rng(seed)
    bank = _bank(bank_path)
    while True:
        ci = rng.integers(len(CLASSES)) if rng.random() < 0.85 else len(CLASSES) - 1
        cls = CLASSES[ci]
        s = scene(cls, bank, rng)
        if s is None:
            continue
        img, tgt, is_bg = s
        d = degrade(img, tgt, bank, rng)
        if d is None:
            continue
        small, tsm = d
        if tsm.sum() == 0:
            continue
        # Box jitter models imperfect blob segmentation (merged/split blobs).
        x = crop_from_mask(small, tsm > 0, jitter=rng.uniform(0, 0.18), rng=rng)
        if x is None:
            continue
        return x, ci


_BANK = {}


def _bank(p):
    if p not in _BANK:
        _BANK[p] = np.load(p)
    return _BANK[p]


def main():
    bank_path, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    seed0 = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    with Pool(10) as pool:
        res = pool.map(sample, [(seed0 * 10_000_000 + i, bank_path) for i in range(n)], chunksize=256)
    X = np.stack([r[0] for r in res])
    y = np.array([r[1] for r in res], np.int64)
    np.savez_compressed(out, X=X, y=y)
    print('wrote', out, X.shape, np.bincount(y, minlength=len(CLASSES)))


if __name__ == '__main__':
    main()
