import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../homegame/blind_clock.dart';
import '../../homegame/blind_clock_controller.dart';
import '../theme.dart';
import '../widgets/blind_clock_strip.dart';

/// Full-screen big-type blind clock, made to be screen-mirrored to a TV.
/// The screen stays awake while it is open. Time comes from the wall clock,
/// so locking the phone or leaving the app doesn't lose any.
class BlindClockScreen extends StatefulWidget {
  final BlindClockController? controller;
  const BlindClockScreen({super.key, this.controller});

  @override
  State<BlindClockScreen> createState() => _BlindClockScreenState();
}

class _BlindClockScreenState extends State<BlindClockScreen> {
  Timer? _tick;

  BlindClockController get c => widget.controller ?? BlindClockController.shared;

  @override
  void initState() {
    super.initState();
    // Cash mode has no timer to start, so opening the screen "starts" it
    // (which is what makes the dashboard strip appear).
    c.ensureLoaded().then((_) {
      if (mounted && c.clock.mode == ClockMode.cash && !c.clock.started) c.start();
    });
    _wake(true);
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (c.takeLevelChange()) levelChangeAlert();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _wake(false);
    super.dispose();
  }

  static void _wake(bool on) {
    // Best effort: unsupported platforms / tests have no plugin.
    try {
      (on ? WakelockPlus.enable() : WakelockPlus.disable()).catchError((_) {});
    } catch (_) {}
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Reset the clock?'),
        content: const Text('Goes back to level 1 and stops the clock. The schedule is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok == true) c.reset();
  }

  void _onMenu(String v) {
    switch (v) {
      case 'tournament':
        c.setMode(ClockMode.tournament);
      case 'cash':
        c.setMode(ClockMode.cash);
        c.start();
      case 'edit':
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => BlindScheduleEditor(controller: c)));
      case 'reset':
        _confirmReset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final clock = c.clock;
        final cash = clock.mode == ClockMode.cash;
        return Scaffold(
          backgroundColor: Felt.feltDark,
          appBar: AppBar(
            backgroundColor: Felt.feltDark,
            foregroundColor: Colors.white,
            title: Text(cash ? 'Cash game blinds' : 'Blind clock'),
            actions: [
              PopupMenuButton<String>(
                onSelected: _onMenu,
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                      value: 'tournament', checked: !cash, child: const Text('Tournament clock')),
                  CheckedPopupMenuItem(
                      value: 'cash', checked: cash, child: const Text('Cash game (no timer)')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'edit', child: Text('Edit levels')),
                  const PopupMenuItem(value: 'reset', child: Text('Reset clock')),
                ],
              ),
            ],
          ),
          body: !c.loaded
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(child: _body(clock, cash)),
        );
      },
    );
  }

  Widget _body(BlindClock clock, bool cash) {
    final now = c.now();
    final p = clock.positionAt(now);
    final lvl = clock.schedule[p.index];
    final upcoming = clock.upcomingAt(now);
    final nextBlind = clock.nextLevelAt(now);

    final header = Text(
      cash
          ? 'CASH GAME'
          : lvl.isBreak
              ? 'BREAK'
              : 'LEVEL ${clock.levelNumber(p.index)}',
      style: const TextStyle(
          color: Felt.gold, fontSize: 22, letterSpacing: 4, fontWeight: FontWeight.w700),
    );

    final blinds = lvl.isBreak
        ? _Big('Break · ${lvl.minutes} min', color: Felt.gold, maxSize: 72)
        : Column(mainAxisSize: MainAxisSize.min, children: [
            _Big('${_n(lvl.smallBlind)} / ${_n(lvl.bigBlind)}', maxSize: 120),
            if (lvl.ante > 0)
              Text('ante ${_n(lvl.ante)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 28)),
          ]);

    final countdown = cash
        ? const SizedBox.shrink()
        : GestureDetector(
            onTap: c.toggle,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _Big(formatClock(p.remainingMs),
                  maxSize: 260,
                  color: !clock.started || clock.paused
                      ? Colors.white54
                      : p.remainingMs <= 60000
                          ? Felt.gold
                          : Colors.white),
              Text(
                  p.finished
                      ? 'Final level'
                      : !clock.started
                          ? 'Tap start when cards are in the air'
                          : clock.paused
                              ? 'PAUSED · tap to resume'
                              : '',
                  style: const TextStyle(color: Colors.white60, fontSize: 18)),
            ]),
          );

    final progress = cash
        ? const SizedBox.shrink()
        : ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: lvl.durationMs == 0 ? 1 : p.elapsedMs / lvl.durationMs,
              minHeight: 12,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation(lvl.isBreak ? Colors.white70 : Felt.gold),
            ),
          );

    final nextText = cash
        ? (nextBlind == null ? 'Top of the schedule' : 'Next stakes: ${nextBlind.label}')
        : upcoming == null
            ? 'Last level'
            : upcoming.isBreak
                ? 'Next: ${upcoming.minutes}-minute break'
                : 'Next: ${upcoming.label}';
    final next = Text(nextText,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 24));

    final controls = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      IconButton.filledTonal(
        tooltip: cash ? 'Lower stakes' : 'Previous level',
        iconSize: 32,
        onPressed: c.previous,
        icon: const Icon(Icons.skip_previous),
      ),
      const SizedBox(width: 20),
      if (!cash)
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Felt.gold,
            foregroundColor: Colors.black,
            minimumSize: const Size(160, 60),
            textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          onPressed: c.toggle,
          icon: Icon(clock.running ? Icons.pause : Icons.play_arrow, size: 30),
          label: Text(clock.running ? 'Pause' : (clock.started ? 'Resume' : 'Start')),
        ),
      if (!cash) const SizedBox(width: 20),
      IconButton.filledTonal(
        tooltip: cash ? 'Raise stakes' : 'Next level',
        iconSize: 32,
        onPressed: c.next,
        icon: const Icon(Icons.skip_next),
      ),
    ]);

    return LayoutBuilder(builder: (context, box) {
      final landscape = box.maxWidth > box.maxHeight * 1.2 && box.maxWidth > 600;
      if (landscape && !cash) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 16),
          child: Column(children: [
            Expanded(
              child: Row(children: [
                Expanded(
                  flex: 2,
                  child: _Fit(gap: 16, children: [header, blinds, next]),
                ),
                const SizedBox(width: 24),
                Expanded(flex: 3, child: _Fit(children: [countdown])),
              ]),
            ),
            progress,
            const SizedBox(height: 16),
            controls,
          ]),
        );
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(children: [
          Expanded(
            child: _Fit(gap: 28, children: [
              header,
              blinds,
              countdown,
              if (!cash) progress,
              next,
            ]),
          ),
          const SizedBox(height: 12),
          controls,
        ]),
      );
    });
  }

  static String _n(int v) => '$v';
}

/// A column at the full available width that shrinks as a whole when the
/// space is too short (phone in landscape), so nothing ever overflows.
class _Fit extends StatelessWidget {
  final List<Widget> children;
  final double gap;
  const _Fit({required this.children, this.gap = 0});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      return Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: box.maxWidth,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) SizedBox(height: gap),
                children[i],
              ],
            ]),
          ),
        ),
      );
    });
  }
}

/// Text that grows to fill its width, up to [maxSize] points.
class _Big extends StatelessWidget {
  final String text;
  final double maxSize;
  final Color color;
  const _Big(this.text, {required this.maxSize, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxSize * 1.25),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text,
            maxLines: 1,
            style: TextStyle(
              color: color,
              fontSize: maxSize,
              height: 1.1,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ),
    );
  }
}

/// Edit the level list: blinds, ante and minutes per level, plus breaks.
class BlindScheduleEditor extends StatefulWidget {
  final BlindClockController controller;
  const BlindScheduleEditor({super.key, required this.controller});

  @override
  State<BlindScheduleEditor> createState() => _BlindScheduleEditorState();
}

class _BlindScheduleEditorState extends State<BlindScheduleEditor> {
  late List<BlindLevel> levels = List.of(widget.controller.clock.schedule);

  void _save() {
    widget.controller.setSchedule(levels);
    Navigator.pop(context);
  }

  Future<void> _edit(int i) async {
    final l = levels[i];
    final sb = TextEditingController(text: '${l.smallBlind}');
    final bb = TextEditingController(text: '${l.bigBlind}');
    final ante = TextEditingController(text: '${l.ante}');
    final min = TextEditingController(text: '${l.minutes}');
    Widget field(String label, TextEditingController t) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: t,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          ),
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(l.isBreak ? 'Break' : 'Level ${_number(i)}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!l.isBreak) ...[
              field('Small blind', sb),
              field('Big blind', bb),
              field('Ante (0 for none)', ante),
            ],
            field('Minutes', min),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok != true) return;
    int parse(TextEditingController t, int fallback, {int min = 0}) {
      final v = int.tryParse(t.text.trim());
      return v == null || v < min ? fallback : v;
    }

    setState(() {
      levels[i] = l.copyWith(
        smallBlind: parse(sb, l.smallBlind),
        bigBlind: parse(bb, l.bigBlind, min: 1),
        ante: parse(ante, l.ante),
        minutes: parse(min, l.minutes, min: 1),
      );
    });
  }

  int _number(int i) {
    var n = 0;
    for (var j = 0; j <= i; j++) {
      if (!levels[j].isBreak) n++;
    }
    return n;
  }

  void _addLevel() {
    final last = levels.lastWhere((l) => !l.isBreak, orElse: () => const BlindLevel(25, 50));
    final mins = levels.isEmpty ? 15 : last.minutes;
    setState(() => levels.add(levels.isEmpty
        ? const BlindLevel(25, 50)
        : BlindLevel(last.smallBlind * 2, last.bigBlind * 2,
            ante: last.ante * 2, minutes: mins)));
  }

  Future<void> _allMinutes() async {
    final t = TextEditingController(
        text: '${levels.firstWhere((l) => !l.isBreak, orElse: () => const BlindLevel(25, 50)).minutes}');
    final v = await showDialog<int>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Minutes per level'),
        content: TextField(
          controller: t,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(helperText: 'Applies to every level (not breaks)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(d, int.tryParse(t.text.trim())),
              child: const Text('Apply')),
        ],
      ),
    );
    if (v == null || v < 1) return;
    setState(() {
      levels = [for (final l in levels) l.isBreak ? l : l.copyWith(minutes: v)];
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Blind levels'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'all') _allMinutes();
              if (v == 'default') setState(() => levels = List.of(defaultSchedule));
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'all', child: Text('Set minutes for all levels')),
              PopupMenuItem(value: 'default', child: Text('Restore default schedule')),
            ],
          ),
          TextButton(onPressed: levels.isEmpty ? null : _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text('Tap a level to change it. The running clock keeps its place.',
                style: t.bodySmall),
          ),
          for (var i = 0; i < levels.length; i++)
            Card(
              child: ListTile(
                leading: levels[i].isBreak
                    ? const Icon(Icons.coffee, color: Felt.gold)
                    : CircleAvatar(child: Text('${_number(i)}')),
                title: Text(levels[i].isBreak ? 'Break' : levels[i].label),
                subtitle: Text('${levels[i].minutes} min'),
                onTap: () => _edit(i),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: levels.length <= 1 ? null : () => setState(() => levels.removeAt(i)),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
            OutlinedButton.icon(
              onPressed: _addLevel,
              icon: const Icon(Icons.add),
              label: const Text('Add level'),
            ),
            OutlinedButton.icon(
              onPressed: () => setState(() => levels.add(const BlindLevel.breakOf(10))),
              icon: const Icon(Icons.coffee_outlined),
              label: const Text('Add break'),
            ),
          ]),
        ],
      ),
    );
  }
}

void openBlindClock(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => const BlindClockScreen()));
