import 'package:flutter/material.dart';

import '../../gto/coach.dart' show pct;
import '../../homegame/home_game.dart';
import 'crew_screen.dart';
import 'dashboard_screen.dart';
import 'glossary_screen.dart';
import 'help_screen.dart';
import 'recap_screen.dart';

/// The History tab: past game nights (Recap, Dashboard) and Crew & season.
/// Moved here unchanged from the old Home game setup screen.
class HistoryScreen extends StatelessWidget {
  final HomeGameModel model;
  const HistoryScreen({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final t = Theme.of(context).textTheme;
        // The night being played lives on Play; only finished ones here.
        final past = [
          for (final s in model.sessions.reversed)
            if (!identical(s, model.active)) s
        ];
        return Scaffold(
          appBar: AppBar(
            title: const Text('History'),
            actions: const [GlossaryButton(), HelpButton(HelpTopic.homeGame)],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              if (past.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Text(
                      'No game nights yet. Host one from Play: it shows up here '
                      'with its recap once it ends.',
                      style: t.bodyMedium,
                      textAlign: TextAlign.center),
                ),
              if (past.isNotEmpty) ...[
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => CrewScreen(model: model))),
                  icon: const Icon(Icons.groups_outlined),
                  label: const Text('Crew & season'),
                ),
                const SizedBox(height: 20),
                Text('Past game nights', style: t.titleMedium),
                for (final s in past)
                  Card(
                    child: ListTile(
                      title: Text(s.name),
                      subtitle: Text(_summary(model, s)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        TextButton(
                          child: const Text('Recap'),
                          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                              fullscreenDialog: true,
                              builder: (_) => RecapScreen(model: model, session: s))),
                        ),
                        IconButton(
                          tooltip: 'Dashboard',
                          icon: const Icon(Icons.bar_chart),
                          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                              fullscreenDialog: true,
                              builder: (_) => DashboardScreen(model: model, session: s))),
                        ),
                      ]),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

String _summary(HomeGameModel m, HomeSession s) {
  final st = computeStats(s.hands, m.library);
  return '${st.logged} hands · VPIP ${pct(st.vpipPct)} · PFR ${pct(st.pfrPct)}';
}
