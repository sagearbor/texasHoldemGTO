import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../gto/spots.dart';
import '../../quiz/quiz_generator.dart';
import '../theme.dart';
import '../widgets/playing_card.dart';
import '../widgets/range_grid.dart';

/// Quizzes: pot odds and range reading, 10 questions per session. All
/// questions are generated on-device from the strategy data.
class QuizScreen extends StatefulWidget {
  final Random? rng;

  /// Build pot-odds questions on a background isolate (off in widget tests).
  final bool useIsolate;
  const QuizScreen({super.key, this.rng, this.useIsolate = true});

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  late final Random _rng = widget.rng ?? Random();
  final _spots = buildCashSpots();
  QuizFocus _focus = QuizFocus.mixed;

  SessionPlan? _plan;
  QuizSession? _session;
  final Map<int, Future<QuizQuestion>> _pending = {};
  int _index = 0;
  int _part = 0;
  bool _reviewing = false;

  Spot _spot(String id) => _spots.firstWhere((s) => s.id == id);

  /// Pot-odds questions run equity maths, so build them off the UI thread
  /// (compute() runs inline on web, where generation stays well under
  /// 300 ms). Range questions are instant.
  Future<QuizQuestion> _generate(int i) => _pending[i] ??= () {
        final plan = _plan!;
        final msg = plan.message(i);
        if (widget.useIsolate && plan.kinds[i] == QuizKind.potOdds) {
          return compute(generateFromSeed, msg);
        }
        return Future.value(generateFromSeed(msg));
      }();

  Future<void> _start() async {
    final plan = SessionPlan.create(_rng, _focus);
    setState(() {
      _plan = plan;
      _session = QuizSession(length: plan.length);
      _pending.clear();
      _index = 0;
      _part = 0;
      _reviewing = false;
    });
    await _load(0);
  }

  Future<void> _load(int i) async {
    final plan = _plan;
    final q = await _generate(i);
    // Ignore results from a session that has since been restarted.
    if (!mounted || plan == null || !identical(plan, _plan)) return;
    final s = _session!;
    if (s.questions.length == i) {
      setState(() => s.add(q));
    }
    // Prefetch the next one while the player thinks.
    if (i + 1 < _plan!.length) _generate(i + 1);
  }

  void _answer(int option) {
    setState(() => _session!.answer(_index, _part, option));
  }

  void _continue() {
    final s = _session!;
    final q = s.questions[_index];
    if (_part + 1 < q.parts.length) {
      setState(() => _part++);
      return;
    }
    if (_index + 1 >= s.length) {
      setState(() => _reviewing = true);
      return;
    }
    setState(() {
      _index++;
      _part = 0;
    });
    _load(_index);
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quizzes'),
        actions: [
          if (s != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text('${s.score} / ${s.answeredCount}',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
        ],
      ),
      body: s == null
          ? _StartView(
              focus: _focus,
              onFocus: (f) => setState(() => _focus = f),
              onStart: _start)
          : _reviewing
              ? _ResultsView(
                  session: s,
                  spotFor: _spot,
                  onRestart: _start,
                  onMenu: () => setState(() => _session = null))
              : s.questions.length <= _index
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                      children: [
                        _Progress(index: _index, total: s.length),
                        const SizedBox(height: 12),
                        _QuestionCard(
                          question: s.questions[_index],
                          part: _part,
                          chosen: s.chosen[_index][_part],
                          spotFor: _spot,
                          onAnswer: _answer,
                          onContinue: _continue,
                          last: _index + 1 >= s.length,
                        ),
                      ],
                    ),
    );
  }
}

class _StartView extends StatelessWidget {
  final QuizFocus focus;
  final ValueChanged<QuizFocus> onFocus;
  final VoidCallback onStart;
  const _StartView(
      {required this.focus, required this.onFocus, required this.onStart});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget item(IconData icon, String title, String body) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: Felt.accent(context)),
          title: Text(title),
          subtitle: Text(body),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('10-question session', style: t.titleLarge),
                const SizedBox(height: 4),
                Text('Score at the end, then review your mistakes.',
                    style: t.bodyMedium),
                const SizedBox(height: 14),
                SegmentedButton<QuizFocus>(
                  segments: [
                    for (final f in QuizFocus.values)
                      ButtonSegment(value: f, label: Text(quizFocusLabels[f]!)),
                  ],
                  selected: {focus},
                  onSelectionChanged: (v) => onFocus(v.first),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: onStart,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50)),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        item(Icons.percent, 'Pot odds',
            'What equity a call needs, then call or fold with a real hand vs a range.'),
        item(Icons.grid_on, 'Range reading',
            'Which hands are in a range, how often a hand 3-bets, how wide a seat plays.'),
        item(Icons.info_outline, 'No AI',
            'Every question and explanation comes from the strategy charts and exact maths.'),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  final int index, total;
  const _Progress({required this.index, required this.total});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Question ${index + 1} of $total',
            style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        LinearProgressIndicator(
            value: (index + 1) / total, color: Felt.accent(context)),
      ],
    );
  }
}

class _QuestionCard extends StatelessWidget {
  final QuizQuestion question;
  final int part;
  final int? chosen;
  final Spot Function(String) spotFor;
  final ValueChanged<int> onAnswer;
  final VoidCallback onContinue;
  final bool last;
  const _QuestionCard({
    required this.question,
    required this.part,
    required this.chosen,
    required this.spotFor,
    required this.onAnswer,
    required this.onContinue,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final q = question;
    final p = q.parts[part];
    final answered = chosen != null;
    final moreParts = part + 1 < q.parts.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                  child: Text(quizKindLabels[q.kind]!, style: t.titleLarge)),
              if (q.parts.length > 1)
                Chip(
                  label: Text('Part ${part + 1} of ${q.parts.length}'),
                  visualDensity: VisualDensity.compact,
                ),
            ]),
            const SizedBox(height: 4),
            Text(q.situation, style: t.bodyMedium),
            if (q.heroCards.isNotEmpty && part > 0) ...[
              const SizedBox(height: 14),
              _Cards(hero: q.heroCards, board: q.board),
            ],
            const SizedBox(height: 14),
            Text(p.prompt,
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            _Options(part: p, chosen: chosen, onAnswer: onAnswer),
            if (answered) ...[
              const SizedBox(height: 14),
              _Explanation(part: p, chosen: chosen!),
              if (q.spotId != null) ...[
                const SizedBox(height: 12),
                _SpotGrid(spot: spotFor(q.spotId!), highlight: q.highlight),
              ],
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: onContinue,
                  icon: Icon(moreParts || !last
                      ? Icons.arrow_forward
                      : Icons.flag_outlined),
                  label: Text(moreParts
                      ? 'Next part'
                      : last
                          ? 'See score'
                          : 'Next question'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Cards extends StatelessWidget {
  final List<int> hero, board;
  const _Cards({required this.hero, required this.board});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return LayoutBuilder(builder: (context, c) {
      // Five board cards + gap + two hole cards must fit the width.
      final w = ((c.maxWidth - 40) / 7.6).clamp(30.0, 56.0);
      return Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 16,
        runSpacing: 10,
        children: [
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Board', style: t.labelSmall),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (final b in board)
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: PlayingCard(card: b, width: w)),
            ]),
          ]),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text('You', style: t.labelSmall),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (final h in hero)
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: PlayingCard(card: h, width: w)),
            ]),
          ]),
        ],
      );
    });
  }
}

class _Options extends StatelessWidget {
  final QuizPart part;
  final int? chosen;
  final ValueChanged<int> onAnswer;
  const _Options(
      {required this.part, required this.chosen, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final answered = chosen != null;
    final two = part.options.length <= 2;
    Widget button(int i) {
      final isAnswer = i == part.answer;
      final isChosen = i == chosen;
      Color? bg;
      if (answered && isAnswer) bg = Felt.good;
      if (answered && isChosen && !isAnswer) bg = Felt.bad;
      return FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          backgroundColor: bg ?? scheme.secondaryContainer,
          foregroundColor: bg != null ? Colors.white : scheme.onSecondaryContainer,
          disabledBackgroundColor: bg ?? scheme.surfaceContainerHighest,
          disabledForegroundColor:
              bg != null ? Colors.white : scheme.onSurfaceVariant,
        ),
        onPressed: answered ? null : () => onAnswer(i),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (answered && isAnswer) ...[
            const Icon(Icons.check, size: 18),
            const SizedBox(width: 6),
          ] else if (answered && isChosen) ...[
            const Icon(Icons.close, size: 18),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(part.options[i],
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
    }

    if (two) {
      return Row(children: [
        for (var i = 0; i < part.options.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: button(i)),
        ],
      ]);
    }
    // 2 × 2 (or 3 in a column) grid of options.
    final rows = <Widget>[];
    final perRow = part.options.length == 4 ? 2 : 1;
    for (var i = 0; i < part.options.length; i += perRow) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          for (var k = i; k < i + perRow && k < part.options.length; k++) ...[
            if (k > i) const SizedBox(width: 8),
            Expanded(child: button(k)),
          ],
        ]),
      ));
    }
    return Column(children: rows);
  }
}

class _Explanation extends StatelessWidget {
  final QuizPart part;
  final int chosen;
  const _Explanation({required this.part, required this.chosen});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final right = chosen == part.answer;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: right ? Felt.good : Felt.bad, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(right ? 'Correct' : 'Answer: ${part.options[part.answer]}',
              style: t.titleSmall?.copyWith(
                  color: right ? Felt.good : Felt.bad,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final line in part.explanation)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $line', style: t.bodyMedium),
            ),
        ],
      ),
    );
  }
}

class _SpotGrid extends StatelessWidget {
  final Spot spot;
  final int? highlight;
  const _SpotGrid({required this.spot, this.highlight});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(spot.title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        RangeGrid(spot: spot, highlight: highlight),
        const SizedBox(height: 6),
        ActionLegend(spot: spot),
      ],
    );
  }
}

class _ResultsView extends StatelessWidget {
  final QuizSession session;
  final Spot Function(String) spotFor;
  final VoidCallback onRestart;
  final VoidCallback onMenu;
  const _ResultsView({
    required this.session,
    required this.spotFor,
    required this.onRestart,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = session;
    final mistakes = s.mistakes;
    final ratio = s.length == 0 ? 0.0 : s.score / s.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Text('${s.score} / ${s.length}',
                  style: t.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: HeatGrid.heat(ratio))),
              const SizedBox(height: 4),
              Text(
                  ratio >= 0.9
                      ? 'Excellent.'
                      : ratio >= 0.7
                          ? 'Solid. Review the misses below.'
                          : 'Keep at it. Review the misses below.',
                  style: t.bodyLarge),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: onMenu, child: const Text('Change type')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                      onPressed: onRestart,
                      icon: const Icon(Icons.refresh),
                      label: const Text('New session')),
                ),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Text(mistakes.isEmpty ? 'No mistakes' : 'Review mistakes',
            style: t.titleMedium),
        const SizedBox(height: 6),
        for (final i in mistakes) _MistakeTile(
            number: i + 1,
            question: s.questions[i],
            chosen: s.chosen[i],
            spotFor: spotFor),
      ],
    );
  }
}

class _MistakeTile extends StatelessWidget {
  final int number;
  final QuizQuestion question;
  final List<int?> chosen;
  final Spot Function(String) spotFor;
  const _MistakeTile({
    required this.number,
    required this.question,
    required this.chosen,
    required this.spotFor,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final q = question;
    final wrong = [
      for (var p = 0; p < q.parts.length; p++)
        if (chosen[p] != q.parts[p].answer) p
    ];
    final first = q.parts[wrong.first];
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        title: Text('Q$number · ${quizKindLabels[q.kind]}'),
        subtitle: Text(first.prompt, maxLines: 2, overflow: TextOverflow.ellipsis),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(q.situation, style: t.bodySmall),
          if (q.heroCards.isNotEmpty) ...[
            const SizedBox(height: 10),
            _Cards(hero: q.heroCards, board: q.board),
          ],
          for (final p in wrong) ...[
            const SizedBox(height: 10),
            Text(q.parts[p].prompt,
                style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('You: ${q.parts[p].options[chosen[p]!]} · '
                'Answer: ${q.parts[p].options[q.parts[p].answer]}',
                style: t.bodyMedium?.copyWith(color: Felt.bad)),
            const SizedBox(height: 6),
            for (final line in q.parts[p].explanation)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('• $line', style: t.bodySmall),
              ),
          ],
          if (q.spotId != null) ...[
            const SizedBox(height: 10),
            _SpotGrid(spot: spotFor(q.spotId!), highlight: q.highlight),
          ],
        ],
      ),
    );
  }
}
