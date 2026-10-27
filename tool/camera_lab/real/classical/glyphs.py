"""Glyph templates for the classical card reader.

Two template sources:
  * render_font_templates(): rank/suit glyphs rendered from macOS system fonts
    (no data from the photos at all -> no leakage).
  * crop_templates_from_reads(): glyphs cropped from the real photos (used only
    with leave-one-deal-out evaluation; see run_eval.py).

Every glyph is normalised the same way: binary ink mask -> tight bbox ->
stretched into a fixed box -> light blur. Stretching (not aspect-preserving)
makes the match tolerant to condensed fonts and to foreshortening along the
card axes (bent "peek" cards).
"""
import os

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

RANK_LABELS = {'A': 'A', '2': '2', '3': '3', '4': '4', '5': '5', '6': '6', '7': '7',
               '8': '8', '9': '9', 'T': '10', 'J': 'J', 'Q': 'Q', 'K': 'K'}
SUIT_CHARS = {'c': '♣', 'd': '♦', 'h': '♥', 's': '♠'}
RED_SUITS = ('d', 'h')
BLACK_SUITS = ('c', 's')

RANK_BOX = (28, 40)   # (w, h) normalised rank glyph
SUIT_BOX = (32, 32)

SUP = '/System/Library/Fonts/Supplemental/'
SYS = '/System/Library/Fonts/'
RANK_FONTS = [
    (SUP + 'Times New Roman.ttf', 0), (SUP + 'Times New Roman Bold.ttf', 0),
    (SUP + 'Georgia.ttf', 0), (SUP + 'Baskerville.ttc', 0), (SUP + 'Didot.ttc', 0),
    (SUP + 'Bodoni 72.ttc', 0), (SYS + 'NewYork.ttf', 0), (SYS + 'Palatino.ttc', 0),
    (SUP + 'Arial.ttf', 0), (SUP + 'Arial Narrow.ttf', 0), (SYS + 'Helvetica.ttc', 0),
]
SUIT_FONTS = [
    (SUP + 'Arial Unicode.ttf', 0), (SYS + 'Apple Symbols.ttf', 0), (SYS + 'Menlo.ttc', 0),
    (SUP + 'Times New Roman.ttf', 0),
]


def normalise(mask, box):
    """Binary mask (uint8 0/255) -> float32 template in `box` (w, h)."""
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    m = mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    m = cv2.resize(m, box, interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
    m = cv2.GaussianBlur(m, (3, 3), 0.8)
    m -= m.mean()
    n = np.linalg.norm(m)
    return m / n if n > 1e-6 else None


def similarity(a, b):
    """Normalised cross-correlation of two normalised templates (-1..1)."""
    return float((a * b).sum())


def _render(text, font_path, index, size=160):
    try:
        f = ImageFont.truetype(font_path, size, index=index)
    except Exception:
        return None
    im = Image.new('L', (size * 3, size * 2), 0)
    d = ImageDraw.Draw(im)
    d.text((size // 2, size // 3), text, font=f, fill=255)
    a = np.array(im)
    return a if a.max() > 0 else None


def _augment(mask):
    """Small shears/rotations/stroke-width changes -> robustness to photo pose."""
    out = []
    h, w = mask.shape
    pad = cv2.copyMakeBorder(mask, 40, 40, 40, 40, cv2.BORDER_CONSTANT, value=0)
    ph, pw = pad.shape
    for shear in (-0.15, 0.0, 0.15):
        for rot in (-8, 0, 8):
            M = cv2.getRotationMatrix2D((pw / 2, ph / 2), rot, 1.0)
            M[0, 1] += shear
            M[0, 2] -= shear * ph / 2
            out.append(cv2.warpAffine(pad, M, (pw, ph)))
    k = np.ones((5, 5), np.uint8)
    out.append(cv2.erode(pad, k))
    out.append(cv2.dilate(pad, k))
    return out


def render_font_templates(augment=True):
    """{'rank': {r: [tmpl,...]}, 'suit': {s: [tmpl,...]}} from system fonts."""
    ranks = {r: [] for r in RANK_LABELS}
    suits = {s: [] for s in SUIT_CHARS}
    for path, idx in RANK_FONTS:
        if not os.path.exists(path):
            continue
        for r, label in RANK_LABELS.items():
            m = _render(label, path, idx)
            if m is None:
                continue
            for v in (_augment(m) if augment else [m]):
                t = normalise((v > 127).astype(np.uint8) * 255, RANK_BOX)
                if t is not None:
                    ranks[r].append(t)
    for path, idx in SUIT_FONTS:
        if not os.path.exists(path):
            continue
        rendered = {s: _render(ch, path, idx) for s, ch in SUIT_CHARS.items()}
        if any(v is None for v in rendered.values()):
            continue
        # Reject fonts that fall back to an identical "missing glyph" box.
        sig = {s: normalise((v > 127).astype(np.uint8) * 255, SUIT_BOX) for s, v in rendered.items()}
        if similarity(sig['c'], sig['d']) > 0.95:
            continue
        for s, m in rendered.items():
            for v in (_augment(m) if augment else [m]):
                t = normalise((v > 127).astype(np.uint8) * 255, SUIT_BOX)
                if t is not None:
                    suits[s].append(t)
    return {'rank': ranks, 'suit': suits}


def classify(mask, bank, kind, allowed=None):
    """Best label and score per class for a glyph mask. Returns (label, score, all)."""
    box = RANK_BOX if kind == 'rank' else SUIT_BOX
    t = normalise(mask, box)
    if t is None:
        return None, -1.0, {}
    scores = {}
    stacks = bank.setdefault('_stack', {})
    for lab, tmpls in bank[kind].items():
        if allowed is not None and lab not in allowed:
            continue
        if not tmpls:
            continue
        key = (kind, lab, len(tmpls))
        if key not in stacks:
            stacks[key] = np.stack([x.ravel() for x in tmpls])
        with np.errstate(all='ignore'):  # spurious Accelerate matmul warnings on macOS
            scores[lab] = float((stacks[key] @ t.ravel()).max())
    if not scores:
        return None, -1.0, {}
    best = max(scores, key=scores.get)
    return best, scores[best], scores


def merge_banks(*banks):
    out = {'rank': {}, 'suit': {}}
    for b in banks:
        for kind in ('rank', 'suit'):  # '_stack' caches are rebuilt lazily
            for lab, ts in b[kind].items():
                out[kind].setdefault(lab, []).extend(ts)
    return out


def crop_bank(glyph_records, augment=True):
    """Template bank from real-photo glyph masks.

    glyph_records: list of (kind, label, mask) with mask already rotated upright.
    """
    bank = {'rank': {}, 'suit': {}}
    for kind, lab, m in glyph_records:
        box = RANK_BOX if kind == 'rank' else SUIT_BOX
        pad = cv2.copyMakeBorder(m, 10, 10, 10, 10, cv2.BORDER_CONSTANT, value=0)
        variants = [pad]
        if augment:
            variants += [cv2.erode(pad, np.ones((3, 3), np.uint8)), cv2.dilate(pad, np.ones((3, 3), np.uint8))]
        for v in variants:
            t = normalise(v, box)
            if t is not None:
                bank[kind].setdefault(lab, []).append(t)
    return bank
