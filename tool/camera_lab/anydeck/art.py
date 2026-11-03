"""Procedural backgrounds for art decks and tables (no photo data).

art(H, W, rng)   -> float32 BGR 0..255 "card artwork": painterly noise in a
                    random palette, landscape bands, blobs and silhouettes,
                    stripes, wood, or a mix, sometimes faded towards white.
table(H, W, rng) -> float32 BGR: wood grain, felt, cloth, carved patterns.
"""
import cv2
import numpy as np


def _noise(H, W, rng, octaves=4, base=None):
    """Multi-octave value noise in 0..1."""
    out = np.zeros((H, W), np.float32)
    amp, tot = 1.0, 0.0
    g = base or int(rng.integers(2, 6))
    for _ in range(octaves):
        small = rng.random((g + 1, g + 1)).astype(np.float32)
        out += amp * cv2.resize(small, (W, H), interpolation=cv2.INTER_CUBIC)
        tot += amp
        amp *= rng.uniform(0.4, 0.65)
        g *= 2
    out /= tot
    lo, hi = out.min(), out.max()
    return (out - lo) / max(hi - lo, 1e-6)


def _palette(rng, n=None):
    n = n or int(rng.integers(2, 6))
    mode = rng.random()
    cols = []
    for _ in range(n):
        if mode < 0.3:  # earthy (dinosaurs, landscapes)
            h = rng.uniform(5, 40)
            s, v = rng.uniform(0.25, 0.8), rng.uniform(0.35, 0.95)
        elif mode < 0.55:  # sky / sea / foliage
            h = rng.uniform(80, 230)
            s, v = rng.uniform(0.15, 0.7), rng.uniform(0.45, 1.0)
        elif mode < 0.75:  # pastel anything
            h = rng.uniform(0, 360)
            s, v = rng.uniform(0.05, 0.35), rng.uniform(0.75, 1.0)
        else:  # saturated anything
            h = rng.uniform(0, 360)
            s, v = rng.uniform(0.4, 1.0), rng.uniform(0.3, 1.0)
        hsv = np.uint8([[[h / 2, s * 255, v * 255]]])
        cols.append(cv2.cvtColor(hsv, cv2.COLOR_HSV2BGR)[0, 0].astype(np.float32))
    return np.array(cols)


def _colorize(t, pal):
    """Map t in 0..1 through a palette (piecewise linear)."""
    n = len(pal)
    x = np.clip(t, 0, 1) * (n - 1)
    i = np.minimum(x.astype(np.int32), n - 2) if n > 1 else np.zeros_like(x, np.int32)
    f = (x - i)[..., None]
    if n == 1:
        return np.broadcast_to(pal[0], t.shape + (3,)).astype(np.float32).copy()
    return pal[i] * (1 - f) + pal[i + 1] * f


def _blobs(img, rng, n, dark_bias=0.0):
    H, W = img.shape[:2]
    for _ in range(n):
        m = np.zeros((H, W), np.uint8)
        k = rng.random()
        if k < 0.45:
            cv2.ellipse(m, (int(rng.uniform(0, W)), int(rng.uniform(0, H))),
                        (int(rng.uniform(4, W * 0.5)), int(rng.uniform(4, H * 0.5))), rng.uniform(0, 180), 0, 360, 255, -1)
        elif k < 0.8:  # irregular silhouette (animal, rock, plant)
            c = np.array([rng.uniform(0, W), rng.uniform(0, H)])
            r = rng.uniform(6, min(H, W) * 0.45)
            npts = int(rng.integers(6, 16))
            ang = np.sort(rng.uniform(0, 2 * np.pi, npts))
            rad = r * rng.uniform(0.3, 1.0, npts)
            pts = np.stack([c[0] + rad * np.cos(ang), c[1] + rad * np.sin(ang)], 1).astype(np.int32)
            cv2.fillPoly(m, [pts], 255)
        else:  # stroke / branch / outline
            p = [tuple(int(v) for v in rng.uniform(0, max(H, W), 2)) for _ in range(int(rng.integers(2, 5)))]
            for a, b in zip(p, p[1:]):
                cv2.line(m, a, b, 255, int(rng.integers(1, 9)))
        col = _palette(rng, 1)[0]
        if rng.random() < dark_bias:
            col = col * rng.uniform(0.1, 0.5)
        a = cv2.GaussianBlur(m.astype(np.float32) / 255, (0, 0), rng.uniform(0.3, 3))[..., None]
        a *= rng.uniform(0.5, 1.0)
        img[:] = img * (1 - a) + col * a
    return img


def art(H, W, rng):
    k = rng.random()
    if k < 0.3:  # painterly noise
        img = _colorize(_noise(H, W, rng, octaves=int(rng.integers(2, 6))), _palette(rng))
        img = _blobs(img, rng, int(rng.integers(0, 5)), 0.3)
    elif k < 0.5:  # landscape: sky gradient, hill bands
        pal = _palette(rng, 2)
        yy = np.linspace(0, 1, H, dtype=np.float32)[:, None, None]
        img = np.broadcast_to(pal[0] * (1 - yy) + pal[1] * yy, (H, W, 3)).astype(np.float32).copy()
        for _ in range(int(rng.integers(1, 4))):
            y0 = rng.uniform(0.2, 0.9) * H
            edge = y0 + (_noise(1, W, rng, 3)[0] - 0.5) * H * rng.uniform(0.1, 0.5)
            m = (np.arange(H)[:, None] > edge[None, :]).astype(np.float32)
            tex = _colorize(_noise(H, W, rng, 4), _palette(rng, 2))
            img = img * (1 - m[..., None]) + tex * m[..., None]
        img = _blobs(img, rng, int(rng.integers(0, 4)), 0.5)
    elif k < 0.65:  # flat colour + shapes (illustration)
        img = np.broadcast_to(_palette(rng, 1)[0], (H, W, 3)).astype(np.float32).copy()
        img = _blobs(img, rng, int(rng.integers(2, 9)), 0.4)
    elif k < 0.75:  # stripes / checks / patterns
        yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
        a = rng.uniform(0, np.pi)
        per = rng.uniform(4, 40)
        t = (np.sin((xx * np.cos(a) + yy * np.sin(a)) * 2 * np.pi / per) > rng.uniform(-0.5, 0.5)).astype(np.float32)
        if rng.random() < 0.4:
            b = a + np.pi / 2
            t = np.abs(t - (np.sin((xx * np.cos(b) + yy * np.sin(b)) * 2 * np.pi / per) > 0))
        img = _colorize(cv2.GaussianBlur(t, (0, 0), 0.7), _palette(rng, 2))
    elif k < 0.85:
        img = wood(H, W, rng)
    else:  # mixture of two
        a, b = art(H, W, rng), art(H, W, rng)
        m = (_noise(H, W, rng, 2) > rng.uniform(0.3, 0.7)).astype(np.float32)
        m = cv2.GaussianBlur(m, (0, 0), 2)[..., None]
        img = a * m + b * (1 - m)
    if rng.random() < 0.25:  # faded print / light artwork
        f = rng.uniform(0.2, 0.7)
        img = img * (1 - f) + 245 * f
    return np.clip(img, 0, 255).astype(np.float32)


def wood(H, W, rng):
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    a = rng.uniform(0, np.pi)
    u = xx * np.cos(a) + yy * np.sin(a)
    n = _noise(H, W, rng, 4)
    t = np.sin(u / rng.uniform(2, 12) + n * rng.uniform(3, 12)) * 0.5 + 0.5
    base = np.array([rng.uniform(20, 90), rng.uniform(50, 120), rng.uniform(90, 190)], np.float32)
    img = base * (0.55 + 0.6 * t[..., None])
    return np.clip(img, 0, 255)


def table(H, W, rng):
    k = rng.random()
    if k < 0.45:
        img = wood(H, W, rng)
        if rng.random() < 0.4:  # carved geometric grooves
            m = np.zeros((H, W), np.uint8)
            step = int(rng.uniform(10, 40))
            for i in range(-max(H, W), max(H, W) * 2, step):
                cv2.line(m, (i, 0), (i + H, H), 255, int(rng.integers(1, 4)))
                if rng.random() < 0.5:
                    cv2.line(m, (i, H), (i + H, 0), 255, int(rng.integers(1, 4)))
            img[m > 0] *= rng.uniform(0.3, 0.6)
    elif k < 0.65:  # felt
        col = _palette(rng, 1)[0] * rng.uniform(0.4, 0.9)
        img = col + (_noise(H, W, rng, 5, base=8)[..., None] - 0.5) * rng.uniform(5, 25)
    else:
        img = art(H, W, rng) * rng.uniform(0.4, 1.0)
    return np.clip(img, 0, 255).astype(np.float32)
