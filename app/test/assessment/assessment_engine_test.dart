import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/assessment/assessment_engine.dart';
import 'package:surakshaar/assessment/question.dart';
import 'package:surakshaar/assessment/question_bank.dart';
import 'package:surakshaar/modules/catalogue.dart';

Question q(
  String id, {
  int difficulty = 2,
  String concept = 'c',
  bool mandatory = false,
  QuestionKind kind = QuestionKind.single,
}) {
  return Question(
    id: id,
    domain: SafetyDomain.fire,
    kind: kind,
    difficulty: difficulty,
    concept: concept,
    mandatory: mandatory,
    prompt: 'prompt $id',
    choices: const ['a', 'b', 'c', 'd'],
    answer: const [0],
    explanation: 'because',
  );
}

/// Answers every presented item correctly by mapping the original answer back
/// through the shuffle the engine produced.
void answerCorrectly(AssessmentEngine engine) {
  final current = engine.current!;
  final wanted = current.question.answer;
  engine.submit([
    for (final original in wanted) current.order.indexOf(original),
  ]);
}

void answerIncorrectly(AssessmentEngine engine) {
  final current = engine.current!;
  final wrong = List<int>.generate(current.choices.length, (i) => i)
      .where((presented) => !current.question.answer.contains(current.order[presented]))
      .toList();
  engine.submit([wrong.first]);
}

void main() {
  group('Question grading', () {
    test('single-choice grading', () {
      final question = q('x');
      expect(question.isCorrect([0]), isTrue);
      expect(question.isCorrect([1]), isFalse);
      expect(question.isCorrect([]), isFalse);
      expect(question.isCorrect([0, 1]), isFalse);
    });

    test('multiple-choice requires the exact set, with no partial credit', () {
      const question = Question(
        id: 'm',
        domain: SafetyDomain.gas,
        kind: QuestionKind.multiple,
        difficulty: 2,
        concept: 'c',
        prompt: 'p',
        choices: ['a', 'b', 'c', 'd'],
        answer: [0, 2],
        explanation: 'e',
      );

      expect(question.isCorrect([0, 2]), isTrue);
      // Order within the set does not matter.
      expect(question.isCorrect([2, 0]), isTrue);
      // Half-correct PPE selection is not half-safe.
      expect(question.isCorrect([0]), isFalse);
      expect(question.isCorrect([0, 2, 3]), isFalse);
    });

    test('ordering requires the exact sequence', () {
      const question = Question(
        id: 'o',
        domain: SafetyDomain.machinery,
        kind: QuestionKind.ordering,
        difficulty: 2,
        concept: 'c',
        prompt: 'p',
        choices: ['first', 'second', 'third'],
        answer: [0, 1, 2],
        explanation: 'e',
      );

      expect(question.isCorrect([0, 1, 2]), isTrue);
      expect(question.isCorrect([0, 2, 1]), isFalse);
      expect(question.isCorrect([2, 1, 0]), isFalse);
    });
  });

  group('adaptive selection', () {
    test('difficulty rises on correct answers and falls on wrong ones', () {
      final bank = [
        for (var d = 1; d <= 3; d++)
          for (var i = 0; i < 4; i++)
            q('d$d-$i', difficulty: d, concept: 'concept-$d-$i'),
      ];

      final engine = AssessmentEngine(
        domain: SafetyDomain.fire,
        bank: bank,
        itemCount: 4,
        random: math.Random(1),
      );

      engine.advance();
      // Starts mid-range.
      expect(engine.current!.question.difficulty, 2);

      answerCorrectly(engine);
      engine.advance();
      expect(engine.current!.question.difficulty, 3);

      answerIncorrectly(engine);
      engine.advance();
      expect(engine.current!.question.difficulty, 2);

      answerIncorrectly(engine);
      engine.advance();
      expect(engine.current!.question.difficulty, 1);
    });

    test('does not ask two questions from the same concept', () {
      final bank = [
        for (var i = 0; i < 3; i++) q('a$i', concept: 'alpha'),
        for (var i = 0; i < 3; i++) q('b$i', concept: 'beta'),
        for (var i = 0; i < 3; i++) q('c$i', concept: 'gamma'),
      ];

      final engine = AssessmentEngine(
        domain: SafetyDomain.fire,
        bank: bank,
        itemCount: 3,
        random: math.Random(7),
      );

      final concepts = <String>[];
      while (engine.advance()) {
        concepts.add(engine.current!.question.concept);
        answerCorrectly(engine);
      }

      expect(concepts.length, 3);
      expect(concepts.toSet().length, 3, reason: 'concepts repeated: $concepts');
    });

    test('never repeats a question within an attempt', () {
      final engine = AssessmentEngine(
        domain: SafetyDomain.fire,
        bank: QuestionBank.fire,
        itemCount: 8,
        random: math.Random(3),
      );

      final ids = <String>[];
      while (engine.advance()) {
        ids.add(engine.current!.question.id);
        answerCorrectly(engine);
      }

      expect(ids.length, 8);
      expect(ids.toSet().length, ids.length);
    });

    test('shuffles choices between attempts so position is not the answer', () {
      final orders = <String>{};
      for (var seed = 0; seed < 8; seed++) {
        final engine = AssessmentEngine(
          domain: SafetyDomain.fire,
          bank: [q('only')],
          itemCount: 1,
          random: math.Random(seed),
        );
        engine.advance();
        orders.add(engine.current!.order.join(','));
      }

      expect(orders.length, greaterThan(1),
          reason: 'choice order never varied across seeds');
    });

    test('leaves ordering questions in their authored order', () {
      // Shuffling the options of a "put these in sequence" item adds noise to a
      // task that is already about sequence.
      final engine = AssessmentEngine(
        domain: SafetyDomain.fire,
        bank: [q('ord', kind: QuestionKind.ordering)],
        itemCount: 1,
        random: math.Random(5),
      );
      engine.advance();
      expect(engine.current!.order, [0, 1, 2, 3]);
    });
  });

  group('mandatory gating', () {
    test('a wrong mandatory item fails the attempt despite a high score', () {
      final bank = [
        q('mand', difficulty: 1, concept: 'fatal', mandatory: true),
        for (var i = 0; i < 6; i++) q('easy$i', difficulty: 3, concept: 'c$i'),
      ];

      final engine = AssessmentEngine(
        domain: SafetyDomain.fire,
        bank: bank,
        itemCount: 7,
        random: math.Random(2),
      );

      while (engine.advance()) {
        if (engine.current!.question.mandatory) {
          answerIncorrectly(engine);
        } else {
          answerCorrectly(engine);
        }
      }

      final result = engine.finish();

      // Six of seven correct, and the wrong one was the cheapest item — so the
      // weighted score is high while the attempt is still a fail.
      expect(result.rawScore, greaterThan(90));
      expect(result.failedMandatory, hasLength(1));
      expect(result.failedMandatory.single.id, 'mand');
      expect(result.passed, isFalse);
    });

    test('mandatory items are always asked, even when slots run short', () {
      final bank = [
        for (var i = 0; i < 10; i++) q('filler$i', concept: 'c$i'),
        q('m1', concept: 'fatal-1', mandatory: true),
        q('m2', concept: 'fatal-2', mandatory: true),
      ];

      // Across many seeds, every attempt must include both mandatory items.
      for (var seed = 0; seed < 20; seed++) {
        final engine = AssessmentEngine(
          domain: SafetyDomain.fire,
          bank: bank,
          itemCount: 5,
          random: math.Random(seed),
        );

        final ids = <String>[];
        while (engine.advance()) {
          ids.add(engine.current!.question.id);
          answerCorrectly(engine);
        }

        expect(ids, containsAll(['m1', 'm2']), reason: 'seed $seed');
      }
    });
  });

  group('scoring', () {
    test('weights harder questions more heavily', () {
      final bank = [
        q('hard', difficulty: 3, concept: 'a'),
        q('easy', difficulty: 1, concept: 'b'),
      ];

      // Getting the hard one right and the easy one wrong beats the reverse.
      double scoreWhen({required bool hardCorrect}) {
        final engine = AssessmentEngine(
          domain: SafetyDomain.fire,
          bank: bank,
          itemCount: 2,
          random: math.Random(4),
        );
        while (engine.advance()) {
          final isHard = engine.current!.question.id == 'hard';
          if (isHard == hardCorrect) {
            answerCorrectly(engine);
          } else {
            answerIncorrectly(engine);
          }
        }
        return engine.finish().rawScore;
      }

      expect(scoreWhen(hardCorrect: true), 75); // 3 of 4 weight
      expect(scoreWhen(hardCorrect: false), 25); // 1 of 4 weight
    });

    test('a perfect attempt passes and an empty one scores zero', () {
      final engine = AssessmentEngine(
        domain: SafetyDomain.gas,
        bank: QuestionBank.gas,
        itemCount: 6,
        random: math.Random(9),
      );

      while (engine.advance()) {
        answerCorrectly(engine);
      }

      final result = engine.finish();
      expect(result.rawScore, 100);
      expect(result.passed, isTrue);
      expect(result.correctCount, 6);

      final untouched = AssessmentEngine(
        domain: SafetyDomain.gas,
        bank: QuestionBank.gas,
        random: math.Random(9),
      );
      expect(untouched.finish().rawScore, 0);
    });

    test('composite weights behaviour at 40 percent', () {
      expect(
        compositeScore(assessmentScore: 100, behaviouralScore: 0),
        closeTo(60, 1e-9),
      );
      expect(
        compositeScore(assessmentScore: 0, behaviouralScore: 100),
        closeTo(40, 1e-9),
      );
      expect(
        compositeScore(assessmentScore: 90, behaviouralScore: 80),
        closeTo(86, 1e-9),
      );
      // A worker who aces the quiz but freezes in the drill must not reach the
      // 80% pass mark on recall alone — that is the whole premise.
      expect(
        compositeScore(assessmentScore: 100, behaviouralScore: 40),
        lessThan(80),
      );
    });
  });

  group('question bank integrity', () {
    test('every domain has a bank with unique ids and valid answers', () {
      final allIds = <String>{};

      for (final domain in SafetyDomain.values) {
        final bank = QuestionBank.forDomain(domain);
        expect(bank, isNotEmpty, reason: domain.name);

        for (final question in bank) {
          expect(allIds.add(question.id), isTrue,
              reason: 'duplicate question id ${question.id}');
          expect(question.domain, domain, reason: question.id);
          expect(question.difficulty, inInclusiveRange(1, 3), reason: question.id);
          expect(question.choices.length, greaterThanOrEqualTo(2),
              reason: question.id);
          expect(question.answer, isNotEmpty, reason: question.id);
          expect(question.explanation, isNotEmpty, reason: question.id);

          for (final index in question.answer) {
            expect(index, inInclusiveRange(0, question.choices.length - 1),
                reason: '${question.id} answer index out of range');
          }

          if (question.kind == QuestionKind.single) {
            expect(question.answer, hasLength(1), reason: question.id);
          }
          if (question.kind == QuestionKind.ordering) {
            // An ordering item must rank every choice exactly once.
            expect(question.answer, hasLength(question.choices.length),
                reason: question.id);
            expect(question.answer.toSet(), hasLength(question.choices.length),
                reason: question.id);
          }
        }
      }
    });

    test('the deep modules can fill a full-length assessment', () {
      // Fire and gas are the two built to production depth, so their banks must
      // be large enough that an 8-item attempt never runs dry or repeats a
      // concept.
      for (final domain in [SafetyDomain.fire, SafetyDomain.gas]) {
        final bank = QuestionBank.forDomain(domain);
        expect(bank.length, greaterThanOrEqualTo(8), reason: domain.name);
        expect(
          bank.map((q) => q.concept).toSet().length,
          greaterThanOrEqualTo(8),
          reason: '${domain.name} needs 8 distinct concepts',
        );
      }
    });

    test('every domain gates on at least one life-critical item', () {
      for (final domain in SafetyDomain.values) {
        expect(
          QuestionBank.forDomain(domain).any((q) => q.mandatory),
          isTrue,
          reason: '${domain.name} has no mandatory question',
        );
      }
    });
  });
}
