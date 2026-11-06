"""Score CornerNet + IndexNet on the owner's labelled stills.

  python eval_real.py <model_dir> <recording_dir> [--thr 0.5] [--dump out.json]

Per labelled card (stills_labels.json, grades A/B/C): read when a read
of score >= thr names it. Wrong: a read >= thr of a card that is neither
in the still's label nor in the hand (labels.json); "big wrong" only
counts reads whose index is at least 4% of the short side (board cards
seen from a phone low on the felt are smaller).
"""
import argparse
import json
import os
from collections import defaultdict

import numpy as np
import torch

from infer import load_models, read, upright


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('model')
    ap.add_argument('rec')
    ap.add_argument('--thr', type=float, default=0.5)
    ap.add_argument('--det-thr', type=float, default=0.25)
    ap.add_argument('--dump')
    ap.add_argument('--rounds', type=int, default=2)
    ap.add_argument('--peaks', type=int, default=32)
    a = ap.parse_args()
    dev = 'cpu'
    torch.set_num_threads(4)
    corner, index = load_models(a.model, dev)
    import infer
    infer.REFINE_ROUNDS, infer.MAX_PEAKS = a.rounds, a.peaks
    stills = json.load(open(os.path.join(a.rec, 'stills_labels.json')))
    hands = {h['hand']: h for h in json.load(open(os.path.join(a.rec, 'labels.json')))}
    by = defaultdict(lambda: [0, 0])
    wrong, bigwrong, wrong_ex = 0, 0, []
    dump = []
    for e in stills:
        img = upright(os.path.join(a.rec, e['file']))
        res = read(corner, index, img, dev, a.det_thr)
        best = {}
        for r in res:
            if r['score'] >= a.thr and r['score'] > best.get(r['card'], {'score': 0})['score']:
                best[r['card']] = r
        truth = set(e['cards'])
        h = hands.get(e.get('hand'))
        if h:
            truth |= set(h['cards'].split())
        for card, g in e['cards'].items():
            k = f"{e.get('context', '?')} {g}"
            by[k][0] += 1
            if card in best:
                by[k][1] += 1
        for card, r in best.items():
            if card not in truth:
                wrong += 1
                if r['h'] >= 0.04 * 720:
                    bigwrong += 1
                    wrong_ex.append(f"n{e['n']} {card} {r['score']:.2f} h{r['h']:.0f}")
        dump.append({'n': e['n'], 'cards': e['cards'], 'reads': [{k: (round(float(v), 3) if isinstance(v, (float, np.floating)) else v) for k, v in r.items()} for r in res]})
    for k in sorted(by):
        t, ok = by[k]
        print(f'{k}: {ok}/{t} = {100 * ok / max(t, 1):.0f}%')
    print(f'wrong reads {wrong}, of them index >= 4% of short side {bigwrong}: {", ".join(wrong_ex[:30])}')
    if a.dump:
        json.dump(dump, open(a.dump, 'w'), default=float)


if __name__ == '__main__':
    main()
