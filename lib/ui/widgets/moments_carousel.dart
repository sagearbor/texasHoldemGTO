import 'dart:async';

import 'package:flutter/material.dart';

import '../../gto/spots.dart';
import '../../homegame/home_game.dart';
import '../../homegame/moments.dart';
import '../theme.dart';

/// Dark-only by design: shown on the TV dashboard, which forces the dark
/// felt theme (see Felt.darkOnly), so the white-on-felt colours are fixed.
/// Big-type rotating callout for the TV dashboard. Pass only the hands the
/// dashboard may show (past its delay cutoff). Renders nothing when there
/// is nothing to say yet.
class MomentsCarousel extends StatefulWidget {
  final List<LoggedHand> hands;
  final SpotLibrary library;
  final Duration every;
  const MomentsCarousel({
    super.key,
    required this.hands,
    required this.library,
    this.every = const Duration(seconds: 15),
  });

  @override
  State<MomentsCarousel> createState() => _MomentsCarouselState();
}

class _MomentsCarouselState extends State<MomentsCarousel> {
  Timer? _timer;
  int _i = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.every, (_) {
      if (mounted) setState(() => _i++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final moments = dashboardMoments(widget.hands, widget.library);
    if (moments.isEmpty) return const SizedBox.shrink();
    final m = moments[_i % moments.length];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        decoration: BoxDecoration(
          color: Felt.feltCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Felt.gold.withOpacity(0.5)),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          child: Column(
            key: ValueKey('${m.label}|${m.headline}'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(m.label.toUpperCase(),
                      style: const TextStyle(color: Felt.gold, fontSize: 13, letterSpacing: 1.4)),
                ),
                if (moments.length > 1)
                  Text('${_i % moments.length + 1}/${moments.length}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ]),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(m.headline,
                    maxLines: 1,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 52, fontWeight: FontWeight.w800, height: 1.1)),
              ),
              Text(m.detail, style: const TextStyle(color: Colors.white70, fontSize: 16)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One-line "Tonight's drama" from story-tagged hands past the delay.
class DramaLine extends StatelessWidget {
  final List<LoggedHand> hands;
  const DramaLine({super.key, required this.hands});

  @override
  Widget build(BuildContext context) {
    final line = dramaLine(hands);
    if (line == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text.rich(
        TextSpan(children: [
          const TextSpan(
              text: "Tonight's drama: ",
              style: TextStyle(color: Felt.gold, fontWeight: FontWeight.w700)),
          TextSpan(text: line),
        ]),
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }
}
