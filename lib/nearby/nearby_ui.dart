/// Nearby games, on screen: the "Nearby game: Sage's game — Join" card
/// (one obvious button; the expected case is exactly one game), the
/// just-in-time Bluetooth ask, the one-tap join and the optional seat
/// calibration diagram for the seating experiment.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync/night_events.dart' show codeAlphabet;
import '../sync/table_night_service.dart';
import '../ui/app_settings.dart';
import '../ui/dev_mode.dart';
import '../ui/player_name.dart' show askPlayerName;
import '../ui/screens/table_night_screen.dart' show PlayerPadScreen;
import '../ui/theme.dart';
import 'ble_payload.dart';
import 'nearby_ble.dart';
import 'nearby_service.dart';
import 'uwb_android.dart';

NearbyService get _near => NearbyService.instance;
TableNightService get _tn => TableNightService.instance;

/// Above the tab bar, on every tab: shown only while a game is heard nearby and this
/// phone is not in it.
class NearbyGameBanner extends StatelessWidget {
  const NearbyGameBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_near, _tn]),
      builder: (context, _) {
        final games = _near.games;
        if (games.isEmpty || _tn.night != null) return const SizedBox.shrink();
        final t = Theme.of(context).textTheme;
        return Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Card(
              color: Felt.accent(context).withOpacity(0.16),
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: Column(children: [
                  for (final g in games.take(3))
                    Row(children: [
                      Icon(Icons.bluetooth_searching, color: Felt.accent(context)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Nearby game: ${g.label}',
                            key: const Key('nearby-game'), style: t.titleSmall, overflow: TextOverflow.ellipsis),
                      ),
                      FilledButton(
                        key: const Key('nearby-join'),
                        onPressed: () => joinNearbyGame(context, g),
                        child: const Text('Join'),
                      ),
                    ]),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Setup screen, before Bluetooth was ever allowed: the one place that
/// asks, with a plain reason first.
class FindNearbyButton extends StatelessWidget {
  const FindNearbyButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!bleSupported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([_near, _tn]),
      builder: (context, _) {
        if (_tn.night != null) return const SizedBox.shrink();
        if (_near.allowed) {
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                _near.games.isEmpty
                    ? (_near.poweredOn ? 'Looking for a game nearby…' : 'Bluetooth is off: turn it on to find a game nearby.')
                    : 'Game nearby: tap Join at the top.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center),
          );
        }
        return OutlinedButton.icon(
          onPressed: () => askBluetooth(context),
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text('Find a game nearby'),
        );
      },
    );
  }
}

/// Explains, then shows the OS prompt. True when Bluetooth may be used.
Future<bool> askBluetooth(BuildContext context, {bool hosting = false}) async {
  if (_near.allowed) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(hosting ? 'Let phones nearby join' : 'Find a game nearby'),
      content: Text(hosting
          ? 'Felt Notes uses Bluetooth so phones at the table see this game and join with one tap, '
              'no internet needed. While the game runs it also notes how strong the other Felt Notes '
              "phones' signals are, for a seating experiment. Nothing else is looked at."
          : 'Felt Notes uses Bluetooth to find a game hosted by a phone at your table, so you can join '
              "with one tap, no internet needed. While you are in a game it also notes how strong the other "
              "Felt Notes phones' signals are, for a seating experiment. Nothing else is looked at."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Continue')),
      ],
    ),
  );
  if (ok != true) return false;
  final yes = await _near.enable();
  if (!yes && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Bluetooth was not allowed. You can still join by photographing the QR.')));
  }
  return yes;
}

const _neutralNameKey = 'nearby_neutral_name_v1';

/// The name to join with: the one set at first launch or in Settings.
/// Older installs without one are asked once; skipping (or cancelling)
/// joins as a neutral "Player K7QX", remembered so it is never asked
/// again.
Future<String> _joinName(BuildContext context) async {
  final have = AppSettings.playerName.value;
  if (have.isNotEmpty) return have;
  SharedPreferences? p;
  try {
    p = await SharedPreferences.getInstance();
    final neutral = p.getString(_neutralNameKey);
    if (neutral != null) return neutral;
  } catch (_) {}
  if (context.mounted) {
    final n = await askPlayerName(context);
    if (n != null && n.isNotEmpty) return n;
  }
  final r = math.Random();
  final neutral = 'Player ${String.fromCharCodes([for (var i = 0; i < 4; i++) codeAlphabet.codeUnitAt(r.nextInt(codeAlphabet.length))])}';
  try {
    await p?.setString(_neutralNameKey, neutral);
  } catch (_) {}
  return neutral;
}

/// One tap: join with the remembered name, private (a joiner's cards and
/// hands stay on the phone; "Share my hands with the table" is under
/// Advanced on the pad), then the optional calibration and the player pad.
Future<void> joinNearbyGame(BuildContext context, NearbyGame g) async {
  final name = await _joinName(context);
  if (!context.mounted) return;
  try {
    await _tn.join(g.ticket, name: name, scannedAtMs: DateTime.now().millisecondsSinceEpoch, sharing: false);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not join ($e)')));
    }
    return;
  }
  if (!context.mounted) return;
  final nav = Navigator.of(context);
  await maybeAskUwb(context);
  if (!context.mounted) return;
  await showSeatCalibration(context);
  await nav.push(MaterialPageRoute(builder: (_) => const PlayerPadScreen()));
}

/// "Where are you sitting?" for the seating experiment: tap a spot on the
/// table, host at the bottom. Clearly optional; logged with the time.
/// Developer mode only: players are never asked where they sit.
Future<void> showSeatCalibration(BuildContext context) async {
  if (!DevMode.on.value) return;
  final picked = await showModalBottomSheet<Offset>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SeatPicker(),
  );
  if (picked == null) return;
  // Angle clockwise from the host (bottom), seen from above.
  final dx = picked.dx - 0.5, dy = picked.dy - 0.5;
  final a = (math.atan2(dy, dx) * 180 / math.pi - 90 + 360) % 360;
  await _near.recordSeat(picked.dx, picked.dy, a);
}

class _SeatPicker extends StatefulWidget {
  const _SeatPicker();
  @override
  State<_SeatPicker> createState() => _SeatPickerState();
}

class _SeatPickerState extends State<_SeatPicker> {
  Offset? _p;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Calibration (optional): where are you sitting?', style: t.titleMedium),
          const SizedBox(height: 4),
          Text(
              'Helps test a seat-finding experiment. The host is at the bottom. Tap your spot, or skip: '
              'it changes nothing in the game.',
              style: t.bodySmall),
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 1.3,
            child: LayoutBuilder(builder: (context, box) {
              return GestureDetector(
                onTapDown: (d) => setState(() => _p = Offset(
                    (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0), (d.localPosition.dy / box.maxHeight).clamp(0.0, 1.0))),
                child: CustomPaint(painter: _TablePainter(_p, Felt.accent(context)), size: Size.infinite),
              );
            }),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Skip'))),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _p == null ? null : () => Navigator.pop(context, _p),
                child: const Text('This is me'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _TablePainter extends CustomPainter {
  final Offset? p;
  final Color accent;
  _TablePainter(this.p, this.accent);

  @override
  void paint(Canvas c, Size s) {
    final table = Rect.fromLTWH(s.width * 0.15, s.height * 0.18, s.width * 0.7, s.height * 0.64);
    c.drawOval(table, Paint()..color = Felt.feltGreen);
    c.drawOval(table, Paint()
      ..color = Colors.brown.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6);
    final host = Offset(s.width / 2, s.height * 0.92);
    c.drawCircle(host, 10, Paint()..color = Colors.grey.shade600);
    final tp = TextPainter(
        text: const TextSpan(text: 'host', style: TextStyle(color: Colors.grey, fontSize: 11)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(c, host + Offset(14, -tp.height / 2));
    final q = p;
    if (q != null) c.drawCircle(Offset(q.dx * s.width, q.dy * s.height), 14, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_TablePainter old) => old.p != p;
}

/// The organizer's sheet: is this game visible to phones nearby.
class NearbyHostTile extends StatelessWidget {
  const NearbyHostTile({super.key});

  @override
  Widget build(BuildContext context) {
    if (!bleSupported) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: _near,
      builder: (context, _) {
        if (!_near.allowed) {
          return OutlinedButton.icon(
            onPressed: () async {
              if (await askBluetooth(context, hosting: true) && context.mounted) await maybeAskUwb(context);
            },
            icon: const Icon(Icons.bluetooth),
            label: const Text('Let phones nearby join (no internet needed)'),
          );
        }
        final on = _near.advertising != null && !_near.advertiseFailed && _near.poweredOn;
        return Row(children: [
          Icon(on ? Icons.bluetooth_connected : Icons.bluetooth_disabled, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                on
                    ? 'Phones nearby with Felt Notes open on Play see this game and join with one tap.'
                    : (_near.poweredOn ? 'This phone cannot advertise over Bluetooth.' : 'Bluetooth is off.'),
                style: t.bodySmall),
          ),
        ]);
      },
    );
  }
}

/// Android phones with UWB hardware only, once in a game with Bluetooth
/// allowed: explain, then ask for the UWB permission. Everyone else: no
/// prompt, nothing happens. Developer mode only (seating experiment).
Future<void> maybeAskUwb(BuildContext context) async {
  if (!DevMode.on.value) return;
  if (kIsWeb || !Platform.isAndroid || !_near.allowed) return;
  try {
    final c = await AndroidUwb().ensurePermission(() async {
      if (!context.mounted) return false;
      final yes = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Measure distances with UWB?'),
          content: const Text('This phone has UWB, which measures the distance to other Android phones with UWB in '
              'this game to within a few centimetres, for the seat-finding experiment. Android asks for the '
              '"Nearby devices" permission for it. Nothing changes in the game if you say no.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Continue')),
          ],
        ),
      );
      return yes == true;
    });
    _near.uwbTelemetry.capability = c;
    await _near.refreshUwb();
  } catch (_) {
    // Never in the way of joining.
  }
}
