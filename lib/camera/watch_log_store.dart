/// Watch my cards diagnostics log: one JSON object per line in the app's
/// private support folder. Bounded to the last [keepSessions] Watch
/// sessions (and [maxBytes]); never uploaded. The player can export it from
/// Settings or the Watch screen with the share sheet.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const watchLogName = 'watch_diagnostics.jsonl';

/// Keeps the lines of the last [keep] sessions (a session starts at a
/// `{"type":"session"...}` line), then drops whole sessions from the front
/// while the text is over [maxBytes]. Pure, unit-tested.
List<String> pruneWatchLog(List<String> lines, {int keep = 5, int maxBytes = 2000000}) {
  final starts = <int>[
    for (var i = 0; i < lines.length; i++)
      if (lines[i].startsWith('{"type":"session"')) i
  ];
  var from = starts.length > keep ? starts[starts.length - keep] : 0;
  int size(int f) => lines.skip(f).fold(0, (a, l) => a + l.length + 1);
  for (final s in starts) {
    if (s <= from) continue;
    if (size(from) <= maxBytes) break;
    from = s;
  }
  return lines.sublist(from);
}

class WatchLogStore {
  final int keepSessions;
  WatchLogStore({this.keepSessions = 5});

  File? _file;

  Future<File> _open() async =>
      _file ??= File('${(await getApplicationSupportDirectory()).path}/$watchLogName');

  /// Prunes old sessions and writes the session header.
  Future<void> startSession(Map<String, Object?> header) async {
    try {
      final f = await _open();
      if (await f.exists()) {
        final kept = pruneWatchLog(await f.readAsLines(), keep: keepSessions - 1);
        await f.writeAsString(kept.isEmpty ? '' : '${kept.join('\n')}\n');
      }
      await append({'type': 'session', ...header});
    } catch (e) {
      debugPrint('watch log: $e');
    }
  }

  Future<void> append(Map<String, Object?> record) async {
    try {
      final f = await _open();
      await f.writeAsString('${jsonEncode(record)}\n', mode: FileMode.append, flush: false);
    } catch (e) {
      debugPrint('watch log: $e');
    }
  }

  /// Opens the share sheet with the log file. Returns false when there is
  /// nothing to share yet.
  static Future<bool> export(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
    try {
      final f = File('${(await getApplicationSupportDirectory()).path}/$watchLogName');
      if (!await f.exists() || await f.length() == 0) return false;
      final text = await f.readAsString();
      final file = XFile.fromData(utf8.encode(text), mimeType: 'application/json', name: 'felt-notes-watch-log.jsonl');
      await Share.shareXFiles([file],
          fileNameOverrides: ['felt-notes-watch-log.jsonl'], sharePositionOrigin: origin);
      return true;
    } catch (e) {
      debugPrint('watch log export: $e');
      return false;
    }
  }
}
