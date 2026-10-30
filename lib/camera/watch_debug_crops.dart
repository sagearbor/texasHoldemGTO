/// Watch my cards, TESTER TOOL (off by default): keeps the last crops the
/// card reader looked at, so a beta tester can send them in when the
/// reader misses cards on their phone. Images stay in the app's private
/// folder until shared or deleted; the toggle says so. The diagnostics log
/// never contains images.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 24-bit BMP of [rgba] (any image viewer opens it; no encoder needed).
Uint8List encodeBmp(Uint8List rgba, int w, int h) {
  final row = (w * 3 + 3) & ~3;
  final size = 54 + row * h;
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  out[0] = 0x42; // B
  out[1] = 0x4D; // M
  bd.setUint32(2, size, Endian.little);
  bd.setUint32(10, 54, Endian.little);
  bd.setUint32(14, 40, Endian.little);
  bd.setInt32(18, w, Endian.little);
  bd.setInt32(22, h, Endian.little); // bottom-up rows
  bd.setUint16(26, 1, Endian.little);
  bd.setUint16(28, 24, Endian.little);
  bd.setUint32(34, row * h, Endian.little);
  for (var y = 0; y < h; y++) {
    var o = 54 + (h - 1 - y) * row;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      out[o++] = rgba[i + 2];
      out[o++] = rgba[i + 1];
      out[o++] = rgba[i];
    }
  }
  return out;
}

class WatchDebugCrops {
  static const keep = 120;
  static const minGapMs = 500;
  int _lastMs = -1 << 40;

  static Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/watch_crops');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Saves one crop (at most one per [minGapMs]); [tag] goes in the name
  /// (e.g. what the reader saw). Keeps the newest [keep].
  Future<void> save(Uint8List rgba, int w, int h, int tMs, String tag) async {
    if (tMs - _lastMs < minGapMs || w == 0 || h == 0) return;
    _lastMs = tMs;
    try {
      final d = await _dir();
      final name = 'crop_${DateTime.now().millisecondsSinceEpoch}_$tag.bmp';
      await File('${d.path}/$name').writeAsBytes(encodeBmp(rgba, w, h));
      final files = (await d.list().toList()).whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files.take(files.length - keep < 0 ? 0 : files.length - keep)) {
        await f.delete();
      }
    } catch (e) {
      debugPrint('watch crops: $e');
    }
  }

  static Future<int> count() async {
    try {
      return (await (await _dir()).list().toList()).whereType<File>().length;
    } catch (_) {
      return 0;
    }
  }

  /// Shares the newest [max] crops. False when there are none.
  static Future<bool> share({int max = 60}) async {
    try {
      final files = (await (await _dir()).list().toList()).whereType<File>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      if (files.isEmpty) return false;
      await Share.shareXFiles([for (final f in files.take(max)) XFile(f.path, mimeType: 'image/bmp')]);
      return true;
    } catch (e) {
      debugPrint('watch crops share: $e');
      return false;
    }
  }

  static Future<void> deleteAll() async {
    try {
      final d = await _dir();
      await d.delete(recursive: true);
    } catch (_) {}
  }
}
