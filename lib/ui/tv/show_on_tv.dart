// "Show on the TV": how to get the table TV page onto a real TV, for an
// organizer who cannot find Cast. No Google Cast sender: a custom receiver
// needs a paid Cast developer registration (zero-cost rule), so this hands
// the link to the browser (Chrome's ⋮ → Cast… tab cast) or opens the
// phone's own screen-cast settings. Native side: MainActivity.kt and
// AppDelegate.swift, channel `felt_notes/tv_cast`.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const tvCastChannel = MethodChannel('felt_notes/tv_cast');

/// Calls the native helper; false when it is missing or failed (web,
/// tests, an older native build).
Future<bool> _call(String method, [Object? args]) async {
  if (kIsWeb) return false;
  try {
    return await tvCastChannel.invokeMethod<bool>(method, args) ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    debugPrint('tv_cast $method: ${e.code} ${e.message}');
    return false;
  }
}

/// Opens [url] in the external browser (Chrome on Android, Safari on iOS).
Future<bool> openInBrowser(String url) => _call('openUrl', {'url': url});

/// Android: the system Cast / screen-cast settings.
Future<bool> openCastSettings() => _call('castSettings');

/// The organizer's "Show on the TV" button.
class ShowOnTvButton extends StatelessWidget {
  final String url;
  const ShowOnTvButton({super.key, required this.url});

  @override
  Widget build(BuildContext context) => FilledButton.icon(
        key: const Key('show-on-tv'),
        onPressed: () => showOnTvSheet(context, url),
        icon: const Icon(Icons.cast),
        label: const Text('Show on the TV'),
      );
}

Future<void> showOnTvSheet(BuildContext context, String url) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ShowOnTvSheet(url: url),
    );

class ShowOnTvSheet extends StatelessWidget {
  final String url;

  /// Tests set the platform; null = the device's.
  final TargetPlatform? platform;
  const ShowOnTvSheet({super.key, required this.url, this.platform});

  void _say(BuildContext context, String text) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ios = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Show the table on the TV', style: t.titleMedium),
          const SizedBox(height: 4),
          Text('The TV page runs in any browser. Pick one way:', style: t.bodySmall),
          const SizedBox(height: 8),
          ListTile(
            key: const Key('tv-open-browser'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.open_in_browser),
            title: Text(ios ? 'Open in Safari, then AirPlay' : 'Open in Chrome, then ⋮ → Cast…'),
            subtitle: Text(ios
                ? 'Opens the TV page. Then Control Center → Screen Mirroring → your Apple TV.'
                : 'Opens the TV page. Then Chrome menu ⋮ → Cast… → your TV (or Chromecast).'),
            onTap: () async {
              if (!await openInBrowser(url) && context.mounted) {
                Clipboard.setData(ClipboardData(text: url));
                _say(context, 'Could not open the browser: link copied, paste it into Chrome');
              }
            },
          ),
          if (ios)
            const ListTile(
              key: Key('tv-cast-screen'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.airplay),
              title: Text("AirPlay this phone's screen"),
              subtitle: Text('Swipe down from the top-right corner → Screen Mirroring → your TV, '
                  'then open the TV preview here.'),
            )
          else
            ListTile(
              key: const Key('tv-cast-screen'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cast),
              title: const Text("Cast this phone's screen"),
              subtitle: const Text('Opens Cast settings. Or swipe down twice → Screen cast. '
                  'Then open the TV preview here.'),
              onTap: () async {
                if (!await openCastSettings() && context.mounted) {
                  _say(context, 'Swipe down twice from the top → Screen cast');
                }
              },
            ),
          ListTile(
            key: const Key('tv-copy-link'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.copy),
            title: const Text('Copy the TV link'),
            subtitle: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () {
              Clipboard.setData(ClipboardData(text: url));
              _say(context, 'TV link copied');
            },
          ),
          const SizedBox(height: 4),
          Text('A laptop, tablet or smart-TV browser works too: open the link there.', style: t.bodySmall),
        ]),
      ),
    );
  }
}
