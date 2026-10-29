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
  // Synthetic clips made of separate stills: re-learn the background at each
  // cut (seconds), as if each segment were filmed on its own.
  final resetEvery = double.tryParse(opt('--reset-every', '') ?? '');
  final pipe = WatchPipeline(WatchConfig(
    tta: args.remove('--tta'),
    whiteBalance: !args.remove('--no-wb'),
    warmLight: !args.remove('--no-warm'),
    minAgree: int.parse(opt('--agree', '2')!),
    readMaxShort: int.parse(opt('--read-short', '720')!),
    minCropFrac: double.parse(opt('--crop', '0.5')!),
  ));
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/watch_lab.dart VIDEO [--short 720] [--fps 15] '
        '[--phone 2.0] [--labels L.json] [--start S] [--max S] [--tta] [--agree 2] '
        '[--read-short 720] [--crop 0.5] [--no-wb] [--no-warm] [--dump DIR] [-v]');
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
    '-vf', "fps=$fps,scale='if(gt(iw,ih),-2,$short)':'if(gt(iw,ih),$short,-2)':flags=area"
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
  if (RegExp(r'arib-std-b67|smpte2084').hasMatch(info)) {
    stdout.writeln('WARNING: HDR source video, not tone-mapped: colours are off, expect worse reads');
  }
  final frameBytes = w * h * 3 ~/ 2;
  stdout.writeln('video ${args.first}: ${w}x$h NV12 @ $fps fps, reader latency '
      '${readMsFixed == null ? 'measured x$phone' : '$readMsFixed ms (fixed)'}');

  final tracker = WatchHandTracker();
  final decisions = <(int, WatchDecision)>[];
  (ReadJob, GlyphReadResult, int, int)? inFlight; // job, result, deliver at, ms
  var frameNo = 0;
  final buf = BytesBuilder(copy: false);
  var maxReadMs = 0, sumReadMs = 0, reads = 0;

  void deliver((ReadJob, GlyphReadResult, int, int) f) {
    final pair = pipe.onRead(f.$1, f.$2, readMs: f.$4);
    if (verbose) {
      stdout.writeln('  read @${(f.$1.tMs / 1000).toStringAsFixed(2)}s ${f.$1.width}x${f.$1.height} '
          '${f.$4}ms ${f.$2.timingMs}: ${f.$2.hero.join(', ')}');
    }
    if (pair == null) return;
    final d = tracker.onRead(pair, f.$1.tMs, episode: pipe.cardEpisode);
    pipe.noteDecision(d);
    if (d.action == WatchAction.newHand) pipe.resetVotes();
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
    final job = pipe.onFrame(frame, t);
    if (job == null) return;
    if (dumpDir != null) _dumpPpm('$dumpDir/crop_${job.tMs.toString().padLeft(7, '0')}.ppm', job);
    final sw = Stopwatch()..start();
    final r = readGlyphs(job.rgba, job.width, job.height,
        cnn: cnn, tta: pipe.cfg.tta, scaleShortSide: job.scaleShortSide, warmLight: pipe.cfg.warmLight);
    final ms = sw.elapsedMilliseconds;
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
  stdout.writeln('reader on this Mac: $reads reads, mean ${reads == 0 ? 0 : sumReadMs ~/ reads} ms, '
      'max $maxReadMs ms (simulated phone x$phone)');
  final mins = endMs / 60000;
  if (mins > 0) {
    stdout.writeln('battery proxy: ${(pipe.counts.read / mins).toStringAsFixed(1)} reader runs/min, '
        '${((readMsFixed == null ? sumReadMs * phone : reads * readMsFixed) / mins / 1000).toStringAsFixed(1)} '
        's reader CPU/min (phone estimate)');
  }

  if (labelsPath != null) {
    final labels = (jsonDecode(File(labelsPath).readAsStringSync()) as List).cast<Map<String, dynamic>>();
    stdout.writeln('\n--- vs labels');
    stdout.writeln(scoreAgainstLabels(decisions, [
      for (final l in labels) (((l['t'] as num) * 1000).round(), canonicalPair(parseCards(l['cards'] as String)))
    ]));
  }
}

/// The hand log the decisions produce: (start ms, final cards) per hand.
/// fill / newHand start a hand, correct replaces its cards.
List<(int, List<int>)> handLog(List<(int, WatchDecision)> decisions) {
  final hands = <(int, List<int>)>[];
  for (final (t, d) in decisions) {
    switch (d.action) {
      case WatchAction.fill || WatchAction.newHand:
        hands.add((t, d.cards));
      case WatchAction.correct:
        if (hands.isNotEmpty) hands[hands.length - 1] = (hands.last.$1, d.cards);
      case _:
    }
  }
  return hands;
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
  var right = 0, wrong = 0, missed = 0, bounds = 0;
  final out = StringBuffer();
  for (var l = 0; l < labels.length; l++) {
    final h = handOf[l];
    final got = h == null ? null : hands[h].$2;
    final ok = got != null && _same(got, labels[l].$2);
    if (ok) {
      right++;
    } else if (got == null) {
      missed++;
    } else {
      wrong++;
    }
    if (l > 0 && h != null && handOf[l - 1] != null && handOf[l - 1] != h) bounds++;
    out.writeln('${(labels[l].$1 / 1000).toStringAsFixed(1)}s truth ${prettyCards(labels[l].$2)}  '
        'logged ${got == null ? '-' : prettyCards(got)}  ${ok ? 'OK' : got == null ? 'MISSED' : 'WRONG'}');
  }
  final spurious = labelOf.where((l) => l == null).length;
  out.writeln('hands ${labels.length}: right $right, wrong $wrong, missed $missed; '
      'spurious logged hands $spurious; false logs ${wrong + spurious}');
  out.write('hand boundaries: ${labels.length - 1} true, $bounds found between logged hands, '
      '${hands.length} hands logged');
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
