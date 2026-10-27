"""Train the glyph CNN on synthetic crops only.
  python train.py <train.npz> <val.npz> <out.pt> [epochs] [width]
"""
import sys
import time

import numpy as np
import torch
import torch.nn as nn

from common import CLASSES, make_model


def main():
    tr, va, out = sys.argv[1:4]
    epochs = int(sys.argv[4]) if len(sys.argv) > 4 else 10
    width = int(sys.argv[5]) if len(sys.argv) > 5 else 16
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    torch.manual_seed(0)
    d = np.load(tr)
    X = torch.tensor(d['X']).float().div(255).unsqueeze(1)
    y = torch.tensor(d['y'])
    v = np.load(va)
    Xv = torch.tensor(v['X']).float().div(255).unsqueeze(1).to(dev)
    yv = torch.tensor(v['y']).to(dev)
    m = make_model(width).to(dev)
    nparam = sum(p.numel() for p in m.parameters())
    print(f'params {nparam} (~{nparam * 4 / 1e6:.2f} MB fp32) device {dev}')
    opt = torch.optim.AdamW(m.parameters(), 2e-3, weight_decay=1e-4)
    bs = 256
    steps = epochs * (len(X) // bs)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, 3e-3, total_steps=steps)
    lossf = nn.CrossEntropyLoss(label_smoothing=0.05)
    best = 0
    for ep in range(epochs):
        m.train()
        t0 = time.time()
        perm = torch.randperm(len(X))
        for i in range(len(X) // bs):
            idx = perm[i * bs:(i + 1) * bs]
            xb, yb = X[idx].to(dev), y[idx].to(dev)
            # cheap extra aug: random brightness/contrast + small shifts
            xb = (xb - 0.5) * (0.7 + 0.6 * torch.rand(len(xb), 1, 1, 1, device=dev)) + 0.5 \
                + 0.15 * (torch.rand(len(xb), 1, 1, 1, device=dev) - 0.5)
            sh = np.random.randint(-2, 3, 2)
            xb = torch.roll(xb, (int(sh[0]), int(sh[1])), (2, 3))
            loss = lossf(m(xb), yb)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
        m.eval()
        with torch.no_grad():
            pv = torch.cat([m(Xv[i:i + 1024]).argmax(1) for i in range(0, len(Xv), 1024)])
        acc = (pv == yv).float().mean().item()
        print(f'ep {ep} loss {loss.item():.3f} val {acc:.4f} {time.time() - t0:.0f}s', flush=True)
        if acc >= best:
            best = acc
            torch.save({'state': m.state_dict(), 'width': width, 'classes': CLASSES}, out)
    print('best val', best)


if __name__ == '__main__':
    main()
