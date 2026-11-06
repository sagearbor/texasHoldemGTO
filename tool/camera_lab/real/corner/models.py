"""The two small networks behind lib/camera/corner_detector.dart.

CornerNet: fully convolutional, upright frame at 0.4x the 720p short side
(288 px) -> stride-8 grid of [heat, dx, dy, log h, log w, sin, cos]:
  heat   a corner index (rank over suit) is centred in this cell
  dx dy  its centre within the cell (0..1, sigmoid)
  log h  the rank+suit box height in input pixels
  log w  its width across the card
  sin cos its "up" direction (0 = upright, + clockwise)

RefineNet: a 48x48 window (image axes, 2 detected index heights wide)
around a CornerNet peak -> the index's centre offset over the window
side, log of its true height over the detected one, and its "up" as
sin, cos. CornerNet's stride-8 angle and size are too rough to crop the
index upright (Nov 6 audit: 29 degrees median error on real stills,
heights 0.7x); RefineNet sees the glyphs at full resolution.

IndexNet: an index-aligned 32x24 RGB crop (the box's height x 1.25 by
height x 0.95, see render.index_crop) -> 13 ranks + "not an index", and
4 suits.

Plain conv / depthwise / pointwise layers, BatchNorm folded at export:
the Dart forward pass (lib/camera/corner_net.dart) has no other ops.
"""
import torch
import torch.nn as nn


def cbr(i, o, k=3, s=1, d=1, groups=1):
    return nn.Sequential(nn.Conv2d(i, o, k, s, padding=d * (k // 2), dilation=d, groups=groups, bias=False),
                         nn.BatchNorm2d(o), nn.ReLU(inplace=True))


def dws(i, o, s=1, d=1):
    return nn.Sequential(cbr(i, i, 3, s, d, groups=i), cbr(i, o, 1))


class CornerNet(nn.Module):
    def __init__(self, w=(12, 24, 32, 48)):
        super().__init__()
        a, b, c, e = w
        self.body = nn.Sequential(
            cbr(3, a, 3, 2),          # /2
            dws(a, b, 2),             # /4
            dws(b, b),
            dws(b, c, 2),             # /8
            dws(c, e),
            dws(e, e, d=2),
            dws(e, e, d=4),
            dws(e, e, d=8),
            cbr(e, 32, 1),
        )
        self.head = nn.Conv2d(32, 7, 1)

    def forward(self, x):
        return self.head(self.body(x))


class IndexNet(nn.Module):
    def __init__(self, w=(16, 32, 64)):
        super().__init__()
        a, b, c = w
        self.body = nn.Sequential(
            cbr(3, a), cbr(a, a), nn.MaxPool2d(2),   # 16x12
            cbr(a, b), cbr(b, b), nn.MaxPool2d(2),   # 8x6
            cbr(b, c), cbr(c, c), nn.MaxPool2d(2),   # 4x3
            nn.Flatten(), nn.Dropout(0.25), nn.Linear(c * 12, 128), nn.ReLU(inplace=True))
        self.rank = nn.Linear(128, 14)
        self.suit = nn.Linear(128, 4)

    def forward(self, x):
        f = self.body(x)
        return self.rank(f), self.suit(f)


class RefineNet(nn.Module):
    def __init__(self, w=(16, 32, 48, 64)):
        super().__init__()
        a, b, c, d = w
        self.body = nn.Sequential(
            cbr(3, a), cbr(a, a), nn.MaxPool2d(2),   # 24
            cbr(a, b), cbr(b, b), nn.MaxPool2d(2),   # 12
            cbr(b, c), cbr(c, c), nn.MaxPool2d(2),   # 6
            cbr(c, d), nn.MaxPool2d(2),              # 3
            nn.Flatten(), nn.Linear(d * 9, 128), nn.ReLU(inplace=True))
        self.out = nn.Linear(128, 5)

    def forward(self, x):
        return self.out(self.body(x))


def to_input(bgr_u8):
    """HxWx3 BGR uint8 (numpy) batch or single -> float tensor NCHW in [-1, 1] (RGB order)."""
    t = torch.as_tensor(bgr_u8)
    if t.dim() == 3:
        t = t[None]
    t = t[..., [2, 1, 0]].permute(0, 3, 1, 2).float()
    return t / 127.5 - 1
