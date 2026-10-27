"""Draws the 1024x500 Google Play feature graphic in the icon's style.

Run: python3 tool/make_feature_graphic.py  -> store/feature-graphic-1024x500.png
"""
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_icons import GOLD, ROOT, card, font  # noqa: E402

W, H = 1024, 500
CREAM = (246, 241, 228)


def draw():
    bg = Image.new('RGBA', (W, H))
    d = ImageDraw.Draw(bg)
    # Same radial felt as the icon, centred behind the cards on the right.
    cx, cy = W * 0.78, H * 0.5
    for r in range(W, 0, -4):
        t = r / W
        c = (int(13 + 30 * (1 - t)), int(26 + 70 * (1 - t)), int(19 + 40 * (1 - t)), 255)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)

    back = card(170, 238, 'K', '♥', (214, 40, 57), 14)
    front = card(170, 238, 'A', '♠', (27, 27, 27), -10)
    # Keep the rotated back card inside the right edge (Play crops nothing,
    # but a clipped card looks like a mistake).
    bg.alpha_composite(back, (W - back.width - 8, int(H * 0.16)))
    bg.alpha_composite(front, (W - back.width - 150, int(H * 0.24)))

    d = ImageDraw.Draw(bg)
    x = 64
    d.text((x, 118), 'Felt Notes', font=font(92), fill=CREAM, anchor='ls')
    d.rounded_rectangle([x, 142, x + 300, 154], 6, fill=GOLD)
    d.text((x, 222), 'Poker trainer', font=font(44), fill=GOLD, anchor='ls')
    lines = ['GTO preflop drills & charts',
             'Equity calculator',
             'Home-game stats on your phone']
    for i, line in enumerate(lines):
        y = 296 + i * 50
        d.ellipse([x, y - 20, x + 12, y - 8], fill=GOLD)
        d.text((x + 28, y), line, font=font(32), fill=CREAM, anchor='ls')
    d.text((x, 462), 'Offline · no account · no ads', font=font(24),
           fill=(168, 181, 172), anchor='ls')
    return bg.convert('RGB')


def main():
    out = os.path.join(ROOT, 'store', 'feature-graphic-1024x500.png')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    draw().save(out, optimize=True)
    print(out)


if __name__ == '__main__':
    main()
