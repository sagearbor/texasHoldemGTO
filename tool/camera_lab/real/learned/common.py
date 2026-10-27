"""Shared bits: class list, crop normalisation and the tiny CNN."""
import cv2
import numpy as np

RANKS = '23456789TJQKA'
SUITS = 'cdhs'
CLASSES = list(RANKS) + list(SUITS) + ['bg']
RANK_LABEL = {r: ('10' if r == 'T' else r) for r in RANKS}
SUIT_CHAR = {'c': '♣', 'd': '♦', 'h': '♥', 's': '♠'}
IN = 32


def crop_from_mask(bgr, mask, jitter=0.0, rng=None, pad=1.3):
    """Square crop around the glyph mask's bbox -> 32x32 uint8 'ink' image.
    Green channel (red and black ink both dark), percentile contrast stretch."""
    ys, xs = np.nonzero(mask)
    if len(ys) < 4:
        return None
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    side = max(x1 - x0, y1 - y0) * pad
    if jitter and rng is not None:
        cx += rng.uniform(-jitter, jitter) * side
        cy += rng.uniform(-jitter, jitter) * side
        side *= 1 + rng.uniform(-jitter, jitter)
    side = max(side, 6)
    M = np.float32([[IN / side, 0, IN / 2 - cx * IN / side], [0, IN / side, IN / 2 - cy * IN / side]])
    g = bgr[:, :, 1] if bgr.ndim == 3 else bgr
    out = cv2.warpAffine(g, M, (IN, IN), flags=cv2.INTER_AREA if side > IN else cv2.INTER_LINEAR,
                         borderMode=cv2.BORDER_REPLICATE)
    lo, hi = np.percentile(out, 2), np.percentile(out, 98)
    out = np.clip((out.astype(np.float32) - lo) * 255 / max(hi - lo, 20), 0, 255)
    return out.astype(np.uint8)


def make_model(width=16):
    import torch.nn as nn
    w = width

    def blk(i, o):
        return nn.Sequential(nn.Conv2d(i, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True))
    return nn.Sequential(
        blk(1, w), blk(w, w), nn.MaxPool2d(2),            # 16
        blk(w, 2 * w), blk(2 * w, 2 * w), nn.MaxPool2d(2),  # 8
        blk(2 * w, 4 * w), blk(4 * w, 4 * w), nn.MaxPool2d(2),  # 4
        nn.Flatten(), nn.Dropout(0.3), nn.Linear(4 * w * 16, 128), nn.ReLU(inplace=True),
        nn.Linear(128, len(CLASSES)))
