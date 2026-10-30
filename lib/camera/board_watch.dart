/// Board watcher: when to look for community cards, and agreement over
/// frames. Pure Dart; runs beside [WatchPipeline] (watch_pipeline.dart) on
/// the same frames, in the app and in tool/watch_lab.dart.
///
/// The board changes three times a hand (flop, turn, river) and is
/// otherwise still, so this is event driven, not continuous:
///
///   every frame -> throttle: one look per [BoardWatchConfig.idleIntervalMs]
///                  while the board is settled or empty, one per
///                  [activeIntervalMs] while a new street is being read
///     -> [findBoardCards] on the upright frame at full size (a far face
///        card is a 3 px paper ring: it needs full size), or, once a
///        street was read, only on the strip around it. Only the COUNT of
///        cards in the board row matters here.
///     -> a count of 3 / 4 / 5 that holds for [stableDetections] looks and
///        is more than the street already reported: a [BoardJob] with a
///        full-resolution crop of each card. The caller reads it
///        ([readBoardJob], in an isolate on the phone) and hands the
///        result to [onRead].
///     -> reads of the same street vote card by card (rank, colour, suit
///        each on their own); after [agreeReads] agreeing reads, or
///        [readsPerStreet] reads whatever they say, a [BoardRead] is
///        emitted with per-card confidence and the watcher rests until
///        the count changes.
///     -> a count of 0 for [clearedMs] after a street was read: the board
///        was swept, the hand is over ([clears]).
///
/// Cost: tens of ms for a whole-frame look (1 a second while the board
/// is unknown), a few ms for a strip look, 4 a second at most while a
/// street is being read, and 2-4 small reads per street. Frames are never
/// kept.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'board_reader.dart';
import 'watch_frame.dart';

class BoardWatchConfig {
  final int idleIntervalMs;
  final int activeIntervalMs;

  /// Once a street was read, later looks only cover the strip of the frame
  /// around it, this many card heights above and below (cheap); the whole
  /// frame again after [roiForgetMs] without a card in the strip.
  final double roiPadHeights;
  final int roiForgetMs;

  /// A card count must hold this many looks before it is read.
  final int stableDetections;

  /// Reads that must agree on every card to settle a street early.
  final int agreeReads;

  /// Reads of one street before it is reported regardless.
  final int readsPerStreet;

  /// Empty board this long after a street: the hand is over.
  final int clearedMs;

  /// Margin around a card crop, as a fraction of its width / height.
  final double padX, padY;

  /// White-balance the frame before detecting (the card crops are always
  /// balanced before reading).
  final bool detectWhiteBalance;

  final BoardReaderConfig reader;

  const BoardWatchConfig({
    this.idleIntervalMs = 1000,
    this.activeIntervalMs = 250,
    this.roiPadHeights = 3,
    this.roiForgetMs = 30000,
    this.stableDetections = 2,
    this.agreeReads = 2,
    this.readsPerStreet = 4,
    this.clearedMs = 4000,
    this.padX = 0.2,
    this.padY = 0.6,
    this.detectWhiteBalance = false,
    this.reader = const BoardReaderConfig(),
  });
}

/// One card crop to read (upright RGBA) and where it was in the frame.
class BoardCardCrop {
  final Uint8List rgba;
  final int width, height;
  final PixRect box;
  const BoardCardCrop(this.rgba, this.width, this.height, this.box);
}

/// The crops of one look at a street, left to right.
class BoardJob {
  final List<BoardCardCrop> cards;
  final int tMs;
  const BoardJob(this.cards, this.tMs);
  int get count => cards.length;
}

/// Reads every crop of [job] (pure function: fine for an isolate).
List<BoardCardRead> readBoardJob(BoardJob job, {BoardReaderConfig cfg = const BoardReaderConfig()}) =>
    [for (final c in job.cards) readBoardCard(c.rgba, c.width, c.height, box: c.box, cfg: cfg)];

/// A street as this phone read it: 3, 4 or 5 cards left to right.
class BoardRead {
  final int tMs;
  final List<BoardCardRead> cards;

  /// Reads that went into the vote, and how many agreed on every card.
  final int reads, agreed;
  const BoardRead(this.tMs, this.cards, {required this.reads, required this.agreed});
  int get count => cards.length;

  /// Mean of the cards' rank confidence.
  double get conf => cards.isEmpty ? 0 : cards.fold(0.0, (s, c) => s + c.rankConf) / cards.length;

  /// Compact tokens, e.g. "7d 9c Fh".
  String get tokens => cards.map((c) => c.token).join(' ');

  @override
  String toString() => '${(tMs / 1000).toStringAsFixed(1)}s $tokens ($agreed/$reads agree)';
}

enum BoardWatchStatus { idle, reading, settled }

class BoardWatcher {
  final BoardWatchConfig cfg;
  BoardWatcher([this.cfg = const BoardWatchConfig()]);

  /// As [WatchPipeline.rotation] / [WatchPipeline.mirror]: the caller keeps
  /// them current.
  int rotation = 0;
  bool mirror = false;

  /// Streets read (oldest first); the caller drains them.
  final List<BoardRead> reads = [];

  /// Times the board was swept after a street had been read.
  final List<int> clears = [];

  /// Looks, jobs and reader time (diagnostics).
  int looks = 0, jobs = 0, lookMs = 0;

  int _lastLookMs = -1 << 40;
  int _lastSeenMs = -1 << 40;
  PixRect? _roi;
  int _count = 0;
  int _stable = 0;
  int _countSinceMs = 0;
  int _settled = 0;
  bool _busy = false;
  final Map<int, List<List<BoardCardRead>>> _votes = {};

  /// Cards in the board row at the last look.
  int get count => _count;

  /// The street already reported (0, 3, 4 or 5).
  int get settledCount => _settled;

  BoardWatchStatus get status =>
      _busy || (_count >= 3 && _count > _settled) ? BoardWatchStatus.reading : (_settled > 0 ? BoardWatchStatus.settled : BoardWatchStatus.idle);

  /// A new hand started by other means (Next hand): forget the street.
  void reset() {
    _settled = 0;
    _votes.clear();
  }

  /// Call for every frame. Returns crops to read, or null.
  BoardJob? onFrame(WatchFrame f, int tMs) {
    final active = _count >= 3 && _count > _settled;
    if (tMs - _lastLookMs < (active ? cfg.activeIntervalMs : cfg.idleIntervalMs) - 5) return null;
    _lastLookMs = tMs;
    looks++;
    final sw = Stopwatch()..start();
    // The strip where the board was last seen, or the whole frame.
    var roi = _roi;
    if (roi != null && tMs - _lastSeenMs > cfg.roiForgetMs) roi = _roi = null;
    final look = roi ?? PixRect(0, 0, f.width, f.height);
    final (crop, cw, ch) = f.cropRgba(look);
    if (cw == 0 || ch == 0) return null;
    if (mirror) mirrorRgba(crop, cw, ch);
    final (up, uw, uh) = rotateRgba(crop, cw, ch, rotation);
    if (cfg.detectWhiteBalance) whiteBalance(up);
    final boxes = findBoardCards(up, uw, uh, shortSide: math.min(f.width, f.height), cfg: cfg.reader);
    lookMs += sw.elapsedMilliseconds;
    final n = boxes.length;
    if (n == _count) {
      _stable++;
    } else {
      _count = n;
      _stable = 1;
      _countSinceMs = tMs;
    }
    if (n > 0) _lastSeenMs = tMs;
    if (n == 0 && _settled > 0 && tMs - _countSinceMs >= cfg.clearedMs) {
      clears.add(tMs);
      _settled = 0;
      _votes.clear();
    }
    if (n < 3 || n > 5 || n <= _settled || _stable < cfg.stableDetections || _busy) return null;
    if ((_votes[n]?.length ?? 0) >= cfg.readsPerStreet) return null;
    // Upright boxes -> frame pixels, padded, cropped at full size.
    final crops = <BoardCardCrop>[];
    final frameBoxes = <PixRect>[];
    for (final b in boxes) {
      final fb = _toFrame(b, uw, uh, cw, ch, 1, look);
      frameBoxes.add(fb);
      final px = (fb.w * cfg.padX).round(), py = (fb.h * cfg.padY).round();
      final box = PixRect(math.max(0, fb.x0 - px), math.max(0, fb.y0 - py), math.min(f.width, fb.x1 + px),
          math.min(f.height, fb.y1 + py));
      final (rgba, cw2, ch2) = f.cropRgba(box);
      if (cw2 == 0 || ch2 == 0) continue;
      if (mirror) mirrorRgba(rgba, cw2, ch2);
      final (r, rw, rh) = rotateRgba(rgba, cw2, ch2, rotation);
      whiteBalance(r);
      crops.add(BoardCardCrop(r, rw, rh, box));
    }
    if (crops.length != n) return null;
    // Remember the strip: the union of the boxes, the whole frame along
    // the row, a few card heights across it.
    var x0 = f.width, y0 = f.height, x1 = 0, y1 = 0, hh = 0;
    for (final b in frameBoxes) {
      x0 = math.min(x0, b.x0);
      y0 = math.min(y0, b.y0);
      x1 = math.max(x1, b.x1);
      y1 = math.max(y1, b.y1);
      hh = math.max(hh, math.min(b.w, b.h));
    }
    final pad = cfg.roiPadHeights * hh;
    _roi = rotation == 90 || rotation == 270
        ? PixRect(math.max(0, (x0 - pad).round()), 0, math.min(f.width, (x1 + pad).round()), f.height)
        : PixRect(0, math.max(0, (y0 - pad).round()), f.width, math.min(f.height, (y1 + pad).round()));
    _busy = true;
    jobs++;
    return BoardJob(crops, tMs);
  }

  /// A box in an upright (rotated, mirrored) image of [rw] x [rh], made
  /// from a crop of [sw] x [sh] pixels taken at [origin] of the frame with
  /// an integer [step], back to frame pixels.
  PixRect _toFrame(PixRect b, int rw, int rh, int sw, int sh, int step, PixRect origin) {
    int x0, y0, x1, y1;
    switch (rotation) {
      case 90:
        (x0, x1, y0, y1) = (b.y0, b.y1, sh - b.x1, sh - b.x0);
      case 180:
        (x0, x1, y0, y1) = (sw - b.x1, sw - b.x0, sh - b.y1, sh - b.y0);
      case 270:
        (x0, x1, y0, y1) = (sw - b.y1, sw - b.y0, b.x0, b.x1);
      default:
        (x0, x1, y0, y1) = (b.x0, b.x1, b.y0, b.y1);
    }
    if (mirror) (x0, x1) = (sw - x1, sw - x0);
    return PixRect(origin.x0 + x0 * step, origin.y0 + y0 * step, origin.x0 + x1 * step, origin.y0 + y1 * step);
  }

  /// The reader finished [job]. Returns the street if this read settled it.
  BoardRead? onRead(BoardJob job, List<BoardCardRead> cards) {
    _busy = false;
    if (job.count != _count || cards.length != job.count) return null;
    final list = _votes.putIfAbsent(job.count, () => []);
    list.add(cards);
    final (merged, agreed) = voteCards(list);
    final done = (agreed >= cfg.agreeReads && list.length >= cfg.agreeReads) || list.length >= cfg.readsPerStreet;
    if (!done) return null;
    final r = BoardRead(job.tMs, merged, reads: list.length, agreed: agreed);
    reads.add(r);
    _settled = job.count;
    return r;
  }
}

/// Card-by-card vote over several reads of the same street (same phone,
/// so position i is the same card in every read). Rank, colour and suit
/// are voted separately, each weighted by its own confidence, so a frame
/// that saw the pips but not their shape still helps. Returns the merged
/// cards and how many reads agreed with the merged rank of every card.
(List<BoardCardRead>, int) voteCards(List<List<BoardCardRead>> reads) {
  if (reads.isEmpty) return (const [], 0);
  final n = reads.first.length;
  final out = <BoardCardRead>[];
  final agreeing = List<bool>.filled(reads.length, true);
  for (var i = 0; i < n; i++) {
    final rankW = <int, double>{}; // -1 = face
    final suitW = <int, double>{};
    var redW = 0.0, blackW = 0.0, total = 0.0;
    for (final r in reads) {
      final c = r[i];
      total += 1;
      final key = c.face ? -1 : c.rank;
      if (key != null) rankW[key] = (rankW[key] ?? 0) + math.max(0.05, c.rankConf);
      if (c.suit != null) suitW[c.suit!] = (suitW[c.suit!] ?? 0) + math.max(0.05, c.suitConf);
      if (c.red == true) redW += 1;
      if (c.red == false) blackW += 1;
    }
    final rankTop = _top(rankW);
    final suitTop = _top(suitW);
    final red = redW == blackW ? (redW == 0 ? null : null) : redW > blackW;
    final rankShare = rankTop == null ? 0.0 : rankW[rankTop]! / rankW.values.fold(0.0, (s, v) => s + v);
    final suitShare = suitTop == null ? 0.0 : suitW[suitTop]! / suitW.values.fold(0.0, (s, v) => s + v);
    final votesFor = rankTop == null ? 0 : reads.where((r) => (r[i].face ? -1 : r[i].rank) == rankTop).length;
    final meanRankConf = rankTop == null ? 0.0 : rankW[rankTop]! / votesFor;
    final meanSuitConf = suitTop == null
        ? 0.0
        : suitW[suitTop]! / reads.where((r) => r[i].suit == suitTop).length;
    // A suit must match the colour.
    final suit = suitTop == null || red == null || (suitTop == 1 || suitTop == 2) != red ? null : suitTop;
    for (var k = 0; k < reads.length; k++) {
      final c = reads[k][i];
      if ((c.face ? -1 : c.rank) != rankTop) agreeing[k] = false;
    }
    out.add(BoardCardRead(
      rank: rankTop == null || rankTop < 0 ? null : rankTop,
      face: rankTop == -1,
      red: red,
      suit: suit,
      rankConf: rankTop == null ? 0 : (rankShare * meanRankConf * (votesFor / total).clamp(0.5, 1.0)).clamp(0.0, 1.0),
      suitConf: suit == null ? 0 : (suitShare * meanSuitConf).clamp(0.0, 1.0),
      box: reads.last[i].box,
      pips: reads.last[i].pips,
    ));
  }
  return (out, agreeing.where((a) => a).length);
}

int? _top(Map<int, double> w) {
  int? best;
  var bw = 0.0;
  w.forEach((k, v) {
    if (v > bw) {
      bw = v;
      best = k;
    }
  });
  return best;
}
