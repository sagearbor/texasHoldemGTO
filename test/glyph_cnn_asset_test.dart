// Loads the CNN through the asset bundle exactly as the app does (catches a
// missing pubspec asset entry) and runs it. Prints the per-crop forward time.
// Note: under `flutter test --platform chrome` (Flutter 3.22) the
// rootBundle.load hangs, so this is a VM test.
import 'dart:typed_data';

import 'package:felt_notes/camera/glyph_cnn.dart';
import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CNN asset loads from the bundle and runs', () async {
    final bytes = (await rootBundle.load('assets/data/glyph_cnn.bin')).buffer.asUint8List();
    final cnn = GlyphCnn.parse(bytes);
    // ignore: avoid_print
    print('CNN asset: ${bytes.length} bytes');
    // A dark vertical bar on white: any class is fine, probabilities must be sane.
    final crop = Uint8List(32 * 32)..fillRange(0, 32 * 32, 250);
    for (var y = 4; y < 28; y++) {
      for (var x = 13; x < 19; x++) {
        crop[y * 32 + x] = 10;
      }
    }
    final sw = Stopwatch()..start();
    late Float32List p;
    for (var i = 0; i < 5; i++) {
      p = cnn.probs(crop);
    }
    final ms = sw.elapsedMilliseconds / 5;
    expect(p.length, glyphCnnClasses);
    expect(p.reduce((a, b) => a + b), closeTo(1, 1e-3));
    // ignore: avoid_print
    print('CNN forward ${ms.toStringAsFixed(2)} ms / crop');

    final img = Uint8List(200 * 150 * 4)..fillRange(0, 200 * 150 * 4, 255);
    final r = readGlyphs(img, 150, 200, cnn: cnn);
    expect(r.hero, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
