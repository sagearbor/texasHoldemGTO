/// Sends one player's heart rate to the night, batched: at most one write
/// per [window] (15 s) for the samples, plus the player's Pulse identity
/// (name, selfie, song) once. Nothing is sent unless the player turned
/// Pulse on for this night; turning it off stops the uploads and deletes
/// what was sent ([PulseUploader.wipe]).
library;

import 'dart:async';

import 'pulse_cloud.dart';
import 'pulse_profile.dart';
import 'pulse_protocol.dart';

class PulseUploader {
  final PulseCloud cloud;
  final String nightId;
  final String deviceId;
  final PulseProfile Function() profile;
  final int Function() now;
  final Duration window;

  /// Makes sure this phone is a member of the night (the rules want it).
  final Future<void> Function() ensureJoined;

  /// After every attempt (UI status).
  void Function()? onChange;

  PulseUploader({
    required this.cloud,
    required this.nightId,
    required this.deviceId,
    required this.profile,
    required this.ensureJoined,
    int Function()? now,
    this.window = const Duration(seconds: 15),
    this.onChange,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// This night's samples on this phone (already filtered), oldest first.
  final List<PulseSample> samples = [];

  /// chunk -> samples the cloud has for it.
  final Map<int, int> _sent = {};
  bool _memberUp = false;
  bool _busy = false;
  Timer? _timer;

  int? lastOkMs;
  Object? lastError;

  void add(Iterable<PulseSample> s) => samples.addAll(s);

  /// The profile changed (new selfie or song): send it with the next batch.
  void profileChanged() => _memberUp = false;

  bool get pending =>
      !_memberUp || samples.isNotEmpty && _sent[chunkOf(samples.last.tMs)] != _countIn(chunkOf(samples.last.tMs));

  int _countIn(int chunk) {
    var n = 0;
    for (var i = samples.length - 1; i >= 0 && chunkOf(samples[i].tMs) >= chunk; i--) {
      if (chunkOf(samples[i].tMs) == chunk) n++;
    }
    return n;
  }

  /// Sends whatever the cloud does not have yet. Never throws.
  Future<bool> flush() async {
    if (_busy) return false;
    _busy = true;
    try {
      await ensureJoined();
      if (!_memberUp) {
        await cloud.putMember(nightId, deviceId, profile());
        _memberUp = true;
      }
      final byChunk = <int, List<PulseSample>>{};
      for (final s in samples) {
        byChunk.putIfAbsent(chunkOf(s.tMs), () => []).add(s);
      }
      for (final c in byChunk.keys.toList()..sort()) {
        final list = byChunk[c]!;
        if (_sent[c] == list.length) continue;
        // A chunk holds 10 minutes; a watch sending faster than 2 a
        // second keeps the newest that fit.
        final fit = list.length * 2 > chunkMaxNumbers ? list.sublist(list.length - chunkMaxNumbers ~/ 2) : list;
        await cloud.putChunk(nightId, PulseChunk(deviceId, c, fit));
        _sent[c] = list.length;
      }
      lastOkMs = now();
      lastError = null;
      return true;
    } catch (e) {
      lastError = e;
      return false;
    } finally {
      _busy = false;
      onChange?.call();
    }
  }

  /// Uploads every [window] while running.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(window, (_) => unawaited(flush()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  bool get running => _timer != null;

  /// Pulse turned off: stop, and delete everything this phone sent for the
  /// night. False when the delete failed (the caller retries later).
  Future<bool> wipe() async {
    stop();
    // A batch in flight lands first, so the delete catches it.
    for (var i = 0; _busy && i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    try {
      await cloud.deleteMine(nightId, deviceId);
      _sent.clear();
      _memberUp = false;
      return true;
    } catch (e) {
      lastError = e;
      return false;
    } finally {
      onChange?.call();
    }
  }
}
