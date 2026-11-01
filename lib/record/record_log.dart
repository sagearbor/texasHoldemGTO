/// Record the table: the session log, one JSON object per line (JSONL).
///
/// Every line carries the wall clock in UTC to the millisecond (`t`, ISO
/// 8601) and a monotonic millisecond counter (`m`) that never goes back,
/// not even across an app restart that resumes the session (`r` counts the
/// runs). The photos are matched to hands offline by these two clocks, so
/// each line is written and flushed before the next one: after a crash
/// everything up to the last line is on disk. Pure Dart; the file sink is
/// injected so tests run in memory.
library;

import 'dart:convert';
import 'dart:io';

/// Where lines go. [FileLineSink] in the app, [MemoryLineSink] in tests.
abstract class LineSink {
  /// Appends [line] (no newline) and makes it durable before returning.
  void writeLine(String line);
}

class MemoryLineSink implements LineSink {
  final List<String> lines = [];
  @override
  void writeLine(String line) => lines.add(line);
}

/// Appends with flush per line. A line every second or so is cheap; an
/// open IOSink would lose its buffer when the app is killed.
class FileLineSink implements LineSink {
  final File file;
  FileLineSink(this.file);
  @override
  void writeLine(String line) => file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

/// `2026-11-05T23:15:02.123Z` for [ms] since the epoch.
String isoUtcMs(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

/// The monotonic counter at the start of a run: a fresh session starts at
/// 0; a resumed one continues after the last logged value, plus the wall
/// time that passed while the app was gone (never negative: the wall clock
/// may have been changed meanwhile).
int resumeBaseMs({int? lastM, int? lastWallMs, required int nowWallMs}) {
  if (lastM == null) return 0;
  final gap = lastWallMs == null ? 0 : nowWallMs - lastWallMs;
  return lastM + (gap > 0 ? gap : 0) + 1;
}

class RecordLogWriter {
  final LineSink sink;

  /// Wall clock (ms since epoch) and a monotonic elapsed-ms source. The app
  /// uses DateTime.now and a Stopwatch; tests pass fakes.
  final int Function() wallMs;
  final int Function() elapsedMs;

  /// Monotonic value at elapsed 0 (see [resumeBaseMs]).
  final int baseM;

  /// Run number: 1 for a new session, +1 each time it is resumed.
  final int run;
  int _lastM = -1;

  RecordLogWriter(this.sink, {required this.wallMs, required this.elapsedMs, this.baseM = 0, this.run = 1});

  int get lastM => _lastM;

  /// Writes one line `{t, m, r, k, ...fields}` and returns it decoded.
  Map<String, Object?> write(String kind, [Map<String, Object?> fields = const {}]) {
    var m = baseM + elapsedMs();
    // A Stopwatch never goes back; this only guards the injected sources.
    if (m <= _lastM) m = _lastM + 1;
    _lastM = m;
    final line = <String, Object?>{'t': isoUtcMs(wallMs()), 'm': m, 'r': run, 'k': kind, ...fields};
    sink.writeLine(jsonEncode(line));
    return line;
  }
}

/// What a session's log says about it, read back at launch (to offer
/// resume / close) and for the sessions list.
class RecordLogSummary {
  final String? sessionId;
  final int? startWallMs;
  final int? lastWallMs;
  final int? lastM;
  final int runs;
  final int photos;
  final int photoBytes;
  final int segments;
  final int marks;

  /// A `stop` (or `closed`) line was written: the session is finished.
  final bool closed;
  final Map<String, Object?>? start;

  const RecordLogSummary({
    this.sessionId,
    this.startWallMs,
    this.lastWallMs,
    this.lastM,
    this.runs = 0,
    this.photos = 0,
    this.photoBytes = 0,
    this.segments = 0,
    this.marks = 0,
    this.closed = false,
    this.start,
  });

  bool get interrupted => !closed && startWallMs != null;
  int get durationMs => (startWallMs == null || lastWallMs == null) ? 0 : lastWallMs! - startWallMs!;
}

/// Reads a log back. A torn last line (the app died mid-write) is skipped.
RecordLogSummary summarizeRecordLog(Iterable<String> lines) {
  String? id;
  int? start, last, lastM;
  var runs = 0, photos = 0, bytes = 0, segs = 0, marks = 0;
  var closed = false;
  Map<String, Object?>? startLine;
  for (final raw in lines) {
    if (raw.trim().isEmpty) continue;
    final Map<String, Object?> j;
    try {
      j = (jsonDecode(raw) as Map).cast<String, Object?>();
    } catch (_) {
      continue;
    }
    final t = DateTime.tryParse('${j['t']}')?.millisecondsSinceEpoch;
    if (t != null) last = t;
    final m = j['m'];
    if (m is int) lastM = m;
    final r = j['r'];
    if (r is int && r > runs) runs = r;
    switch (j['k']) {
      case 'session_start':
        id = j['session'] as String?;
        start = t;
        startLine = j;
      case 'segment_start':
        segs++;
      case 'photo':
        photos++;
        final b = j['bytes'];
        if (b is int) bytes += b;
      case 'mark':
        marks++;
      case 'stop':
      case 'closed':
        closed = true;
      case 'resume_session':
        closed = false;
    }
  }
  return RecordLogSummary(
    sessionId: id,
    startWallMs: start,
    lastWallMs: last,
    lastM: lastM,
    runs: runs,
    photos: photos,
    photoBytes: bytes,
    segments: segs,
    marks: marks,
    closed: closed,
    start: startLine,
  );
}
