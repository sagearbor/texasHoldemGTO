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
/// Nothing is recorded or saved except the cards it reads and numeric
/// diagnostics (watch_log_store.dart). Frames are dropped as soon as they
/// are processed. The frame path (WatchFrame) does not care where frames
/// come from, so a later record-while-watching mode can feed it frames from
/// startVideoRecording(onAvailable: ...).
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

import '../poker/cards.dart';
import 'snap_cards_screen.dart' show BetaBadge;
import 'watch_debug_crops.dart';
import 'watch_diagnostics.dart';
import 'glyph_reader.dart';
import 'watch_frame.dart';
import 'watch_log_store.dart';
import 'watch_pipeline.dart';
import 'watch_tracker.dart';
import 'watch_voice.dart';
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
  /// [cards] on the next one, logged in the tracker with [episode]. Returns
  /// false when the logger cannot move on by itself (first orbit: the
  /// organizer taps the dealer); the cards are then only put in the slots.
  bool watchNewHand(List<int> cards, {int? episode, int? scene});

  /// Next hand, from the black screen.
  void watchNextHand();

  /// Opens the card picker on [context]; the logger tells the tracker.
  Future<void> watchFixCards(BuildContext context);
}

/// Device-only Watch settings (not in backups: they describe this phone).
class WatchSettings {
  static const voiceKey = 'watch_voice_v1';
  static const frontKey = 'watch_front_camera_v1';
  static const sharpKey = 'watch_sharp_v1';
  static const cropsKey = 'watch_debug_crops_v1';

  static final voice = ValueNotifier<bool>(true);
  static final front = ValueNotifier<bool>(false);

  /// 1080p instead of 720p: smaller cards read better, more battery.
  static final sharp = ValueNotifier<bool>(false);

  /// Tester tool: keep the reader's crops on the phone (off by default).
  static final crops = ValueNotifier<bool>(false);

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    voice.value = p.getBool(voiceKey) ?? true;
    front.value = p.getBool(frontKey) ?? false;
    sharp.value = p.getBool(sharpKey) ?? false;
    crops.value = p.getBool(cropsKey) ?? false;
  }

  static Future<void> set(ValueNotifier<bool> n, String key, bool v) async {
    n.value = v;
    (await SharedPreferences.getInstance()).setBool(key, v);
  }
}

Future<void> openWatchMode(BuildContext context, WatchHost host) async {
  await WatchSettings.load();
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => WatchScreen(host: host),
  ));
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
  const WatchScreen({super.key, required this.host});

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
  int _peeksLogged = 0;

  /// The stream's actual format is logged once per session (frame size,
  /// planes, rotation): the first phone test could not tell them apart.
  bool _streamLogged = false;
  final List<(int, int)> _battery = [];
  Timer? _ticker;

  /// Last logged pair and what happened, for the chip.
  List<int>? _lastCards;
  String _lastWhat = '';
  bool _waitDealer = false;

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
      _stopWatching();
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

  Future<void> _initCamera() async {
    if (_opening) return;
    _opening = true;
    try {
      final cams = await availableCameras();
      final want = WatchSettings.front.value ? CameraLensDirection.front : CameraLensDirection.back;
      final cam = cams.firstWhere((c) => c.lensDirection == want, orElse: () => cams.first);
      final c = CameraController(
        cam,
        WatchSettings.sharp.value ? ResolutionPreset.veryHigh : ResolutionPreset.high,
        enableAudio: false,
        // 15 fps (iOS honours it; Android drops the extra frames in Dart).
        fps: 15,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      _worker ??= await GlyphWorker.spawn((await rootBundle.load('assets/data/glyph_cnn.bin')).buffer.asUint8List());
      if (!mounted) return;
      setState(() {
        _cam = c;
        _error = null;
      });
      if (_watching) {
        _watching = false;
        await _startWatching();
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera unavailable ($e)');
    } finally {
      _opening = false;
    }
  }

  Future<void> _startWatching() async {
    final c = _cam;
    if (c == null || _watching) return;
    _pipe = WatchPipeline(_cfg);
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
      'voice': WatchSettings.voice.value,
    });
    _sampleBattery();
    if (WatchSettings.voice.value) await _voice.refresh();
    _ticker = Timer.periodic(const Duration(seconds: 10), (t) {
      _drainPeeks();
      if (WatchSettings.voice.value) _voice.refresh();
      if (t.tick % 60 == 0) _sampleBattery(); // every 10 minutes
    });
    await c.startImageStream(_onImage);
  }

  void _stopWatching() {
    if (!_watching) return;
    _watching = false;
    _ticker?.cancel();
    _ticker = null;
    final c = _cam;
    if (c != null && c.value.isStreamingImages) c.stopImageStream().ignore();
    WakelockPlus.disable();
    final t = _clock.elapsedMilliseconds;
    _pipe.flush(t);
    _drainPeeks();
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
      _log.append(_pipe.peeks[_peeksLogged++].toJson());
    }
  }

  void _onImage(CameraImage img) {
    if (!_watching) return;
    final t = _clock.elapsedMilliseconds;
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
      if (WatchSettings.crops.value) {
        final tag = r.hero.isEmpty ? 'none' : r.hero.map((c) => '${cardToString(c.card)}${(c.score * 100).round()}').join('-');
        _crops.save(job.rgba, job.width, job.height, job.tMs, tag);
      }
      final pair = _pipe.onRead(job, r, readMs: sw.elapsedMilliseconds);
      _setStatus(_pipe.status(_clock.elapsedMilliseconds));
      if (pair != null) _onPair(pair);
    }, onError: (Object e) {
      debugPrint('watch reader: $e');
      _pipe.onRead(job, GlyphReadResult.empty);
    });
  }

  void _setStatus(WatchStatus s) {
    if (s != _status && mounted) setState(() => _status = s);
  }

  void _onPair(List<int> pair) {
    final h = widget.host;
    // The tracker runs on wall-clock ms (the logger's manual picks use it).
    final episode = _pipe.cardEpisode;
    _apply(
        h.watchTracker.onRead(pair, DateTime.now().millisecondsSinceEpoch, episode: episode, scene: _pipe.sceneEpoch),
        episode);
  }

  void _apply(WatchDecision d, int episode) {
    final h = widget.host;
    _pipe.noteDecision(d);
    switch (d.action) {
      case WatchAction.fill:
      case WatchAction.correct:
        h.watchSetCards(d.cards);
      case WatchAction.newHand:
      case WatchAction.newHandUnread:
        _pipe.resetVotes();
        _waitDealer = !h.watchNewHand(d.cards, episode: episode, scene: _pipe.sceneEpoch);
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
    final text = spokenDecision(d);
    if (text != null && WatchSettings.voice.value) _voice.say(text);
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
      appBar: AppBar(title: const Row(children: [Text('Watch my cards'), SizedBox(width: 8), BetaBadge()])),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Text(
            'Prop the phone up beside you, camera towards your cards, about an arm\'s length '
            'away, where it sees the corners when you peek. Then peek as usual: the cards are '
            'logged for this hand, no taps.',
            style: t.bodyMedium),
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
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: c == null ? null : _startWatching,
          icon: const Icon(Icons.visibility_outlined),
          label: const Text('Start watching'),
        ),
        const SizedBox(height: 8),
        Text(
            'The screen goes black and stays on (the camera only works while the app is open). '
            'Nothing is recorded: each frame is dropped once checked, only the cards it reads '
            'are kept. If it is unsure it logs nothing; the card slots always work by hand.',
            style: t.bodySmall),
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
      ]),
    );
  }

  Future<void> _restartCamera() async {
    final c = _cam;
    setState(() => _cam = null);
    await c?.dispose();
    await _initCamera();
  }

  // ---------------------------------------------------------------- black

  Widget _black(BuildContext context) {
    const dim = Color(0x66FFFFFF);
    final dot = switch (_status) {
      WatchStatus.idle => const Color(0xFF555555),
      WatchStatus.burst => const Color(0xFFB8860B),
      WatchStatus.reading => const Color(0xFF2E7D32),
    };
    final cards = _lastCards;
    return PopScope(
      onPopInvoked: (_) => _stopWatching(),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(children: [
            Positioned(
              top: 10,
              right: 12,
              child: Semantics(
                label: 'Watching: ${_status.name}',
                child: Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    child: Text('First orbit: tap the dealer on the logger',
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
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
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
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
