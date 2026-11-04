/// The player's name at the table: typed once (onboarding, or the first
/// time Play needs it) and reused at every game night. Never asked again
/// once set; Settings edits it.
library;

import 'package:flutter/material.dart';

import 'app_settings.dart';

const playerNameQuestion = 'What should the table call you?';
const playerNameNeeded = 'Needed for game nights';

/// True when a name is set. Otherwise asks once ([playerNameQuestion]);
/// true if the player typed one, false for "Not now".
Future<bool> ensurePlayerName(BuildContext context) async {
  if (AppSettings.playerName.value.trim().isNotEmpty) return true;
  final n = await askPlayerName(context);
  return n != null && n.isNotEmpty;
}

/// The name dialog: Continue stays disabled until a usable name is typed.
/// Returns the saved name, or null when dismissed.
Future<String?> askPlayerName(BuildContext context) async {
  final v = await showDialog<String>(
    context: context,
    builder: (_) => const _NameDialog(),
  );
  if (v == null) return null;
  final ok = await AppSettings.setPlayerName(v);
  return ok ? AppSettings.playerName.value : null;
}

class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _c = TextEditingController(text: AppSettings.playerName.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool get _valid => AppSettings.normalizePlayerName(_c.text) != null;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text(playerNameQuestion),
        content: PlayerNameField(
          key: const Key('name-prompt-field'),
          controller: _c,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          onSubmitted: (v) {
            if (_valid) Navigator.pop(context, v);
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
          FilledButton(
            key: const Key('name-prompt-continue'),
            onPressed: _valid ? () => Navigator.pop(context, _c.text) : null,
            child: const Text('Continue'),
          ),
        ],
      );
}

/// The one name text field (onboarding, the dialog, Settings). Empty shows
/// [playerNameNeeded] in the error colour when [warnWhenEmpty].
class PlayerNameField extends StatelessWidget {
  final TextEditingController controller;
  final bool autofocus;
  final bool warnWhenEmpty;
  final String? label;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  const PlayerNameField({
    super.key,
    required this.controller,
    this.autofocus = false,
    this.warnWhenEmpty = false,
    this.label,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final empty = controller.text.trim().isEmpty;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      maxLength: 24,
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        labelText: label,
        hintText: label == null ? 'Your name' : null,
        border: const OutlineInputBorder(),
        counterText: '',
        errorText: warnWhenEmpty && empty ? playerNameNeeded : null,
        helperText: warnWhenEmpty && empty ? null : 'Typed once, used at every game night.',
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}
