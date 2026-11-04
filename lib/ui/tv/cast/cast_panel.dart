// "Cast to a TV" at the top of the Show on the TV sheet: find the
// Chromecast on this Wi-Fi, start Felt Notes TV on it with tonight's code,
// and let go. The TV runs the table page by itself; the phone is free and
// nothing of its screen is sent. Protocol: cast_sender.dart; receiver page:
// web/cast/index.html; docs/CASTING.md.

import 'dart:async';

import 'package:flutter/material.dart';

import 'cast_discovery.dart';
import 'cast_sender.dart';

/// What the panel talks to; tests pass fakes.
class CastServices {
  final CastDiscovery discover;
  final Future<String> Function(CastDevice device, String code, void Function(CastPhase) onPhase) show;
  final Future<bool> Function(CastDevice device) stop;

  /// Android's Wi-Fi MulticastLock around discovery (native helper).
  final Future<bool> Function(bool on) multicastLock;
  final Duration searchFor;

  const CastServices({
    required this.discover,
    required this.show,
    required this.stop,
    required this.multicastLock,
    this.searchFor = const Duration(seconds: 6),
  });

  static CastServices real(Future<bool> Function(bool on) multicastLock) => CastServices(
        discover: discoverCastDevices,
        show: (d, code, onPhase) => castShowCode(host: d.host, port: d.port, code: code, onPhase: onPhase),
        stop: (d) => castStop(host: d.host, port: d.port),
        multicastLock: multicastLock,
      );
}

/// The TV Felt Notes is casting to, for this app run (so the sheet can
/// offer "Stop casting" when it is opened again).
class ActiveCast {
  final CastDevice device;
  final String code;
  const ActiveCast(this.device, this.code);
}

final activeCast = ValueNotifier<ActiveCast?>(null);

enum _Step { idle, searching, picking, none, casting, live, failed }

class CastToTvPanel extends StatefulWidget {
  /// Tonight's night code (what the TV page needs).
  final String code;
  final CastServices services;
  const CastToTvPanel({super.key, required this.code, required this.services});

  @override
  State<CastToTvPanel> createState() => _CastToTvPanelState();
}

class _CastToTvPanelState extends State<CastToTvPanel> {
  _Step step = _Step.idle;
  final devices = <CastDevice>[];
  CastDevice? target;
  CastPhase? phase;
  String? error;
  StreamSubscription<CastDevice>? _search;
  bool _locked = false;

  CastServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    final a = activeCast.value;
    if (a != null && a.code == widget.code) {
      step = _Step.live;
      target = a.device;
    }
  }

  @override
  void dispose() {
    _endSearch();
    _unlock();
    super.dispose();
  }

  void _unlock() {
    if (!_locked) return;
    _locked = false;
    unawaited(s.multicastLock(false));
  }

  /// Ends a search still running (not awaited: a finished stream's
  /// cancel may never complete).
  void _endSearch() {
    final s = _search;
    _search = null;
    if (s != null) unawaited(s.cancel());
  }

  Future<void> _find() async {
    _endSearch();
    setState(() {
      step = _Step.searching;
      devices.clear();
      error = null;
    });
    _locked = true;
    await s.multicastLock(true);
    if (!mounted) return;
    _search = s.discover(s.searchFor).listen((d) {
      if (!mounted || devices.any((x) => x.id == d.id)) return;
      setState(() {
        devices.add(d);
        devices.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      });
    }, onError: (Object e) {
      debugPrint('cast discovery: $e');
    }, onDone: () {
      _search = null;
      _unlock();
      if (mounted && step == _Step.searching) {
        setState(() => step = devices.isEmpty ? _Step.none : _Step.picking);
      }
    });
  }

  Future<void> _cast(CastDevice d) async {
    _endSearch();
    _unlock();
    setState(() {
      step = _Step.casting;
      target = d;
      phase = CastPhase.connecting;
      error = null;
    });
    try {
      await s.show(d, widget.code, (p) {
        if (mounted) setState(() => phase = p);
      });
      activeCast.value = ActiveCast(d, widget.code);
      if (mounted) setState(() => step = _Step.live);
    } catch (e) {
      if (mounted) {
        setState(() {
          step = _Step.failed;
          error = '$e';
        });
      }
    }
  }

  Future<void> _stop() async {
    final d = target;
    if (d == null) return;
    setState(() {
      step = _Step.casting;
      phase = null;
    });
    try {
      await s.stop(d);
    } catch (e) {
      debugPrint('cast stop: $e');
    }
    activeCast.value = null;
    if (mounted) setState(() => step = _Step.idle);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget tile(
            {required Key key,
            required Widget leading,
            required String title,
            String? subtitle,
            VoidCallback? onTap,
            Widget? trailing}) =>
        ListTile(
          key: key,
          contentPadding: EdgeInsets.zero,
          leading: leading,
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: trailing,
          onTap: onTap,
        );
    const spin = SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5));

    switch (step) {
      case _Step.idle:
        return tile(
          key: const Key('tv-cast-find'),
          leading: const Icon(Icons.cast_connected),
          title: 'Cast to a TV',
          subtitle: 'Finds the Chromecast on this Wi-Fi. The TV runs the table by itself; '
              'your phone stays free and your cards stay on it.',
          onTap: _find,
        );
      case _Step.searching:
      case _Step.picking:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          tile(
            key: const Key('tv-cast-searching'),
            leading: step == _Step.searching ? spin : const Icon(Icons.cast_connected),
            title: step == _Step.searching ? 'Looking for TVs…' : 'Pick the TV',
            subtitle: 'Phone and TV must be on the same Wi-Fi.',
            trailing: step == _Step.picking
                ? IconButton(
                    key: const Key('tv-cast-again'),
                    tooltip: 'Look again',
                    icon: const Icon(Icons.refresh),
                    onPressed: _find,
                  )
                : null,
          ),
          for (final d in devices)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: tile(
                key: Key('tv-cast-device-${d.id}'),
                leading: const Icon(Icons.tv),
                title: d.name,
                subtitle: d.model,
                onTap: () => _cast(d),
              ),
            ),
        ]);
      case _Step.none:
        return tile(
          key: const Key('tv-cast-none'),
          leading: const Icon(Icons.cast),
          title: 'No TV found on this Wi-Fi',
          subtitle: 'Is the phone on the same Wi-Fi as the TV? Tap to look again, or use '
              '"Cast this phone\'s screen" below.',
          onTap: _find,
        );
      case _Step.casting:
        final name = target?.name ?? 'the TV';
        return tile(
          key: const Key('tv-cast-working'),
          leading: spin,
          title: phase == null ? 'Stopping $name…' : 'Starting Felt Notes on $name…',
          subtitle: switch (phase) {
            CastPhase.connecting => 'Connecting',
            CastPhase.launching => 'The TV is loading the table page',
            CastPhase.sending || CastPhase.done => "Sending tonight's code",
            null => null,
          },
        );
      case _Step.live:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          tile(
            key: const Key('tv-cast-live'),
            leading: const Icon(Icons.cast_connected, color: Colors.green),
            title: 'Casting to ${target?.name ?? 'the TV'}',
            subtitle: 'The TV shows the table by itself. You can close this and use the phone.',
          ),
          Row(children: [
            OutlinedButton.icon(
              key: const Key('tv-cast-stop'),
              onPressed: _stop,
              icon: const Icon(Icons.stop),
              label: const Text('Stop casting'),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('tv-cast-other'),
              onPressed: _find,
              child: const Text('Another TV'),
            ),
          ]),
        ]);
      case _Step.failed:
        return tile(
          key: const Key('tv-cast-failed'),
          leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          title: 'Could not cast to ${target?.name ?? 'the TV'}',
          subtitle: '${error ?? ''}\nTap to try again, or use "Cast this phone\'s screen" below.',
          onTap: _find,
          trailing: Text('Retry', style: t.labelLarge),
        );
    }
  }
}
