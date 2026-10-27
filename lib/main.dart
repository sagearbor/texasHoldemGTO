import 'package:flutter/material.dart';

import 'gto/spots.dart';
import 'trainer/trainer_model.dart';
import 'ui/screens/charts_screen.dart';
import 'ui/screens/equity_screen.dart';
import 'ui/screens/home_game_screen.dart';
import 'ui/screens/stats_screen.dart';
import 'ui/screens/train_screen.dart';
import 'ui/theme.dart';

void main() => runApp(const FeltNotesApp());

class FeltNotesApp extends StatelessWidget {
  const FeltNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Felt Notes',
      debugShowCheckedModeBanner: false,
      theme: Felt.light(),
      darkTheme: Felt.dark(),
      themeMode: ThemeMode.dark,
      home: const _Loader(),
    );
  }
}

class _Loader extends StatefulWidget {
  const _Loader();

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> {
  TrainerModel? model;

  @override
  void initState() {
    super.initState();
    SpotLibrary.load().then((lib) async {
      final m = TrainerModel(lib);
      await m.load();
      if (mounted) setState(() => model = m);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = model;
    if (m == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Shell(model: m);
  }
}

class Shell extends StatefulWidget {
  final TrainerModel model;
  const Shell({super.key, required this.model});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;

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
      const HomeGameScreen(),
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
