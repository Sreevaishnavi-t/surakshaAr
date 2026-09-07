import '../modules/catalogue.dart';

enum QuestionKind {
  /// Exactly one correct choice.
  single,

  /// Several correct choices; partial credit is not given, because half-correct
  /// PPE selection is not half-safe.
  multiple,

  /// Choices must be placed in the right order. Used for procedures where
  /// sequence is the whole point — lockout-tagout, evacuation, permit steps.
  ordering,
}

/// One assessment item.
class Question {
  const Question({
    required this.id,
    required this.domain,
    required this.kind,
    required this.difficulty,
    required this.concept,
    required this.prompt,
    required this.choices,
    required this.answer,
    required this.explanation,
    this.mandatory = false,
  });

  final String id;
  final SafetyDomain domain;
  final QuestionKind kind;

  /// 1 (recall) to 3 (judgement under ambiguity). Drives adaptive selection.
  final int difficulty;

  /// Groups items that test the same underlying idea. The engine avoids asking
  /// two items from one concept, so a worker cannot pass by happening to know a
  /// single fact well.
  final String concept;

  final String prompt;
  final List<String> choices;

  /// Indices into [choices]. For [QuestionKind.ordering] the list *is* the
  /// required order; otherwise it is an unordered set of correct choices.
  final List<int> answer;

  /// Shown after answering, right or wrong. An assessment that only reports a
  /// score teaches nothing, which is the classroom failure this platform exists
  /// to replace.
  final String explanation;

  /// Life-critical items that must be answered correctly regardless of total
  /// score. Getting 90% while believing a filter respirator is fine in an
  /// oxygen-deficient space is not a pass.
  final bool mandatory;

  bool isCorrect(List<int> given) {
    if (kind == QuestionKind.ordering) {
      if (given.length != answer.length) return false;
      for (var i = 0; i < answer.length; i++) {
        if (given[i] != answer[i]) return false;
      }
      return true;
    }

    if (given.length != answer.length) return false;
    final expected = answer.toSet();
    return given.toSet().containsAll(expected) &&
        expected.containsAll(given.toSet());
  }
}

/// A worker's response to one item.
class AnsweredQuestion {
  const AnsweredQuestion({
    required this.question,
    required this.given,
    required this.correct,
    required this.timeTaken,
    required this.presentedOrder,
  });

  final Question question;

  /// Indices into the *original* [Question.choices], already mapped back from
  /// whatever shuffled order the worker saw.
  final List<int> given;

  final bool correct;
  final Duration timeTaken;

  /// The shuffle that was shown, kept so a result screen can replay exactly
  /// what the worker was looking at.
  final List<int> presentedOrder;
}
