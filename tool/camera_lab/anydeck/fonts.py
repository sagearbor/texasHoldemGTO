"""Font inventory for the any-deck glyph generator.

Fonts are only READ on this machine to render training glyphs; none is
copied into the repo or the app. Sources:
  * macOS system fonts (/System/Library/Fonts, Supplemental),
  * freely licensed fonts that other installed software already ships:
    Android Studio layoutlib (Roboto, Noto Serif, Source Sans Pro, Droid,
    Carrois, Cutive Mono, Coming Soon, Dancing Script: Apache 2.0 / OFL),
    flutter_gallery_assets google_fonts (OFL / Apache 2.0), matplotlib's
    DejaVu (Bitstream Vera licence), TeX Live Latin Modern (GUST licence).
Missing paths are skipped, so the generator runs on any Mac.

The font list is split by FAMILY into train and held-out test fonts
(TEST_FAMILIES): the synthetic any-deck test set renders indices only in
fonts the network never saw.
"""
import glob
import hashlib
import os

from fontTools.ttLib import TTCollection, TTFont
from PIL import Image, ImageDraw, ImageFont
import numpy as np

HOME = os.path.expanduser('~')
GLOBS = [
    '/System/Library/Fonts/*.tt?', '/System/Library/Fonts/Supplemental/*.tt?',
    '/System/Library/Fonts/Supplemental/*.otf', '/Library/Fonts/*.ttf',
    '/Applications/Android Studio.app/Contents/plugins/design-tools/resources/layoutlib/data/fonts/*.ttf',
    HOME + '/.pub-cache/hosted/pub.dev/flutter_gallery_assets-*/lib/fonts/google_fonts/*.ttf',
    HOME + '/projects/githubs/*/.venv/lib/python3*/site-packages/matplotlib/mpl-data/fonts/ttf/DejaVu*.ttf',
    '/usr/local/texlive/*/texmf-dist/fonts/opentype/public/lm/lmroman*-regular.otf',
    '/usr/local/texlive/*/texmf-dist/fonts/opentype/public/lm/lmroman*-bold.otf',
    '/usr/local/texlive/*/texmf-dist/fonts/opentype/public/lm/lmsans*-regular.otf',
    '/usr/local/texlive/*/texmf-dist/fonts/opentype/public/lm/lmsans*-bold.otf',
]
# Non-Latin scripts, symbol / emoji fonts and connected scripts whose digits
# do not look like card indices.
DENY = ('Noto Sans ', 'Emoji', 'LastResort', 'Last Resort', 'Webdings', 'Wingdings', 'Symbol', 'Ornaments',
        'NISC', 'STIXInt', 'STIXNonUni', 'STIXSiz', 'STIXVar', 'STIX Two Math', 'Aqua', 'Interface', 'Mishafi',
        'Kokonor', 'Diwan', 'Farisi', 'Waseem', 'DecoType', 'Nadeem', 'Muna', 'Sana', 'Raanana', 'Al Bayan',
        'Baghdad', 'Beirut', 'Damascus', 'Farah', 'Kufi', 'Al Nile', 'Al Tarikh', 'Kefa', 'Sinhala', 'Tamil',
        'Telugu', 'Malayalam', 'Kannada', 'Khmer', 'Lao', 'Myanmar', 'Oriya', 'Gurmukhi', 'Gujarati', 'Bangla',
        'Devanagari', 'ITF', 'InaiMathi', 'Shree', 'Mshtakan', 'Euphemia', 'Cherokee', 'Ayuthaya', 'Krungthep',
        'Sathu', 'Silom', 'Thonburi', 'Sukhumvit', 'Peninim', 'Zapfino', 'Chancery', 'Snell', 'Savoye',
        'Brush Script', 'Bradley', 'SignPainter', 'Braille', 'Keyboard', 'Apple Color', 'Galvji', 'Noto Serif ',
        'Dancing', 'Academy Engraved', 'Bodoni Ornaments', 'Hoefler Text Ornaments', 'Trattatello', 'Party',
        'Zapf', 'SF Soft', 'Mukta', 'Sangam', 'PingFang', 'Corsiva', 'Herculanum', 'Bodoni 72 Smallcaps')
# Families never used for training: the held-out "unknown deck" fonts.
TEST_FAMILIES = ('Oswald', 'Rockwell', 'Copperplate', 'Trebuchet', 'PT Serif', 'Eczar', 'Rubik', 'Chalkboard',
                 'Luminari', 'Merriweather', 'DejaVu Serif', 'Avenir Next Condensed', 'Cutive', 'Optima',
                 'Gill Sans', 'Didot')
RANK_TEXT = ['A', 'K', 'Q', 'J', '10', '9', '8', '7', '6', '5', '4', '3', '2']
SUIT_TEXT = ['♠', '♣', '♥', '♦']


def _faces(p):
    try:
        fs = TTCollection(p).fonts if p.lower().endswith('.ttc') else [TTFont(p, lazy=True)]
    except Exception:
        return []
    out = []
    for i, f in enumerate(fs):
        try:
            cm = f.getBestCmap() or {}
            name = f['name'].getDebugName(4) or f['name'].getDebugName(1) or ''
        except Exception:
            continue
        out.append((i, name, cm))
    return out


def _render_sig(path, idx, text):
    try:
        f = ImageFont.truetype(path, 48, index=idx)
    except Exception:
        return None
    im = Image.new('L', (160, 80), 0)
    try:
        ImageDraw.Draw(im).text((10, 5), text, font=f, fill=255)
    except Exception:
        return None
    a = np.array(im)
    return a if a.max() > 0 else None


CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.fonts_cache.json')


def scan():
    """{'rank_train', 'rank_test', 'suit_train', 'suit_test'}: lists of (path, index, name).
    Cached in .fonts_cache.json (gitignored; delete it to rescan)."""
    import json
    if os.path.exists(CACHE):
        with open(CACHE) as f:
            return {k: [tuple(x) for x in v] for k, v in json.load(f).items()}
    d = _scan()
    with open(CACHE, 'w') as f:
        json.dump(d, f)
    return d


def _scan():
    seen = set()
    rank_tr, rank_te, suit_tr, suit_te = [], [], [], []
    for g in GLOBS:
        for p in sorted(glob.glob(g)):
            for idx, name, cm in _faces(p):
                if not name or name in seen or any(d in name for d in DENY) or name.startswith('.'):
                    continue
                has_r = all(ord(c) in cm for c in 'AKQJ0123456789')
                has_s = all(ord(c) in cm for c in SUIT_TEXT)
                if not (has_r or has_s):
                    continue
                # Drop faces whose glyphs render empty or all alike (missing-glyph boxes).
                if has_r:
                    sigs = [_render_sig(p, idx, t) for t in ('A', 'K', '8')]
                    if any(s is None for s in sigs) or np.array_equal(sigs[0], sigs[1]):
                        has_r = False
                if has_s:
                    sigs = [_render_sig(p, idx, t) for t in SUIT_TEXT]
                    if any(s is None for s in sigs) or np.array_equal(sigs[0], sigs[2]):
                        has_s = False
                if not (has_r or has_s):
                    continue
                seen.add(name)
                test = any(t in name for t in TEST_FAMILIES)
                if has_r:
                    (rank_te if test else rank_tr).append((p, idx, name))
                if has_s:
                    (suit_te if test else suit_tr).append((p, idx, name))
    return {'rank_train': rank_tr, 'rank_test': rank_te, 'suit_train': suit_tr, 'suit_test': suit_te}


def stable_split(items, frac, salt):
    """Deterministic subset (by name hash) of about `frac` of items."""
    return [it for it in items if int(hashlib.md5((salt + it[2]).encode()).hexdigest(), 16) % 1000 < frac * 1000]


if __name__ == '__main__':
    d = scan()
    for k, v in d.items():
        print(k, len(v))
        print('   ', ', '.join(sorted({n for _, _, n in v}))[:3000])
