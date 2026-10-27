"""Evaluate the classical card reader on the real photos.

  python tool/camera_lab/real/classical/run_eval.py \
      --data camera_data/cards-2deals_TH --out tmp/overnight/cv-classical

Writes annotated images, results.md and results.json to --out.

Configs evaluated:
  fonts/1080      system-font templates only, image resized to 1080 px wide
  fonts/1500, fonts/3000 (full res)
  fonts/1080 no-rotation-search / joint-rank+suit-rotation-search (ablations)
  lodo+fonts/1080 fonts + glyphs cropped from the OTHER deal's photos
                  (leave-one-deal-out: deal 1 tested with deal-2 crops and
                  vice versa)
  lodo-crops-only/1080  only the other deal's crops (no fonts)
  insample-crops+fonts/1080  crops from all photos incl. the test one (leaky
                  upper reference, not a valid accuracy number)
"""
import argparse
import json
import os
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline as P  # noqa: E402
from glyphs import crop_bank, merge_banks, render_font_templates  # noqa: E402


def board_polys(cards, grow=2.2):
    out = []
    for c in cards:
        (cx, cy), (rw, rh), ang = c['rect']
        out.append(cv2.boxPoints(((cx, cy), (rw * grow, rh * grow), ang)).astype(np.float32).reshape(-1, 1, 2))
    return out


def process(full, width, bank, rot_search=P.RANK_ROT_SEARCH, suit_search=P.SUIT_ROT_SEARCH):
    t0 = time.perf_counter()
    img = P.resize_w(full, width)
    t1 = time.perf_counter()
    cards = P.find_board(img)
    t2 = time.perf_counter()
    reads, blobs, cands = P.read_indices(img, bank, rot_search=rot_search, exclude=board_polys(cards),
                                         suit_search=suit_search)
    hero, agg = P.hero_from_reads(reads)
    t3 = time.perf_counter()
    return dict(img=img, cards=cards, reads=reads, cands=cands, hero=hero, agg=agg,
                t_resize=t1 - t0, t_board=t2 - t1, t_hero=t3 - t2, t_total=t3 - t0)


def harvest(res, truth_hero, per_card=2, min_score=0.5):
    """Glyph masks of the true hero cards from one processed photo.

    Uses the labels only to pick WHICH detected pairs are the true cards
    (the masks themselves come from the detector), i.e. training data.
    """
    recs = []
    for code in truth_hero:
        r, s = code[0], code[1]
        scored = []
        for c in res['cands']:
            if c['red'] != (s in 'dh') or r not in c['rank_scores'] or s not in c['suit_scores']:
                continue
            scored.append((0.5 * (c['rank_scores'][r] + c['suit_scores'][s]), c))
        scored.sort(key=lambda x: -x[0])
        used = set()
        for sc, c in scored:
            if sc < min_score or len([u for u in used if u[0] == code]) >= per_card:
                break
            if (code, c['i']) in used or (code, c['j']) in used:
                continue
            used.update({(code, c['i']), (code, c['j'])})
            recs.append(('rank', r, c['rank_mask']))
            recs.append(('suit', s, c['suit_mask']))
    return recs


def annotate(res, name, truth, out_path):
    vis = res['img'].copy()
    H, W = vis.shape[:2]
    f = W / 1080
    for c in res['cards']:
        col = (0, 0, 255) if c['colour'] == 'red' else (40, 40, 40) if c['colour'] == 'black' else (200, 200, 0)
        cv2.polylines(vis, [c['box'].astype(np.int32)], True, (0, 255, 255), max(1, int(2 * f)))
        p = c['box'].min(0).astype(int)
        cv2.putText(vis, c['colour'][0].upper(), (int(p[0]), int(p[1] - 4 * f)), cv2.FONT_HERSHEY_SIMPLEX,
                    0.6 * f, col, max(1, int(2 * f)))
    for r in res['reads']:
        ok = r['code'] in truth['hero']
        chosen = r['code'] in res['hero']
        col = (0, 200, 0) if ok else (0, 0, 255)
        for (x, y, w, h) in (r['rank_bbox'], r['suit_bbox']):
            cv2.rectangle(vis, (x, y), (x + w, y + h), col, max(1, int((3 if chosen else 1) * f)))
        x, y, w, h = r['rank_bbox']
        cv2.putText(vis, '%s %.2f' % (r['code'], r['score']), (x + w + 4, y + h // 2), cv2.FONT_HERSHEY_SIMPLEX,
                    0.7 * f, col, max(1, int(2 * f)))
    bar = np.full((int(90 * f), W, 3), 255, np.uint8)
    hero_ok = sorted(res['hero']) == sorted(truth['hero'])
    cv2.putText(bar, '%s  hero %s (truth %s) %s' % (name[-10:-4], ' '.join(res['hero']) or '-',
                                                   ' '.join(truth['hero']), 'OK' if hero_ok else 'X'),
                (int(10 * f), int(35 * f)), cv2.FONT_HERSHEY_SIMPLEX, 0.75 * f, (0, 120, 0) if hero_ok else (0, 0, 200),
                max(1, int(2 * f)))
    bc = len(res['cards'])
    cv2.putText(bar, 'board %d (truth %d)  colours %s' % (bc, truth['board_count'],
                                                         ''.join(c['colour'][0].upper() for c in res['cards']) or '-'),
                (int(10 * f), int(75 * f)), cv2.FONT_HERSHEY_SIMPLEX, 0.75 * f,
                (0, 120, 0) if bc == truth['board_count'] else (0, 0, 200), max(1, int(2 * f)))
    cv2.imwrite(out_path, np.vstack([bar, vis]), [cv2.IMWRITE_JPEG_QUALITY, 85])


def hero_score(pred, truth):
    """(cards right out of 2, exact both)."""
    t = list(truth)
    n = 0
    for p in pred:
        if p in t:
            t.remove(p)
            n += 1
    return n, n == 2


def board_ranks_attempt(full, cards_1080, bank):
    """Stretch: run the index reader at full res inside the board areas."""
    s = full.shape[1] / 1080.0
    polys = []
    for c in cards_1080:
        (cx, cy), (rw, rh), ang = c['rect']
        polys.append(cv2.boxPoints(((cx * s, cy * s), (rw * s * 2.2, rh * s * 2.2), ang)).astype(np.float32))
    if not polys:
        return []
    allp = np.vstack(polys)
    x0, y0 = np.maximum(allp.min(0).astype(int) - 10, 0)
    x1, y1 = allp.max(0).astype(int) + 10
    crop = full[y0:y1, x0:x1]
    # glyph size relative to crop width: board indices are ~1% of image width
    rel = full.shape[1] / max(1, crop.shape[1])
    reads, _, _ = P.read_indices(crop, bank, min_frac=0.004 * rel, score_min=0.3)
    return [(r['code'], round(r['score'], 2)) for r in reads]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default='camera_data/cards-2deals_TH')
    ap.add_argument('--out', default='tmp/overnight/cv-classical')
    ap.add_argument('--reps', type=int, default=3)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    labels = json.load(open(os.path.join(a.data, 'labels.json')))
    names = sorted(k for k in labels if k.endswith('.jpg'))

    t = time.perf_counter()
    fonts = render_font_templates()
    t_bank = time.perf_counter() - t
    n_tmpl = sum(len(v) for v in fonts['rank'].values()) + sum(len(v) for v in fonts['suit'].values())

    t = time.perf_counter()
    fulls = {n: cv2.imread(os.path.join(a.data, n)) for n in names}
    t_decode = (time.perf_counter() - t) / len(names)

    results = {}

    def run_cfg(key, width, bank_for, rot=P.RANK_ROT_SEARCH, suit=P.SUIT_ROT_SEARCH):
        rows = []
        for n in names:
            res = process(fulls[n], width, bank_for(n), rot, suit)
            ts = [res['t_total']]
            for _ in range(a.reps - 1):
                ts.append(process(fulls[n], width, bank_for(n), rot, suit)['t_total'])
            res['t_med'] = float(np.median(ts))
            rows.append((n, res))
        results[key] = rows
        return rows

    run_cfg('fonts/1080', 1080, lambda n: fonts)
    run_cfg('fonts/1500', 1500, lambda n: fonts)
    run_cfg('fonts/3000 (full res)', 3000, lambda n: fonts)
    run_cfg('fonts/1080 no-rotation-search', 1080, lambda n: fonts, (0,), (0,))
    run_cfg('fonts/1080 joint-rank+suit-rotation-search', 1080, lambda n: fonts, P.ROT_SEARCH, (0,))

    # Leave-one-deal-out crop templates (harvested at 1080 with the font bank).
    base = dict(results['fonts/1080'])
    crops_by_deal = {}
    for n in names:
        d = labels[n]['deal']
        crops_by_deal.setdefault(d, []).extend(harvest(base[n], labels[n]['hero']))
    banks = {d: crop_bank(recs) for d, recs in crops_by_deal.items()}
    lodo = {}
    for n in names:
        d = labels[n]['deal']
        other = [bk for dd, bk in banks.items() if dd != d]
        lodo[n] = merge_banks(fonts, *other)
    crop_only = {n: merge_banks(*[bk for dd, bk in banks.items() if dd != labels[n]['deal']]) for n in names}
    run_cfg('lodo+fonts/1080', 1080, lambda n: lodo[n])
    run_cfg('lodo-crops-only/1080', 1080, lambda n: crop_only[n])
    # In-sample (cheating) reference: crops from ALL photos incl. the test deal.
    allcrops = merge_banks(fonts, *banks.values())
    run_cfg('insample-crops+fonts/1080 (LEAKY reference)', 1080, lambda n: allcrops)
    harvested = {d: {k: {lab: len(v) for lab, v in bk[k].items()} for k in ('rank', 'suit')} for d, bk in banks.items()}

    # Annotated images for the main configs.
    for key, sub in (('fonts/1080', 'fonts'), ('lodo+fonts/1080', 'lodo')):
        os.makedirs(os.path.join(a.out, sub), exist_ok=True)
        for n, res in results[key]:
            annotate(res, n, labels[n], os.path.join(a.out, sub, n.replace('.jpg', '_annot.jpg')))

    # Board rank stretch attempt (full-res crops of the found board area).
    board_rank = {n: board_ranks_attempt(fulls[n], res['cards'], fonts) for n, res in results['fonts/1080']}

    # ---- summarise
    summ = {}
    for key, rows in results.items():
        cards = exact = bc = col = 0
        for n, res in rows:
            c, e = hero_score(res['hero'], labels[n]['hero'])
            cards += c
            exact += e
            bc += len(res['cards']) == labels[n]['board_count']
            tr = sum(x[1] in 'dh' for x in labels[n]['board'])
            pr = sum(x['colour'] == 'red' for x in res['cards'])
            col += (pr == tr and len(res['cards']) == labels[n]['board_count'])
        summ[key] = dict(hero_cards=cards, hero_cards_n=2 * len(rows), hero_exact=exact, n=len(rows),
                         board_count_ok=bc, board_colour_ok=col,
                         t_med_ms=1000 * float(np.mean([r['t_med'] for _, r in rows])),
                         t_board_ms=1000 * float(np.mean([r['t_board'] for _, r in rows])),
                         t_hero_ms=1000 * float(np.mean([r['t_hero'] for _, r in rows])),
                         t_resize_ms=1000 * float(np.mean([r['t_resize'] for _, r in rows])))

    write_md(a.out, labels, names, results, summ, board_rank, t_bank, n_tmpl, t_decode, harvested)
    json.dump(dict(summary=summ, per_photo={k: {n: dict(hero=r['hero'], board=len(r['cards']),
                                                         colours=[c['colour'] for c in r['cards']],
                                                         reads=[(x['code'], round(x['score'], 3)) for x in r['reads']])
                                                 for n, r in rows} for k, rows in results.items()},
                   board_rank_attempt=board_rank, harvested=harvested),
              open(os.path.join(a.out, 'results.json'), 'w'), indent=1, default=str)
    for k, v in summ.items():
        print('%-34s hero %d/%d cards, %d/%d photos exact | board count %d/%d | colour %d/%d | %.0f ms'
              % (k, v['hero_cards'], v['hero_cards_n'], v['hero_exact'], v['n'], v['board_count_ok'], v['n'],
                 v['board_colour_ok'], v['n'], v['t_med_ms']))


def write_md(out, labels, names, results, summ, board_rank, t_bank, n_tmpl, t_decode, harvested):
    L = []
    L.append('# Classical CV card reader on real photos\n')
    L.append('Code: `tool/camera_lab/real/classical/` (pipeline.py, glyphs.py, run_eval.py). '
             'OpenCV/numpy only, no learned weights. Annotated images: `fonts/` and `lodo/`.\n')
    L.append('**Caveat:** 7 photos, 2 deals, 4 distinct hero cards (Qc 5d 6h Ac). All thresholds were '
             'chosen while looking at these same 7 photos, so every number below is in-sample for the '
             'pipeline design. Only the template source is held out in the LODO rows.\n')
    L.append('## Summary\n')
    L.append('| config | hero cards right | photos with both right | board count exact | board count+red/black count exact | ms / image (median) |')
    L.append('|---|---|---|---|---|---|')
    for k, v in summ.items():
        L.append('| %s | %d/%d | %d/%d | %d/%d | %d/%d | %.0f |' % (
            k, v['hero_cards'], v['hero_cards_n'], v['hero_exact'], v['n'], v['board_count_ok'], v['n'],
            v['board_colour_ok'], v['n'], v['t_med_ms']))
    L.append('')
    L.append('Timing (MacBook, Python+OpenCV, single thread-ish, excludes JPEG decode %.0f ms/image; '
             'font template bank built once in %.1f s, %d templates):\n' % (1000 * t_decode, t_bank, n_tmpl))
    L.append('| width | resize ms | board ms | hero ms | total ms |')
    L.append('|---|---|---|---|---|')
    for k in ('fonts/1080', 'fonts/1500', 'fonts/3000 (full res)', 'fonts/1080 no-rotation-search'):
        v = summ[k]
        L.append('| %s | %.0f | %.0f | %.0f | %.0f |' % (k, v['t_resize_ms'], v['t_board_ms'], v['t_hero_ms'], v['t_med_ms']))
    L.append('')
    for key in ('fonts/1080', 'lodo+fonts/1080', 'fonts/1500', 'fonts/3000 (full res)'):
        L.append('## Per photo: %s\n' % key)
        L.append('| photo | deal | pose | hero truth | hero predicted | ok | board truth | board found | colours (L->R) | truth #red | index reads (code score) |')
        L.append('|---|---|---|---|---|---|---|---|---|---|---|')
        for n, res in results[key]:
            lab = labels[n]
            c, e = hero_score(res['hero'], lab['hero'])
            tr = sum(x[1] in 'dh' for x in lab['board'])
            L.append('| %s | %d | %s | %s | %s | %s | %d | %d | %s | %d | %s |' % (
                n[-10:-4], lab['deal'], lab['hero_pose'], ' '.join(lab['hero']), ' '.join(res['hero']) or '-',
                '2/2' if e else '%d/2' % c, lab['board_count'], len(res['cards']),
                ''.join(x['colour'][0].upper() for x in res['cards']) or '-', tr,
                ', '.join('%s %.2f' % (r['code'], r['score']) for r in res['reads'][:6])))
        L.append('')
    L.append('## LODO template harvest (glyph masks cropped per deal)\n')
    L.append('```\n%s\n```\n' % json.dumps(harvested, indent=1))
    L.append('## Board rank stretch attempt (full-res index reader inside board areas)\n')
    L.append('| photo | board truth | reads |')
    L.append('|---|---|---|')
    for n in names:
        L.append('| %s | %s | %s |' % (n[-10:-4], ' '.join(labels[n]['board']) or '-',
                                       ', '.join('%s %.2f' % x for x in board_rank[n]) or 'none'))
    L.append('')
    L.append(FINDINGS)
    open(os.path.join(out, 'results.md'), 'w').write('\n'.join(L))


FINDINGS = '''## Findings (hand-written, see final report)

* **Hero, held up / fanned (5 photos): read correctly in every photo with system-font templates.**
  Pipeline: paper mask (HSV S<62, V>90) -> ink = adaptive threshold on min(B,G,R), plus a separate
  pure-red mask -> blobs of index size that are >=50% surrounded by paper and are either clearly dark
  or saturated pure red (rejects orange photo faces, wood, grey caption text) -> rank/suit pairs ->
  rotate so rank->suit points down -> NCC against 1749 rendered templates (11 fonts x 13 augmentations).
* **Peek photo 809072 fails completely:** the bent Ac index is foreshortened and motion-blurred into
  fragments ("A" splits into two blobs, the club loses a lobe); the shaded 6h is pale pink (S<110) so
  only part of the "6" survives the red mask and it reads as J. The other peek (754698) works.
* **Heart vs diamond** needed the suit-only rotation search (without it 831500 reads 6d).
* **LODO crop templates did not help**: deal 1 has ranks Q/5, deal 2 has 6/A, so crops from the other
  deal can never supply the missing rank and only add distractors (6-crops pulled the bent Q to 6c).
  Crops-only scores 0/14 for that reason. Real crops only help when the deck's full index set is
  captured once (a 52-card calibration pass), which the leaky in-sample row approximates (13/14).
* **Board count** works by counting framed photo holes (enclosed non-paper, convex, textured,
  colourful). It is resolution-sensitive: 7/7 at 1500 px, 4/7 at 1080 px (touching cards/pale sky
  merge into the frame). Every threshold was tuned on these photos.
* **Board colour fails** (1-2/7 photos fully right). Deal-1 board is dim and its red indices are pale
  pink smudges indistinguishable from paper; it is reported black everywhere. Deal 2 is partially right.
* **Board ranks fail** as expected: the full-res index reader returns 0-1 spurious reads per photo.
'''


if __name__ == '__main__':
    main()
