import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_data.dart';
import 'gto/spots.dart';
import 'homegame/home_game.dart';
import 'trainer/trainer_model.dart';
import 'ui/app_settings.dart';
import 'ui/chart_prefs.dart';
import 'ui/screens/charts_screen.dart';
import 'ui/screens/equity_screen.dart';
import 'ui/screens/help_screen.dart';
import 'ui/screens/home_game_screen.dart';
import 'ui/screens/stats_screen.dart';
import 'ui/screens/train_screen.dart';
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
          [m.load(), h.load(), ChartPrefs.load(), AppSettings.load()]);
      // Resumes a table night this phone was in (no network until one is).
      unawaited(TableNightService.instance.init(h));
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
  int tab = 0;

  @override
  void initState() {
    super.initState();
    shellTabs.addListener(_onTabRequest);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => maybeShowWelcome(context, widget.model));
  }

  void _onTabRequest() {
    if (mounted) setState(() => tab = shellTabs.tab);
  }

  @override
  void dispose() {
    shellTabs.removeListener(_onTabRequest);
    super.dispose();
  }

  void _drill(String spotId) {
    widget.model.focus(spotId);
    setState(() => tab = 0);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final pages = [
      TrainScreen(model: m),
      ChartsScreen(
          library: m.library,
          onDrill: _drill,
          model: m,
          onDrillWeak: (spotId, targets) {
            m.drillWeakHands(spotId, targets);
            setState(() => tab = 0);
          }),
      EquityScreen(library: m.library),
      StatsScreen(model: m, onDrill: _drill),
      HomeGameScreen(model: widget.home, trainer: m),
    ];
    const dests = [
      (Icons.fitness_center, 'Train'),
      (Icons.grid_on, 'Charts'),
      (Icons.percent, 'Equity'),
      (Icons.insights, 'Stats'),
      (Icons.groups, 'Home game'),
    ];
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: IndexedStack(index: tab, children: pages),
      ),
    );
    void select(int i) => setState(() => tab = i);
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
