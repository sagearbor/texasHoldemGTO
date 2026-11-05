/// "Watch my cards" (Beta): prop the phone up, peek at your cards as usual,
/// and the camera logs them for the hand being played. No taps.
///
/// Setup shows a live preview to aim with; Start turns the screen black
/// (camera still running: iOS cannot use the camera in the background) with
/// a tiny status dot. The pipeline (watch_pipeline.dart) looks at a coarse
/// brightness grid 5 times a second, speeds up while something changes, and
/// only runs the card reader (glyph_reader.dart, in a background isolate)
/// on a crop around a card-like change. A pair is logged after several
/// frames agree; WatchHandTracker decides fill / confirm / correct / new
/// hand; the cards are spoken only into earbuds (watch_voice.dart).
///
/// By default nothing is recorded or saved except the cards it reads and
/// numeric diagnostics (watch_log_store.dart); frames are dropped as soon
/// as they are processed. "Also record the table" (watch_recorder.dart)
/// keeps about one still a second from the same stream as a Record-the-
/// table session, and "Wide shots between peeks" (watch_wide.dart) adds an
/// ultra-wide still every few seconds while the gate is idle. The black
/// screen has a dim action pad (the logger's: tap call, swipe up raise,
/// swipe down undo, sideways next hand) for the hand being played.
library;

import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../homegame/home_game.dart' show PreAction;
import '../poker/cards.dart';
import '../record/lens_alternator.dart' show sampledMeanLuma;
import '../record/record_screen.dart' show RecordingsScreen;
import '../record/record_session.dart' show RecordWarning, warningText;
import '../ui/dev_mode.dart';
import '../ui/widgets/action_pad.dart';
import 'lens.dart';
import 'lens_camera.dart';
import 'snap_cards_screen.dart' show BetaBadge;
import 'watch_buzz.dart';
import 'watch_certainty.dart';
import 'watch_debug_crops.dart';
import 'watch_diagnostics.dart';
import 'glyph_reader.dart';
import 'watch_frame.dart';
import 'watch_health.dart';
import 'watch_log_store.dart';
import 'watch_pipeline.dart';
import 'watch_recorder.dart';
import 'watch_tracker.dart';
import 'watch_voice.dart';
import 'watch_wide.dart';
import 'watch_worker.dart';

/// Live camera streams exist only in the Android / iOS apps.
bool get watchModeSupported =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// What Watch mode needs from the hand logger.
abstract class WatchHost {
  /// Shared with the logger, so manual picks and Next hand reach it.
  WatchHandTracker get watchTracker;

  /// Number of the hand being played (for the chip).
  int get watchHandNumber;

  /// Fill or correct the cards of the hand being played.
  void watchSetCards(List<int> cards);

  /// Close the hand being played the normal way (default fold), then put
  /// [cards] on the next one, logged in the tracker with [episode]. Also in
  /// the first orbit of a learned-seat night (the next dealer is guessed in
  /// seat order). Returns false when the logger could not move on (no
  /// night running); the cards are then only put in the slots.
  bool watchNewHand(List<int> cards, {int? episode, int? scene});

  /// Next hand, from the black screen.
  void watchNextHand();

  /// Opens the card picker on [context]; the logger tells the tracker.
  Future<void> watchFixCards(BuildContext context);

  /// Your action for the hand being played (the logger's action pad):
  /// null = the default fold.
  PreAction? get watchPendingAction;

  /// Sets it, exactly as the logger's own pad does (null = undo).
  void watchSetAction(PreAction? action);
}

/// Device-only Watch settings (not in backups: they describe this phone).
class WatchSettings {
  static const voiceKey = 'watch_voice_v1';
  static const frontKey = 'watch_front_camera_v1';
  static const sharpKey = 'watch_sharp_v1';
  static const cropsKey = 'watch_debug_crops_v1';
  static const buzzKey = 'watch_buzz_v1';
  static const recordKey = 'watch_record_v1';
  static const wideKey = 'watch_wide_v1';

  static final voice = ValueNotifier<bool>(true);
  static final front = ValueNotifier<bool>(false);

  /// 1080p instead of 720p: smaller cards read better, more battery.
  static final sharp = ValueNotifier<bool>(false);

  /// Tester tool: keep the reader's crops on the phone (off by default).
  static final crops = ValueNotifier<bool>(false);

  /// Buzz a paired smartwatch on a read (off by default).
  static final buzz = ValueNotifier<bool>(false);

  /// Also record the table (stills into Recordings). Default: on in
  /// developer mode, else off.
  static final record = ValueNotifier<bool>(false);

  /// With recording: ultra-wide stills while no peek is going on.
  static final wide = ValueNotifier<bool>(true);

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    voice.value = p.getBool(voiceKey) ?? true;
    front.value = p.getBool(frontKey) ?? false;
    sharp.value = p.getBool(sharpKey) ?? false;
    crops.value = p.getBool(cropsKey) ?? false;
    buzz.value = p.getBool(buzzKey) ?? false;
    record.value = p.getBool(recordKey) ?? DevMode.on.value;
    wide.value = p.getBool(wideKey) ?? true;
  }

  static Future<void> set(ValueNotifier<bool> n, String key, bool v) async {
    n.value = v;
    (await SharedPreferences.getInstance()).setBool(key, v);
  }
}

/// True when the player picked "Just one photo" instead (the caller then
/// opens Snap my cards); only offered with [offerOnePhoto].
Future<bool> openWatchMode(BuildContext context, WatchHost host, {bool offerOnePhoto = false}) async {
  await WatchSettings.load();
  if (!context.mounted) return false;
  final r = await Navigator.of(context).push<bool>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => WatchScreen(host: host, offerOnePhoto: offerOnePhoto),
  ));
  return r == true;
}

const _deviceDegrees = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

/// Camera frame -> [WatchFrame] without copying the pixels.
WatchFrame watchFrameFromCamera(CameraImage img) {
  final planes = [
    for (final p in img.planes) WatchPlane(p.bytes, p.bytesPerRow, p.bytesPerPixel ?? 1),
  ];
  final bgra = img.format.group == ImageFormatGroup.bgra8888;
  return WatchFrame(img.width, img.height, bgra ? WatchPixelFormat.bgra8888 : WatchPixelFormat.yuv420, planes,
      // iOS delivers 420v (video range); Android YUV_420_888 is full range.
      videoRange: !bgra && Platform.isIOS);
}

class WatchScreen extends StatefulWidget {
  final WatchHost host;

  /// Shows "Just one photo" on the setup page (pops with true).
  final bool offerOnePhoto;
  const WatchScreen({super.key, required this.host, this.offerOnePhoto = false});

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> with WidgetsBindingObserver {
  CameraController? _cam;
  GlyphWorker? _worker;
  String? _error;
  bool _watching = false;

  // White balance runs in the reader isolate (see _onImage), not here.
  static const _cfg = WatchConfig(whiteBalance: false);
  WatchPipeline _pipe = WatchPipeline(_cfg);
  final Stopwatch _clock = Stopwatch();
  WatchStatus _status = WatchStatus.idle;

  final WatchVoice _voice = WatchVoice();
  final WatchLogStore _log = WatchLogStore();
  final WatchDebugCrops _crops = WatchDebugCrops();
  final WatchBuzz _buzz = WatchBuzz();
  int _peeksLogged = 0;

  /// The stream's actual format is logged once per session (frame size,
  /// planes, rotation): the first phone test could not tell them apart.
  bool _streamLogged = false;
  final List<(int, int)> _battery = [];
  Timer? _ticker;

  /// Is the pipeline running at all (frames coming, reader working)? A
  /// problem buzzes, shows on the black screen and goes in the log.
  final WatchHealth _health = WatchHealth();
  Timer? _healthTicker;

  /// Last logged pair and what happened, for the chip.
  List<int>? _lastCards;
  String _lastWhat = '';
  bool _waitDealer = false;

  /// "Also record the table": open for the whole stay on this screen
  /// (camera restarts and the background continue it; Stop ends it).
  WatchRecorder? _rec;

  /// "Wide shots between peeks" on the camera open now, and why they went
  /// off for this recording (a failed switch).
  WideExcursion? _wide;
  String? _wideOff;
  bool _shownAway = false;

  /// Storage / heat (and, recording, "no photo"): polled every 30 s.
  final WatchConditions _cond = WatchConditions();
  List<RecordWarning> _warnings = const [];
  final Set<RecordWarning> _loggedWarnings = {};

  /// Frame-clock ms of the last action-pad gesture (see [_carryAction]).
  int? _padAtMs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopWatching();
    _cam?.dispose();
    _worker?.dispose();
    _voice.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // iOS stops the camera in the background: release it, start again on
    // return.
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      final c = _cam;
      if (c == null || _opening) return;
      final was = _watching;
      _stopWatching(end: false);
      _watching = was; // resume into the same mode
      _cam = null;
      c.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _cam == null) {
      _initCamera();
    }
  }

  /// The permission prompt makes the app "inactive" while the camera is
  /// still opening: do not open a second one on "resumed".
  bool _opening = false;

  /// The lens the camera opened on (the "Lens: ..." label and the log).
  LensInfo? _lens;

  /// Watch reads small card corners: the normal lens unless Settings →
  /// Camera lens says Widest.
  bool get _widest => useWidest(CameraLens.choice.value, featureDefault: false);

  Future<void> _initCamera() async {
    if (_opening) return;
    _opening = true;
    try {
      final (c, lens) = await openCameraWithLens(
        direction: WatchSettings.front.value ? CameraLensDirection.front : CameraLensDirection.back,
        widest: _widest,
        preset: WatchSettings.sharp.value ? ResolutionPreset.veryHigh : ResolutionPreset.high,
        // 15 fps (iOS honours it; Android drops the extra frames in Dart).
        fps: 15,
        imageFormatGroup: ImageFormatGroup.yuv420,
        fallbackToAny: true,
      );
      if (!mounted) {
        c.dispose();
        return;
      }
      c.addListener(() {
        if (_watching && identical(c, _cam) && c.value.hasError) {
          _report(_health.onFailure('Camera error'), detail: c.value.errorDescription);
        }
      });
      _worker ??= await GlyphWorker.spawn((await rootBundle.load('assets/data/glyph_cnn.bin')).buffer.asUint8List());
      if (!mounted) return;
      setState(() {
        _cam = c;
        _lens = lens;
        _error = null;
      });
      if (_watching) {
        _watching = false;
        await _startWatching();
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera unavailable ($e)');
      // Resuming into the black screen: say so there, not only in setup.
      if (_watching) _report(_health.onFailure('Camera would not start'), detail: e);
    } finally {
      _opening = false;
    }
  }

  Future<void> _startWatching() async {
    final c = _cam;
    if (c == null || _watching) return;
    _pipe = WatchPipeline(_cfg);
    _padAtMs = null;
    _peeksLogged = 0;
    _streamLogged = false;
    _battery.clear();
    _clock
      ..reset()
      ..start();
    setState(() => _watching = true);
    WakelockPlus.enable();
    await _log.startSession({
      'start': DateTime.now().toIso8601String(),
      'platform': defaultTargetPlatform.name,
      'preset': WatchSettings.sharp.value ? '1080p' : '720p',
      'lens': WatchSettings.front.value ? 'front' : 'back',
      'lens_setting': CameraLens.choice.value.name,
      if (_lens != null) 'lens_info': _lens!.toJson(),
      'voice': WatchSettings.voice.value,
    });
    _sampleBattery();
    if (WatchSettings.voice.value) await _voice.refresh();
    await _startRecording(c);
    unawaited(_refreshConditions());
    _ticker = Timer.periodic(const Duration(seconds: 10), (t) {
      _drainPeeks();
      if (WatchSettings.voice.value) _voice.refresh();
      if (t.tick % 60 == 0) _sampleBattery(); // every 10 minutes
      if (t.tick % 3 == 0) unawaited(_refreshConditions());
      if (t.tick % 6 == 0) _writeStatus();
    });
    _health.start(_clock.elapsedMilliseconds);
    _healthTicker = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_watching) _report(_health.check(_clock.elapsedMilliseconds));
    });
    try {
      await c.startImageStream(_onImage);
    } catch (e) {
      _report(_health.onFailure('Camera stream would not start'), detail: e);
    }
  }

  /// Opens (or, after a camera restart, continues) the recording, and sets
  /// up wide shots on camera [c] when they can work: Android, back lens,
  /// the normal lens open with an ultra-wide reachable by zoom.
  Future<void> _startRecording(CameraController c) async {
    if (!WatchSettings.record.value) return;
    final lens = _lens;
    if (lens == null) return;
    var rec = _rec;
    if (rec == null) {
      try {
        rec = await WatchRecorder.start(lens: lens, cam: c, extra: {
          'watch': {
            'preset': WatchSettings.sharp.value ? '1080p' : '720p',
            'lens': WatchSettings.front.value ? 'front' : 'back',
            'voice': WatchSettings.voice.value,
            'buzz': WatchSettings.buzz.value,
            'wide_shots': WatchSettings.wide.value,
          },
        });
      } catch (e) {
        _log.append({'type': 'error', 'what': 'recording would not start', 'detail': '$e'});
        return;
      }
      if (!mounted || !_watching) {
        rec.stop();
        return;
      }
      _rec = rec;
    } else {
      rec.setBackground(false);
    }
    _wide = null;
    final min = lens.minZoom;
    final canWide = WatchSettings.wide.value &&
        _wideOff == null &&
        Platform.isAndroid &&
        !WatchSettings.front.value &&
        lens.kind == 'wide' &&
        min != null &&
        min < 1.0;
    if (WatchSettings.wide.value && !canWide && _wideOff == null) {
      rec.write(('wide_unavailable', {'lens': lens.toJson(), 'front': WatchSettings.front.value}));
    }
    if (!canWide) return;
    _wide = WideExcursion(
      setZoom: c.setZoomLevel,
      nowMs: () => _clock.elapsedMilliseconds,
      wideZoom: min,
      onEvent: (k, f) {
        _rec?.write((k, {'seg': _rec?.session.segment.n, ...f}));
        if (k == 'wide_off') {
          _wideOff = _wide?.offReason ?? 'off';
          _log.append({'type': 'wide_off', ...f, 'tMs': _clock.elapsedMilliseconds});
          if (mounted) setState(() {});
        }
      },
    );
    rec.write(('wide_start', {'wide_zoom': min, 'interval_ms': _wide!.intervalMs, 'idle_ms': _wide!.idleMs}));
  }

  Future<void> _refreshConditions() async {
    await _cond.refresh(_rec?.dir, () async {
      final b = Battery();
      final level = await b.batteryLevel;
      final st = await b.batteryState;
      return (
        level,
        st == BatteryState.charging || st == BatteryState.full
            ? true
            : st == BatteryState.discharging
                ? false
                : null
      );
    });
    if (!mounted || !_watching) return;
    _updateWarnings();
  }

  void _updateWarnings() {
    final rec = _rec;
    final ms = rec?.clock.elapsedMilliseconds ?? 0;
    final perHour = rec == null || ms < 60000 || rec.session.photos == 0
        ? (rec == null ? 0 : 1 << 30) // ~1 GB/h guess until measured
        : (rec.session.photoBytes * 3600000 / ms).round();
    final since = rec == null ? null : ms - (rec.lastPhotoMs ?? 0);
    final w = watchWarnings(_cond, bytesPerHour: perHour, msSincePhoto: since);
    for (final x in w) {
      if (_loggedWarnings.add(x)) {
        rec?.write(('warn', {'what': x.name, 'on': true}));
        _log.append({'type': 'warn', 'what': x.name, 'tMs': _clock.elapsedMilliseconds});
        // Once, gently: these do not stop the reading.
        HapticFeedback.heavyImpact();
        if (WatchSettings.voice.value) _voice.say(warningText(x)).ignore();
      }
    }
    for (final x in _loggedWarnings.difference(w.toSet()).toList()) {
      _loggedWarnings.remove(x);
      rec?.write(('warn', {'what': x.name, 'on': false}));
    }
    setState(() => _warnings = w);
  }

  /// Under 200 MB free: stop saving stills (the reader goes on).
  bool get _storageOk => _cond.free == null || _cond.free! > 200 * 1024 * 1024;

  void _writeStatus() {
    final rec = _rec;
    if (rec == null) return;
    final ex = _wide;
    rec.write(('status', {
      'seg': rec.session.segment.n,
      'phase': rec.session.phase.name,
      'photos': rec.session.photos,
      'bytes': rec.session.photoBytes,
      ..._cond.toJson(),
      'bg': rec.session.backgrounded,
      'skipped_busy': rec.pacer.skippedBusy,
      'watch': {
        'peeks': _pipe.peeks.length,
        'reads': _pipe.counts.read,
        'hand': widget.host.watchHandNumber,
        if (_health.problem != null) 'problem': _health.problem,
      },
      'wide': ex == null
          ? {'on': false, if (_wideOff != null) 'off': _wideOff}
          : {'on': !ex.off, 'excursions': ex.excursions, 'stills': ex.stills, 'aborts': ex.aborts, 'saved': rec.wideStills},
    }));
  }

  /// A new pipeline problem: buzz the phone (and say it in the earbuds),
  /// show it on the black screen, log it.
  void _report(String? problem, {Object? detail}) {
    if (problem == null) return;
    debugPrint('watch problem: $problem ($detail)');
    _log.append({
      'type': 'error',
      'what': problem,
      if (detail != null) 'detail': '$detail',
      'tMs': _clock.elapsedMilliseconds,
      'at': DateTime.now().toIso8601String(),
    });
    _rec?.write(('watch_error', {'what': problem, if (detail != null) 'detail': '$detail'}));
    () async {
      for (var i = 0; i < 3; i++) {
        await HapticFeedback.heavyImpact();
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }()
        .ignore();
    if (WatchSettings.voice.value) _voice.say('Watch my cards stopped: $problem. Check the phone.').ignore();
    if (mounted) setState(() {});
  }

  /// [end]: the owner stopped (or left): the recording ends too. Else the
  /// camera is only going away for a while (background, restart).
  void _stopWatching({bool end = true}) {
    if (!_watching) return;
    _watching = false;
    _ticker?.cancel();
    _ticker = null;
    _healthTicker?.cancel();
    _healthTicker = null;
    final c = _cam;
    final ex = _wide;
    _wide = null;
    if (ex != null) {
      final away = ex.away;
      ex.stop(end ? 'stopped' : 'camera released');
      // Never leave the camera on the ultra-wide for the next start.
      if (away && c != null) c.setZoomLevel(1.0).ignore();
    }
    _shownAway = false;
    if (c != null && c.value.isStreamingImages) c.stopImageStream().ignore();
    WakelockPlus.disable();
    final t = _clock.elapsedMilliseconds;
    _pipe.flush(t);
    _drainPeeks();
    _writeStatus();
    if (end) {
      _rec?.stop();
      _rec = null;
      _wideOff = null;
    } else {
      _rec?.setBackground(true);
    }
    _sampleBattery().then((_) {
      final s = WatchSessionSummary(t, _pipe.counts, _pipe.peeks, battery: List.of(_battery));
      _log.append({...s.toJson(), 'end': DateTime.now().toIso8601String()});
    });
  }

  Future<void> _sampleBattery() async {
    try {
      final level = await Battery().batteryLevel;
      _battery.add((_clock.elapsedMilliseconds, level));
    } catch (_) {
      // Simulator / no battery: skip.
    }
  }

  void _drainPeeks() {
    while (_peeksLogged < _pipe.peeks.length) {
      final j = _pipe.peeks[_peeksLogged++].toJson();
      _log.append(j);
      _rec?.write(('watch_peek', j));
    }
  }

  void _onImage(CameraImage img) {
    if (!_watching) return;
    final t = _clock.elapsedMilliseconds;
    final hadProblem = _health.problem;
    _health.onFrame(t);
    if (hadProblem != null && _health.problem == null && mounted) setState(() {});
    final c = _cam;
    if (c != null) {
      final front = c.description.lensDirection == CameraLensDirection.front;
      if (Platform.isIOS) {
        // The iOS plugin turns its stream to the device orientation already
        // and mirrors the front lens.
        _pipe.rotation = 0;
        _pipe.mirror = front;
      } else {
        // Android frames come in sensor orientation: turn crops upright
        // for however the phone is propped (portrait or landscape).
        _pipe.rotation = uprightRotation(
            c.description.sensorOrientation, _deviceDegrees[c.value.deviceOrientation] ?? 0,
            front: front);
        _pipe.mirror = false;
      }
    }
    if (!_streamLogged && c != null) {
      _streamLogged = true;
      _log.append({
        'type': 'stream',
        'width': img.width,
        'height': img.height,
        'format': img.format.group.name,
        'raw': '${img.format.raw}',
        'planes': [
          for (final p in img.planes) {'bytesPerRow': p.bytesPerRow, 'bytesPerPixel': p.bytesPerPixel, 'len': p.bytes.length}
        ],
        'sensorOrientation': c.description.sensorOrientation,
        'deviceOrientation': c.value.deviceOrientation.name,
        'rotation': _pipe.rotation,
        'mirror': _pipe.mirror,
      });
    }
    final rec = _rec;
    if (rec != null && !_recordFrame(rec, img, t)) return;
    final job = _pipe.onFrame(watchFrameFromCamera(img), t);
    _setStatus(_pipe.status(t));
    for (final (_, seen) in _pipe.lookEnds) {
      final d = widget.host.watchTracker
          .onLookEnd(seen, DateTime.now().millisecondsSinceEpoch, scene: _pipe.sceneEpoch);
      if (d.action == WatchAction.newHandUnread) _apply(d, _pipe.cardEpisode);
    }
    _pipe.lookEnds.clear();
    if (job == null) return;
    final sw = Stopwatch()..start();
    _worker!.read(job.rgba, job.width, job.height, tta: _pipe.cfg.tta, scaleShortSide: job.scaleShortSide, warmLight: _pipe.cfg.warmLight, balance: true,
            ringPaperMin: _pipe.cfg.ringPaperMin, maxBlobs: _pipe.cfg.maxBlobs, findBoard: _pipe.cfg.findBoard)
        .then((r) {
      if (!mounted || !_watching) return;
      if (WatchSettings.crops.value && DevMode.on.value) {
        final tag = r.hero.isEmpty ? 'none' : r.hero.map((c) => '${cardToString(c.card)}${(c.score * 100).round()}').join('-');
        _crops.save(job.rgba, job.width, job.height, job.tMs, tag);
      }
      final wasBroken = _health.problem == WatchHealth.readerBroken;
      _health.onReadOk();
      if (wasBroken) setState(() {});
      final pair = _pipe.onRead(job, r, readMs: sw.elapsedMilliseconds);
      _setStatus(_pipe.status(_clock.elapsedMilliseconds));
      if (pair != null) _onPair(pair, _pipe.lastEvidence);
    }, onError: (Object e) {
      debugPrint('watch reader: $e');
      _pipe.onRead(job, GlyphReadResult.empty);
      if (_watching) _report(_health.onReadError(), detail: e);
    });
  }

  /// Recording: wide shots and the ~1/s still. False when the frame is not
  /// for the card reader (switching lenses, or the ultra-wide).
  bool _recordFrame(WatchRecorder rec, CameraImage img, int t) {
    final rotation = _pipe.rotation;
    rec.onFirstFrame(img, rotation);
    final ex = _wide;
    if (ex != null) {
      final quiet = _pipe.status(t) == WatchStatus.idle ? t - _pipe.lastCardLikeMs : 0;
      final use = ex.onFrame(t,
          quietMs: quiet,
          luma: ex.wantsLuma ? sampledMeanLuma(img.planes.first.bytes) : null,
          grid: ex.wantsGrid ? watchFrameFromCamera(img).lumaGrid(16, 9) : null);
      if (ex.away != _shownAway && mounted) setState(() => _shownAway = ex.away);
      if (use == WideUse.wideStill && _storageOk) {
        unawaited(rec.save(img, rec.clock.elapsedMilliseconds,
            rotation: rotation, lensKind: 'ultra_wide', zoom: ex.wideZoom, wide: {'excursion': ex.excursions}));
      }
      if (use != WideUse.read) return false;
    }
    final now = rec.clock.elapsedMilliseconds;
    if (_storageOk && rec.pacer.due(now)) {
      final lens = _lens;
      unawaited(rec.save(img, now,
          rotation: rotation,
          lensKind: WatchSettings.front.value ? 'front' : (lens?.kind ?? 'wide'),
          zoom: lens?.zoom ?? 1.0));
    }
    return true;
  }

  void _setStatus(WatchStatus s) {
    if (s != _status && mounted) setState(() => _status = s);
  }

  void _onPair(List<int> pair, PairEvidence? evidence) {
    final h = widget.host;
    // The tracker runs on wall-clock ms (the logger's manual picks use it).
    final episode = _pipe.cardEpisode;
    _apply(
        h.watchTracker.onRead(pair, DateTime.now().millisecondsSinceEpoch,
            episode: episode, scene: _pipe.sceneEpoch, evidence: evidence),
        episode);
  }

  void _apply(WatchDecision d, int episode) {
    final h = widget.host;
    _pipe.noteDecision(d);
    // Every decision into the recording, with the hand it was for.
    _rec?.write(('watch_decision', {
      'action': d.action.name,
      'cards': d.cards.map(cardToString).join(' '),
      'hand': h.watchHandNumber,
      'episode': episode,
      'scene': _pipe.sceneEpoch,
      'certainty': d.certainty,
      if (d.evidence != null) ...d.evidence!.toJson(),
    }));
    switch (d.action) {
      case WatchAction.fill:
      case WatchAction.correct:
        h.watchSetCards(d.cards);
      case WatchAction.newHand:
      case WatchAction.newHandUnread:
        _pipe.votesAfter(d);
        final carry = _carryAction();
        _waitDealer = !h.watchNewHand(d.cards, episode: episode, scene: _pipe.sceneEpoch);
        if (carry != null) {
          h.watchSetAction(carry);
          _rec?.write(('watch_action_moved', {'action': carry.name, 'hand': h.watchHandNumber}));
        }
      case WatchAction.confirm:
      case WatchAction.ignore:
        return;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _lastCards = d.action == WatchAction.newHandUnread ? null : d.cards;
      _lastWhat = switch (d.action) {
        WatchAction.correct => 'corrected',
        WatchAction.newHand => 'new hand',
        WatchAction.newHandUnread => 'new hand, cards not read',
        _ => 'logged',
      };
    });
    // Every logged pair's certainty and its raw parts, to calibrate it
    // against the true cards later (watch_certainty.dart).
    final ev = d.evidence;
    if (ev != null) {
      _log.append({
        'type': 'decision',
        't': _clock.elapsedMilliseconds,
        'action': d.action.name,
        'cards': d.cards.map(cardToString).join(' '),
        ...ev.toJson(),
      });
    }
    if (WatchSettings.buzz.value) _buzz.buzz(d.action, certainty: d.certainty);
    final text = spokenDecision(d);
    if (text != null && WatchSettings.voice.value) _voice.say(text);
  }

  /// A pad action given after the peek that turned out to start a new hand
  /// was meant for the new hand (the reader was a beat slower than the
  /// tap): take it off the closing hand and return it, to put on the new
  /// one. Null otherwise.
  PreAction? _carryAction() {
    final at = _padAtMs;
    final a = widget.host.watchPendingAction;
    final peek = _pipe.currentPeek ?? (_pipe.peeks.isEmpty ? null : _pipe.peeks.last);
    if (at == null || a == null || peek == null || at < peek.startMs) return null;
    widget.host.watchSetAction(null);
    return a;
  }

  /// The pad on the black screen: the logger's own gesture, on the hand
  /// being played.
  void _padAction(PreAction? a) {
    final h = widget.host;
    h.watchSetAction(a);
    _padAtMs = _clock.elapsedMilliseconds;
    final f = {'action': a?.name ?? 'undo', 'hand': h.watchHandNumber, 'cards_read': _lastCards != null};
    _rec?.write(('watch_action', f));
    _log.append({'type': 'action', 't': _clock.elapsedMilliseconds, ...f});
    setState(() {});
  }

  Future<void> _fix() async {
    await widget.host.watchFixCards(context);
    if (!mounted) return;
    setState(() {
      _lastCards = widget.host.watchTracker.cards;
      _lastWhat = 'fixed';
    });
  }

  void _nextHand() {
    _rec?.write(('watch_next_hand', {'hand': widget.host.watchHandNumber}));
    widget.host.watchNextHand();
    _pipe.resetVotes();
    setState(() {
      _lastCards = null;
      _waitDealer = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _watching ? _black(context) : _setup(context);
  }

  // ---------------------------------------------------------------- setup

  Widget _setup(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = _cam;
    return Scaffold(
      appBar: AppBar(
          title: const Row(children: [
        Flexible(child: Text('Watch my cards', overflow: TextOverflow.ellipsis)),
        SizedBox(width: 8),
        BetaBadge(),
      ])),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Text(
            'Prop the phone up beside you, camera towards your cards, about an arm\'s length '
            'away, where it sees the corners when you peek. Then peek as usual: the cards are '
            'logged for this hand, no taps.',
            style: t.bodyMedium),
        if (widget.offerOnePhoto)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('watch-one-photo'),
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.photo_camera_outlined, size: 18),
              label: const Text('Just one photo'),
            ),
          ),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 3 / 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ColoredBox(
              color: Colors.black,
              child: _error != null
                  ? Center(child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)))
                  : c == null || !c.value.isInitialized
                      ? const Center(child: CircularProgressIndicator())
                      : Center(child: CameraPreview(c)),
            ),
          ),
        ),
        if (_lens != null) ...[
          const SizedBox(height: 4),
          Text(lensLine(_lens!, widest: _widest && !WatchSettings.front.value),
              key: const Key('watch-lens'), style: t.bodySmall),
        ],
        const SizedBox(height: 8),
        Text('Aim with this preview: peek once and check your card corners are in view and sharp.',
            style: t.bodySmall),
        const SizedBox(height: 8),
        ValueListenableBuilder(
          valueListenable: WatchSettings.voice,
          builder: (_, v, __) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Say the cards in my earbuds'),
            subtitle: const Text('Quietly, and only through earbuds or headphones: never the speaker'),
            value: v,
            onChanged: (x) => WatchSettings.set(WatchSettings.voice, WatchSettings.voiceKey, x),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: WatchSettings.buzz,
          builder: (_, v, __) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Buzz my watch'),
            subtitle: const Text('One buzz when your cards are read (with how sure it is, '
                'usually 65-80%: peek again when it is well below that), two when corrected. The '
                'notification never shows the cards. Apple Watch: only while the iPhone is locked, '
                'so not during Watch mode.'),
            value: v,
            onChanged: (x) async {
              if (x && !await _buzz.requestPermission()) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Notifications are off for Felt Notes: allow them to buzz')));
                }
                return;
              }
              await WatchSettings.set(WatchSettings.buzz, WatchSettings.buzzKey, x);
            },
          ),
        ),
        ValueListenableBuilder(
          valueListenable: WatchSettings.front,
          builder: (_, v, __) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use the front camera'),
            value: v,
            onChanged: (x) async {
              await WatchSettings.set(WatchSettings.front, WatchSettings.frontKey, x);
              await _restartCamera();
            },
          ),
        ),
        ValueListenableBuilder(
          valueListenable: WatchSettings.sharp,
          builder: (_, v, __) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sharper camera'),
            subtitle: const Text('Helps when the phone is far from your cards; uses more battery'),
            value: v,
            onChanged: (x) async {
              await WatchSettings.set(WatchSettings.sharp, WatchSettings.sharpKey, x);
              await _restartCamera();
            },
          ),
        ),
        ValueListenableBuilder(
          valueListenable: WatchSettings.record,
          builder: (_, v, __) => Column(children: [
            SwitchListTile(
              key: const Key('watch-record'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Also record the table'),
              subtitle: const Text('Keeps about one photo a second from this camera on the phone, for '
                  'reviewing the night later (Recordings below; Share zip exports it). Sharper camera '
                  'gives 1080p photos.'),
              value: v,
              onChanged: (x) => WatchSettings.set(WatchSettings.record, WatchSettings.recordKey, x),
            ),
            if (v)
              ValueListenableBuilder(
                valueListenable: WatchSettings.wide,
                builder: (_, w, __) => SwitchListTile(
                  key: const Key('watch-wide'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Wide shots between peeks'),
                  subtitle: const Text('While you are not peeking, every few seconds a quick photo on the '
                      'ultra-wide lens (Android). Cards are never read from it.'),
                  value: w,
                  onChanged: (x) => WatchSettings.set(WatchSettings.wide, WatchSettings.wideKey, x),
                ),
              ),
          ]),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('watch-recordings'),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const RecordingsScreen())),
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('Recordings & export'),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: c == null ? null : _startWatching,
          icon: const Icon(Icons.visibility_outlined),
          label: const Text('Start watching'),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder(
          valueListenable: WatchSettings.record,
          builder: (_, rec, __) => Text(
              'The screen goes black and stays on (the camera only works while the app is open). '
              '${rec ? 'Photos are kept on this phone only, never uploaded. ' : 'Nothing is recorded: each frame is dropped once checked, only the cards it reads are kept. '}'
              'If it is unsure it logs nothing; the card slots always work by hand. '
              'The dim pad at the bottom logs your action like the logger\'s: do nothing = fold, '
              'tap = call, swipe up = raise, swipe down = undo, sideways = next hand.',
              style: t.bodySmall),
        ),
        // Tester tools: developer mode only (About → tap the version 7 times).
        if (DevMode.on.value) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final ok = await WatchLogStore.export(context);
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('No Watch diagnostics yet')));
                }
              },
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('Share diagnostics log'),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final ok = await WatchLogStore.saveToDevice();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(ok ? 'Diagnostics log saved' : 'Nothing saved')));
                }
              },
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('Save diagnostics log to device'),
            ),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Tester tools', style: t.labelLarge),
            children: [
              ValueListenableBuilder(
                valueListenable: WatchSettings.crops,
                builder: (_, v, __) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep what the reader looked at'),
                  subtitle: const Text('Saves the last 120 crops around your cards on this phone, to send '
                      'in when cards are missed. They may show the table or other hands. Off by default; '
                      'nothing leaves the phone unless you share it.'),
                  value: v,
                  onChanged: (x) => WatchSettings.set(WatchSettings.crops, WatchSettings.cropsKey, x),
                ),
              ),
              Row(children: [
                TextButton.icon(
                  onPressed: () async {
                    final ok = await WatchDebugCrops.share();
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No crops saved')));
                    }
                  },
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Share crops'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await WatchDebugCrops.deleteAll();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Crops deleted')));
                    }
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete crops'),
                ),
              ]),
            ],
          ),
        ],
      ]),
    );
  }

  Future<void> _restartCamera() async {
    final c = _cam;
    setState(() => _cam = null);
    await c?.dispose();
    await _initCamera();
  }

  /// From the black screen after a problem: a fresh camera and session,
  /// back into watching.
  Future<void> _restartWatching() async {
    _stopWatching(end: false);
    _watching = true; // _initCamera resumes into watching
    await _restartCamera();
  }

  // ---------------------------------------------------------------- black

  Widget _black(BuildContext context) {
    const dim = Color(0x66FFFFFF);
    const amber = Color(0xFFFFB300);
    final dot = switch (_status) {
      WatchStatus.idle => const Color(0xFF555555),
      WatchStatus.burst => const Color(0xFFB8860B),
      WatchStatus.reading => const Color(0xFF2E7D32),
    };
    final cards = _lastCards;
    final rec = _rec;
    return PopScope(
      onPopInvoked: (_) => _stopWatching(),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(children: [
            // Top: Stop / Next hand and the status dots, away from the pad.
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
              child: Row(children: [
                TextButton(
                  onPressed: () {
                    _stopWatching();
                    setState(() {});
                  },
                  child: const Text('Stop', style: TextStyle(color: dim)),
                ),
                TextButton(
                  onPressed: _nextHand,
                  child: const Text('Next hand', style: TextStyle(color: dim)),
                ),
                const Spacer(),
                if (rec != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('rec ${rec.session.photos}',
                        key: const Key('watch-rec'), style: const TextStyle(color: Color(0x44FFFFFF), fontSize: 11)),
                  ),
                if (_shownAway)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Semantics(
                      label: 'wide shot',
                      child: Container(
                          key: const Key('watch-wide-dot'),
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(color: Color(0xFF3D5A80), shape: BoxShape.circle)),
                    ),
                  ),
                Semantics(
                  label: 'Watching: ${_status.name}',
                  child: Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                ),
              ]),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_health.problem != null)
                  Padding(
                    key: const Key('watch-problem'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(children: [
                      Text('${_health.problem}: not reading cards',
                          textAlign: TextAlign.center, style: const TextStyle(color: amber, fontSize: 15)),
                      TextButton(
                        onPressed: _restartWatching,
                        child: const Text('Restart camera', style: TextStyle(color: amber)),
                      ),
                    ]),
                  ),
                for (final w in _warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(warningText(w),
                        key: Key('watch-warn-${w.name}'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: amber, fontSize: 13)),
                  ),
                if (rec != null && _wideOff != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('Wide shots off: $_wideOff', style: const TextStyle(color: dim, fontSize: 12)),
                  ),
                if (WatchSettings.voice.value)
                  ValueListenableBuilder(
                    valueListenable: _voice.state,
                    builder: (_, s, __) => s == VoiceState.paused
                        ? const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text('earbuds disconnected, voice paused',
                                style: TextStyle(color: dim, fontSize: 12)),
                          )
                        : const SizedBox.shrink(),
                  ),
                if (_waitDealer)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('Hand not moved on: check the logger',
                        style: TextStyle(color: dim, fontSize: 12)),
                  ),
                if (cards != null)
                  ActionChip(
                    backgroundColor: Colors.black,
                    side: const BorderSide(color: Color(0x33FFFFFF)),
                    label: Text('${prettyCards(cards)} $_lastWhat · hand ${widget.host.watchHandNumber} · tap to fix',
                        style: const TextStyle(color: dim, fontSize: 13)),
                    onPressed: _fix,
                  ),
                const SizedBox(height: 10),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: WatchActionArea(host: widget.host, onAction: _padAction, onNext: _nextHand),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The black screen's action pad: the logger's gesture pad, dark and dim,
/// on the hand being played. Shows only the action (never the cards).
class WatchActionArea extends StatelessWidget {
  final WatchHost host;
  final ValueChanged<PreAction?> onAction;
  final VoidCallback onNext;
  const WatchActionArea({super.key, required this.host, required this.onAction, required this.onNext});

  @override
  Widget build(BuildContext context) => ActionPad(
        key: const Key('watch-action-pad'),
        pending: host.watchPendingAction,
        onAction: onAction,
        onNext: onNext,
        lowLight: true,
        height: 190,
      );
}
