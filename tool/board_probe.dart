// Board reader probe: one frame of a video through lib/camera/board_reader.dart
// with every intermediate number printed, to tune its thresholds.
//
//   ~/flutter/bin/dart run tool/board_probe.dart VIDEO SECONDS [--short 720]
//       [--hlg LUT.cube] [--rotate 90] [--out DIR]
//
// Prints every paper component of the small upright frame (area, box,
// aspect, fill) and whether it passed, the row that was picked, and the
// read of each card in it. With --out, writes the small frame with the
// picked boxes marked, every card crop and its ink mask, as PPMs.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:felt_notes/camera/board_reader.dart';
import 'package:felt_notes/camera/board_watch.dart';
import 'package:felt_notes/camera/watch_frame.dart';

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

  final short = int.parse(opt('--short', '720')!);
  final hlg = opt('--hlg');
  final rotate = int.parse(opt('--rotate', '0')!);
  final out = opt('--out');
  final vmin = int.parse(opt('--vmin', '225')!);
  final smax = int.parse(opt('--smax', '80')!);
  final erode = int.parse(opt('--erode', '1')!);
  final wb = args.remove('--wb');
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/board_probe.dart VIDEO SECONDS [--short 720] [--hlg LUT] [--rotate 90] [--out DIR]');
    exit(2);
  }
  final video = args[0];
  final sec = double.parse(args[1]);
  final vf = "${switch (rotate) { 90 => 'transpose=1,', 180 => 'hflip,vflip,', 270 => 'transpose=2,', _ => '' }}"
      "scale='if(gt(iw,ih),-2,$short)':'if(gt(iw,ih),$short,-2)':flags=area"
      "${hlg == null ? '' : ':in_color_matrix=bt2020:in_range=tv,format=rgb48le,lut3d=file=$hlg'}";
  final res = await Process.run(_ffmpeg, [
    '-hide_banner', '-loglevel', 'error', '-ss', '$sec', '-i', video, '-frames:v', '1', '-an', //
    '-vf', vf, '-pix_fmt', 'bgra', '-f', 'rawvideo', '-',
  ], stdoutEncoding: null);
  final bytes = res.stdout as List<int>;
  final probe = await Process.run('/opt/homebrew/bin/ffprobe',
      ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', video]);
  final dims = '${probe.stdout}'.trim().split(',').map(int.parse).toList();
  var (w, h) = (dims[0], dims[1]);
  if (rotate == 90 || rotate == 270) (w, h) = (h, w);
  if (w > h) {
    (w, h) = ((w * short / h).round() & ~1, short);
  } else {
    (w, h) = (short, (h * short / w).round() & ~1);
  }
  if (bytes.length != w * h * 4) {
    stderr.writeln('frame size mismatch: ${bytes.length} bytes for ${w}x$h');
    exit(1);
  }
  final frame = WatchFrame(w, h, WatchPixelFormat.bgra8888, [WatchPlane(Uint8List.fromList(bytes), w * 4, 4)]);
  final cfg = BoardWatchConfig(
      detectWhiteBalance: wb, reader: BoardReaderConfig(detectVMin: vmin, paperSMax: smax, erode: erode));
  final watcher = BoardWatcher(cfg)..rotation = (360 - rotate) % 360;
  final (full, sw, sh) = frame.cropRgba(PixRect(0, 0, w, h));
  final (up, uw, uh) = rotateRgba(full, sw, sh, watcher.rotation);
  if (wb) whiteBalance(up);
  stdout.writeln('frame ${w}x$h, upright ${uw}x$uh');
  for (final line in probeBoardCards(up, uw, uh, shortSide: short, cfg: cfg.reader)) {
    stdout.writeln(line);
  }
  final boxes = findBoardCards(up, uw, uh, shortSide: short, cfg: cfg.reader);
  stdout.writeln('row: ${boxes.length} cards ${boxes.join(' ')}');
  if (out != null) {
    final marked = Uint8List.fromList(up);
    for (final b in boxes) {
      for (var x = b.x0; x < b.x1; x++) {
        for (final y in [b.y0, b.y1 - 1]) {
          marked.setAll((y * uw + x) * 4, [0, 255, 0, 255]);
        }
      }
      for (var y = b.y0; y < b.y1; y++) {
        for (final x in [b.x0, b.x1 - 1]) {
          marked.setAll((y * uw + x) * 4, [0, 255, 0, 255]);
        }
      }
    }
    _ppm('$out/frame.ppm', marked, uw, uh);
  }
  // Force a job through the watcher to get the same crops the app makes.
  BoardJob? job;
  for (var i = 0; i <= cfg.stableDetections && job == null; i++) {
    job = watcher.onFrame(frame, i * 2000);
  }
  if (job == null) {
    stdout.writeln('no job (count ${watcher.count})');
    return;
  }
  for (var i = 0; i < job.cards.length; i++) {
    final c = job.cards[i];
    final r = readBoardCard(c.rgba, c.width, c.height, box: c.box, cfg: cfg.reader);
    stdout.writeln('card $i ${c.width}x${c.height} at ${c.box}: $r  ${jsonEncode(probeCard(c.rgba, c.width, c.height, cfg: cfg.reader))}');
    if (out != null) _ppm('$out/card_$i.ppm', c.rgba, c.width, c.height);
  }
}

void _ppm(String path, Uint8List rgba, int w, int h) {
  final o = BytesBuilder()..add(ascii.encode('P6\n$w $h\n255\n'));
  final rgb = Uint8List(w * h * 3);
  for (var i = 0, k = 0; i < w * h; i++) {
    rgb[k++] = rgba[i * 4];
    rgb[k++] = rgba[i * 4 + 1];
    rgb[k++] = rgba[i * 4 + 2];
  }
  o.add(rgb);
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(o.takeBytes());
}
