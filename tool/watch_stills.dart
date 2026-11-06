// Offline evaluator for Watch my cards over a Watch recording's stills
// (Settings > record while watching: session.jsonl + s01/*.jpg, ~1 still
// a second). Runs the app's own pipeline (gate, reader, board guards,
// voter, Omaha path) and hand tracker over the stills in order.
//
//   ~/flutter/bin/dart run tool/watch_stills.dart camera_data/record/<id> \
//       [--labels L.json] [--scale 0.35] [--flat 0.85] [--dump reads.jsonl] [-v]
//
// The stills are ~1 s apart, a phone reads ~3-4 frames a second. Time is
// compressed by --scale (0.35: one still every ~350 ms of pipeline clock)
// so consecutive stills look like consecutive reads to the pipeline's
// timers (vote window, cards-gone, quiet). Each still is read at once
// (no frames are dropped while the reader is busy). Times printed are the
// recording's own seconds; the hand tracker gets the recording's own
// clock too (its windows are wall-clock times in the app).
//
// Stills are decoded by ffmpeg in sensor orientation; the JPEG's EXIF
// orientation is the turn the app applied, used as the pipeline rotation
// (portrait: 90; the phone propped landscape: none).
//
// --labels (default <rec>/labels.json): hands as written by hand from the
// stills: [{"hand": 1, "t0": s, "t1": s, "game": "omaha", "ncards": 4,
// "cards": "Qd Jh Kd ??"}, ...]; "??" an unreadable card, "Q?" / "?d" a
// partly readable one. Per hand: the cards the tracker ended with for
// decisions inside [t0 - 2, t1 + 2]: right (all reported cards real, the
// whole hand or for Omaha at least 3 of 4), partial (real cards, too few),
// WRONG (any card not in the hand), missed (nothing logged).
//
// --dump writes one JSON line per read: still, crop, every distinct card
// read with its geometry (size, aspect, upright aspect, tilt, position),
// and the hero cards left after the board guards.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/camera/glyph_cnn.dart';
import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:felt_notes/camera/watch_frame.dart';
import 'package:felt_notes/camera/watch_pipeline.dart';
import 'package:felt_notes/camera/watch_tracker.dart';
import 'package:felt_notes/poker/cards.dart';

const _ffmpeg = '/opt/homebrew/bin/ffmpeg';

Future<void> main(List<String> argv) async {
  final args = [...argv];
  String? opt(String name, [String? def]) {
    final i = args.indexOf(name);
    if (i < 0) return def;
    final v = args[i + 1];
    args.removeRange(i, i + 2);
    return v;
  }

  final verbose = args.remove('-v');
  final debug = args.remove('--debug');
  final quiet = args.remove('-q');
  final scale = double.parse(opt('--scale', '0.35')!);
  final dumpPath = opt('--dump');
  final labelsOpt = opt('--labels');
  final maxN = int.tryParse(opt('--max', '') ?? '');
  // Reader ceiling: read every still's whole upright frame (no gate, no
  // pipeline); with --dump only.
  final full = args.remove('--full');
  final fullLoose = args.contains('--loose');
  final fullCoarse = args.contains('--coarse');
  final fullMaxFrac = double.parse(opt('--maxfrac', '0.14')!);
  final fromN = int.tryParse(opt('--from', '') ?? '') ?? 0;
  // --only FILE: still numbers (whitespace / comma separated) to read.
  final onlyPath = opt('--only');
  final only = onlyPath == null
      ? null
      : {for (final t in File(onlyPath).readAsStringSync().split(RegExp(r'[\s,]+'))) if (t.isNotEmpty) int.parse(t)};
  // --legacy: build 49's reader and guards (2 hero cards a read, the
  // image-axis flat guard, no coarse pass, strict ink colours).
  final legacy = args.remove('--legacy');
  const def = WatchConfig();
  final cfg = WatchConfig(
    flatAspect: double.parse(opt('--flat', legacy ? '0.85' : '${def.flatAspect}')!),
    maxSizeRatio: double.parse(opt('--ratio', '${def.maxSizeRatio}')!),
    uprightFlatAspect: double.parse(opt('--uflat', legacy ? '0' : '${def.uprightFlatAspect}')!),
    heroCardsMax: int.parse(opt('--hero-max', legacy ? '2' : '${def.heroCardsMax}')!),
    omahaMinCards: int.parse(opt('--omaha-min', legacy ? '3' : '${def.omahaMinCards}')!),
    looseInk: !legacy && !args.remove('--no-loose') && (args.remove('--loose') || def.looseInk),
    coarsePass: !legacy && !args.remove('--no-coarse') && (args.remove('--coarse') || def.coarsePass),
    minCropFrac: double.parse(opt('--crop', '${def.minCropFrac}')!),
    readMaxShort: int.parse(opt('--read-short', '${def.readMaxShort}')!),
  );

  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/watch_stills.dart REC_DIR [--labels L] [--scale 0.35] [--dump F] [-v]');
    exit(2);
  }
  final rec = args.first;
  final photos = <(int n, int ms, String file)>[];
  for (final line in File('$rec/session.jsonl').readAsLinesSync()) {
    if (!line.contains('"k":"photo"')) continue;
    final e = jsonDecode(line) as Map<String, dynamic>;
    photos.add((e['n'] as int, e['m'] as int, e['f'] as String));
  }
  if (maxN != null) photos.removeWhere((p) => p.$1 > maxN);
  photos.removeWhere((p) => p.$1 < fromN || (only != null && !only.contains(p.$1)));
  final labelsPath = labelsOpt ?? '$rec/labels.json';
  final labels = File(labelsPath).existsSync()
      ? (jsonDecode(File(labelsPath).readAsStringSync()) as List).cast<Map<String, dynamic>>()
      : const <Map<String, dynamic>>[];

  // One ffmpeg over all stills, BGRA in sensor orientation.
  final list = File('${Directory.systemTemp.path}/watch_stills_$pid.txt')
    ..writeAsStringSync(photos.map((p) => "file '${File('$rec/${p.$3}').absolute.path}'\nduration 1\n").join());
  final proc = await Process.start(_ffmpeg, [
    '-hide_banner', '-loglevel', 'error', '-noautorotate', '-f', 'concat', '-safe', '0', '-i', list.path,
    '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'bgra', '-',
  ]);
  proc.stderr.transform(utf8.decoder).listen(stderr.write);
  const w = 1280, h = 720, frameBytes = w * h * 4;

  final cnn = GlyphCnn.parse(File('assets/data/glyph_cnn.bin').readAsBytesSync());
  final pipe = WatchPipeline(cfg);
  final tracker = WatchHandTracker();
  final decisions = <(int, WatchDecision)>[]; // real ms
  final dump = dumpPath == null ? null : File(dumpPath).openWrite();
  var idx = 0, reads = 0, readMsSum = 0, cnnCalls = 0;
  final sw = Stopwatch()..start();

  void onStill(Uint8List bgra) {
    final (n, ms, file) = photos[idx++];
    final t = (ms * scale).round();
    final rot = _exifRotation(File('$rec/$file'));
    pipe.rotation = rot;
    final frame = WatchFrame(w, h, WatchPixelFormat.bgra8888, [WatchPlane(bgra, w * 4, 4)]);
    if (full) {
      final (crop, cw, ch) = frame.cropRgba(const PixRect(0, 0, w, h), maxShort: cfg.readMaxShort);
      final (rgba, rw, rh) = rotateRgba(crop, cw, ch, rot);
      whiteBalance(rgba);
      if (debug) {
        glyphDebugSink = [];
        glyphDebugMasks = (paper, red, dark, g, mw, mh) {
          final out = BytesBuilder()..add(ascii.encode('P6\n$mw $mh\n255\n'));
          for (var i = 0; i < mw * mh; i++) {
            final v = g[i] ~/ 3;
            out.add([red[i] != 0 ? 255 : (dark[i] != 0 ? 0 : v + (paper[i] != 0 ? 120 : 0)), dark[i] != 0 ? 255 : v + (paper[i] != 0 ? 120 : 0), dark[i] != 0 ? 0 : v]);
          }
          File('${Directory.systemTemp.path}/mask_$n.ppm').writeAsBytesSync(out.takeBytes());
        };
      }
      final r = readGlyphs(rgba, rw, rh,
          cnn: cnn, tta: cfg.tta, warmLight: cfg.warmLight, ringPaperMin: cfg.ringPaperMin, findBoard: false,
          looseInk: fullLoose, maxGlyphFrac: fullMaxFrac, coarsePass: fullCoarse);
      reads++;
      readMsSum += r.timingMs['total'] ?? 0;
      cnnCalls += r.timingMs['cnnCalls'] ?? 0;
      if (glyphDebugSink != null) {
        stdout.writeln('n$n work ${r.workWidth}x${r.workHeight}\n  ${glyphDebugSink!.join('\n  ')}');
      }
      if (verbose && r.hits.isNotEmpty) {
        stdout.writeln('n$n ${r.timingMs['nBlobs']} blobs: ${r.hits.map(_hit).join(' | ')}');
      }
      dump?.writeln(jsonEncode({'n': n, 's': ms / 1000, 'rot': rot, 'nBlobs': r.timingMs['nBlobs'], 'hits': r.hits.map(_hitJson).toList(), 'hero': [], 'kept': []}));
      return;
    }
    final job = pipe.onFrame(frame, t);
    for (final (_, seen) in pipe.lookEnds) {
      final d = tracker.onLookEnd(seen, ms, scene: pipe.sceneEpoch);
      if (d.action == WatchAction.ignore) continue;
      pipe.votesAfter(d);
      decisions.add((ms, d));
    }
    pipe.lookEnds.clear();
    if (job == null) return;
    reads++;
    final r = readGlyphs(job.rgba, job.width, job.height,
        cnn: cnn,
        tta: cfg.tta,
        scaleShortSide: job.scaleShortSide,
        warmLight: cfg.warmLight,
        ringPaperMin: cfg.ringPaperMin,
        maxBlobs: cfg.maxBlobs,
        findBoard: cfg.findBoard,
        looseInk: cfg.looseInk,
        coarsePass: cfg.coarsePass);
    readMsSum += r.timingMs['total'] ?? 0;
    cnnCalls += r.timingMs['cnnCalls'] ?? 0;
    final g0 = pipe.counts.boardGuarded;
    final kept = cfg.heroCardsMax > 2 ? pipe.heroHits(r) : pipe.heroCards(r);
    pipe.counts.boardGuarded = g0;
    final pair = pipe.onRead(job, r);
    final ev = pipe.lastEvidence;
    WatchDecision? d;
    if (pair != null) {
      d = tracker.onRead(pair, ms, episode: pipe.cardEpisode, scene: pipe.sceneEpoch, evidence: ev);
      pipe.noteDecision(d);
      pipe.votesAfter(d);
      decisions.add((ms, d));
    }
    if (verbose && (r.hits.isNotEmpty || d != null)) {
      stdout.writeln('n$n ${(ms / 1000).toStringAsFixed(1)}s rot$rot ${job.box} '
          '${r.hits.map(_hit).join(' | ')}'
          ' => ${kept.where((c) => c.confident).map((c) => cardToString(c.card)).join(' ')}'
          '${d == null ? '' : '   ** ${d.action.name} ${prettyCards(d.cards)}'}');
    }
    dump?.writeln(jsonEncode({
      'n': n,
      's': ms / 1000,
      'rot': rot,
      'box': [job.box?.x0, job.box?.y0, job.box?.x1, job.box?.y1],
      'nBlobs': r.timingMs['nBlobs'],
      'hits': r.hits.map(_hitJson).toList(),
      'hero': [for (final c in r.hero) cardToString(c.card)],
      'kept': [for (final c in kept) if (c.confident) cardToString(c.card)],
      if (pair != null) 'pair': prettyCards(pair),
      if (d != null) 'decision': '${d.action.name} ${prettyCards(d.cards)}',
    }));
  }

  final buf = BytesBuilder(copy: false);
  await for (final chunk in proc.stdout) {
    buf.add(chunk);
    if (buf.length < frameBytes) continue;
    final all = buf.takeBytes();
    var off = 0;
    while (all.length - off >= frameBytes && idx < photos.length) {
      onStill(Uint8List.fromList(Uint8List.sublistView(all, off, off + frameBytes)));
      off += frameBytes;
    }
    if (off < all.length) buf.add(Uint8List.sublistView(all, off));
  }
  await proc.exitCode;
  list.deleteSync();
  pipe.flush(((photos.isEmpty ? 0 : photos.last.$2) * scale).round() + 5000);
  await dump?.close();

  if (!quiet) {
    stdout.writeln('\n--- decisions ($rec)');
    for (final (t, d) in decisions) {
      if (d.action == WatchAction.confirm) continue;
      stdout.writeln('${(t / 1000).toStringAsFixed(1)}s ${d.action.name.padRight(13)} ${prettyCards(d.cards)}'
          '${d.previous == null ? '' : ' (was ${prettyCards(d.previous!)})'}');
    }
  }
  stdout.writeln('stills $idx, reads $reads (mean ${reads == 0 ? 0 : readMsSum ~/ reads} ms on this Mac, ${reads == 0 ? 0 : cnnCalls ~/ reads} CNN calls), ${sw.elapsed.inSeconds} s; '
      'guarded ${pipe.counts.boardGuarded}, omaha ${pipe.counts.omaha}, single ${pipe.counts.singleFrame}');
  if (labels.isNotEmpty) stdout.writeln(scoreHands(decisions, labels));
}

String _hit(GlyphHit x) => '${cardToString(x.card)} ${x.score.toStringAsFixed(2)}${x.confident ? '' : '~'} '
    's${x.size.toStringAsFixed(3)} a${x.aspect.toStringAsFixed(2)} u${x.uprightAspect.toStringAsFixed(2)} '
    '${x.angle.round()}deg @${(x.x * 100).round()},${(x.y * 100).round()}';

Map<String, Object> _hitJson(GlyphHit x) => {
      'c': cardToString(x.card),
      'p': x.score,
      'conf': x.confident,
      'size': x.size,
      'asp': x.aspect,
      'up': x.uprightAspect,
      'ang': x.angle,
      'x': x.x,
      'y': x.y,
    };

/// Clockwise turn from the JPEG's EXIF orientation (0 when absent).
int _exifRotation(File f) {
  final raf = f.openSync();
  final b = raf.readSync(4096);
  raf.closeSync();
  for (var i = 0; i + 10 < b.length; i++) {
    // Big-endian (MM) or little-endian (II) tag 0x0112, type SHORT.
    int? v;
    if (b[i] == 0x01 && b[i + 1] == 0x12 && b[i + 2] == 0 && b[i + 3] == 3) v = b[i + 9];
    if (b[i] == 0x12 && b[i + 1] == 0x01 && b[i + 2] == 3 && b[i + 3] == 0) v = b[i + 8];
    if (v != null) return switch (v) { 6 => 90, 3 => 180, 8 => 270, _ => 0 };
  }
  return 0;
}

/// A label card: exact, or a rank / suit pattern ("Q?", "?d"), or "??".
typedef _Pat = (int? rank, int? suit);

_Pat _pat(String s) {
  const ranks = '23456789TJQKA', suits = 'cdhs';
  final r = ranks.indexOf(s[0]), su = suits.indexOf(s[1]);
  return (r < 0 ? null : r, su < 0 ? null : su);
}

/// Per hand: right / partial / WRONG / missed, and the totals.
String scoreHands(List<(int, WatchDecision)> decisions, List<Map<String, dynamic>> labels) {
  final out = StringBuffer();
  var right = 0, partial = 0, wrong = 0, missed = 0;
  final used = <int>{};
  for (final l in labels.where((l) => l['skip'] != true)) {
    final t0 = ((l['t0'] as num) * 1000).round() - 2000, t1 = ((l['t1'] as num) * 1000).round() + 2000;
    final pats = [for (final c in (l['cards'] as String).trim().split(RegExp(r'\s+'))) _pat(c)];
    final n = (l['ncards'] as num?)?.toInt() ?? pats.length;
    // The tracker's cards for this hand: the last set it logged in the window.
    List<int>? got;
    final logged = <String>[];
    for (var i = 0; i < decisions.length; i++) {
      final (t, d) = decisions[i];
      if (t < t0 || t > t1) continue;
      used.add(i);
      switch (d.action) {
        case WatchAction.fill || WatchAction.newHand || WatchAction.correct:
          got = d.cards;
          logged.add('${d.action.name} ${prettyCards(d.cards)}');
        case WatchAction.confirm:
          got ??= d.cards;
        case _:
      }
    }
    String verdict;
    if (got == null || got.isEmpty) {
      verdict = 'missed';
      missed++;
    } else {
      // Match each reported card to a distinct label pattern, exact first.
      final free = [...pats];
      var bad = 0;
      for (final c in got) {
        int k = free.indexWhere((p) => p.$1 == cardRank(c) && p.$2 == cardSuit(c));
        if (k < 0) k = free.indexWhere((p) => (p.$1 == null || p.$1 == cardRank(c)) && (p.$2 == null || p.$2 == cardSuit(c)) && (p.$1 == null || p.$2 == null));
        if (k < 0) {
          bad++;
        } else {
          free.removeAt(k);
        }
      }
      final need = n <= 2 ? n : 3;
      if (bad > 0) {
        verdict = 'WRONG';
        wrong++;
      } else if (got.length >= need) {
        verdict = 'right';
        right++;
      } else {
        verdict = 'partial';
        partial++;
      }
    }
    out.writeln('hand ${l['hand']} ${(l['t0'] as num).toStringAsFixed(0)}-${(l['t1'] as num).toStringAsFixed(0)}s '
        '${l['game']} truth ${l['cards']}: ${verdict.padRight(7)} ${got == null ? '' : prettyCards(got)}'
        '${logged.length > 1 ? '  [${logged.join('; ')}]' : ''}');
  }
  final stray = [
    for (var i = 0; i < decisions.length; i++)
      if (!used.contains(i) &&
          const {WatchAction.fill, WatchAction.newHand, WatchAction.correct}.contains(decisions[i].$2.action))
        '${(decisions[i].$1 / 1000).toStringAsFixed(0)}s ${prettyCards(decisions[i].$2.cards)}'
  ];
  out.writeln('HANDS ${labels.where((l) => l['skip'] != true).length}: right $right, partial $partial, WRONG $wrong, missed $missed; '
      'logs outside labelled hands ${stray.length}${stray.isEmpty ? '' : ' (${stray.join(', ')})'}');
  return out.toString();
}
