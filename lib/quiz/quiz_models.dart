/// Plain data for the quiz section. Everything here is generated on-device
/// from existing strategy data; explanations are templates filled with
/// numbers (no AI text).
library;

enum QuizKind { potOdds, notInRange, frequency, rangeWidth }

const quizKindLabels = {
  QuizKind.potOdds: 'Pot odds',
  QuizKind.notInRange: 'Range reading',
  QuizKind.frequency: 'How often?',
  QuizKind.rangeWidth: 'Range width',
};

/// One multiple-choice step. A question has one or more parts.
class QuizPart {
  final String prompt;
  final List<String> options;
  final int answer;
  final List<String> explanation;
  const QuizPart({
    required this.prompt,
    required this.options,
    required this.answer,
    required this.explanation,
  });
}

class QuizQuestion {
  final QuizKind kind;

  /// Short situation line shown above the prompt.
  final String situation;
  final List<QuizPart> parts;

  /// Hero hole cards and board (pot-odds follow-up only; empty otherwise).
  final List<int> heroCards;
  final List<int> board;

  /// Spot whose range grid is shown after answering (range questions).
  final String? spotId;

  /// Hand-class index highlighted on that grid.
  final int? highlight;

  const QuizQuestion({
    required this.kind,
    required this.situation,
    required this.parts,
    this.heroCards = const [],
    this.board = const [],
    this.spotId,
    this.highlight,
  });
}

/// Score keeping for a session of questions. A question counts as correct
/// only when every one of its parts was answered correctly.
class QuizSession {
  final List<QuizQuestion> questions = [];

  /// chosen[q][part] = option index picked, or null while unanswered.
  final List<List<int?>> chosen = [];

  final int length;
  QuizSession({this.length = 10});

  void add(QuizQuestion q) {
    questions.add(q);
    chosen.add(List<int?>.filled(q.parts.length, null));
  }

  void answer(int question, int part, int option) {
    if (chosen[question][part] != null) return;
    chosen[question][part] = option;
  }

  bool isAnswered(int q) => chosen[q].every((c) => c != null);

  bool isCorrect(int q) {
    final qs = questions[q];
    for (var p = 0; p < qs.parts.length; p++) {
      if (chosen[q][p] != qs.parts[p].answer) return false;
    }
    return true;
  }

  int get answeredCount =>
      [for (var i = 0; i < questions.length; i++) i].where(isAnswered).length;

  int get score => [for (var i = 0; i < questions.length; i++) i]
      .where((i) => isAnswered(i) && isCorrect(i))
      .length;

  bool get finished => questions.length >= length && answeredCount >= length;

  /// Indices of answered questions with at least one wrong part.
  List<int> get mistakes => [
        for (var i = 0; i < questions.length; i++)
          if (isAnswered(i) && !isCorrect(i)) i
      ];
}
