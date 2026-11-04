"""Synthetic "unknown deck" test scenes for tool/glyph_probe.dart.

Each scene is a camera-like frame of two held, overlapping playing cards on
a table, a thumb over them, from a deck the reader never saw: rank fonts
from fonts.TEST_FAMILIES only (never used in training), suits from held-out
fonts or procedural shapes, card faces either white stock ('std') or
artwork behind the index ('art', like the dinosaur deck), with a per-deck
index style (bare, light plate, halo), index size and ink colours. The
camera adds tilt, light falloff, colour cast, blur, noise and JPEG.

  python make_scenes.py OUT_DIR N [--kind art|std|mix] [--seed S]

Writes NAME_WxH.rgba + labels.json ({"NAME_WxH.rgba": "Ks 9s"}) and a few
preview JPEGs.
"""
import json
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'real', 'learned'))
sys.path.insert(0, HERE)
import art as A  # noqa: E402
import fonts as F  # noqa: E402
import synth as S  # noqa: E402

RANKS = '23456789TJQKA'
CROP_FRAC = 0.6  # tool/glyph_probe.dart --frame-frac 0.6
SUITS = 'cdhs'
SUIT_CH = {'c': '♣', 'd': '♦', 'h': '♥', 's': '♠'}
_FONTS = F.scan()
# Card indices are regular to heavy weights: hairline faces are left out.
RANK_TEST = [(p, i) for p, i, n in _FONTS['rank_test'] if not any(t in n for t in ('Light', 'Thin', 'Hairline'))]
SUIT_TEST = [(p, i) for p, i, _ in _FONTS['suit_test']]


def glyph(text, spec, h, rng, condense):
    f = ImageFont.truetype(spec[0], int(h * 1.4), index=spec[1])
    im = Image.new('L', (int(h * 4), int(h * 3)), 0)
    ImageDraw.Draw(im).text((h // 2, h // 3), text, font=f, fill=255)
    m = np.array(im)
    ys, xs = np.nonzero(m > 60)
    if len(ys) == 0:
        return None
    m = m[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    nh = max(4, int(h))
    nw = max(3, int(m.shape[1] * nh / m.shape[0] * condense))
    return cv2.resize(m, (nw, nh), interpolation=cv2.INTER_AREA)


class Deck:
    def __init__(self, rng, kind):
        self.kind = kind
        self.rank_font = RANK_TEST[rng.integers(len(RANK_TEST))]
        self.suit_font = SUIT_TEST[rng.integers(len(SUIT_TEST))] if rng.random() < 0.5 else None
        self.condense = rng.uniform(0.6, 1.0) if rng.random() < 0.5 else rng.uniform(0.9, 1.15)
        self.idx_h = rng.uniform(0.11, 0.2)  # rank glyph height / card width
        self.suit_scale = rng.uniform(0.6, 0.95)
        self.black = S.ink_color(False, rng)
        # Printed card red: hue about -6..+10 degrees (OpenCV 177..5), not magenta.
        hsv = np.uint8([[[rng.uniform(-3, 5) % 180, rng.uniform(150, 245), rng.uniform(140, 230)]]])
        self.red = cv2.cvtColor(hsv, cv2.COLOR_HSV2BGR)[0, 0].astype(np.float32)
        self.style = rng.choice(['bare', 'bare', 'plate', 'halo']) if kind == 'art' else 'bare'
        self.border = rng.uniform(0.0, 0.07) if rng.random() < 0.6 else 0.0
        self.seed = int(rng.integers(1 << 30))

    def suit_mask(self, s, h, rng):
        if self.suit_font is None:
            return S.procedural_suit(s, int(h * 1.1), np.random.default_rng(self.seed + SUITS.index(s)))
        return glyph(SUIT_CH[s], self.suit_font, h, rng, 1.0)


def render_card(deck, card, W, rng):
    """RGB float card image (W x 1.4W) and its alpha (rounded corners)."""
    H = int(W * 1.4)
    r, s = card[0], card[1]
    if deck.kind == 'art':
        face = A.art(H, W, np.random.default_rng(rng.integers(1 << 30)))
        if deck.border > 0:
            b = int(deck.border * W)
            stock = S.paper(H, W, rng)
            stock[b:H - b, b:W - b] = face[b:H - b, b:W - b]
            face = stock
    else:
        face = S.paper(H, W, rng)
        # big centre pip / picture so the face is not blank
        pm = deck.suit_mask(s, W * 0.35, rng)
        if pm is not None:
            S.stamp(face, pm, W // 2 - pm.shape[1] // 2, H // 2 - pm.shape[0] // 2, deck.red if s in 'dh' else deck.black)
    col = deck.red if s in 'dh' else deck.black
    h = deck.idx_h * W
    rm = glyph('10' if r == 'T' else r, deck.rank_font, h, rng, deck.condense * (0.8 if r == 'T' else 1.0))
    sm = deck.suit_mask(s, h * deck.suit_scale, rng)
    if rm is None or sm is None:
        return None
    mx = int(W * (0.04 + deck.border * 0.6))
    my = int(W * (0.05 + deck.border * 0.6))
    cx = mx + max(rm.shape[1], sm.shape[1]) // 2
    rx, ry = cx - rm.shape[1] // 2, my
    sx, sy = cx - sm.shape[1] // 2, my + rm.shape[0] + int(h * 0.15)
    for corner in (0, 1):
        tgt = face if corner == 0 else face[::-1, ::-1]
        tgt = np.ascontiguousarray(tgt)
        if deck.style != 'bare':
            m_all = np.zeros(tgt.shape[:2], np.uint8)
            m_all[ry:ry + rm.shape[0], rx:rx + rm.shape[1]] = np.maximum(m_all[ry:ry + rm.shape[0], rx:rx + rm.shape[1]], rm)
            m_all[sy:sy + sm.shape[0], sx:sx + sm.shape[1]] = np.maximum(m_all[sy:sy + sm.shape[0], sx:sx + sm.shape[1]], sm)
            if deck.style == 'plate':
                p = int(h * 0.25)
                plate = np.zeros_like(m_all)
                cv2.rectangle(plate, (min(rx, sx) - p, ry - p), (max(rx + rm.shape[1], sx + sm.shape[1]) + p, sy + sm.shape[0] + p), 255, -1)
                S.stamp(tgt, cv2.GaussianBlur(plate, (0, 0), 1.0), 0, 0, np.array([245, 245, 240], np.float32))
            else:
                k = int(max(3, h * 0.18)) | 1
                halo = cv2.dilate((m_all > 60).astype(np.uint8) * 255, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
                S.stamp(tgt, halo, 0, 0, np.array([250, 250, 250], np.float32))
        S.stamp(tgt, rm, rx, ry, col)
        S.stamp(tgt, sm, sx, sy, col)
        if corner == 0:
            face = tgt
        else:
            face = np.ascontiguousarray(tgt[::-1, ::-1])
    alpha = np.zeros((H, W), np.uint8)
    rad = int(W * 0.06)
    cv2.rectangle(alpha, (rad, 0), (W - rad, H), 255, -1)
    cv2.rectangle(alpha, (0, rad), (W, H - rad), 255, -1)
    for c in ((rad, rad), (W - rad, rad), (rad, H - rad), (W - rad, H - rad)):
        cv2.circle(alpha, c, rad, 255, -1)
    # top-left index: rank and suit centres, rank height (card pixels)
    idx = ((rx + rm.shape[1] / 2, ry + rm.shape[0] / 2), (sx + sm.shape[1] / 2, sy + sm.shape[0] / 2), rm.shape[0])
    return face, alpha, idx


def place(canvas, img, alpha, M):
    Hc, Wc = canvas.shape[:2]
    w = cv2.warpAffine(img, M, (Wc, Hc), flags=cv2.INTER_AREA)
    a = cv2.warpAffine(alpha, M, (Wc, Hc), flags=cv2.INTER_LINEAR).astype(np.float32)[..., None] / 255
    canvas[:] = canvas * (1 - a) + w * a


def scene(rng, kind):
    deck = Deck(rng, kind)
    Wf, Hf = (720, 960) if rng.random() < 0.5 else (960, 720)
    short = min(Wf, Hf)
    canvas = A.table(Hf, Wf, rng)
    glyphs = []
    cards = []
    while len(cards) < 2:
        c = RANKS[rng.integers(13)] + SUITS[rng.integers(4)]
        if c not in cards:
            cards.append(c)
    cw = int(short * rng.uniform(0.2, 0.34))
    base_ang = rng.uniform(-30, 30)
    cx0, cy0 = Wf * rng.uniform(0.3, 0.6), Hf * rng.uniform(0.35, 0.65)
    shift = rng.uniform(0.42, 0.7) * cw
    for k, card in enumerate(cards):
        rc = render_card(deck, card, cw, rng)
        if rc is None:
            return None
        img, alpha, idx = rc
        ang = base_ang + (k * rng.uniform(5, 15) if rng.random() < 0.6 else 0) + rng.normal(0, 3)
        M = cv2.getRotationMatrix2D((cw / 2, cw * 0.7), ang, 1.0)
        t = np.deg2rad(-base_ang)
        off = np.array([np.cos(t), np.sin(t)]) * shift * k + np.array([0, rng.uniform(0, 0.12) * cw * k])
        M[:, 2] += [cx0 - cw / 2 + off[0], cy0 - cw * 0.7 + off[1]]
        place(canvas, img, alpha, M)
        glyphs.append((card, [tuple(M @ np.array([x, y, 1.0])) for x, y in idx[:2]], idx[2]))
    # thumb over the lower-left of the hand
    if rng.random() < 0.8:
        m = np.zeros((Hf, Wf), np.uint8)
        cv2.ellipse(m, (int(cx0 - cw * rng.uniform(-0.1, 0.3)), int(cy0 + cw * rng.uniform(0.7, 1.1))),
                    (int(cw * rng.uniform(0.25, 0.4)), int(cw * rng.uniform(0.5, 0.8))), rng.uniform(-60, 60), 0, 360, 255, -1)
        skin = np.array([rng.uniform(90, 160), rng.uniform(110, 170), rng.uniform(170, 230)], np.float32)
        a = cv2.GaussianBlur(m, (0, 0), 3).astype(np.float32)[..., None] / 255
        shade = 0.75 + 0.25 * A._noise(Hf, Wf, rng, 2)[..., None]
        canvas[:] = canvas * (1 - a) + skin * shade * a
    # camera: tilt, light falloff, colour cast, blur, noise, JPEG
    src = np.float32([[0, 0], [Wf, 0], [Wf, Hf], [0, Hf]])
    j = short * rng.uniform(0, 0.08)
    P = cv2.getPerspectiveTransform(src, src + rng.uniform(-j, j, (4, 2)).astype(np.float32))
    img = cv2.warpPerspective(canvas, P, (Wf, Hf), borderMode=cv2.BORDER_REFLECT)
    yy, xx = np.mgrid[0:Hf, 0:Wf].astype(np.float32)
    g = 1 + rng.uniform(-0.3, 0.3) * (xx / Wf - 0.5) + rng.uniform(-0.3, 0.3) * (yy / Hf - 0.5)
    img = img * g[..., None] * rng.uniform(0.6, 1.05) * np.array([rng.uniform(0.7, 1.0), rng.uniform(0.85, 1.0), 1.0])
    img = np.clip(img, 0, 255).astype(np.uint8)
    sig = rng.uniform(0.3, 1.4)
    img = cv2.GaussianBlur(img, (0, 0), sig)
    img = np.clip(img + rng.normal(0, rng.uniform(1, 6), img.shape), 0, 255).astype(np.uint8)
    img = cv2.imdecode(cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, int(rng.uniform(55, 92))])[1], cv2.IMREAD_COLOR)
    # The app reads a crop around the change (>= half the frame's short
    # side): crop CROP_FRAC of the frame around the hand.
    cw_, ch_ = int(Wf * CROP_FRAC), int(Hf * CROP_FRAC)
    x0 = int(np.clip(cx0 + shift / 2 - cw_ / 2, 0, Wf - cw_))
    y0 = int(np.clip(cy0 - ch_ / 2, 0, Hf - ch_))
    img = np.ascontiguousarray(img[y0:y0 + ch_, x0:x0 + cw_])
    gl = []
    for card, pts, gh in glyphs:
        q = cv2.perspectiveTransform(np.float32([pts]), P)[0] - [x0, y0]
        gl.append({'card': card, 'rank': [round(float(v), 1) for v in q[0]], 'suit': [round(float(v), 1) for v in q[1]],
                   'h': round(float(gh), 1)})
    return img, ' '.join(cards), deck, gl


def main():
    args = sys.argv[1:]

    def opt(name, d):
        if name in args:
            i = args.index(name)
            v = args[i + 1]
            del args[i:i + 2]
            return v
        return d
    kind = opt('--kind', 'mix')
    seed = int(opt('--seed', '1000'))
    out, n = args[0], int(args[1])
    os.makedirs(out, exist_ok=True)
    rng = np.random.default_rng(seed)
    labels = {}
    glyph_pos = {}  # top-left index positions (diagnostics: tool analyse_probe.py)
    i = 0
    while i < n:
        k = kind if kind != 'mix' else ('art' if rng.random() < 0.7 else 'std')
        s = scene(rng, k)
        if s is None:
            continue
        img, cards, deck, gl = s
        h, w = img.shape[:2]
        name = 'scene%04d_%s_%dx%d.rgba' % (i, k, w, h)
        cv2.cvtColor(img, cv2.COLOR_BGR2RGBA).tofile(os.path.join(out, name))
        labels[name] = cards
        glyph_pos[name] = gl
        if i < 12:
            cv2.imwrite(os.path.join(out, 'preview%02d.jpg' % i), img)
        i += 1
    with open(os.path.join(out, 'labels.json'), 'w') as f:
        json.dump(labels, f, indent=0)
    with open(os.path.join(out, 'glyphs.json'), 'w') as f:
        json.dump(glyph_pos, f)
    print('wrote', n, 'scenes to', out)


if __name__ == '__main__':
    main()
