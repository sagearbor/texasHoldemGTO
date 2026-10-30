/// One live camera frame for Watch my cards, independent of where it came
/// from (the camera plugin's image stream, a future record-while-watching
/// stream, or the desktop harness reading ffmpeg output). Pure Dart.
///
/// Two layouts cover iOS and Android:
///  * [WatchPixelFormat.yuv420]: plane 0 is luma (Y). Chroma is either one
///    interleaved CbCr plane (iOS 420v / NV12: 2 planes) or separate Cb and
///    Cr planes with a pixel stride of 1 or 2 (Android YUV_420_888: 3 planes).
///  * [WatchPixelFormat.bgra8888]: one plane, 4 bytes per pixel (iOS when
///    BGRA is requested).
///
/// Only two things are ever read from a frame: a coarse luma grid for the
/// cheap change gate ([lumaGrid]) and an RGBA copy of a small region for the
/// card reader ([cropRgba]). Frames are never stored.
library;

import 'dart:math' as math;
import 'dart:typed_data';

enum WatchPixelFormat { yuv420, bgra8888 }

class WatchPlane {
  final Uint8List bytes;
  final int bytesPerRow;

  /// 1 for luma, 1 or 2 for chroma, 4 for BGRA.
  final int bytesPerPixel;
  const WatchPlane(this.bytes, this.bytesPerRow, this.bytesPerPixel);
}

/// Integer pixel rectangle [x0, x1) x [y0, y1).
class PixRect {
  final int x0, y0, x1, y1;
  const PixRect(this.x0, this.y0, this.x1, this.y1);
  int get w => x1 - x0;
  int get h => y1 - y0;

  @override
  String toString() => '[$x0,$y0 ${w}x$h]';
}

class WatchFrame {
  final int width, height;
  final WatchPixelFormat format;
  final List<WatchPlane> planes;

  /// Luma 16..235 with the BT.709 matrix ("video range": iOS 420v at HD
  /// sizes, and the harness's ffmpeg output) rather than 0..255 BT.601
  /// (Android YUV_420_888).
  final bool videoRange;

  WatchFrame(this.width, this.height, this.format, this.planes, {this.videoRange = false})
      : assert(planes.isNotEmpty);

  /// Mean luma per cell of a [gw] x [gh] grid. Each cell is point-sampled on
  /// a 3x3 lattice, so the cost is 9 * gw * gh reads whatever the frame size.
  Uint8List lumaGrid(int gw, int gh) {
    final out = Uint8List(gw * gh);
    final p = planes[0];
    final bgra = format == WatchPixelFormat.bgra8888;
    for (var cy = 0; cy < gh; cy++) {
      for (var cx = 0; cx < gw; cx++) {
        var acc = 0;
        for (var sy = 0; sy < 3; sy++) {
          final y = ((cy + (sy + 0.5) / 3) * height / gh).floor().clamp(0, height - 1);
          final row = y * p.bytesPerRow;
          for (var sx = 0; sx < 3; sx++) {
            final x = ((cx + (sx + 0.5) / 3) * width / gw).floor().clamp(0, width - 1);
            if (bgra) {
              final i = row + x * 4;
              // Rec.601 luma from B, G, R.
              acc += (29 * p.bytes[i] + 150 * p.bytes[i + 1] + 77 * p.bytes[i + 2]) >> 8;
            } else {
              acc += p.bytes[row + x];
            }
          }
        }
        var v = acc ~/ 9;
        if (videoRange && !bgra) v = ((v - 16) * 255 ~/ 219).clamp(0, 255);
        out[cy * gw + cx] = v;
      }
    }
    return out;
  }

  /// RGBA pixels of [r] (clamped to the frame), shrunk by an integer step
  /// so the short side is at most [maxShort]. Returns (rgba, w, h).
  (Uint8List, int, int) cropRgba(PixRect r, {int maxShort = 100000}) {
    final x0 = r.x0.clamp(0, width), x1 = r.x1.clamp(0, width);
    final y0 = r.y0.clamp(0, height), y1 = r.y1.clamp(0, height);
    final short = math.min(x1 - x0, y1 - y0);
    final step = short <= maxShort ? 1 : (short / maxShort).ceil();
    final w = (x1 - x0) ~/ step, h = (y1 - y0) ~/ step;
    final out = Uint8List(w * h * 4);
    if (w <= 0 || h <= 0) return (out, 0, 0);
    if (format == WatchPixelFormat.bgra8888) {
      final p = planes[0];
      var o = 0;
      for (var j = 0; j < h; j++) {
        final row = (y0 + j * step) * p.bytesPerRow;
        for (var i = 0; i < w; i++) {
          final s = row + (x0 + i * step) * 4;
          out[o++] = p.bytes[s + 2];
          out[o++] = p.bytes[s + 1];
          out[o++] = p.bytes[s];
          out[o++] = 255;
        }
      }
      return (out, w, h);
    }
    final yp = planes[0];
    // Chroma: (plane, byte offset of Cb, byte offset of Cr, pixel stride).
    final WatchPlane cbP, crP;
    final int cbOff, crOff, cStride;
    if (planes.length == 2) {
      cbP = crP = planes[1];
      cbOff = 0;
      crOff = 1;
      cStride = 2;
    } else {
      cbP = planes[1];
      crP = planes[2];
      cbOff = crOff = 0;
      cStride = planes[1].bytesPerPixel <= 0 ? 1 : planes[1].bytesPerPixel;
    }
    var o = 0;
    for (var j = 0; j < h; j++) {
      final y = y0 + j * step;
      final yRow = y * yp.bytesPerRow;
      final cbRow = (y >> 1) * cbP.bytesPerRow, crRow = (y >> 1) * crP.bytesPerRow;
      for (var i = 0; i < w; i++) {
        final x = x0 + i * step;
        var yy = yp.bytes[yRow + x];
        final cx = (x >> 1) * cStride;
        final cb = _at(cbP.bytes, cbRow + cx + cbOff) - 128;
        final cr = _at(crP.bytes, crRow + cx + crOff) - 128;
        int r, g, b;
        if (videoRange) {
          // BT.709 limited range, fixed point (x1024).
          final c = 1192 * (yy - 16);
          r = (c + 1836 * cr) >> 10;
          g = (c - 218 * cb - 546 * cr) >> 10;
          b = (c + 2163 * cb) >> 10;
        } else {
          yy <<= 10;
          r = (yy + 1436 * cr) >> 10;
          g = (yy - 352 * cb - 731 * cr) >> 10;
          b = (yy + 1815 * cb) >> 10;
        }
        out[o++] = r.clamp(0, 255);
        out[o++] = g.clamp(0, 255);
        out[o++] = b.clamp(0, 255);
        out[o++] = 255;
      }
    }
    return (out, w, h);
  }

  // Android chroma planes can be one byte shorter than rows * stride.
  static int _at(Uint8List b, int i) => i < b.length ? b[i] : 128;
}

/// White balance on the card stock, in place. Warm tungsten light at a
/// home game tints white cards orange (HSV saturation 70-110, and red ink
/// drifts to orange), while the glyph reader treats only low-saturation
/// pixels as paper and only near-pure red as red ink.
///
/// Reference "white": the brightest [top] of the TINTED pixels (saturation
/// [sMin]..[sMax]). Under a lamp the card stock is the brightest tinted
/// thing near the hand (skin is a little darker); already-neutral pixels
/// (white window frames, a daylight scene) are left out, so a scene without
/// a cast is left alone: too few tinted bright pixels, no change. Each
/// channel is scaled so the reference becomes neutral at [target]; gains
/// are capped at [maxGain] and never darken.
void whiteBalance(Uint8List rgba,
    {int target = 225, double maxGain = 3.0, double top = 0.03, int sMin = 25, int sMax = 150}) {
  final n = rgba.length ~/ 4;
  if (n == 0) return;
  int vOf(int o) => math.max(rgba[o], math.max(rgba[o + 1], rgba[o + 2]));
  bool tinted(int o) {
    final mx = vOf(o);
    if (mx == 0) return false;
    final mn = math.min(rgba[o], math.min(rgba[o + 1], rgba[o + 2]));
    final sat = 255 * (mx - mn) ~/ mx;
    // A warm (or cool) cast: blue lowest (or highest), not a hue like green.
    return sat >= sMin && sat <= sMax && (rgba[o + 2] == mn || rgba[o + 2] == mx);
  }

  final vHist = Int32List(256);
  var tintedN = 0;
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    if (!tinted(o)) continue;
    vHist[vOf(o)]++;
    tintedN++;
  }
  if (tintedN < n * 0.01) return;
  var vThr = 255, acc = 0;
  while (vThr > 0 && acc + vHist[vThr] < tintedN * top) {
    acc += vHist[vThr--];
  }
  var sr = 0, sg = 0, sb = 0, cnt = 0;
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    if (vOf(o) < vThr || !tinted(o)) continue;
    sr += rgba[o];
    sg += rgba[o + 1];
    sb += rgba[o + 2];
    cnt++;
  }
  if (cnt == 0) return;
  final means = [sr / cnt, sg / cnt, sb / cnt];
  final luts = [
    for (final m in means)
      Uint8List.fromList(
          List.generate(256, (v) => (v * math.min(maxGain, math.max(1.0, target / math.max(m, 1)))).round().clamp(0, 255)))
  ];
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    rgba[o] = luts[0][rgba[o]];
    rgba[o + 1] = luts[1][rgba[o + 1]];
    rgba[o + 2] = luts[2][rgba[o + 2]];
  }
}

/// [rgba] ([w] x [h]) turned [deg] (0 / 90 / 180 / 270) clockwise. Returns
/// (pixels, width, height).
(Uint8List, int, int) rotateRgba(Uint8List rgba, int w, int h, int deg) {
  final d = ((deg % 360) + 360) % 360;
  if (d == 0) return (rgba, w, h);
  final px = Uint32List.view(rgba.buffer, rgba.offsetInBytes, w * h);
  final out = Uint8List(w * h * 4);
  final o = Uint32List.view(out.buffer);
  final nw = d == 180 ? w : h, nh = d == 180 ? h : w;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = px[y * w + x];
      switch (d) {
        case 90:
          o[x * nw + (h - 1 - y)] = v;
        case 180:
          o[(h - 1 - y) * nw + (w - 1 - x)] = v;
        default: // 270
          o[(w - 1 - x) * nw + y] = v;
      }
    }
  }
  return (out, nw, nh);
}

/// Clockwise turn that makes a camera frame upright for the reader, from
/// the sensor's mounting angle and how the phone is held (0 = portrait,
/// 90 = landscape with the top to the left, 180, 270). Camera-stream frames
/// (Android ImageAnalysis, iOS video data output) are never mirrored, so the
/// front lens only turns the other way.
int uprightRotation(int sensorOrientation, int deviceDegrees, {required bool front}) => front
    ? (sensorOrientation + deviceDegrees) % 360
    : (sensorOrientation - deviceDegrees + 360) % 360;
