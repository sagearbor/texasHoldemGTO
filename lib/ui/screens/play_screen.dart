import 'package:flutter/material.dart';

import '../../homegame/home_game.dart';
import '../../nearby/nearby_ble.dart' show bleSupported;
import '../../nearby/nearby_service.dart';
import '../../nearby/nearby_ui.dart' show askBluetooth, joinNearbyGame;
import '../../sync/table_night_service.dart';
import '../../trainer/trainer_model.dart';
import '../theme.dart';
import 'glossary_screen.dart';
import 'help_screen.dart';
import 'home_game_screen.dart';
import 'table_night_screen.dart' show JoinTableNightScreen, PlayerPadScreen, showTvCodeDialog;

NearbyService get _near => NearbyService.instance;
TableNightService get _tn => TableNightService.instance;

/// The Play tab, one screen for hosts and players: games running nearby
/// (Join), Host a game, Scan the host's code, This device is the TV. A
/// night running on this phone shows that night (the hand logger) instead.
class PlayScreen extends StatefulWidget {
  final HomeGameModel model;
  final TrainerModel? trainer;
  const PlayScreen({super.key, required this.model, this.trainer});

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  /// "Host a game" tapped: the setup form, then (after Start) the logger.
  bool _hosting = false;
  bool _hadNight = false;

  @override
  void initState() {
    super.initState();
    _hadNight = widget.model.active != null;
    widget.model.addListener(_onModel);
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    super.dispose();
  }

  void _onModel() {
    final has = widget.model.active != null;
    // The night ended: back to the Play screen, not a fresh setup form.
    if (_hadNight && !has && _hosting) setState(() => _hosting = false);
    _hadNight = has;
  }

  void _back() => setState(() => _hosting = false);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final running = widget.model.active != null;
        if (running || _hosting) {
          return PopScope(
            // Android back on the setup form: to the Play screen, not out
            // of the app.
            canPop: running || !_hosting,
            onPopInvoked: (didPop) {
              if (!didPop) _back();
            },
            child: HomeGameScreen(
              model: widget.model,
              trainer: widget.trainer,
              onBack: running ? null : _back,
            ),
          );
        }
        return _Hub(onHost: () => setState(() => _hosting = true));
      },
    );
  }
}

class _Hub extends StatelessWidget {
  final VoidCallback onHost;
  const _Hub({required this.onHost});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play'),
        actions: const [GlossaryButton(), HelpButton(HelpTopic.homeGame)],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_near, _tn]),
        builder: (context, _) {
          final joined = _tn.night != null && !_tn.isOrganizer;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (joined) ...[
                FilledButton.tonalIcon(
                  key: const Key('play-back-to-night'),
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => const PlayerPadScreen())),
                  icon: const Icon(Icons.touch_app_outlined),
                  label: Text('Back to ${_tn.tableName()}'),
                ),
                const SizedBox(height: 20),
              ],
              if (bleSupported && _tn.night == null) ...[
                Text('Games nearby', style: t.titleMedium),
                const SizedBox(height: 6),
                const _NearbyGames(),
                const SizedBox(height: 24),
              ],
              FilledButton.icon(
                key: const Key('play-host'),
                onPressed: onHost,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Host a game'),
              ),
              const SizedBox(height: 4),
              Text('You log the hands; other phones and a TV can join.',
                  style: t.bodySmall, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('play-scan'),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const JoinTableNightScreen())),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text("Scan the host's code"),
              ),
              const SizedBox(height: 32),
              Center(
                child: TextButton.icon(
                  key: const Key('play-tv'),
                  onPressed: () => showTvCodeDialog(context),
                  icon: const Icon(Icons.tv, size: 18),
                  label: const Text('This device is the TV'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Games heard over Bluetooth, each with Join; "Still looking…" when none.
/// Before Bluetooth was ever allowed: one button that asks (just in time).
class _NearbyGames extends StatelessWidget {
  const _NearbyGames();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (!_near.allowed) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Games hosted at your table show up here by Bluetooth, no internet needed.',
            style: t.bodySmall),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          key: const Key('play-allow-bluetooth'),
          onPressed: () async {
            if (await askBluetooth(context)) _near.setLooking(true);
          },
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text('Find games nearby'),
        ),
      ]);
    }
    final games = _near.games;
    if (games.isEmpty) {
      return Row(children: [
        Icon(_near.poweredOn ? Icons.bluetooth_searching : Icons.bluetooth_disabled, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              _near.poweredOn
                  ? 'Still looking… Games hosted nearby show up here.'
                  : 'Bluetooth is off: turn it on to find games nearby, or scan the host\'s code.',
              key: const Key('play-still-looking'),
              style: t.bodyMedium),
        ),
      ]);
    }
    return Column(children: [
      for (final g in games.take(5))
        Card(
          color: Felt.accent(context).withOpacity(0.16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
            child: Row(children: [
              Icon(Icons.bluetooth_searching, color: Felt.accent(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(g.label,
                    key: const Key('nearby-game'), style: t.titleSmall, overflow: TextOverflow.ellipsis),
              ),
              FilledButton(
                key: const Key('nearby-join'),
                onPressed: () => joinNearbyGame(context, g),
                child: const Text('Join'),
              ),
            ]),
          ),
        ),
    ]);
  }
}
