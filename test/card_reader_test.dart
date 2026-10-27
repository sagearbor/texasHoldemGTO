import 'dart:math' as math;

import 'package:felt_notes/camera/card_reader.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';

import 'font_pips.dart';

// ---------------------------------------------------------------------------
// Synthetic "photo" painting. Everything is drawn in the token's own frame,
// so rotating the token rotates the whole corner index (rank + pip).
// ---------------------------------------------------------------------------

typedef Shape = bool Function(double x, double y); // x in [-1,1], y in [0,1]

/// Real pip outlines: filled suit glyphs rendered from three system fonts
/// (see test/font_pips.dart).
const pipFonts = ['arialuni', 'applesym', 'menlo'];

Shape fontShape(String font, int suit) {
  final m = fontPips[font]![suit]!;
  final n = m.length;
  return (x, y) {
    final col = ((x + 1) / 2 * n).floor().clamp(0, n - 1);
    final row = (y * n).floor().clamp(0, n - 1);
    return m[row][col] == '#';
  };
}

bool _none(double x, double y) => false;

const red = (205, 30, 45);
const black = (25, 25, 30);

/// Paints a corner index for [t]: a solid "glyph" inside the token box and
/// the [suit] pip just below it.
void paintIndex(RgbaImage img, OcrToken t, int suit,
    {(int, int, int)? ink, String font = 'arialuni', bool blankPip = false}) {
  final c = ink ?? (suit == 1 || suit == 2 ? red : black);
  final shape = blankPip ? _none : fontShape(font, suit);
  final h = t.height, w = t.width;
  final cs = w / 2;
  final pipHalf = h * 0.42;
  final pipTop = h * 1.18, pipH = h * 0.8;
  final pts = [for (final p in t.corners) p] +
      [t.local(cs - pipHalf, pipTop + pipH), t.local(cs + pipHalf, pipTop + pipH)];
  final minX = pts.map((p) => p.x).reduce(math.min).floor() - 2;
  final maxX = pts.map((p) => p.x).reduce(math.max).ceil() + 2;
  final minY = pts.map((p) => p.y).reduce(math.min).floor() - 2;
  final maxY = pts.map((p) => p.y).reduce(math.max).ceil() + 2;
  for (var py = minY; py <= maxY; py++) {
    for (var px = minX; px <= maxX; px++) {
      final d = Pt(px.toDouble(), py.toDouble()) - t.tl;
      final s = d.x * t.u.x + d.y * t.u.y;
      final tt = d.x * t.v.x + d.y * t.v.y;
      // Glyph: two thick strokes (a stand-in for the letter).
      final inGlyph = s >= w * 0.15 &&
          s <= w * 0.85 &&
          tt >= h * 0.1 &&
          tt <= h * 0.9 &&
          ((s - w * 0.15) < w * 0.25 || (tt - h * 0.1) < h * 0.2 || (h * 0.9 - tt) < h * 0.2);
      final x = (s - cs) / pipHalf, y = (tt - pipTop) / pipH;
      final inPip = y >= 0 && y <= 1 && x.abs() <= 1 && shape(x, y);
      if (inGlyph || inPip) img.set(px, py, c.$1, c.$2, c.$3);
    }
  }
}

RgbaImage felt() => RgbaImage.filled(600, 600, 240, 236, 228);

void main() {
  group('parseRankText', () {
    int? only(String s) {
      final p = parseRankText(s);
      return p != null && p.length == 1 ? p.single.$1 : null;
    }

    test('single ranks and tens', () {
      expect(only('A'), 12);
      expect(only('k'), 11);
      expect(only('Q'), 10);
      expect(only('J'), 9);
      expect(only('10'), 8);
      expect(only('1O'), 8);
      expect(only('IO'), 8);
      expect(only('7'), 5);
      expect(only('2.'), 0);
    });
    test('multi-rank tokens split', () {
      expect(parseRankText('AK')!.map((e) => e.$1), [12, 11]);
      expect(parseRankText('K10')!.map((e) => e.$1), [11, 8]);
    });
    test('words are rejected', () {
      expect(parseRankText('JACK'), isNull);
      expect(parseRankText('Bicycle'), isNull);
      expect(parseRankText('1'), isNull);
      expect(parseRankText(''), isNull);
      expect(parseRankText('12'), isNull);
    });
  });

  group('readCards without pixels', () {
    test('ranks only, colour unknown', () {
      final r = readCards([
        OcrToken.box('A', 100, 100, 130, 140),
        OcrToken.box('10', 300, 110, 350, 150),
      ]);
      expect(r.cards.map((c) => rankChars[c.rank]).toSet(), {'A', 'T'});
      expect(r.cards.every((c) => c.suit == null && c.colour == InkColour.unknown), isTrue);
    });

    test('caption words and their lines are ignored', () {
      final r = readCards([
        OcrToken.box('Q', 10, 10, 40, 50, lineText: 'Q is for Queen'),
        OcrToken.box('Hand', 10, 60, 80, 100, lineText: 'Hand 3 A K'),
        OcrToken.box('A', 90, 60, 120, 100, lineText: 'Hand 3 A K'),
        OcrToken.box('K', 200, 200, 230, 240),
        OcrToken.box('BICYCLE', 300, 300, 420, 340),
      ]);
      expect(r.cards.map((c) => c.rank), [11]);
    });

    test('tiny far-away ranks are dropped', () {
      final r = readCards([
        OcrToken.box('9', 100, 100, 130, 150),
        OcrToken.box('J', 200, 100, 230, 150),
        OcrToken.box('A', 400, 400, 408, 412), // someone else's card / print
      ]);
      expect(r.cards.map((c) => c.rank).toSet(), {7, 9});
    });

    test('split "1" "0" is merged into a ten', () {
      final r = readCards([
        OcrToken.box('1', 100, 100, 112, 140),
        OcrToken.box('0', 118, 100, 140, 140),
        OcrToken.box('5', 300, 100, 325, 140),
      ]);
      expect(r.cards.map((c) => c.rank).toSet(), {8, 3});
    });

    test('rotated tokens still parse', () {
      final r = readCards([
        OcrToken.rotated('Q', 200, 200, 30, 40, 75),
        OcrToken.rotated('8', 350, 220, 30, 40, -60),
      ]);
      expect(r.cards.map((c) => c.rank).toSet(), {10, 6});
    });

    test('nothing readable -> empty', () {
      expect(readCards([OcrToken.box('Poker night', 0, 0, 100, 20)]).isEmpty, isTrue);
      expect(readCards([]).isEmpty, isTrue);
    });
  });

  group('readCards with synthetic pixels', () {
    test('colour + suit shape for all four suits (upright)', () {
      for (final font in pipFonts) {
        for (final suit in [0, 1, 2, 3]) {
          final img = felt();
          final t = OcrToken.box('K', 200, 150, 240, 200);
          paintIndex(img, t, suit, font: font);
          final r = readCards([t], img);
          expect(r.cards, hasLength(1));
          final c = r.cards.single;
          expect(c.colour, suit == 1 || suit == 2 ? InkColour.red : InkColour.black,
              reason: '$font suit $suit colour');
          expect(c.suit, suit,
              reason: '$font suit $suit guessed ${c.suit} conf ${c.suitConfidence}');
        }
      }
    });

    test('suit shape survives rotation of the whole index', () {
      final misses = <String>[];
      for (final font in pipFonts) {
        for (final suit in [0, 1, 2, 3]) {
          for (final a in [-90.0, -35.0, 25.0, 90.0, 180.0]) {
            final img = felt();
            final t = OcrToken.rotated('9', 300, 260, 38, 48, a);
            paintIndex(img, t, suit, font: font);
            final c = readCards([t], img).cards.single;
            if (c.suit != suit) misses.add('$font ${suitChars[suit]}@$a -> ${c.suit}');
          }
        }
      }
      expect(misses, isEmpty);
    });

    test('two cards, rotated corner indices (held in hand)', () {
      for (final (a1, a2) in [(0.0, 0.0), (90.0, -20.0), (200.0, 35.0), (-140.0, 160.0)]) {
        final img = felt();
        final t1 = OcrToken.rotated('A', 180, 160, 36, 46, a1);
        final t2 = OcrToken.rotated('10', 420, 380, 52, 46, a2);
        paintIndex(img, t1, 2); // heart
        paintIndex(img, t2, 3); // spade
        final r = readCards([t1, t2, OcrToken.box('Bicycle', 20, 560, 120, 580)], img);
        expect(r.cards.map((c) => c.card).toSet(), {parseCard('Ah'), parseCard('Ts')},
            reason: 'angles $a1/$a2 -> ${r.cards}');
      }
    });

    test('dim warm lighting still separates red from black', () {
      final img = RgbaImage.filled(600, 600, 150, 128, 100);
      final t1 = OcrToken.box('7', 100, 100, 130, 140);
      final t2 = OcrToken.box('7', 300, 100, 330, 140);
      paintIndex(img, t1, 1, ink: (120, 25, 30));
      paintIndex(img, t2, 0, ink: (30, 28, 25));
      final r = readCards([t1, t2], img);
      expect(r.cards.map((c) => c.colour).toSet(), {InkColour.red, InkColour.black});
    });

    test('same card read at both corners is de-duplicated', () {
      final img = felt();
      final top = OcrToken.rotated('J', 150, 150, 30, 40, 0);
      final bottom = OcrToken.rotated('J', 330, 420, 30, 40, 180);
      final other = OcrToken.rotated('4', 450, 150, 30, 36, 0);
      paintIndex(img, top, 1);
      paintIndex(img, bottom, 1);
      paintIndex(img, other, 3);
      final r = readCards([top, bottom, other], img);
      expect(r.cards.map((c) => c.card).toSet(), {parseCard('Jd'), parseCard('4s')});
    });

    test('pocket pair never yields the same card twice', () {
      final img = felt();
      final t1 = OcrToken.box('8', 100, 100, 130, 140);
      final t2 = OcrToken.box('8', 300, 100, 330, 140);
      paintIndex(img, t1, 2);
      paintIndex(img, t2, 2); // both look like hearts
      final r = readCards([t1, t2], img);
      expect(r.cards, hasLength(2));
      expect(r.cards[0].card, isNot(r.cards[1].card));
      expect(r.cards.map((c) => c.suit).toSet(), {1, 2});
    });

    test('blank pip area -> colour from glyph, low suit confidence', () {
      final img = felt();
      final t = OcrToken.box('Q', 100, 100, 130, 140);
      paintIndex(img, t, 2, blankPip: true);
      final c = readCards([t], img).cards.single;
      expect(c.colour, InkColour.red);
      expect(c.suitConfidence, lessThan(0.5));
    });
  });
}
