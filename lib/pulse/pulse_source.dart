/// Where heart rate comes from: the player's own watch through the native
/// channels (docs/PULSE.md, "Phone <-> Flutter channel"), or a simulated
/// player (Developer mode, demos and tests).
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import 'pulse_cloud.dart';
import 'pulse_protocol.dart';

/// What the phone knows about its watch.
class WatchStatus {
  /// This phone can talk to a watch at all (the native side exists).
  final bool supported;
  final bool paired;

  /// The Felt Notes watch app is installed on the paired watch.
  final bool appInstalled;

  /// The watch app is reachable right now (Bluetooth, app running).
  final bool reachable;

  const WatchStatus({this.supported = false, this.paired = false, this.appInstalled = false, this.reachable = false});

  static const none = WatchStatus();

  factory WatchStatus.fromMap(Object? m) {
    if (m is! Map) return none;
    bool b(String k) => m[k] == true;
    return WatchStatus(supported: b('supported'), paired: b('paired'), appInstalled: b('appInstalled'), reachable: b('reachable'));
  }
}

abstract class PulseSource {
  /// Heart rate ([PulseHr], not yet filtered) and watch state ([PulseState]).
  Stream<PulseMessage> get messages;
  Future<WatchStatus> status();

  /// Asks the watch to start / stop measuring; true when the request went out.
  Future<bool> start();
  Future<bool> stop();

  /// Opens the watch app's install page on the watch, when possible.
  Future<bool> openWatchStore();
  void dispose();
}

/// The real watch: `EventChannel("feltnotes/pulse/events")` and
/// `MethodChannel("feltnotes/pulse/ctl")`. Without the native side (web, an
/// older build, tests) every call answers "no watch".
class ChannelPulseSource implements PulseSource {
  static const events = EventChannel('feltnotes/pulse/events');
  static const ctl = MethodChannel('feltnotes/pulse/ctl');

  Stream<PulseMessage>? _messages;

  @override
  Stream<PulseMessage> get messages => _messages ??= events
      .receiveBroadcastStream()
      .handleError((Object _) {}) // no native side: simply no samples
      .map(parsePulseEvent)
      .where((m) => m != null)
      .cast<PulseMessage>()
      .asBroadcastStream();

  Future<T?> _call<T>(String method) async {
    try {
      return await ctl.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<WatchStatus> status() async => WatchStatus.fromMap(await _call<Object?>('status'));
  @override
  Future<bool> start() async => await _call<bool>('start') ?? false;
  @override
  Future<bool> stop() async => await _call<bool>('stop') ?? false;
  @override
  Future<bool> openWatchStore() async => await _call<bool>('openWatchStore') ?? false;
  @override
  void dispose() {}
}

/// A pretend player for demos without a watch: resting around [resting]
/// bpm with a slow drift, small beat-to-beat noise and now and then a
/// spike (a big pot) that fades over half a minute. Sends a batch every
/// [every] like the watch apps do. Seeded, so tests are repeatable.
class SimulatedPulseSource implements PulseSource {
  final Random rng;
  final int Function() now;
  final Duration every;
  final int resting;

  /// Chance per second that a spike starts.
  final double spikeChance;

  SimulatedPulseSource({
    Random? rng,
    int Function()? now,
    this.every = const Duration(seconds: 2),
    this.resting = 70,
    this.spikeChance = 1 / 90,
  })  : rng = rng ?? Random(),
        now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final _out = StreamController<PulseMessage>.broadcast();
  Timer? _timer;
  bool running = false;
  int? _lastMs;
  double _drift = 0, _spike = 0;

  @override
  Stream<PulseMessage> get messages => _out.stream;

  /// The samples between the last one made and [toMs], one per second.
  List<PulseSample> samplesUntil(int toMs) {
    final out = <PulseSample>[];
    var t = _lastMs == null ? toMs - 1000 : _lastMs! + 1000;
    for (; t <= toMs; t += 1000) {
      // Drift: a random walk pulled back towards resting, about ±8 bpm.
      _drift += (rng.nextDouble() - 0.5) * 1.6 - _drift * 0.02;
      if (_spike < 3 && rng.nextDouble() < spikeChance) _spike = 18 + rng.nextDouble() * 30;
      _spike *= 0.965; // fades by half in about 20 s
      final noise = (rng.nextDouble() - 0.5) * 3;
      final bpm = (resting + _drift + _spike + noise).round().clamp(pulseMinBpm, pulseMaxBpm);
      out.add(PulseSample(t, bpm));
      _lastMs = t;
    }
    return out;
  }

  void _send() {
    if (!running) return;
    final s = samplesUntil(now());
    if (s.isNotEmpty) _out.add(PulseHr(s));
  }

  @override
  Future<WatchStatus> status() async =>
      const WatchStatus(supported: true, paired: true, appInstalled: true, reachable: true);

  @override
  Future<bool> start() async {
    if (!running) {
      running = true;
      _lastMs = null;
      _timer = Timer.periodic(every, (_) => _send());
    }
    _out.add(const PulseState(true));
    return true;
  }

  @override
  Future<bool> stop() async {
    running = false;
    _timer?.cancel();
    _timer = null;
    _out.add(const PulseState(false));
    return true;
  }

  @override
  Future<bool> openWatchStore() async => true;

  @override
  void dispose() {
    _timer?.cancel();
    _out.close();
  }
}

/// Developer mode: a made-up second player drawn only on this phone's TV
/// screen (nothing is sent), so the chart can be tried with one phone. It
/// starts with the last [spanMs] already filled in.
class DemoPulsePlayer {
  static const deviceId = 'demo-player';
  static const member = PulseMember(deviceId: deviceId, name: 'Demo');

  final SimulatedPulseSource _sim;
  final int spanMs;
  final _samples = <PulseSample>[];

  DemoPulsePlayer({Random? rng, this.spanMs = 10 * 60000})
      : _sim = SimulatedPulseSource(rng: rng, resting: 62, spikeChance: 1 / 60);

  /// [n] with the demo player's samples up to [nowMs] added.
  PulseNight addTo(PulseNight n, int nowMs) {
    if (_samples.isEmpty) _samples.addAll(_sim.samplesUntil(nowMs - spanMs));
    _samples.addAll(_sim.samplesUntil(nowMs));
    _samples.removeWhere((x) => x.tMs < nowMs - spanMs - 60000);
    return PulseNight(
      members: {...n.members, deviceId: member},
      samples: {...n.samples, deviceId: List.unmodifiable(_samples)},
    );
  }
}
