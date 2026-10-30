/// Pure-Dart classical card reader ("glyph reader") for Snap my cards.
///
/// A port of the OpenCV pipeline in tool/camera_lab/real/classical/
/// (pipeline.py + glyphs.py), which was the best reader on the owner's real
/// table photos. No ML Kit, no plugins, no dart:ui, so it runs in a
/// background isolate on Android / iOS and on the main thread on the web.
///
/// Hero (held hole cards):
///   1. downscale so the short side is ~1500 px (area average).
///   2. paper mask  = card stock: low saturation, not dark (OpenCV HSV).
///   3. ink         = adaptive mean threshold on min(R,G,B) (both red and
///                    black ink are dark there) + a separate pure-red mask.
///   4. glyph blobs = connected components of corner-index size that are
///                    mostly surrounded by paper and are either clearly dark
///                    or saturated pure red ("ink purity").
///   5. index pairs = two same-colour blobs about one glyph apart; the
///                    rank->suit vector rotates the index upright (also the
///                    upside-down bottom-right index). The suit is re-matched
///                    at +-30 deg because a slanted rank skews that vector.
///   6. classify    = normalised cross-correlation against glyph templates
///                    rendered offline from system fonts
///                    (tool/camera_lab/make_glyph_templates.py ->
///                    tool/camera_lab/glyph_templates.bin); the ink colour gates
///                    the suit to {d,h} or {c,s}.
///   7. aggregate   = group reads by card, keep the best two.
///
/// Board: each face-up community card of the (souvenir) deck is a paper
/// frame around a photo, so count enclosed, convex, colourful, textured
/// non-paper holes of board-card size. Only the COUNT is estimated (the board
/// is usually out of focus); it is shown as an informational hint.
///
/// All thresholds were tuned on 7 photos of one deck (see
/// tmp/overnight/cv-classical/results.md); treat every output as a guess the
/// user confirms.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../poker/cards.dart';
import 'glyph_cnn.dart';

// ---------------------------------------------------------------- constants

const int _paperSMaxDefault = 62;

/// Colour gates for the hero glyph finder. [readGlyphs] sets them per call:
/// the defaults (tuned on daylight photos) or, with warmLight, looser ones
/// for tungsten-lit live frames where white card stock reads orange.
int _paperSMax = _paperSMaxDefault;
int _redHueMax = 8; // OpenCV hue (0..179): red ink is <= this or >= 166
int _redInkSMin = _redSMin; // red-ink pixel mask
int _redPureSMin = _redSMin + 30; // a red glyph's median saturation
int _redInkVMax = 256; // warm light: lit skin is as orange as red ink, but brighter
double _ringPaperMin = 0.5; // share of a glyph's surroundings that must be card stock

const int _paperVMin = 90;
const int _redSMin = 110;
const double _boardSolidity = 0.75;
const int _boardVStdMin = 12;
const List<int> _suitRotSearch = [-30, -20, -10, 0, 10, 20, 30];
const double _rotPenalty = 0.002; // per degree
const double _scoreMin = 0.45;

/// Template-matching hero reads at or above this score count as "confident".
const double glyphConfidentScore = 0.65;

/// CNN hero reads (P(rank) * P(suit)) at or above this count as "confident".
const double glyphCnnConfidentScore = 0.5;

/// CNN reads below this are dropped.
const double _cnnScoreMin = 0.25;

/// Test-time rotations (degrees) for the CNN crops.
const List<double> _cnnTta = [0, -25, 25];

// ---------------------------------------------------------------- templates

/// Glyph templates: per rank (0..12) and suit (0..3) a stack of
/// zero-mean, unit-norm float templates, flattened row-major.
class GlyphTemplates {
  final int rankW, rankH, suitW, suitH;
  final List<Float32List> rank; // 13 stacks
  final List<Float32List> suit; // 4 stacks

  GlyphTemplates._(this.rankW, this.rankH, this.suitW, this.suitH, this.rank, this.suit);

  int get count =>
      rank.fold<int>(0, (a, s) => a + s.length ~/ (rankW * rankH)) +
      suit.fold<int>(0, (a, s) => a + s.length ~/ (suitW * suitH));

  /// Parses tool/camera_lab/glyph_templates.bin (format: see the generator).
  factory GlyphTemplates.parse(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    if (bytes.length < 13 || String.fromCharCodes(bytes.sublist(0, 4)) != 'FNGT' || bytes[4] != 1) {
      throw const FormatException('Not a glyph template file');
    }
    final rw = bytes[5], rh = bytes[6], sw = bytes[7], sh = bytes[8];
    final n = bd.getUint32(9, Endian.little);
    final rankLists = List.generate(13, (_) => <Float32List>[]);
    final suitLists = List.generate(4, (_) => <Float32List>[]);
    var off = 13;
    for (var k = 0; k < n; k++) {
      final kind = bytes[off], label = bytes[off + 1];
      off += 2;
      final w = kind == 0 ? rw : sw, h = kind == 0 ? rh : sh;
      final nbytes = (w * h + 7) >> 3;
      final px = Float64List(w * h);
      for (var i = 0; i < w * h; i++) {
        if ((bytes[off + (i >> 3)] >> (7 - (i & 7))) & 1 == 1) px[i] = 1;
      }
      off += nbytes;
      final t = _finishTemplate(px, w, h);
      if (t == null) continue;
      (kind == 0 ? rankLists[label] : suitLists[label]).add(t);
    }
    Float32List stack(List<Float32List> l, int len) {
      final out = Float32List(l.length * len);
      for (var i = 0; i < l.length; i++) {
        out.setAll(i * len, l[i]);
      }
      return out;
    }

    return GlyphTemplates._(rw, rh, sw, sh, [for (final l in rankLists) stack(l, rw * rh)],
        [for (final l in suitLists) stack(l, sw * sh)]);
  }
}

/// 3x3 Gaussian (sigma 0.8, BORDER_REFLECT_101), zero mean, unit L2 norm.
Float32List? _finishTemplate(Float64List px, int w, int h) {
  const e = 0.45783335; // exp(-1 / (2 * 0.8^2))
  const k0 = 1 / (1 + 2 * e), k1 = e / (1 + 2 * e);
  int refl(int i, int n) => i < 0 ? -i : (i >= n ? 2 * n - 2 - i : i);
  final tmp = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      tmp[y * w + x] = k1 * px[y * w + refl(x - 1, w)] + k0 * px[y * w + x] + k1 * px[y * w + refl(x + 1, w)];
    }
  }
  final out = Float32List(w * h);
  var mean = 0.0;
  final blurred = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = k1 * tmp[refl(y - 1, h) * w + x] + k0 * tmp[y * w + x] + k1 * tmp[refl(y + 1, h) * w + x];
      blurred[y * w + x] = v;
      mean += v;
    }
  }
  mean /= w * h;
  var ss = 0.0;
  for (var i = 0; i < w * h; i++) {
    final v = blurred[i] - mean;
    blurred[i] = v;
    ss += v * v;
  }
  final n = math.sqrt(ss);
  if (n <= 1e-6) return null;
  for (var i = 0; i < w * h; i++) {
    out[i] = blurred[i] / n;
  }
  return out;
}

// ---------------------------------------------------------------- results

/// One card the reader believes it saw.
class GlyphCard {
  /// 0..51 (see lib/poker/cards.dart).
  final int card;

  /// Template match score (about 0.45..0.95); [glyphConfidentScore] and up
  /// is a confident read.
  final double score;

  /// How many corner indices voted for this card.
  final int votes;

  /// Score above the confidence bar of the classifier that produced it.
  final bool confident;
  const GlyphCard(this.card, this.score, this.votes, {required this.confident});

  @override
  String toString() => '${cardToString(card)} ${score.toStringAsFixed(2)}';
}

class GlyphReadResult {
  /// Up to two hero-card candidates, best first.
  final List<GlyphCard> hero;

  /// Every accepted corner-index read (debugging).
  final List<GlyphCard> reads;

  /// Number of face-up board cards found (raw count, may be any number).
  final int boardCount;

  /// Width x height the pipeline worked at.
  final int workWidth, workHeight;

  /// Stage timings in milliseconds.
  final Map<String, int> timingMs;

  const GlyphReadResult({
    required this.hero,
    required this.reads,
    required this.boardCount,
    this.workWidth = 0,
    this.workHeight = 0,
    this.timingMs = const {},
  });

  static const empty = GlyphReadResult(hero: [], reads: [], boardCount: 0);

  /// Two different cards, both read confidently.
  bool get confident =>
      hero.length == 2 && hero[0].card != hero[1].card && hero.every((c) => c.confident);

  /// 0 / 3 / 4 / 5 when the count is a legal street, else null.
  int? get boardEstimate => const {0, 3, 4, 5}.contains(boardCount) ? boardCount : null;

  /// "preflop" / "flop" / "turn" / "river", or null when unsure.
  String? get street => switch (boardEstimate) {
        0 => 'preflop',
        3 => 'flop',
        4 => 'turn',
        5 => 'river',
        _ => null,
      };
}

// ---------------------------------------------------------------- entry

/// Message for [readGlyphsMessage] (isolate friendly: only typed data).
class GlyphReadRequest {
  final Uint8List rgba;
  final int width, height;
  /// tool/camera_lab/glyph_templates.bin (used when [cnn] is null).
  final Uint8List? templates;

  /// assets/data/glyph_cnn.bin (preferred classifier).
  final Uint8List? cnn;
  final int targetShortSide;
  const GlyphReadRequest(this.rgba, this.width, this.height,
      {this.templates, this.cnn, this.targetShortSide = 1500});
}

/// Top-level function for `compute(readGlyphsMessage, request)`.
GlyphReadResult readGlyphsMessage(GlyphReadRequest r) => readGlyphs(r.rgba, r.width, r.height,
    templates: r.templates == null ? null : GlyphTemplates.parse(r.templates!),
    cnn: r.cnn == null ? null : GlyphCnn.parse(r.cnn!),
    targetShortSide: r.targetShortSide);

/// Reads hero cards and the board count from an RGBA photo.
///
/// The corner indices are classified by [cnn] when given (the better reader
/// on real photos), else by template matching against [templates].
///
/// [scaleShortSide]: [rgba] is a crop of a frame with this short side;
/// glyph-size limits use it instead of the crop's own size.
///
/// [warmLight]: live frames under warm room light (Watch my cards): card
/// stock may be orange-tinted (paper saturation up to 100) and red ink
/// orange and paler (hue up to 14, saturation from 90-100). The board
/// finder keeps the daylight gates.
///
/// [ringPaperMin]: share of a glyph's surroundings that must be card stock
/// (0.5). A standard deck's small suit index sits next to a big pip on low
/// cards, so that share drops below half there.
///
/// [tta] = false classifies each glyph once instead of at three rotations
/// (about half the time). Watch my cards uses it: agreement over several
/// frames replaces the rotation voting.
GlyphReadResult readGlyphs(Uint8List rgba, int width, int height,
    {GlyphTemplates? templates,
    GlyphCnn? cnn,
    int targetShortSide = 1500,
    bool tta = true,
    int? scaleShortSide,
    bool warmLight = false,
    double ringPaperMin = 0.5}) {
  if (templates == null && cnn == null) throw ArgumentError('templates or cnn required');
  _paperSMax = warmLight ? 100 : _paperSMaxDefault;
  _redHueMax = warmLight ? 14 : 8;
  _redInkSMin = warmLight ? 90 : _redSMin;
  _redPureSMin = warmLight ? 100 : _redSMin + 30;
  _redInkVMax = warmLight ? 165 : 256;
  _ringPaperMin = ringPaperMin;
  final sw = Stopwatch()..start();
  final timing = <String, int>{};
  final img = _Planes.fromRgba(rgba, width, height, targetShortSide);
  if (scaleShortSide != null) img.sRef = (scaleShortSide * img.w / width).round();
  timing['resize'] = sw.elapsedMilliseconds;
  final hsv = _Hsv(img);
  timing['hsv'] = sw.elapsedMilliseconds - timing['resize']!;
  var t0 = sw.elapsedMilliseconds;
  final board = _findBoard(img, hsv);
  timing['board'] = sw.elapsedMilliseconds - t0;
  t0 = sw.elapsedMilliseconds;
  final List<_Read> reads;
  final List<GlyphCard> hero;
  if (cnn != null) {
    reads = _readIndicesCnn(img, hsv, cnn, board, tta ? _cnnTta : const [0]);
    hero = _heroFromCnnReads(reads);
  } else {
    reads = _readIndices(img, hsv, templates!, board);
    hero = _heroFromReads(reads);
  }
  timing['hero'] = sw.elapsedMilliseconds - t0;
  timing['total'] = sw.elapsedMilliseconds;
  return GlyphReadResult(
    hero: hero,
    reads: [
      for (final r in reads)
        GlyphCard(r.card, r.score, 1,
            confident: r.score >= (cnn != null ? glyphCnnConfidentScore : glyphConfidentScore))
    ],
    boardCount: board.length,
    workWidth: img.w,
    workHeight: img.h,
    timingMs: timing,
  );
}

// ---------------------------------------------------------------- image

class _Planes {
  final int w, h;
  final Uint8List r, g, b;
  _Planes(this.w, this.h, this.r, this.g, this.b);

  /// Short side of the working image (all size parameters scale with it),
  /// or of the frame a crop came from ([sRef]), so glyph sizes are judged
  /// against the whole view, as the thresholds were tuned.
  int get s => sRef ?? math.min(w, h);
  int? sRef;

  factory _Planes.fromRgba(Uint8List rgba, int width, int height, int targetShort) {
    final short = math.min(width, height);
    if (short <= targetShort * 1.05) {
      final n = width * height;
      final r = Uint8List(n), g = Uint8List(n), b = Uint8List(n);
      for (var i = 0, j = 0; i < n; i++, j += 4) {
        r[i] = rgba[j];
        g[i] = rgba[j + 1];
        b[i] = rgba[j + 2];
      }
      return _Planes(width, height, r, g, b);
    }
    final scale = targetShort / short;
    final dw = (width * scale).round(), dh = (height * scale).round();
    final xs = _areaTaps(width, dw), ys = _areaTaps(height, dh);
    Uint8List plane(int c) {
      // horizontal
      final tmp = Float32List(dw * height);
      for (var y = 0; y < height; y++) {
        final row = y * width * 4 + c;
        for (var x = 0; x < dw; x++) {
          final t = xs[x];
          var acc = 0.0;
          for (var k = 0; k < t.idx.length; k++) {
            acc += rgba[row + t.idx[k] * 4] * t.wt[k];
          }
          tmp[y * dw + x] = acc;
        }
      }
      final out = Uint8List(dw * dh);
      for (var y = 0; y < dh; y++) {
        final t = ys[y];
        for (var x = 0; x < dw; x++) {
          var acc = 0.0;
          for (var k = 0; k < t.idx.length; k++) {
            acc += tmp[t.idx[k] * dw + x] * t.wt[k];
          }
          out[y * dw + x] = acc.round().clamp(0, 255);
        }
      }
      return out;
    }

    return _Planes(dw, dh, plane(0), plane(1), plane(2));
  }
}

class _Taps {
  final Int32List idx;
  final Float64List wt;
  _Taps(this.idx, this.wt);
}

/// OpenCV INTER_AREA taps for shrinking one axis (src > dst).
List<_Taps> _areaTaps(int src, int dst) {
  final scale = src / dst;
  return List.generate(dst, (d) {
    final a = d * scale, b = (d + 1) * scale;
    final i0 = a.floor(), i1 = math.min(src, b.ceil());
    final idx = <int>[], wt = <double>[];
    for (var i = i0; i < i1; i++) {
      final ov = math.min(b, i + 1.0) - math.max(a, i.toDouble());
      if (ov > 1e-9) {
        idx.add(i);
        wt.add(ov / scale);
      }
    }
    return _Taps(Int32List.fromList(idx), Float64List.fromList(wt));
  });
}

/// OpenCV INTER_AREA taps when the other axis (or this one) enlarges:
/// OpenCV falls back to a 2-tap linear-like filter in that case.
List<_Taps> _areaEnlargeTaps(int src, int dst) {
  final scale = src / dst, inv = dst / src;
  return List.generate(dst, (d) {
    final sx = (d * scale).floor();
    var fx = (d + 1) - (sx + 1) * inv;
    fx = fx <= 0 ? 0 : fx - fx.floor();
    final a = math.min(sx, src - 1), b = math.min(sx + 1, src - 1);
    return _Taps(Int32List.fromList([a, b]), Float64List.fromList([1 - fx, fx]));
  });
}

/// cv2.resize(src, (dw, dh), INTER_AREA) on a single float plane.
Float64List _resizeArea(Float64List src, int sw, int sh, int dw, int dh) {
  final shrinkBoth = sw >= dw && sh >= dh;
  final xs = shrinkBoth ? _areaTaps(sw, dw) : _areaEnlargeTaps(sw, dw);
  final ys = shrinkBoth ? _areaTaps(sh, dh) : _areaEnlargeTaps(sh, dh);
  final tmp = Float64List(dw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < dw; x++) {
      final t = xs[x];
      var acc = 0.0;
      for (var k = 0; k < t.idx.length; k++) {
        acc += src[y * sw + t.idx[k]] * t.wt[k];
      }
      tmp[y * dw + x] = acc;
    }
  }
  final out = Float64List(dw * dh);
  for (var y = 0; y < dh; y++) {
    final t = ys[y];
    for (var x = 0; x < dw; x++) {
      var acc = 0.0;
      for (var k = 0; k < t.idx.length; k++) {
        acc += tmp[t.idx[k] * dw + x] * t.wt[k];
      }
      out[y * dw + x] = acc;
    }
  }
  return out;
}

/// OpenCV-style 8-bit HSV (H 0..179, S and V 0..255) plus min(R,G,B).
class _Hsv {
  final Uint8List h, s, v, minc;
  _Hsv._(this.h, this.s, this.v, this.minc);

  factory _Hsv(_Planes p) {
    final n = p.w * p.h;
    final h = Uint8List(n), s = Uint8List(n), v = Uint8List(n), mn = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final r = p.r[i], g = p.g[i], b = p.b[i];
      final mx = math.max(r, math.max(g, b));
      final mi = math.min(r, math.min(g, b));
      v[i] = mx;
      mn[i] = mi;
      final d = mx - mi;
      s[i] = mx == 0 ? 0 : (255 * d / mx).round();
      if (d == 0) {
        h[i] = 0;
      } else {
        double hh;
        if (mx == r) {
          hh = 60.0 * (g - b) / d;
        } else if (mx == g) {
          hh = 120.0 + 60.0 * (b - r) / d;
        } else {
          hh = 240.0 + 60.0 * (r - g) / d;
        }
        if (hh < 0) hh += 360;
        final q = (hh / 2).round();
        h[i] = q >= 180 ? q - 180 : q;
      }
    }
    return _Hsv._(h, s, v, mn);
  }
}

/// Inclusive-exclusive integral image of a 0/1 (or small int) plane.
Int32List _integral(Uint8List m, int w, int h) {
  final ii = Int32List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var rowSum = 0;
    for (var x = 0; x < w; x++) {
      rowSum += m[y * w + x];
      ii[(y + 1) * (w + 1) + x + 1] = ii[y * (w + 1) + x + 1] + rowSum;
    }
  }
  return ii;
}

int _boxSum(Int32List ii, int w, int x0, int y0, int x1, int y1) {
  final W = w + 1;
  return ii[y1 * W + x1] - ii[y0 * W + x1] - ii[y1 * W + x0] + ii[y0 * W + x0];
}

/// Binary dilation with a k x k square (k odd).
Uint8List _dilate(Uint8List m, int w, int h, int k) {
  final r = k ~/ 2;
  final ii = _integral(m, w, h);
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final y0 = math.max(0, y - r), y1 = math.min(h, y + r + 1);
    for (var x = 0; x < w; x++) {
      final x0 = math.max(0, x - r), x1 = math.min(w, x + r + 1);
      if (_boxSum(ii, w, x0, y0, x1, y1) > 0) out[y * w + x] = 1;
    }
  }
  return out;
}

/// 3x3 morphological opening (erode: out-of-image counts as set, as OpenCV).
Uint8List _open3(Uint8List m, int w, int h) {
  final er = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var ok = 1;
      for (var dy = -1; dy <= 1 && ok == 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          if (m[yy * w + xx] == 0) {
            ok = 0;
            break;
          }
        }
      }
      er[y * w + x] = ok;
    }
  }
  return _dilate(er, w, h, 3);
}

class _Comp {
  int minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1, area = 0;
  double sumX = 0, sumY = 0;
  bool touchesBorder = false;
  int get bw => maxX - minX + 1;
  int get bh => maxY - minY + 1;
  double get cx => sumX / area;
  double get cy => sumY / area;
}

/// Connected components of nonzero pixels. Labels start at [firstLabel];
/// returns components indexed by label - firstLabel.
List<_Comp> _components(Uint8List m, int w, int h, Int32List labels, int firstLabel,
    {required bool conn8, Int32List? stack}) {
  final comps = <_Comp>[];
  final st = stack ?? Int32List(w * h);
  for (var start = 0; start < w * h; start++) {
    if (m[start] == 0 || labels[start] != 0) continue;
    final lab = firstLabel + comps.length;
    final c = _Comp();
    comps.add(c);
    var sp = 0;
    st[sp++] = start;
    labels[start] = lab;
    while (sp > 0) {
      final p = st[--sp];
      final x = p % w, y = p ~/ w;
      c.area++;
      c.sumX += x;
      c.sumY += y;
      if (x < c.minX) c.minX = x;
      if (x > c.maxX) c.maxX = x;
      if (y < c.minY) c.minY = y;
      if (y > c.maxY) c.maxY = y;
      if (x == 0 || y == 0 || x == w - 1 || y == h - 1) c.touchesBorder = true;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          if (!conn8 && dx != 0 && dy != 0) continue;
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          final q = yy * w + xx;
          if (m[q] != 0 && labels[q] == 0) {
            labels[q] = lab;
            st[sp++] = q;
          }
        }
      }
    }
  }
  return comps;
}

double _median(List<int> v) {
  if (v.isEmpty) return 0;
  v.sort();
  final n = v.length;
  return n.isOdd ? v[n ~/ 2].toDouble() : (v[n ~/ 2 - 1] + v[n ~/ 2]) / 2;
}

// ---------------------------------------------------------------- geometry

class _P {
  final double x, y;
  const _P(this.x, this.y);
}

double _cross(_P o, _P a, _P b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

List<_P> _convexHull(List<_P> pts) {
  if (pts.length < 3) return pts;
  pts.sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
  final lower = <_P>[], upper = <_P>[];
  for (final p in pts) {
    while (lower.length >= 2 && _cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  for (final p in pts.reversed) {
    while (upper.length >= 2 && _cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

double _polyArea(List<_P> p) {
  var a = 0.0;
  for (var i = 0; i < p.length; i++) {
    final q = p[(i + 1) % p.length];
    a += p[i].x * q.y - q.x * p[i].y;
  }
  return a.abs() / 2;
}

/// Minimum-area rectangle of a convex hull: centre, unit axis u, half sizes.
class _Rect {
  final double cx, cy, ux, uy, hw, hh;
  const _Rect(this.cx, this.cy, this.ux, this.uy, this.hw, this.hh);

  double get aspect => math.max(hw, hh) / math.max(1e-6, math.min(hw, hh));

  bool contains(double x, double y, double grow) {
    final dx = x - cx, dy = y - cy;
    final a = dx * ux + dy * uy, b = -dx * uy + dy * ux;
    return a.abs() < hw * grow && b.abs() < hh * grow;
  }
}

_Rect _minAreaRect(List<_P> hull) {
  if (hull.length < 3) {
    final p = hull.isEmpty ? const _P(0, 0) : hull.first;
    return _Rect(p.x, p.y, 1, 0, 0.5, 0.5);
  }
  _Rect? best;
  var bestA = double.infinity;
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], b = hull[(i + 1) % hull.length];
    var ux = b.x - a.x, uy = b.y - a.y;
    final l = math.sqrt(ux * ux + uy * uy);
    if (l < 1e-9) continue;
    ux /= l;
    uy /= l;
    var minU = double.infinity, maxU = -double.infinity, minV = double.infinity, maxV = -double.infinity;
    for (final p in hull) {
      final pu = p.x * ux + p.y * uy, pv = -p.x * uy + p.y * ux;
      minU = math.min(minU, pu);
      maxU = math.max(maxU, pu);
      minV = math.min(minV, pv);
      maxV = math.max(maxV, pv);
    }
    final area = (maxU - minU) * (maxV - minV);
    if (area < bestA) {
      bestA = area;
      final cu = (minU + maxU) / 2, cv = (minV + maxV) / 2;
      best = _Rect(cu * ux - cv * uy, cu * uy + cv * ux, ux, uy, (maxU - minU) / 2, (maxV - minV) / 2);
    }
  }
  return best!;
}

// ---------------------------------------------------------------- board

List<_Rect> _findBoard(_Planes img, _Hsv hsv) {
  final w = img.w, h = img.h, n = w * h;
  final paper0 = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (hsv.s[i] < _paperSMaxDefault && hsv.v[i] > _paperVMin) paper0[i] = 1;
  }
  final paper = _open3(paper0, w, h);
  final nonPaper = Uint8List(n);
  for (var i = 0; i < n; i++) {
    nonPaper[i] = 1 - paper[i];
  }
  final labels = Int32List(n);
  final comps = _components(nonPaper, w, h, labels, 1, conn8: false);
  final imgArea = w * h;
  final cards = <(_Rect, int, double, double)>[]; // rect, area, cx, cy
  for (var ci = 0; ci < comps.length; ci++) {
    final c = comps[ci];
    if (c.touchesBorder) continue; // not enclosed by paper
    if (!(c.area > 0.0002 * imgArea && c.area < 0.006 * imgArea)) continue;
    final lab = ci + 1;
    final bx = c.minX, by = c.minY, bw = c.bw, bh = c.bh;
    // Outline: fill interior holes (pale sky islands) by flooding the
    // background from the bbox border.
    final outside = Uint8List(bw * bh);
    final st = <int>[];
    void seed(int x, int y) {
      final q = y * bw + x;
      if (outside[q] == 0 && labels[(by + y) * w + bx + x] != lab) {
        outside[q] = 1;
        st.add(q);
      }
    }

    for (var x = 0; x < bw; x++) {
      seed(x, 0);
      seed(x, bh - 1);
    }
    for (var y = 0; y < bh; y++) {
      seed(0, y);
      seed(bw - 1, y);
    }
    while (st.isNotEmpty) {
      final q = st.removeLast();
      final x = q % bw, y = q ~/ bw;
      if (x > 0) seed(x - 1, y);
      if (x < bw - 1) seed(x + 1, y);
      if (y > 0) seed(x, y - 1);
      if (y < bh - 1) seed(x, y + 1);
    }
    var filled = 0, edge = 0;
    final pts = <_P>[];
    for (var y = 0; y < bh; y++) {
      var first = -1, last = -1;
      for (var x = 0; x < bw; x++) {
        if (outside[y * bw + x] != 0) continue;
        filled++;
        if (first < 0) first = x;
        last = x;
        final isEdge = x == 0 ||
            y == 0 ||
            x == bw - 1 ||
            y == bh - 1 ||
            outside[y * bw + x - 1] != 0 ||
            outside[y * bw + x + 1] != 0 ||
            outside[(y - 1) * bw + x] != 0 ||
            outside[(y + 1) * bw + x] != 0;
        if (isEdge) edge++;
      }
      if (first >= 0) {
        pts.add(_P((bx + first).toDouble(), (by + y).toDouble()));
        if (last != first) pts.add(_P((bx + last).toDouble(), (by + y).toDouble()));
      }
    }
    final hull = _convexHull(pts);
    final hullA = _polyArea(hull);
    // contourArea of the outline through boundary pixel centres.
    final contourA = filled - edge / 2;
    final fill = contourA / math.max(hullA, 1.0);
    final rect = _minAreaRect(hull);
    if (rect.hw * rect.hh <= 0) continue;
    if (fill < _boardSolidity || rect.aspect > 4.0) continue;
    // Frame must be card stock all around: 9x9-dilated ring outside the hole.
    final x0 = math.max(0, bx - 6), y0 = math.max(0, by - 6);
    final x1 = math.min(w, bx + bw + 6), y1 = math.min(h, by + bh + 6);
    final ww = x1 - x0, wh = y1 - y0;
    final own = Uint8List(ww * wh);
    for (var y = 0; y < wh; y++) {
      for (var x = 0; x < ww; x++) {
        if (labels[(y0 + y) * w + x0 + x] == lab) own[y * ww + x] = 1;
      }
    }
    final dil = _dilate(own, ww, wh, 9);
    var ringN = 0, ringPaper = 0;
    for (var y = 0; y < wh; y++) {
      for (var x = 0; x < ww; x++) {
        final q = y * ww + x;
        if (dil[q] == 0 || own[q] != 0) continue;
        ringN++;
        ringPaper += paper[(y0 + y) * w + x0 + x];
      }
    }
    if (ringN == 0 || ringPaper / ringN < 0.8) continue;
    // Pixel statistics of the hole.
    var redInk = 0, darkInk = 0;
    final sats = <int>[];
    var vSum = 0.0, vSq = 0.0;
    for (var y = by; y < by + bh; y++) {
      for (var x = bx; x < bx + bw; x++) {
        final q = y * w + x;
        if (labels[q] != lab) continue;
        final hh = hsv.h[q], ss = hsv.s[q], vv = hsv.v[q];
        if ((hh <= 8 || hh >= 166) && ss > _redSMin) redInk++;
        if (vv < 60) darkInk++;
        sats.add(ss);
        vSum += vv;
        vSq += vv * vv;
      }
    }
    final a = c.area;
    if (math.max(redInk, darkInk) / a > 0.7) continue; // flat ink: a glyph
    if (_median(sats) < 60) continue; // grey table runner etc.
    final vMean = vSum / a;
    final vStd = math.sqrt(math.max(0, vSq / a - vMean * vMean));
    if (vStd < _boardVStdMin) continue; // flat tone
    cards.add((rect, a, c.cx, c.cy));
  }
  // One row of near-equal photos: keep the dominant size cluster.
  if (cards.length > 1) {
    final med = _median([for (final c in cards) c.$2]);
    cards.retainWhere((c) => c.$2 > 0.35 * med && c.$2 < 2.8 * med);
  }
  return [for (final c in cards) c.$1];
}

// ---------------------------------------------------------------- hero

class _Blob {
  final int x, y, w, h;
  final double cx, cy, md;
  final bool red;
  final Float64List mask; // w*h, 0 or 255
  _Blob(this.x, this.y, this.w, this.h, this.cx, this.cy, this.md, this.red, this.mask);
}

class _Read {
  final int card, i, j;
  final double score, md;
  _Read(this.card, this.score, this.i, this.j, this.md);
}

List<_Blob> _findGlyphBlobs(_Planes img, _Hsv hsv, {double minFrac = 0.016, double maxFrac = 0.14}) {
  final w = img.w, h = img.h, n = w * h, s = img.s;
  final paper = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (hsv.s[i] < _paperSMax && hsv.v[i] > _paperVMin) paper[i] = 1;
  }
  final block = (s * 0.03).toInt() | 1;
  final nearPaper = _dilate(paper, w, h, (s * 0.02).toInt() | 1);
  final redInk = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final hh = hsv.h[i];
    if ((hh <= _redHueMax || hh >= 166) && hsv.s[i] > _redInkSMin && hsv.v[i] > 60 && hsv.v[i] < _redInkVMax) {
      redInk[i] = 1;
    }
  }
  // Adaptive mean threshold (block x block, C = 18, inverted) on min(R,G,B).
  final ii = Int32List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var rowSum = 0;
    for (var x = 0; x < w; x++) {
      rowSum += hsv.minc[y * w + x];
      ii[(y + 1) * (w + 1) + x + 1] = ii[y * (w + 1) + x + 1] + rowSum;
    }
  }
  final r = block ~/ 2;
  final redM = Uint8List(n), darkM = Uint8List(n);
  for (var y = 0; y < h; y++) {
    final y0 = math.max(0, y - r), y1 = math.min(h, y + r + 1);
    for (var x = 0; x < w; x++) {
      final q = y * w + x;
      if (nearPaper[q] == 0) continue;
      if (redInk[q] != 0) {
        redM[q] = 1;
        continue;
      }
      final x0 = math.max(0, x - r), x1 = math.min(w, x + r + 1);
      final mean = _boxSum(ii, w, x0, y0, x1, y1) / ((x1 - x0) * (y1 - y0));
      if (hsv.minc[q] <= mean.round() - 18) darkM[q] = 1;
    }
  }
  final labels = Int32List(n);
  final stack = Int32List(n);
  final redComps = _components(redM, w, h, labels, 1, conn8: true, stack: stack);
  final darkComps = _components(darkM, w, h, labels, 1 + redComps.length, conn8: true, stack: stack);
  final comps = [...redComps, ...darkComps];
  final lo = s * minFrac, hi = s * maxFrac;
  final blobs = <_Blob>[];
  for (var ci = 0; ci < comps.length; ci++) {
    final c = comps[ci];
    final lab = ci + 1;
    final bw = c.bw, bh = c.bh;
    final md = math.max(bw, bh);
    if (md < lo || md > hi) continue;
    if (c.area < 0.12 * bw * bh || math.min(bw, bh) < 0.12 * md) continue;
    final pad = (md * 0.3).toInt() + 2;
    final x0 = math.max(0, c.minX - pad), y0 = math.max(0, c.minY - pad);
    final x1 = math.min(w, c.maxX + 1 + pad), y1 = math.min(h, c.maxY + 1 + pad);
    var ringN = 0, ringPaper = 0;
    final ringV = <int>[];
    for (var y = y0; y < y1; y++) {
      final inRows = y >= c.minY && y <= c.maxY;
      for (var x = x0; x < x1; x++) {
        if (inRows && x >= c.minX && x <= c.maxX) continue; // bbox core
        final q = y * w + x;
        ringN++;
        if (paper[q] != 0) {
          ringPaper++;
          ringV.add(hsv.v[q]);
        }
      }
    }
    if (ringN == 0 || ringPaper / ringN < _ringPaperMin) continue;
    final hs = <int>[], ss = <int>[], vs = <int>[];
    final mask = Float64List(bw * bh);
    for (var y = c.minY; y <= c.maxY; y++) {
      for (var x = c.minX; x <= c.maxX; x++) {
        final q = y * w + x;
        if (labels[q] != lab) continue;
        mask[(y - c.minY) * bw + x - c.minX] = 255;
        hs.add(hsv.h[q]);
        ss.add(hsv.s[q]);
        vs.add(hsv.v[q]);
      }
    }
    final paperV = ringV.isEmpty ? 255.0 : _median(ringV);
    final hue = _median(hs), sat = _median(ss), val = _median(vs);
    // Ink purity: clearly dark (black) or saturated pure red.
    final isRed = (hue <= _redHueMax - 1 || hue >= 168) && sat > _redPureSMin;
    final isBlack = val < 0.5 * paperV && !isRed;
    if (!(isRed || isBlack)) continue;
    blobs.add(_Blob(c.minX, c.minY, bw, bh, c.cx, c.cy, md.toDouble(), isRed, mask));
  }
  return blobs;
}

class _Mask {
  final Float64List px;
  final int w, h;
  _Mask(this.px, this.w, this.h);
}

/// cv2.warpAffine (bilinear, constant 0 border) with forward matrix
/// [m0 m1 m2; m3 m4 m5]; the result is rounded like an 8-bit image.
_Mask _warp(Float64List src, int sw, int sh, List<double> m, int dw, int dh) {
  final det = m[0] * m[4] - m[1] * m[3];
  final i0 = m[4] / det, i1 = -m[1] / det, i3 = -m[3] / det, i4 = m[0] / det;
  final out = Float64List(dw * dh);
  for (var y = 0; y < dh; y++) {
    for (var x = 0; x < dw; x++) {
      final dx = x - m[2], dy = y - m[5];
      final sx = i0 * dx + i1 * dy, sy = i3 * dx + i4 * dy;
      final fx = sx.floor(), fy = sy.floor();
      final ax = sx - fx, ay = sy - fy;
      double at(int xx, int yy) => (xx < 0 || yy < 0 || xx >= sw || yy >= sh) ? 0 : src[yy * sw + xx];
      final v = (1 - ay) * ((1 - ax) * at(fx, fy) + ax * at(fx + 1, fy)) +
          ay * ((1 - ax) * at(fx, fy + 1) + ax * at(fx + 1, fy + 1));
      out[y * dw + x] = v.roundToDouble();
    }
  }
  return _Mask(out, dw, dh);
}

/// Rotate blob [a] (rank) so the a->b (rank->suit) vector points down.
_Mask _upright(_Blob blob, double ca, double sa) {
  final s = math.sqrt(blob.w * blob.w + blob.h * blob.h).toInt() + 4;
  final cx = blob.w / 2, cy = blob.h / 2;
  return _warp(blob.mask, blob.w, blob.h,
      [ca, -sa, s / 2 - (ca * cx - sa * cy), sa, ca, s / 2 - (sa * cx + ca * cy)], s, s);
}

/// cv2.getRotationMatrix2D about the centre + expand canvas.
_Mask _rotate(_Mask m, int deg) {
  if (deg == 0) return m;
  final s = math.sqrt(m.w * m.w + m.h * m.h).toInt() + 2;
  final a = deg * math.pi / 180;
  final al = math.cos(a), be = math.sin(a);
  final cx = m.w / 2, cy = m.h / 2;
  return _warp(m.px, m.w, m.h, [
    al,
    be,
    (1 - al) * cx - be * cy + (s - m.w) / 2,
    -be,
    al,
    be * cx + (1 - al) * cy + (s - m.h) / 2,
  ], s, s);
}

/// Tight bbox -> stretched to (bw, bh) -> blurred, zero-mean, unit-norm.
Float32List? _normalise(_Mask m, int bw, int bh) {
  var x0 = m.w, y0 = m.h, x1 = -1, y1 = -1;
  for (var y = 0; y < m.h; y++) {
    for (var x = 0; x < m.w; x++) {
      if (m.px[y * m.w + x] > 0) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) return null;
  final cw = x1 - x0 + 1, ch = y1 - y0 + 1;
  final crop = Float64List(cw * ch);
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      crop[y * cw + x] = m.px[(y0 + y) * m.w + x0 + x] / 255.0;
    }
  }
  return _finishTemplate(_resizeArea(crop, cw, ch, bw, bh), bw, bh);
}

/// Best score per label (max over that label's templates).
Map<int, double> _scores(Float32List t, List<Float32List> stacks, Iterable<int> allowed) {
  final out = <int, double>{};
  final len = t.length;
  for (final lab in allowed) {
    final st = stacks[lab];
    if (st.isEmpty) continue;
    var best = -2.0;
    for (var off = 0; off < st.length; off += len) {
      var acc = 0.0;
      for (var k = 0; k < len; k++) {
        acc += st[off + k] * t[k];
      }
      if (acc > best) best = acc;
    }
    out[lab] = best;
  }
  return out;
}

(int, double)? _best(Map<int, double> sc) {
  if (sc.isEmpty) return null;
  var bl = -1;
  var bs = -9.0;
  sc.forEach((k, v) {
    if (v > bs) {
      bs = v;
      bl = k;
    }
  });
  return (bl, bs);
}

const _redSuits = [1, 2]; // d, h
const _blackSuits = [0, 3]; // c, s
final _allRanks = List<int>.generate(13, (i) => i);

List<_Read> _readIndices(_Planes img, _Hsv hsv, GlyphTemplates t, List<_Rect> board) {
  var blobs = _findGlyphBlobs(img, hsv);
  // Ignore glyphs on or around the board cards.
  blobs = [
    for (final b in blobs)
      if (!board.any((r) => r.contains(b.cx, b.cy, 2.2))) b
  ];
  final rankCache = <int, Map<int, double>>{};
  final cands = <_Read>[];
  for (var i = 0; i < blobs.length; i++) {
    final a = blobs[i];
    for (var j = 0; j < blobs.length; j++) {
      if (i == j) continue;
      final b = blobs[j];
      final ratio = a.md / b.md;
      if (!(ratio > 0.55 && ratio < 2.2)) continue;
      final dx = b.cx - a.cx, dy = b.cy - a.cy;
      final dist = math.sqrt(dx * dx + dy * dy);
      final meanMd = (a.md + b.md) / 2;
      if (!(dist > 0.55 * meanMd && dist < 1.9 * meanMd)) continue;
      if (a.red != b.red) continue;
      final alpha = math.pi / 2 - math.atan2(dy, dx);
      final ca = math.cos(alpha), sa = math.sin(alpha);
      // Rank: classify the upright rank blob (cache per pair angle is not
      // worth it; cache by pair key instead).
      final key = i * 4096 + j;
      final rsc = rankCache[key] ??= () {
        final nt = _normalise(_upright(a, ca, sa), t.rankW, t.rankH);
        return nt == null ? <int, double>{} : _scores(nt, t.rank, _allRanks);
      }();
      final rb = _best(rsc);
      if (rb == null) continue;
      // Suit: residual rotation search on the suit alone.
      final sm0 = _upright(b, ca, sa);
      final agg = <int, double>{};
      for (final d in _suitRotSearch) {
        final nt = _normalise(_rotate(sm0, d), t.suitW, t.suitH);
        if (nt == null) continue;
        final sc = _scores(nt, t.suit, a.red ? _redSuits : _blackSuits);
        sc.forEach((k, v) {
          final vv = v - _rotPenalty * d.abs();
          if (vv > (agg[k] ?? -9)) agg[k] = vv;
        });
      }
      final sb = _best(agg);
      if (sb == null) continue;
      cands.add(_Read(makeCard(rb.$1, sb.$1), 0.5 * (rb.$2 + sb.$2), i, j, meanMd));
    }
  }
  cands.sort((x, y) => y.score.compareTo(x.score));
  final used = <int>{};
  var reads = <_Read>[];
  for (final c in cands) {
    if (used.contains(c.i) || used.contains(c.j) || c.score < _scoreMin) continue;
    used
      ..add(c.i)
      ..add(c.j);
    reads.add(c);
  }
  // Size gate: the held cards' indices are the biggest in the frame.
  if (reads.isNotEmpty) {
    final big = reads.map((r) => r.md).reduce(math.max);
    reads = [for (final r in reads) if (r.md > 0.45 * big) r];
  }
  return reads;
}

List<GlyphCard> _heroFromReads(List<_Read> reads) {
  final by = <int, List<double>>{};
  for (final r in reads) {
    (by[r.card] ??= []).add(r.score);
  }
  final agg = <GlyphCard>[
    for (final e in by.entries)
      () {
        final sc = e.value.reduce(math.max) + 0.05 * (e.value.length - 1);
        return GlyphCard(e.key, sc, e.value.length, confident: sc >= glyphConfidentScore);
      }()
  ];
  agg.sort((a, b) => b.score.compareTo(a.score));
  return agg.take(2).toList();
}

// ---------------------------------------------------------------- CNN path

List<_Blob> _heroBlobs(_Planes img, _Hsv hsv, List<_Rect> board) => [
      for (final b in _findGlyphBlobs(img, hsv))
        if (!board.any((r) => r.contains(b.cx, b.cy, 2.2))) b
    ];

/// 32x32 crop of the green channel around [b], rotated so that the unit
/// vector ([ux], [uy]) points down, plus [extraDeg] (port of the lab's
/// upright_crop + crop_from_mask: square side = 1.3 x the rotated glyph
/// bbox, bilinear, replicate border, 2..98 percentile contrast stretch).
Uint8List _cnnCrop(_Planes img, _Blob b, double ux, double uy, double extraDeg) {
  final ang = math.atan2(ux, uy) * 180 / math.pi + extraDeg;
  final t = -ang * math.pi / 180; // getRotationMatrix2D(centre, -ang)
  final al = math.cos(t), be = math.sin(t);
  final cx = b.cx, cy = b.cy;
  // Rotated bbox of the glyph pixels.
  var rx0 = double.infinity, ry0 = double.infinity, rx1 = -double.infinity, ry1 = -double.infinity;
  for (var y = 0; y < b.h; y++) {
    for (var x = 0; x < b.w; x++) {
      if (b.mask[y * b.w + x] == 0) continue;
      final dx = b.x + x - cx, dy = b.y + y - cy;
      final rx = al * dx + be * dy, ry = -be * dx + al * dy;
      if (rx < rx0) rx0 = rx;
      if (rx > rx1) rx1 = rx;
      if (ry < ry0) ry0 = ry;
      if (ry > ry1) ry1 = ry;
    }
  }
  rx1 += 1;
  ry1 += 1;
  final mx = (rx0 + rx1) / 2, my = (ry0 + ry1) / 2;
  final side = math.max(math.max(rx1 - rx0, ry1 - ry0) * 1.3, 6.0);
  const n = glyphCnnInput;
  final w = img.w, h = img.h, g = img.g;
  final raw = Float64List(n * n);
  for (var oy = 0; oy < n; oy++) {
    for (var ox = 0; ox < n; ox++) {
      // output -> rotated frame (relative to the blob centre) -> image
      final rx = (ox - n / 2) * side / n + mx, ry = (oy - n / 2) * side / n + my;
      final sx = al * rx - be * ry + cx, sy = be * rx + al * ry + cy;
      final fx = sx.floor(), fy = sy.floor();
      final ax = sx - fx, ay = sy - fy;
      int at(int xx, int yy) => g[yy.clamp(0, h - 1) * w + xx.clamp(0, w - 1)];
      final v = (1 - ay) * ((1 - ax) * at(fx, fy) + ax * at(fx + 1, fy)) +
          ay * ((1 - ax) * at(fx, fy + 1) + ax * at(fx + 1, fy + 1));
      raw[oy * n + ox] = v.roundToDouble();
    }
  }
  final sorted = Float64List.fromList(raw)..sort();
  double pct(double p) {
    final pos = p / 100 * (sorted.length - 1);
    final i = pos.floor();
    final f = pos - i;
    return i + 1 < sorted.length ? sorted[i] + f * (sorted[i + 1] - sorted[i]) : sorted[i];
  }

  final lo = pct(2), hi = pct(98);
  final k = 255 / math.max(hi - lo, 20);
  final out = Uint8List(n * n);
  for (var i = 0; i < n * n; i++) {
    out[i] = ((raw[i] - lo) * k).clamp(0, 255).toInt();
  }
  return out;
}

/// Element-wise max of the class probabilities over the TTA rotations.
Float32List _ttaProbs(GlyphCnn cnn, _Planes img, _Blob b, double ux, double uy, List<double> angles) {
  Float32List? best;
  for (final e in angles) {
    final p = cnn.probs(_cnnCrop(img, b, ux, uy, e));
    if (best == null) {
      best = p;
    } else {
      for (var i = 0; i < p.length; i++) {
        if (p[i] > best[i]) best[i] = p[i];
      }
    }
  }
  return best!;
}

List<_Read> _readIndicesCnn(_Planes img, _Hsv hsv, GlyphCnn cnn, List<_Rect> board, List<double> tta) {
  final blobs = _heroBlobs(img, hsv, board);
  final reads = <_Read>[];
  for (var i = 0; i < blobs.length; i++) {
    final a = blobs[i];
    for (var j = 0; j < blobs.length; j++) {
      if (i == j) continue;
      final b = blobs[j];
      if (a.red != b.red) continue;
      final ratio = a.md / b.md;
      if (!(ratio > 0.55 && ratio < 2.2)) continue;
      final dx = b.cx - a.cx, dy = b.cy - a.cy;
      final dist = math.sqrt(dx * dx + dy * dy);
      final meanMd = (a.md + b.md) / 2;
      if (!(dist > 0.55 * meanMd && dist < 1.9 * meanMd)) continue;
      final ux = dx / dist, uy = dy / dist;
      final pr = _ttaProbs(cnn, img, a, ux, uy, tta);
      var r = 0;
      for (var k = 1; k < 13; k++) {
        if (pr[k] > pr[r]) r = k;
      }
      // score = P(rank) * P(suit) <= P(rank): skip the suit crops (half the
      // CNN work; Watch my cards runs this several times a second).
      if (pr[r] < _cnnScoreMin) continue;
      final ps = _ttaProbs(cnn, img, b, ux, uy, tta);
      final allowed = a.red ? _redSuits : _blackSuits;
      final su = ps[glyphCnnSuit0 + allowed[0]] >= ps[glyphCnnSuit0 + allowed[1]] ? allowed[0] : allowed[1];
      final score = pr[r] * ps[glyphCnnSuit0 + su];
      if (score < _cnnScoreMin) continue;
      reads.add(_Read(makeCard(r, su), score, i, j, meanMd));
    }
  }
  reads.sort((x, y) => y.score.compareTo(x.score));
  return reads;
}

/// Top two distinct cards (each card's best read).
List<GlyphCard> _heroFromCnnReads(List<_Read> reads) {
  final votes = <int, int>{};
  for (final r in reads) {
    votes[r.card] = (votes[r.card] ?? 0) + 1;
  }
  final out = <GlyphCard>[];
  for (final r in reads) {
    if (out.any((c) => c.card == r.card)) continue;
    out.add(GlyphCard(r.card, r.score, votes[r.card]!, confident: r.score >= glyphCnnConfidentScore));
    if (out.length == 2) break;
  }
  return out;
}
