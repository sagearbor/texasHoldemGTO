/// Board cards (flop, turn, river) from a propped phone. Pure Dart, no
/// Flutter: the app and tool/watch_lab.dart run the same code.
///
/// A phone propped at table height sees the community cards far away and
/// at a grazing angle: on the owner's footage a board card is about
/// 105 x 25 px of a 1280 x 720 stream, and its corner index (what the hole
/// card reader classifies, glyph_reader.dart) is 5 px tall and gone. What
/// survives is the FACE of the card: paper-white, with pips big enough to
/// count and clearly red or black. So the board reader does not read
/// glyphs at all:
///
///   1. [findBoardCards]: on an upright full-resolution frame (or the strip
///      where the board was last seen), the card stock (low saturation,
///      very bright) becomes connected components; low, wide ones with ink
///      inside, in one tight row, are the board. Held hole cards are far
///      too big; other players' cards are face down (patterned backs, not
///      paper); a glass, a silver tray or a sleeve has no pips inside.
///   2. [readBoardCard]: on a full-resolution crop of one card, the ink
///      inside the paper is split into red / black / "picture" (the yellow
///      and blue of a face card). Pips are the ink blobs of pip size; the
///      corner indices are too small to count. Pip count gives the rank
///      (A, 2..10); a picture gives "face card" (J / Q / K are told apart
///      by their index, which is unreadable here); the ink colour gives red
///      or black for certain; the pip SHAPE (how much of its box a pip
///      fills: a diamond is a thin rhombus, a heart is fatter; a club is
///      lumpy, a spade solid) gives the suit, with low confidence.
///
/// Every read is a [BoardCardRead] with what is known and how surely, so
/// several frames (board_watch.dart) and several phones
/// (lib/sync/board_consensus.dart) can vote attribute by attribute, and a
/// face card can be fixed with one tap instead of typing the whole board.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'watch_frame.dart';

class BoardReaderConfig {
  /// Card stock: OpenCV-style saturation below this, value above. The
  /// detector uses [detectVMin], stricter: far cards are the brightest
  /// thing in a dim room, and a silver tray or a glass is bright but not
  /// that bright.
  final int paperSMax;
  final int paperVMin;
  final int detectVMin;

  /// Erosion radius (pixels) on the paper mask before labelling:
  /// breaks thin bridges to a bright rim, mug or sleeve.
  final int erode;

  /// A board card's box, as fractions of the frame's SHORT side (so the
  /// same numbers hold at any stream size): lying flat and far away a
  /// card is wide and low.
  final double cardHMin, cardHMax, cardWMin, cardWMax;

  /// Width / height of a board card's box.
  final double minAspect, maxAspect;

  /// Paper pixels / box area: a face card is a thin paper ring around its
  /// picture, a tilted card fills less of its box.
  final double minFill;

  /// A blob at least this wide for its height may be two cards touching;
  /// it is cut where a column has under [splitDip] of the median paper.
  final double splitAspect;
  final double splitDip;

  /// Cards of one row: centres within this many card heights, heights
  /// within this factor of each other, no gap wider than this many
  /// (median) card widths between neighbours.
  final double rowTolHeights;
  final double sizeTol;
  final double chainGapWidths;

  /// Inside a card, white = saturation under [inkSMin] and value at least
  /// [inkWhiteFrac] of the card's paper; everything else is ink. Red ink:
  /// hue (OpenCV 0..179) at most [redHueMax] or at least 160. Black ink:
  /// saturation under [pictureSMin] and value under [darkFrac] of the
  /// paper. Saturated ink of any other hue is a picture.
  final int inkSMin;
  final double inkWhiteFrac;
  final int redHueMax;
  final int pictureSMin;
  final double darkFrac;

  /// Red hue at this saturation or more is red ink even when dark.
  final int deepRedSMin;

  /// Below this fraction of the paper value a pixel is black ink whatever
  /// its hue (dark brown reads as red otherwise).
  final double blackFrac;

  /// A pip's area as a fraction of the card's paper area.
  final double pipMinFrac, pipMaxFrac;

  /// A single ink blob this big (fraction of paper area) is an ace's pip.
  final double aceMinFrac;

  /// Picture ink (yellow / blue / mixed) above this fraction of the paper
  /// area, or one ink region at least this fraction of the card's width:
  /// a face card.
  final double faceInkFrac;
  final double faceWidthFrac;

  /// Ink over this fraction of the card's middle three fifths: a picture
  /// (pips leave most of the middle white).
  final double faceCentreFrac;

  /// An ink blob at least this fraction of the card's height is not a pip
  /// (two of them: a picture; one: an ace).
  final double tallBlobFrac;

  const BoardReaderConfig({
    this.paperSMax = 80,
    this.paperVMin = 140,
    this.detectVMin = 225,
    this.erode = 1,
    this.cardHMin = 0.015,
    this.cardHMax = 0.12,
    this.cardWMin = 0.04,
    this.cardWMax = 0.3,
    this.minAspect = 1.3,
    this.maxAspect = 9,
    this.minFill = 0.2,
    this.splitAspect = 5.5,
    this.splitDip = 0.5,
    this.rowTolHeights = 1.5,
    this.sizeTol = 2.2,
    this.chainGapWidths = 1.5,
    this.inkSMin = 40,
    this.inkWhiteFrac = 0.8,
    this.redHueMax = 20,
    this.pictureSMin = 70,
    this.darkFrac = 0.75,
    this.deepRedSMin = 100,
    this.blackFrac = 0.7,
    this.pipMinFrac = 0.004,
    this.pipMaxFrac = 0.05,
    this.aceMinFrac = 0.06,
    this.faceInkFrac = 0.04,
    this.faceWidthFrac = 0.5,
    this.faceCentreFrac = 0.45,
    this.tallBlobFrac = 0.3,
  });
}

/// One community card as read from one frame. Anything unknown is null.
class BoardCardRead {
  /// 0..12 (2..A) or null (unknown, or a face card: see [face]).
  final int? rank;

  /// 0..3 (c d h s) or null.
  final int? suit;

  /// Ink colour: true red, false black, null unknown.
  final bool? red;

  /// A picture card (J / Q / K, which one is unknown).
  final bool face;

  /// Confidence in the rank and in the suit, 0..1.
  final double rankConf, suitConf;

  /// Where in the frame (frame pixels, unrotated).
  final PixRect box;

  /// Pips counted (diagnostics).
  final int pips;

  /// Ink blobs of at least pip size enclosed by the paper (0 = not a
  /// face-up card: bare paper, a sleeve, a bright metal segment).
  final int inkBlobs;

  const BoardCardRead({
    this.rank,
    this.suit,
    this.red,
    this.face = false,
    this.rankConf = 0,
    this.suitConf = 0,
    required this.box,
    this.pips = 0,
    this.inkBlobs = 0,
  });

  /// Exact card 0..51 when both rank and suit are known.
  int? get card => rank == null || suit == null ? null : rank! * 4 + suit!;

  /// Compact token: rank char (2..9 T J Q K A, F = face, ? = unknown) +
  /// suit char (c d h s, r = red, b = black, ? = unknown). "7d", "Fr", "9?".
  String get token => '${rank == null ? (face ? 'F' : '?') : '23456789TJQKA'[rank!]}'
      '${suit == null ? (red == null ? '?' : (red! ? 'r' : 'b')) : 'cdhs'[suit!]}';

  @override
  String toString() => '$token(${rankConf.toStringAsFixed(2)}/${suitConf.toStringAsFixed(2)})';
}

// ------------------------------------------------------------- detection

Uint8List _paperMask(Uint8List rgba, int n, int vMin, int sMax) {
  final paper = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    final r = rgba[o], g = rgba[o + 1], b = rgba[o + 2];
    final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
    if (mx < vMin) continue;
    final s = mx == 0 ? 0 : 255 * (mx - mn) ~/ mx;
    if (s < sMax) paper[i] = 1;
  }
  return paper;
}

/// Board-card boxes (pixels of [rgba], left to right) in an upright
/// full-resolution image: the whole frame, or the strip of it where the
/// board was last seen. [shortSide] is the frame's short side at this
/// scale (card sizes are fractions of it). Returns the most card-like
/// row; 0 to many boxes (the caller treats 3 / 4 / 5 as a street).
List<PixRect> findBoardCards(Uint8List rgba, int w, int h,
    {required int shortSide, BoardReaderConfig cfg = const BoardReaderConfig()}) {
  final cands = [for (final (c, why) in _candidates(rgba, w, h, shortSide, cfg)) if (why == null) c];
  if (cands.isEmpty) return const [];
  // The best row: for each candidate, the candidates that share its row
  // and height, then the longest run of them with no gap wider than a
  // card and a half (the board is dealt in one tight row; a bright
  // window pane across the room is not next to it). Ties go to the row
  // lower in the frame, nearer the camera than a window sill.
  List<_Comp> best = const [];
  var bestY = -1.0;
  for (final a in cands) {
    final row = [
      for (final b in cands)
        if ((b.cy - a.cy).abs() <= cfg.rowTolHeights * a.bh && b.bh <= cfg.sizeTol * a.bh && a.bh <= cfg.sizeTol * b.bh) b
    ]..sort((p, q) => p.cx.compareTo(q.cx));
    final widths = [for (final b in row) b.bw]..sort();
    final gapMax = cfg.chainGapWidths * widths[widths.length ~/ 2];
    var start = 0;
    for (var i = 1; i <= row.length; i++) {
      if (i == row.length || row[i].minX - row[i - 1].maxX > gapMax) {
        final chain = row.sublist(start, i);
        if (chain.length > best.length || (chain.length == best.length && a.cy > bestY)) {
          best = chain;
          bestY = a.cy;
        }
        start = i;
      }
    }
  }
  return [for (final c in best) PixRect(c.minX, c.minY, c.maxX + 1, c.maxY + 1)];
}

/// [rgba] ([w] x [h]) cut to [r] (clamped). Returns (pixels, w, h).
(Uint8List, int, int) cropRgbaImage(Uint8List rgba, int w, int h, PixRect r) {
  final x0 = r.x0.clamp(0, w), x1 = r.x1.clamp(0, w), y0 = r.y0.clamp(0, h), y1 = r.y1.clamp(0, h);
  final cw = x1 - x0, ch = y1 - y0;
  if (cw <= 0 || ch <= 0) return (Uint8List(0), 0, 0);
  final out = Uint8List(cw * ch * 4);
  for (var y = 0; y < ch; y++) {
    out.setRange(y * cw * 4, (y + 1) * cw * 4, rgba, ((y0 + y) * w + x0) * 4);
  }
  return (out, cw, ch);
}

/// Every paper component with why it was rejected (null = a candidate).
List<(_Comp, String?)> _candidates(Uint8List rgba, int w, int h, int shortSide, BoardReaderConfig cfg) {
  final paper = _paperMask(rgba, w * h, cfg.detectVMin, cfg.paperSMax);
  // Erode: a card lying against the bright rim of a tray, a mug or a
  // sleeve is joined to it by a thin bridge; the card itself survives.
  var m = paper;
  for (var k = 0; k < cfg.erode; k++) {
    m = _erode3(m, w, h);
  }
  final comps = _components(m, w, h, conn8: false);
  final hMin = cfg.cardHMin * shortSide, hMax = cfg.cardHMax * shortSide;
  final wMin = cfg.cardWMin * shortSide, wMax = cfg.cardWMax * shortSide;
  final out = <(_Comp, String?)>[];
  for (final c0 in comps) {
    // Two cards dealt touching merge into one wide blob: split it where
    // the paper thins out between them (the dark gap or the shadow line).
    for (final c in _splitAtDips(c0, m, w, wMin, cfg)) {
      // Give back the eroded pixels on each side.
      c.minX = math.max(0, c.minX - cfg.erode);
      c.minY = math.max(0, c.minY - cfg.erode);
      c.maxX = math.min(w - 1, c.maxX + cfg.erode);
      c.maxY = math.min(h - 1, c.maxY + cfg.erode);
      String? why;
      final aspect = c.bw / math.max(1, c.bh);
      if (c.bh < hMin || c.bw < wMin) {
        why = 'small';
      } else if (c.bh > hMax || c.bw > wMax) {
        why = 'big';
      } else if (c.minX == 0 || c.maxX == w - 1) {
        // Cut off by the frame edge: unreadable, and usually a placemat.
        why = 'edge';
      } else if (aspect < cfg.minAspect || aspect > cfg.maxAspect) {
        why = 'aspect';
      } else if (c.area / (c.bw * c.bh) < cfg.minFill) {
        why = 'fill';
      } else {
        // Paper with ink inside: a bright metal segment, a window pane or
        // a sleeve cuff has no pips.
        final px = (c.bw * 0.2).round(), py = (c.bh * 0.6).round();
        final (crop, cw, ch) = cropRgbaImage(rgba, w, h, PixRect(c.minX - px, c.minY - py, c.maxX + 1 + px, c.maxY + 1 + py));
        final r = readBoardCard(crop, cw, ch, box: const PixRect(0, 0, 0, 0), cfg: cfg);
        if (!r.face && r.inkBlobs == 0) why = 'noink';
      }
      out.add((c, why));
    }
  }
  return out;
}

/// A blob wider than [BoardReaderConfig.splitAspect] is cut at every column
/// run where its paper count drops below [splitDip] of the median column,
/// as long as every part is at least a card wide; otherwise it is kept
/// whole. Parts get their own bounds and area; the mean position is
/// approximate (the part's box centre).
List<_Comp> _splitAtDips(_Comp c, Uint8List m, int w, double wMin, BoardReaderConfig cfg) {
  final aspect = c.bw / math.max(1, c.bh);
  if (aspect < cfg.splitAspect) return [c];
  final cols = Int32List(c.bw);
  for (var y = c.minY; y <= c.maxY; y++) {
    for (var x = c.minX; x <= c.maxX; x++) {
      if (c.labels[y * w + x] == c.lab) cols[x - c.minX]++;
    }
  }
  final sorted = [...cols]..sort();
  final median = sorted[sorted.length ~/ 2];
  final cuts = <int>[];
  final margin = math.max(2, wMin.round());
  var inDip = false, dipStart = 0;
  for (var x = 0; x <= c.bw; x++) {
    final dip = x < c.bw && cols[x] < cfg.splitDip * median;
    if (dip && !inDip) {
      inDip = true;
      dipStart = x;
    } else if (!dip && inDip) {
      inDip = false;
      final mid = (dipStart + x) ~/ 2;
      if (mid >= margin && mid <= c.bw - margin && (cuts.isEmpty || mid - cuts.last >= margin)) cuts.add(mid);
    }
  }
  if (cuts.isEmpty) return [c];
  final parts = <_Comp>[];
  var x0 = 0;
  for (final cut in [...cuts, c.bw]) {
    final p = _Comp(c.minX + x0, c.maxY, c.labels, c.lab)
      ..maxX = c.minX + cut - 1
      ..minY = c.maxY;
    for (var x = x0; x < cut; x++) {
      p.area += cols[x];
    }
    // Vertical extent of this part.
    for (var y = c.minY; y <= c.maxY; y++) {
      for (var x = p.minX; x <= p.maxX; x++) {
        if (c.labels[y * w + x] == c.lab) {
          if (y < p.minY) p.minY = y;
          break;
        }
      }
    }
    p.sx = p.area * (p.minX + p.maxX) / 2;
    p.sy = p.area * (p.minY + p.maxY) / 2;
    if (p.area > 0) parts.add(p);
    x0 = cut;
  }
  return parts;
}

/// Diagnostics (tool/board_probe.dart): one line per paper component of
/// at least 8 pixels, with the detector's verdict.
List<String> probeBoardCards(Uint8List rgba, int w, int h,
        {required int shortSide, BoardReaderConfig cfg = const BoardReaderConfig()}) =>
    [
      for (final (c, why) in _candidates(rgba, w, h, shortSide, cfg))
        if (c.area >= 8)
          'paper area ${c.area} box [${c.minX},${c.minY} ${c.bw}x${c.bh}] '
              'aspect ${(c.bw / math.max(1, c.bh)).toStringAsFixed(2)} fill ${(c.area / (c.bw * c.bh)).toStringAsFixed(2)}: '
              '${why ?? 'CANDIDATE'}'
    ];

// ------------------------------------------------------------------ read

/// Reads one board card from an upright RGBA crop of it (a little margin
/// around the card is fine). [box] is only carried into the result.
BoardCardRead readBoardCard(Uint8List rgba, int w, int h,
    {required PixRect box, BoardReaderConfig cfg = const BoardReaderConfig(), Map<String, Object?>? probe}) {
  final n = w * h;
  if (n == 0) return BoardCardRead(box: box);
  final paper = Uint8List(n);
  final hue = Uint8List(n), sat = Uint8List(n), val = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    final r = rgba[o], g = rgba[o + 1], b = rgba[o + 2];
    final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
    final d = mx - mn;
    val[i] = mx;
    sat[i] = mx == 0 ? 0 : 255 * d ~/ mx;
    int hh = 0;
    if (d != 0) {
      if (mx == r) {
        hh = (30 * (g - b) ~/ d);
      } else if (mx == g) {
        hh = 60 + 30 * (b - r) ~/ d;
      } else {
        hh = 120 + 30 * (r - g) ~/ d;
      }
      if (hh < 0) hh += 180;
    }
    hue[i] = hh;
    if (mx >= cfg.paperVMin && sat[i] < cfg.paperSMax) paper[i] = 1;
  }
  // The card = the paper component under the crop's centre (the crop is
  // centred on the detected card; a neighbour card may be in the margin),
  // else the largest. "Inside" = between its first and last paper pixel
  // on each row and each column (a cheap hull).
  final comps = _components(paper, w, h, conn8: false);
  if (comps.isEmpty) return BoardCardRead(box: box);
  _Comp? card;
  final centre = (h ~/ 2) * w + w ~/ 2;
  for (final c in comps) {
    if (c.labels[centre] == c.lab) card = c;
  }
  if (card == null) {
    for (final c in comps) {
      if (card == null || c.area > card.area) card = c;
    }
  }
  final inside = Uint8List(n);
  final rowFirst = Int32List(h)..fillRange(0, h, -1), rowLast = Int32List(h);
  final colFirst = Int32List(w)..fillRange(0, w, -1), colLast = Int32List(w);
  var paperV = 0, paperN = 0;
  for (var y = card!.minY; y <= card.maxY; y++) {
    for (var x = card.minX; x <= card.maxX; x++) {
      final i = y * w + x;
      if (card.labels[i] != card.lab) continue;
      paperV += val[i];
      paperN++;
      if (rowFirst[y] < 0) rowFirst[y] = x;
      rowLast[y] = x;
      if (colFirst[x] < 0) colFirst[x] = y;
      colLast[x] = y;
    }
  }
  if (paperN == 0) return BoardCardRead(box: box);
  paperV ~/= paperN;
  var insideN = 0;
  for (var y = card.minY; y <= card.maxY; y++) {
    if (rowFirst[y] < 0) continue;
    for (var x = rowFirst[y]; x <= rowLast[y]; x++) {
      if (colFirst[x] >= 0 && y >= colFirst[x] && y <= colLast[x]) {
        inside[y * w + x] = 1;
        insideN++;
      }
    }
  }
  final cardArea = insideN.toDouble();
  // Ink classes inside the card, relative to ITS paper: anything not
  // white is ink. Red ink comes out pale pink after white balance and a
  // blurred black pip has grey edges, so fixed gates would cut pips into
  // pieces.
  final ink = Uint8List(n); // 1 red, 2 dark, 3 picture
  var pictureN = 0, centralInk = 0, centralN = 0;
  final whiteV = (cfg.inkWhiteFrac * paperV).round(), darkV = (cfg.darkFrac * paperV).round();
  final blackV = (cfg.blackFrac * paperV).round();
  // The middle of the card: a picture covers it, pips leave most of it white.
  final cx0 = card.minX + card.bw ~/ 5, cx1 = card.maxX - card.bw ~/ 5;
  final cy0 = card.minY + card.bh ~/ 5, cy1 = card.maxY - card.bh ~/ 5;
  for (var i = 0; i < n; i++) {
    if (inside[i] == 0) continue;
    final x = i % w, y = i ~/ w;
    final central = x >= cx0 && x <= cx1 && y >= cy0 && y <= cy1;
    if (central) centralN++;
    if (sat[i] < cfg.inkSMin && val[i] >= whiteV) continue; // white
    if (central) centralInk++;
    final hh = hue[i];
    final redHue = hh <= cfg.redHueMax || hh >= 160;
    if (redHue && sat[i] >= cfg.deepRedSMin && val[i] >= blackV ~/ 2) {
      // Deep red: a heart in shadow is dark but stays saturated; brown
      // (black ink under a warm lamp) never gets this saturated.
      ink[i] = 1;
    } else if (val[i] < blackV) {
      // Black ink is dark whatever its hue (under a warm lamp it is brown
      // and reads as a red hue); red ink is bright pink after white
      // balance. Value tells them apart, not hue.
      ink[i] = 2;
    } else if (redHue && sat[i] >= cfg.inkSMin) {
      ink[i] = 1;
    } else if (sat[i] < cfg.pictureSMin) {
      if (val[i] < darkV) ink[i] = 2;
    } else {
      // Yellow, blue, green: the picture of a face card.
      ink[i] = 3;
      pictureN++;
    }
  }
  // Ink blobs (4-connected, so two pips that touch at a corner stay two).
  // A blob touching the hull's boundary is the card's own edge or shadow,
  // or a neighbour card poking in: never a pip.
  final blobs = _components(ink, w, h, conn8: false);
  final pips = <_Comp>[];
  final pipRed = <_Comp, bool>{};
  var maxArea = 0, widest = 0;
  for (final b in blobs) {
    var edge = false, redPx = 0;
    for (var y = b.minY; y <= b.maxY && !edge; y++) {
      for (var x = b.minX; x <= b.maxX; x++) {
        final i = y * w + x;
        if (b.labels[i] != b.lab) continue;
        if (ink[i] == 1) redPx++;
        if (x == 0 || y == 0 || x == w - 1 || y == h - 1 || inside[i - 1] == 0 || inside[i + 1] == 0 || inside[i - w] == 0 || inside[i + w] == 0) {
          edge = true;
          break;
        }
      }
    }
    if (edge) continue;
    widest = math.max(widest, b.bw);
    pips.add(b);
    pipRed[b] = redPx * 2 >= b.area;
    maxArea = math.max(maxArea, b.area);
  }
  final picture = pictureN / cardArea;
  final lo = cfg.pipMinFrac * cardArea, hi = cfg.pipMaxFrac * cardArea;
  final inkBlobs = pips.where((b) => b.area >= lo).length;
  // Colour: by the ink of pip-sized blobs, not stray specks.
  var redA = 0, blackA = 0;
  for (final b in pips) {
    if (b.area < lo) continue;
    if (pipRed[b]!) {
      redA += b.area;
    } else {
      blackA += b.area;
    }
  }
  final red = redA + blackA == 0 ? null : redA > blackA;
  if (probe != null) {
    probe['paper'] = paperN;
    probe['inside'] = insideN;
    probe['paperV'] = paperV;
    probe['redA'] = redA;
    probe['blackA'] = blackA;
    probe['picture'] = pictureN;
    probe['blobs'] = [for (final b in pips) '${b.area}@${b.bw}x${b.bh}${pipRed[b]! ? 'r' : 'b'}'];
  }
  // A face card: coloured picture ink, or one ink region spanning most
  // of the card (the picture's frame; a pip never does).
  final middleInk = centralN == 0 ? 0.0 : centralInk / centralN;
  // Pips are low (a fifth or sixth of the card); picture fragments are
  // tall. Two tall ink blobs: a face card. One: an ace's single pip.
  final tall = pips.where((b) => b.bh >= cfg.tallBlobFrac * card!.bh && b.area >= lo).length;
  if (probe != null) probe['centre'] = '${middleInk.toStringAsFixed(2)} tall $tall';
  if (picture >= cfg.faceInkFrac ||
      widest >= cfg.faceWidthFrac * card.bw ||
      middleInk >= cfg.faceCentreFrac ||
      tall >= 2) {
    return BoardCardRead(
      face: true,
      red: red,
      rankConf: math.min(1.0, 0.5 + picture * 4),
      box: box,
      inkBlobs: inkBlobs,
    );
  }
  // Ace: one dominant pip (the indices beside it are far smaller).
  if (maxArea >= cfg.aceMinFrac * cardArea) {
    final big = pips.where((b) => b.area >= 0.4 * maxArea).length;
    if (big == 1) {
      final pip = pips.firstWhere((b) => b.area == maxArea);
      final r = pipRed[pip]!;
      return BoardCardRead(
        rank: 12,
        red: r,
        suit: _suitOf2(r, _fat(pip)),
        rankConf: 0.9,
        suitConf: 0.4,
        box: box,
        pips: 1,
        inkBlobs: inkBlobs,
      );
    }
  }
  // Number card: pips of pip size, not the tiny corner indices.
  final sized = [for (final b in pips) if (b.area >= lo && b.area <= hi) b];
  if (sized.isEmpty) return BoardCardRead(red: red, box: box, inkBlobs: inkBlobs);
  final areas = [for (final b in sized) b.area]..sort();
  final median = areas[areas.length ~/ 2];
  final counted = [
    for (final b in sized)
      if (b.area >= 0.45 * median && b.area <= 3.4 * median && pipRed[b] == red) b
  ];
  // Pips in one column of a foreshortened card touch: a blob of twice the
  // median area is two pips (three at most).
  var count = 0, merged = 0;
  for (final b in counted) {
    final k = (b.area / median).round().clamp(1, 3);
    count += k;
    if (k > 1) merged++;
  }
  if (count < 2 || count > 10) return BoardCardRead(red: red, box: box, pips: count, inkBlobs: inkBlobs);
  // Confidence: like-sized pips (a clean count) and no stray ink.
  var mean = 0.0;
  for (final b in counted) {
    mean += b.area;
  }
  mean /= counted.length;
  var varSum = 0.0;
  for (final b in counted) {
    varSum += (b.area - mean) * (b.area - mean);
  }
  final cv = math.sqrt(varSum / counted.length) / mean;
  final stray = sized.length - counted.length;
  final rankConf = (0.95 - cv * 0.6 - stray * 0.12 - merged * 0.15).clamp(0.2, 0.95);
  // Suit by majority of the pips' shapes.
  var fatVotes = 0;
  for (final b in counted) {
    if (_fat(b)) fatVotes++;
  }
  final fat = fatVotes * 2 > counted.length;
  final suit = red == null ? null : _suitOf2(red, fat);
  final margin = (fatVotes * 2 - counted.length).abs() / counted.length;
  return BoardCardRead(
    rank: count - 2,
    red: red,
    suit: suit,
    rankConf: rankConf,
    suitConf: red == null ? 0 : (0.3 + 0.4 * margin).clamp(0.2, 0.7),
    box: box,
    pips: count,
    inkBlobs: inkBlobs,
  );
}

/// A pip that fills most of its box: a heart or a spade (a diamond is a
/// thin rhombus, a club lumpy).
bool _fat(_Comp pip) => pip.area / (pip.bw * pip.bh) >= 0.6;

/// Red: fat = heart (2), thin = diamond (1). Black: fat = spade (3), thin = club (0).
int _suitOf2(bool red, bool fat) => red ? (fat ? 2 : 1) : (fat ? 3 : 0);

/// Diagnostics: the ink statistics [readBoardCard] worked from.
Map<String, Object?> probeCard(Uint8List rgba, int w, int h, {BoardReaderConfig cfg = const BoardReaderConfig()}) {
  final m = <String, Object?>{};
  readBoardCard(rgba, w, h, box: const PixRect(0, 0, 0, 0), cfg: cfg, probe: m);
  return m;
}

// ------------------------------------------------------------- components

class _Comp {
  int area = 0;
  int minX, minY, maxX, maxY;
  double sx = 0, sy = 0;
  final Int32List labels;
  final int lab;
  _Comp(this.minX, this.minY, this.labels, this.lab)
      : maxX = minX,
        maxY = minY;
  int get bw => maxX - minX + 1;
  int get bh => maxY - minY + 1;
  double get cx => sx / area;
  double get cy => sy / area;
}

/// 3x3 erosion (out-of-image counts as unset).
Uint8List _erode3(Uint8List m, int w, int h) {
  final out = Uint8List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      if (m[i] == 0) continue;
      if (m[i - 1] != 0 && m[i + 1] != 0 && m[i - w] != 0 && m[i + w] != 0 &&
          m[i - w - 1] != 0 && m[i - w + 1] != 0 && m[i + w - 1] != 0 && m[i + w + 1] != 0) {
        out[i] = 1;
      }
    }
  }
  return out;
}

/// Connected components of nonzero pixels (4- or 8-connected). Each
/// component's [labels] view is shared: label value = index + 1.
List<_Comp> _components(Uint8List m, int w, int h, {required bool conn8}) {
  final labels = Int32List(w * h);
  final out = <_Comp>[];
  final stack = <int>[];
  for (var i = 0; i < w * h; i++) {
    if (m[i] == 0 || labels[i] != 0) continue;
    final lab = out.length + 1;
    final c = _Comp(i % w, i ~/ w, labels, lab);
    labels[i] = lab;
    stack.add(i);
    while (stack.isNotEmpty) {
      final q = stack.removeLast();
      final x = q % w, y = q ~/ w;
      c.area++;
      c.sx += x;
      c.sy += y;
      if (x < c.minX) c.minX = x;
      if (x > c.maxX) c.maxX = x;
      if (y < c.minY) c.minY = y;
      if (y > c.maxY) c.maxY = y;
      void push(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
        final j = ny * w + nx;
        if (m[j] != 0 && labels[j] == 0) {
          labels[j] = lab;
          stack.add(j);
        }
      }

      push(x - 1, y);
      push(x + 1, y);
      push(x, y - 1);
      push(x, y + 1);
      if (conn8) {
        push(x - 1, y - 1);
        push(x + 1, y - 1);
        push(x - 1, y + 1);
        push(x + 1, y + 1);
      }
    }
    out.add(c);
  }
  return out;
}
