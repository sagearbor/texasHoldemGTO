/// Watch my cards: the live frame pipeline. Pure Dart (no Flutter), so the
/// app and the desktop harness (tool/watch_lab.dart) run the same code.
///
///   every camera frame
///     -> frame-rate throttle ([WatchConfig.idleIntervalMs] while nothing
///        happens, [WatchConfig.burstIntervalMs] during a burst). Dropped
///        frames cost nothing: no pixel is touched.
///     -> [ChangeGate]: a 48-cell luma grid against a slowly adapting
///        background. A "card-like" change is a cluster of cells that got
///        clearly brighter (card faces are paper-white). Any change starts a
///        burst; only card-like changes go on.
///     -> card reader on an RGBA crop around the change (the caller runs
///        readGlyphs, in an isolate on the phone), one read at a time;
///        frames that arrive while it is busy are dropped.
///     -> [PeekVoter]: both cards must agree in [WatchConfig.minAgree]
///        frames within [WatchConfig.voteWindowMs] before anything is
///        logged. After an agreed pair the reader rests until the peek ends.
///
/// Frames are never kept: the pipeline holds only the luma grid
/// (48 x 27 numbers) and the reads.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'glyph_reader.dart';
import 'watch_diagnostics.dart';
import 'watch_frame.dart';
import 'watch_tracker.dart';

class WatchConfig {
  /// Gate interval while idle (5 per second).
  final int idleIntervalMs;

  /// Gate interval during a burst (every frame of a 15 fps stream).
  final int burstIntervalMs;

  /// A burst lasts this long after the last change.
  final int burstHoldMs;

  /// A peek ends after this long without a change, or without anything
  /// card-like (players keep moving; the cards come and go).
  final int quietMs;

  /// Cells along the long side of the luma grid.
  final int gridLong;

  /// A cell "changed" when its luma moved this much from the background.
  final int diffThreshold;

  /// A card-like cell is also at least this much above the frame mean.
  final int brightMargin;

  /// Smallest card-like cluster, in cells.
  final int minCells;

  /// More than this fraction of cells changed: lighting or the phone moved;
  /// re-learn the background instead of reading.
  final double globalChange;

  /// A cell changed this long is part of the scene now.
  final int absorbMs;

  /// Reader crop: at least this fraction of the frame's short side, so a
  /// corner index stays a sensible fraction of the crop.
  final double minCropFrac;

  /// Reader crop is shrunk (integer step) to at most this short side.
  final int readMaxShort;

  /// Glyph rotation voting in the reader (see readGlyphs). Off: frame
  /// agreement does that job at half the cost.
  final bool tta;

  final int minAgree;
  final int voteWindowMs;

  /// After this many reads in a row with no card at all, the reader backs
  /// off (doubling up to [maxBackoffMs]) until the peek ends or a card is
  /// seen: a white mug or a shirt cuff must not keep the reader busy.
  final int emptyReadsBeforeBackoff;
  final int maxBackoffMs;

  const WatchConfig({
    this.idleIntervalMs = 200,
    this.burstIntervalMs = 60,
    this.burstHoldMs = 1500,
    this.quietMs = 1000,
    this.gridLong = 48,
    this.diffThreshold = 18,
    this.brightMargin = 0,
    this.minCells = 2,
    this.globalChange = 0.5,
    this.absorbMs = 6000,
    this.minCropFrac = 0.5,
    this.readMaxShort = 720,
    this.tta = false,
    this.minAgree = 2,
    this.voteWindowMs = 2500,
    this.emptyReadsBeforeBackoff = 4,
    this.maxBackoffMs = 2000,
  });
}

// ---------------------------------------------------------------- gate

class GateResult {
  /// Cells that changed (any direction).
  final int changed;

  /// Card-like cluster in frame pixels, or null.
  final PixRect? card;

  /// Lighting / camera moved: background re-learnt.
  final bool global;
  const GateResult(this.changed, this.card, {this.global = false});
  static const none = GateResult(0, null);
}

class ChangeGate {
  final WatchConfig cfg;
  ChangeGate(this.cfg);

  int _gw = 0, _gh = 0;
  Float32List? _bg;
  Int32List? _since; // ms a cell started being "changed", -1 = not changed

  void reset() => _bg = null;

  GateResult update(WatchFrame f, int tMs) {
    final long = math.max(f.width, f.height);
    final gw = math.max(4, (cfg.gridLong * f.width / long).round());
    final gh = math.max(4, (cfg.gridLong * f.height / long).round());
    final g = f.lumaGrid(gw, gh);
    final n = gw * gh;
    var bg = _bg;
    if (bg == null || gw != _gw || gh != _gh) {
      _gw = gw;
      _gh = gh;
      _bg = Float32List(n);
      for (var i = 0; i < n; i++) {
        _bg![i] = g[i].toDouble();
      }
      _since = Int32List(n)..fillRange(0, n, -1);
      return GateResult.none;
    }
    final since = _since!;
    // Auto-exposure shifts the whole frame: compare after removing the
    // mean difference.
    var meanG = 0.0, meanB = 0.0;
    for (var i = 0; i < n; i++) {
      meanG += g[i];
      meanB += bg[i];
    }
    meanG /= n;
    meanB /= n;
    final shift = meanG - meanB;
    final bright = Uint8List(n);
    var changed = 0;
    for (var i = 0; i < n; i++) {
      final d = g[i] - bg[i] - shift;
      if (d.abs() > cfg.diffThreshold) {
        changed++;
        if (since[i] < 0) since[i] = tMs;
        if (d > 0 && g[i] >= meanG + cfg.brightMargin) bright[i] = 1;
        // Slow adaptation inside a change; absorb what stays.
        if (tMs - since[i] > cfg.absorbMs) {
          bg[i] = g[i] - shift;
          since[i] = -1;
          bright[i] = 0;
        } else {
          bg[i] += 0.02 * (g[i] - shift - bg[i]);
        }
      } else {
        since[i] = -1;
        bg[i] += 0.1 * (g[i] - shift - bg[i]);
      }
    }
    if (changed > cfg.globalChange * n) {
      for (var i = 0; i < n; i++) {
        bg[i] = g[i].toDouble();
        since[i] = -1;
      }
      return GateResult(changed, null, global: true);
    }
    // Bounding box of every 4-connected bright cluster of [minCells] or
    // more: two cards (or a card and its corner) often split in two.
    var any = false, bx0 = gw, by0 = gh, bx1 = -1, by1 = -1;
    final seen = Uint8List(n);
    final stack = <int>[];
    for (var i = 0; i < n; i++) {
      if (bright[i] == 0 || seen[i] != 0) continue;
      var size = 0, x0 = gw, y0 = gh, x1 = -1, y1 = -1;
      stack.add(i);
      seen[i] = 1;
      while (stack.isNotEmpty) {
        final q = stack.removeLast();
        final x = q % gw, y = q ~/ gw;
        size++;
        x0 = math.min(x0, x);
        x1 = math.max(x1, x);
        y0 = math.min(y0, y);
        y1 = math.max(y1, y);
        for (final nb in [if (x > 0) q - 1, if (x < gw - 1) q + 1, if (y > 0) q - gw, if (y < gh - 1) q + gw]) {
          if (bright[nb] != 0 && seen[nb] == 0) {
            seen[nb] = 1;
            stack.add(nb);
          }
        }
      }
      if (size < cfg.minCells) continue;
      any = true;
      bx0 = math.min(bx0, x0);
      by0 = math.min(by0, y0);
      bx1 = math.max(bx1, x1);
      by1 = math.max(by1, y1);
    }
    if (!any) return GateResult(changed, null);
    // Cells -> pixels. The change is often only the brightest part of a
    // card (its face), with the corner index at the edge, so pad by a third
    // of the box (at least one cell) and grow to the minimum crop.
    final cw = f.width / gw, ch = f.height / gh;
    final padX = math.max(1.0, (bx1 - bx0 + 1) / 3) * cw, padY = math.max(1.0, (by1 - by0 + 1) / 3) * ch;
    final minSide = cfg.minCropFrac * math.min(f.width, f.height);
    (int, int) span(double a, double b, int limit) {
      if (b - a < minSide) {
        final c = (a + b) / 2;
        a = c - minSide / 2;
        b = c + minSide / 2;
      }
      // Shift (not clip) a box that pokes out of the frame.
      if (a < 0) (a, b) = (0, b - a);
      if (b > limit) (a, b) = (a - (b - limit), limit.toDouble());
      return (math.max(0, a.floor()), math.min(limit, b.ceil()));
    }

    final (x0, x1) = span(bx0 * cw - padX, (bx1 + 1) * cw + padX, f.width);
    final (y0, y1) = span(by0 * ch - padY, (by1 + 1) * ch + padY, f.height);
    final r = PixRect(x0, y0, x1, y1);
    return GateResult(changed, r);
  }
}

// ---------------------------------------------------------------- voter

/// Agreement over a short window of frame reads. Each read is the set of
/// cards the reader was confident about in one frame (0, 1 or 2 cards).
/// A pair is agreed when both cards were each seen in at least [minAgree]
/// frames, at least one frame saw them together, and no third card has as
/// much support (so one misread among agreeing reads is outvoted, and two
/// competing reads produce nothing).
class PeekVoter {
  final int minAgree, windowMs;
  PeekVoter({this.minAgree = 2, this.windowMs = 2500});

  final List<(int, List<int>)> _reads = [];

  void reset() => _reads.clear();

  /// Frames that read the best pair together (diagnostics).
  int bestAgree = 0;

  /// Adds one frame's confident cards; returns the agreed pair (high card
  /// first) or null.
  List<int>? add(List<int> cards, int tMs) {
    _reads.removeWhere((r) => tMs - r.$1 > windowMs);
    if (cards.isNotEmpty) _reads.add((tMs, cards));
    final votes = <int, int>{};
    for (final (_, cs) in _reads) {
      for (final c in cs.toSet()) {
        votes[c] = (votes[c] ?? 0) + 1;
      }
    }
    final ranked = votes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    if (ranked.length < 2) {
      bestAgree = 0;
      return null;
    }
    final a = ranked[0], b = ranked[1];
    // Frames that saw both together.
    final both = _reads.where((r) => r.$2.contains(a.key) && r.$2.contains(b.key)).length;
    bestAgree = both;
    if (b.value < minAgree || both == 0) return null;
    if (ranked.length > 2 && ranked[2].value >= b.value) return null;
    return canonicalPair([a.key, b.key]);
  }
}

// ---------------------------------------------------------------- pipeline

/// A crop for the card reader.
class ReadJob {
  final Uint8List rgba;
  final int width, height, tMs;
  const ReadJob(this.rgba, this.width, this.height, this.tMs);
}

enum WatchStatus { idle, burst, reading }

class WatchPipeline {
  final WatchConfig cfg;
  final ChangeGate gate;
  final PeekVoter voter;
  WatchPipeline([this.cfg = const WatchConfig()])
      : gate = ChangeGate(cfg),
        voter = PeekVoter(minAgree: cfg.minAgree, windowMs: cfg.voteWindowMs);

  final StageCounts counts = StageCounts();

  /// Finished peeks (oldest first). The app drains these into its log.
  final List<PeekRecord> peeks = [];
  PeekRecord? _peek;

  int _lastGateMs = -1 << 40;
  int _burstUntil = -1 << 40;
  int _lastChangeMs = -1 << 40;
  int _lastCandidateMs = -1 << 40;
  bool _busy = false;
  int _emptyReads = 0;
  int _nextReadMs = -1 << 40;

  /// An agreed pair this peek: rest the reader until the peek ends.
  bool _satisfied = false;

  bool get readerBusy => _busy;
  PeekRecord? get currentPeek => _peek;

  WatchStatus status(int tMs) =>
      _busy ? WatchStatus.reading : (tMs < _burstUntil ? WatchStatus.burst : WatchStatus.idle);

  /// Call for every frame the camera delivers. Returns a crop to read, or
  /// null (dropped, nothing card-like, or the reader is busy).
  ReadJob? onFrame(WatchFrame f, int tMs) {
    counts.seen++;
    _peek?.framesSeen++;
    _closePeekIfQuiet(tMs);
    final burst = tMs < _burstUntil;
    if (tMs - _lastGateMs < (burst ? cfg.burstIntervalMs : cfg.idleIntervalMs) - 5) return null;
    final prevGate = _lastGateMs;
    _lastGateMs = tMs;
    counts.gated++;
    final g = gate.update(f, tMs);
    if (g.global) {
      voter.reset();
      return null;
    }
    if (g.changed > 0) {
      if (_peek == null) {
        counts.motionEvents++;
        _peek = PeekRecord(tMs, prevGate);
        _peek!.framesSeen = 1;
        _satisfied = false;
      } else if (_peek!.burstMs == null && burst) {
        _peek!.burstMs = tMs;
      }
      _lastChangeMs = tMs;
      _burstUntil = tMs + cfg.burstHoldMs;
    }
    final p = _peek;
    if (p != null) p.framesGated++;
    if (g.card == null) return null;
    _lastCandidateMs = tMs;
    counts.candidate++;
    p?.framesCandidate++;
    if (_busy || _satisfied || tMs < _nextReadMs) return null;
    _busy = true;
    counts.read++;
    p?.framesRead++;
    final (rgba, w, h) = f.cropRgba(g.card!, maxShort: cfg.readMaxShort);
    return ReadJob(rgba, w, h, tMs);
  }

  /// The reader finished [job]. Returns the agreed pair (high card first)
  /// when this read completed one, else null. [readMs] feeds diagnostics.
  List<int>? onRead(ReadJob job, GlyphReadResult r, {int readMs = 0}) {
    _busy = false;
    counts.readMs += readMs;
    final cards = [for (final c in r.hero) if (c.confident) c.card];
    if (r.hero.isEmpty) {
      _emptyReads++;
      if (_emptyReads >= cfg.emptyReadsBeforeBackoff) {
        final k = math.min(5, _emptyReads - cfg.emptyReadsBeforeBackoff);
        _nextReadMs = job.tMs + math.min(cfg.maxBackoffMs, 250 << k);
      }
    } else {
      _emptyReads = 0;
      _nextReadMs = -1 << 40;
    }
    final p = _peek;
    if (p != null) {
      for (final c in r.hero) {
        if (c.score > p.bestScore) p.bestScore = c.score;
      }
      if (cards.isNotEmpty) {
        if (p.framesReadable == 0) {
          p.firstReadableMs = job.tMs;
          // Readable on the very first read: they were visible before the
          // burst started.
          if (p.framesRead == 1) p.lateBurstGapMs = job.tMs - p.prevGateMs;
        }
        p.framesReadable++;
      }
    }
    final pair = voter.add(cards, job.tMs);
    if (p != null) p.agree = math.max(p.agree, voter.bestAgree);
    if (pair == null) return null;
    _satisfied = true;
    if (p != null && p.confidentMs == null) {
      p.confidentMs = job.tMs;
      p.cards = pair;
    }
    return pair;
  }

  /// What the hand tracker made of the pair this peek agreed on.
  void noteDecision(WatchDecision d) {
    final p = _peek ?? (peeks.isEmpty ? null : peeks.last);
    if (p == null) return;
    p.outcome = switch (d.action) {
      WatchAction.fill => PeekOutcome.logged,
      WatchAction.confirm => PeekOutcome.confirmed,
      WatchAction.correct => PeekOutcome.corrected,
      WatchAction.newHand => PeekOutcome.newHand,
      WatchAction.ignore => PeekOutcome.ignored,
    };
  }

  /// A new hand began (Next hand, or a new pair): old votes must not mix in.
  void resetVotes() => voter.reset();

  /// Ends the open peek (the camera stopped, or the harness reached the end).
  void flush(int tMs) {
    if (_peek != null) _finish(tMs);
  }

  void _closePeekIfQuiet(int tMs) {
    final p = _peek;
    if (p == null || _busy) return;
    final noChange = tMs - _lastChangeMs > cfg.quietMs;
    final cardGone = _lastCandidateMs >= p.startMs && tMs - _lastCandidateMs > cfg.quietMs;
    if (noChange || cardGone) _finish(tMs);
  }

  void _finish(int tMs) {
    final p = _peek!;
    _peek = null;
    _satisfied = false;
    _emptyReads = 0;
    _nextReadMs = -1 << 40;
    p.endMs = math.min(tMs, math.max(_lastCandidateMs, p.startMs) + cfg.quietMs);
    // Plain motion (no card-like change) is only counted.
    if (p.framesRead > 0) peeks.add(p);
  }
}
