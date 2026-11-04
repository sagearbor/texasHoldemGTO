"""Fine-tune an existing glyph CNN checkpoint on new synthetic crops.

Starting from the shipped model (trained on standard-deck synthetics)
keeps what it already reads well; a few low-rate epochs on the any-deck
mix add artwork backgrounds and new faces.

  python finetune.py <init.pt> <train.npz> <val.npz> <out.pt> [epochs] [max_lr]
"""
import os
import sys
import time

import numpy as np
import torch
import torch.nn as nn

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'real', 'learned'))
from common import CLASSES, make_model  # noqa: E402


def main():
    init, tr, va, out = sys.argv[1:5]
    epochs = int(sys.argv[5]) if len(sys.argv) > 5 else 5
    max_lr = float(sys.argv[6]) if len(sys.argv) > 6 else 1e-3
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    torch.manual_seed(0)
    ck = torch.load(init, map_location='cpu')
    m = make_model(ck['width'])
    m.load_state_dict(ck['state'])
    m.to(dev)
    d = np.load(tr)
    X = torch.tensor(d['X']).float().div(255).unsqueeze(1)
    y = torch.tensor(d['y'])
    v = np.load(va)
    Xv = torch.tensor(v['X']).float().div(255).unsqueeze(1).to(dev)
    yv = torch.tensor(v['y']).to(dev)

    def val():
        m.eval()
        with torch.no_grad():
            pv = torch.cat([m(Xv[i:i + 1024]).argmax(1) for i in range(0, len(Xv), 1024)])
        return (pv == yv).float().mean().item()
    print(f'init val {val():.4f}', flush=True)
    opt = torch.optim.AdamW(m.parameters(), max_lr / 3, weight_decay=1e-4)
    bs = 256
    steps = epochs * (len(X) // bs)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr, total_steps=steps)
    lossf = nn.CrossEntropyLoss(label_smoothing=0.05)
    best = 0
    for ep in range(epochs):
        m.train()
        t0 = time.time()
        perm = torch.randperm(len(X))
        for i in range(len(X) // bs):
            idx = perm[i * bs:(i + 1) * bs]
            xb, yb = X[idx].to(dev), y[idx].to(dev)
            xb = (xb - 0.5) * (0.7 + 0.6 * torch.rand(len(xb), 1, 1, 1, device=dev)) + 0.5 \
                + 0.15 * (torch.rand(len(xb), 1, 1, 1, device=dev) - 0.5)
            sh = np.random.randint(-2, 3, 2)
            xb = torch.roll(xb, (int(sh[0]), int(sh[1])), (2, 3))
            loss = lossf(m(xb), yb)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
        acc = val()
        print(f'ep {ep} loss {loss.item():.3f} val {acc:.4f} {time.time() - t0:.0f}s', flush=True)
        if acc >= best:
            best = acc
            torch.save({'state': m.state_dict(), 'width': ck['width'], 'classes': CLASSES}, out)
    print('best val', best)


if __name__ == '__main__':
    main()
