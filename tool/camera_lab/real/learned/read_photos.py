"""Evaluate the synthetic-trained glyph CNN on the REAL photos.

Localiser (no learning): dark/red ink blobs that sit on white card stock ->
pairs (rank blob, suit blob) with plausible spacing -> the rank->suit vector
defines "down", so each blob is rotated upright (this also resolves 6 vs 9
and upside-down bottom indices) -> CNN classifies each blob crop.

  python read_photos.py <model.pt|model.onnx> <photo_dir> <out_dir>
Prints per-photo hero/board reads plus classifier-only accuracy on
hand-located index boxes (HAND_BOXES, evaluation only).
"""
import glob
import json
import os
import sys
import time

import cv2
import numpy as np

from common import CLASSES, SUITS, crop_from_mask

# Hand-located corner-index boxes (x0,y0,x1,y1 in 750x1000 thumbnail coords,
# x4 for the 3000x4000 originals). Evaluation only, never used for training.
HAND_BOXES = [
    ('052737969', 'Qc', (18, 380, 70, 490)), ('052737969', '5d', (195, 435, 258, 535)),
    ('052737969', '5d', (290, 825, 352, 925)),
    ('052745925', 'Qc', (178, 508, 215, 585)), ('052745925', '5d', (310, 530, 345, 605)),
    ('052745925', '5d', (410, 765, 450, 825)),
    ('052754698', 'Qc', (135, 578, 175, 645)), ('052754698', '5d', (280, 640, 335, 690)),
    ('052809072', '6h', (110, 490, 165, 560)), ('052809072', 'Ac', (250, 580, 340, 615)),
    ('052824832', '6h', (75, 610, 110, 685)), ('052824832', 'Ac', (180, 610, 225, 680)),
    ('052824832', 'Ac', (255, 865, 305, 930)),
    ('052831500', '6h', (90, 690, 140, 745)), ('052831500', 'Ac', (300, 685, 370, 725)),
    ('052831500', 'Ac', (320, 855, 375, 890)),
    ('052836314', '6h', (140, 725, 190, 780)), ('052836314', 'Ac', (295, 662, 335, 725)),
    ('052836314', 'Ac', (425, 870, 465, 930)),
]
TTA = (0.0, -25.0, 25.0)
BOARD_MAX_S = 48  # px at 3000x4000
RI = {c: i for i, c in enumerate(CLASSES)}


class TemplateClassifier:
    """Baseline: normalised cross-correlation against clean rendered glyphs of
    one font, through the SAME localiser + crop normalisation as the CNN.
    'bg' gets a fixed pseudo-score so weak matches lose."""
    def __init__(self, font_path):
        from PIL import Image, ImageDraw, ImageFont
        from common import RANK_LABEL, SUIT_CHAR
        self.T = []
        for c in CLASSES[:-1]:
            f = ImageFont.truetype(font_path, 120)
            im = Image.new('L', (400, 300), 255)
            ImageDraw.Draw(im).text((40, 40), SUIT_CHAR.get(c) or RANK_LABEL[c], font=f, fill=0)
            a = np.array(im)
            t = crop_from_mask(np.dstack([a] * 3), a < 128)
            t = t.astype(np.float32)
            t -= t.mean()
            self.T.append(t / (np.linalg.norm(t) + 1e-6))
        self.T = np.stack(self.T).reshape(len(self.T), -1)

    def probs(self, crops):
        x = np.stack(crops).astype(np.float32).reshape(len(crops), -1)
        x -= x.mean(1, keepdims=True)
        x /= np.linalg.norm(x, axis=1, keepdims=True) + 1e-6
        sim = x @ self.T.T
        lg = np.concatenate([sim, np.full((len(x), 1), 0.2)], 1) * 15
        e = np.exp(lg - lg.max(1, keepdims=True))
        return e / e.sum(1, keepdims=True)


class Classifier:
    def __init__(self, path):
        self.onnx = path.endswith('.onnx')
        if self.onnx:
            import onnxruntime as ort
            self.sess = ort.InferenceSession(path, providers=['CPUExecutionProvider'])
        else:
            import torch
            from common import make_model
            ck = torch.load(path, map_location='cpu')
            self.m = make_model(ck['width'])
            self.m.load_state_dict(ck['state'])
            self.m.eval()
            self.torch = torch

    def probs(self, crops):
        x = np.stack(crops).astype(np.float32)[:, None] / 255
        if self.onnx:
            lg = self.sess.run(None, {'x': x})[0]
        else:
            with self.torch.no_grad():
                lg = self.m(self.torch.from_numpy(x)).numpy()
        e = np.exp(lg - lg.max(1, keepdims=True))
        return e / e.sum(1, keepdims=True)


def white_mask(img):
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    return cv2.inRange(hsv, (0, 0, 110), (180, 80, 255))


def blobs(img, roi=None, offsets=(30, 60)):
    """Ink components that sit on white card stock, at several ink thresholds
    (a stricter one splits glyphs that touch other ink). Returns list of dicts."""
    out = []
    for lvl, off in enumerate(offsets):
        out += _blobs(img, roi, off, lvl)
    return out, None


def _blobs(img, roi, off, lvl):
    g = img[:, :, 1]
    H, W = g.shape
    wm = white_mask(img)
    bg = cv2.blur(g, (101, 101))
    ink = ((g.astype(np.int16) < bg.astype(np.int16) - off)).astype(np.uint8) * 255
    near_white = cv2.dilate(wm, np.ones((31, 31), np.uint8))
    ink &= near_white
    if roi is not None:
        m = np.zeros_like(ink)
        x0, y0, x1, y1 = roi
        m[y0:y1, x0:x1] = 255
        ink &= m
    ink = cv2.morphologyEx(ink, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    n, lab, st, cen = cv2.connectedComponentsWithStats(ink)
    out = []
    for i in range(1, n):
        x, y, w, h, a = st[i]
        s = max(w, h)
        if a < 40 or s < 12 or s > 400 or a > 0.95 * w * h or min(w, h) < 3:
            continue
        # ring of card-white around the blob
        p = max(4, s // 4)
        xa, ya, xb, yb = max(0, x - p), max(0, y - p), min(W, x + w + p), min(H, y + h + p)
        ring = wm[ya:yb, xa:xb].astype(bool) & (lab[ya:yb, xa:xb] != i)
        ring_frac = ring.mean() / max(1e-3, 1 - (lab[ya:yb, xa:xb] == i).mean())
        if ring_frac < 0.45:
            continue
        px = img[y:y + h, x:x + w][lab[y:y + h, x:x + w] == i]
        red = float(px[:, 2].mean()) - float(px[:, 1].mean()) > 45
        out.append(dict(id=i, box=(x, y, w, h), c=cen[i], s=s, area=a, red=red, lab=lab, lvl=lvl))
    return out


def upright_crop(img, lab, b, down, extra=0.0):
    """Rotate a window around blob b so that `down` (unit vector) points +y."""
    ang = np.degrees(np.arctan2(down[0], down[1])) + extra  # rotate by -ang about centre
    cx, cy = b['c']
    R = 1.6 * b['s']
    x0, y0 = int(max(0, cx - R)), int(max(0, cy - R))
    x1, y1 = int(min(img.shape[1], cx + R)), int(min(img.shape[0], cy + R))
    win = img[y0:y1, x0:x1]
    m = (b['lab'][y0:y1, x0:x1] == b['id']).astype(np.uint8) * 255
    M = cv2.getRotationMatrix2D((cx - x0, cy - y0), -ang, 1.0)
    wr = cv2.warpAffine(win, M, (win.shape[1], win.shape[0]), borderMode=cv2.BORDER_REPLICATE)
    mr = cv2.warpAffine(m, M, (win.shape[1], win.shape[0]))
    return crop_from_mask(wr, mr > 127)


def pairs(bl):
    out = []
    for a in bl:
        for b in bl:
            if a is b or a['red'] != b['red'] or a['lvl'] != b['lvl']:
                continue
            d = np.subtract(b['c'], a['c'])
            dist = float(np.hypot(*d))
            s = max(a['s'], b['s'])
            if not (0.55 * s < dist < 1.9 * s):
                continue
            if not (0.35 < a['s'] / b['s'] < 2.6):
                continue
            out.append((a, b, d / dist))
    return out


def read_region(img, clf, roi=None):
    """All (score, code, rank_blob, suit_blob) candidate reads in a region."""
    bl, lab = blobs(img, roi)
    ps = pairs(bl)
    if not ps:
        return [], bl
    # Test-time rotation: under strong foreshortening the rank->suit vector is
    # only roughly the card's 'down', so also try +-TTA degrees, keep the max.
    crops, keep = [], []
    for a, b, u in ps:
        cs = [upright_crop(img, lab, x, u, e) for e in TTA for x in (a, b)]
        if any(c is None for c in cs):
            continue
        crops += cs
        keep.append((a, b))
    if not keep:
        return [], bl
    P = clf.probs(crops).reshape(len(keep), len(TTA), 2, -1).max(1)
    reads = []
    for k, (a, b) in enumerate(keep):
        pr, psu = P[k, 0], P[k, 1]
        r = int(np.argmax(pr[:13]))
        allowed = 'dh' if a['red'] else 'cs'
        su = max(allowed, key=lambda s: psu[RI[s]])
        score = float(pr[r] * psu[RI[su]])
        reads.append((score, CLASSES[r] + su, a, b, float(pr[r]), float(psu[RI[su]])))
    reads.sort(key=lambda t: -t[0])
    return reads, bl


def distinct(reads, thr):
    seen, out = set(), []
    for t in reads:
        if t[0] >= thr and t[1] not in seen:
            seen.add(t[1])
            out.append(t)
    return out


def main():
    model, src, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    clf = TemplateClassifier(model[5:]) if model.startswith('tmpl:') else Classifier(model)
    labels = json.load(open(os.path.join(src, 'labels.json')))
    report = {'photos': {}, 'hand': []}
    hero_ok = hero_n = 0
    for f in sorted(glob.glob(os.path.join(src, '*.jpg'))):
        name = os.path.basename(f)
        lb = labels.get(name, {})
        img = cv2.imread(f)
        H = img.shape[0]
        t0 = time.time()
        reads, bl = read_region(img, clf)
        dt = time.time() - t0
        # Near (hero) vs far (board) by glyph size: board indices are tiny.
        hero_r = distinct([r for r in reads if r[2]['s'] >= BOARD_MAX_S], 0.25)
        board_r = distinct([r for r in reads if r[2]['s'] < BOARD_MAX_S and r[2]['c'][1] < 0.5 * H], 0.25)
        hero_pred = [r[1] for r in hero_r[:2]]
        truth = lb.get('hero', [])
        ok = sum(1 for c in truth if c in hero_pred)
        hero_ok += ok
        hero_n += len(truth)
        board_truth = lb.get('board', [])
        board_pred = [r[1] for r in board_r[:len(board_truth) or 5]]
        report['photos'][name] = dict(
            hero_truth=truth, hero_pred=hero_pred, hero_correct=ok,
            hero_top=[(r[1], round(r[0], 3)) for r in hero_r[:6]],
            board_truth=board_truth, board_pred=board_pred,
            board_correct=sum(1 for c in board_truth if c in board_pred),
            n_blobs=len(bl), secs=round(dt, 2))
        print(f"{name}: hero {truth} -> {hero_pred} ({ok}/{len(truth)})  top={report['photos'][name]['hero_top']}"
              f"  | board {board_truth} -> {board_pred}  [{len(bl)} blobs, {dt:.1f}s]")
        vis = img.copy()
        for b in bl:
            x, y, w, h = b['box']
            cv2.rectangle(vis, (x, y), (x + w, y + h), (255, 200, 0), 2)
        for r in (hero_r[:4] + board_r[:6]):
            a, b = r[2], r[3]
            col = (0, 200, 0) if (r[1] in truth or r[1] in board_truth) else (0, 0, 255)
            cv2.line(vis, tuple(int(v) for v in a['c']), tuple(int(v) for v in b['c']), col, 4)
            cv2.putText(vis, f"{r[1]} {r[0]:.2f}", (int(a['c'][0]) + 20, int(a['c'][1])),
                        cv2.FONT_HERSHEY_SIMPLEX, 2.2, col, 6)
        cv2.imwrite(os.path.join(out, 'vis_' + name), cv2.resize(vis, None, fx=0.3, fy=0.3))
    print(f'\nHERO cards read: {hero_ok}/{hero_n}')
    # Classifier-only on hand-located index boxes.
    cache, rk_ok, su_ok, both_ok = {}, 0, 0, 0
    for p, code, (x0, y0, x1, y1) in HAND_BOXES:
        name = f'PXL_20261027_{p}.jpg'
        if name not in cache:
            cache[name] = cv2.imread(os.path.join(src, name))
        img = cache[name]
        roi = (x0 * 4, y0 * 4, x1 * 4, y1 * 4)
        reads, bl = read_region(img, clf, roi)
        got = reads[0][1] if reads else '--'
        rk_ok += got[0] == code[0]
        su_ok += got[1:] == code[1]
        both_ok += got == code
        report['hand'].append(dict(photo=p, truth=code, pred=got, score=round(reads[0][0], 3) if reads else 0,
                                   n_blobs=len(bl)))
        print(f'hand {p} {code} -> {got}  ({len(bl)} blobs, {len(reads)} pairs)')
    n = len(HAND_BOXES)
    print(f'HAND crops: rank {rk_ok}/{n}  suit {su_ok}/{n}  card {both_ok}/{n}')
    report['summary'] = dict(hero=f'{hero_ok}/{hero_n}', hand_rank=f'{rk_ok}/{n}', hand_suit=f'{su_ok}/{n}',
                             hand_card=f'{both_ok}/{n}')
    json.dump(report, open(os.path.join(out, 'report.json'), 'w'), indent=1)


if __name__ == '__main__':
    main()
