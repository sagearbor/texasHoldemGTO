import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../homegame/blind_clock.dart';
import '../../homegame/blind_clock_controller.dart';
import '../screens/blind_clock_screen.dart';
import '../theme.dart';

/// Buzz + system beep when the blinds go up. No audio assets needed.
void levelChangeAlert() {
  HapticFeedback.heavyImpact();
  SystemSound.play(SystemSoundType.alert);
}

/// One-line clock for the top of the TV dashboard. Renders nothing unless a
/// blind clock has been started. Tap to open the full clock.
class BlindClockStrip extends StatefulWidget {
  final BlindClockController? controller;
  const BlindClockStrip({super.key, this.controller});

  @override
  State<BlindClockStrip> createState() => _BlindClockStripState();
}

class _BlindClockStripState extends State<BlindClockStrip> {
  Timer? _tick;

  BlindClockController get c => widget.controller ?? BlindClockController.shared;

  @override
  void initState() {
    super.initState();
    c.ensureLoaded();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !c.clock.started) return;
      if (c.takeLevelChange()) levelChangeAlert();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final clock = c.clock;
        if (!c.loaded || !clock.started) return const SizedBox.shrink();
        final now = c.now();
        final p = clock.positionAt(now);
        final lvl = clock.schedule[p.index];
        final cash = clock.mode == ClockMode.cash;
        final next = clock.upcomingAt(now);
        final wide = MediaQuery.sizeOf(context).width > 800;
        final big = TextStyle(
            color: Colors.white,
            fontSize: wide ? 30 : 22,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()]);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: lvl.isBreak ? const Color(0xFF3A2F12) : Felt.feltCard,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => BlindClockScreen(controller: widget.controller))),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    Text(
                        cash
                            ? 'CASH'
                            : lvl.isBreak
                                ? 'BREAK'
                                : 'LVL ${clock.levelNumber(p.index)}',
                        style: const TextStyle(
                            color: Felt.gold, fontSize: 13, letterSpacing: 1.2)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(lvl.isBreak ? '${lvl.minutes} min' : lvl.label,
                          style: big, overflow: TextOverflow.ellipsis),
                    ),
                    if (!cash) ...[
                      if (clock.paused)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Icon(Icons.pause, color: Colors.white54, size: 20),
                        ),
                      Text(formatClock(p.remainingMs),
                          style: big.copyWith(
                              color: clock.paused
                                  ? Colors.white54
                                  : p.remainingMs <= 60000
                                      ? Felt.gold
                                      : Colors.white)),
                    ],
                    if (!cash && next != null && wide) ...[
                      const SizedBox(width: 16),
                      Text('next ${next.isBreak ? 'break' : next.label}',
                          style: const TextStyle(color: Colors.white60, fontSize: 15)),
                    ],
                  ]),
                ),
                if (!cash)
                  LinearProgressIndicator(
                    value: lvl.durationMs == 0 ? 1 : p.elapsedMs / lvl.durationMs,
                    minHeight: 4,
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation(Felt.gold),
                  ),
              ]),
            ),
          ),
        );
      },
    );
  }
}
