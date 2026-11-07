// Small Pulse pieces used on the phone and the TV: the face circle
// (selfie, or coloured initials), the "Share my heart rate" switch, and the
// end-of-night summary card (made to be screenshotted).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../pulse/pulse_board.dart';
import '../../pulse/pulse_profile.dart';
import '../../pulse/pulse_service.dart';
import '../../sync/night_merge.dart' show clockLabel;
import '../theme.dart';
import 'pulse_profile_screen.dart';
import 'pulse_screen.dart';

/// A round face: the selfie, or initials on [colour].
class FaceCircle extends StatelessWidget {
  final Uint8List? face;
  final String name;
  final Color colour;
  final double size;

  /// A ring around it (the line colour on the TV; gold for the leader).
  final Color? ring;
  final double ringWidth;

  const FaceCircle(
      {super.key, this.face, required this.name, required this.colour, this.size = 48, this.ring, this.ringWidth = 3});

  /// From the base64 the cloud holds.
  factory FaceCircle.b64(String? b64,
      {Key? key, required String name, required Color colour, double size = 48, Color? ring, double ringWidth = 3}) {
    Uint8List? bytes;
    if (b64 != null) {
      try {
        bytes = base64Decode(b64);
      } catch (_) {}
    }
    return FaceCircle(
        key: key, face: bytes, name: name, colour: colour, size: size, ring: ring, ringWidth: ringWidth);
  }

  @override
  Widget build(BuildContext context) {
    final inner = face == null
        ? Container(
            color: colour,
            alignment: Alignment.center,
            child: Text(initialsOf(name),
                style: TextStyle(color: Colors.white, fontSize: size * 0.38, fontWeight: FontWeight.w800)),
          )
        : Image.memory(face!, fit: BoxFit.cover, gaplessPlayback: true,
            errorBuilder: (_, __, ___) => Container(color: colour));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: ring == null ? null : Border.all(color: ring!, width: ringWidth),
      ),
      child: ClipOval(child: inner),
    );
  }
}

/// "Share my heart rate with this table": the per-night switch on the
/// player's pad and the host's sheet. Turning it on the first time asks
/// for a name and selfie; on opens the Pulse screen.
class PulseShareTile extends StatelessWidget {
  const PulseShareTile({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = PulseService.instance;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) => Card(
        child: Column(children: [
          SwitchListTile(
            key: const Key('pulse-share'),
            secondary: Icon(Icons.favorite, color: svc.on ? Colors.redAccent : null),
            title: const Text('Share my heart rate with this table'),
            subtitle: const Text('Pulse: your watch, on the TV chart. Off by default; '
                'off deletes it from the table.'),
            value: svc.on,
            onChanged: (v) => v ? turnPulseOn(context) : svc.setOn(false),
          ),
          if (svc.on)
            ListTile(
              key: const Key('pulse-open'),
              leading: const Icon(Icons.monitor_heart_outlined),
              title: Text(svc.bpm == null ? 'Open Pulse' : 'Open Pulse · ${svc.bpm} bpm'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openPulseScreen(context),
            ),
        ]),
      ),
    );
  }
}

/// Turns Pulse on for this night: the profile first if there is none,
/// then the Pulse screen.
Future<void> turnPulseOn(BuildContext context) async {
  final svc = PulseService.instance;
  final p = await PulseProfileStore.load();
  if (!context.mounted) return;
  if (p == null) {
    final made = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const PulseProfileScreen(firstTime: true)));
    if (made != true || !context.mounted) return;
  }
  await svc.setOn(true);
  if (context.mounted) await openPulseScreen(context);
}

String _hand(PulseAward a) =>
    a.hand != null ? 'hand ${a.hand}' : (a.atMs != null ? clockLabel(a.atMs!) : '');

/// The night's three awards, big and dark, for a screenshot.
class PulseSummaryCard extends StatelessWidget {
  final PulseSummary summary;
  final double scale;
  const PulseSummaryCard({super.key, required this.summary, this.scale = 1});

  @override
  Widget build(BuildContext context) {
    TextStyle st(double s, {Color c = Colors.white, FontWeight w = FontWeight.w600}) =>
        TextStyle(color: c, fontSize: s * scale, fontWeight: w);
    Widget row(IconData icon, Color ic, String label, PulseAward a, String value, String? note) => Padding(
          padding: EdgeInsets.symmetric(vertical: 8 * scale),
          child: Row(children: [
            Icon(icon, color: ic, size: 34 * scale),
            SizedBox(width: 12 * scale),
            FaceCircle.b64(a.member.faceB64, name: a.member.name, colour: Felt.feltDark, size: 52 * scale),
            SizedBox(width: 12 * scale),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: st(15, c: const Color(0xFF9FB3A8))),
                Text(a.member.name, style: st(24, w: FontWeight.w800), overflow: TextOverflow.ellipsis),
                if (note != null && note.isNotEmpty) Text(note, style: st(14, c: const Color(0xFF9FB3A8))),
              ]),
            ),
            Text(value, style: st(28, c: Felt.gold, w: FontWeight.w800)),
          ]),
        );
    final s = summary;
    return Container(
      key: const Key('pulse-summary'),
      padding: EdgeInsets.all(18 * scale),
      decoration: BoxDecoration(
        color: const Color(0xFF10221A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Felt.gold.withOpacity(0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(Icons.favorite, color: Colors.redAccent, size: 26 * scale),
          SizedBox(width: 8 * scale),
          Flexible(
              child: Text('Pulse: the night',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: st(24, c: Felt.gold, w: FontWeight.w800))),
        ]),
        SizedBox(height: 6 * scale),
        if (s.calmest case final a?)
          row(Icons.self_improvement, const Color(0xFF199E70), 'Calmest player', a, '+${a.value}',
              'bpm above their own resting, on average'),
        if (s.spike case final a?)
          row(Icons.bolt, const Color(0xFFD95926), 'Biggest spike', a, '+${a.value}',
              '${a.from} → ${(a.from ?? 0) + a.value.toInt()} bpm · ${_hand(a)}'),
        if (s.highest case final a?)
          row(Icons.local_fire_department, const Color(0xFFE66767), 'Highest heart rate', a, '${a.value}',
              'bpm · ${_hand(a)}'),
        SizedBox(height: 4 * scale),
        Text('Felt Notes · Pulse', style: st(12, c: const Color(0xFF9FB3A8), w: FontWeight.w500)),
      ]),
    );
  }
}
