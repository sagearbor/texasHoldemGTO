import 'package:flutter/material.dart';

import '../../app_data.dart';
import '../../camera/watch_log_store.dart';
import '../../camera/watch_screen.dart' show watchModeSupported;
import '../../homegame/home_game.dart';
import '../../homegame/my_result.dart';
import '../../poker/cards.dart';
import '../../trainer/trainer_model.dart';
import '../app_settings.dart';
import '../chart_prefs.dart';
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
          if (trainer != null) trainer,
          if (home != null) home,
        ]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
          children: [
            _Section(icon: Icons.palette_outlined, title: 'Appearance', children: [
              const _Label('Theme'),
              _Choices<ThemeChoice>(
                keyPrefix: 'theme',
                values: ThemeChoice.values,
                selected: AppSettings.theme.value,
                label: (c) => themeChoiceLabels[c]!,
                onSelected: AppSettings.setTheme,
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                key: const Key('settings-colorblind'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Colour-blind friendly charts'),
                subtitle: const Text('Blue / orange plus patterns on every grid'),
                value: ChartPrefs.colorBlind.value,
                onChanged: ChartPrefs.setColorBlind,
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
              const SizedBox(height: 4),
              Text(
                  AppSettings.cardStyle.value == CardStyle.fourColor
                      ? 'Clubs green, diamonds blue: no suit mix-ups.'
                      : 'Classic deck: hearts and diamonds red.',
                  style: Theme.of(context).textTheme.bodySmall),
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
                const SizedBox(height: 4),
              ],
              SwitchListTile(
                key: const Key('settings-dice'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Show solver dice on mixed hands'),
                subtitle: const Text(
                    'A roll that shows how the solver picks between actions'),
                value: AppSettings.solverDice.value,
                onChanged: AppSettings.setSolverDice,
              ),
            ]),
            _Section(icon: Icons.groups, title: 'Home game', children: [
              if (home != null) ...[
                const _Label('TV dashboard delay'),
                _Choices<int>(
                  keyPrefix: 'delay',
                  values: dashboardDelays,
                  selected: home.dashboardDelayMinutes,
                  label: delayLabel,
                  onSelected: home.setDelay,
                ),
                const SizedBox(height: 8),
              ],
              const _Label('Currency for My result'),
              _CurrencyChoices(current: AppSettings.currency.value),
              const SizedBox(height: 4),
              Text('Example: ${moneyLabel(42.5, signed: true)}',
                  style: Theme.of(context).textTheme.bodySmall),
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
            _Section(icon: Icons.save_alt, title: 'Data', children: [
              ListTile(
                key: const Key('settings-data'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.settings_backup_restore),
                title: const Text('Backup, restore & reset'),
                subtitle: const Text('In About & privacy'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AboutScreen())),
              ),
            ]),
          ],
        ),
      )),
    );
  }
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
                Text(title, style: Theme.of(context).textTheme.titleMedium),
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
