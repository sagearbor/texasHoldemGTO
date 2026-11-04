// Still-image probe for the hole-card reader with Watch my cards' settings
// (white balance, warm-light gates, no TTA, no board finder), so a deck can
// be checked from photos or synthetic scenes without a video.
//
//   ~/flutter/bin/dart run tool/glyph_probe.dart DIR [--labels L.json]
//       [--cnn assets/data/glyph_cnn.bin] [--frame-frac 1] [--max-short 540]
//       [--no-wb] [--any] [-v]   (--any: readGlyphs anyDeck)
//
// DIR holds NAME_WxH.rgba files (raw 8-bit RGBA; tool/camera_lab/anydeck/
// to_rgba.py writes them from JPEG/PNG). --labels: {"NAME_WxH.rgba": "Ks 9s"}.
// Each image is shrunk (integer step) to --max-short like the Watch crop;
// --frame-frac: the image is a crop whose short side is that fraction of
// the camera frame's (glyph-size limits are relative to the frame).
//
// Testing a new deck (e.g. camera_data/dino/, photos + labels.json with
// "IMG.jpg": "Ks 9s"): convert with to_rgba.py, rename the label keys to
// the .rgba names, and score BEFORE tuning anything on that deck; keep a
// held-out split that no training or threshold ever sees.
//
// Reported per image: hero cards, and with --labels a hand is RIGHT when
// both confident hero cards are the truth, WRONG when any confident hero
// card is not in the truth, else UNREAD; plus card-level counts.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/camera/glyph_cnn.dart';
import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:felt_notes/camera/watch_frame.dart' show whiteBalance;
import 'package:felt_notes/poker/cards.dart';

void main(List<String> argv) {
  final args = [...argv];
  String? opt(String name, [String? def]) {
    final i = args.indexOf(name);
    if (i < 0) return def;
    final v = args[i + 1];
    args.removeRange(i, i + 2);
    return v;
  }

  final verbose = args.remove('-v');
  final labelsPath = opt('--labels');
  final cnnPath = opt('--cnn', 'assets/data/glyph_cnn.bin')!;
  // The image's short side over the camera frame's (a Watch crop is 0.5..1).
  final frac = double.parse(opt('--frame-frac', '1')!);
  final maxShort = int.parse(opt('--max-short', '540')!);
  final noBalance = args.remove('--no-wb');
  final anyDeck = args.remove('--any');
  final cnn = GlyphCnn.parse(File(cnnPath).readAsBytesSync());
  final labels = labelsPath == null
      ? const <String, String>{}
      : (jsonDecode(File(labelsPath).readAsStringSync()) as Map).cast<String, String>();
  final files = Directory(args.first).listSync().whereType<File>().where((f) => f.path.endsWith('.rgba')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final stage = <String, int>{};
  var right = 0, wrong = 0, unread = 0, cardsRight = 0, cardsWrong = 0, cardsTotal = 0, ms = 0, calls = 0;
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    final m = RegExp(r'_(\d+)x(\d+)\.rgba$').firstMatch(name)!;
    var w = int.parse(m[1]!), h = int.parse(m[2]!);
    var px = f.readAsBytesSync();
    final short = w < h ? w : h;
    final step = (short / maxShort).ceil();
    if (step > 1) (px, w, h) = _shrink(px, w, h, step);
    if (!noBalance) whiteBalance(px);
    final sw = Stopwatch()..start();
    final now = w < h ? w : h;
    final r = readGlyphs(px, w, h, cnn: cnn, tta: false, warmLight: true, findBoard: false, anyDeck: anyDeck,
        scaleShortSide: frac >= 1 ? null : (now / frac).round());
    ms += sw.elapsedMilliseconds;
    calls += r.timingMs['cnnCalls'] ?? 0;
    r.timingMs.forEach((k, v) => stage[k] = (stage[k] ?? 0) + v);
    final conf = [for (final c in r.hero) if (c.confident) c.card];
    var verdict = '';
    final truthS = labels[name];
    if (truthS != null) {
      final truth = parseCards(truthS).toSet();
      cardsTotal += truth.length;
      cardsRight += conf.where(truth.contains).length;
      cardsWrong += conf.where((c) => !truth.contains(c)).length;
      if (conf.any((c) => !truth.contains(c))) {
        wrong++;
        verdict = 'WRONG';
      } else if (conf.length == 2 && conf.toSet().containsAll(truth)) {
        right++;
        verdict = 'RIGHT';
      } else {
        unread++;
        verdict = 'UNREAD';
      }
      verdict = '$verdict (truth $truthS)';
    }
    stdout.writeln('$name ${w}x$h: ${r.hero.map((c) => '${cardToString(c.card)} ${c.score.toStringAsFixed(2)}'
        '${c.confident ? '' : '?'}').join(', ')}  $verdict'
        '${verbose ? '\n   reads ${r.reads.join(', ')} | ${r.timingMs}' : ''}');
  }
  stdout.writeln('--- ${files.length} images, mean ${(ms / files.length).toStringAsFixed(1)} ms, '
      'cnn calls ${(calls / files.length).toStringAsFixed(1)} / image; stages '
      '${stage.entries.map((e) => '${e.key} ${(e.value / files.length).toStringAsFixed(1)}').join(', ')}');
  if (labels.isNotEmpty) {
    stdout.writeln('hands right $right, wrong $wrong, unread $unread; '
        'cards right $cardsRight / $cardsTotal, wrong $cardsWrong');
  }
}

/// Box-average shrink by an integer step (as the Watch crop is shrunk).
(Uint8List, int, int) _shrink(Uint8List px, int w, int h, int step) {
  final dw = w ~/ step, dh = h ~/ step;
  final out = Uint8List(dw * dh * 4);
  final n = step * step;
  for (var y = 0; y < dh; y++) {
    for (var x = 0; x < dw; x++) {
      for (var c = 0; c < 4; c++) {
        var acc = 0;
        for (var yy = 0; yy < step; yy++) {
          for (var xx = 0; xx < step; xx++) {
            acc += px[((y * step + yy) * w + x * step + xx) * 4 + c];
          }
        }
        out[(y * dw + x) * 4 + c] = acc ~/ n;
      }
    }
  }
  return (out, dw, dh);
}
