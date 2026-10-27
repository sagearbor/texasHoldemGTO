// The pure-Dart CNN forward pass must reproduce the exporter's PyTorch
// logits (dequantised int8 model) on 300 synthetic crops (font-rendered
// glyphs + noise, no photo pixels): test/fixtures/glyph_cnn_vectors.bin is
// written by tool/camera_lab/export_glyph_cnn.py.
import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/camera/glyph_cnn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart CNN forward pass matches PyTorch logits', () {
    final cnn = GlyphCnn.parse(File('assets/data/glyph_cnn.bin').readAsBytesSync());
    final fx = File('test/fixtures/glyph_cnn_vectors.bin').readAsBytesSync();
    final bd = ByteData.sublistView(fx);
    final n = bd.getUint32(0, Endian.little), k = bd.getUint32(4, Endian.little);
    expect(k, glyphCnnClasses);
    const px = glyphCnnInput * glyphCnnInput;
    final logitsOff = 8 + n * px;
    var maxDiff = 0.0;
    var argmaxSame = 0;
    for (var i = 0; i < n; i++) {
      final crop = Uint8List.sublistView(fx, 8 + i * px, 8 + (i + 1) * px);
      final got = cnn.logits(crop);
      var bestGot = 0, bestRef = 0;
      for (var c = 0; c < k; c++) {
        final ref = bd.getFloat32(logitsOff + 4 * (i * k + c), Endian.little);
        final d = (got[c] - ref).abs();
        if (d > maxDiff) maxDiff = d;
        if (got[c] > got[bestGot]) bestGot = c;
        if (ref > bd.getFloat32(logitsOff + 4 * (i * k + bestRef), Endian.little)) bestRef = c;
      }
      if (bestGot == bestRef) argmaxSame++;
    }
    // ignore: avoid_print
    print('CNN parity: $n crops, max |logit diff| ${maxDiff.toStringAsExponential(2)}, '
        'argmax agreement $argmaxSame/$n');
    expect(maxDiff, lessThan(1e-3));
    expect(argmaxSame, n);
  });
}
