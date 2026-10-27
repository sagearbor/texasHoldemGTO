"""Generate assets/data/glyph_templates.bin for lib/camera/glyph_reader.dart.

Renders rank and suit glyphs from macOS system fonts with the same
augmentations as the classical OpenCV reader (tool/camera_lab/real/classical/
glyphs.py), normalises each one (tight bbox -> stretched into a fixed box,
INTER_AREA) and stores it as a 1-bit bitmap. The Dart side blurs, zero-means
and L2-normalises each bitmap at load time. Storing 1 bit per pixel (instead
of the float template) keeps the asset < 300 KB; on the 7 real photos the
Python pipeline scores the same 12/14 hero cards with 1-bit templates as with
float ones.

No photo data is used: templates come from fonts only.

Run (any Python with opencv-python-headless, numpy, pillow):
  python tool/camera_lab/make_glyph_templates.py

File format (little endian):
  'FNGT' magic, u8 version (1), u8 rankW, u8 rankH, u8 suitW, u8 suitH,
  u32 count, then count records:
    u8 kind (0 rank, 1 suit), u8 label (rank 0=deuce..12=ace as in
    lib/poker/cards.dart; suit 0 c, 1 d, 2 h, 3 s),
    ceil(w*h/8) bytes, row-major bits, MSB first.
"""
import os
import struct
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'real', 'classical'))
import glyphs as G  # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'assets', 'data', 'glyph_templates.bin')
RANKS = '23456789TJQKA'
SUITS = 'cdhs'

_bits = {}
_orig = G.normalise


def _normalise_1bit(mask, box):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    m = mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    m = cv2.resize(m, box, interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
    b = (m >= 0.5)
    t = cv2.GaussianBlur(b.astype(np.float32), (3, 3), 0.8)
    t -= t.mean()
    n = np.linalg.norm(t)
    if n <= 1e-6:
        return None
    t = t / n
    _bits[id(t)] = b
    return t


def main():
    G.normalise = _normalise_1bit
    try:
        bank = G.render_font_templates()
    finally:
        G.normalise = _orig
    recs = []
    for kind, labels, box in ((0, RANKS, G.RANK_BOX), (1, SUITS, G.SUIT_BOX)):
        name = 'rank' if kind == 0 else 'suit'
        for lab, tmpls in bank[name].items():
            seen = set()
            for t in tmpls:
                b = _bits[id(t)]
                key = np.packbits(b.ravel()).tobytes()
                if key in seen:  # identical bitmaps add nothing
                    continue
                seen.add(key)
                assert b.shape == (box[1], box[0])
                recs.append((kind, labels.index(lab), key))
    head = b'FNGT' + struct.pack('<BBBBBI', 1, G.RANK_BOX[0], G.RANK_BOX[1], G.SUIT_BOX[0],
                                 G.SUIT_BOX[1], len(recs))
    body = b''.join(struct.pack('<BB', k, lab) + bits for k, lab, bits in recs)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(head + body)
    n_rank = sum(1 for r in recs if r[0] == 0)
    print('wrote %s: %d rank + %d suit templates, %d bytes' % (os.path.normpath(OUT), n_rank,
                                                              len(recs) - n_rank, len(head) + len(body)))


if __name__ == '__main__':
    main()
