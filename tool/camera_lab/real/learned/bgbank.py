"""Build a bank of BACKGROUND-ONLY patches from the real photos.

Cards (anything white-ish, plus the photo prints enclosed by white borders)
are masked out with a generous margin, so no card pixels reach training.
Writes bg_patches.npy (N,128,128,3 BGR uint8) and a mask preview.
  python bgbank.py <photo_dir> <out_dir>
"""
import glob, os, sys
import cv2
import numpy as np

def card_mask(img):
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    white = cv2.inRange(hsv, (0, 0, 120), (180, 70, 255))
    white = cv2.morphologyEx(white, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    closed = cv2.morphologyEx(white, cv2.MORPH_CLOSE, np.ones((61, 61), np.uint8))
    cnts, _ = cv2.findContours(closed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    m = np.zeros(white.shape, np.uint8)
    for c in cnts:
        if cv2.contourArea(c) > 400:
            cv2.drawContours(m, [cv2.convexHull(c)], -1, 255, -1)
    return cv2.dilate(m, np.ones((81, 81), np.uint8))

def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    rng = np.random.default_rng(0)
    patches, previews = [], []
    for f in sorted(glob.glob(os.path.join(src, '*.jpg'))):
        img = cv2.imread(f)
        img = cv2.resize(img, None, fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA)
        m = card_mask(img)
        ii = cv2.integral((m > 0).astype(np.uint8))
        H, W = m.shape
        n = 0
        for _ in range(6000):
            s = int(rng.choice([64, 96, 128, 192, 256]))
            x, y = rng.integers(0, W - s), rng.integers(0, H - s)
            bad = ii[y + s, x + s] - ii[y, x + s] - ii[y + s, x] + ii[y, x]
            if bad == 0:
                patches.append(cv2.resize(img[y:y + s, x:x + s], (128, 128), interpolation=cv2.INTER_AREA))
                n += 1
                if n >= 300:
                    break
        pv = img.copy(); pv[m > 0] = (pv[m > 0] * 0.3).astype(np.uint8)
        previews.append(cv2.resize(pv, (375, 500)))
        print(os.path.basename(f), 'patches', n)
    np.save(os.path.join(out, 'bg_patches.npy'), np.stack(patches))
    cv2.imwrite(os.path.join(out, 'bg_mask_preview.jpg'), np.hstack(previews))

if __name__ == '__main__':
    main()
