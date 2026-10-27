/// Pure-Dart forward pass of the tiny glyph CNN (no plugins, runs anywhere).
///
/// The network was trained on synthetic crops only (see
/// tool/camera_lab/real/learned/ in the lab and
/// tool/camera_lab/export_glyph_cnn.py, which folds BatchNorm and writes
/// assets/data/glyph_cnn.bin with int8 per-channel weights):
///
///   1x32x32 grey/255 -> [conv3x3+ReLU] x2 -> pool2 -> (16 ch)
///                    -> [conv3x3+ReLU] x2 -> pool2 -> (32 ch)
///                    -> [conv3x3+ReLU] x2 -> pool2 -> (64 ch, 4x4)
///                    -> FC 1024->128 + ReLU -> FC 128->18 logits
///
/// Classes: 13 ranks '23456789TJQKA' (indices 0..12, same order as
/// lib/poker/cards.dart), 4 suits 'cdhs' (13..16), background (17).
library;

import 'dart:math' as math;
import 'dart:typed_data';

const int glyphCnnInput = 32;
const int glyphCnnClasses = 18;
const int glyphCnnSuit0 = 13;

/// dart2js emulates Float32x4 with objects (slow), so the web build uses
/// scalar loops; native builds use SIMD.
const bool _isJs = identical(0, 0.0);

class _Layer {
  final bool conv;
  final bool flag; // conv: max-pool 2x2 after ReLU; linear: ReLU
  final int out, inp;

  /// Conv: [inp][3][3][out] (output channels contiguous, out % 4 == 0).
  /// Linear: [out][inp] with the input in HWC order (inp % 4 == 0).
  final Float32x4List w4;
  final Float32List w; // same weights as [w4], scalar view
  final Float32List b;
  _Layer(this.conv, this.flag, this.out, this.inp, this.w4, this.w, this.b);
}

class GlyphCnn {
  final List<_Layer> _layers;
  GlyphCnn._(this._layers);

  /// Parses assets/data/glyph_cnn.bin.
  factory GlyphCnn.parse(Uint8List bytes) {
    if (bytes.length < 6 || String.fromCharCodes(bytes.sublist(0, 4)) != 'FNCN' || bytes[4] != 1) {
      throw const FormatException('Not a glyph CNN file');
    }
    final bd = ByteData.sublistView(bytes);
    final n = bytes[5];
    var off = 6;
    final layers = <_Layer>[];
    var lastC = 1, lastHW = glyphCnnInput * glyphCnnInput;
    for (var l = 0; l < n; l++) {
      final kind = bytes[off], flag = bytes[off + 1];
      final out = bd.getUint16(off + 2, Endian.little), inp = bd.getUint16(off + 4, Endian.little);
      off += 6;
      final per = kind == 0 ? inp * 9 : inp;
      final q = Int8List.sublistView(bytes, off, off + out * per);
      off += out * per;
      final scale = Float32List(out), b = Float32List(out);
      for (var o = 0; o < out; o++) {
        scale[o] = bd.getFloat32(off + 4 * o, Endian.little);
      }
      off += 4 * out;
      for (var o = 0; o < out; o++) {
        b[o] = bd.getFloat32(off + 4 * o, Endian.little);
      }
      off += 4 * out;
      if (kind == 0) {
        if (out % 4 != 0) throw const FormatException('conv width must be a multiple of 4');
        // PyTorch [out][in][ky][kx] -> [in][ky*3+kx][out]
        final w = Float32List(out * per);
        for (var o = 0; o < out; o++) {
          for (var i = 0; i < inp; i++) {
            for (var k = 0; k < 9; k++) {
              w[(i * 9 + k) * out + o] = q[(o * inp + i) * 9 + k] * scale[o];
            }
          }
        }
        layers.add(_Layer(true, flag == 1, out, inp, Float32x4List.view(w.buffer), w, b));
        lastC = out;
        lastHW = flag == 1 ? lastHW ~/ 4 : lastHW;
      } else {
        // The first linear layer sees PyTorch's CHW flatten; our activations
        // are HWC, so permute its columns once here.
        final chw = inp == lastC * lastHW && lastHW > 1;
        final w = Float32List(out * ((inp + 3) & ~3));
        final stride = (inp + 3) & ~3;
        for (var o = 0; o < out; o++) {
          for (var k = 0; k < inp; k++) {
            final dst = chw ? (k % lastHW) * lastC + k ~/ lastHW : k;
            w[o * stride + dst] = q[o * inp + k] * scale[o];
          }
        }
        layers.add(_Layer(false, flag == 1, out, stride, Float32x4List.view(w.buffer), w, b));
        lastC = out;
        lastHW = 1;
      }
    }
    return GlyphCnn._(layers);
  }

  /// Logits for one 32x32 crop given as 0..255 grey values (row-major).
  Float32List logits(Uint8List crop) {
    var c = 1, h = glyphCnnInput, w = glyphCnnInput;
    var x = Float32List(h * w); // HWC
    for (var i = 0; i < x.length; i++) {
      x[i] = crop[i] / 255.0;
    }
    for (final l in _layers) {
      if (l.conv) {
        x = _conv3x3Relu(x, c, h, w, l);
        c = l.out;
        if (l.flag) {
          x = _pool2(x, c, h, w);
          h ~/= 2;
          w ~/= 2;
        }
      } else {
        final y = Float32List(l.out);
        if (_isJs) {
          for (var o = 0; o < l.out; o++) {
            var acc = l.b[o];
            final base = o * l.inp;
            for (var k = 0; k < x.length; k++) {
              acc += l.w[base + k] * x[k];
            }
            y[o] = l.flag && acc < 0 ? 0 : acc;
          }
          x = y;
          continue;
        }
        final n4 = l.inp >> 2;
        final xin = Float32List(l.inp)..setAll(0, x);
        final x4 = Float32x4List.view(xin.buffer);
        for (var o = 0; o < l.out; o++) {
          var acc = Float32x4.zero();
          final base = o * n4;
          for (var k = 0; k < n4; k++) {
            acc += l.w4[base + k] * x4[k];
          }
          final v = acc.x + acc.y + acc.z + acc.w + l.b[o];
          y[o] = l.flag && v < 0 ? 0 : v;
        }
        x = y;
      }
    }
    return x;
  }

  /// Softmax probabilities for one crop.
  Float32List probs(Uint8List crop) {
    final lg = logits(crop);
    var mx = -double.infinity;
    for (final v in lg) {
      if (v > mx) mx = v;
    }
    var sum = 0.0;
    final p = Float32List(lg.length);
    for (var i = 0; i < lg.length; i++) {
      final e = math.exp(lg[i] - mx);
      p[i] = e;
      sum += e;
    }
    for (var i = 0; i < p.length; i++) {
      p[i] /= sum;
    }
    return p;
  }
}

/// 3x3 conv, zero padding 1, + bias + ReLU. x is HWC (c channels).
Float32List _conv3x3Relu(Float32List x, int c, int h, int w, _Layer l) {
  final pw = w + 2, ph = h + 2;
  final pad = Float32List(ph * pw * c);
  for (var y = 0; y < h; y++) {
    pad.setRange(((y + 1) * pw + 1) * c, ((y + 1) * pw + 1 + w) * c, x, y * w * c);
  }
  if (_isJs) return _conv3x3ReluScalar(pad, c, h, w, l);
  final o4 = l.out >> 2;
  final out = Float32x4List(h * w * o4);
  final bias = Float32x4List(o4);
  for (var k = 0; k < o4; k++) {
    bias[k] = Float32x4(l.b[4 * k], l.b[4 * k + 1], l.b[4 * k + 2], l.b[4 * k + 3]);
  }
  final acc = Float32x4List(o4);
  final wv = l.w4;
  final zero = Float32x4.zero();
  for (var y = 0; y < h; y++) {
    for (var xx = 0; xx < w; xx++) {
      acc.setAll(0, bias);
      for (var ky = 0; ky < 3; ky++) {
        for (var kx = 0; kx < 3; kx++) {
          final pb = ((y + ky) * pw + xx + kx) * c;
          final tap = ky * 3 + kx;
          for (var ic = 0; ic < c; ic++) {
            final v = pad[pb + ic];
            if (v == 0) continue; // post-ReLU activations are often 0
            final vv = Float32x4.splat(v);
            final wb = (ic * 9 + tap) * o4;
            for (var k = 0; k < o4; k++) {
              acc[k] += wv[wb + k] * vv;
            }
          }
        }
      }
      final ob = (y * w + xx) * o4;
      for (var k = 0; k < o4; k++) {
        out[ob + k] = acc[k].max(zero);
      }
    }
  }
  return Float32List.view(out.buffer);
}

Float32List _conv3x3ReluScalar(Float32List pad, int c, int h, int w, _Layer l) {
  final pw = w + 2, oc = l.out;
  final out = Float32List(h * w * oc);
  final acc = Float32List(oc);
  final wt = l.w;
  for (var y = 0; y < h; y++) {
    for (var xx = 0; xx < w; xx++) {
      acc.setAll(0, l.b);
      for (var ky = 0; ky < 3; ky++) {
        for (var kx = 0; kx < 3; kx++) {
          final pb = ((y + ky) * pw + xx + kx) * c;
          final tap = ky * 3 + kx;
          for (var ic = 0; ic < c; ic++) {
            final v = pad[pb + ic];
            if (v == 0) continue;
            final wb = (ic * 9 + tap) * oc;
            for (var k = 0; k < oc; k++) {
              acc[k] += wt[wb + k] * v;
            }
          }
        }
      }
      final ob = (y * w + xx) * oc;
      for (var k = 0; k < oc; k++) {
        final v = acc[k];
        out[ob + k] = v > 0 ? v : 0;
      }
    }
  }
  return out;
}

Float32List _pool2(Float32List x, int c, int h, int w) {
  final oh = h ~/ 2, ow = w ~/ 2;
  final out = Float32List(oh * ow * c);
  for (var y = 0; y < oh; y++) {
    for (var xx = 0; xx < ow; xx++) {
      final i00 = ((2 * y) * w + 2 * xx) * c, i01 = i00 + c;
      final i10 = i00 + w * c, i11 = i10 + c;
      final o = (y * ow + xx) * c;
      for (var ch = 0; ch < c; ch++) {
        out[o + ch] = math.max(math.max(x[i00 + ch], x[i01 + ch]), math.max(x[i10 + ch], x[i11 + ch]));
      }
    }
  }
  return out;
}
