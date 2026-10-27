"""Draws the Felt Notes icon and writes every Android/iOS/web size.

Run: python3 tool/make_icons.py
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024
GOLD = (226, 184, 87)


def font(size):
    for p in ['/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
              '/Library/Fonts/Arial Unicode.ttf',
              '/System/Library/Fonts/Supplemental/Arial Bold.ttf']:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def card(w, h, rank, suit, color, rot):
    im = Image.new('RGBA', (w + 80, h + 80), (0, 0, 0, 0))
    shadow = Image.new('RGBA', im.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([46, 52, 46 + w, 52 + h], 48, fill=(0, 0, 0, 140))
    im = Image.alpha_composite(im, shadow.filter(ImageFilter.GaussianBlur(14)))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([40, 40, 40 + w, 40 + h], 48, fill=(250, 248, 242, 255))
    d.text((40 + w / 2, 40 + h * 0.36), rank, font=font(int(h * 0.36)), fill=color, anchor='mm')
    d.text((40 + w / 2, 40 + h * 0.70), suit, font=font(int(h * 0.36)), fill=color, anchor='mm')
    return im.rotate(rot, resample=Image.BICUBIC, expand=True)


def draw():
    bg = Image.new('RGBA', (S, S))
    d = ImageDraw.Draw(bg)
    for r in range(S, 0, -4):  # radial felt gradient
        t = r / S
        c = (int(13 + 30 * (1 - t)), int(26 + 70 * (1 - t)), int(19 + 40 * (1 - t)), 255)
        d.ellipse([S / 2 - r * 0.75, S / 2 - r * 0.75, S / 2 + r * 0.75, S / 2 + r * 0.75], fill=c)
    back = card(380, 532, 'K', '♥', (214, 40, 57), 14)
    front = card(380, 532, 'A', '♠', (27, 27, 27), -10)
    bg.alpha_composite(back, (int(S * 0.43), int(S * 0.15)))
    bg.alpha_composite(front, (int(S * 0.12), int(S * 0.20)))
    # Gold "note" underline: the notebook nod.
    d = ImageDraw.Draw(bg)
    d.rounded_rectangle([S * 0.2, S * 0.84, S * 0.8, S * 0.875], 18, fill=GOLD)
    return bg.convert('RGB')


def main():
    icon = draw()
    out = lambda *p: os.path.join(ROOT, *p)
    icon.save(out('assets', 'icon', 'icon-1024.png')) if os.path.isdir(out('assets', 'icon')) else (
        os.makedirs(out('assets', 'icon')), icon.save(out('assets', 'icon', 'icon-1024.png')))
    icon.resize((512, 512), Image.LANCZOS).save(out('assets', 'icon', 'play-512.png'))
    for name, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        icon.resize((px, px), Image.LANCZOS).save(
            out('android', 'app', 'src', 'main', 'res', f'mipmap-{name}', 'ic_launcher.png'))
    ios_dir = out('ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    contents = json.load(open(os.path.join(ios_dir, 'Contents.json')))
    for img in contents['images']:
        if 'filename' not in img:
            continue
        px = round(float(img['size'].split('x')[0]) * int(img['scale'][0]))
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(ios_dir, img['filename']))
    for name, px in [('Icon-192.png', 192), ('Icon-512.png', 512),
                     ('Icon-maskable-192.png', 192), ('Icon-maskable-512.png', 512)]:
        icon.resize((px, px), Image.LANCZOS).save(out('web', 'icons', name))
    icon.resize((32, 32), Image.LANCZOS).save(out('web', 'favicon.png'))


if __name__ == '__main__':
    main()
