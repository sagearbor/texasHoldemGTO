"""Real index boxes from the glyph reader's own right reads.

  python oldboxes.py <recording_dir> <dump.jsonl> <out.json> [--viz dir]

<dump.jsonl>: tool/watch_stills.dart --full --loose --coarse --only <the
labelled stills> --dump (whole upright frame). Every confident hit that
names a card the still's label has (stills_labels.json) becomes a box:
the rank glyph centre (x, y), its size md (largest side over the short
side) and the index "up" angle become an index box about 2 md tall,
centred half an md below the rank's centre.
"""
import json
import math
import os
import sys

import cv2

from infer import upright


def main():
    rec, dump, out = sys.argv[1], sys.argv[2], sys.argv[3]
    viz = sys.argv[sys.argv.index('--viz') + 1] if '--viz' in sys.argv else None
    labels = {e['n']: e for e in json.load(open(os.path.join(rec, 'stills_labels.json')))}
    boxes = {}
    n = 0
    for line in open(dump):
        d = json.loads(line)
        e = labels.get(d['n'])
        if e is None:
            continue
        want = {c for c in e['cards'] if '?' not in c}
        img = None
        for h in d['hits']:
            if not h['conf'] or h['c'] not in want:
                continue
            if img is None:
                img = upright(os.path.join(rec, e['file']))
            H, W = img.shape[:2]
            md = h['size'] * min(H, W)
            a = math.radians(h['ang'])
            ux, uy = math.sin(a), -math.cos(a)
            cx, cy = h['x'] * W - ux * 0.5 * md, h['y'] * H - uy * 0.5 * md
            hh = 2.0 * md
            ww = md / max(h['up'], 0.6) * 1.15
            boxes.setdefault(e['file'], []).append(dict(card=h['c'], x=cx, y=cy, h=hh, w=ww, a=a))
            n += 1
        if viz and img is not None and len(boxes) <= 12:
            v = img.copy()
            for b in boxes[e['file']]:
                ux, uy = math.sin(b['a']), -math.cos(b['a'])
                rx, ry = -uy, ux
                pts = []
                for (sx, sy) in [(-1, 1), (1, 1), (1, -1), (-1, -1)]:
                    pts.append((b['x'] + sx * rx * b['w'] / 2 + sy * ux * b['h'] / 2, b['y'] + sx * ry * b['w'] / 2 + sy * uy * b['h'] / 2))
                cv2.polylines(v, [__import__('numpy').int32(pts)], True, (0, 255, 0), 2)
                cv2.putText(v, b['card'], (int(b['x']) + 5, int(b['y'])), 0, 0.7, (0, 255, 0), 2)
            os.makedirs(viz, exist_ok=True)
            cv2.imwrite(os.path.join(viz, f"{d['n']}.jpg"), v)
    json.dump(boxes, open(out, 'w'))
    print(f'{n} boxes on {len(boxes)} stills')


if __name__ == '__main__':
    main()
