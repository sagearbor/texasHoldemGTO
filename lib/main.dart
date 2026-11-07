import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_data.dart';
import 'camera/lens.dart';
import 'camera/watch_screen.dart' show WatchSettings;
import 'gto/spots.dart';
import 'homegame/home_game.dart';
import 'nearby/nearby_service.dart';
import 'pulse/pulse_service.dart';
import 'record/record_screen.dart';
import 'settings/dev_settings.dart';
import 'trainer/trainer_model.dart';
import 'ui/app_settings.dart';
import 'ui/chart_prefs.dart';
import 'ui/dev_mode.dart';
import 'ui/screens/charts_screen.dart';
import 'ui/screens/equity_screen.dart';
import 'ui/screens/help_screen.dart';
import 'ui/screens/history_screen.dart';
import 'ui/screens/learn_screen.dart';
import 'ui/screens/play_screen.dart';
import 'ui/screens/stats_screen.dart';
import 'ui/screens/train_screen.dart';
import 'sync/cloud_logs.dart' show cardsLeavePhone;
import 'sync/table_night_service.dart';
import 'ui/theme.dart';
import 'ui/tv/tv_screen.dart';

void main() {
  // The table TV page (/#/tv?c=CODE) is its own small app: no trainer, no
  // spot library, nothing stored but the code.
  final tv = tvRoute(Uri.base);
  if (tv != null) return runApp(TvApp(code: tv.isEmpty ? null : tv));
  runApp(const FeltNotesApp());
}

/// "" for the TV page without a code, the code for /#/tv?c=CODE, null when
/// this is not the TV page. Web only (the hash route is the GitHub Pages URL).
String? tvRoute(Uri u) {
  if (!kIsWeb) return null;
  final f = u.fragment;
  if (f != '/tv' && !f.startsWith('/tv?') && !f.startsWith('/tv/')) return null;
  final q = f.indexOf('?');
  if (q < 0) return '';
  return Uri.splitQueryString(f.substring(q + 1))['c'] ?? '';
}

class FeltNotesApp extends StatefulWidget {
  const FeltNotesApp({super.key});

  @override
  State<FeltNotesApp> createState() => _FeltNotesAppState();
}

class _FeltNotesAppState extends State<FeltNotesApp> {
  TrainerModel? model;
  HomeGameModel? home;

  @override
  void initState() {
    super.initState();
    SpotLibrary.load().then((lib) async {
      final m = TrainerModel(lib);
      final h = HomeGameModel(lib);
      await Future.wait(
          [m.load(), h.load(), ChartPrefs.load(), AppSettings.load(), DevMode.load(), DevSettings.load(), CameraLens.load()]);
      await WatchSettings.load(); // after DevMode (its record default)
      // Hole cards stay on the phone unless Settings → Advanced / Developer says.
      cardsLeavePhone = () => DevSettings.cardsToCloud;
      // Resumes a table night this phone was in (no network until one is).
      unawaited(TableNightService.instance.init(h).then((_) {
        // Pulse follows the night (resumes heart-rate sharing if it was on).
        PulseService.instance.hook();
        return NearbyService.instance.init();
      }));
      if (mounted) {
        setState(() {
          model = m;
          home = h;
        });
      }
    });
  }

  static final _light = Felt.light();
  static final _dark = Felt.dark();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeChoice>(
      valueListenable: AppSettings.theme,
      builder: (context, choice, _) => MaterialApp(
        title: 'Felt Notes',
        debugShowCheckedModeBanner: false,
        theme: _light,
        darkTheme: _dark,
        themeMode: themeModeFor(choice),
        // Above the Navigator so every route (e.g. About's reset) can reach it.
        builder: (context, child) =>
            AppScope(trainer: model, home: home, child: child!),
        home: const _Home(),
      ),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    final m = scope?.trainer, h = scope?.home;
    if (m == null || h == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Shell(model: m, home: h);
  }
}

class Shell extends StatefulWidget {
  final TrainerModel model;
  final HomeGameModel home;
  const Shell({super.key, required this.model, required this.home});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  /// Bottom tabs: 0 Learn (where the app opens), 1 Play, 2 History.
  int tab = 0;

  /// Inside Learn: 0 Train, 1 Charts, 2 Equity, 3 Stats.
  int learnTab = 0;

  static const _play = 1;

  /// The tab stack keeps its state when the layout swaps between the
  /// bottom bar and the side rail (a Pixel turned sideways is 915 dp
  /// wide): without it the hand logger under Watch was rebuilt from
  /// scratch, and Watch kept talking to the dead one (build 45: no tap
  /// or hand reached the night).
  final _tabsKey = GlobalKey(debugLabel: 'shell-tabs');

  @override
  void initState() {
    super.initState();
    shellTabs.addListener(_onTabRequest);
    TableNightService.instance.hostEnded.addListener(_onHostEnded);
    _syncLooking();
    WidgetsBinding.instance
        .addPostFrameCallback((_) async {
      await maybeShowWelcome(context, widget.model);
      // A table recording the app did not stop: resume or close it.
      if (mounted) await maybeOfferRecordResume(context);
    });
  }

  /// Bluetooth looks for games only while Play is on screen (battery).
  void _syncLooking() => NearbyService.instance.setLooking(tab == _play);

  /// Requests (e.g. the leak test's "Drill my leaks") ask for tab 0, which
  /// is Train: Learn, its first section.
  void _onTabRequest() {
    if (!mounted) return;
    setState(() {
      tab = 0;
      learnTab = 0;
    });
    _syncLooking();
  }

  /// A joined player's host ended the game (TableNightService noticed,
  /// on whatever screen): say so and go back to Play.
  void _onHostEnded() {
    if (!mounted) return;
    final msg = TableNightService.instance.takeHostEnded();
    if (msg == null) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    setState(() => tab = _play);
    _syncLooking();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    TableNightService.instance.hostEnded.removeListener(_onHostEnded);
    shellTabs.removeListener(_onTabRequest);
    NearbyService.instance.setLooking(false);
    super.dispose();
  }

  void _train() {
    setState(() {
      tab = 0;
      learnTab = 0;
    });
    _syncLooking();
  }

  void _drill(String spotId) {
    widget.model.focus(spotId);
    _train();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final pages = [
      LearnScreen(
        index: learnTab,
        onIndex: (i) => setState(() => learnTab = i),
        pages: [
          TrainScreen(model: m),
          ChartsScreen(
              library: m.library,
              onDrill: _drill,
              model: m,
              onDrillWeak: (spotId, targets) {
                m.drillWeakHands(spotId, targets);
                _train();
              }),
          EquityScreen(library: m.library),
          StatsScreen(model: m, onDrill: _drill),
        ],
      ),
      PlayScreen(model: widget.home, trainer: m),
      HistoryScreen(model: widget.home),
    ];
    const dests = [
      (Icons.school_outlined, 'Learn'),
      (Icons.style_outlined, 'Play'),
      (Icons.history, 'History'),
    ];
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: IndexedStack(key: _tabsKey, index: tab, children: pages),
      ),
    );
    void select(int i) {
      setState(() => tab = i);
      _syncLooking();
    }
    // Wide screens (desktop browser, TV, tablet landscape): a rail on the left
    // instead of a 1920-px-wide bottom bar under a 640-px column.
    if (MediaQuery.sizeOf(context).width > 900) {
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              NavigationRail(
                selectedIndex: tab,
                onDestinationSelected: select,
                labelType: NavigationRailLabelType.all,
                groupAlignment: -0.6,
                destinations: [
                  for (final d in dests)
                    NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2)),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: content),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      // Games nearby are listed on Play (Bluetooth looks only there).
      body: content,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: select,
        destinations: [
          for (final d in dests)
            NavigationDestination(icon: Icon(d.$1), label: d.$2),
        ],
      ),
    );
  }
}
