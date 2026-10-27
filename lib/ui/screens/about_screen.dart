import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app_data.dart';
import '../theme.dart';

// TODO(owner): replace with the real support address before store release
// (Play and App Store both require a contact email on the listing too).
const feedbackEmail = 'TODO-feedback@example.com';

const privacyPolicyUrl = 'https://sagearbor.github.io/texasHoldemGTO/privacy.html';

const privacyStatement = 'No account. Everything stays on this device. '
    'No ads, no tracking, no analytics. Data is never sent anywhere.';

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
      // Web: hand the plugin the page URL so it reads version.json from
      // there first. Its own fallback (engine asset base URL) threw before
      // any request on Flutter 3.22, so About showed "Version unknown".
      final p = await PackageInfo.fromPlatform(
          baseUrl: kIsWeb ? Uri.base.toString() : null);
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
