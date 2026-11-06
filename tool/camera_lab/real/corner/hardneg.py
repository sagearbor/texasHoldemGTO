"""Real detector crops with explicit hard negatives (Nov 7 audit).

  python hardneg.py <model_dir> <out.npz> <recording_dir>[:<oldboxes.json>] ...

pseudo.py leaves every white-ish region "ignore" for CornerNet, so the
detector never learns that a face, a chip stack, a pip in the middle of
a card or a shirt is not an index: on the owner's stills those peaks
heat as high as real indices and push them out of the peaks the app
reads (CornerDetector.maxPeaks). Here, on the TRAINING recordings' stills:

  positive  a read of a card the still's label has (grade A/B, score
            >= 0.25) or the glyph reader's right box (oldboxes.json)
  negative  a detector peak whose refined crop IndexNet calls "not an
            index" (P >= 0.9), more than an index away from every
            positive and from every read of score >= 0.2: a disk there is
            taken out of the ignore mask, so the focal loss pushes it down
  ignore    everything else white-ish (cards nobody labelled, the board)

Crops are taken around the positives and around the negatives, so the
negatives are seen. Index crops of the negatives are added for IndexNet
as "not an index". Only pass TRAINING recordings.
"""
import json
import math
import os
import sys

import cv2
import numpy as np
import torch

import infer
from infer import load_models, read, upright
from render import DET_SCALE, RANKS, SUITS, card_regions, index_crop


def main():
    mdir, out = sys.argv[1], sys.argv[2]
    recs = sys.argv[3:]
    torch.set_num_threads(8)
    infer.MAX_PEAKS = 40
    corner, index = load_models(mdir)
    rng = np.random.default_rng(1)
    det, ign, tl = [], [], []
    nx = []
    npos = nneg = 0
    for spec in recs:
        rec, _, oldp = spec.partition(':')
        old = json.load(open(oldp)) if oldp else {}
        for e in json.load(open(os.path.join(rec, 'stills_labels.json'))):
            want = {c for c, g in e['cards'].items() if g in ('A', 'B') and '?' not in c}
            img = upright(os.path.join(rec, e['file']))
            res = read(corner, index, img, thr=0.2)
            pos = [dict(b, heat=1.0) for b in old.get(e['file'], [])]
            for r in res:
                if r['card'] in want and r['score'] >= 0.25 and not any(
                        b['card'] == r['card'] and math.hypot(b['x'] - r['x'], b['y'] - r['y']) < 0.5 * b['h'] for b in pos):
                    pos.append(r)
            keep = pos + [r for r in res if r['score'] >= 0.2]
            neg = [r for r in res if r['pbg'] >= 0.9 and r['score'] < 0.2
                   and all(math.hypot(q['x'] - r['x'], q['y'] - r['y']) > max(q['h'], r['h']) for q in keep)]
            npos += len(pos)
            nneg += len(neg)
            for r in neg:
                nx.append(index_crop(img, r['x'], r['y'], r['h'], r['a']))
            small = cv2.resize(img, None, fx=DET_SCALE, fy=DET_SCALE, interpolation=cv2.INTER_AREA)
            ig = cv2.resize(card_regions(img).astype(np.uint8), (small.shape[1], small.shape[0]), interpolation=cv2.INTER_NEAREST)
            H, W = small.shape[:2]
            for r in res:
                if r['score'] >= 0.2 and not any(r is b for b in pos) and not any(
                        math.hypot(b['x'] - r['x'], b['y'] - r['y']) < 0.5 * b['h'] for b in pos):
                    cv2.circle(ig, (int(r['x'] * DET_SCALE), int(r['y'] * DET_SCALE)), int(max(6, r['h'] * DET_SCALE * 0.8)), 1, -1)
            for r in neg:
                cv2.circle(ig, (int(r['x'] * DET_SCALE), int(r['y'] * DET_SCALE)), int(max(4, r['h'] * DET_SCALE * 0.7)), 0, -1)
            for p in pos:
                cv2.circle(ig, (int(p['x'] * DET_SCALE), int(p['y'] * DET_SCALE)), int(max(4, p['h'] * DET_SCALE * 0.6)), 0, -1)
            anchors = [(p['x'], p['y']) for p in pos] + [(r['x'], r['y']) for r in neg]
            if not anchors:
                continue
            t_all = [(p['x'] * DET_SCALE, p['y'] * DET_SCALE, p['h'] * DET_SCALE, p['w'] * DET_SCALE, p['a'],
                      RANKS.index(p['card'][0]), SUITS.index(p['card'][1]), 1.0) for p in pos]
            for _ in range(3):
                ax, ay = anchors[rng.integers(len(anchors))]
                x0 = int(np.clip(ax * DET_SCALE - rng.uniform(0.15, 0.85) * 256, 0, W - 256))
                y0 = int(np.clip(ay * DET_SCALE - rng.uniform(0.15, 0.85) * 256, 0, H - 256))
                det.append(small[y0:y0 + 256, x0:x0 + 256])
                ign.append(np.packbits(ig[y0:y0 + 256, x0:x0 + 256] > 0, axis=None))
                tl.append(np.float32([(x - x0, y - y0, h, w, a, r_, s_, v) for (x, y, h, w, a, r_, s_, v) in t_all]).reshape(-1, 8))
    toff = np.zeros(len(tl) + 1, np.int64)
    toff[1:] = np.cumsum([len(t) for t in tl])
    nx = np.stack(nx) if nx else np.zeros((0, 32, 24, 3), np.uint8)
    np.savez_compressed(out, det=np.stack(det), ign=np.stack(ign), t=np.concatenate(tl), toff=toff,
                        cx=nx, cr=np.full(len(nx), 13, np.int8), cs=np.full(len(nx), -1, np.int8))
    print(f'{npos} positives, {nneg} hard negatives, {len(det)} detector crops')


if __name__ == '__main__':
    main()
