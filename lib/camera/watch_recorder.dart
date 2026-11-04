/// Watch my cards, "Also record the table": stills from the stream Watch
/// already has, saved as a Record-the-table session (record_storage.dart:
/// same folder, same session.jsonl format), so Recordings lists it and
/// Share zip exports it. The log carries the same lines Record writes
/// (session_start with `mode: watch`, camera_inventory, segment_start,
/// still_size, photo, status, warn) plus every Watch decision, peek and
/// action-pad tap (`watch_*` lines), for training seat / action detection
/// offline against the owner's own taps.
///
/// Saving never slows the reader: the JPEG is encoded on a native
/// background thread (record_native.dart) and a still is skipped while the
/// previous one is still encoding ([WatchStillPacer]).
library;

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../record/record_log.dart';
import '../record/record_native.dart';
import '../record/record_session.dart';
import '../record/record_storage.dart';
import 'lens.dart';

/// When the next normal-lens still is due: about one a second, never while
/// another still is encoding (a busy encoder skips the frame; nothing
/// queues). [WatchRecorder.save] claims and releases it.
class WatchStillPacer {
  final CapturePacer _p;
  int skippedBusy = 0;
  int _inFlight = 0;
  WatchStillPacer({int intervalMs = 1000}) : _p = CapturePacer(intervalMs);

  bool get busy => _inFlight > 0;

  /// True: save this frame now (synchronously start [WatchRecorder.save]).
  bool due(int nowMs) {
    if (!_p.due(nowMs)) return false;
    _p.done(); // the cadence is ours; busy is tracked here
    if (busy) {
      skippedBusy++;
      return false;
    }
    return true;
  }

  /// A still (normal or wide) started encoding.
  void claim() => _inFlight++;

  /// It is on disk (or failed).
  void done() {
    if (_inFlight > 0) _inFlight--;
  }
}

class WatchRecorder {
  final Directory dir;
  final RecordLogWriter log;
  final RecordSession session;
  final Stopwatch clock;
  final int quality;
  final WatchStillPacer pacer = WatchStillPacer();
  final Set<String> _sizes = {};
  bool _segmentLogged = false;
  bool _stopped = false;
  int? lastPhotoMs;
  int wideStills = 0;

  WatchRecorder._(this.dir, this.log, this.session, this.clock, this.quality);

  String get id => dir.path.split('/').last;
  bool get stopped => _stopped;

  /// A new session folder and its first lines. [extra] goes into
  /// session_start (Watch's own settings).
  static Future<WatchRecorder> start({
    required LensInfo lens,
    CameraController? cam,
    int quality = 80,
    Map<String, Object?> extra = const {},
  }) async {
    await closeInterruptedWatchSessions();
    // Its own clock: the log's monotonic `m` runs on across camera
    // restarts (Watch's frame clock starts again on each).
    final clock = Stopwatch()..start();
    final now = DateTime.now();
    final id = newSessionId(now);
    final dir = Directory('${(await recordingsRoot()).path}/$id');
    await dir.create(recursive: true);
    final log = RecordLogWriter(FileLineSink(File('${dir.path}/$sessionLogName')),
        wallMs: () => DateTime.now().millisecondsSinceEpoch, elapsedMs: () => clock.elapsedMilliseconds);
    final s = RecordSession(PhonePosition.other, lens);
    final app = await PackageInfo.fromPlatform().then((p) => '${p.version}+${p.buildNumber}', onError: (_) => null);
    log.write('session_start', {
      'session': id,
      'mode': 'watch',
      'app': app,
      'platform': defaultTargetPlatform.name,
      'device': await deviceInfo(),
      'rate': 1.0,
      'quality': quality,
      'lens_setting': CameraLens.choice.value.name,
      'role': 'watch',
      'tz_offset_min': now.timeZoneOffset.inMinutes,
      ...extra,
    });
    try {
      log.write('camera_inventory', {
        'open': lens.toJson(),
        'open_camera': cam?.description.name,
        'preview': cam?.value.previewSize == null
            ? null
            : [cam!.value.previewSize!.width.round(), cam.value.previewSize!.height.round()],
        'inventory': await cameraInventory(),
      });
    } catch (e) {
      log.write('camera_inventory', {'error': '$e'});
    }
    final r = WatchRecorder._(dir, log, s, clock, quality);
    // No framing check in Watch: straight to recording.
    r.write(s.framingDone(skipped: true));
    return r;
  }

  /// Interrupted Watch recordings (the app was killed) are closed when the
  /// next one starts: Record's resume offer skips them (record_storage.dart).
  static Future<void> closeInterruptedWatchSessions() async {
    try {
      for (final s in await listSessions()) {
        if (!s.summary.interrupted || s.summary.start?['mode'] != 'watch') continue;
        final sum = s.summary;
        RecordLogWriter(FileLineSink(s.log),
                wallMs: () => DateTime.now().millisecondsSinceEpoch,
                elapsedMs: () => 0,
                baseM: resumeBaseMs(
                    lastM: sum.lastM, lastWallMs: sum.lastWallMs, nowWallMs: DateTime.now().millisecondsSinceEpoch),
                run: sum.runs + 1)
            .write('closed', {'reason': 'interrupted', 'photos': sum.photos});
      }
    } catch (e) {
      debugPrint('watch recorder close: $e');
    }
  }

  void write(LogEntry e) {
    if (_stopped) return;
    try {
      log.write(e.$1, e.$2);
    } catch (err) {
      debugPrint('watch record log: $err');
    }
  }

  /// The first frame of a run: the segment's size and rotation.
  void onFirstFrame(CameraImage img, int rotation) {
    if (_segmentLogged) return;
    _segmentLogged = true;
    write(session.segmentStart(width: img.width, height: img.height, rotation: rotation));
  }

  /// Saves [img] (taken at [t] on the clock) as a still. [lensKind] /
  /// [zoom]: the lens it came from; [wide]: the excursion's timings.
  /// Release the pacer when done. Never throws.
  Future<void> save(CameraImage img, int t,
      {required int rotation, required String lensKind, double? zoom, Map<String, Object?>? wide}) async {
    pacer.claim();
    try {
      if (_stopped) return;
      final wall = DateTime.now().millisecondsSinceEpoch;
      final n = session.photos + 1;
      final rel = '${session.segment.folder}/${n.toString().padLeft(6, '0')}-$wall.jpg';
      final sw = Stopwatch()..start();
      final bytes = await encodeJpeg(img, '${dir.path}/$rel', quality: quality, rotation: rotation);
      if (bytes == null || _stopped) return;
      if (_sizes.add('$lensKind/${img.width}x${img.height}')) {
        write(('still_size', {
          'seg': session.segment.n,
          'lens': lensKind,
          'zoom': zoom,
          'w': img.width,
          'h': img.height,
          'rotation': rotation,
          'quality': quality,
        }));
      }
      if (wide != null) wideStills++;
      write(session.photoSaved(rel, bytes,
          width: img.width,
          height: img.height,
          encodeMs: sw.elapsedMilliseconds,
          lagMs: clock.elapsedMilliseconds - t,
          lens: lensKind,
          alt: wide));
      lastPhotoMs = clock.elapsedMilliseconds;
    } catch (e) {
      debugPrint('watch still: $e');
    } finally {
      pacer.done();
    }
  }

  /// The app went to the background / came back (camera released there).
  void setBackground(bool bg) {
    if (session.backgrounded == bg) return;
    write(session.setBackground(bg));
    // A new camera may stream another size: log the segment again.
    if (!bg) _segmentLogged = false;
  }

  void stop() {
    if (_stopped) return;
    for (final e in session.stop(durationMs: clock.elapsedMilliseconds)) {
      write(e);
    }
    _stopped = true;
  }
}

/// Free storage, phone temperature, charging: polled for the black screen
/// warnings and the record log, recording or not (3-4 hours plugged in).
class WatchConditions {
  int? battery;
  bool? charging;
  String thermal = 'unknown';
  int? free;

  Future<void> refresh(Directory? dir, Future<(int, bool?)?> Function() readBattery) async {
    try {
      final b = await readBattery();
      if (b != null) {
        battery = b.$1;
        charging = b.$2;
      }
    } catch (_) {}
    thermal = await thermalState();
    try {
      free = await freeBytes(dir ?? await recordingsRoot());
    } catch (_) {}
  }

  Map<String, Object?> toJson() =>
      {'battery': battery, 'charging': charging, 'thermal': thermal, 'free': free};
}

/// The black screen's warnings: Record's own rules for storage and heat,
/// and "no photo for 10 s" while recording ([msSincePhoto] non-null).
/// Never "unplugged": Watch has its own battery log and the owner plugs in.
List<RecordWarning> watchWarnings(WatchConditions c, {required int bytesPerHour, int? msSincePhoto}) =>
    recordWarnings(
        capturing: msSincePhoto != null,
        charging: null,
        msSincePhoto: msSincePhoto,
        freeBytes: c.free,
        bytesPerHour: bytesPerHour,
        thermal: c.thermal);
