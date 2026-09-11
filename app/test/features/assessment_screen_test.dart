import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/assessment/question_bank.dart';
import 'package:surakshaar/core/l10n/app_localizations.dart';
import 'package:surakshaar/features/assessment/assessment_screen.dart';
import 'package:surakshaar/modules/catalogue.dart';

/// Plays the assessment the way a worker does: read, tap a choice, check the
/// answer, read the explanation, continue.
///
/// This exists because the engine was thoroughly unit tested and the screen was
/// not tested at all, and the defect lived exactly in the gap between them —
/// `submit()` correctly clears the presented question so it cannot be answered
/// twice, and the view then had nothing left to draw and showed a spinner
/// forever. No amount of engine testing can see that.
Widget _host(SafetyDomain domain) => MaterialApp(
      localizationsDelegates: L.localizationsDelegates,
      supportedLocales: L.supportedLocales,
      home: AssessmentScreen(domain: domain),
    );

void main() {
  group('AssessmentScreen', () {
    testWidgets('shows the explanation after answering, not a spinner',
        (tester) async {
      await tester.pumpWidget(_host(SafetyDomain.fire));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Check answer'), findsOneWidget);

      // Answer the first question however it happens to be shuffled.
      await _answerWhateverIsAsked(tester);

      await tester.tap(find.text('Check answer'));
      await tester.pumpAndSettle();

      // The regression: this used to be a CircularProgressIndicator forever.
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'answering a question must not leave the quiz spinning',
      );
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('the question counter does not skip while explaining',
        (tester) async {
      await tester.pumpWidget(_host(SafetyDomain.fire));
      await tester.pumpAndSettle();

      expect(find.textContaining('Question 1 of'), findsOneWidget);

      await _answerWhateverIsAsked(tester);
      await tester.tap(find.text('Check answer'));
      await tester.pumpAndSettle();

      // Still question 1: the worker is reading the explanation for it.
      expect(find.textContaining('Question 1 of'), findsOneWidget);
    });

    for (final domain in SafetyDomain.values) {
      testWidgets('${domain.name} can be played to a result', (tester) async {
        await tester.pumpWidget(_host(domain));
        await tester.pumpAndSettle();

        final expected =
            QuestionBank.forDomain(domain).length.clamp(0, 8);

        for (var i = 0; i < expected; i++) {
          expect(
            find.byType(CircularProgressIndicator),
            findsNothing,
            reason: '$domain stalled at item ${i + 1}',
          );
          await _answerWhateverIsAsked(tester);
          await tester.tap(find.text('Check answer'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Continue'));
          await tester.pumpAndSettle();
          // A wrong answer can end the attempt early on a mandatory item; if
          // the result screen is up, the loop is done.
          if (find.text('Check answer').evaluate().isEmpty) break;
        }

        // Every domain must reach its result screen rather than stalling.
        expect(find.text('Check answer'), findsNothing);
      });
    }

    testWidgets('counts toward a total the bank can actually reach',
        (tester) async {
      // The lighter domains carry fewer than the default eight items. Counting
      // to eight told the worker the quiz had ended early when it had not.
      await tester.pumpWidget(_host(SafetyDomain.strata));
      await tester.pumpAndSettle();

      final available = QuestionBank.forDomain(SafetyDomain.strata).length;
      expect(find.textContaining('of $available'), findsOneWidget);
    });
  });
}

/// Taps every choice, which satisfies all three question kinds at once.
///
/// A single-answer item ends up with the last tap selected, a multi-answer item
/// with everything selected, and an ordering item with a complete sequence. The
/// answers are mostly wrong, which is deliberate: the point is to drive the
/// screen through its states, and a wrong answer exercises the same transitions
/// as a right one.
Future<void> _answerWhateverIsAsked(WidgetTester tester) async {
  final choices = find.descendant(
    of: find.byType(SingleChildScrollView),
    matching: find.byType(InkWell),
  );
  final count = tester.widgetList(choices).length;
  for (var i = 0; i < count; i++) {
    // The default 800x600 test surface is shorter than a phone, so a fourth or
    // fifth choice can sit below the fold. A tap that lands off-screen is
    // silently dropped, which would make an ordering item look unsubmittable
    // for reasons that have nothing to do with the app.
    await tester.ensureVisible(choices.at(i));
    await tester.pumpAndSettle();
    await tester.tap(choices.at(i));
    await tester.pumpAndSettle();
  }
}
