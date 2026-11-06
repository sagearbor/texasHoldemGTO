/// Learned card-corner reader: finds every corner index (rank over suit)
/// in an upright frame and reads it, with two small networks
/// (corner_net.dart, trained in tool/camera_lab/real/corner/).
///
///   frame -> 0.4x of a 720p frame's scale (288 px short side), RGB
///         -> CornerNet: stride-8 heat map + per cell centre, box height
///            and width, "up" direction
///         -> peaks (3x3 local maxima over [CornerDetector.heatMin])
///         -> RefineNet, twice: a 48x48 window of the full-resolution
///            frame, 2 index heights wide, gives a better centre, height
///            and "up" (CornerNet's are stride-8 rough)
///         -> per peak, a 32x24 crop of the full-resolution frame turned
///            upright around the index (1.25 x its height tall)
///         -> IndexNet: rank (or "not an index") and suit
///
/// The hand-written glyph finder (glyph_reader.dart) needs a rank and a
/// suit blob that pair up under its size, colour and stroke gates; close,
/// tilted, thin, maroon or "10" indices fail those gates. This reader is
/// trained on rendered cards composited into the owner's game-night
/// stills (render.py) and does not threshold anything by hand.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'corner_net.dart';

/// Output stride of CornerNet and its input scale against a 720p frame.
const int cornerStride = 8;
const double cornerDetScale = 0.4;

/// IndexNet crop: [cornerCropH] x [cornerCropW] pixels covering
/// 1.25 x 0.95 index heights (render.py CROP_*).
const int cornerCropH = 32, cornerCropW = 24;
const double cornerSpanH = 1.25, cornerSpanW = 0.95;

/// RefineNet window: [cornerRefSize] square, [cornerRefSpan] index
/// heights wide (render.py REF_*).
const int cornerRefSize = 48;
const double cornerRefSpan = 2.0;

class CornerRead {
  /// 0..51 (lib/poker/cards.dart).
  final int card;

  /// Rank probability x suit probability (IndexNet).
  final double score;
  final double heat, rankP, suitP, notIndexP;

  /// Index centre (image pixels), rank+suit box height and width (image
  /// pixels, height along the card's "up"), and that "up" in radians
  /// (0 = upright, positive = turned clockwise).
  final double x, y, h, w, angle;
  const CornerRead(this.card, this.score,
      {required this.heat,
      required this.rankP,
      required this.suitP,
      required this.notIndexP,
      required this.x,
      required this.y,
      required this.h,
      required this.w,
      required this.angle});

  @override
  String toString() => 'card $card ${score.toStringAsFixed(2)} h ${h.toStringAsFixed(0)}';
}

class CornerDetector {
  final TinyNet det, index, refine;

  /// Heat a peak needs before its crop is read.
  final double heatMin;

  /// At most this many peaks are read (the strongest).
  final int maxPeaks;
  CornerDetector(this.det, this.index, this.refine, {this.heatMin = 0.25, this.maxPeaks = 12});

  /// Parses assets/data/corner_net.bin.
  factory CornerDetector.parse(Uint8List bytes, {double heatMin = 0.25, int maxPeaks = 12}) {
    final nets = parseCornerNets(bytes);
    return CornerDetector(nets[0], nets[1], nets[2], heatMin: heatMin, maxPeaks: maxPeaks);
  }

  /// Every index found in [rgba] (upright, [width] x [height]), best first.
  /// [frameScale]: this image's pixels per pixel of a 720p frame (the
  /// whole 1280x720 frame: 1; a crop of it resized to a 540 short side:
  /// 540 / the crop's short side in frame pixels).
  List<CornerRead> read(Uint8List rgba, int width, int height, {double frameScale = 1, Map<String, int>? timing}) {
    final sw = Stopwatch()..start();
    // CornerNet at the frame's scale and at half of it: an index bigger
    // than about a quarter of the short side (a card right at the lens)
    // reads better at half size (infer.py detect_multi).
    final cands = <_Peak>[];
    for (final (k, top) in const [(1.0, 24), (0.5, 8)]) {
      final f = cornerDetScale * k / frameScale;
      final dw = math.max(cornerStride, (width * f).round()), dh = math.max(cornerStride, (height * f).round());
      final input = resizeRgbNorm(rgba, width, height, dw, dh);
      final (o, gh, gw, cP, _) = det.run(input, dh, dw);
      final heat = Float32List(gh * gw);
      for (var i = 0; i < gh * gw; i++) {
        heat[i] = _sigmoid(o[i * cP]);
      }
      final peaks = <int>[];
      for (var y = 0; y < gh; y++) {
        for (var x = 0; x < gw; x++) {
          final v = heat[y * gw + x];
          if (v < heatMin) continue;
          var max = true;
          for (var yy = math.max(0, y - 1); yy <= math.min(gh - 1, y + 1) && max; yy++) {
            for (var xx = math.max(0, x - 1); xx <= math.min(gw - 1, x + 1); xx++) {
              if (heat[yy * gw + xx] > v) {
                max = false;
                break;
              }
            }
          }
          if (max) peaks.add(y * gw + x);
        }
      }
      peaks.sort((a, b) => heat[b].compareTo(heat[a]));
      for (final p in peaks.take(top)) {
        final gy = p ~/ gw, gx = p % gw, b = p * cP;
        cands.add(_Peak(
            (gx + _sigmoid(o[b + 1])) * cornerStride / f,
            (gy + _sigmoid(o[b + 2])) * cornerStride / f,
            math.exp(o[b + 3]) / f,
            math.exp(o[b + 4]) / f,
            math.atan2(o[b + 5], o[b + 6]),
            heat[p]));
      }
    }
    timing?['cornerDet'] = sw.elapsedMilliseconds;
    cands.sort((a, b) => b.heat.compareTo(a.heat));
    final out = <CornerRead>[];
    final crop = Float32List(cornerCropH * cornerCropW * 3);
    final win = Float32List(cornerRefSize * cornerRefSize * 3);
    for (final p in cands.take(maxPeaks)) {
      var cx = p.x, cy = p.y, h = p.h, w = p.w, ang = p.angle;
      for (var round = 0; round < 2; round++) {
        final side = cornerRefSpan * h;
        sampleRotated(rgba, width, height, cx, cy, side, side, 0, cornerRefSize, cornerRefSize, win);
        final (v, _, _, _, _) = refine.run(win, cornerRefSize, cornerRefSize);
        final nh = h * math.exp(v[2].clamp(-1.2, 1.2));
        cx += v[0] * side;
        cy += v[1] * side;
        w *= nh / h;
        h = nh;
        ang = math.atan2(v[3], v[4]);
      }
      sampleRotated(rgba, width, height, cx, cy, cornerSpanH * h, cornerSpanW * h, ang, cornerCropH, cornerCropW, crop);
      final (l, _, _, _, _) = index.run(crop, cornerCropH, cornerCropW);
      final pr = _softmax(l, 0, 14), ps = _softmax(l, 14, 4);
      var r = 0, s = 0;
      for (var i = 1; i < 13; i++) {
        if (pr[i] > pr[r]) r = i;
      }
      for (var i = 1; i < 4; i++) {
        if (ps[i] > ps[s]) s = i;
      }
      out.add(CornerRead(r * 4 + s, pr[r] * ps[s],
          heat: p.heat, rankP: pr[r], suitP: ps[s], notIndexP: pr[13], x: cx, y: cy, h: h, w: w, angle: ang));
    }
    timing?['cornerTotal'] = sw.elapsedMilliseconds;
    timing?['cornerPeaks'] = math.min(cands.length, maxPeaks);
    out.sort((a, b) => b.score.compareTo(a.score));
    // Two peaks that refined onto the same index: keep the better read.
    final kept = <CornerRead>[];
    for (final r in out) {
      if (kept.every((q) => _dist(r, q) >= 0.6 * math.max(r.h, q.h))) kept.add(r);
    }
    return kept;
  }
}

class _Peak {
  final double x, y, h, w, angle, heat;
  const _Peak(this.x, this.y, this.h, this.w, this.angle, this.heat);
}

double _sigmoid(double x) => 1 / (1 + math.exp(-x));

double _dist(CornerRead a, CornerRead b) => math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

List<double> _softmax(Float32List l, int from, int n) {
  var m = -double.infinity;
  for (var i = 0; i < n; i++) {
    m = math.max(m, l[from + i]);
  }
  final e = List<double>.generate(n, (i) => math.exp(l[from + i] - m));
  final s = e.fold<double>(0, (a, b) => a + b);
  return [for (final v in e) v / s];
}

/// [rgba] area-averaged to [dw] x [dh], RGB as (v / 127.5 - 1), HWC.
/// Shrinking: each output pixel averages the source pixels it covers
/// (fractional at the edges, like OpenCV's INTER_AREA); growing: bilinear.
Float32List resizeRgbNorm(Uint8List rgba, int w, int h, int dw, int dh) {
  final out = Float32List(dw * dh * 3);
  if (dw > w || dh > h) {
    for (var y = 0; y < dh; y++) {
      for (var x = 0; x < dw; x++) {
        final sx = (x + 0.5) * w / dw - 0.5, sy = (y + 0.5) * h / dh - 0.5;
        _bilinear(rgba, w, h, sx, sy, out, (y * dw + x) * 3);
      }
    }
  } else {
    final xs = _areaTaps(w, dw), ys = _areaTaps(h, dh);
    final row = Float64List(dw * 3);
    for (var y = 0; y < dh; y++) {
      row.fillRange(0, row.length, 0);
      final ty = ys[y];
      for (var a = 0; a < ty.$1.length; a++) {
        final sy = ty.$1[a], wy = ty.$2[a];
        final rb = sy * w * 4;
        for (var x = 0; x < dw; x++) {
          final tx = xs[x];
          var r = 0.0, g = 0.0, b = 0.0;
          for (var k = 0; k < tx.$1.length; k++) {
            final i = rb + tx.$1[k] * 4, wx = tx.$2[k];
            r += rgba[i] * wx;
            g += rgba[i + 1] * wx;
            b += rgba[i + 2] * wx;
          }
          row[x * 3] += r * wy;
          row[x * 3 + 1] += g * wy;
          row[x * 3 + 2] += b * wy;
        }
      }
      final ob = y * dw * 3;
      for (var i = 0; i < dw * 3; i++) {
        out[ob + i] = row[i] / 127.5 - 1;
      }
    }
  }
  return out;
}

/// Source pixels and weights (summing to 1) for each of [dst] outputs
/// covering [src] inputs.
List<(Int32List, Float64List)> _areaTaps(int src, int dst) {
  final scale = src / dst;
  return List.generate(dst, (d) {
    final a = d * scale, b = (d + 1) * scale;
    final i0 = a.floor(), i1 = math.min(src, b.ceil());
    final idx = <int>[], wt = <double>[];
    for (var i = i0; i < i1; i++) {
      final c = math.min(b, i + 1.0) - math.max(a, i.toDouble());
      if (c > 1e-9) {
        idx.add(i);
        wt.add(c / scale);
      }
    }
    return (Int32List.fromList(idx), Float64List.fromList(wt));
  });
}

void _bilinear(Uint8List rgba, int w, int h, double sx, double sy, Float32List out, int o, {bool raw = false}) {
  sx = sx.clamp(0, w - 1.0);
  sy = sy.clamp(0, h - 1.0);
  final x0 = sx.floor(), y0 = sy.floor();
  final x1 = math.min(w - 1, x0 + 1), y1 = math.min(h - 1, y0 + 1);
  final fx = sx - x0, fy = sy - y0;
  final a = (y0 * w + x0) * 4, b = (y0 * w + x1) * 4, c = (y1 * w + x0) * 4, d = (y1 * w + x1) * 4;
  for (var k = 0; k < 3; k++) {
    final v = (rgba[a + k] * (1 - fx) + rgba[b + k] * fx) * (1 - fy) + (rgba[c + k] * (1 - fx) + rgba[d + k] * fx) * fy;
    out[o + k] = raw ? v : v / 127.5 - 1;
  }
}

/// The [outH] x [outW] crop of the [sh] x [sw] window centred at ([cx],
/// [cy]) whose "up" is [ang] (radians, + clockwise) (render.py
/// sample_rot): n x n bilinear samples per output pixel, averaged, n =
/// clamp(ceil(step / 1.5), 1, 4) for a step of sh / outH. Writes RGB as
/// (v / 127.5 - 1), HWC, into [out].
void sampleRotated(Uint8List rgba, int w, int h, double cx, double cy, double sh, double sw, double ang, int outH,
    int outW, Float32List out) {
  final step = sh / outH;
  final n = math.min(4, math.max(1, (step / 1.5).ceil()));
  final ux = math.sin(ang), uy = -math.cos(ang);
  final rx = -uy, ry = ux;
  final oh = outH * n, ow = outW * n;
  final ax = sw / ow, ay = sh / oh;
  final px = Float32List(3);
  final inv = 1 / (n * n);
  for (var y = 0; y < outH; y++) {
    for (var x = 0; x < outW; x++) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (var j = 0; j < n; j++) {
        final v = (y * n + j + 0.5 - oh / 2) * ay;
        for (var i = 0; i < n; i++) {
          final u = (x * n + i + 0.5 - ow / 2) * ax;
          _bilinear(rgba, w, h, cx + u * rx - v * ux - 0.5, cy + u * ry - v * uy - 0.5, px, 0, raw: true);
          r += px[0];
          g += px[1];
          b += px[2];
        }
      }
      // Python rounds the average to uint8 before normalising.
      final o = (y * outW + x) * 3;
      out[o] = (r * inv).roundToDouble() / 127.5 - 1;
      out[o + 1] = (g * inv).roundToDouble() / 127.5 - 1;
      out[o + 2] = (b * inv).roundToDouble() / 127.5 - 1;
    }
  }
}
