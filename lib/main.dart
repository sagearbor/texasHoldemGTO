import 'package:flutter/material.dart';

import 'app_data.dart';
import 'gto/spots.dart';
import 'homegame/home_game.dart';
import 'trainer/trainer_model.dart';
import 'ui/chart_prefs.dart';
import 'ui/screens/charts_screen.dart';
import 'ui/screens/equity_screen.dart';
import 'ui/screens/help_screen.dart';
import 'ui/screens/home_game_screen.dart';
import 'ui/screens/stats_screen.dart';
import 'ui/screens/train_screen.dart';
import 'ui/theme.dart';

void main() => runApp(const FeltNotesApp());

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
      await Future.wait([m.load(), h.load(), ChartPrefs.load()]);
      if (mounted) {
        setState(() {
          model = m;
          home = h;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Felt Notes',
      debugShowCheckedModeBanner: false,
      theme: Felt.light(),
      darkTheme: Felt.dark(),
      themeMode: ThemeMode.dark,
      // Above the Navigator so every route (e.g. About's reset) can reach it.
      builder: (context, child) =>
          AppScope(trainer: model, home: home, child: child!),
      home: const _Home(),
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
      ChartsScreen(library: m.library, onDrill: _drill),
      EquityScreen(library: m.library),
      StatsScreen(model: m, onDrill: _drill),
      HomeGameScreen(model: widget.home, trainer: m),
    ];
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: IndexedStack(index: tab, children: pages),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Train'),
          NavigationDestination(icon: Icon(Icons.grid_on), label: 'Charts'),
          NavigationDestination(icon: Icon(Icons.percent), label: 'Equity'),
          NavigationDestination(icon: Icon(Icons.insights), label: 'Stats'),
          NavigationDestination(icon: Icon(Icons.groups), label: 'Home game'),
        ],
      ),
    );
  }
}
