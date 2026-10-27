/// EXPERIMENTAL "Snap my cards" recogniser (pure Dart, no Flutter imports).
///
/// Input: OCR tokens (text + the four corner points of the token, in the
/// order ML Kit reports them: top-left, top-right, bottom-right, bottom-left
/// *in reading orientation*, so a rotated card gives a rotated box) plus,
/// optionally, the decoded photo as RGBA pixels.
///
/// Output: up to two candidate hole cards. The rank comes from the OCR text
/// of a corner index; the colour (red/black) is sampled from the ink of the
/// rank glyph and of the suit pip printed just below it; the suit itself is a
/// shape *guess* with a confidence that the UI shows so the user can fix it.
///
/// Everything here runs on-device and is deterministic, so it is unit-tested
/// with fabricated OCR results (see test/card_reader_test.dart).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../poker/cards.dart';

/// A 2-D point in image pixel coordinates.
class Pt {
  final double x, y;
  const Pt(this.x, this.y);
  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);
  Pt operator *(double k) => Pt(x * k, y * k);
  double get length => math.sqrt(x * x + y * y);
  Pt get unit {
    final l = length;
    return l == 0 ? const Pt(1, 0) : Pt(x / l, y / l);
  }

  @override
  String toString() => '(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// One OCR word ("element" in ML Kit terms).
class OcrToken {
  final String text;

  /// tl, tr, br, bl in reading orientation.
  final List<Pt> corners;

  /// Text of the whole OCR line the token came from (used to drop caption
  /// words such as "Hand 3 A K"). Defaults to [text].
  final String lineText;

  OcrToken(this.text, this.corners, {String? lineText})
      : assert(corners.length == 4),
        lineText = lineText ?? text;

  /// Axis-aligned box helper for tests and simple callers.
  factory OcrToken.box(String text, double left, double top, double right, double bottom,
          {String? lineText}) =>
      OcrToken(text, [Pt(left, top), Pt(right, top), Pt(right, bottom), Pt(left, bottom)],
          lineText: lineText);

  /// A box of size [w] x [h] centred on ([cx], [cy]) and rotated by
  /// [degrees] clockwise (image y points down).
  factory OcrToken.rotated(String text, double cx, double cy, double w, double h, double degrees,
      {String? lineText}) {
    final a = degrees * math.pi / 180;
    final u = Pt(math.cos(a), math.sin(a));
    final v = Pt(-math.sin(a), math.cos(a));
    final c = Pt(cx, cy);
    Pt p(double s, double t) => c + u * (s * w / 2) + v * (t * h / 2);
    return OcrToken(text, [p(-1, -1), p(1, -1), p(1, 1), p(-1, 1)], lineText: lineText);
  }

  Pt get tl => corners[0];
  Pt get tr => corners[1];
  Pt get bl => corners[3];

  /// Reading direction (unit vector).
  Pt get u => (tr - tl).unit;

  /// "Down" in the token's own frame (unit vector).
  Pt get v => (bl - tl).unit;
  double get width => (tr - tl).length;
  double get height => (bl - tl).length;
  Pt get centre => (corners[0] + corners[2]) * 0.5;

  /// Rotation of the reading direction in degrees, -180..180.
  double get angle => math.atan2(u.y, u.x) * 180 / math.pi;

  /// Maps token-local coordinates (s along the text, t down the text, both
  /// in pixels, origin at the top-left corner) to image coordinates.
  Pt local(double s, double t) => tl + u * s + v * t;
}

/// Pixel source. Kept abstract so tests can paint synthetic images.
class RgbaImage {
  final int width, height;

  /// width * height * 4 bytes, row-major RGBA.
  final Uint8List rgba;
  RgbaImage(this.width, this.height, this.rgba) : assert(rgba.length == width * height * 4);

  factory RgbaImage.filled(int width, int height, int r, int g, int b) {
    final px = Uint8List(width * height * 4);
    for (var i = 0; i < px.length; i += 4) {
      px[i] = r;
      px[i + 1] = g;
      px[i + 2] = b;
      px[i + 3] = 255;
    }
    return RgbaImage(width, height, px);
  }

  bool contains(int x, int y) => x >= 0 && y >= 0 && x < width && y < height;

  /// (r, g, b) at pixel, or null outside the image.
  (int, int, int)? at(int x, int y) {
    if (!contains(x, y)) return null;
    final i = (y * width + x) * 4;
    return (rgba[i], rgba[i + 1], rgba[i + 2]);
  }

  void set(int x, int y, int r, int g, int b) {
    if (!contains(x, y)) return;
    final i = (y * width + x) * 4;
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
}

enum InkColour { red, black, unknown }

class CardCandidate {
  /// 0 = deuce .. 12 = ace (same as lib/poker/cards.dart).
  final int rank;
  final InkColour colour;

  /// 0 clubs, 1 diamonds, 2 hearts, 3 spades; null when we could not even
  /// tell the colour.
  final int? suit;

  /// 0..1. Below ~0.6 the UI should ask the user to confirm the suit.
  final double suitConfidence;

  /// Ranking score (bigger = more likely a hole-card index).
  final double score;
  final OcrToken token;

  const CardCandidate({
    required this.rank,
    required this.colour,
    required this.suit,
    required this.suitConfidence,
    required this.score,
    required this.token,
  });

  /// The card as an int 0..51, or null while the suit is unknown.
  int? get card => suit == null ? null : makeCard(rank, suit!);

  CardCandidate withSuit(int? s, double conf) => CardCandidate(
      rank: rank, colour: colour, suit: s, suitConfidence: conf, score: score, token: token);

  @override
  String toString() => '${rankChars[rank]}${suit == null ? '?' : suitChars[suit!]}'
      '(${colour.name}, suit ${suitConfidence.toStringAsFixed(2)}, score ${score.toStringAsFixed(2)})';
}

class CardReadResult {
  /// Best two (or fewer) candidates, most confident first.
  final List<CardCandidate> cards;

  /// Every rank token we accepted, for debugging / a "pick another" UI.
  final List<CardCandidate> all;
  const CardReadResult(this.cards, this.all);

  bool get isEmpty => cards.isEmpty;
}

// ---------------------------------------------------------------------------
// Rank parsing
// ---------------------------------------------------------------------------

const _tenSpellings = {'10', '1O', 'IO', 'LO', 'I0', 'L0', '1D', 'T'};

/// Single-character rank, with a prior (how sure we are that the OCR text
/// really is that rank). Returns null for non-ranks.
(int, double)? _rankOfChar(String c) {
  switch (c) {
    case 'A':
      return (12, 1.0);
    case 'K':
      return (11, 1.0);
    case 'Q':
      return (10, 1.0);
    case 'J':
      return (9, 1.0);
    case 'T':
      return (8, 0.8); // real decks print "10", a "T" is rarer.
    case '0':
    case 'O':
      return (10, 0.45); // a squat "Q" often reads as O/0.
  }
  final d = '23456789'.indexOf(c);
  if (d >= 0) return (d, 1.0);
  return null;
}

String _clean(String s) => s.toUpperCase().replaceAll(RegExp(r'''[\s.,:;'"|`!_\-‘’“”]'''), '');

/// Splits a token's text into ranks: "10" -> [T], "AK" -> [A, K],
/// "K10" -> [K, T]. Returns null when any part is not a rank (so words like
/// "JACK" or "Bicycle" are rejected outright). Each entry is
/// (rank, prior, startFraction, endFraction) along the token width.
List<(int, double, double, double)>? parseRankText(String raw) {
  final s = _clean(raw);
  if (s.isEmpty || s.length > 4) return null;
  if (_tenSpellings.contains(s)) return [(8, s == 'T' ? 0.8 : 1.0, 0, 1)];
  final out = <(int, double, int, int)>[];
  var i = 0;
  while (i < s.length) {
    if (i + 1 < s.length && _tenSpellings.contains(s.substring(i, i + 2))) {
      out.add((8, 0.9, i, i + 2));
      i += 2;
      continue;
    }
    final r = _rankOfChar(s[i]);
    if (r == null) return null;
    // A lone 0/O inside a longer token is almost certainly noise.
    if (s.length > 1 && r.$2 < 0.5) return null;
    out.add((r.$1, s.length > 1 ? r.$2 * 0.85 : r.$2, i, i + 1));
    i++;
  }
  return [for (final (r, p, a, b) in out) (r, p, a / s.length, b / s.length)];
}

/// True when the OCR line looks like a caption / sentence rather than a
/// corner index (contains a real word of 3+ letters that is not a rank).
bool _isCaptionLine(String line) {
  for (final w in line.split(RegExp(r'\s+'))) {
    final c = _clean(w);
    if (c.length >= 3 && RegExp(r'[A-Z]').hasMatch(c) && parseRankText(c) == null) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Colour + suit shape
// ---------------------------------------------------------------------------

/// Samples an n x m grid over a token-local rectangle; returns a boolean ink
/// mask plus red/black ink counts. Ink = noticeably darker than the local
/// background (the card face).
class InkSample {
  final List<List<bool>> mask; // [row][col]
  final int red, black;
  const InkSample(this.mask, this.red, this.black);
}

double _lum(int r, int g, int b) => 0.299 * r + 0.587 * g + 0.114 * b;

InkSample sampleInk(RgbaImage img, OcrToken t, double s0, double s1, double t0, double t1,
    {int cols = 40, int rows = 44}) {
  final px = <(int, int, int)?>[];
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      final p = t.local(s0 + (s1 - s0) * (i + 0.5) / cols, t0 + (t1 - t0) * (j + 0.5) / rows);
      px.add(img.at(p.x.round(), p.y.round()));
    }
  }
  final lums = [
    for (final p in px)
      if (p != null) _lum(p.$1, p.$2, p.$3)
  ]..sort();
  if (lums.isEmpty) {
    return InkSample(List.generate(rows, (_) => List.filled(cols, false)), 0, 0);
  }
  // Card face = bright end of the sample (90th percentile).
  final bg = lums[(lums.length * 0.9).floor().clamp(0, lums.length - 1)];
  final mask = List.generate(rows, (_) => List.filled(cols, false));
  var red = 0, black = 0;
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      final p = px[j * cols + i];
      if (p == null) continue;
      final (r, g, b) = p;
      final l = _lum(r, g, b);
      final mx = math.max(g, b);
      final isRed = r >= 80 && r > 1.6 * mx + 10 && l < bg - 25;
      final isDark = !isRed && l < bg * 0.6 && l < 150;
      if (isRed) red++;
      if (isDark) black++;
      mask[j][i] = isRed || isDark;
    }
  }
  return InkSample(mask, red, black);
}

/// Largest 4-connected component of [mask] as a new mask (same size).
List<List<bool>> largestComponent(List<List<bool>> mask) {
  final rows = mask.length, cols = rows == 0 ? 0 : mask[0].length;
  final seen = List.generate(rows, (_) => List.filled(cols, false));
  var best = <(int, int)>[];
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      if (!mask[y][x] || seen[y][x]) continue;
      final comp = <(int, int)>[];
      final stack = [(x, y)];
      seen[y][x] = true;
      while (stack.isNotEmpty) {
        final (cx, cy) = stack.removeLast();
        comp.add((cx, cy));
        for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final nx = cx + dx, ny = cy + dy;
          if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
          if (!mask[ny][nx] || seen[ny][nx]) continue;
          seen[ny][nx] = true;
          stack.add((nx, ny));
        }
      }
      if (comp.length > best.length) best = comp;
    }
  }
  final out = List.generate(rows, (_) => List.filled(cols, false));
  for (final (x, y) in best) {
    out[y][x] = true;
  }
  return out;
}

/// Guess the suit of a single pip mask, given its colour.
/// Returns (suit, confidence). Heuristics (pip upright, top = row 0):
///  - heart: two lobes at the top (a notch), widest in the upper half.
///  - diamond: pointed top, widest near the middle, no notch.
///  - club: width shrinks between the top lobe and the side lobes (a waist)
///    before the widest row.
///  - spade: grows steadily from a point to the widest row (no waist).
(int, double) guessSuitFromMask(List<List<bool>> rawMask, InkColour colour) {
  final fallback = colour == InkColour.red ? (2, 0.3) : (3, 0.3);
  final mask = largestComponent(rawMask);
  final rowsIdx = <int>[];
  for (var y = 0; y < mask.length; y++) {
    if (mask[y].contains(true)) rowsIdx.add(y);
  }
  final cells = mask.fold<int>(0, (a, r) => a + r.where((b) => b).length);
  if (rowsIdx.length < 6 || cells < 20) return fallback;
  final top = rowsIdx.first, bottom = rowsIdx.last;
  final h = bottom - top + 1;
  final widths = <int>[];
  final fills = <int>[];
  final runs = <int>[];
  for (var y = top; y <= bottom; y++) {
    final row = mask[y];
    final xs = [
      for (var x = 0; x < row.length; x++)
        if (row[x]) x
    ];
    widths.add(xs.isEmpty ? 0 : xs.last - xs.first + 1);
    fills.add(xs.length);
    runs.add(_solidRuns(row));
  }
  final maxW = widths.reduce(math.max);
  final widest = widths.indexOf(maxW) / (h - 1);
  // Notch: a top-quarter row split into two runs.
  final topRows = math.max(2, (h * 0.3).round());
  final notch = [for (var i = 0; i < topRows; i++) runs[i]].any((n) => n >= 2);

  if (colour == InkColour.red) {
    if (notch) return (2, 0.75);
    if (widest <= 0.38) return (2, 0.55);
    if (widest >= 0.38 && widest <= 0.65) return (1, 0.65);
    return (1, 0.4);
  }
  // Black. Three separate runs in an upper row = the club's top lobe (or its
  // stalk) between the two side lobes. (A spade shows three runs too, but
  // only near the bottom: lobe, stem, lobe.)
  if ([for (var i = 0; i < (h * 0.65).round(); i++) runs[i]].any((n) => n >= 3)) {
    return (0, 0.7);
  }
  // Otherwise look for a waist (ink per row shrinks, then grows again)
  // above the fullest row.
  final maxF = fills.reduce(math.max);
  final maxIdx = fills.indexOf(maxF);
  var peak = 0, waist = false;
  for (var i = 0; i < maxIdx; i++) {
    peak = math.max(peak, fills[i]);
    if (peak >= 3 && fills[i] <= peak * 0.75) waist = true;
  }
  if (waist) return (0, 0.65);
  // Or a shoulder: the club's narrow top lobe gives way abruptly to the
  // wide side lobes, while a spade widens smoothly from its point.
  final upper = (h * 0.65).round();
  for (var i = 0; i + 2 < upper; i++) {
    if (widths[i + 2] - widths[i] >= 0.38 * maxW) return (0, 0.6);
  }
  return (3, 0.6);
}

/// Number of ink runs in a mask row, ignoring sampling noise: one-cell holes
/// are closed before counting.
int _solidRuns(List<bool> row) {
  final r = [...row];
  for (var x = 1; x + 1 < r.length; x++) {
    if (!row[x] && row[x - 1] && row[x + 1]) r[x] = true;
  }
  var n = 0, len = 0;
  for (var x = 0; x <= r.length; x++) {
    if (x < r.length && r[x]) {
      len++;
    } else {
      if (len >= 1) n++;
      len = 0;
    }
  }
  return n;
}

InkColour _colourOf(int red, int black) {
  final total = red + black;
  if (total < 4) return InkColour.unknown;
  final f = red / total;
  if (f >= 0.5) return InkColour.red;
  if (f <= 0.25) return InkColour.black;
  return InkColour.unknown;
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

class _Raw {
  final int rank;
  final double prior;
  final OcrToken token;
  _Raw(this.rank, this.prior, this.token);
}

/// Merges a lone "1"/"I"/"l" with a following "0"/"O" of similar height
/// (OCR sometimes splits "10" into two words).
List<OcrToken> _mergeSplitTens(List<OcrToken> toks) {
  final out = <OcrToken>[...toks];
  final ones = toks.where((t) => {'1', 'I', 'L'}.contains(_clean(t.text)));
  for (final one in ones) {
    for (final zero in toks.where((t) => {'0', 'O'}.contains(_clean(t.text)))) {
      final d = zero.centre - one.centre;
      final along = d.x * one.u.x + d.y * one.u.y;
      final across = (d.x * one.v.x + d.y * one.v.y).abs();
      final h = math.max(one.height, zero.height);
      final similar = (one.height - zero.height).abs() < 0.35 * h;
      if (similar && along > 0 && along < 1.6 * h && across < 0.35 * h) {
        out.remove(one);
        out.remove(zero);
        out.add(OcrToken('10', [one.tl, zero.tr, zero.corners[2], one.bl]));
      }
    }
  }
  return out;
}

/// Turns OCR tokens (+ optional pixels) into candidate hole cards.
CardReadResult readCards(List<OcrToken> tokens, [RgbaImage? image]) {
  final raws = <_Raw>[];
  for (final t in _mergeSplitTens(tokens)) {
    if (t.height <= 0 || t.width <= 0) continue;
    if (_isCaptionLine(t.lineText)) continue;
    final parts = parseRankText(t.text);
    if (parts == null) continue;
    for (final (rank, prior, a, b) in parts) {
      final sub = parts.length == 1
          ? t
          : OcrToken(t.text, [
              t.local(t.width * a, 0),
              t.local(t.width * b, 0),
              t.local(t.width * b, t.height),
              t.local(t.width * a, t.height),
            ]);
      raws.add(_Raw(rank, prior, sub));
    }
  }
  if (raws.isEmpty) return const CardReadResult([], []);

  // Corner indices of the cards you hold are the biggest rank glyphs in the
  // shot; tiny ones (another player's cards, a printed ad) are dropped.
  final maxH = raws.map((r) => r.token.height).reduce(math.max);
  final kept = raws.where((r) => r.token.height >= 0.45 * maxH).toList();

  final cands = <CardCandidate>[];
  for (final r in kept) {
    final t = r.token;
    var colour = InkColour.unknown;
    int? suit;
    var conf = 0.0;
    if (image != null) {
      final h = t.height;
      // Rank glyph ink (colour only).
      final glyph = sampleInk(image, t, 0, t.width, 0, h, cols: 16, rows: 16);
      // Suit pip sits directly below the index, roughly as wide as a letter.
      final pipW = math.max(t.width, h * 0.8);
      final cs = t.width / 2;
      final pip = sampleInk(image, t, cs - pipW * 0.75, cs + pipW * 0.75, h * 1.05, h * 2.15);
      colour = _colourOf(glyph.red + pip.red, glyph.black + pip.black);
      if (colour != InkColour.unknown) {
        (suit, conf) = guessSuitFromMask(pip.mask, colour);
      }
    }
    final score = (t.height / maxH) * r.prior;
    cands.add(CardCandidate(
        rank: r.rank, colour: colour, suit: suit, suitConfidence: conf, score: score, token: t));
  }
  cands.sort((a, b) => b.score.compareTo(a.score));

  // Pick two. The same card can appear twice (its two corner indices are
  // rotated 180 degrees from each other): skip such duplicates.
  final picked = <CardCandidate>[];
  for (final c in cands) {
    if (picked.length == 2) break;
    final dup = picked.any((p) {
      if (p.rank != c.rank || p.colour != c.colour) return false;
      var da = (p.token.angle - c.token.angle).abs() % 360;
      if (da > 180) da = 360 - da;
      return da > 120;
    });
    if (dup) continue;
    picked.add(c);
  }
  // Pocket pair with the same suit guess: impossible, so flip the less
  // confident one to the other suit of the same colour.
  if (picked.length == 2 &&
      picked[0].rank == picked[1].rank &&
      picked[0].suit != null &&
      picked[0].suit == picked[1].suit) {
    final weaker = picked[0].suitConfidence < picked[1].suitConfidence ? 0 : 1;
    final s = picked[weaker].suit!;
    const twin = {0: 3, 3: 0, 1: 2, 2: 1};
    picked[weaker] = picked[weaker].withSuit(twin[s], 0.3);
  }
  return CardReadResult(picked, cands);
}
