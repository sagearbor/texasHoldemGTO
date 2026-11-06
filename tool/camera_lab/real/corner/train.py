"""Train CornerNet and IndexNet on render.py shards (+ optional real crops).

  python train.py <data_dir> <out_dir> --holdout CZE2 [--det-epochs 25] [--cls-epochs 20]
                  [--real real_crops.npz] [--real-det real_det.npz]

--holdout: drop scenes whose background still came from this recording
(leave-one-recording-out). --real / --real-det: crops and detector
samples cut from the owner's stills (pseudo-labelled, see pseudo.py),
already restricted to the training recordings.
"""
import argparse
import glob
import math
import os
import time

import numpy as np
import torch
import torch.nn.functional as F

from models import CornerNet, IndexNet, to_input

STRIDE = 8


def load(data_dir, holdout, max_det=1200):
    """Each array is read once per shard (an npz member decompresses in full
    on every access); detector ignore masks stay bit-packed."""
    det, ign, tgt, cx, cr, cs = [], [], [], [], [], []
    for f in sorted(f for d in data_dir.split(',') for f in glob.glob(os.path.join(d, 'scenes_*.npz'))):
        z = np.load(f)
        tags = list(z['tags'])
        bad = tags.index(holdout) if holdout in tags else -1
        dtag, toff, t = z['dtag'], z['toff'], z['t']
        keep = np.nonzero(dtag != bad)[0][:max_det]
        d = z['det']
        det.append(d[keep])
        del d
        ign.append(z['ign'][keep])
        tgt.extend(t[toff[i]:toff[i + 1]] for i in keep)
        k = z['ctag'] != bad
        cx.append(z['cx'][k])
        cr.append(z['cr'][k])
        cs.append(z['cs'][k])
        del z
    return (np.concatenate(det), np.concatenate(ign), tgt,
            np.concatenate(cx), np.concatenate(cr), np.concatenate(cs))


def det_targets(t, ign, size=256):
    """Heatmap, regression targets and weights on the stride-8 grid."""
    G = size // STRIDE
    heat = np.zeros((G, G), np.float32)
    reg = np.zeros((6, G, G), np.float32)
    regm = np.zeros((G, G), np.float32)
    ignore = (ign.reshape(G, STRIDE, G, STRIDE).mean((1, 3)) > 0.5).astype(np.float32)
    yy, xx = np.mgrid[0:G, 0:G]
    for (x, y, h, w, ang, r, s, vis) in t:
        gx, gy = x / STRIDE, y / STRIDE
        if not (-1 <= gx < G + 1 and -1 <= gy < G + 1):
            continue
        ix, iy = int(math.floor(gx)), int(math.floor(gy))
        pos = vis >= 0.75 and h >= 4
        if not pos:
            if vis >= 0.25 and h >= 2.5:
                r_ = max(1, int(round(h / STRIDE * 0.5)))
                ignore[max(0, iy - r_):iy + r_ + 1, max(0, ix - r_):ix + r_ + 1] = 1
            continue
        sig = max(0.55, 0.15 * h / STRIDE)
        g = np.exp(-((xx + 0.5 - gx) ** 2 + (yy + 0.5 - gy) ** 2) / (2 * sig * sig))
        heat = np.maximum(heat, g)
        if 0 <= ix < G and 0 <= iy < G:
            heat[iy, ix] = 1.0
            reg[:, iy, ix] = [gx - ix, gy - iy, math.log(h), math.log(max(w, 1.0)), math.sin(ang), math.cos(ang)]
            regm[iy, ix] = 1
            ignore[iy, ix] = 0
    # Positive peaks are never ignored; the rest of a white real region is.
    ignore[heat > 0.3] = 0
    return heat, reg, regm, ignore


def focal(pred, gt, ignore):
    p = torch.sigmoid(pred).clamp(1e-4, 1 - 1e-4)
    pos = gt.eq(1).float()
    neg = (1 - pos) * (1 - ignore)
    pl = -torch.log(p) * (1 - p) ** 2 * pos
    nl = -torch.log(1 - p) * p ** 2 * (1 - gt) ** 4 * neg
    n = pos.sum().clamp(min=1)
    return (pl.sum() + nl.sum()) / n


def augment_det(x, rng):
    # x: N,3,H,W in [-1,1]; colour jitter per sample.
    n = x.shape[0]
    g = torch.as_tensor(rng.uniform(0.75, 1.25, (n, 3, 1, 1)), dtype=x.dtype, device=x.device)
    b = torch.as_tensor(rng.uniform(-0.15, 0.15, (n, 1, 1, 1)), dtype=x.dtype, device=x.device)
    return ((x + 1) * g - 1 + b).clamp(-1, 1)


def train_det(det, ign, tgt, out, epochs, dev, rng, real=None, rep=6, init=None, lr=2e-3):
    net = CornerNet().to(dev)
    if init:
        net.load_state_dict(torch.load(init, map_location='cpu'))
    imgs, packed, tgt = det, ign, list(tgt)
    if real is not None:
        imgs = np.concatenate([imgs] + [real['det']] * rep)
        packed = np.concatenate([packed] + [real['ign']] * rep)
        tgt += [real['t'][real['toff'][k]:real['toff'][k + 1]] for k in range(len(real['det']))] * rep

    def batch_targets(idx):
        ts = [det_targets(tgt[i], np.unpackbits(packed[i])[:256 * 256].reshape(256, 256)) for i in idx]
        return [np.stack([t[j] for t in ts]).astype(np.float32) for j in range(4)]
    N = len(imgs)
    bs = 64
    steps = epochs * (N // bs)
    opt = torch.optim.AdamW(net.parameters(), lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, lr, total_steps=steps, pct_start=0.1)
    t0 = time.time()
    step = 0
    for ep in range(epochs):
        perm = rng.permutation(N)
        tot = 0
        for k in range(N // bs):
            idx = perm[k * bs:(k + 1) * bs]
            x = augment_det(to_input(imgs[idx]).to(dev), rng)
            h, r, m, ig = (torch.as_tensor(a, device=dev) for a in batch_targets(idx))
            o = net(x)
            lh = focal(o[:, 0], h, ig)
            nm = m.sum().clamp(min=1)
            off = (torch.sigmoid(o[:, 1:3]) - r[:, 0:2]).abs().sum(1)
            lsz = (o[:, 3] - r[:, 2]).abs() + (o[:, 4] - r[:, 3]).abs()
            sc = F.normalize(o[:, 5:7], dim=1)
            lang = (sc - r[:, 4:6]).abs().sum(1)
            lr_ = ((off + lsz + lang) * m).sum() / nm
            loss = lh + lr_
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            step += 1
            tot += loss.item()
        print(f'det ep {ep} loss {tot / (N // bs):.3f} {time.time() - t0:.0f}s', flush=True)
    torch.save(net.state_dict(), os.path.join(out, 'corner.pt'))
    return net


def train_cls(cx, cr, cs, out, epochs, dev, rng, real=None, init=None, lr=2e-3):
    net = IndexNet().to(dev)
    if init:
        net.load_state_dict(torch.load(init, map_location='cpu'))
    if real is not None:
        cx = np.concatenate([cx] + [real['cx']] * 3)
        cr = np.concatenate([cr] + [real['cr']] * 3)
        cs = np.concatenate([cs] + [real['cs']] * 3)
    N = len(cx)
    bs = 256
    steps = epochs * (N // bs)
    opt = torch.optim.AdamW(net.parameters(), lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, lr, total_steps=steps, pct_start=0.1)
    t0 = time.time()
    for ep in range(epochs):
        perm = rng.permutation(N)
        tot, acc, n = 0, 0, 0
        net.train()
        for k in range(N // bs):
            idx = perm[k * bs:(k + 1) * bs]
            x = augment_det(to_input(cx[idx]).to(dev), rng)
            r = torch.as_tensor(cr[idx].astype(np.int64), device=dev)
            s = torch.as_tensor(cs[idx].astype(np.int64), device=dev)
            lr, ls = net(x)
            loss = F.cross_entropy(lr, r) + F.cross_entropy(ls, s.clamp(min=0), reduction='none')[s >= 0].mean()
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            tot += loss.item()
            acc += (lr.argmax(1) == r).float().sum().item()
            n += len(idx)
        print(f'cls ep {ep} loss {tot / (N // bs):.3f} rank acc {acc / n:.3f} {time.time() - t0:.0f}s', flush=True)
    torch.save(net.state_dict(), os.path.join(out, 'index.pt'))
    return net


def merge_real(spec):
    """Comma-separated real npz files (pseudo.py, hardneg.py) as one."""
    if not spec:
        return None
    parts = [dict(np.load(f)) for f in spec.split(',')]
    if len(parts) == 1:
        return parts[0]
    out = {}
    for k in ('cx', 'cr', 'cs', 'det', 'ign', 't'):
        out[k] = np.concatenate([p[k] for p in parts if k in p and len(p[k])])
    toff, base = [0], 0
    for p in parts:
        toff.extend(int(v) + base for v in p['toff'][1:])
        base += int(p['toff'][-1])
    out['toff'] = np.int64(toff)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('data')
    ap.add_argument('out')
    ap.add_argument('--holdout', default='none')
    ap.add_argument('--det-epochs', type=int, default=25)
    ap.add_argument('--cls-epochs', type=int, default=20)
    ap.add_argument('--real')
    ap.add_argument('--real-det')
    ap.add_argument('--real-rep', type=int, default=6)
    ap.add_argument('--only', choices=['det', 'cls'])
    ap.add_argument('--max-det', type=int, default=1200, help='detector crops per shard (memory)')
    ap.add_argument('--init', help='model dir to fine-tune from (corner.pt / index.pt)')
    ap.add_argument('--lr', type=float, default=2e-3)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    rng = np.random.default_rng(0)
    torch.manual_seed(0)
    det, ign, tgt, cx, cr, cs = load(a.data, a.holdout, a.max_det)
    print(f'{len(det)} detector crops, {len(cx)} index crops (holdout {a.holdout})', flush=True)
    real = merge_real(a.real)
    real_det = merge_real(a.real_det)
    if a.only != 'cls':
        train_det(det, ign, tgt, a.out, a.det_epochs, dev, rng, real_det, a.real_rep,
                  init=a.init and os.path.join(a.init, 'corner.pt'), lr=a.lr)
    if a.only != 'det':
        train_cls(cx, cr, cs, a.out, a.cls_epochs, dev, rng, real,
                  init=a.init and os.path.join(a.init, 'index.pt'), lr=a.lr)


if __name__ == '__main__':
    main()
