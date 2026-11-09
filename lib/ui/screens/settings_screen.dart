import 'package:flutter/material.dart';

import '../../nearby/distance_test_screen.dart';
import '../../nearby/nearby_ble.dart' show bleSupported;

import '../../app_data.dart';
import '../../camera/lens.dart';
import '../../camera/watch_log_store.dart';
import '../../camera/watch_screen.dart' show WatchSettings, watchModeSupported;
import '../../homegame/home_game.dart';
import '../../homegame/my_result.dart';
import '../../poker/cards.dart';
import '../../settings/dev_settings.dart';
import '../../trainer/trainer_model.dart';
import '../app_settings.dart';
import '../chart_prefs.dart';
import '../dev_mode.dart';
import '../player_name.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';
import 'about_screen.dart';

/// Gear icon that opens [SettingsScreen] (About's app bar).
class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Settings',
        icon: const Icon(Icons.settings_outlined),
        onPressed: () => openSettings(context),
      );
}

void openSettings(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));

String delayLabel(int minutes) => minutes == 0 ? 'Instant' : '$minutes min';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    final trainer = scope?.trainer, home = scope?.home;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Felt.narrow(ListenableBuilder(
        listenable: Listenable.merge([
          AppSettings.all,
          ChartPrefs.colorBlind,
          DevMode.on,
          if (trainer != null) trainer,
          if (home != null) home,
        ]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
          children: [
            // Most used first: name, camera lens, appearance.
            const _Section(icon: Icons.badge_outlined, title: 'Your name', children: [_NameField()]),
            _Section(icon: Icons.photo_camera_outlined, title: 'Camera lens', children: [
              ValueListenableBuilder<LensChoice>(
                valueListenable: CameraLens.choice,
                builder: (context, v, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _Choices<LensChoice>(
                    keyPrefix: 'lens',
                    values: LensChoice.values,
                    selected: v,
                    label: (c) => lensChoiceLabels[c]!,
                    onSelected: CameraLens.set,
                  ),
                  const SizedBox(height: 4),
                  Text(
                      switch (v) {
                        LensChoice.auto => 'Normal lens for your cards, widest for the whole table.',
                        LensChoice.normal => 'Always the normal lens.',
                        LensChoice.widest => 'Always the ultra-wide lens (cards look smaller).',
                      },
                      style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            ]),
            _Section(icon: Icons.palette_outlined, title: 'Appearance', children: [
              const _Label('Theme'),
              _Choices<ThemeChoice>(
                keyPrefix: 'theme',
                values: ThemeChoice.values,
                selected: AppSettings.theme.value,
                label: (c) => themeChoiceLabels[c]!,
                onSelected: AppSettings.setTheme,
              ),
              const _Label('Cards'),
              Row(children: [
                Expanded(
                  child: _Choices<CardStyle>(
                    keyPrefix: 'cards',
                    values: CardStyle.values,
                    selected: AppSettings.cardStyle.value,
                    label: (c) => cardStyleLabels[c]!,
                    onSelected: AppSettings.setCardStyle,
                  ),
                ),
                const SizedBox(width: 8),
                // Live preview: one card of each suit.
                for (final s in const [0, 1, 2, 3])
                  Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: PlayingCard(card: makeCard(12, s), width: 24),
                  ),
              ]),
              SwitchListTile(
                key: const Key('settings-colorblind'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Colour-blind friendly charts'),
                value: ChartPrefs.colorBlind.value,
                onChanged: ChartPrefs.setColorBlind,
              ),
            ]),
            _Section(icon: Icons.fitness_center, title: 'Trainer', children: [
              if (trainer != null) ...[
                const _Label('Difficulty'),
                _Choices<Difficulty>(
                  keyPrefix: 'difficulty',
                  values: Difficulty.values,
                  selected: trainer.difficulty,
                  label: (d) => difficultyLabels[d]!,
                  onSelected: trainer.setDifficulty,
                ),
              ],
              SwitchListTile(
                key: const Key('settings-dice'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Solver dice on mixed hands'),
                value: AppSettings.solverDice.value,
                onChanged: AppSettings.setSolverDice,
              ),
            ]),
            _Section(icon: Icons.groups, title: 'Game nights', children: [
              if (home != null) ...[
                const _Label('TV shows hands after'),
                _Choices<int>(
                  keyPrefix: 'delay',
                  values: dashboardDelays,
                  selected: home.dashboardDelayMinutes,
                  label: delayLabel,
                  onSelected: home.setDelay,
                ),
              ],
              _Label('Currency for My result (${moneyLabel(42.5, signed: true)})'),
              _CurrencyChoices(current: AppSettings.currency.value),
              if (watchModeSupported)
                ValueListenableBuilder<bool>(
                  valueListenable: WatchSettings.autoStart,
                  builder: (context, on, _) => SwitchListTile(
                    key: const Key('settings-auto-watch'),
                    contentPadding: EdgeInsets.zero,
                    value: on,
                    onChanged: (v) => WatchSettings.set(WatchSettings.autoStart, WatchSettings.autoStartKey, v),
                    title: const Text('Start watching my cards when a game starts'),
                    subtitle: const Text('After Start playing, Watch opens and starts with your Watch settings. '
                        'Off: the hand logger, as before.'),
                  ),
                ),
            ]),
            Card(
              child: ListTile(
                key: const Key('settings-data'),
                leading: Icon(Icons.settings_backup_restore, color: Felt.accent(context)),
                title: const Text('Backup, restore & reset'),
                subtitle: const Text('In About & privacy'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen())),
              ),
            ),
            const _AdvancedSection(),
            // Testing tools: developer mode only (About: tap the version 7
            // times), last.
            if (DevMode.on.value)
              _Section(icon: Icons.science_outlined, title: 'Diagnostics', children: [
                const SwitchListTile(
                  key: Key('settings-dev-mode'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('Developer mode'),
                  subtitle: Text('Shows testing tools. Turn on again from About: tap the version 7 times'),
                  value: true,
                  onChanged: DevMode.set,
                ),
                if (bleSupported)
                  ListTile(
                    key: const Key('settings-bt-distance'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.bluetooth_searching),
                    title: const Text('Bluetooth distance test'),
                    subtitle: const Text('For testing only, not needed to play'),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const DistanceTestScreen())),
                  ),
                if (watchModeSupported)
                  Builder(
                    builder: (context) => ListTile(
                      key: const Key('settings-watch-log'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.ios_share),
                      title: const Text('Share Watch my cards diagnostics'),
                      subtitle: const Text(
                          'Timings and reads from the last few sessions, no images. Stays on this phone unless you share it'),
                      onTap: () async {
                        final ok = await WatchLogStore.export(context);
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('No Watch diagnostics yet')));
                        }
                      },
                    ),
                  ),
                if (watchModeSupported)
                  ListTile(
                    key: const Key('settings-watch-log-save'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.save_alt),
                    title: const Text('Save Watch my cards diagnostics to device'),
                    onTap: () async {
                      final ok = await WatchLogStore.saveToDevice();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(ok ? 'Diagnostics log saved' : 'Nothing saved')));
                      }
                    },
                  ),
              ]),
          ],
        ),
      )),
    );
  }
}

/// The name, edited in place and saved as you type. Empty: error outline
/// and "Needed for game nights".
class _NameField extends StatefulWidget {
  const _NameField();

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final _c = TextEditingController(text: AppSettings.playerName.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    AppSettings.playerName.addListener(_sync);
  }

  /// Changed elsewhere (a restore, the Play prompt): show it unless typing.
  void _sync() {
    if (!_focus.hasFocus && _c.text.trim() != AppSettings.playerName.value) {
      setState(() => _c.text = AppSettings.playerName.value);
    }
  }

  @override
  void dispose() {
    AppSettings.playerName.removeListener(_sync);
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlayerNameField(
        key: const Key('settings-player-name'),
        controller: _c,
        focusNode: _focus,
        warnWhenEmpty: true,
        label: 'Your name at the table',
        onChanged: (v) {
          AppSettings.setPlayerName(v);
          setState(() {});
        },
      );
}

/// Advanced / Developer: locked behind a password (dev_settings.dart);
/// once entered it stays unlocked and shows the testing switches.
class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection();

  Future<void> _unlock(BuildContext context) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => const _PasswordDialog());
    if (ok != true) return;
    await DevMode.set(true);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Developer mode unlocked')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([DevSettings.unlocked, DevSettings.cloudCards, DevSettings.devBoard, DevSettings.simPulse]),
      builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    if (!DevSettings.unlocked.value) {
      return Card(
        child: ListTile(
          key: const Key('settings-advanced'),
          leading: Icon(Icons.lock_outline, color: Felt.accent(context)),
          title: const Text('Advanced / Developer'),
          subtitle: const Text('Password needed'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _unlock(context),
        ),
      );
    }
    return _Section(icon: Icons.lock_open_outlined, title: 'Advanced / Developer', children: [
      SwitchListTile(
        key: const Key('settings-cloud-cards'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Send my cards to the cloud'),
        subtitle: const Text('With "Share my hands" on, your hole cards go to the table and its TV 20 '
            'minutes after you enter them. Off: they never leave this phone.'),
        value: DevSettings.cloudCards.value,
        onChanged: DevSettings.setCloudCards,
      ),
      SwitchListTile(
        key: const Key('settings-dev-board'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Board reading (experimental)'),
        subtitle: const Text('Watch also tries to read the community cards.'),
        value: DevSettings.devBoard.value,
        onChanged: DevSettings.setBoard,
      ),
      SwitchListTile(
        key: const Key('settings-sim-pulse'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Pulse: pretend watch'),
        subtitle: const Text('Pulse mode makes up a heart rate (about 70, with spikes) instead of reading a watch. '
            'For demos.'),
        value: DevSettings.simPulse.value,
        onChanged: DevSettings.setSimPulse,
      ),
      SwitchListTile(
        key: const Key('settings-demo-pulse'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Pulse: add a demo player'),
        subtitle: const Text('The TV on this phone also shows a made-up player ("Demo"), to try the chart '
            'with one phone. Nothing is sent.'),
        value: DevSettings.demoPulse.value,
        onChanged: DevSettings.setDemoPulse,
      ),
    ]);
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _c = TextEditingController();
  bool _wrong = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ok = await DevSettings.unlock(_c.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _wrong = true);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Developer password'),
        content: TextField(
          key: const Key('dev-password'),
          controller: _c,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(errorText: _wrong ? 'Wrong password' : null),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(key: const Key('dev-unlock'), onPressed: _submit, child: const Text('Unlock')),
        ],
      );
}

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;
  const _Section({required this.icon, required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, color: Felt.accent(context), size: 20),
                const SizedBox(width: 8),
                Flexible(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ]),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

/// Single-choice chips that wrap at narrow widths (never overflow).
class _Choices<T> extends StatelessWidget {
  final String keyPrefix;
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final void Function(T) onSelected;
  const _Choices({
    required this.keyPrefix,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final v in values)
            ChoiceChip(
              key: Key('$keyPrefix-${v is Enum ? v.name : v}'),
              label: Text(label(v)),
              selected: v == selected,
              onSelected: (_) => onSelected(v),
            ),
        ],
      );
}

class _CurrencyChoices extends StatelessWidget {
  final String current;
  const _CurrencyChoices({required this.current});

  Future<void> _other(BuildContext context) async {
    final ctl = TextEditingController(
        text: currencyPresets.contains(current) ? '' : current);
    final v = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Currency symbol'),
        content: TextField(
          key: const Key('currency-field'),
          controller: ctl,
          autofocus: true,
          maxLength: 3,
          decoration: const InputDecoration(
              hintText: 'e.g. CHF, R, zł', helperText: '1 to 3 characters, no digits'),
          onSubmitted: (t) => Navigator.pop(c, t),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Use')),
        ],
      ),
    );
    if (v == null) return;
    final ok = await AppSettings.setCurrency(v);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Use 1 to 3 characters, no digits or spaces')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final custom = !currencyPresets.contains(current);
    return Wrap(spacing: 6, runSpacing: 4, children: [
      for (final c in currencyPresets)
        ChoiceChip(
          key: Key('currency-$c'),
          label: Text(c),
          selected: c == current,
          onSelected: (_) => AppSettings.setCurrency(c),
        ),
      ChoiceChip(
        key: const Key('currency-other'),
        label: Text(custom ? current : 'Other…'),
        selected: custom,
        onSelected: (_) => _other(context),
      ),
    ]);
  }
}
