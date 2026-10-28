// CI-safe tests of the pure-Dart glyph reader on synthetic images (the real
// photo evaluation lives in glyph_reader_real_photos_test.dart).
//
// Synthetic cards are white rectangles on green felt with a corner index
// painted from the font bitmaps in tool/camera_lab/glyph_templates.bin.
import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/camera/glyph_cnn.dart';
import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';

/// Raw 1-bit glyph bitmaps from the template file: (kind, label) -> bitmaps.
Map<(int, int), List<(int, int, List<bool>)>> _bitmaps() {
  final bytes = File('tool/camera_lab/glyph_templates.bin').readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  final rw = bytes[5], rh = bytes[6], sw = bytes[7], sh = bytes[8];
  final n = bd.getUint32(9, Endian.little);
  final out = <(int, int), List<(int, int, List<bool>)>>{};
  var off = 13;
  for (var k = 0; k < n; k++) {
    final kind = bytes[off], label = bytes[off + 1];
    off += 2;
    final w = kind == 0 ? rw : sw, h = kind == 0 ? rh : sh;
    final bits = [for (var i = 0; i < w * h; i++) (bytes[off + (i >> 3)] >> (7 - (i & 7))) & 1 == 1];
    off += (w * h + 7) >> 3;
    (out[(kind, label)] ??= []).add((w, h, bits));
  }
  return out;
}

class _Canvas {
  final int w, h;
  final Uint8List px;
  _Canvas(this.w, this.h) : px = Uint8List(w * h * 4) {
    rect(0, 0, w, h, 30, 110, 60); // felt
  }

  void rect(int x0, int y0, int rw, int rh, int r, int g, int b) {
    for (var y = y0; y < y0 + rh; y++) {
      for (var x = x0; x < x0 + rw; x++) {
        final i = (y * w + x) * 4;
        px[i] = r;
        px[i + 1] = g;
        px[i + 2] = b;
        px[i + 3] = 255;
      }
    }
  }

  /// Paints a bitmap scaled to (dw, dh) at (x0, y0) (nearest neighbour).
  void glyph((int, int, List<bool>) bm, int x0, int y0, int dw, int dh, (int, int, int) ink) {
    final (bw, bh, bits) = bm;
    for (var y = 0; y < dh; y++) {
      for (var x = 0; x < dw; x++) {
        if (bits[(y * bh ~/ dh) * bw + x * bw ~/ dw]) rect(x0 + x, y0 + y, 1, 1, ink.$1, ink.$2, ink.$3);
      }
    }
  }
}

void main() {
  final cnn = GlyphCnn.parse(File('assets/data/glyph_cnn.bin').readAsBytesSync());

  test('blank felt: no cards, no board', () {
    final c = _Canvas(600, 800);
    final r = readGlyphs(c.px, c.w, c.h, cnn: cnn);
    expect(r.hero, isEmpty);
    expect(r.boardCount, 0);
    expect(r.street, 'preflop');
    expect(r.confident, isFalse);
  });

  test('street mapping from the board count', () {
    String? s(int n) => GlyphReadResult(hero: const [], reads: const [], boardCount: n).street;
    expect([s(0), s(3), s(4), s(5), s(2), s(6)], ['preflop', 'flop', 'turn', 'river', null, null]);
  });

  test('reads two synthetic hole cards (CNN and templates)', () {
    final bm = _bitmaps();
    final c = _Canvas(750, 1000);
    // (rank, suit, ink): A of clubs (black), K of hearts (red).
    final cards = [(12, 0, (20, 20, 20)), (11, 2, (200, 25, 35))];
    for (var k = 0; k < cards.length; k++) {
      final (rank, suit, ink) = cards[k];
      final x0 = 80 + k * 320, y0 = 420;
      c.rect(x0, y0, 280, 400, 245, 245, 240);
      // 5th bitmap of each label = first font, no shear / rotation.
      c.glyph(bm[(0, rank)]![4], x0 + 20, y0 + 20, 40, 58, ink);
      c.glyph(bm[(1, suit)]![4], x0 + 22, y0 + 88, 36, 36, ink);
    }
    final want = {makeCard(12, 0), makeCard(11, 2)};
    final r = readGlyphs(c.px, c.w, c.h, cnn: cnn);
    expect(r.hero.map((g) => g.card).toSet(), want, reason: 'CNN read ${r.hero}');
    expect(r.confident, isTrue);
    final t = readGlyphs(c.px, c.w, c.h,
        templates: GlyphTemplates.parse(File('tool/camera_lab/glyph_templates.bin').readAsBytesSync()));
    expect(t.hero.map((g) => g.card).toSet(), want, reason: 'template read ${t.hero}');
  });

  test('isolate message entry point', () {
    final c = _Canvas(300, 400);
    final r = readGlyphsMessage(GlyphReadRequest(c.px, c.w, c.h,
        cnn: File('assets/data/glyph_cnn.bin').readAsBytesSync()));
    expect(r.hero, isEmpty);
  });
}
