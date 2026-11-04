"""Any-deck synthetic training crops for the glyph CNN.

Extends tool/camera_lab/real/learned/synth.py (same 18 classes, same 32x32
crop normalisation, same degradations) with what non-standard decks do:
  * ~320 font faces (system + freely licensed, see fonts.py), condensed /
    extended, bold / light, serif / sans / slab / mono / hand-drawn;
  * index printed on ARTWORK instead of white card stock: procedural
    paintings, landscapes, illustrations, stripes, wood (art.py), on cream
    or tinted stock, with or without a light plate or halo behind the
    index;
  * ink colours beyond pure black / red (navy, brown, dark green, purple,
    maroon, orange-red), low light and colour casts;
  * more 'bg' negatives: bare artwork, dark silhouettes, carved tables,
    glyph fragments on artwork.
The fonts in fonts.TEST_FAMILIES are never used here (held out for the
any-deck test set, make_scenes.py).

  python synth_any.py <bg_patches.npy> <out.npz> <n> [seed] [--std-frac 0.35]

--std-frac: share of samples drawn by the original synth.py generator
(white card stock, its 45 fonts), so standard decks stay covered.
No photo card pixels are used: bg_patches.npy holds card-free patches
(bgbank.py), extended here with procedural table / art patches.
"""
import os
import sys
from multiprocessing import Pool

import cv2
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'real', 'learned'))
sys.path.insert(0, HERE)
import synth as S  # noqa: E402
from common import CLASSES, RANK_LABEL, SUIT_CHAR, crop_from_mask  # noqa: E402
import art as A  # noqa: E402
import fonts as F  # noqa: E402

_FONTS = F.scan()
RANK_TRAIN = [(p, i) for p, i, _ in _FONTS['rank_train']]
SUIT_TRAIN = [(p, i) for p, i, _ in _FONTS['suit_train']]
STD_RANK, STD_SUIT = list(S.RANK_FONTS), list(S.SUIT_FONTS)


def use_fonts(rank, suit):
    S.RANK_FONTS[:] = rank
    S.SUIT_FONTS[:] = suit


def split_ten(h, rng):
    """'1' and '0' rendered from the same face as two separate glyphs (many
    decks print the 10 with a gap, so the blob finder sees two blobs).
    Returns (mask of both, mask of the '1', mask of the '0')."""
    spec = S.RANK_FONTS[rng.integers(len(S.RANK_FONTS))]
    f = S.font(spec, int(h * 1.35))
    ims = []
    for ch in '10':
        im = Image.new('L', (int(h * 3), int(h * 3)), 0)
        ImageDraw.Draw(im).text((h // 2, h // 3), ch, font=f, fill=255)
        m = np.array(im)
        ys, xs = np.nonzero(m > 60)
        if len(ys) == 0:
            return None
        ims.append((m, ys.min(), ys.max() + 1, xs.min(), xs.max() + 1))
    y0 = min(a[1] for a in ims)
    y1 = max(a[2] for a in ims)
    gap = int(h * rng.uniform(0.06, 0.35))
    w1 = ims[0][4] - ims[0][3]
    w0 = ims[1][4] - ims[1][3]
    W = w1 + gap + w0
    out1 = np.zeros((y1 - y0, W), np.uint8)
    out0 = np.zeros((y1 - y0, W), np.uint8)
    out1[:, :w1] = ims[0][0][y0:y1, ims[0][3]:ims[0][4]]
    out0[:, w1 + gap:] = ims[1][0][y0:y1, ims[1][3]:ims[1][4]]
    sx = rng.uniform(0.6, 1.0) if rng.random() < 0.5 else 1.0
    nh = max(4, int(h))
    nw = max(3, int(W * nh / (y1 - y0) * sx))
    r = lambda m: cv2.resize(m, (nw, nh), interpolation=cv2.INTER_AREA)
    o1, o0 = r(out1), r(out0)
    return np.maximum(o1, o0), o1, o0


def ink_any(red, rng):
    """BGR ink colour: mostly black / red, sometimes an off colour."""
    if rng.random() < 0.78:
        return S.ink_color(red, rng)
    if red:
        opts = [(30, 30, 130), (40, 20, 100), (30, 70, 210), (90, 30, 170), (40, 40, 180)]  # maroon, brick, orange-red, magenta-red
    else:
        opts = [(90, 30, 20), (30, 60, 20), (20, 40, 70), (80, 20, 60), (60, 60, 60), (70, 50, 20)]  # navy, green, brown, purple, grey, teal
    c = np.array(opts[rng.integers(len(opts))], np.float32)
    return np.clip(c * rng.uniform(0.6, 1.2) + rng.uniform(-15, 15, 3), 0, 255)


def _ring_g(img, mask, pad):
    m = (mask > 100).astype(np.uint8)
    if m.sum() == 0:
        return None, None
    ring = cv2.dilate(m, np.ones((pad, pad), np.uint8)) - m
    g = img[..., 1]
    return float(np.median(g[m > 0])), float(np.median(g[ring > 0])) if ring.sum() else None


def card_face(S_, rng):
    """Background of the card around the index, and its kind."""
    k = rng.random()
    if k < 0.25:
        return S.paper(S_, S_, rng), 'paper'
    if k < 0.37:  # cream / tinted stock
        base = A._palette(rng, 1)[0] * 0.3 + 255 * 0.7
        img = np.ones((S_, S_, 3), np.float32) * base + rng.normal(0, 2, (S_, S_, 1))
        return img, 'tint'
    img = A.art(S_, S_, rng)
    if rng.random() < 0.35:  # card border strip: art starts some way in
        img2 = S.paper(S_, S_, rng)
        e = int(rng.uniform(0, 50))
        side = rng.integers(4)
        if side == 0:
            img2[:, e:] = img[:, e:]
        elif side == 1:
            img2[e:] = img[e:]
        else:
            img2[e:, e:] = img[e:, e:]
        img = img2
    return img, 'art'


def scene_any(cls, bank, rng):
    S_ = 160
    img, kind = card_face(S_, rng)
    tgt = np.zeros((S_, S_), np.uint8)
    h = rng.uniform(26, 46)
    if cls == 'bg' and rng.random() < 0.6:
        return bg_any(img, bank, rng, h)
    suits = 'cdhs'
    is_suit = cls in suits
    suit = cls if is_suit else suits[rng.integers(4)]
    red = suit in 'dh'
    col = ink_any(red, rng)
    rank = cls if not is_suit else CLASSES[rng.integers(13)]
    # A ten printed as two separate digits is found as two blobs; the reader
    # merges them (glyph_reader.dart) and reads the pair as a ten. One digit
    # on its own is 'bg' (a lone "0" must not read as a Q, a "1" as a 7),
    # and so is a rank and its suit taken as one blob.
    part = None
    split_part = cls == 'bg' and rng.random() < 0.55
    if cls == 'bg':
        rank = 'T' if split_part else CLASSES[rng.integers(13)]
    if rank == 'T' and (split_part or (cls != 'bg' and rng.random() < 0.5)):
        st = split_ten(h, rng)
        if st is None:
            return None
        rm = st[0]
        if cls == 'bg':
            part = st[1] if rng.random() < 0.4 else st[2]
    else:
        rm = S.glyph_mask(rank, h, rng)
    sm = S.glyph_mask(suit, h * rng.uniform(0.5, 1.0), rng)
    if rm is None or sm is None:
        return None
    cx = S_ / 2 + rng.uniform(-4, 4)
    gap = h * rng.uniform(0.03, 0.45)
    if is_suit:
        sy = int(S_ / 2 - sm.shape[0] / 2)
        ry = int(sy - gap - rm.shape[0])
    else:
        ry = int(S_ / 2 - rm.shape[0] / 2)
        sy = int(ry + rm.shape[0] + gap)
    rx = int(cx - rm.shape[1] / 2 + rng.uniform(-6, 6))
    sx = int(cx - sm.shape[1] / 2 + rng.uniform(-6, 6))
    m_all = np.zeros((S_, S_), np.float32)
    for m, x, y in ((rm, rx, ry), (sm, sx, sy)):
        x0, y0, x1, y1 = max(0, x), max(0, y), min(S_, x + m.shape[1]), min(S_, y + m.shape[0])
        if x1 > x0 and y1 > y0:
            m_all[y0:y1, x0:x1] = np.maximum(m_all[y0:y1, x0:x1], m[y0 - y:y1 - y, x0 - x:x1 - x])
    if kind == 'art':
        r = rng.random()
        if r < 0.25:  # light plate behind the index
            ys, xs = np.nonzero(m_all > 60)
            if len(xs):
                p = int(h * rng.uniform(0.1, 0.4))
                plate = np.zeros((S_, S_), np.uint8)
                cv2.rectangle(plate, (int(xs.min()) - p, int(ys.min()) - p), (int(xs.max()) + p, int(ys.max()) + p), 255, -1)
                plate = cv2.GaussianBlur(plate, (0, 0), rng.uniform(0.5, 2))
                S.stamp(img, plate, 0, 0, np.array([rng.uniform(215, 255)] * 3) - rng.uniform(0, 25, 3))
        elif r < 0.45:  # halo / outline around the glyphs
            k = int(max(3, h * rng.uniform(0.08, 0.25))) | 1
            halo = cv2.dilate((m_all > 60).astype(np.uint8) * 255, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
            S.stamp(img, cv2.GaussianBlur(halo, (0, 0), 0.8), 0, 0, np.array([rng.uniform(220, 255)] * 3))
        # Legibility: real decks keep the index readable. If the artwork
        # around it is too close to the ink (green channel), lighten it.
        inkg = float(col[1])
        _, ringg = _ring_g(img, m_all, int(h * 0.4) | 1)
        if ringg is not None and ringg - inkg < 45:
            f = min(0.85, (45 - (ringg - inkg)) / max(255 - ringg, 1) + rng.uniform(0.05, 0.25))
            yy0, xx0 = np.nonzero(m_all > 0)
            pad = int(h * rng.uniform(0.3, 1.0))
            box = np.zeros((S_, S_), np.uint8)
            cv2.rectangle(box, (int(xx0.min()) - pad, int(yy0.min()) - pad), (int(xx0.max()) + pad, int(yy0.max()) + pad), 255, -1)
            box = cv2.GaussianBlur(box, (0, 0), pad * 0.5 + 1).astype(np.float32)[..., None] / 255 * f
            img = img * (1 - box) + 245 * box
    if rng.random() < 0.5:  # card edge / table beyond
        edge = int(min(rx, sx) - rng.uniform(8, 30))
        if edge > 0:
            img[:, :edge] = S.bg_patch(bank, S_, edge, rng)
    if rng.random() < 0.4:
        top = int(min(ry, sy) - rng.uniform(8, 30))
        if top > 0:
            img[:top] = S.bg_patch(bank, top, S_, rng)
    S.stamp(img, rm, rx, ry, col)
    S.stamp(img, sm, sx, sy, col)
    m = rm if not is_suit else sm
    x, y = (rx, ry) if not is_suit else (sx, sy)
    if part is not None:
        m = part
    tgt[max(0, y):y + m.shape[0], max(0, x):x + m.shape[1]] = (m[max(0, -y):, max(0, -x):] > 100) * 255
    if cls == 'bg' and part is None:  # rank and suit as one blob
        x0, y0 = max(0, min(rx, sx)), max(0, min(ry, sy))
        tgt[y0:sy + sm.shape[0], x0:max(rx + rm.shape[1], sx + sm.shape[1])] = 255
    return img, tgt, cls == 'bg'


def bg_any(img, bank, rng, h):
    S_ = img.shape[0]
    tgt = np.zeros((S_, S_), np.uint8)
    k = rng.integers(6)
    if k == 0:  # bare artwork
        img = A.art(S_, S_, rng)
    elif k == 1:  # artwork with dark silhouettes / strokes
        img = A._blobs(A.art(S_, S_, rng), rng, int(rng.integers(2, 7)), 0.8)
    elif k == 2:  # table: wood, carved grooves, felt
        img = A.table(S_, S_, rng)
    elif k == 3:  # glyph fragment (cut off / too big) on artwork
        g = S.glyph_mask(rng.choice(list(CLASSES[:-1])), h * rng.uniform(1.5, 3), rng)
        if g is not None:
            S.stamp(img, g, int(rng.uniform(-g.shape[1] * 0.8, S_ * 0.3)), int(rng.uniform(-g.shape[0] * 0.8, S_ * 0.3)),
                    ink_any(rng.random() < 0.5, rng))
    elif k == 4:  # card edges against table / artwork
        img = A.table(S_, S_, rng)
        pts = np.int32([[rng.uniform(40, 120), 0], [S_, 0], [S_, S_], [rng.uniform(40, 120), S_]])
        m = np.zeros((S_, S_), np.uint8)
        cv2.fillPoly(m, [pts], 255)
        face, _ = card_face(S_, rng)
        img[m > 0] = face[m > 0]
    else:  # body text on artwork / plate (card titles, captions)
        d_img = Image.new('L', (S_, S_), 0)
        dd = ImageDraw.Draw(d_img)
        spec = S.RANK_FONTS[rng.integers(len(S.RANK_FONTS))]
        f = S.font(spec, int(rng.uniform(12, 34)))
        y = rng.uniform(-10, 40)
        while y < S_:
            dd.text((rng.uniform(-40, 10), y), ' '.join(rng.choice(S.WORDS, 4)), font=f, fill=255)
            y += f.size * 1.2
        S.stamp(img, np.array(d_img), 0, 0, ink_any(rng.random() < 0.2, rng))
    cx, cy = rng.uniform(60, 100, 2)
    hh = rng.uniform(14, 46)
    tgt[int(cy - hh / 2):int(cy + hh / 2), int(cx - hh * 0.35):int(cx + hh * 0.35)] = 255
    return img, tgt, True


def sample(args):
    seed, bank_path, std_frac = args
    rng = np.random.default_rng(seed)
    bank = S._bank(bank_path)
    std = rng.random() < std_frac
    if std:
        use_fonts(STD_RANK, STD_SUIT)
    else:
        use_fonts(RANK_TRAIN, SUIT_TRAIN)
    while True:
        ci = rng.integers(len(CLASSES)) if rng.random() < 0.82 else len(CLASSES) - 1
        cls = CLASSES[ci]
        s = S.scene(cls, bank, rng) if std else scene_any(cls, bank, rng)
        if s is None:
            continue
        img, tgt, _ = s
        if not std and rng.random() < 0.15:  # dim room
            img = img * rng.uniform(0.3, 0.6)
        d = S.degrade(img, tgt, bank, rng)
        if d is None:
            continue
        small, tsm = d
        if tsm.sum() == 0:
            continue
        jit = rng.uniform(0, 0.18) if rng.random() < 0.9 else rng.uniform(0.18, 0.3)
        x = crop_from_mask(small, tsm > 0, jitter=jit, rng=rng)
        if x is None:
            continue
        return x, ci


def extend_bank(photo_bank_path, out_path, n_proc=1500, seed=123):
    """Photo background patches + procedural table / artwork patches."""
    rng = np.random.default_rng(seed)
    b = np.load(photo_bank_path)
    extra = [np.clip(A.table(128, 128, rng) if rng.random() < 0.6 else A.art(128, 128, rng), 0, 255).astype(np.uint8)
             for _ in range(n_proc)]
    np.save(out_path, np.concatenate([b, np.stack(extra)]))


def main():
    args = sys.argv[1:]
    std_frac = 0.35
    if '--std-frac' in args:
        i = args.index('--std-frac')
        std_frac = float(args[i + 1])
        del args[i:i + 2]
    if args[0] == '--extend-bank':
        extend_bank(args[1], args[2])
        return
    bank_path, out, n = args[0], args[1], int(args[2])
    seed0 = int(args[3]) if len(args) > 3 else 0
    with Pool(8) as pool:
        res = pool.map(sample, [(seed0 * 10_000_000 + i, bank_path, std_frac) for i in range(n)], chunksize=256)
    X = np.stack([r[0] for r in res])
    y = np.array([r[1] for r in res], np.int64)
    np.savez_compressed(out, X=X, y=y)
    print('wrote', out, X.shape, np.bincount(y, minlength=len(CLASSES)))


if __name__ == '__main__':
    main()
