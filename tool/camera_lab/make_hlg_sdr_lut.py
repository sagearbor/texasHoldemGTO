"""HLG (BT.2100, BT.2020 primaries) -> SDR (BT.709 / sRGB-like) 3D LUT.

The owner's test videos are HLG HDR (phones record HDR by default) but the
live camera stream Watch my cards reads is SDR. This homebrew ffmpeg has no
zscale / libplacebo tone-mapping, so tool/watch_lab.dart (--hlg) converts
with ffmpeg's lut3d and this cube instead:

  HLG inverse OETF -> scene linear -> HLG OOTF (gamma 1.2, on luminance)
  -> HLG reference white (75 % signal) to SDR 0.85 -> BT.2020 to BT.709
  primaries -> soft highlight knee -> sRGB-style gamma.

    python3 tool/camera_lab/make_hlg_sdr_lut.py OUT.cube [size]
"""
import math
import sys

A, B, C = 0.17883277, 0.28466892, 0.55991073
M2020_709 = [
    (1.6605, -0.5876, -0.0728),
    (-0.1246, 1.1329, -0.0083),
    (-0.0182, -0.1006, 1.1187),
]


def hlg_inv(e):
    e = min(max(e, 0.0), 1.0)
    return e * e / 3 if e <= 0.5 else (math.exp((e - C) / A) + B) / 12


def ootf(rgb, gamma=1.2):
    y = 0.2627 * rgb[0] + 0.6780 * rgb[1] + 0.0593 * rgb[2]
    k = y ** (gamma - 1) if y > 0 else 0.0
    return [c * k for c in rgb]


REF = ootf([hlg_inv(0.75)] * 3)[0]  # display-linear value of HLG ref white


def knee(x, start=0.8):
    if x <= start:
        return x
    over = x - start
    return start + (1 - start) * over / (over + (1 - start))


def srgb(x):
    x = min(max(x, 0.0), 1.0)
    return 12.92 * x if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055


def convert(r, g, b):
    lin = ootf([hlg_inv(r), hlg_inv(g), hlg_inv(b)])
    lin = [c * 0.85 / REF for c in lin]
    out = [sum(m[i] * lin[i] for i in range(3)) for m in M2020_709]
    return [srgb(knee(max(c, 0.0))) for c in out]


def main():
    path = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 33
    with open(path, 'w') as f:
        f.write('TITLE "HLG BT.2020 to SDR BT.709"\nLUT_3D_SIZE %d\n' % n)
        # .cube order: red fastest.
        for bi in range(n):
            for gi in range(n):
                for ri in range(n):
                    o = convert(ri / (n - 1), gi / (n - 1), bi / (n - 1))
                    f.write('%.6f %.6f %.6f\n' % tuple(o))


if __name__ == '__main__':
    main()
