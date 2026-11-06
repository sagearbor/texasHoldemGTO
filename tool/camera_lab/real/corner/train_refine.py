"""Train RefineNet on render.py shards (rx, rt) + real windows.

  python train_refine.py <data_dirs,comma> <out_dir> --holdout 9JF3 [--real real.npz] [--epochs 20]

--real: real windows from oldboxes.py boxes of the training recordings
(refine_real.py).
"""
import argparse
import glob
import os
import time

import numpy as np
import torch
import torch.nn.functional as F

from models import RefineNet, to_input
from train import augment_det


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('data')
    ap.add_argument('out')
    ap.add_argument('--holdout', default='none')
    ap.add_argument('--real')
    ap.add_argument('--epochs', type=int, default=20)
    a = ap.parse_args()
    xs, ts = [], []
    for f in sorted(f for d in a.data.split(',') for f in glob.glob(os.path.join(d, 'scenes_*.npz'))):
        z = np.load(f)
        if 'rx' not in z.files:
            continue
        tags = list(z['tags'])
        bad = tags.index(a.holdout) if a.holdout in tags else -1
        k = z['rtag'] != bad
        xs.append(z['rx'][k])
        ts.append(z['rt'][k])
    X, T = np.concatenate(xs), np.concatenate(ts)
    if a.real:
        r = np.load(a.real)
        X = np.concatenate([X] + [r['rx']] * 5)
        T = np.concatenate([T] + [r['rt']] * 5)
    print(len(X), 'windows', flush=True)
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    rng = np.random.default_rng(0)
    torch.manual_seed(0)
    net = RefineNet().to(dev)
    bs = 256
    steps = a.epochs * (len(X) // bs)
    opt = torch.optim.AdamW(net.parameters(), 2e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, 2e-3, total_steps=steps, pct_start=0.1)
    t0 = time.time()
    for ep in range(a.epochs):
        perm = rng.permutation(len(X))
        tot, aerr = 0, []
        for k in range(len(X) // bs):
            idx = perm[k * bs:(k + 1) * bs]
            x = augment_det(to_input(X[idx]).to(dev), rng)
            t = torch.as_tensor(T[idx], device=dev)
            o = net(x)
            sc = F.normalize(o[:, 3:5], dim=1)
            loss = (o[:, :3] - t[:, :3]).abs().sum(1).mean() + 2 * (sc - t[:, 3:5]).abs().sum(1).mean()
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            tot += loss.item()
            if k % 20 == 0:
                d = torch.atan2(sc[:, 0], sc[:, 1]) - torch.atan2(t[:, 3], t[:, 4])
                aerr.append(torch.rad2deg(torch.remainder(d + np.pi, 2 * np.pi) - np.pi).abs().median().item())
        print(f'ref ep {ep} loss {tot / (len(X) // bs):.3f} angle err {np.median(aerr):.1f} {time.time() - t0:.0f}s', flush=True)
    torch.save(net.state_dict(), os.path.join(a.out, 'refine.pt'))


if __name__ == '__main__':
    main()
