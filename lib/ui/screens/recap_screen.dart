import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../gto/coach.dart';
import '../../homegame/home_game.dart';
import '../../homegame/moments.dart';
import '../../homegame/my_result.dart';
import '../../homegame/recap.dart';
import '../../poker/cards.dart';
import '../theme.dart';
import '../widgets/my_result_dialog.dart';
import '../widgets/share_card.dart';

/// End-of-night "Wrapped": one big felt card per stat, swipe through them.
/// Cards whose sample is too small are left out rather than shown empty.
class RecapScreen extends StatefulWidget {
  final HomeGameModel model;
  final HomeSession session;
  const RecapScreen({super.key, required this.model, required this.session});

  @override
  State<RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends State<RecapScreen> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = nightRecap(widget.session, widget.model.library);
    final cards = recapCards(r);
    return Scaffold(
      backgroundColor: Felt.feltDark,
      appBar: AppBar(
        backgroundColor: Felt.feltDark,
        foregroundColor: Colors.white,
        title: Text(widget.session.name),
        actions: [
          IconButton(
            tooltip: 'My result',
            icon: const Icon(Icons.payments_outlined),
            onPressed: () async {
              if (await editMyResult(context, widget.model, widget.session)) setState(() {});
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                for (final c in cards)
                  Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), child: c),
              ],
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < cards.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.all(3),
                width: i == _page ? 18 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: i == _page ? Felt.gold : Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Felt.gold,
                      side: const BorderSide(color: Felt.gold),
                      minimumSize: const Size.fromHeight(48)),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: recapText(r)));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Recap copied')));
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy recap'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Builder(
                  builder: (bc) => OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Felt.gold,
                        side: const BorderSide(color: Felt.gold),
                        minimumSize: const Size.fromHeight(48)),
                    onPressed: () => shareCardImage(bc,
                        card: NightShareCard(r),
                        fileName: 'felt-notes-recap.png',
                        fallbackText: recapText(r)),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share image'),
                  ),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Felt.gold,
                      foregroundColor: Felt.feltDark,
                      minimumSize: const Size.fromHeight(48)),
                  onPressed: () {
                    if (_page < cards.length - 1) {
                      _pages.nextPage(
                          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  },
                  child: Text(_page < cards.length - 1 ? 'Next' : 'Done'),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The recap's cards, in order, already gated on sample size.
List<Widget> recapCards(NightRecap r) {
  final st = r.stats;
  final out = <Widget>[
    RecapCard(
      icon: Icons.style,
      label: 'Tonight',
      value: '${st.logged}',
      caption: st.logged == 1 ? 'hand logged' : 'hands logged',
      lines: [
        if (r.duration != null) 'over ${durationLabel(r.duration!)}',
        if (st.dealt > 0) '${st.dealt} with your cards',
        if (st.dealt > 0 && r.best == null) 'card luck needs the equity table',
        if (st.logged < 10) 'Short night: log more hands for the full recap',
      ],
    ),
  ];
  if (r.best != null) {
    final h = r.best!;
    out.add(RecapCard(
      icon: Icons.emoji_events_outlined,
      label: 'Best hand',
      value: h.hand!.name,
      caption: '${cardToString(h.cards![0])} ${cardToString(h.cards![1])}',
      lines: [
        'Hand #${h.number} from ${h.position}',
        '${pct(r.bestEquity)} vs a random hand',
        if (h.dealer != null) 'Dealt by ${h.dealer}',
      ],
    ));
  }
  if (r.coldRun != null) {
    out.add(RecapCard(
      icon: Icons.ac_unit,
      label: 'Coldest stretch',
      value: luckLabel(r.coldRun!.avg),
      caption: 'card luck over ${RecapGates.coldRunWindow} dealt hands',
      lines: [
        'Hands #${r.coldRun!.from} to #${r.coldRun!.to}',
        'Whole night: ${luckLabel(st.avgStrength)}',
      ],
    ));
  }
  if (r.showPremiums) {
    out.add(RecapCard(
      icon: Icons.diamond_outlined,
      label: 'Premiums',
      value: '${st.premiums}',
      caption: 'JJ+ or AK',
      lines: [
        'Expected about ${r.expectedPremiums.toStringAsFixed(1)} in ${st.dealt} hands',
        st.premiums > r.expectedPremiums + 0.5
            ? 'Above your share'
            : (st.premiums + 0.5 < r.expectedPremiums ? 'Below your share' : 'About your share'),
      ],
    ));
  }
  if (r.showStyle) {
    out.add(RecapCard(
      icon: Icons.psychology_outlined,
      label: 'Your style',
      value: st.style,
      small: true,
      lines: [
        'VPIP ${pct(st.vpipPct)}: put money in preflop',
        'PFR ${pct(st.pfrPct)}: raised preflop',
        if (st.coverage < 0.7) 'Only ${pct(st.coverage)} of hands had an action logged',
      ],
    ));
  }
  if (r.showGto) {
    out.add(RecapCard(
      icon: Icons.school_outlined,
      label: 'GTO preflop',
      value: r.gtoGrade!,
      caption: '${pct(st.gtoScore)} of ${st.graded} unopened spots',
      lines: [
        if (st.misses.isNotEmpty)
          'Most teachable: ${st.misses.last.$1.hand!.name} from ${st.misses.last.$1.position}',
      ],
    ));
  }
  if (r.showFoldStreak) {
    out.add(RecapCard(
      icon: Icons.hourglass_bottom,
      label: 'Longest fold streak',
      value: '${r.foldStreak}',
      caption: 'folds in a row',
    ));
  }
  if (r.showDealers) out.add(_DealerCard(r.dealers));
  final told = stories(r.session.hands);
  if (told.isNotEmpty) {
    out.add(RecapCard(
      icon: Icons.local_fire_department_outlined,
      label: 'Stories',
      value: '${told.length}',
      caption: told.length == 1 ? 'hand worth retelling' : 'hands worth retelling',
      lines: [for (final h in told.reversed.take(8)) storyLine(h)],
    ));
  }
  final s = r.session;
  if (s.buyIn != null || s.cashOut != null) {
    out.add(RecapCard(
      icon: Icons.payments_outlined,
      label: 'My result',
      value: s.net == null ? '–' : moneyLabel(s.net!, signed: true),
      caption: myResultNote,
      lines: [
        if (s.buyIn != null) 'Buy-in ${moneyLabel(s.buyIn!)}',
        if (s.cashOut != null) 'Cash-out ${moneyLabel(s.cashOut!)}',
      ],
    ));
  }
  if (r.awards.isNotEmpty) {
    out.add(RecapCard(
      icon: Icons.military_tech_outlined,
      label: 'Awards',
      value: '${r.awards.length}',
      caption: r.awards.length == 1 ? 'award tonight' : 'awards tonight',
      lines: [for (final a in r.awards) '${a.title}: ${a.detail}'],
    ));
  }
  return out;
}

class RecapCard extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final String caption;
  final List<String> lines;
  final bool small;
  const RecapCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.caption = '',
    this.lines = const [],
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return _Felt(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: Felt.gold, size: 40),
        const SizedBox(height: 10),
        Text(label.toUpperCase(),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Felt.gold, fontSize: 14, letterSpacing: 2)),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value,
              style: TextStyle(
                  color: Colors.white,
                  fontSize: small ? 40 : 84,
                  fontWeight: FontWeight.w800,
                  height: 1.1)),
        ),
        if (caption.isNotEmpty)
          Text(caption,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 17)),
        const SizedBox(height: 18),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(l,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
          ),
      ]),
    );
  }
}

class _Felt extends StatelessWidget {
  final Widget child;
  const _Felt({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Felt.gold.withOpacity(0.5), width: 1.5),
        gradient: const RadialGradient(
          colors: [Color(0xFF2F6B47), Felt.feltCard],
          radius: 1.1,
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: Center(child: SingleChildScrollView(child: child)),
    );
  }
}

class _DealerCard extends StatelessWidget {
  final DealerLuck d;
  const _DealerCard(this.d);

  @override
  Widget build(BuildContext context) {
    final golden = d.goldenArm, doom = d.dealerOfDoom;
    return _Felt(
      child: Column(children: [
        const Icon(Icons.back_hand_outlined, color: Felt.gold, size: 40),
        const SizedBox(height: 10),
        const Text('DEALER LUCK',
            style: TextStyle(color: Felt.gold, fontSize: 14, letterSpacing: 2)),
        const SizedBox(height: 14),
        if (golden != null) _award('Golden Arm', golden),
        if (doom != null) _award('Dealer of Doom', doom),
        const SizedBox(height: 12),
        for (final r in d.ranked)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(
                  child: Text(r.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 16))),
              Text('${r.hands} hands  ',
                  style: const TextStyle(color: Colors.white60, fontSize: 13)),
              SizedBox(
                width: 64,
                child: Text(luckLabel(r.avgEquity),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        color: r.avgEquity >= 0.5 ? Felt.good : Felt.bad,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        const SizedBox(height: 8),
        const Text('Card luck vs a random hand, dealers with ${RecapGates.dealerMinHands}+ hands',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 12)),
      ]),
    );
  }

  Widget _award(String title, DealerLuckRow r) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(children: [
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 15)),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(r.name,
                style: const TextStyle(
                    color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800)),
          ),
          Text(
              '${luckLabel(r.avgEquity)} over ${r.hands} hands'
              '${r.best == null ? '' : ' · best ${r.best!.name}'}',
              style: const TextStyle(color: Colors.white60, fontSize: 13)),
        ]),
      );
}
