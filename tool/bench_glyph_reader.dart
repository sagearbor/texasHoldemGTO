// AOT timing of the pure-Dart glyph reader (no Flutter needed).
//
//   dart compile exe tool/bench_glyph_reader.dart -o /tmp/bench
//   /tmp/bench <dir with NAME_WxH.rgba files> [--fast]   (--fast: no TTA, as Watch mode)
//
// Each .rgba file is raw 8-bit RGBA (e.g. dumped with OpenCV); the
// dimensions come from the file name.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:felt_notes/camera/glyph_cnn.dart';
import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:felt_notes/poker/cards.dart';

void main(List<String> args) {
  final cnn = GlyphCnn.parse(File('assets/data/glyph_cnn.bin').readAsBytesSync());
  // CNN alone: best-of-N per-crop time (robust to a busy machine).
  final crop = Uint8List.fromList(List.generate(32 * 32, (i) => (i * 37) % 256));
  var bestUs = 1 << 30;
  for (var rep = 0; rep < 200; rep++) {
    final sw = Stopwatch()..start();
    cnn.logits(crop);
    bestUs = math.min(bestUs, sw.elapsedMicroseconds);
  }
  stdout.writeln('CNN forward: best ${(bestUs / 1000).toStringAsFixed(2)} ms / crop');
  final files = Directory(args.first).listSync().whereType<File>().where((f) => f.path.endsWith('.rgba')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final m = RegExp(r'_(\d+)x(\d+)\.rgba$').firstMatch(f.path)!;
    final w = int.parse(m[1]!), h = int.parse(m[2]!);
    final px = f.readAsBytesSync();
    // Best of 3 runs per photo (the build machine may be busy).
    var r = readGlyphs(px, w, h, cnn: cnn, tta: !args.contains("--fast"));
    for (var k = 0; k < 2; k++) {
      final again = readGlyphs(px, w, h, cnn: cnn, tta: !args.contains("--fast"));
      if (again.timingMs['total']! < r.timingMs['total']!) r = again;
    }
    final name = f.uri.pathSegments.last;
    stdout.writeln('$name: ${r.hero.map((c) => '${cardToString(c.card)} ${c.score.toStringAsFixed(2)}').join(', ')}'
        ' | board ${r.boardCount} | ms ${r.timingMs}');
  }
}
