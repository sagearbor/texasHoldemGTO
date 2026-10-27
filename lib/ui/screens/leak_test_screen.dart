import 'dart:math';

import 'package:flutter/material.dart';

import '../../app_data.dart';
import '../../gto/coach.dart';
import '../../gto/spots.dart';
import '../../trainer/leak_test.dart';
import '../../trainer/trainer_model.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';

enum _Stage { welcome, offer, test, verdict }

/// First-launch onboarding: welcome card, the 60-second leak test offer,
/// 10 fast hands with no explanations, then a verdict. With
/// [showWelcome] false (Help → Retake) it opens at the offer.
class OnboardingFlow extends StatefulWidget {
  final TrainerModel model;
  final bool showWelcome;
  final Random? rng;
  const OnboardingFlow(
      {super.key, required this.model, this.showWelcome = true, this.rng});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late _Stage stage = widget.showWelcome ? _Stage.welcome : _Stage.offer;
  List<LeakTestItem> items = const [];
  final answers = <LeakTestAnswer>[];
  LeakVerdict? verdict;

  void _start() {
    setState(() {
      items = leakTestSet(widget.model.library, widget.rng ?? Random());
      answers.clear();
      verdict = null;
      stage = _Stage.test;
    });
  }

  void _answer(int i) {
    final a = LeakTestAnswer(items[answers.length], i);
    recordLeakAnswer(widget.model, a);
    setState(() {
      answers.add(a);
      if (answers.length >= items.length) {
        verdict = leakVerdict(answers);
        stage = _Stage.verdict;
      }
    });
  }

  void _close() => Navigator.of(context).popUntil((r) => r.isFirst);

  Future<void> _drill() async {
    final v = verdict;
    if (v != null && v.misses.isNotEmpty) await drillLeaks(widget.model, v);
    shellTabs.go(0);
    if (mounted) _close();
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (stage) {
      _Stage.welcome => _WelcomeCard(
          onNext: () => setState(() => stage = _Stage.offer),
          onSkip: _close,
        ),
      _Stage.offer => _OfferCard(onStart: _start, onSkip: _close),
      _Stage.test => _TestHand(
          item: items[answers.length],
          index: answers.length,
          total: items.length,
          onAnswer: _answer,
        ),
      _Stage.verdict => _VerdictView(
          verdict: verdict!,
          answers: answers,
          onDrill: _drill,
          onExplore: _close,
        ),
    };
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(stage == _Stage.welcome ? 'Felt Notes' : 'Leak test'),
        actions: [
          if (stage != _Stage.verdict)
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: _close,
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

class _WelcomeCard extends StatelessWidget {
  final VoidCallback onNext, onSkip;
  const _WelcomeCard({required this.onNext, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget line(IconData i, String s) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 20, color: Felt.gold),
            const SizedBox(width: 10),
            Expanded(child: Text(s, style: t.bodyMedium)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Welcome to Felt Notes', style: t.headlineSmall),
          const SizedBox(height: 14),
          line(Icons.fitness_center,
              'A poker trainer: see a hand, tap what you would do, and get graded against GTO.'),
          line(Icons.grid_on, 'Charts for every preflop spot, plus an equity calculator.'),
          line(Icons.groups, 'A home-game tracker for your own hands at poker night.'),
          line(Icons.lock_outline,
              'Everything stays on your phone. No account, no uploads.'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('Continue'),
          ),
          TextButton(onPressed: onSkip, child: const Text('Skip intro')),
        ]),
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  final VoidCallback onStart, onSkip;
  const _OfferCard({required this.onStart, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Icon(Icons.timer_outlined, size: 40, color: Felt.gold),
          const SizedBox(height: 10),
          Text('Take the 60-second leak test',
              style: t.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Text(
            '10 borderline hands from opens, blind defence and short-stack '
            'push/fold. Tap your play fast: no explanations until the end. '
            'Then you get your leaks in plain words.',
            style: t.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: onStart,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('Take the 60-second leak test'),
          ),
          TextButton(onPressed: onSkip, child: const Text('Skip')),
        ]),
      ),
    );
  }
}

class _TestHand extends StatelessWidget {
  final LeakTestItem item;
  final int index, total;
  final ValueChanged<int> onAnswer;
  const _TestHand(
      {required this.item,
      required this.index,
      required this.total,
      required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final b = Theme.of(context).brightness;
    final spot = item.spot;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
            child: Text('Hand ${index + 1} of $total', style: t.labelLarge)),
        Text(switch (spot.format) {
          SpotFormat.cash100 => '6-max · 100bb',
          SpotFormat.pushFold => 'Heads-up',
          SpotFormat.pushFold3 => '3-handed',
        }, style: t.labelMedium),
      ]),
      const SizedBox(height: 6),
      LinearProgressIndicator(value: index / total, color: Felt.gold),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(spot.title, style: t.titleLarge),
            const SizedBox(height: 4),
            Text(spot.situation, style: t.bodyMedium),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              PlayingCard(card: item.cards[0], width: 72),
              const SizedBox(width: 10),
              PlayingCard(card: item.cards[1], width: 72),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              for (var i = 0; i < spot.actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: ValueKey('leak-action-$i'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Felt.actionColor(spot.actions[i], b),
                      foregroundColor:
                          spot.actions[i] == 'Fold' && b == Brightness.light
                              ? Colors.black87
                              : Colors.white,
                      minimumSize: const Size.fromHeight(52),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    onPressed: () => onAnswer(i),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(spot.actions[i],
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ],
            ]),
          ]),
        ),
      ),
    ]);
  }
}

class _VerdictView extends StatelessWidget {
  final LeakVerdict verdict;
  final List<LeakTestAnswer> answers;
  final VoidCallback onDrill, onExplore;
  const _VerdictView(
      {required this.verdict,
      required this.answers,
      required this.onDrill,
      required this.onExplore});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final v = verdict;
    final missed = [for (final a in answers) if (a.isMiss) a];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Text('${v.correct} / ${v.total}',
                style: t.displaySmall?.copyWith(color: Felt.gold)),
            const SizedBox(height: 4),
            Text(v.headline, style: t.titleMedium, textAlign: TextAlign.center),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v.leaks.isEmpty ? 'Your leaks' : 'Your biggest leaks',
                style: t.titleMedium),
            const SizedBox(height: 8),
            for (final s in v.sentences)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(v.leaks.isEmpty ? Icons.check_circle : Icons.water_drop,
                      size: 18, color: v.leaks.isEmpty ? Felt.good : Felt.bad),
                  const SizedBox(width: 8),
                  Expanded(child: Text(s, style: t.bodyMedium)),
                ]),
              ),
          ]),
        ),
      ),
      if (missed.isNotEmpty) ...[
        const SizedBox(height: 8),
        Card(
          child: ExpansionTile(
            title: Text('Hands you missed (${missed.length})', style: t.titleSmall),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final a in missed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${a.item.hand.name} · ${a.item.spot.title}: you chose '
                    '${a.item.spot.actions[a.chosen]}. GTO: '
                    '${strategyLine(a.item.spot, a.item.hand)}.',
                    style: t.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: onDrill,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        icon: const Icon(Icons.fitness_center),
        label: Text(v.misses.isEmpty ? 'Start training' : 'Drill my leaks'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: onExplore,
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text('Explore the app'),
      ),
    ]);
  }
}

/// Opens the leak test (Help → Retake), skipping the welcome card.
Future<void> openLeakTest(BuildContext context, TrainerModel model) =>
    Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OnboardingFlow(model: model, showWelcome: false)));
