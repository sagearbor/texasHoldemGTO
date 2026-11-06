// The Dart forward pass of the corner detector's networks
// (lib/camera/corner_net.dart) against the dequantised PyTorch nets
// (test/fixtures/corner_net_vectors.bin, written by
// tool/camera_lab/real/corner/export.py with assets/data/corner_net.bin).
import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/camera/corner_detector.dart';
import 'package:felt_notes/camera/corner_net.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final nets = parseCornerNets(File('assets/data/corner_net.bin').readAsBytesSync());

  test('both nets match the reference outputs', () {
    final b = File('test/fixtures/corner_net_vectors.bin').readAsBytesSync();
    final bd = ByteData.sublistView(b);
    expect(String.fromCharCodes(b.sublist(0, 4)), 'FNTF');
    final n = bd.getUint16(4, Endian.little);
    var off = 6;
    for (var k = 0; k < n; k++) {
      final net = b[off];
      final h = bd.getUint16(off + 1, Endian.little), w = bd.getUint16(off + 3, Endian.little), c = bd.getUint16(off + 5, Endian.little);
      off += 7;
      final x = Float32List(h * w * c);
      for (var i = 0; i < x.length; i++) {
        x[i] = bd.getFloat32(off + 4 * i, Endian.little);
      }
      off += 4 * x.length;
      final oh = bd.getUint16(off, Endian.little), ow = bd.getUint16(off + 2, Endian.little), oc = bd.getUint16(off + 4, Endian.little);
      off += 6;
      final (y, gh, gw, cP, cReal) = nets[net].run(x, h, w);
      expect((gh, gw, cReal), (oh, ow, oc), reason: 'case $k shape');
      var maxDiff = 0.0, maxRef = 0.0;
      for (var i = 0; i < oh * ow; i++) {
        for (var ch = 0; ch < oc; ch++) {
          final ref = bd.getFloat32(off + 4 * (i * oc + ch), Endian.little);
          maxDiff = (y[i * cP + ch] - ref).abs() > maxDiff ? (y[i * cP + ch] - ref).abs() : maxDiff;
          maxRef = ref.abs() > maxRef ? ref.abs() : maxRef;
        }
      }
      off += 4 * oh * ow * oc;
      expect(maxDiff, lessThan(1e-3 * (1 + maxRef)), reason: 'case $k (net $net)');
    }
  });

  test('a blank frame has no corners', () {
    const w = 320, h = 180;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      rgba[i * 4] = 40;
      rgba[i * 4 + 1] = 90;
      rgba[i * 4 + 2] = 50;
      rgba[i * 4 + 3] = 255;
    }
    final det = CornerDetector(nets[0], nets[1], nets[2]);
    final reads = det.read(rgba, w, h, frameScale: w / 1280);
    expect(reads.where((r) => r.score >= 0.5), isEmpty);
  });
}
