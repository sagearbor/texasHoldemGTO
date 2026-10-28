"""Range strings -> 169 hand-class weights (same grammar and grid layout as
lib/gto/range_parser.dart / lib/gto/hand_class.dart)."""

RANKS = "23456789TJQKA"


def cls_index(hi, lo, suffix):
    """hi/lo: rank 0..12 (deuce..ace)."""
    if hi < lo:
        hi, lo = lo, hi
    r_hi, r_lo = 12 - hi, 12 - lo
    if hi == lo:
        return r_hi * 13 + r_hi
    if suffix == "s":
        return r_hi * 13 + r_lo
    return r_lo * 13 + r_hi


def class_name(k):
    r, c = divmod(k, 13)
    hi, lo = 12 - min(r, c), 12 - max(r, c)
    s = RANKS[hi] + RANKS[lo]
    if r != c:
        s += "s" if r < c else "o"
    return s


def class_combos(k):
    r, c = divmod(k, 13)
    return 6 if r == c else (4 if r < c else 12)


def _all(hi, lo, suffix):
    if not suffix:
        return [cls_index(hi, lo, "s"), cls_index(hi, lo, "o")]
    return [cls_index(hi, lo, suffix)]


def _expand(tok):
    R = RANKS.index
    if "-" in tok:
        a, b = [x.strip() for x in tok.split("-")]
        hi_a, lo_a, lo_b = R(a[0].upper()), R(a[1].upper()), R(b[1].upper())
        if hi_a == lo_a:
            top, bot = max(hi_a, R(b[0].upper())), min(hi_a, R(b[0].upper()))
            return [cls_index(r, r, "") for r in range(bot, top + 1)]
        suffix = a[2:]
        top, bot = max(lo_a, lo_b), min(lo_a, lo_b)
        out = []
        for r in range(bot, top + 1):
            out += _all(hi_a, r, suffix)
        return out
    plus = tok.endswith("+")
    t = tok[:-1] if plus else tok
    hi, lo = R(t[0].upper()), R(t[1].upper())
    suffix = t[2:]
    if hi == lo:
        if not plus:
            return [cls_index(hi, hi, "")]
        return [cls_index(r, r, "") for r in range(hi, 13)]
    if not plus:
        return _all(hi, lo, suffix)
    out = []
    for r in range(lo, hi):
        out += _all(hi, r, suffix)
    return out


def parse(text):
    w = [0.0] * 169
    for raw in text.split(","):
        raw = raw.strip()
        if not raw:
            continue
        f = 1.0
        if ":" in raw:
            raw, fs = raw.split(":")
            raw, f = raw.strip(), float(fs)
        for k in _expand(raw):
            w[k] = f
    return w


def percent(w):
    return sum(class_combos(k) * w[k] for k in range(169)) / 1326.0
