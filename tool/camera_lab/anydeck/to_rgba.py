"""Convert JPEG/PNG images to NAME_WxH.rgba (raw RGBA) for tool/glyph_probe.dart.

  python to_rgba.py OUT_DIR IMAGE... [--max-short 720]

--max-short shrinks (INTER_AREA) so the short side is at most that, like
the 720p camera stream Watch my cards reads.
"""
import os
import sys

import cv2
import numpy as np


def main():
    args = sys.argv[1:]
    ms = 720
    if '--max-short' in args:
        i = args.index('--max-short')
        ms = int(args[i + 1])
        del args[i:i + 2]
    out, imgs = args[0], args[1:]
    os.makedirs(out, exist_ok=True)
    for p in imgs:
        im = cv2.imread(p, cv2.IMREAD_COLOR)
        if im is None:
            print('skip', p)
            continue
        h, w = im.shape[:2]
        if min(h, w) > ms:
            f = ms / min(h, w)
            im = cv2.resize(im, (round(w * f), round(h * f)), interpolation=cv2.INTER_AREA)
        h, w = im.shape[:2]
        rgba = cv2.cvtColor(im, cv2.COLOR_BGR2RGBA)
        name = os.path.splitext(os.path.basename(p))[0]
        dst = os.path.join(out, '%s_%dx%d.rgba' % (name, w, h))
        rgba.astype(np.uint8).tofile(dst)
        print(dst)


if __name__ == '__main__':
    main()
