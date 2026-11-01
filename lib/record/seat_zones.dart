/// Record the table: where the other seats should land in the picture, for
/// the framing check's boxes. The phone sits at the owner's place (seat 0,
/// out of view); the others are numbered clockwise as seen from above,
/// which from the camera is left-near, across the far side, to right-near.
/// A framing aid only: the offline seat model is fitted to the photos.
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'record_session.dart' show PhonePosition;

/// One box per other player ([players] - 1 of them, seat 1 first), in
/// 0..1 coordinates of the picture. Far seats are smaller (perspective).
List<Rect> seatZones(int players, PhonePosition position) {
  final others = players - 1;
  if (others < 1) return const [];
  // Phone at an end of an oval table: the arc is tall (the far end is far
  // away). At the middle of a long side: wide and flat.
  final side = position == PhonePosition.side;
  final cx = 0.5, cy = side ? 0.66 : 0.64;
  final rx = side ? 0.46 : 0.42, ry = side ? 0.34 : 0.40;
  // From a little below the left edge of the oval, over the far side, to
  // the same point on the right.
  const from = math.pi + 0.30, to = -0.30;
  return [
    for (var k = 0; k < others; k++)
      () {
        final f = others == 1 ? 0.5 : k / (others - 1);
        final a = from + (to - from) * f;
        final x = cx + rx * math.cos(a);
        final y = cy - ry * math.sin(a);
        // 0.09 of the width at the far side up to 0.2 at the near corners.
        final s = 0.09 + 0.11 * ((y - (cy - ry)) / (2 * ry)).clamp(0.0, 1.0) * 1.6;
        final w = s.clamp(0.08, 0.22), h = (s * 1.25).clamp(0.10, 0.28);
        final l = (x - w / 2).clamp(0.0, 1.0 - w), t = (y - h / 2).clamp(0.0, 1.0 - h);
        return Rect.fromLTWH(l, t, w, h);
      }(),
  ];
}
