/// "Leave on the table": a joined player puts the phone down for the
/// seating experiment. The screen goes black (OLED pixels off) and stays on
/// with a wake lock, so the app stays in the foreground and keeps scanning
/// and advertising (and iPhone-iPhone UWB). A tap shows a small status and
/// Exit. Opt-in only; it changes nothing in the game.
library;

import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../sync/table_night_service.dart';
import 'nearby_service.dart';

Future<void> openTableMode(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const TableModeScreen()));

/// Warn below this battery level when not charging.
const lowBatteryPct = 20;

bool batteryWarning(int? level, bool? charging) => level != null && level < lowBatteryPct && charging != true;

class TableModeScreen extends StatefulWidget {
  const TableModeScreen({super.key});
  @override
  State<TableModeScreen> createState() => _TableModeScreenState();
}

class _TableModeScreenState extends State<TableModeScreen> {
  bool _status = false;
  Timer? _hide;
  Timer? _poll;
  int? _battery;
  bool? _charging;
  final Stopwatch _since = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    NearbyService.instance.note('table_mode', {'on': true});
    _readBattery();
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _readBattery());
  }

  @override
  void dispose() {
    _hide?.cancel();
    _poll?.cancel();
    WakelockPlus.disable();
    NearbyService.instance.note('table_mode', {'on': false, 'ms': _since.elapsedMilliseconds});
    super.dispose();
  }

  Future<void> _readBattery() async {
    try {
      final b = Battery();
      final level = await b.batteryLevel;
      final st = await b.batteryState;
      if (!mounted) return;
      setState(() {
        _battery = level;
        _charging = st == BatteryState.charging || st == BatteryState.full;
      });
    } catch (_) {}
  }

  void _tap() {
    _hide?.cancel();
    setState(() => _status = true);
    _hide = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _status = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tn = TableNightService.instance;
    final warn = batteryWarning(_battery, _charging);
    const dim = TextStyle(color: Colors.white54, fontSize: 14);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _tap,
        child: SafeArea(
          child: Center(
            child: !_status
                ? (warn
                    ? Text('Battery $_battery%: plug in', style: dim.copyWith(color: Colors.amber.withOpacity(0.6)))
                    : const SizedBox.expand())
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(tn.night == null ? 'Not in a game' : tn.tableName(), style: dim.copyWith(fontSize: 16)),
                    const SizedBox(height: 6),
                    Text(
                        NearbyService.instance.allowed
                            ? 'Logging · keep this screen open'
                            : 'Bluetooth is off for Felt Notes: nothing is logged',
                        style: dim),
                    const SizedBox(height: 6),
                    Text(
                        _battery == null
                            ? 'Battery ?'
                            : 'Battery $_battery%${_charging == true ? ' · charging' : ''}',
                        style: warn ? dim.copyWith(color: Colors.amber) : dim),
                    if (warn) const Text('Under 20% and not charging: plug in', style: TextStyle(color: Colors.amber)),
                    const SizedBox(height: 20),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Exit'),
                    ),
                  ]),
          ),
        ),
      ),
    );
  }
}
