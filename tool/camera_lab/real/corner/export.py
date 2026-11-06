"""Export CornerNet + IndexNet + RefineNet to assets/data/corner_net.bin for Dart.

  python export.py <model_dir> <out.bin> [<fixture.bin>]

BatchNorm is folded into each conv; weights are int8 per output channel
(float32 scale), biases float32. IndexNet's two heads are written as one
linear layer: 14 rank logits then 4 suit logits. Linear weights that
follow a flatten are reordered from PyTorch's CHW order to the HWC order
the Dart pass keeps activations in.

File (little endian): 'FNTN', u8 version 1, u8 networks (3: CornerNet, IndexNet, RefineNet); per network:
u16 ops, u16 input channels; per op a u8 type:
  0 conv   u8 k, u8 stride, u8 dilation, u8 depthwise, u8 relu, u16 in, u16 out,
           int8 w[out][in or 1][k][k], f32 scale[out], f32 bias[out]
  1 maxpool 2x2
  2 linear u8 relu, u16 in, u16 out, u16 flatH, u16 flatW, int8 w[out][in] (HWC order),
           f32 scale[out], f32 bias[out]

The fixture (for test/corner_net_test.dart) holds a few inputs and the
dequantised model's outputs:
  'FNTF', u16 n, then per case: u8 net, u16 h, u16 w, u16 c, f32 input HWC,
  u16 oh, u16 ow, u16 oc, f32 output HWC.
"""
import struct
import sys

import numpy as np
import torch
import torch.nn as nn

from models import CornerNet, IndexNet, RefineNet


def fold(conv, bn):
    w = conv.weight.detach().double()
    g = bn.weight.detach().double() / torch.sqrt(bn.running_var.double() + bn.eps)
    w = w * g[:, None, None, None]
    b = bn.bias.detach().double() - bn.running_mean.double() * g
    if conv.bias is not None:
        b = b + conv.bias.detach().double() * g
    return w.numpy(), b.numpy()


def q8(w):
    flat = w.reshape(w.shape[0], -1)
    scale = np.abs(flat).max(1) / 127
    scale[scale == 0] = 1e-8
    q = np.clip(np.round(flat / scale[:, None]), -127, 127).astype(np.int8)
    return q, scale.astype(np.float32), (q.astype(np.float64) * scale[:, None]).reshape(w.shape)


def ops_of(model):
    """Flatten the model into (kind, params) with BN folded (float64 weights)."""
    ops = []

    def walk(m):
        if isinstance(m, nn.Sequential):
            mods = list(m)
            i = 0
            while i < len(mods):
                x = mods[i]
                if isinstance(x, nn.Conv2d):
                    bn = mods[i + 1] if i + 1 < len(mods) and isinstance(mods[i + 1], nn.BatchNorm2d) else None
                    relu = any(isinstance(y, nn.ReLU) for y in mods[i + 1:i + 3])
                    if bn is not None:
                        w, b = fold(x, bn)
                    else:
                        w = x.weight.detach().double().numpy()
                        b = x.bias.detach().double().numpy()
                    ops.append(('conv', dict(k=x.kernel_size[0], s=x.stride[0], d=x.dilation[0],
                                             dw=int(x.groups > 1), relu=int(relu), w=w, b=b,
                                             cin=x.in_channels, cout=x.out_channels)))
                    i += 1 + (bn is not None) + int(relu)
                    continue
                if isinstance(x, nn.MaxPool2d):
                    ops.append(('pool', {}))
                elif isinstance(x, nn.Linear):
                    relu = i + 1 < len(mods) and isinstance(mods[i + 1], nn.ReLU)
                    ops.append(('linear', dict(relu=int(relu), w=x.weight.detach().double().numpy(),
                                               b=x.bias.detach().double().numpy())))
                    i += 1 + int(relu)
                    continue
                elif isinstance(x, (nn.Flatten, nn.Dropout, nn.ReLU)):
                    pass
                else:
                    walk(x)
                i += 1
        else:
            for c in m.children():
                walk(c)

    walk(model)
    return ops


def corner_ops(m):
    ops = ops_of(m.body)
    w = m.head.weight.detach().double().numpy()
    ops.append(('conv', dict(k=1, s=1, d=1, dw=0, relu=0, w=w, b=m.head.bias.detach().double().numpy(),
                             cin=w.shape[1], cout=w.shape[0])))
    return ops


def index_ops(m):
    ops = ops_of(m.body)
    w = np.concatenate([m.rank.weight.detach().double().numpy(), m.suit.weight.detach().double().numpy()])
    b = np.concatenate([m.rank.bias.detach().double().numpy(), m.suit.bias.detach().double().numpy()])
    ops.append(('linear', dict(relu=0, w=w, b=b)))
    return ops


def refine_ops(m):
    ops = ops_of(m.body)
    ops.append(('linear', dict(relu=0, w=m.out.weight.detach().double().numpy(), b=m.out.bias.detach().double().numpy())))
    return ops


def write_net(f, ops, cin, in_hw):
    f.write(struct.pack('<HH', len(ops), cin))
    h, w, c = in_hw[0], in_hw[1], cin
    deq = []
    for kind, p in ops:
        if kind == 'conv':
            q, sc, dq = q8(p['w'])
            f.write(struct.pack('<BBBBBBHH', 0, p['k'], p['s'], p['d'], p['dw'], p['relu'], p['cin'], p['cout']))
            f.write(q.tobytes())
            f.write(sc.tobytes())
            f.write(p['b'].astype(np.float32).tobytes())
            deq.append(('conv', p, dq))
            pad = p['d'] * (p['k'] // 2)
            h = (h + 2 * pad - p['d'] * (p['k'] - 1) - 1) // p['s'] + 1
            w = (w + 2 * pad - p['d'] * (p['k'] - 1) - 1) // p['s'] + 1
            c = p['cout']
        elif kind == 'pool':
            f.write(struct.pack('<B', 1))
            deq.append(('pool', p, None))
            h, w = h // 2, w // 2
        else:
            W = p['w']
            assert W.shape[1] == c * h * w
            fh, fw = h, w
            if h * w > 1:
                # CHW -> HWC column order.
                W = W.reshape(W.shape[0], c, h, w).transpose(0, 2, 3, 1).reshape(W.shape[0], -1)
            q, sc, dq = q8(W)
            f.write(struct.pack('<BBHHHH', 2, p['relu'], W.shape[1], W.shape[0], fh, fw))
            f.write(q.tobytes())
            f.write(sc.tobytes())
            f.write(p['b'].astype(np.float32).tobytes())
            deq.append(('linear', dict(p, hwc=(fh, fw, W.shape[1] // max(1, fh * fw))), dq))
            h, w, c = 1, 1, W.shape[0]
    return deq


def run_deq(deq, x):
    """Reference forward pass of the dequantised net. x: HWC float64."""
    import torch.nn.functional as F
    t = torch.as_tensor(x.transpose(2, 0, 1)[None])
    flat = None
    for kind, p, dq in deq:
        if kind == 'conv':
            pad = p['d'] * (p['k'] // 2)
            t = F.conv2d(t, torch.as_tensor(dq), torch.as_tensor(p['b']), p['s'], pad, p['d'],
                         groups=p['cin'] if p['dw'] else 1)
            if p['relu']:
                t = F.relu(t)
        elif kind == 'pool':
            t = F.max_pool2d(t, 2)
        else:
            if flat is None:
                flat = t[0].permute(1, 2, 0).reshape(1, -1)  # HWC flatten
            else:
                flat = t
            t = flat @ torch.as_tensor(dq).T + torch.as_tensor(p['b'])
            if p['relu']:
                t = F.relu(t)
            flat = t
    if t.dim() == 4:
        return t[0].permute(1, 2, 0).numpy()
    return t.numpy().reshape(1, 1, -1)


def main():
    d, out = sys.argv[1], sys.argv[2]
    fixture = sys.argv[3] if len(sys.argv) > 3 else None
    c = CornerNet()
    c.load_state_dict(torch.load(f'{d}/corner.pt', map_location='cpu'))
    i = IndexNet()
    i.load_state_dict(torch.load(f'{d}/index.pt', map_location='cpu'))
    r = RefineNet()
    r.load_state_dict(torch.load(f'{d}/refine.pt', map_location='cpu'))
    c.eval()
    i.eval()
    r.eval()
    with open(out, 'wb') as f:
        f.write(b'FNTN' + struct.pack('<BB', 1, 3))
        dc = write_net(f, corner_ops(c), 3, (64, 64))
        di = write_net(f, index_ops(i), 3, (32, 24))
        dr = write_net(f, refine_ops(r), 3, (48, 48))
    # Agreement of the dequantised nets with the float originals.
    rng = np.random.default_rng(0)
    x = rng.uniform(-1, 1, (40, 48, 3))
    with torch.no_grad():
        ref = c(torch.as_tensor(x.transpose(2, 0, 1)[None]).float())[0].permute(1, 2, 0).numpy()
    got = run_deq(dc, x)
    print('corner max |diff| int8 vs float', float(np.abs(ref - got).max()), 'of', float(np.abs(ref).max()))
    xi = rng.uniform(-1, 1, (32, 24, 3))
    with torch.no_grad():
        rr, rs = i(torch.as_tensor(xi.transpose(2, 0, 1)[None]).float())
    gi = run_deq(di, xi).reshape(-1)
    print('index max |diff| int8 vs float', float(np.abs(np.concatenate([rr[0].numpy(), rs[0].numpy()]) - gi).max()))
    if fixture:
        cases = [(0, rng.uniform(-1, 1, (24, 40, 3))), (0, rng.uniform(-1, 1, (17, 9, 3))),
                 (1, rng.uniform(-1, 1, (32, 24, 3))), (1, rng.uniform(-1, 1, (32, 24, 3))),
                 (2, rng.uniform(-1, 1, (48, 48, 3)))]
        with open(fixture, 'wb') as f:
            f.write(b'FNTF' + struct.pack('<H', len(cases)))
            for (net, xx) in cases:
                y = run_deq([dc, di, dr][net], xx)
                f.write(struct.pack('<BHHH', net, *xx.shape))
                f.write(xx.astype(np.float32).tobytes())
                f.write(struct.pack('<HHH', *y.shape))
                f.write(y.astype(np.float32).tobytes())
    import os
    print('wrote', out, os.path.getsize(out), 'bytes')


if __name__ == '__main__':
    main()
