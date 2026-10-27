"""Export the synthetic-trained glyph CNN to a compact int8 asset for Dart.

Input : the PyTorch checkpoint from tool/camera_lab/real/learned/train.py
        (model = common.make_model: 6 x [conv3x3 no-bias, BN, ReLU] with a
        2x2 max-pool after every 2nd conv, then FC 1024->128, ReLU,
        FC 128->18; input 1x32x32 grey / 255; 18 classes = 13 ranks
        '23456789TJQKA', 4 suits 'cdhs', 'bg').
Output: assets/data/glyph_cnn.bin           (~210 KB, read by
                                             lib/camera/glyph_cnn.dart)
        test/fixtures/glyph_cnn_vectors.bin (inputs + expected logits for
                                             test/glyph_cnn_test.dart)

BatchNorm is folded into the conv weights and biases. Weights are
quantised to int8 symmetric per output channel (float32 scale per
channel), biases stay float32. The Dart forward pass dequantises at load,
so it must reproduce the logits of the DEQUANTISED model (stored in the
fixture) to float32 rounding; agreement of the int8 model with the fp32
original is printed here.

The fixture inputs are crops of glyphs rendered from macOS fonts (rotated,
blurred, noisy) plus random noise: no photo pixels.

  python tool/camera_lab/export_glyph_cnn.py <w16v2.pt> [val.npz]

File format (little endian): 'FNCN', u8 version 1, u8 nLayers (8), then per
layer: u8 type (0 conv3x3 pad1 + ReLU [+ pool2 if flag], 1 linear [+ ReLU if
flag]), u8 flag, u16 out, u16 in, int8 weights (out*in*9 or out*in),
f32 scale[out], f32 bias[out].
"""
import os
import struct
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'real', 'classical'))

# Same definitions as tool/camera_lab/real/learned/common.py (the training
# code), inlined so this exporter stands alone.
CLASSES = list('23456789TJQKA') + list('cdhs') + ['bg']
IN = 32


def crop_from_mask(bgr, mask, pad=1.3):
    import cv2
    ys, xs = np.nonzero(mask)
    if len(ys) < 4:
        return None
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    side = max(max(x1 - x0, y1 - y0) * pad, 6)
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
        blk(1, w), blk(w, w), nn.MaxPool2d(2),
        blk(w, 2 * w), blk(2 * w, 2 * w), nn.MaxPool2d(2),
        blk(2 * w, 4 * w), blk(4 * w, 4 * w), nn.MaxPool2d(2),
        nn.Flatten(), nn.Dropout(0.3), nn.Linear(4 * w * 16, 128), nn.ReLU(inplace=True),
        nn.Linear(128, len(CLASSES)))

ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
OUT = os.path.join(ROOT, 'assets', 'data', 'glyph_cnn.bin')
FIX = os.path.join(ROOT, 'test', 'fixtures', 'glyph_cnn_vectors.bin')


def fold(model):
    """[(kind, flag, W (out,in,3,3)|(out,in), b)] with BN folded."""
    mods = list(model)
    layers = []
    for i, m in enumerate(mods):
        if isinstance(m, torch.nn.Sequential):  # conv, bn, relu
            conv, bn = m[0], m[1]
            w = conv.weight.detach().numpy().astype(np.float64)
            g = (bn.weight / torch.sqrt(bn.running_var + bn.eps)).detach().numpy().astype(np.float64)
            b = (bn.bias - bn.running_mean * bn.weight / torch.sqrt(bn.running_var + bn.eps)).detach().numpy()
            pool = i + 1 < len(mods) and isinstance(mods[i + 1], torch.nn.MaxPool2d)
            layers.append((0, int(pool), w * g[:, None, None, None], b.astype(np.float64)))
        elif isinstance(m, torch.nn.Linear):
            relu = i + 1 < len(mods) and isinstance(mods[i + 1], torch.nn.ReLU)
            layers.append((1, int(relu), m.weight.detach().numpy().astype(np.float64),
                           m.bias.detach().numpy().astype(np.float64)))
    return layers


def quant(w):
    flat = w.reshape(w.shape[0], -1)
    scale = np.abs(flat).max(1) / 127.0
    scale[scale == 0] = 1.0
    q = np.clip(np.round(flat / scale[:, None]), -127, 127).astype(np.int8)
    return q, scale.astype(np.float32)


def forward(layers, x):
    """Numpy forward with (dequantised) layers; x (N,1,32,32) float."""
    import torch.nn.functional as F
    t = torch.from_numpy(x.astype(np.float32))
    for kind, flag, w, b in layers:
        if kind == 0:
            t = F.relu(F.conv2d(t, torch.from_numpy(w.astype(np.float32)), torch.from_numpy(b.astype(np.float32)),
                                padding=1))
            if flag:
                t = F.max_pool2d(t, 2)
        else:
            t = t.reshape(t.shape[0], -1)
            t = F.linear(t, torch.from_numpy(w.astype(np.float32)), torch.from_numpy(b.astype(np.float32)))
            if flag:
                t = F.relu(t)
    return t.numpy()


def font_crops(n, rng):
    """Rendered font glyphs, rotated / blurred / noisy, through crop_from_mask."""
    import cv2
    import glyphs as G
    chars = [(lab, G.RANK_LABELS[lab]) for lab in G.RANK_LABELS] + [(s, ch) for s, ch in G.SUIT_CHARS.items()]
    fonts = [p for p, _ in G.RANK_FONTS if os.path.exists(p)]
    sfonts = [p for p, _ in G.SUIT_FONTS if os.path.exists(p)]
    out = []
    while len(out) < n:
        lab, ch = chars[rng.integers(len(chars))]
        path = (sfonts if lab in G.SUIT_CHARS else fonts)[rng.integers(len(sfonts if lab in G.SUIT_CHARS else fonts))]
        m = G._render(ch, path, 0, size=int(rng.integers(30, 90)))
        if m is None:
            continue
        a = 255 - m  # dark ink on white
        h, w = a.shape
        M = cv2.getRotationMatrix2D((w / 2, h / 2), float(rng.normal(0, 10)), 1.0)
        a = cv2.warpAffine(a, M, (w, h), borderValue=255)
        a = cv2.GaussianBlur(a, (0, 0), float(rng.uniform(0.3, 1.5)))
        a = np.clip(a + rng.normal(0, 8, a.shape), 0, 255).astype(np.uint8)
        c = crop_from_mask(np.dstack([a] * 3), a < 128)
        if c is not None:
            out.append(c)
    return np.stack(out)


def main():
    ck = torch.load(sys.argv[1], map_location='cpu')
    model = make_model(ck['width'])
    model.load_state_dict(ck['state'])
    model.eval()
    layers = fold(model)
    qlayers, deq = [], []
    for kind, flag, w, b in layers:
        q, s = quant(w)
        qlayers.append((kind, flag, q, s, b.astype(np.float32), w.shape))
        deq.append((kind, flag, (q.astype(np.float64) * s[:, None]).reshape(w.shape), b.astype(np.float32)))
    blob = bytearray(b'FNCN' + struct.pack('<BB', 1, len(qlayers)))
    for kind, flag, q, s, b, shape in qlayers:
        blob += struct.pack('<BBHH', kind, flag, shape[0], shape[1])
        blob += q.tobytes() + s.astype('<f4').tobytes() + b.astype('<f4').tobytes()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(blob)
    print('wrote', OUT, len(blob), 'bytes')

    rng = np.random.default_rng(0)
    X = np.concatenate([font_crops(250, rng), rng.integers(0, 256, (50, 32, 32)).astype(np.uint8)])
    x = X[:, None].astype(np.float32) / 255
    with torch.no_grad():
        ref = model(torch.from_numpy(x)).numpy()
    lg = forward(deq, x)
    print('fixture: argmax agreement int8 vs fp32 %.3f, max |logit diff| %.3f' % (
        (lg.argmax(1) == ref.argmax(1)).mean(), np.abs(lg - ref).max()))
    os.makedirs(os.path.dirname(FIX), exist_ok=True)
    with open(FIX, 'wb') as f:
        f.write(struct.pack('<II', len(X), lg.shape[1]))
        f.write(X.astype(np.uint8).tobytes())
        f.write(lg.astype('<f4').tobytes())
    print('wrote', FIX, os.path.getsize(FIX), 'bytes')
    if len(sys.argv) > 2:  # synthetic val set: int8 vs fp32 accuracy
        v = np.load(sys.argv[2])
        xv = v['X'][:5000, None].astype(np.float32) / 255
        yv = v['y'][:5000]
        with torch.no_grad():
            p32 = model(torch.from_numpy(xv)).numpy().argmax(1)
        p8 = forward(deq, xv).argmax(1)
        print('val (5000): fp32 acc %.4f, int8 acc %.4f, agreement %.4f' % (
            (p32 == yv).mean(), (p8 == yv).mean(), (p8 == p32).mean()))
    print('classes', ''.join(c if len(c) == 1 else '_' for c in CLASSES))


if __name__ == '__main__':
    main()
