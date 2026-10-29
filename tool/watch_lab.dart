// Desktop harness for Watch my cards: runs the app's own pipeline
// (lib/camera/watch_pipeline.dart + watch_tracker.dart) over a video.
//
//   ~/flutter/bin/dart run tool/watch_lab.dart camera_data/peeks.mov \
//       [--short 720] [--fps 15] [--phone 2.0] [--labels peeks.json] [-v]
//
// ffmpeg (/opt/homebrew/bin/ffmpeg) decodes the video to NV12 at the app's
// stream rate and resolution (short side --short, default 720 = the app's
// ResolutionPreset.high), which is what the iPhone camera stream delivers
// (420v, video range). Frames are fed in real time order; the glyph reader
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
  // Synthetic clips made of separate stills: re-learn the background at each
  // cut (seconds), as if each segment were filmed on its own.
  final resetEvery = double.tryParse(opt('--reset-every', '') ?? '');
  final pipe = WatchPipeline(WatchConfig(
    tta: args.remove('--tta'),
    minAgree: int.parse(opt('--agree', '2')!),
    readMaxShort: int.parse(opt('--read-short', '720')!),
    minCropFrac: double.parse(opt('--crop', '0.5')!),
  ));
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/watch_lab.dart VIDEO [--short 720] [--fps 15] '
        '[--phone 2.0] [--labels L.json] [--start S] [--max S] [--tta] [--agree 2] '
        '[--read-short 720] [--crop 0.5] [--dump DIR] [-v]');
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
        ':out_range=tv:out_color_matrix=bt709',
    '-pix_fmt', 'nv12', '-f', 'rawvideo', '-',
  ]);
  // Output size from ffmpeg's stream description.
  final sizeC = Completer<(int, int)>();
  proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    final m = RegExp(r'Video: rawvideo.*?(\d{2,5})x(\d{2,5})').firstMatch(l);
    if (m != null && !sizeC.isCompleted) sizeC.complete((int.parse(m[1]!), int.parse(m[2]!)));
  });
  final (w, h) = await sizeC.future;
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
    final d = tracker.onRead(pair, f.$1.tMs);
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
        videoRange: true);
    final job = pipe.onFrame(frame, t);
    if (job == null) return;
    if (dumpDir != null) _dumpPpm('$dumpDir/crop_${job.tMs.toString().padLeft(7, '0')}.ppm', job);
    final sw = Stopwatch()..start();
    final r = readGlyphs(job.rgba, job.width, job.height,
        cnn: cnn, tta: pipe.cfg.tta, scaleShortSide: job.scaleShortSide);
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
    var hit = 0, wrong = 0, missed = 0;
    final used = <int>{};
    stdout.writeln('\n--- vs labels');
    for (final l in labels) {
      final t = ((l['t'] as num) * 1000).round();
      final truth = canonicalPair(parseCards(l['cards'] as String));
      // Cards logged for this peek: the latest decision within 4 s.
      final near = [
        for (var i = 0; i < decisions.length; i++)
          if ((decisions[i].$1 - t).abs() <= 4000) i
      ];
      List<int>? got;
      for (final i in near) {
        used.add(i);
        got = decisions[i].$2.cards;
      }
      final ok = got != null && _same(got, truth);
      if (ok) {
        hit++;
      } else if (got == null) {
        missed++;
      } else {
        wrong++;
      }
      stdout.writeln('${(t / 1000).toStringAsFixed(1)}s truth ${prettyCards(truth)}  '
          'logged ${got == null ? '-' : prettyCards(got)}  ${ok ? 'OK' : got == null ? 'MISSED' : 'WRONG'}');
    }
    var stray = 0;
    for (var i = 0; i < decisions.length; i++) {
      if (!used.contains(i) && decisions[i].$2.action != WatchAction.confirm) stray++;
    }
    stdout.writeln('labels ${labels.length}: right $hit, missed $missed, wrong $wrong; '
        'false logs (wrong + decisions away from any label) ${wrong + stray}');
  }
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
