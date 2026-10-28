// Checks the glyph reader compiled to JavaScript (what the web app runs):
// CNN parity with the PyTorch fixture + timing, optionally a full read of
// one raw RGBA photo. Run with node (inputs are handed over as globals):
//
//   dart compile js -O2 tool/glyph_reader_js_check.dart -o /tmp/gr.js
//   node tool/glyph_reader_js_check.mjs /tmp/gr.js [photo_WxH.rgba]
// ignore_for_file: avoid_print
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:felt_notes/camera/glyph_cnn.dart';
import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:felt_notes/poker/cards.dart';

@JS('grCnn')
external JSUint8Array get _cnn;
@JS('grFixture')
external JSUint8Array get _fixture;
@JS('grPhoto')
external JSUint8Array? get _photo;
@JS('grPhotoW')
external int get _photoW;
@JS('grPhotoH')
external int get _photoH;

void main() {
  final cnn = GlyphCnn.parse(_cnn.toDart);
  final fx = _fixture.toDart;
  final bd = ByteData.sublistView(fx);
  final n = bd.getUint32(0, Endian.little), k = bd.getUint32(4, Endian.little);
  const px = 32 * 32;
  var maxDiff = 0.0;
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    final got = cnn.logits(Uint8List.sublistView(fx, 8 + i * px, 8 + (i + 1) * px));
    for (var c = 0; c < k; c++) {
      final ref = bd.getFloat32(8 + n * px + 4 * (i * k + c), Endian.little);
      final d = (got[c] - ref).abs();
      if (d > maxDiff) maxDiff = d;
    }
  }
  print('JS CNN parity: $n crops, max |logit diff| $maxDiff, '
      '${(sw.elapsedMilliseconds / n).toStringAsFixed(2)} ms / crop');
  final photo = _photo;
  if (photo != null) {
    final r = readGlyphs(photo.toDart, _photoW, _photoH, cnn: cnn);
    print('JS photo read: ${r.hero.map((c) => '${cardToString(c.card)} ${c.score.toStringAsFixed(2)}').join(', ')}'
        ' | board ${r.boardCount} | ms ${r.timingMs}');
  }
}
