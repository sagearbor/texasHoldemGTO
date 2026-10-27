"""Dev: dump the upright crops the CNN sees for each hand box (rank|suit per row)."""
import os, sys, cv2, numpy as np
from read_photos import HAND_BOXES, blobs, pairs, upright_crop
src, out = sys.argv[1], sys.argv[2]
rows = []
for p, code, (x0, y0, x1, y1) in HAND_BOXES:
    img = cv2.imread(os.path.join(src, f'PXL_20261027_{p}.jpg'))
    bl, lab = blobs(img, (x0 * 4, y0 * 4, x1 * 4, y1 * 4))
    tiles = []
    for a, b, u in pairs(bl)[:6]:
        for bb in (a, b):
            c = upright_crop(img, lab, bb, u)
            tiles.append(cv2.resize(c, (64, 64), interpolation=cv2.INTER_NEAREST) if c is not None else np.zeros((64, 64), np.uint8))
    sizes = ' '.join(str(b['s']) for b in bl)
    tiles = (tiles + [np.full((64, 64), 128, np.uint8)] * 12)[:12]
    r = np.hstack(tiles); r = np.hstack([np.full((64, 200), 255, np.uint8), r])
    cv2.putText(r, f'{p[-3:]} {code} s={sizes}'[:28], (2, 36), 0, 0.4, 0, 1)
    rows.append(r)
cv2.imwrite(out, np.vstack(rows))
