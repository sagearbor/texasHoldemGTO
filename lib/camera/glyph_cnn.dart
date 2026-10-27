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

class _Layer {
  final bool conv;
  final bool flag; // conv: max-pool 2x2 after ReLU; linear: ReLU
  final int out, inp;
  final Float32List w; // conv: out*inp*9, linear: out*inp
  final Float32List b;
  _Layer(this.conv, this.flag, this.out, this.inp, this.w, this.b);
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
    for (var l = 0; l < n; l++) {
      final kind = bytes[off], flag = bytes[off + 1];
      final out = bd.getUint16(off + 2, Endian.little), inp = bd.getUint16(off + 4, Endian.little);
      off += 6;
      final per = kind == 0 ? inp * 9 : inp;
      final q = Int8List.sublistView(bytes, off, off + out * per);
      off += out * per;
      final w = Float32List(out * per), b = Float32List(out);
      for (var o = 0; o < out; o++) {
        final s = bd.getFloat32(off + 4 * o, Endian.little);
        for (var k = 0; k < per; k++) {
          w[o * per + k] = q[o * per + k] * s;
        }
      }
      off += 4 * out;
      for (var o = 0; o < out; o++) {
        b[o] = bd.getFloat32(off + 4 * o, Endian.little);
      }
      off += 4 * out;
      layers.add(_Layer(kind == 0, flag == 1, out, inp, w, b));
    }
    return GlyphCnn._(layers);
  }

  /// Logits for one 32x32 crop given as 0..255 grey values (row-major).
  Float32List logits(Uint8List crop) {
    var c = 1, h = glyphCnnInput, w = glyphCnnInput;
    var x = Float32List(h * w);
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
        final n = l.inp;
        for (var o = 0; o < l.out; o++) {
          var acc = l.b[o];
          final base = o * n;
          for (var k = 0; k < n; k++) {
            acc += l.w[base + k] * x[k];
          }
          y[o] = l.flag && acc < 0 ? 0 : acc;
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

/// 3x3 conv, zero padding 1, + bias + ReLU. x is CHW.
Float32List _conv3x3Relu(Float32List x, int c, int h, int w, _Layer l) {
  final pw = w + 2, ph = h + 2;
  final pad = Float32List(c * ph * pw);
  for (var ch = 0; ch < c; ch++) {
    for (var y = 0; y < h; y++) {
      final src = (ch * h + y) * w, dst = (ch * ph + y + 1) * pw + 1;
      for (var xx = 0; xx < w; xx++) {
        pad[dst + xx] = x[src + xx];
      }
    }
  }
  final out = Float32List(l.out * h * w);
  final acc = Float32List(h * w);
  for (var o = 0; o < l.out; o++) {
    acc.fillRange(0, acc.length, l.b[o]);
    for (var ch = 0; ch < c; ch++) {
      final wb = (o * c + ch) * 9;
      final pb = ch * ph * pw;
      for (var ky = 0; ky < 3; ky++) {
        final w0 = l.w[wb + ky * 3], w1 = l.w[wb + ky * 3 + 1], w2 = l.w[wb + ky * 3 + 2];
        for (var y = 0; y < h; y++) {
          final row = pb + (y + ky) * pw;
          final ab = y * w;
          for (var xx = 0; xx < w; xx++) {
            final r = row + xx;
            acc[ab + xx] += w0 * pad[r] + w1 * pad[r + 1] + w2 * pad[r + 2];
          }
        }
      }
    }
    final ob = o * h * w;
    for (var i = 0; i < h * w; i++) {
      final v = acc[i];
      out[ob + i] = v > 0 ? v : 0;
    }
  }
  return out;
}

Float32List _pool2(Float32List x, int c, int h, int w) {
  final oh = h ~/ 2, ow = w ~/ 2;
  final out = Float32List(c * oh * ow);
  for (var ch = 0; ch < c; ch++) {
    for (var y = 0; y < oh; y++) {
      for (var xx = 0; xx < ow; xx++) {
        final i = (ch * h + 2 * y) * w + 2 * xx;
        out[(ch * oh + y) * ow + xx] = math.max(math.max(x[i], x[i + 1]), math.max(x[i + w], x[i + w + 1]));
      }
    }
  }
  return out;
}
