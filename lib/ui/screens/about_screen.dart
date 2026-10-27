import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_data.dart';
import '../../data/backup.dart';
import '../../data/hands_csv.dart';
import '../../homegame/home_game.dart';
import '../theme.dart';

// TODO(owner): replace with the real support address before store release
// (Play and App Store both require a contact email on the listing too).
const feedbackEmail = 'TODO-feedback@example.com';

const privacyPolicyUrl = 'https://sagearbor.github.io/texasHoldemGTO/privacy.html';

const privacyStatement = 'No account. Everything stays on this device. '
    'No ads, no tracking, no analytics. Data is never sent anywhere.';

const backupStatement = 'A backup is a file you keep: you choose where it '
    'goes (Files, Drive, email, a computer). Felt Notes never uploads it '
    'and has no server to send it to.';

const creditsText = 'Push/fold charts solved by Felt Notes; '
    '6-max charts are approximate GTO baselines.';

/// "1.2.3 (45)" from the platform's package info.
String formatVersion(String version, String buildNumber) =>
    buildNumber.isEmpty || buildNumber == version
        ? version
        : '$version ($buildNumber)';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<String> _version() async {
    try {
      final p = await PackageInfo.fromPlatform();
      return formatVersion(p.version, p.buildNumber);
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _reset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Reset all data?'),
        content: const Text(
            'This permanently deletes your trainer history, every home-game '
            'night and all settings on this device. It cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Felt.bad, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final scope = AppScope.maybeOf(context);
    await resetAllData(trainer: scope?.trainer, home: scope?.home);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('All data deleted')));
  }

  // ---------------------------------------------------------------- backup

  Rect? _origin(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
  }

  void _toast(BuildContext context, String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Shares [text] as a file (web: downloads it). Falls back to the
  /// clipboard if the platform cannot share files.
  Future<void> _shareFile(BuildContext context, String text, String name,
      String mime, String what) async {
    final origin = _origin(context);
    try {
      final file =
          XFile.fromData(utf8.encode(text), mimeType: mime, name: name);
      await Share.shareXFiles([file],
          fileNameOverrides: [name], sharePositionOrigin: origin);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      _toast(context, 'Could not share a file here: $what copied as text');
    }
  }

  Future<void> _backup(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    if (!context.mounted) return;
    await _shareFile(context, exportJson(prefs, now: now),
        backupFileName(now), 'application/json', 'backup');
  }

  Future<void> _copyBackup(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await Clipboard.setData(ClipboardData(text: exportJson(prefs)));
    if (!context.mounted) return;
    _toast(context,
        'Backup copied (${summarizeDevice(prefs).label}). Paste it somewhere safe.');
  }

  Future<void> _exportCsv(BuildContext context) async {
    final home = AppScope.maybeOf(context)?.home;
    final sessions = home?.sessions ?? const <HomeSession>[];
    if (sessions.every((s) => s.hands.isEmpty)) {
      _toast(context, 'No logged hands to export yet');
      return;
    }
    final now = DateTime.now();
    await _shareFile(context, homeHandsCsv(sessions), handsCsvFileName(now),
        'text/csv', 'CSV');
  }

  Future<void> _restore(BuildContext context) async {
    final how = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Choose a backup file'),
            subtitle: const Text('felt-notes-backup-….json'),
            onTap: () => Navigator.pop(c, 'file'),
          ),
          ListTile(
            leading: const Icon(Icons.content_paste),
            title: const Text('Paste backup text'),
            onTap: () => Navigator.pop(c, 'paste'),
          ),
        ]),
      ),
    );
    if (how == null || !context.mounted) return;
    final Future<String?> pending =
        how == 'file' ? _pickFile(context) : _paste(context);
    final text = await pending;
    if (text == null || !context.mounted) return;
    await restoreFromText(context, text);
  }

  Future<String?> _pickFile(BuildContext context) async {
    try {
      final r = await FilePicker.platform
          .pickFiles(type: FileType.any, withData: true);
      final bytes = r?.files.single.bytes;
      if (bytes == null) return null;
      if (bytes.length > 50 * 1024 * 1024) {
        if (context.mounted) {
          _toast(context, 'That file is too big to be a Felt Notes backup');
        }
        return null;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      if (context.mounted) _toast(context, 'Could not open that file');
      return null;
    }
  }

  Future<String?> _paste(BuildContext context) => showDialog<String>(
      context: context, builder: (_) => const _PasteBackupDialog());

  /// Validates [text], confirms (merge or replace), restores and reloads.
  Future<void> restoreFromText(BuildContext context, String text) async {
    final Map<String, dynamic> backup;
    final BackupSummary incoming;
    try {
      backup = parseBackup(text);
      incoming = summarizeBackup(backup);
    } on BackupFormatException catch (e) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text("Can't restore this"),
          content: Text(e.message),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final current = summarizeDevice(prefs);
    final at = DateTime.tryParse('${backup['exportedAt']}')?.toLocal();
    if (!context.mounted) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(
          'Backup${at == null ? '' : ' from ${_day(at)}'}: ${incoming.label}.\n'
          'On this device now: ${current.label}.\n\n'
          'Replace makes this device match the backup (what is here now is '
          'lost). Merge keeps both and drops duplicates.',
          key: const Key('restore-summary'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          OutlinedButton(
              onPressed: () => Navigator.pop(c, 'merge'),
              child: const Text('Merge')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Felt.bad, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(c, 'replace'),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (mode == null || !context.mounted) return;
    final scope = AppScope.maybeOf(context);
    try {
      final now = await restoreBackup(backup,
          merge: mode == 'merge', trainer: scope?.trainer, home: scope?.home);
      if (!context.mounted) return;
      _toast(context, 'Restored. This device now has ${now.label}.');
    } on BackupFormatException catch (e) {
      if (!context.mounted) return;
      _toast(context, e.message);
    }
  }

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget section(IconData icon, String title, List<Widget> body) => Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(icon, color: Felt.gold, size: 20),
                  const SizedBox(width: 8),
                  Text(title, style: t.titleMedium),
                ]),
                const SizedBox(height: 8),
                ...body,
              ],
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('About & privacy')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          section(Icons.info_outline, 'Felt Notes', [
            FutureBuilder<String>(
              future: _version(),
              builder: (_, snap) => Text(
                'Version ${snap.data ?? '…'}',
                key: const Key('about-version'),
                style: t.bodyMedium,
              ),
            ),
            const SizedBox(height: 4),
            Text('GTO poker trainer and home-game notebook.', style: t.bodyMedium),
          ]),
          section(Icons.lock_outline, 'Privacy', [
            Text(privacyStatement, style: t.bodyMedium),
            const SizedBox(height: 6),
            SelectableText('Full policy: $privacyPolicyUrl', style: t.bodySmall),
          ]),
          section(Icons.emoji_events_outlined, 'Credits', [
            Text(creditsText, style: t.bodyMedium),
          ]),
          section(Icons.mail_outline, 'Feedback', [
            Text('Ideas, bugs or a chart that looks wrong? Email:',
                style: t.bodyMedium),
            const SizedBox(height: 4),
            Row(children: [
              const Expanded(child: SelectableText(feedbackEmail)),
              IconButton(
                tooltip: 'Copy address',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(const ClipboardData(text: feedbackEmail));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Address copied')));
                },
              ),
            ]),
          ]),
          section(Icons.save_alt, 'Backup & export', [
            Text(
                'Losing or replacing your phone loses every game night '
                'unless you keep a backup.',
                style: t.bodyMedium),
            const SizedBox(height: 4),
            Text(backupStatement, style: t.bodySmall),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: () => _backup(context),
                icon: const Icon(Icons.backup_outlined),
                label: const Text('Back up my data'),
              ),
              OutlinedButton.icon(
                onPressed: () => _restore(context),
                icon: const Icon(Icons.settings_backup_restore),
                label: const Text('Restore from backup'),
              ),
              OutlinedButton.icon(
                onPressed: () => _exportCsv(context),
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('Export hands (CSV)'),
              ),
              TextButton.icon(
                onPressed: () => _copyBackup(context),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy backup as text'),
              ),
            ]),
          ]),
          section(Icons.delete_forever_outlined, 'Your data', [
            Text(
                'Delete your trainer history, home-game nights and settings '
                'from this device.',
                style: t.bodyMedium),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Felt.bad),
              onPressed: () => _reset(context),
              icon: const Icon(Icons.delete_forever),
              label: const Text('Reset all data'),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Multi-line field for restoring from backup text (the clipboard path).
class _PasteBackupDialog extends StatefulWidget {
  const _PasteBackupDialog();

  @override
  State<_PasteBackupDialog> createState() => _PasteBackupDialogState();
}

class _PasteBackupDialogState extends State<_PasteBackupDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Paste backup text'),
        content: TextField(
          key: const Key('backup-paste-field'),
          controller: _ctl,
          minLines: 6,
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            hintText: '{"app": "felt_notes", …}',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _ctl.text),
              child: const Text('Next')),
        ],
      );
}
