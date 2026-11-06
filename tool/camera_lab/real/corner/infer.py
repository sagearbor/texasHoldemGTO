"""Run CornerNet + IndexNet on an upright frame (reference for the Dart port).

  python infer.py <model_dir> <jpg> [--viz out.jpg]
"""
import math
import sys

import cv2
import numpy as np
import torch
from PIL import Image, ImageOps

import os

from models import CornerNet, IndexNet, RefineNet, to_input
from render import DET_SCALE, REF_SPAN, RANKS, SUITS, index_crop, ref_crop

STRIDE = 8


def load_models(d, dev='cpu'):
    c = CornerNet()
    c.load_state_dict(torch.load(f'{d}/corner.pt', map_location='cpu'))
    i = IndexNet()
    i.load_state_dict(torch.load(f'{d}/index.pt', map_location='cpu'))
    c, i = c.eval().to(dev), i.eval().to(dev)
    if os.path.exists(f'{d}/refine.pt'):
        r = RefineNet()
        r.load_state_dict(torch.load(f'{d}/refine.pt', map_location='cpu'))
        i.refine = r.eval().to(dev)
    return c, i


def upright(path):
    im = ImageOps.exif_transpose(Image.open(path)).convert('RGB')
    a = np.asarray(im)[:, :, ::-1]
    s = 720 / min(a.shape[:2])
    if abs(s - 1) > 0.01:
        a = cv2.resize(a, (round(a.shape[1] * s), round(a.shape[0] * s)), interpolation=cv2.INTER_AREA)
    return np.ascontiguousarray(a)


@torch.no_grad()
def detect(corner, img, thr=0.25, top=24, dev='cpu'):
    small = cv2.resize(img, (round(img.shape[1] * DET_SCALE), round(img.shape[0] * DET_SCALE)), interpolation=cv2.INTER_AREA)
    o = corner(to_input(small).to(dev))[0].cpu()
    heat = torch.sigmoid(o[0])
    mx = torch.nn.functional.max_pool2d(heat[None, None], 3, 1, 1)[0, 0]
    peaks = ((heat == mx) & (heat >= thr)).nonzero().tolist()
    peaks.sort(key=lambda p: -heat[p[0], p[1]].item())
    out = []
    for (gy, gx) in peaks[:top]:
        dx, dy = torch.sigmoid(o[1:3, gy, gx]).tolist()
        h = math.exp(o[3, gy, gx].item())
        w = math.exp(o[4, gy, gx].item())
        s, c = o[5, gy, gx].item(), o[6, gy, gx].item()
        out.append(((gx + dx) * STRIDE / DET_SCALE, (gy + dy) * STRIDE / DET_SCALE, h / DET_SCALE,
                    math.atan2(s, c), heat[gy, gx].item(), w / DET_SCALE))
    return out


REFINE_ROUNDS = 2
MAX_PEAKS = 32


@torch.no_grad()
def refine(net, img, dets, dev='cpu', rounds=None):
    rounds = REFINE_ROUNDS if rounds is None else rounds
    """RefineNet: better centre, height and angle for each detection."""
    out = list(dets)
    for _ in range(rounds):
        if not out:
            break
        crops = np.stack([ref_crop(img, d[0], d[1], d[2]) for d in out])
        o = net(to_input(crops).to(dev)).cpu().numpy()
        nxt = []
        for d, v in zip(out, o):
            x, y, h, a, p, w = d
            side = REF_SPAN * h
            nh = h * math.exp(float(np.clip(v[2], -1.2, 1.2)))
            nxt.append((x + v[0] * side, y + v[1] * side, nh, math.atan2(v[3], v[4]), p, w * nh / h))
        out = nxt
    return out


@torch.no_grad()
def classify(index, img, dets, dev='cpu'):
    if not dets:
        return []
    if getattr(index, 'refine', None) is not None:
        dets = refine(index.refine, img, dets, dev)
    crops = np.stack([index_crop(img, d[0], d[1], d[2], d[3]) for d in dets])
    lr, ls = index(to_input(crops).to(dev))
    pr = torch.softmax(lr, 1).cpu().numpy()
    ps = torch.softmax(ls, 1).cpu().numpy()
    res = []
    for k, (x, y, h, a, p, w) in enumerate(dets):
        r = int(pr[k, :13].argmax())
        s = int(ps[k].argmax())
        res.append(dict(x=x, y=y, h=h, w=w, a=a, heat=p, card=RANKS[r] + SUITS[s], pr=float(pr[k, r]),
                        pbg=float(pr[k, 13]), ps=float(ps[k, s]), score=float(pr[k, r] * ps[k, s])))
    return res


def nms(res, k=0.6):
    """Peaks that refined onto the same index: keep the best read."""
    out = []
    for r in sorted(res, key=lambda r: -r['score']):
        if all(math.hypot(r['x'] - q['x'], r['y'] - q['y']) >= k * max(r['h'], q['h']) for q in out):
            out.append(r)
    return out


def detect_multi(corner, img, thr=0.25, dev='cpu', scales=(1.0, 0.5)):
    """CornerNet on the frame and on smaller copies (indices bigger than
    about a quarter of the short side read at half size)."""
    out = []
    for s in scales:
        im = img if s == 1 else cv2.resize(img, (round(img.shape[1] * s), round(img.shape[0] * s)), interpolation=cv2.INTER_AREA)
        top = 24 if s == 1 else 8
        for (x, y, h, a, p, w) in detect(corner, im, thr, top=top, dev=dev):
            out.append((x / s, y / s, h / s, a, p, w / s))
    return out


SCALES = (1.0, 0.5)


def read(corner, index, img, dev='cpu', thr=0.25):
    d = sorted(detect_multi(corner, img, thr, dev, SCALES), key=lambda q: -q[4])[:MAX_PEAKS]
    return nms(classify(index, img, d, dev))


if __name__ == '__main__':
    c, i = load_models(sys.argv[1])
    img = upright(sys.argv[2])
    res = read(c, i, img)
    for r in res:
        print(f"{r['card']} score {r['score']:.2f} heat {r['heat']:.2f} rank {r['pr']:.2f} suit {r['ps']:.2f} "
              f"h {r['h']:.0f} at {r['x']:.0f},{r['y']:.0f} ang {math.degrees(r['a']):.0f}")
    if '--viz' in sys.argv:
        v = img.copy()
        for r in res:
            col = (0, 255, 0) if r['score'] > 0.5 else (0, 200, 255)
            ux, uy = math.sin(r['a']), -math.cos(r['a'])
            cv2.circle(v, (int(r['x']), int(r['y'])), 4, col, -1)
            cv2.line(v, (int(r['x']), int(r['y'])), (int(r['x'] + ux * r['h'] * 0.6), int(r['y'] + uy * r['h'] * 0.6)), col, 2)
            cv2.putText(v, f"{r['card']} {r['score']:.2f}", (int(r['x']) + 6, int(r['y'])), 0, 0.7, col, 2)
        cv2.imwrite(sys.argv[sys.argv.index('--viz') + 1], v)
