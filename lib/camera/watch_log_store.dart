/// Watch my cards diagnostics log: one JSON object per line in the app's
/// private support folder. Bounded to the last [keepSessions] Watch
/// sessions (and [maxBytes]); never uploaded. The player can export it from
/// Settings or the Watch screen with the share sheet.
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

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

  /// Writes run one after another (a session's peeks, then its summary;
  /// the next session's pruning never races an append).
  Future<void> _chain = Future.value();

  Future<void> _serial(Future<void> Function() op) => _chain = _chain.then((_) => op()).catchError((Object e) {
        debugPrint('watch log: $e');
      });

  Future<File> _open() async =>
      _file ??= File('${(await getApplicationSupportDirectory()).path}/$watchLogName');

  /// Prunes old sessions and writes the session header.
  Future<void> startSession(Map<String, Object?> header) => _serial(() async {
        final f = await _open();
        final kept = await f.exists() ? pruneWatchLog(await f.readAsLines(), keep: keepSessions - 1) : <String>[];
        kept.add(jsonEncode({'type': 'session', ...header}));
        await f.writeAsString('${kept.join('\n')}\n');
      });

  Future<void> append(Map<String, Object?> record) => _serial(() async {
        final f = await _open();
        await f.writeAsString('${jsonEncode(record)}\n', mode: FileMode.append);
      });

  static Future<File> _logFile() async => File('${(await getApplicationSupportDirectory()).path}/$watchLogName');

  static String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}';
  }

  /// Saves the log where the player picks (Android: the system "save as"
  /// dialog, e.g. Downloads; iOS: Files). Returns false when there is
  /// nothing to save or it was cancelled.
  static Future<bool> saveToDevice() async {
    try {
      final f = await _logFile();
      if (!await f.exists() || await f.length() == 0) return false;
      final path = await FilePicker.platform.saveFile(
        fileName: 'felt-notes-watch-log-${_stamp()}.jsonl',
        bytes: await f.readAsBytes(),
      );
      return path != null;
    } catch (e) {
      debugPrint('watch log save: $e');
      return false;
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
