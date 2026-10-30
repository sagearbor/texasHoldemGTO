// Desktop harness for Watch my cards: runs the app's own pipeline
// (lib/camera/watch_pipeline.dart + watch_tracker.dart) over a video.
//
//   ~/flutter/bin/dart run tool/watch_lab.dart camera_data/peeks.mov \
//       [--short 720] [--fps 15] [--phone 2.0 | --read-ms 180] \
//       [--labels peeks.json] [--android] [-v]
//
// ffmpeg (/opt/homebrew/bin/ffmpeg) decodes the video to NV12 at the app's
// stream rate and resolution (short side --short, default 720 = the app's
// ResolutionPreset.high), as the iPhone camera stream delivers it (420v:
// video range, BT.709), or with --android as CameraX delivers it (full
// range, BT.601). Frames are fed in real time order; the glyph reader
// runs inline, but its answer is delivered only after its measured time x
// --phone (a phone is slower than this Mac), and frames that arrive in the
// meantime find the reader busy, exactly as on the device.
//
// Reported: every peek (time to readable / confident, frames per stage,
// agreeing reads, near-misses, late bursts), every logging decision, the
// session summary (the same WatchSessionSummary the app writes to its
// diagnostics log) and, with --labels, hits / misses / FALSE logs against
// the truth:  [{"t": 12.5, "cards": "As Kd"}, ...]  (t = seconds, roughly
// mid-peek; a decision within 4 s of a label is matched to it).
//
// The ML Kit fallback is not available on the desktop and is not used by
// Watch mode on the phone either (glyph reader only).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/camera/board_watch.dart';
import 'package:felt_notes/camera/glyph_cnn.dart';
import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:felt_notes/camera/watch_diagnostics.dart';
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
  final android = args.remove('--android');
  // Debug: write every reader crop as a PPM (your own footage, local only).
  final dumpDir = opt('--dump');
  final short = int.parse(opt('--short', '720')!);
  final fps = int.parse(opt('--fps', '15')!);
  final phone = double.parse(opt('--phone', '2.0')!);
  // Fixed simulated reader latency (ms) instead of measured x --phone: use
  // it when this Mac is busy and its timings are noise.
  final readMsFixed = int.tryParse(opt('--read-ms', '') ?? '');
  final labelsPath = opt('--labels');
  final maxSec = double.tryParse(opt('--max', '') ?? '');
  final startSec = double.tryParse(opt('--start', '') ?? '') ?? 0;
  final sat = double.tryParse(opt('--sat', '') ?? '');
  // HLG HDR clip -> SDR like the live camera stream: a 3D LUT made by
  // tool/camera_lab/make_hlg_sdr_lut.py (this ffmpeg has no zscale).
  final hlgLut = opt('--hlg');
  // Scene rotation in the frame, as CameraX delivers a phone held the other
  // way (sensor orientation): 90 = portrait-held phone, landscape video.
  final rotate = int.parse(opt('--rotate', '0')!);
  // Undo it before reading, as the app does (WatchConfig-independent).
  final unrotate = args.remove('--unrotate');
  // Spoken "next hand" times (tool/camera_lab/next_hand_markers.py).
  final markersPath = opt('--markers');
  // Synthetic clips made of separate stills: re-learn the background at each
  // cut (seconds), as if each segment were filmed on its own.
  final resetEvery = double.tryParse(opt('--reset-every', '') ?? '');
  // Board cards too (lib/camera/board_watch.dart), scored against
  // [{"t0": 11.5, "t1": 15.5, "cards": "7d 9c Kh"}, ...] (seconds the
  // street lay on the table; "?" for a rank or suit you cannot tell).
  final boardLabelsPath = opt('--board-labels');
  final boardDump = opt('--board-dump');
  final board = args.remove('--board') || boardLabelsPath != null;
  final pipe = WatchPipeline(WatchConfig(
    tta: args.remove('--tta'),
    whiteBalance: !args.remove('--no-wb'),
    warmLight: !args.remove('--no-warm'),
    minAgree: int.parse(opt('--agree', '2')!),
    readMaxShort: int.parse(opt('--read-short', '540')!),
    minCropFrac: double.parse(opt('--crop', '0.5')!),
    singleFrameScore: double.parse(opt('--single', '0.92')!),
    ringPaperMin: double.parse(opt('--ring', '0.5')!),
    maxBlobs: int.tryParse(opt('--max-blobs', '') ?? ''),
    findBoard: args.remove('--board'),
  ));
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/watch_lab.dart VIDEO [--short 720] [--fps 15] '
        '[--phone 2.0] [--labels L.json] [--start S] [--max S] [--tta] [--agree 2] '
        '[--read-short 540] [--crop 0.5] [--no-wb] [--no-warm] [--hlg LUT.cube] [--markers M.json] [--sat S] [--dump DIR] [-v]');
    exit(2);
  }
  final cnn = GlyphCnn.parse(File('assets/data/glyph_cnn.bin').readAsBytesSync());
  final proc = await Process.start(_ffmpeg, [
    '-hide_banner', '-nostats', '-loglevel', 'info',
    if (startSec > 0) ...['-ss', '$startSec'],
    '-i', args.first,
    if (maxSec != null) ...['-t', '$maxSec'],
    '-an',
    // Always video range + BT.709, like the iPhone stream, whatever the
    // file is tagged (a clip made from JPEGs is full range).
    '-vf', "fps=$fps${switch (rotate) { 90 => ',transpose=1', 180 => ',hflip,vflip', 270 => ',transpose=2', _ => '' }},scale='if(gt(iw,ih),-2,$short)':'if(gt(iw,ih),$short,-2)':flags=area"
        "${hlgLut == null ? '' : ':in_color_matrix=bt2020:in_range=tv,format=rgb48le,lut3d=file=$hlgLut,scale=in_range=pc'}"
        "${android ? ':out_range=pc:out_color_matrix=bt601' : ':out_range=tv:out_color_matrix=bt709'}"
        // Rough stand-in for HDR tone-mapping (no zscale here): HLG / BT.2020
        // shown as SDR looks flat and desaturated; --sat 1.35 undoes part.
        "${sat == null ? '' : ',eq=saturation=$sat'}",
    '-pix_fmt', 'nv12', '-f', 'rawvideo', '-',
  ]);
  // Output size from ffmpeg's stream description.
  final sizeC = Completer<(int, int)>();
  proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    final m = RegExp(r'Video: rawvideo.*?(\d{2,5})x(\d{2,5})').firstMatch(l);
    if (m != null && !sizeC.isCompleted) sizeC.complete((int.parse(m[1]!), int.parse(m[2]!)));
  });
  final (w, h) = await sizeC.future;
  // HDR (HLG / PQ) phone video has no tone-mapping here (this ffmpeg lacks
  // zscale): colours come out flat and reads suffer. Record in SDR.
  final probe = await Process.run('/opt/homebrew/bin/ffprobe', [
    '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=color_transfer,codec_name,r_frame_rate',
    '-of', 'default=nw=1', args.first,
  ]);
  final info = '${probe.stdout}'.trim().replaceAll('\n', ', ');
  stdout.writeln('source: $info');
  if (hlgLut == null && RegExp(r'arib-std-b67|smpte2084').hasMatch(info)) {
    stdout.writeln('WARNING: HDR source video, not tone-mapped: colours are off, expect worse reads');
  }
  final frameBytes = w * h * 3 ~/ 2;
  stdout.writeln('video ${args.first}: ${w}x$h NV12 @ $fps fps, reader latency '
      '${readMsFixed == null ? 'measured x$phone' : '$readMsFixed ms (fixed)'}');

  if (unrotate) pipe.rotation = (360 - rotate) % 360;
  final boardWatch = BoardWatcher()..rotation = pipe.rotation;
  var boardReadMs = 0;
  final tracker = WatchHandTracker();
  final decisions = <(int, WatchDecision)>[];
  (ReadJob, GlyphReadResult, int, int)? inFlight; // job, result, deliver at, ms
  var frameNo = 0;
  final buf = BytesBuilder(copy: false);
  var maxReadMs = 0, sumReadMs = 0, reads = 0;
  // Per-stage reader time (this Mac) and crop sizes: where a read's cost goes.
  final stageMs = <String, int>{};
  var cropPx = 0, emptyReads = 0;

  void deliver((ReadJob, GlyphReadResult, int, int) f) {
    final pair = pipe.onRead(f.$1, f.$2, readMs: f.$4);
    if (verbose) {
      stdout.writeln('  read @${(f.$1.tMs / 1000).toStringAsFixed(2)}s ${f.$1.width}x${f.$1.height} '
          '${f.$4}ms ${f.$2.timingMs}: ${f.$2.hero.join(', ')}');
    }
    if (pair == null) return;
    final d = tracker.onRead(pair, f.$1.tMs, episode: pipe.cardEpisode, scene: pipe.sceneEpoch);
    pipe.noteDecision(d);
    if (d.startsHand) pipe.resetVotes();
    decisions.add((f.$1.tMs, d));
  }

  void onFrame(Uint8List data) {
    final t = frameNo++ * 1000 ~/ fps;
    if (resetEvery != null && t > 0 && t % (resetEvery * 1000).round() < 1000 ~/ fps) pipe.gate.reset();
    if (inFlight != null && t >= inFlight!.$3) {
      final f = inFlight!;
      inFlight = null;
      deliver(f);
    }
    final y = Uint8List.sublistView(data, 0, w * h);
    final uv = Uint8List.sublistView(data, w * h);
    final frame = WatchFrame(w, h, WatchPixelFormat.yuv420, [WatchPlane(y, w, 1), WatchPlane(uv, w, 2)],
        videoRange: !android);
    if (board) {
      final bj = boardWatch.onFrame(frame, t);
      if (bj != null) {
        final bsw = Stopwatch()..start();
        final cards = readBoardJob(bj);
        boardReadMs += bsw.elapsedMilliseconds;
        if (boardDump != null) {
          for (var i = 0; i < bj.cards.length; i++) {
            final c = bj.cards[i];
            _dumpPpm('$boardDump/board_${bj.tMs.toString().padLeft(7, '0')}_$i.ppm',
                ReadJob(c.rgba, c.width, c.height, bj.tMs, 0));
          }
        }
        final r = boardWatch.onRead(bj, cards);
        if (verbose) {
          stdout.writeln('  board @${(bj.tMs / 1000).toStringAsFixed(2)}s ${cards.join(' ')}'
              '${r == null ? '' : '  -> $r'}');
        }
      }
    }
    final job = pipe.onFrame(frame, t);
    for (final (tl, seen) in pipe.lookEnds) {
      final d = tracker.onLookEnd(seen, tl, scene: pipe.sceneEpoch);
      if (d.action == WatchAction.ignore) continue;
      if (d.startsHand) pipe.resetVotes();
      decisions.add((tl, d));
    }
    pipe.lookEnds.clear();
    if (job == null) return;
    if (dumpDir != null) _dumpPpm('$dumpDir/crop_${job.tMs.toString().padLeft(7, '0')}.ppm', job);
    final sw = Stopwatch()..start();
    final r = readGlyphs(job.rgba, job.width, job.height,
        cnn: cnn, tta: pipe.cfg.tta, scaleShortSide: job.scaleShortSide, warmLight: pipe.cfg.warmLight, ringPaperMin: pipe.cfg.ringPaperMin,
        maxBlobs: pipe.cfg.maxBlobs, findBoard: pipe.cfg.findBoard);
    final ms = sw.elapsedMilliseconds;
    for (final e in r.timingMs.entries) {
      if (e.key != 'total') stageMs[e.key] = (stageMs[e.key] ?? 0) + e.value;
    }
    cropPx += job.width * job.height;
    if (r.hero.isEmpty) emptyReads++;
    maxReadMs = ms > maxReadMs ? ms : maxReadMs;
    sumReadMs += ms;
    reads++;
    inFlight = (job, r, t + (readMsFixed ?? (ms * phone).round()), ms);
  }

  await for (final chunk in proc.stdout) {
    buf.add(chunk);
    if (buf.length < frameBytes) continue;
    final all = buf.takeBytes();
    var off = 0;
    while (all.length - off >= frameBytes) {
      onFrame(Uint8List.sublistView(all, off, off + frameBytes));
      off += frameBytes;
    }
    if (off < all.length) buf.add(Uint8List.sublistView(all, off));
  }
  await proc.exitCode;
  final endMs = frameNo * 1000 ~/ fps;
  if (inFlight != null) deliver(inFlight!);
  pipe.flush(endMs);

  stdout.writeln('\n--- peeks (card-like changes the reader looked at)');
  for (final p in pipe.peeks) {
    stdout.writeln(p);
  }
  stdout.writeln('\n--- decisions');
  for (final (t, d) in decisions.where((e) => e.$2.action != WatchAction.confirm)) {
    stdout.writeln('${(t / 1000).toStringAsFixed(1)}s ${d.action.name.padRight(8)} ${prettyCards(d.cards)}'
        '${d.previous == null ? '' : ' (was ${prettyCards(d.previous!)})'}');
  }
  final sum = WatchSessionSummary(endMs, pipe.counts, pipe.peeks);
  stdout.writeln('\n--- summary');
  stdout.writeln(sum.describe());
  if (reads > 0) {
    stdout.writeln('reader stages (mean ms, this Mac): '
        '${stageMs.entries.map((e) => '${e.key} ${(e.value / reads).toStringAsFixed(1)}').join(', ')}; '
        'crop mean ${(cropPx / reads / 1000).round()} kpx; reads with no card ${(100 * emptyReads / reads).round()} %');
  }
  stdout.writeln('reader on this Mac: $reads reads, mean ${reads == 0 ? 0 : sumReadMs ~/ reads} ms, '
      'max $maxReadMs ms (simulated phone x$phone)');
  final mins = endMs / 60000;
  if (mins > 0) {
    stdout.writeln('battery proxy: ${(pipe.counts.read / mins).toStringAsFixed(1)} reader runs/min, '
        '${((readMsFixed == null ? sumReadMs * phone : reads * readMsFixed) / mins / 1000).toStringAsFixed(1)} '
        's reader CPU/min (phone estimate)');
  }

  if (board) {
    stdout.writeln('\n--- board streets read');
    for (final r in boardWatch.reads) {
      stdout.writeln(r);
    }
    stdout.writeln('board swept at: ${boardWatch.clears.map((t) => '${(t / 1000).toStringAsFixed(1)}s').join(', ')}');
    stdout.writeln('board looks ${boardWatch.looks} (${boardWatch.lookMs} ms), jobs ${boardWatch.jobs} ($boardReadMs ms)');
    if (boardLabelsPath != null) {
      final labels = (jsonDecode(File(boardLabelsPath).readAsStringSync()) as List).cast<Map<String, dynamic>>();
      stdout.writeln('\n--- board vs labels');
      stdout.writeln(scoreBoard(boardWatch.reads, labels));
    }
  }

  if (labelsPath != null) {
    final labels = (jsonDecode(File(labelsPath).readAsStringSync()) as List).cast<Map<String, dynamic>>();
    stdout.writeln('\n--- vs labels');
    final lab = [
      for (final l in labels) (((l['t'] as num) * 1000).round(), canonicalPair(parseCards(l['cards'] as String)))
    ];
    stdout.writeln(scoreAgainstLabels(decisions, lab));
    if (markersPath != null) {
      final marks = [
        for (final m in (jsonDecode(File(markersPath).readAsStringSync()) as List).cast<Map<String, dynamic>>())
          ((m['t'] as num) * 1000).round()
      ];
      stdout.writeln(scoreBoundaries(decisions, marks, [for (final l in lab) l.$1]));
    }
  }
}

/// The hand log the decisions produce: (start ms, final cards) per hand;
/// no cards = a hand counted but not read. newHand / newHandUnread start a
/// hand; fill starts the first one or fills an unread one; correct replaces
/// the cards.
List<(int, List<int>)> handLog(List<(int, WatchDecision)> decisions) {
  final hands = <(int, List<int>)>[];
  for (final (t, d) in decisions) {
    switch (d.action) {
      case WatchAction.fill:
        if (hands.isNotEmpty && hands.last.$2.isEmpty) {
          hands[hands.length - 1] = (hands.last.$1, d.cards);
        } else {
          hands.add((t, d.cards));
        }
      case WatchAction.newHand:
        hands.add((t, d.cards));
      case WatchAction.newHandUnread:
        hands.add((t, const []));
      case WatchAction.correct:
        if (hands.isNotEmpty) hands[hands.length - 1] = (hands.last.$1, d.cards);
      case _:
    }
  }
  return hands;
}

/// Hand boundaries against the spoken "next hand" markers: a marker is
/// found when a hand starts between 2 s before it and 4 s after the next
/// labelled peek. Splits: hands started beyond one between two labelled
/// peeks (each label's interval runs from 3 s before it to 3 s before the
/// next), i.e. one real hand logged as two. (The owner forgot to say "next
/// hand" on the first deals, so markers alone would over-count splits.)
String scoreBoundaries(List<(int, WatchDecision)> decisions, List<int> markers, List<int> labelTimes) {
  final starts = <int>[];
  for (final (t, d) in decisions) {
    // A fill of a just-started unread hand is the same hand.
    if (d.action == WatchAction.fill && starts.isNotEmpty) continue;
    if (d.startsHand || d.action == WatchAction.fill) starts.add(t);
  }
  final windows = [
    for (final m in markers) (m - 2000, (labelTimes.firstWhere((t) => t > m, orElse: () => m + 6000)) + 4000)
  ];
  var found = 0;
  for (final (a, b) in windows) {
    if (starts.any((t) => t >= a && t <= b)) found++;
  }
  var extra = 0;
  for (var i = 0; i < labelTimes.length; i++) {
    final a = i == 0 ? -1 << 40 : labelTimes[i] - 3000;
    final b = i + 1 < labelTimes.length ? labelTimes[i + 1] - 3000 : 1 << 40;
    final n = starts.where((t) => t >= a && t < b).length;
    if (n > 1) extra += n - 1;
  }
  return 'next-hand markers ${markers.length}: found $found, missed ${markers.length - found}; '
      'extra boundaries (hands split) $extra';
}

/// Scores the hand log against labelled hands ((ms mid-peek, cards), one
/// per hand, in order). Each logged hand is matched to the nearest label
/// within 6 s of its start (each label at most once). Reports right /
/// wrong / missed hands, spurious logged hands, and hand boundaries found
/// (two consecutive labelled hands that became two different logged
/// hands).
String scoreAgainstLabels(List<(int, WatchDecision)> decisions, List<(int, List<int>)> labels) {
  final hands = handLog(decisions);
  final labelOf = List<int?>.filled(hands.length, null);
  final handOf = List<int?>.filled(labels.length, null);
  for (var h = 0; h < hands.length; h++) {
    var best = -1, bestD = 6001;
    for (var l = 0; l < labels.length; l++) {
      if (handOf[l] != null) continue;
      final d = (hands[h].$1 - labels[l].$1).abs();
      if (d < bestD) {
        best = l;
        bestD = d;
      }
    }
    if (best >= 0) {
      labelOf[h] = best;
      handOf[best] = h;
    }
  }
  var right = 0, wrong = 0, missed = 0, unread = 0, bounds = 0;
  final out = StringBuffer();
  for (var l = 0; l < labels.length; l++) {
    final h = handOf[l];
    final got = h == null ? null : hands[h].$2;
    final ok = got != null && got.length == 2 && _same(got, labels[l].$2);
    if (ok) {
      right++;
    } else if (got == null) {
      missed++;
    } else if (got.isEmpty) {
      unread++;
    } else {
      wrong++;
    }
    if (l > 0 && h != null && handOf[l - 1] != null && handOf[l - 1] != h) bounds++;
    out.writeln('${(labels[l].$1 / 1000).toStringAsFixed(1)}s truth ${prettyCards(labels[l].$2)}  '
        'logged ${got == null ? '-' : got.isEmpty ? '(not read)' : prettyCards(got)}  '
        '${ok ? 'OK' : got == null ? 'MISSED' : got.isEmpty ? 'UNREAD (hand counted)' : 'WRONG'}');
  }
  final spurious = labelOf.where((l) => l == null).length;
  out.writeln('hands ${labels.length}: right $right, wrong $wrong, counted unread $unread, missed $missed; '
      'spurious logged hands $spurious; false logs ${wrong + spurious}');
  out.write('hand boundaries: ${labels.length - 1} true, $bounds found between logged hands, '
      '${hands.length} hands logged');
  return out.toString();
}

/// Scores the board streets read against labels: each label is a street
/// window (t0..t1 seconds, cards left to right as the camera sees them,
/// "?" for an unknown rank or suit). A label is found when a read with
/// the same card count lands between t0 - 1.5 s and t1 + 1.5 s (its
/// latency is counted from t0). Rank, colour and suit are scored per card;
/// a J / Q / K label counts a "face" read as right for the rank class and
/// notes that the exact rank was not told. Reads outside every window
/// are false streets.
String scoreBoard(List<BoardRead> reads, List<Map<String, dynamic>> labels) {
  final out = StringBuffer();
  var found = 0, rankOk = 0, rankWrong = 0, rankNone = 0, faceOnly = 0;
  var suitOk = 0, suitWrong = 0, suitNone = 0, colourOk = 0, colourWrong = 0, cards = 0;
  final latencies = <int>[];
  final used = <BoardRead>{};
  for (final l in labels) {
    final t0 = ((l['t0'] as num) * 1000).round(), t1 = ((l['t1'] as num) * 1000).round();
    final toks = (l['cards'] as String).split(RegExp(r'\s+'));
    final hits = [
      for (final r in reads)
        if (r.count == toks.length && r.tMs >= t0 - 1500 && r.tMs <= t1 + 1500) r
    ];
    if (hits.isEmpty) {
      out.writeln('${(t0 / 1000).toStringAsFixed(1)}s truth ${toks.join(' ')}  MISSED');
      continue;
    }
    found++;
    final r = hits.first;
    used.addAll(hits);
    latencies.add(r.tMs - t0);
    final marks = <String>[];
    for (var i = 0; i < toks.length; i++) {
      final want = toks[i], got = r.cards[i];
      cards++;
      final wr = want[0], ws = want[1];
      var m = got.token;
      if (wr != '?') {
        final wantRank = '23456789TJQKA'.indexOf(wr);
        if (got.face && wantRank >= 9 && wantRank <= 11) {
          faceOnly++;
          m += ' face';
        } else if (got.rank == wantRank) {
          rankOk++;
        } else if (got.rank == null && !got.face) {
          rankNone++;
          m += ' rank?';
        } else {
          rankWrong++;
          m += ' RANK';
        }
      }
      if (ws != '?') {
        final wantSuit = 'cdhs'.indexOf(ws);
        final wantRed = wantSuit == 1 || wantSuit == 2;
        if (got.red == null) {
          colourWrong++;
          m += ' colour?';
        } else if (got.red == wantRed) {
          colourOk++;
        } else {
          colourWrong++;
          m += ' COLOUR';
        }
        if (got.suit == wantSuit) {
          suitOk++;
        } else if (got.suit == null) {
          suitNone++;
        } else {
          suitWrong++;
          m += ' suit';
        }
      }
      marks.add(m);
    }
    out.writeln('${(t0 / 1000).toStringAsFixed(1)}s truth ${toks.join(' ')}  read ${marks.join(' | ')}  '
        '(+${((r.tMs - t0) / 1000).toStringAsFixed(1)}s, ${r.agreed}/${r.reads} agree)');
  }
  final falseReads = reads.where((r) => !used.contains(r)).toList();
  for (final r in falseReads) {
    out.writeln('FALSE street: $r');
  }
  latencies.sort();
  out.writeln('streets ${labels.length}: found $found, missed ${labels.length - found}, false ${falseReads.length}; '
      'latency median ${latencies.isEmpty ? '-' : '${latencies[latencies.length ~/ 2]} ms'}');
  out.writeln('cards $cards: rank right $rankOk (+$faceOnly face, exact rank not told), wrong $rankWrong, '
      'unread $rankNone; colour right $colourOk, wrong $colourWrong; '
      'suit right $suitOk, wrong $suitWrong, unknown $suitNone');
  return out.toString();
}

void _dumpPpm(String path, ReadJob j) {
  final out = BytesBuilder()..add(ascii.encode('P6\n${j.width} ${j.height}\n255\n'));
  final rgb = Uint8List(j.width * j.height * 3);
  for (var i = 0, o = 0; i < j.width * j.height; i++) {
    rgb[o++] = j.rgba[i * 4];
    rgb[o++] = j.rgba[i * 4 + 1];
    rgb[o++] = j.rgba[i * 4 + 2];
  }
  out.add(rgb);
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(out.takeBytes());
}

bool _same(List<int> a, List<int> b) => a[0] == b[0] && a[1] == b[1];
