"""Pseudo-labels from the owner's stills for a second training round.

  python pseudo.py <model_dir|none> <out.npz> <recording_dir>[:<oldboxes.json>] ...

Runs the current CornerNet + IndexNet on every still labelled in
stills_labels.json. A read that names a card the label says is in view
(grade A or B) keeps its geometry as a real example: index crops for
IndexNet (with jitter) and 256x256 detector crops whose targets are those
reads. Everything white-ish that is not such a read is "ignore" for the
detector (other cards nobody labelled, board cards), never a negative.

<oldboxes.json> (oldboxes.py): the glyph reader's right reads on the
same stills, added as more real boxes (a model read of the same card
within half an index of one of them is the same box).

Only pass TRAINING recordings: the held-out one must stay unseen.
"""
import json
import math
import os
import sys

import cv2
import numpy as np
import torch

from infer import load_models, read, upright
from render import DET_SCALE, RANKS, SUITS, card_regions, index_crop


def main():
    mdir, out = sys.argv[1], sys.argv[2]
    recs = sys.argv[3:]
    torch.set_num_threads(8)
    corner, index = load_models(mdir) if mdir != 'none' else (None, None)
    rng = np.random.default_rng(0)
    cx, cr, cs = [], [], []
    det, ign, tl = [], [], []
    found = total = 0
    for spec in recs:
        rec, _, oldp = spec.partition(':')
        old = json.load(open(oldp)) if oldp else {}
        stills = json.load(open(os.path.join(rec, 'stills_labels.json')))
        for e in stills:
            want = {c for c, g in e['cards'].items() if g in ('A', 'B') and '?' not in c}
            if not want:
                continue
            img = upright(os.path.join(rec, e['file']))
            res = read(corner, index, img, thr=0.2) if corner is not None else []
            plist = [dict(b, heat=1.0) for b in old.get(e['file'], [])]
            for r in res:
                if r['card'] in want and r['score'] >= 0.25:
                    if not any(b['card'] == r['card'] and math.hypot(b['x'] - r['x'], b['y'] - r['y']) < 0.5 * b['h'] for b in plist):
                        plist.append(r)
            total += len(want)
            found += len({b['card'] for b in plist})
            if not plist:
                continue
            pos = {id(b): b for b in plist}
            for r in plist:
                card = r['card']
                for _ in range(3):
                    j = 0.1
                    cx.append(index_crop(img, r['x'] + rng.normal(0, j) * r['h'], r['y'] + rng.normal(0, j) * r['h'],
                                         r['h'] * math.exp(rng.normal(0, 0.1)), r['a'] + rng.normal(0, 0.08)))
                    cr.append(RANKS.index(card[0]))
                    cs.append(SUITS.index(card[1]))
            # Detector crop around the hand.
            small = cv2.resize(img, None, fx=DET_SCALE, fy=DET_SCALE, interpolation=cv2.INTER_AREA)
            ig = cv2.resize(card_regions(img).astype(np.uint8), (small.shape[1], small.shape[0]), interpolation=cv2.INTER_NEAREST)
            H, W = small.shape[:2]
            # Any other confident-looking index: ignore.
            for r in res:
                if not any(r is b for b in plist) and not any(math.hypot(b['x'] - r['x'], b['y'] - r['y']) < 0.5 * b['h'] for b in plist):
                    if r['heat'] >= 0.2:
                        x, y, h = r['x'] * DET_SCALE, r['y'] * DET_SCALE, r['h'] * DET_SCALE
                        cv2.circle(ig, (int(x), int(y)), int(max(6, h * 0.8)), 1, -1)
            ps = plist
            m = np.mean([[p['x'], p['y']] for p in ps], 0) * DET_SCALE
            for _ in range(2):
                x0 = int(np.clip(m[0] - rng.uniform(0.2, 0.8) * 256, 0, W - 256))
                y0 = int(np.clip(m[1] - rng.uniform(0.2, 0.8) * 256, 0, H - 256))
                det.append(small[y0:y0 + 256, x0:x0 + 256])
                g = ig[y0:y0 + 256, x0:x0 + 256].copy()
                t = []
                for p in ps:
                    t.append((p['x'] * DET_SCALE - x0, p['y'] * DET_SCALE - y0, p['h'] * DET_SCALE, p['w'] * DET_SCALE,
                              p['a'], RANKS.index(p['card'][0]), SUITS.index(p['card'][1]), 1.0))
                    # The read itself is not ignored.
                    cv2.circle(g, (int(p['x'] * DET_SCALE - x0), int(p['y'] * DET_SCALE - y0)), int(max(4, p['h'] * DET_SCALE * 0.6)), 0, -1)
                ign.append(np.packbits(g > 0, axis=None))
                tl.append(np.float32(t).reshape(-1, 8))
    toff = np.zeros(len(tl) + 1, np.int64)
    toff[1:] = np.cumsum([len(t) for t in tl])
    np.savez_compressed(out, cx=np.stack(cx), cr=np.int8(cr), cs=np.int8(cs),
                        det=np.stack(det), ign=np.stack(ign), t=np.concatenate(tl), toff=toff)
    print(f'{found}/{total} labelled A/B cards found and kept; {len(cx)} index crops, {len(det)} detector crops')


if __name__ == '__main__':
    main()
