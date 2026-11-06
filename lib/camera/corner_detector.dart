/// Learned card-corner reader: finds every corner index (rank over suit)
/// in an upright frame and reads it, with two small networks
/// (corner_net.dart, trained in tool/camera_lab/real/corner/).
///
///   frame -> 0.4x of a 720p frame's scale (288 px short side), RGB
///         -> CornerNet: stride-8 heat map + per cell centre, box height
///            and width, "up" direction
///         -> peaks (3x3 local maxima over [CornerDetector.heatMin]), the
///            [CornerDetector.maxPeaks] biggest read first
///            ([CornerDetector.bySize]: hole cards are the closest cards)
///         -> RefineNet, twice: a 48x48 window of the full-resolution
///            frame, 2 index heights wide, gives a better centre, height
///            and "up" (CornerNet's are stride-8 rough)
///         -> per peak, a 32x24 crop of the full-resolution frame turned
///            upright around the index (1.25 x its height tall)
///         -> IndexNet: rank (or "not an index") and suit; an index-like
///            crop that did not read is read at a quarter, half and three
///            quarter turn too ([CornerDetector.turnRetry])
///         -> next to each confident read: weaker peaks on its row and
///            windows at its size beside it, read the same way (the rest
///            of a fanned hand; [CornerDetector.rowExtra], rowProbes)
///
/// Each step is measured on the owner's game-night stills by
/// tool/card_audit.sh (Nov 7: clear cards read 87% -> 94%).
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

  /// Row search: once a corner reads at [rowSeedScore] or more, up to
  /// [rowExtra] weaker peaks (heat down to [rowHeatMin]) that sit along its
  /// row are read too: the other corners of a fanned hand are at the same
  /// height and scale, one card width or so apart, but at a busy table their
  /// heat can rank below board cards, chips and faces (Nov 7 audit). 0: off.
  final int rowExtra;
  final double rowSeedScore, rowHeatMin;

  /// Row probes: windows at the seed's own size and "up", stepped along
  /// its row at these multiples of its index height (both sides), for the
  /// best [rowProbeSeeds] seeds. RefineNet pulls a probe onto a corner
  /// within about half a window: a neighbour CornerNet missed or sized
  /// wrong (a close "10" found as its "1" alone, a card turned sideways).
  final List<double> rowProbes;
  final int rowProbeSeeds;

  /// Which peaks are read first: the biggest (CornerNet's index height)
  /// rather than the hottest. Hole cards are the closest cards to the lens,
  /// so the biggest indices in view; board cards, the button and faces
  /// across the table heat as high but are small (Nov 7 audit).
  final bool bySize;

  /// See [_readPeak].
  final bool turnRetry;

  /// Reads whose index is under this fraction of the biggest confident
  /// read's are dropped (and, ranked by size, not read at all): the hand's
  /// corners are all about one size, the board and other players' cards
  /// far smaller. 0: off (the default: at 0.45 it lost 3 right cards on
  /// the Nov 5 stills and dropped no wrong one).
  final double minRelSize;
  CornerDetector(this.det, this.index, this.refine,
      {this.heatMin = 0.25,
      this.maxPeaks = 12,
      this.rowExtra = 6,
      this.rowSeedScore = 0.9,
      this.rowHeatMin = 0.06,
      this.rowProbes = const [1.0, 1.8, 2.6],
      this.rowProbeSeeds = 2,
      this.bySize = true,
      this.turnRetry = true,
      this.minRelSize = 0});

  /// Parses assets/data/corner_net.bin (null: the default).
  factory CornerDetector.parse(Uint8List bytes,
      {int? maxPeaks,
      int? rowExtra,
      List<double>? rowProbes,
      int? rowProbeSeeds,
      bool? bySize,
      bool? turnRetry,
      double? minRelSize}) {
    final nets = parseCornerNets(bytes);
    return CornerDetector(nets[0], nets[1], nets[2],
        maxPeaks: maxPeaks ?? 12,
        rowExtra: rowExtra ?? 6,
        rowProbes: rowProbes ?? const [1.0, 1.8, 2.6],
        rowProbeSeeds: rowProbeSeeds ?? 2,
        bySize: bySize ?? true,
        turnRetry: turnRetry ?? true,
        minRelSize: minRelSize ?? 0);
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
    // Weaker peaks, for the row search.
    final spare = <_Peak>[];
    final lowHeat = rowExtra > 0 ? math.min(heatMin, rowHeatMin) : heatMin;
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
          if (v < lowHeat) continue;
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
      var taken = 0;
      for (final p in peaks) {
        final gy = p ~/ gw, gx = p % gw, b = p * cP;
        final peak = _Peak((gx + _sigmoid(o[b + 1])) * cornerStride / f, (gy + _sigmoid(o[b + 2])) * cornerStride / f,
            math.exp(o[b + 3]) / f, math.exp(o[b + 4]) / f, math.atan2(o[b + 5], o[b + 6]), heat[p]);
        if (heat[p] >= heatMin && (bySize || taken < top)) {
          cands.add(peak);
          taken++;
        } else {
          spare.add(peak);
        }
      }
    }
    timing?['cornerDet'] = sw.elapsedMilliseconds;
    final List<_Peak> chosen;
    if (bySize) {
      // Biggest first; the same index found at both scales is one candidate.
      cands.sort((a, b) => b.h.compareTo(a.h));
      chosen = [];
      for (final p in cands) {
        if (chosen.length < maxPeaks && chosen.every((q) => _distXY(q.x, q.y, p.x, p.y) >= 0.5 * math.max(q.h, p.h))) {
          chosen.add(p);
        } else {
          spare.add(p);
        }
      }
    } else {
      cands.sort((a, b) => b.heat.compareTo(a.heat));
      chosen = cands.take(maxPeaks).toList();
      spare.addAll(cands.skip(maxPeaks));
    }
    spare.sort((a, b) => b.heat.compareTo(a.heat));
    final out = <CornerRead>[];
    final crop = Float32List(cornerCropH * cornerCropW * 3);
    final win = Float32List(cornerRefSize * cornerRefSize * 3);
    // Biggest confident read so far: a peak far smaller is a card across
    // the table or on the board, not in the hand (skipped, and dropped below).
    var bigH = 0.0;
    for (final p in chosen) {
      if (bySize && minRelSize > 0 && p.h < minRelSize * bigH) continue;
      final r = _readPeak(p, rgba, width, height, win, crop);
      out.add(r);
      if (r.score >= rowSeedScore && r.h > bigH) bigH = r.h;
    }
    if (rowExtra > 0) {
      final seeds = [
        for (final r in out)
          if (r.score >= rowSeedScore) r
      ];
      final picked = <_Peak>[];
      for (final p in spare) {
        if (picked.length >= rowExtra || seeds.isEmpty) break;
        // Already read (a peak that refined onto it, or the read itself).
        if (out.any((r) => _distXY(r.x, r.y, p.x, p.y) < 0.6 * math.max(r.h, p.h))) continue;
        if (picked.any((q) => _distXY(q.x, q.y, p.x, p.y) < 0.6 * math.max(q.h, p.h))) continue;
        if (seeds.any((s) => _onRow(s, p))) picked.add(p);
      }
      for (final p in picked) {
        out.add(_readPeak(p, rgba, width, height, win, crop));
      }
      timing?['cornerRow'] = picked.length;
    }
    if (rowProbes.isNotEmpty) {
      final seeds = [
        for (final r in out)
          if (r.score >= rowSeedScore) r
      ]..sort((a, b) => b.score.compareTo(a.score));
      var probes = 0;
      for (final s in seeds.take(rowProbeSeeds)) {
        final rx = math.cos(s.angle), ry = math.sin(s.angle);
        for (final k in rowProbes) {
          for (final side in const [-1, 1]) {
            final px = s.x + side * k * s.h * rx, py = s.y + side * k * s.h * ry;
            // Up to half an index past the frame's edge: a corner right at
            // the edge (RefineNet pulls the window back in).
            final m = 0.5 * s.h;
            if (px < -m || py < -m || px >= width + m || py >= height + m) continue;
            // A confident read there already.
            if (out.any((r) => r.score >= rowSeedScore && _distXY(r.x, r.y, px, py) < 0.6 * math.max(r.h, s.h))) {
              continue;
            }
            out.add(_readPeak(_Peak(px, py, s.h, s.w, s.angle, 0), rgba, width, height, win, crop));
            probes++;
          }
        }
      }
      timing?['cornerProbes'] = probes;
    }
    if (minRelSize > 0) {
      for (final r in out) {
        if (r.score >= rowSeedScore && r.h > bigH) bigH = r.h;
      }
      out.removeWhere((r) => r.h < minRelSize * bigH);
    }
    timing?['cornerTotal'] = sw.elapsedMilliseconds;
    timing?['cornerPeaks'] = chosen.length;
    out.sort((a, b) => b.score.compareTo(a.score));
    // Two peaks that refined onto the same index: keep the better read.
    final kept = <CornerRead>[];
    for (final r in out) {
      if (kept.every((q) => _dist(r, q) >= 0.6 * math.max(r.h, q.h))) kept.add(r);
    }
    return kept;
  }

  /// [p] sits on [s]'s row: about [s]'s size (CornerNet's height is rough),
  /// within most of an index height of the line through [s] across its
  /// card, and no further than a few card widths along it.
  static bool _onRow(CornerRead s, _Peak p) {
    final ratio = p.h / s.h;
    if (ratio < 0.45 || ratio > 2.2) return false;
    final ux = math.sin(s.angle), uy = -math.cos(s.angle);
    final dx = p.x - s.x, dy = p.y - s.y;
    final across = (dx * -uy + dy * ux).abs(), up = (dx * ux + dy * uy).abs();
    return across >= 0.4 * s.h && across <= 6 * s.h && up <= 0.9 * s.h;
  }

  CornerRead _readPeak(_Peak p, Uint8List rgba, int width, int height, Float32List win, Float32List crop) {
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
    var best = _classify(rgba, width, height, p.heat, cx, cy, h, w, ang, crop);
    // RefineNet's "up" is sometimes a quarter or half turn off on a card
    // turned sideways or upside down (an upside-down 6 reads as a 9 over a
    // club): an index-like crop that did not read is read at the other
    // three turns too, and the best read is kept.
    if (turnRetry && best.score < rowSeedScore && best.notIndexP < 0.5) {
      for (final t in const [0.5, 1.0, 1.5]) {
        final r = _classify(rgba, width, height, p.heat, cx, cy, h, w, ang + t * math.pi, crop);
        if (r.score > best.score) best = r;
      }
    }
    return best;
  }

  CornerRead _classify(Uint8List rgba, int width, int height, double heat, double cx, double cy, double h, double w,
      double ang, Float32List crop) {
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
    if (ang > math.pi) ang -= 2 * math.pi;
    return CornerRead(r * 4 + s, pr[r] * ps[s],
        heat: heat, rankP: pr[r], suitP: ps[s], notIndexP: pr[13], x: cx, y: cy, h: h, w: w, angle: ang);
  }
}

class _Peak {
  final double x, y, h, w, angle, heat;
  const _Peak(this.x, this.y, this.h, this.w, this.angle, this.heat);
}

double _sigmoid(double x) => 1 / (1 + math.exp(-x));

double _distXY(double ax, double ay, double bx, double by) => math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

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
