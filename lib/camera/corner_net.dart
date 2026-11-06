/// Pure-Dart forward pass for the small corner-detector networks (no
/// plugins, runs anywhere), the way glyph_cnn.dart runs the glyph CNN.
///
/// assets/data/corner_net.bin is written by
/// tool/camera_lab/real/corner/export.py and holds two networks:
///   0  CornerNet: upright frame (RGB in -1..1) -> stride-8 grid of
///      [heat, dx, dy, log h, log w, sin, cos] (see corner_detector.dart)
///   1  IndexNet: 32x24 index-aligned crop -> 14 rank logits (13 ranks,
///      then "not an index") and 4 suit logits
///
/// Ops: 3x3 / 1x1 convolution (plain or depthwise, any stride and
/// dilation, zero padding d * (k ~/ 2)), 2x2 max-pool, fully connected.
/// BatchNorm is folded in; weights are int8 per output channel,
/// dequantised at load. Activations are HWC with the channel count padded
/// to a multiple of 4 so every inner loop runs on Float32x4 lanes.
library;

import 'dart:typed_data';

/// dart2js emulates Float32x4 with objects (slow): the web build would
/// want scalar loops; Watch my cards only runs on phones.
int _pad4(int c) => (c + 3) & ~3;

abstract class _Op {}

class _Conv extends _Op {
  final int k, stride, dil, cin, cout, cinP, coutP;
  final bool depthwise, relu;

  /// Plain: [ky][kx][cinP][coutP/4]; depthwise: [ky][kx][coutP/4].
  final Float32x4List w;
  final Float32x4List b;
  _Conv(this.k, this.stride, this.dil, this.depthwise, this.relu, this.cin, this.cout, this.w, this.b)
      : cinP = _pad4(cin),
        coutP = _pad4(cout);
}

class _Pool extends _Op {}

class _Linear extends _Op {
  final bool relu;
  final int inp, out, outP;

  /// [inp][outP/4]: input element i's weights for every output.
  final Float32x4List w;
  final Float32x4List b;

  /// Shape of the activation it flattens (HWC, channels padded) and its
  /// real channel count: the file's columns are HWC over real channels.
  final int flatH, flatW;
  _Linear(this.relu, this.inp, this.out, this.flatH, this.flatW, this.w, this.b) : outP = _pad4(out);
}

/// One network: a list of ops.
class TinyNet {
  final List<_Op> _ops;
  final int inputChannels;
  TinyNet._(this._ops, this.inputChannels);

  /// Runs the net on [x] (HWC, [inputChannels] channels, unpadded).
  /// Returns the output as (data HWC with channels padded to 4, h, w,
  /// channels padded, real channels).
  (Float32List, int, int, int, int) run(Float32List x, int h, int w) {
    final c0 = inputChannels, c0P = _pad4(c0);
    var cur = Float32List(h * w * c0P);
    for (var i = 0, j = 0; i < h * w; i++, j += c0P) {
      for (var c = 0; c < c0; c++) {
        cur[j + c] = x[i * c0 + c];
      }
    }
    var cP = c0P, cReal = c0;
    for (final op in _ops) {
      if (op is _Conv) {
        final pad = op.dil * (op.k ~/ 2);
        final oh = (h + 2 * pad - op.dil * (op.k - 1) - 1) ~/ op.stride + 1;
        final ow = (w + 2 * pad - op.dil * (op.k - 1) - 1) ~/ op.stride + 1;
        cur = op.depthwise ? _depthwise(op, cur, h, w, oh, ow, pad) : _conv(op, cur, h, w, oh, ow, pad);
        h = oh;
        w = ow;
        cP = op.coutP;
        cReal = op.cout;
      } else if (op is _Pool) {
        final oh = h ~/ 2, ow = w ~/ 2;
        final out = Float32List(oh * ow * cP);
        final o4 = Float32x4List.view(out.buffer);
        final i4 = Float32x4List.view(cur.buffer);
        final c4 = cP >> 2;
        for (var y = 0; y < oh; y++) {
          for (var xx = 0; xx < ow; xx++) {
            final a = ((2 * y) * w + 2 * xx) * c4, b = a + c4, c = a + w * c4, d = c + c4;
            final o = (y * ow + xx) * c4;
            for (var q = 0; q < c4; q++) {
              o4[o + q] = i4[a + q].max(i4[b + q]).max(i4[c + q].max(i4[d + q]));
            }
          }
        }
        cur = out;
        h = oh;
        w = ow;
      } else if (op is _Linear) {
        // Gather the real channels in HWC order (the file's column order).
        final n = op.inp;
        final v = Float32List(n);
        if (cP == cReal) {
          v.setRange(0, n, cur);
        } else {
          var k = 0;
          for (var i = 0; i < h * w; i++) {
            for (var c = 0; c < cReal; c++) {
              v[k++] = cur[i * cP + c];
            }
          }
        }
        final o4n = op.outP >> 2;
        final acc = Float32x4List(o4n)..setAll(0, op.b);
        for (var i = 0; i < n; i++) {
          final s = Float32x4.splat(v[i]);
          final base = i * o4n;
          for (var q = 0; q < o4n; q++) {
            acc[q] += op.w[base + q] * s;
          }
        }
        if (op.relu) {
          final z = Float32x4.zero();
          for (var q = 0; q < o4n; q++) {
            acc[q] = acc[q].max(z);
          }
        }
        cur = Float32List.view(acc.buffer);
        h = 1;
        w = 1;
        cP = op.outP;
        cReal = op.out;
      }
    }
    return (cur, h, w, cP, cReal);
  }

  static Float32List _conv(_Conv op, Float32List x, int h, int w, int oh, int ow, int pad) {
    final cinP = op.cinP, o4n = op.coutP >> 2, k = op.k, d = op.dil, s = op.stride;
    final out = Float32x4List(oh * ow * o4n);
    final wt = op.w, b = op.b;
    final acc = Float32x4List(o4n);
    final z = Float32x4.zero();
    for (var oy = 0; oy < oh; oy++) {
      for (var ox = 0; ox < ow; ox++) {
        acc.setAll(0, b);
        for (var ky = 0; ky < k; ky++) {
          final iy = oy * s - pad + ky * d;
          if (iy < 0 || iy >= h) continue;
          for (var kx = 0; kx < k; kx++) {
            final ix = ox * s - pad + kx * d;
            if (ix < 0 || ix >= w) continue;
            final ib = (iy * w + ix) * cinP;
            var wb = ((ky * k + kx) * cinP) * o4n;
            for (var ic = 0; ic < cinP; ic++, wb += o4n) {
              final xv = x[ib + ic];
              if (xv == 0) continue;
              final sv = Float32x4.splat(xv);
              for (var q = 0; q < o4n; q++) {
                acc[q] += wt[wb + q] * sv;
              }
            }
          }
        }
        final ob = (oy * ow + ox) * o4n;
        if (op.relu) {
          for (var q = 0; q < o4n; q++) {
            out[ob + q] = acc[q].max(z);
          }
        } else {
          for (var q = 0; q < o4n; q++) {
            out[ob + q] = acc[q];
          }
        }
      }
    }
    return Float32List.view(out.buffer);
  }

  static Float32List _depthwise(_Conv op, Float32List x, int h, int w, int oh, int ow, int pad) {
    final c4 = op.coutP >> 2, k = op.k, d = op.dil, s = op.stride;
    final x4 = Float32x4List.view(x.buffer, x.offsetInBytes, x.length >> 2);
    final out = Float32x4List(oh * ow * c4);
    final wt = op.w, b = op.b;
    final z = Float32x4.zero();
    for (var oy = 0; oy < oh; oy++) {
      for (var ox = 0; ox < ow; ox++) {
        final ob = (oy * ow + ox) * c4;
        for (var q = 0; q < c4; q++) {
          var acc = b[q];
          for (var ky = 0; ky < k; ky++) {
            final iy = oy * s - pad + ky * d;
            if (iy < 0 || iy >= h) continue;
            for (var kx = 0; kx < k; kx++) {
              final ix = ox * s - pad + kx * d;
              if (ix < 0 || ix >= w) continue;
              acc += x4[(iy * w + ix) * c4 + q] * wt[(ky * k + kx) * c4 + q];
            }
          }
          out[ob + q] = op.relu ? acc.max(z) : acc;
        }
      }
    }
    return Float32List.view(out.buffer);
  }
}

/// Parses assets/data/corner_net.bin: [CornerNet, IndexNet].
List<TinyNet> parseCornerNets(Uint8List bytes) {
  if (bytes.length < 6 || String.fromCharCodes(bytes.sublist(0, 4)) != 'FNTN' || bytes[4] != 1) {
    throw const FormatException('Not a corner net file');
  }
  final bd = ByteData.sublistView(bytes);
  var off = 6;
  final nets = <TinyNet>[];
  for (var n = 0; n < bytes[5]; n++) {
    final nOps = bd.getUint16(off, Endian.little), cin = bd.getUint16(off + 2, Endian.little);
    off += 4;
    final ops = <_Op>[];
    for (var i = 0; i < nOps; i++) {
      final type = bytes[off++];
      if (type == 1) {
        ops.add(_Pool());
        continue;
      }
      if (type == 0) {
        final k = bytes[off], s = bytes[off + 1], d = bytes[off + 2], dw = bytes[off + 3] == 1, relu = bytes[off + 4] == 1;
        final ci = bd.getUint16(off + 5, Endian.little), co = bd.getUint16(off + 7, Endian.little);
        off += 9;
        final per = (dw ? 1 : ci) * k * k;
        final q = Int8List.sublistView(bytes, off, off + co * per);
        off += co * per;
        final scale = _f32s(bd, off, co);
        off += 4 * co;
        final bias = _f32s(bd, off, co);
        off += 4 * co;
        final ciP = _pad4(ci), coP = _pad4(co), o4 = coP >> 2;
        final w = Float32List(dw ? k * k * coP : k * k * ciP * coP);
        for (var o = 0; o < co; o++) {
          for (var c = 0; c < (dw ? 1 : ci); c++) {
            for (var t = 0; t < k * k; t++) {
              final v = q[(o * (dw ? 1 : ci) + c) * k * k + t] * scale[o];
              w[dw ? t * coP + o : (t * ciP + c) * coP + o] = v;
            }
          }
        }
        final b = Float32List(coP)..setRange(0, co, bias);
        ops.add(_Conv(k, s, d, dw, relu, ci, co, Float32x4List.view(w.buffer), Float32x4List.view(b.buffer)));
        assert(o4 > 0);
        continue;
      }
      if (type == 2) {
        final relu = bytes[off] == 1;
        final inp = bd.getUint16(off + 1, Endian.little), out = bd.getUint16(off + 3, Endian.little);
        final fh = bd.getUint16(off + 5, Endian.little), fw = bd.getUint16(off + 7, Endian.little);
        off += 9;
        final q = Int8List.sublistView(bytes, off, off + out * inp);
        off += out * inp;
        final scale = _f32s(bd, off, out);
        off += 4 * out;
        final bias = _f32s(bd, off, out);
        off += 4 * out;
        final oP = _pad4(out);
        final w = Float32List(inp * oP);
        for (var o = 0; o < out; o++) {
          for (var i2 = 0; i2 < inp; i2++) {
            w[i2 * oP + o] = q[o * inp + i2] * scale[o];
          }
        }
        final b = Float32List(oP)..setRange(0, out, bias);
        ops.add(_Linear(relu, inp, out, fh, fw, Float32x4List.view(w.buffer), Float32x4List.view(b.buffer)));
        continue;
      }
      throw FormatException('Unknown op $type');
    }
    nets.add(TinyNet._(ops, cin));
  }
  return nets;
}

Float32List _f32s(ByteData bd, int off, int n) {
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getFloat32(off + 4 * i, Endian.little);
  }
  return out;
}
