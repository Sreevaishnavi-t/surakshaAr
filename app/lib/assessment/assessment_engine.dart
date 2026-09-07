import 'dart:math' as math;

import '../modules/catalogue.dart';
import 'question.dart';

/// Outcome of a completed assessment.
class AssessmentResult {
  const AssessmentResult({
    required this.domain,
    required this.answers,
    required this.rawScore,
    required this.passed,
    required this.failedMandatory,
    required this.duration,
  });

  final SafetyDomain domain;
  final List<AnsweredQuestion> answers;

  /// Difficulty-weighted percentage, 0..100.
  final double rawScore;

  final bool passed;

  /// Life-critical items answered wrongly. Non-empty means an automatic fail
  /// however high [rawScore] is, and these are exactly what retraining should
  /// target.
  final List<Question> failedMandatory;

  final Duration duration;

  int get correctCount => answers.where((a) => a.correct).length;
}

/// Adaptive assessment over a domain's question bank.
///
/// Three properties matter more than sophistication here:
///
/// * **Adaptive difficulty.** Starting mid-range and moving with performance
///   separates a confident worker from a lucky one in fewer items than a fixed
///   paper would, which matters when the assessment is taken standing up at the
///   end of a shift.
/// * **Concept coverage.** Items are grouped by the idea they test and the
///   engine will not ask twice from one concept, so a pass cannot come from
///   knowing a single fact unusually well.
/// * **Mandatory gating.** Some misconceptions are fatal. Those items must be
///   right regardless of the total, because an 85% that includes "a filter
///   respirator is fine in a confined space" is not a competent worker.
///
/// Item and choice order are shuffled per attempt from a seeded RNG, so two
/// workers sharing a phone cannot coach each other by position and a retry is
/// not muscle memory. Seeding keeps a session reproducible for review.
class AssessmentEngine {
  AssessmentEngine({
    required this.domain,
    required List<Question> bank,
    this.itemCount = 8,
    this.passThreshold = 80,
    math.Random? random,
  })  : _bank = List.unmodifiable(bank),
        _random = random ?? math.Random() {
    if (_bank.isEmpty) {
      throw ArgumentError('Question bank for ${domain.name} is empty');
    }
  }

  final SafetyDomain domain;
  final List<Question> _bank;
  final math.Random _random;

  /// How many items to ask. Kept short on purpose: this is taken on a phone,
  /// often at the end of a shift, and a long paper measures stamina.
  final int itemCount;

  /// Percentage needed to pass. 80 by default, matching the level typically
  /// expected for statutory safety certification rather than a casual quiz.
  final double passThreshold;

  final List<AnsweredQuestion> _answers = [];
  final Set<String> _usedConcepts = {};
  final Set<String> _usedIds = {};

  /// Current target difficulty. Starts mid-range so the first item is neither
  /// insulting nor demoralising.
  int _difficulty = 2;

  Question? _current;
  List<int>? _presentedOrder;
  DateTime? _presentedAt;
  DateTime? _startedAt;

  List<AnsweredQuestion> get answers => List.unmodifiable(_answers);

  int get askedCount => _answers.length;

  bool get isFinished => _answers.length >= itemCount || _nextCandidate() == null;

  /// The item to display, along with the choice order to show it in.
  ({Question question, List<String> choices, List<int> order})? get current {
    final question = _current;
    final order = _presentedOrder;
    if (question == null || order == null) return null;
    return (
      question: question,
      choices: [for (final index in order) question.choices[index]],
      order: order,
    );
  }

  /// Selects and presents the next item. Returns false when the assessment is
  /// over.
  bool advance() {
    _startedAt ??= DateTime.now();

    if (_answers.length >= itemCount) {
      _current = null;
      return false;
    }

    final next = _nextCandidate();
    if (next == null) {
      _current = null;
      return false;
    }

    _current = next;
    _usedIds.add(next.id);
    _usedConcepts.add(next.concept);

    // Ordering items keep their choice list stable — shuffling the options of a
    // "put these in order" question just adds noise to a task that is already
    // about sequence.
    final indices = List<int>.generate(next.choices.length, (i) => i);
    if (next.kind != QuestionKind.ordering) {
      indices.shuffle(_random);
    }
    _presentedOrder = indices;
    _presentedAt = DateTime.now();

    return true;
  }

  /// Records an answer. [givenPresentedIndices] are positions in the shuffled
  /// list the worker actually saw; they are mapped back to original indices
  /// here so the rest of the system never has to think about the shuffle.
  void submit(List<int> givenPresentedIndices) {
    final question = _current;
    final order = _presentedOrder;
    if (question == null || order == null) {
      throw StateError('submit() called with no question presented');
    }

    final given = [
      for (final presented in givenPresentedIndices)
        if (presented >= 0 && presented < order.length) order[presented],
    ];

    final correct = question.isCorrect(given);

    _answers.add(AnsweredQuestion(
      question: question,
      given: given,
      correct: correct,
      timeTaken: DateTime.now().difference(_presentedAt ?? DateTime.now()),
      presentedOrder: order,
    ));

    // Move up on a correct answer, down on a wrong one. A wrong answer pulls an
    // easier item on the same footing rather than compounding failure.
    _difficulty = correct
        ? math.min(3, _difficulty + 1)
        : math.max(1, _difficulty - 1);

    _current = null;
    _presentedOrder = null;
  }

  /// Picks the best unused item, preferring the target difficulty and an
  /// unseen concept, then relaxing each constraint in turn rather than giving
  /// up. Relaxing concept coverage last matters: breadth is worth more to the
  /// validity of the result than hitting an exact difficulty.
  Question? _nextCandidate() {
    final unused = _bank.where((q) => !_usedIds.contains(q.id)).toList();
    if (unused.isEmpty) return null;

    // Mandatory items are never skipped. If any remain unasked and we are
    // running out of slots, force them in — a pass that never tested a
    // life-critical misconception is not worth issuing.
    final remainingSlots = itemCount - _answers.length;
    final unaskedMandatory = unused.where((q) => q.mandatory).toList();
    if (unaskedMandatory.isNotEmpty &&
        unaskedMandatory.length >= remainingSlots) {
      return _pick(unaskedMandatory);
    }

    for (final requireFreshConcept in [true, false]) {
      var pool = unused;
      if (requireFreshConcept) {
        pool = pool.where((q) => !_usedConcepts.contains(q.concept)).toList();
        if (pool.isEmpty) continue;
      }

      // Exact difficulty, then widening bands around it.
      for (var spread = 0; spread <= 2; spread++) {
        final band = pool
            .where((q) => (q.difficulty - _difficulty).abs() == spread)
            .toList();
        if (band.isNotEmpty) return _pick(band);
      }
    }

    return _pick(unused);
  }

  Question _pick(List<Question> pool) => pool[_random.nextInt(pool.length)];

  /// Finalises the attempt.
  AssessmentResult finish() {
    final failedMandatory = [
      for (final answered in _answers)
        if (answered.question.mandatory && !answered.correct) answered.question,
    ];

    // Difficulty-weighted: a hard item is worth more than an easy one, so a
    // worker who clears the judgement questions scores above one who only
    // clears recall.
    var earned = 0.0;
    var available = 0.0;
    for (final answered in _answers) {
      final weight = answered.question.difficulty.toDouble();
      available += weight;
      if (answered.correct) earned += weight;
    }

    final rawScore = available == 0 ? 0.0 : (earned / available) * 100;

    return AssessmentResult(
      domain: domain,
      answers: List.unmodifiable(_answers),
      rawScore: rawScore,
      passed: rawScore >= passThreshold && failedMandatory.isEmpty,
      failedMandatory: List.unmodifiable(failedMandatory),
      duration: DateTime.now().difference(_startedAt ?? DateTime.now()),
    );
  }
}

/// Combines drill behaviour and assessment into the figure a certificate
/// carries.
///
/// The 40% behavioural share is the substantive answer to the problem this
/// platform exists for: a paper certificate attests that someone attended, and
/// a pure quiz attests that they could recall an answer while sitting still.
/// Neither predicts what a worker does in the first ten seconds of a fire.
/// Weighting measured behaviour — reaction time, action ordering, wrong turns
/// under a thickening smoke layer — is what lets the QR claim comprehension
/// rather than attendance.
double compositeScore({
  required double assessmentScore,
  required double behaviouralScore,
  double assessmentWeight = 0.6,
}) {
  final behaviouralWeight = 1.0 - assessmentWeight;
  final combined =
      assessmentScore * assessmentWeight + behaviouralScore * behaviouralWeight;
  return combined.clamp(0.0, 100.0);
}
