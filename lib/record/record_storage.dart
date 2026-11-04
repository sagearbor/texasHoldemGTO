/// Record the table: where sessions live on the phone and how they leave
/// it. One folder per session:
///
///   recordings/<id>/session.jsonl            the log (record_log.dart)
///   recordings/<id>/s01/000001-<utc ms>.jpg  stills, one folder per segment
///
/// Android keeps them in the app's external files folder
/// (/sdcard/Android/data/com.sagearbor.feltnotes.app/files/recordings), so
/// `adb pull` or a USB file browser reaches them; iOS in Documents, which
/// Info.plist shares with the Files app and Finder (UIFileSharingEnabled).
/// Nothing here is ever uploaded.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

import 'record_log.dart';

const sessionLogName = 'session.jsonl';

Future<Directory> recordingsRoot() async {
  Directory? base;
  if (Platform.isAndroid) {
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {}
  }
  base ??= await getApplicationDocumentsDirectory();
  final d = Directory('${base.path}/recordings');
  await d.create(recursive: true);
  return d;
}

/// `20261105-231502-K7QX`: sorts by start time, unique enough per phone.
String newSessionId(DateTime nowLocal, {Random? rng}) {
  String two(int v) => v.toString().padLeft(2, '0');
  const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = rng ?? Random.secure();
  final tag = String.fromCharCodes([for (var i = 0; i < 4; i++) abc.codeUnitAt(r.nextInt(abc.length))]);
  final d = nowLocal;
  return '${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}${two(d.second)}-$tag';
}

class StoredSession {
  final Directory dir;
  final RecordLogSummary summary;
  StoredSession(this.dir, this.summary);

  String get id => dir.path.split('/').last;
  File get log => File('${dir.path}/$sessionLogName');
}

/// Every session on the phone, newest first.
Future<List<StoredSession>> listSessions() async {
  final root = await recordingsRoot();
  final out = <StoredSession>[];
  await for (final e in root.list()) {
    if (e is! Directory) continue;
    final f = File('${e.path}/$sessionLogName');
    if (!f.existsSync()) continue;
    try {
      out.add(StoredSession(e, summarizeRecordLog(await f.readAsLines())));
    } catch (_) {
      // Unreadable: leave it for the Mac.
    }
  }
  out.sort((a, b) => b.id.compareTo(a.id));
  return out;
}

/// The newest session that was neither stopped nor closed (the app was
/// killed while recording), if any.
Future<StoredSession?> interruptedSession() async {
  try {
    for (final s in await listSessions()) {
      // Watch my cards recordings are closed by the next Watch session
      // (watch_recorder.dart), never resumed into Record the table.
      if (s.summary.interrupted && s.summary.start?['mode'] != 'watch') return s;
    }
  } catch (_) {}
  return null;
}

/// Bytes on disk under [dir].
Future<int> folderBytes(Directory dir) async {
  var n = 0;
  await for (final e in dir.list(recursive: true)) {
    if (e is File) n += await e.length();
  }
  return n;
}

/// One zip of the session in the cache folder, photos stored (JPEG does
/// not compress). [logOnly]: just the log (tiny; for a quick look).
/// Runs in a background isolate: a few GB take a while.
Future<File> zipSession(StoredSession s, {bool logOnly = false}) async {
  final tmp = await getTemporaryDirectory();
  final out = '${tmp.path}/feltnotes-${s.id}${logOnly ? '-log' : ''}.zip';
  final src = s.dir.path;
  await Isolate.run(() => zipFolder(src, out, logOnly: logOnly));
  return File(out);
}

/// Zips folder [src] into [out] under the folder's own name, stored.
Future<void> zipFolder(String src, String out, {bool logOnly = false}) async {
  final enc = ZipFileEncoder();
  enc.create(out, level: ZipFileEncoder.STORE);
  final files = logOnly
      ? [File('$src/$sessionLogName')]
      : [for (final e in Directory(src).listSync(recursive: true)) if (e is File) e];
  files.sort((a, b) => a.path.compareTo(b.path));
  final name = src.split('/').last;
  for (final f in files) {
    await enc.addFile(f, '$name/${f.path.substring(src.length + 1)}', ZipFileEncoder.STORE);
  }
  await enc.close();
}
