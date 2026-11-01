/// Record the table: the pure parts of a recording session, apart from the
/// camera and the screen. A session is a run of segments; each segment is
/// one phone position ("I moved" starts the next one after a fresh framing
/// check). [RecordSession] is the state machine and says what to log for
/// every step; [CapturePacer] decides when the next still is due;
/// [recordWarnings] and [viewMatch] feed the status screen.
library;

import 'dart:math' as math;
import 'dart:typed_data';

enum RecordPhase {
  /// The 10-second framing check over the live view (each segment starts
  /// with one).
  framing,
  recording,
  paused,
  stopped,
}

/// Where the phone sits, per segment, as the owner said in the framing
/// check (the offline seat model differs for each).
enum PhonePosition { end, side, other }

/// Which lens a segment used, as the camera reported it.
class LensInfo {
  /// `ultra_wide`, `wide` (the normal back lens) or `front`.
  final String kind;
  final String cameraName;

  /// Zoom asked for (Android: below 1.0 switches the logical camera to the
  /// ultra-wide) and the camera's minimum; null where not used.
  final double? zoom;
  final double? minZoom;
  const LensInfo(this.kind, this.cameraName, {this.zoom, this.minZoom});

  Map<String, Object?> toJson() => {
        'kind': kind,
        'camera': cameraName,
        if (zoom != null) 'zoom': zoom,
        if (minZoom != null) 'min_zoom': minZoom,
      };
}

class RecordSegment {
  final int n;
  final PhonePosition position;
  final LensInfo lens;
  int photos = 0;
  RecordSegment(this.n, this.position, this.lens);

  /// Folder of this segment's photos inside the session folder.
  String get folder => 's${n.toString().padLeft(2, '0')}';
}

/// One line to write: kind and fields (record_log.dart adds t / m / r).
typedef LogEntry = (String, Map<String, Object?>);

class RecordSession {
  RecordPhase _phase = RecordPhase.framing;
  final List<RecordSegment> segments = [];
  int marks = 0;
  int photos = 0;
  int photoBytes = 0;

  /// App in the background (the camera is released there): no photos,
  /// whatever the phase says.
  bool backgrounded = false;

  /// Starts with the first segment's framing check. [firstSegment] > 1
  /// when a session is resumed after the app was killed.
  RecordSession(PhonePosition position, LensInfo lens, {int firstSegment = 1, this.photos = 0, this.marks = 0}) {
    segments.add(RecordSegment(firstSegment, position, lens));
  }

  RecordPhase get phase => _phase;
  RecordSegment get segment => segments.last;
  bool get capturing => _phase == RecordPhase.recording && !backgrounded;

  void _need(Set<RecordPhase> ok, String what) {
    if (!ok.contains(_phase)) throw StateError('$what while ${_phase.name}');
  }

  /// The segment's first line (written when it starts framing).
  LogEntry segmentStart({int? width, int? height, int? rotation}) => (
        'segment_start',
        {
          'seg': segment.n,
          'position': segment.position.name,
          'lens': segment.lens.toJson(),
          if (width != null) 'w': width,
          if (height != null) 'h': height,
          if (rotation != null) 'rotation': rotation,
        }
      );

  /// Framing check over: [skipped] when the owner did not wait it out.
  LogEntry framingDone({bool skipped = false, Uint8List? refGrid}) {
    _need({RecordPhase.framing}, 'framingDone');
    _phase = RecordPhase.recording;
    return (
      'framing_done',
      {'seg': segment.n, 'skipped': skipped, if (refGrid != null) 'ref': refGrid.toList()}
    );
  }

  LogEntry pause() {
    _need({RecordPhase.recording}, 'pause');
    _phase = RecordPhase.paused;
    return ('pause', {'seg': segment.n});
  }

  LogEntry resume() {
    _need({RecordPhase.paused}, 'resume');
    _phase = RecordPhase.recording;
    return ('resume', {'seg': segment.n});
  }

  /// "I moved": the current segment ends, the next one starts with its own
  /// framing check (and may use another lens).
  List<LogEntry> moved(PhonePosition position, LensInfo lens) {
    _need({RecordPhase.recording, RecordPhase.paused, RecordPhase.framing}, 'moved');
    final end = ('segment_end', {'seg': segment.n, 'photos': segment.photos, 'reason': 'moved'});
    segments.add(RecordSegment(segment.n + 1, position, lens));
    _phase = RecordPhase.framing;
    return [end];
  }

  /// "Mark this hand": a bookmark for the offline review. Not while
  /// stopped.
  LogEntry mark() {
    _need({RecordPhase.recording, RecordPhase.paused, RecordPhase.framing}, 'mark');
    marks++;
    return ('mark', {'seg': segment.n, 'n': marks, 'photos': photos});
  }

  /// A still was saved as [file] (path inside the session folder).
  LogEntry photoSaved(String file, int bytes, {int? width, int? height, int? encodeMs, int? lagMs}) {
    photos++;
    photoBytes += bytes;
    segment.photos++;
    return (
      'photo',
      {
        'seg': segment.n,
        'n': photos,
        'f': file,
        'bytes': bytes,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (encodeMs != null) 'enc_ms': encodeMs,
        if (lagMs != null) 'lag_ms': lagMs,
      }
    );
  }

  List<LogEntry> stop({required int durationMs}) {
    _need({RecordPhase.recording, RecordPhase.paused, RecordPhase.framing}, 'stop');
    _phase = RecordPhase.stopped;
    return [
      ('segment_end', {'seg': segment.n, 'photos': segment.photos, 'reason': 'stop'}),
      ('stop', {'photos': photos, 'bytes': photoBytes, 'segments': segments.length, 'marks': marks, 'ms': durationMs}),
    ];
  }

  LogEntry setBackground(bool bg) {
    backgrounded = bg;
    return (bg ? 'background' : 'foreground', {'seg': segment.n, 'phase': _phase.name});
  }
}

/// When the next still is due: one every [intervalMs], never two at once
/// (a slow encode skips frames rather than queueing them).
class CapturePacer {
  int intervalMs;
  int? _lastMs;
  bool _busy = false;
  CapturePacer(this.intervalMs);

  /// True: take this frame (call [done] when it is on disk).
  bool due(int nowMs) {
    if (_busy) return false;
    final last = _lastMs;
    if (last != null && nowMs - last < intervalMs) return false;
    // Keep the cadence: a frame that arrives a little late does not push
    // every later one back.
    _lastMs = last == null || nowMs - last > 2 * intervalMs ? nowMs : last + intervalMs;
    _busy = true;
    return true;
  }

  void done() => _busy = false;

  void reset() {
    _lastMs = null;
    _busy = false;
  }
}

/// Photos per second the owner can pick, and the matching interval.
const recordRates = [1.0, 1.5, 2.0];
int intervalForRate(double perSecond) => (1000 / perSecond).round();

enum RecordWarning { unplugged, stalled, storageLow, hot }

/// The amber banner's reasons, most urgent first. [msSincePhoto] is null
/// before the first photo; [bytesPerHour] is the rate so far.
List<RecordWarning> recordWarnings({
  required bool capturing,
  required bool? charging,
  required int? msSincePhoto,
  required int? freeBytes,
  required int bytesPerHour,
  required String thermal,
}) {
  final out = <RecordWarning>[];
  if (thermal == 'serious' || thermal == 'critical') out.add(RecordWarning.hot);
  if (capturing && msSincePhoto != null && msSincePhoto > 10000) out.add(RecordWarning.stalled);
  if (freeBytes != null) {
    // Low: under 1 GB, or under 30 minutes at the current rate.
    final halfHour = bytesPerHour ~/ 2;
    if (freeBytes < 1 << 30 || freeBytes < halfHour) out.add(RecordWarning.storageLow);
  }
  if (charging == false) out.add(RecordWarning.unplugged);
  return out;
}

String warningText(RecordWarning w) => switch (w) {
      RecordWarning.unplugged => 'Not charging: plug the phone in for a long session.',
      RecordWarning.stalled => 'No photo saved for over 10 seconds.',
      RecordWarning.storageLow => 'Storage is running low.',
      RecordWarning.hot => 'The phone is hot: it may slow down or stop the camera.',
    };

/// How alike two coarse luma grids are, 0..1 (Pearson correlation, clamped
/// at 0). The framing check keeps one grid as the reference; a much lower
/// match later means the phone was knocked or the view is blocked. Null if
/// either grid is flat (a black or blank frame says nothing).
double? viewMatch(Uint8List ref, Uint8List cur) {
  if (ref.length != cur.length || ref.isEmpty) return null;
  final n = ref.length;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < n; i++) {
    ma += ref[i];
    mb += cur[i];
  }
  ma /= n;
  mb /= n;
  var sab = 0.0, saa = 0.0, sbb = 0.0;
  for (var i = 0; i < n; i++) {
    final a = ref[i] - ma, b = cur[i] - mb;
    sab += a * b;
    saa += a * a;
    sbb += b * b;
  }
  if (saa < n * 4 || sbb < n * 4) return null; // std dev under 2 grey levels
  return math.max(0, sab / math.sqrt(saa * sbb));
}

/// Human sizes for the status rows.
String bytesLabel(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
  return '${(b / 1024).toStringAsFixed(0)} KB';
}

String elapsedLabel(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}
