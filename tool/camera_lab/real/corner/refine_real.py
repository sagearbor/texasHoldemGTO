"""Real RefineNet windows from oldboxes.py boxes (training recordings only).

  python refine_real.py <out.npz> <recording_dir>:<oldboxes.json> ...
"""
import json
import math
import os
import sys

import numpy as np

from infer import upright
from render import ref_crop, ref_target


def main():
    out = sys.argv[1]
    rng = np.random.default_rng(1)
    xs, ts = [], []
    for spec in sys.argv[2:]:
        rec, _, oldp = spec.partition(':')
        for f, boxes in json.load(open(oldp)).items():
            img = upright(os.path.join(rec, f))
            for b in boxes:
                tf = ref_target(b['x'], b['y'], b['h'], b['a'])
                for _ in range(8):
                    h0 = b['h'] * math.exp(rng.normal(-0.15, 0.25))
                    cx0 = b['x'] + rng.normal(0, 0.15) * b['h']
                    cy0 = b['y'] + rng.normal(0, 0.15) * b['h']
                    xs.append(ref_crop(img, cx0, cy0, h0))
                    ts.append(tf(cx0, cy0, h0))
    np.savez_compressed(out, rx=np.stack(xs), rt=np.stack(ts))
    print(len(xs), 'real windows')


if __name__ == '__main__':
    main()
