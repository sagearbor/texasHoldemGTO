/// Android-Android UWB for the seating experiment (UwbChannel.kt, Jetpack
/// androidx.core.uwb). Never iPhone-Android. Gated: the phone must have UWB
/// hardware, Android 12+, the library, and the UWB_RANGING permission
/// (asked just in time, with a plain reason, only on such phones and only
/// once the owner is in a game with Bluetooth allowed). The distances join
/// the iPhone ones (sense.dart) and the radar weighs them the same.
///
/// The owner needs to know why two UWB phones did not range, so every
/// native stage arrives as a `uwb_android` event; [UwbTelemetry] counts
/// them for the per-minute summary (uploaded with the night, under the
/// usual sharing switch) and the per-night summary. Pure Dart apart from
/// [AndroidUwb]'s channel calls.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'sense.dart' show median;

/// What the native capability check found.
class UwbCapability {
  final bool feature;
  final int sdk;
  final bool library;
  final bool permission;

  /// UwbManager.isAvailable (null: not asked, a requirement failed first).
  final bool? available;
  const UwbCapability(
      {this.feature = false, this.sdk = 0, this.library = false, this.permission = false, this.available});

  static UwbCapability fromMap(Map<Object?, Object?>? m) => m == null
      ? const UwbCapability()
      : UwbCapability(
          feature: m['feature'] == true,
          sdk: (m['sdk'] as num?)?.toInt() ?? 0,
          library: m['lib'] == true,
          permission: m['permission'] == true,
          available: m['available'] as bool?,
        );

  /// The phone could do UWB if the owner allows it.
  bool get hardware => feature && sdk >= 31 && library;
  bool get usable => hardware && permission && available != false;

  /// Why not (for the log), or null when usable.
  String? get whyNot {
    if (!feature) return 'no UWB hardware';
    if (sdk < 31) return 'Android $sdk is older than 12';
    if (!library) return 'UWB library missing';
    if (!permission) return 'UWB permission not granted';
    if (available == false) return 'UWB is off or unavailable';
    return null;
  }

  Map<String, Object?> toJson() =>
      {'feature': feature, 'sdk': sdk, 'lib': library, 'perm': permission, 'avail': available, 'why': whyNot};
}

/// Who leads a pair: the phone whose advert key sorts first is the
/// controller and starts the exchange (both phones decide the same way).
bool isController(String myKey, String peerKey) => myKey.compareTo(peerKey) < 0;

/// Which peers to start ranging with now: at most [maxSessions] at once,
/// longest-unranged first (never ranged before anything), so every pair
/// gets its turn as sessions rotate.
List<String> pickPeers(Iterable<String> candidates,
    {required Set<String> active, required Map<String, int> lastRangedMs, int maxSessions = 2}) {
  final free = maxSessions - active.length;
  if (free <= 0) return const [];
  final c = [
    for (final p in candidates)
      if (!active.contains(p)) p
  ]..sort((a, b) {
      final x = lastRangedMs[a], y = lastRangedMs[b];
      if (x == null && y == null) return a.compareTo(b);
      if (x == null) return -1;
      if (y == null) return 1;
      return x.compareTo(y);
    });
  return c.take(free).toList();
}

/// Counts the native stages.
class UwbTelemetry {
  /// Peers an exchange was started or received with, and ones that ranged.
  final Set<String> attempted = {};
  final Set<String> ranged = {};

  /// Failure reason -> count ("exchange_failed: not seen", ...).
  final Map<String, int> failures = {};
  final List<double> distancesCm = [];
  final List<int> firstLatencyMs = [];
  int results = 0;
  int _minuteResults = 0;
  final Map<String, int> _minuteFailures = {};
  final Set<String> _minuteRanged = {};
  UwbCapability? capability;

  void onStage(Map<String, Object?> e) {
    final stage = '${e['stage']}';
    final peer = e['peer'] as String?;
    switch (stage) {
      case 'exchange_start':
      case 'exchange_received':
        if (peer != null) attempted.add(peer);
      case 'first_result':
        final l = (e['latency_ms'] as num?)?.toInt();
        if (l != null) firstLatencyMs.add(l);
      case 'exchange_failed':
      case 'session_error':
      case 'ranging_failure':
      case 'start_error':
      case 'capability_error':
      case 'range_skipped':
        final why = '$stage: ${e['why'] ?? e['error'] ?? e['reason'] ?? '?'}';
        failures[why] = (failures[why] ?? 0) + 1;
        _minuteFailures[why] = (_minuteFailures[why] ?? 0) + 1;
    }
  }

  /// A distance reading from an Android peer.
  void onReading(String peer, double meters) {
    ranged.add(peer);
    _minuteRanged.add(peer);
    results++;
    _minuteResults++;
    if (distancesCm.length < 5000) distancesCm.add(meters * 100);
  }

  /// The minute's compact summary (goes into that minute's `sense` event
  /// as `ua`), then the minute counters restart.
  Map<String, Object?>? takeMinute() {
    if (_minuteResults == 0 && _minuteFailures.isEmpty && _minuteRanged.isEmpty) return null;
    final out = {
      'n': _minuteResults,
      'peers': _minuteRanged.length,
      if (_minuteFailures.isNotEmpty) 'fail': Map.of(_minuteFailures),
    };
    _minuteResults = 0;
    _minuteFailures.clear();
    _minuteRanged.clear();
    return out;
  }

  /// The night so far: pairs attempted / ranged, median distance, failure
  /// histogram, capability.
  Map<String, Object?> night() => {
        'attempted': attempted.length,
        'ranged': ranged.length,
        'results': results,
        if (distancesCm.isNotEmpty) 'median_cm': median(distancesCm).round(),
        if (firstLatencyMs.isNotEmpty) 'first_ms': median(firstLatencyMs).round(),
        'fail': Map.of(failures),
        if (capability != null) 'cap': capability!.toJson(),
      };
}

/// The channel calls (BleChannel.kt; no-ops on iPhones, the web, tests).
class AndroidUwb {
  final MethodChannel channel;
  AndroidUwb([this.channel = const MethodChannel('felt_notes/ble')]);

  Future<T?> _call<T>(String m, [Object? a]) async {
    try {
      return await channel.invokeMethod<T>(m, a);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('uwb $m: ${e.code}');
      return null;
    }
  }

  Future<UwbCapability> capability() async => UwbCapability.fromMap(await _call<Map>('uwbStatus'));

  /// Asks (after [explain] returned true) only on a phone with UWB
  /// hardware that has not got the permission yet. Returns the capability
  /// after.
  Future<UwbCapability> ensurePermission(Future<bool> Function() explain) async {
    final c = await capability();
    if (!c.hardware || c.permission) return c;
    if (!await explain()) return c;
    await _call<bool>('uwbRequestPermission');
    return capability();
  }

  Future<void> range(String uuid, String peerKey) => _call<void>('uwbRange', {'uuid': uuid, 'peer': peerKey});
}
