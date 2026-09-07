import 'package:flutter/material.dart';

import '../../assessment/assessment_engine.dart';
import '../../assessment/question.dart';
import '../../assessment/question_bank.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../modules/catalogue.dart';

/// Presents an adaptive assessment for one domain.
///
/// Two things shape the layout more than anything else. Choices are large,
/// separated blocks because these are tapped with gloved hands. And the
/// explanation is shown after *every* answer, right or wrong — an assessment
/// that only reports a score is exactly the classroom experience whose
/// retention this platform exists to improve on.
class AssessmentScreen extends StatefulWidget {
  const AssessmentScreen({
    super.key,
    required this.domain,
    this.itemCount = 8,
  });

  final SafetyDomain domain;
  final int itemCount;

  @override
  State<AssessmentScreen> createState() => _AssessmentScreenState();
}

class _AssessmentScreenState extends State<AssessmentScreen> {
  late final AssessmentEngine _engine;

  /// Indices into the *presented* choice order.
  final Set<int> _selected = {};

  /// For ordering questions, the sequence built so far.
  final List<int> _sequence = [];

  bool _showingExplanation = false;
  bool _lastAnswerCorrect = false;
  AssessmentResult? _result;

  @override
  void initState() {
    super.initState();
    _engine = AssessmentEngine(
      domain: widget.domain,
      bank: QuestionBank.forDomain(widget.domain),
      itemCount: widget.itemCount,
    );
    _engine.advance();
  }

  void _toggle(int presentedIndex, QuestionKind kind) {
    if (_showingExplanation) return;

    setState(() {
      switch (kind) {
        case QuestionKind.single:
          _selected
            ..clear()
            ..add(presentedIndex);
        case QuestionKind.multiple:
          if (!_selected.remove(presentedIndex)) _selected.add(presentedIndex);
        case QuestionKind.ordering:
          if (!_sequence.remove(presentedIndex)) _sequence.add(presentedIndex);
      }
    });
  }

  bool get _canSubmit {
    final current = _engine.current;
    if (current == null) return false;
    return switch (current.question.kind) {
      QuestionKind.single => _selected.length == 1,
      QuestionKind.multiple => _selected.isNotEmpty,
      QuestionKind.ordering => _sequence.length == current.choices.length,
    };
  }

  void _submit() {
    final current = _engine.current;
    if (current == null || !_canSubmit) return;

    final given = current.question.kind == QuestionKind.ordering
        ? List<int>.from(_sequence)
        : _selected.toList();

    _engine.submit(given);

    setState(() {
      _lastAnswerCorrect = _engine.answers.last.correct;
      _showingExplanation = true;
    });
  }

  void _next() {
    setState(() {
      _selected.clear();
      _sequence.clear();
      _showingExplanation = false;

      if (!_engine.advance()) {
        _result = _engine.finish();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final module = moduleFor(widget.domain);
    final result = _result;

    return Scaffold(
      appBar: AppBar(
        title: Text(module.title(L.of(context))),
        bottom: result == null
            ? PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: LinearProgressIndicator(
                  value: _engine.askedCount / widget.itemCount,
                  minHeight: 4,
                ),
              )
            : null,
      ),
      body: result != null
          ? _ResultView(result: result, onDone: () => Navigator.of(context).pop(result))
          : _buildQuestion(),
    );
  }

  Widget _buildQuestion() {
    final current = _engine.current;
    if (current == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final question = current.question;
    final theme = Theme.of(context);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Question ${_engine.askedCount + 1} of ${widget.itemCount}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    if (question.mandatory) const _CriticalBadge(),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  question.prompt,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  switch (question.kind) {
                    QuestionKind.single => 'Choose one answer.',
                    QuestionKind.multiple => 'Choose all that apply.',
                    QuestionKind.ordering => 'Tap the steps in the correct order.',
                  },
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                for (var i = 0; i < current.choices.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ChoiceTile(
                      label: current.choices[i],
                      kind: question.kind,
                      selected: question.kind == QuestionKind.ordering
                          ? _sequence.contains(i)
                          : _selected.contains(i),
                      orderPosition: question.kind == QuestionKind.ordering
                          ? _sequence.indexOf(i)
                          : -1,
                      // After answering, reveal which choices were actually
                      // correct so the explanation has something to point at.
                      revealCorrect: _showingExplanation &&
                          question.answer.contains(current.order[i]),
                      revealWrong: _showingExplanation &&
                          !question.answer.contains(current.order[i]) &&
                          (question.kind == QuestionKind.ordering
                              ? _sequence.contains(i)
                              : _selected.contains(i)),
                      onTap: () => _toggle(i, question.kind),
                    ),
                  ),
                if (_showingExplanation) ...[
                  const SizedBox(height: 8),
                  _ExplanationCard(
                    correct: _lastAnswerCorrect,
                    explanation: question.explanation,
                  ),
                ],
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _showingExplanation
                    ? _next
                    : (_canSubmit ? _submit : null),
                child: Text(_showingExplanation ? 'Continue' : 'Check answer'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.kind,
    required this.selected,
    required this.orderPosition,
    required this.revealCorrect,
    required this.revealWrong,
    required this.onTap,
  });

  final String label;
  final QuestionKind kind;
  final bool selected;
  final int orderPosition;
  final bool revealCorrect;
  final bool revealWrong;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Color borderColor;
    final Color background;
    if (revealCorrect) {
      borderColor = AppTheme.safeGreen;
      background = AppTheme.safeGreen.withValues(alpha: 0.16);
    } else if (revealWrong) {
      borderColor = AppTheme.hazardRed;
      background = AppTheme.hazardRed.withValues(alpha: 0.16);
    } else if (selected) {
      borderColor = theme.colorScheme.primary;
      background = theme.colorScheme.primary.withValues(alpha: 0.14);
    } else {
      borderColor = theme.colorScheme.outlineVariant;
      background = theme.colorScheme.surfaceContainerHighest;
    }

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: AppTheme.minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 2),
          ),
          child: Row(
            children: [
              _Marker(
                kind: kind,
                selected: selected,
                orderPosition: orderPosition,
                revealCorrect: revealCorrect,
                revealWrong: revealWrong,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Selection indicator.
///
/// Shape carries the meaning as well as colour — a circle for single choice, a
/// square for multiple, a number for ordering — so the interface still reads
/// correctly for the roughly one in twelve men with colour vision deficiency,
/// which is a meaningful share of a mining workforce.
class _Marker extends StatelessWidget {
  const _Marker({
    required this.kind,
    required this.selected,
    required this.orderPosition,
    required this.revealCorrect,
    required this.revealWrong,
  });

  final QuestionKind kind;
  final bool selected;
  final int orderPosition;
  final bool revealCorrect;
  final bool revealWrong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (revealCorrect) {
      return const Icon(Icons.check_circle, color: AppTheme.safeGreen, size: 26);
    }
    if (revealWrong) {
      return const Icon(Icons.cancel, color: AppTheme.hazardRed, size: 26);
    }

    if (kind == QuestionKind.ordering) {
      return Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: orderPosition >= 0
              ? theme.colorScheme.primary
              : Colors.transparent,
          border: Border.all(color: theme.colorScheme.outline, width: 2),
        ),
        child: orderPosition >= 0
            ? Text(
                '${orderPosition + 1}',
                style: TextStyle(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              )
            : null,
      );
    }

    final isSquare = kind == QuestionKind.multiple;
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: isSquare ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: isSquare ? BorderRadius.circular(6) : null,
        color: selected ? theme.colorScheme.primary : Colors.transparent,
        border: Border.all(color: theme.colorScheme.outline, width: 2),
      ),
      child: selected
          ? Icon(Icons.check, size: 18, color: theme.colorScheme.onPrimary)
          : null,
    );
  }
}

class _ExplanationCard extends StatelessWidget {
  const _ExplanationCard({required this.correct, required this.explanation});

  final bool correct;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final signal = correct ? SafetySignal.safe : SafetySignal.caution;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: signal.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: signal.color.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(signal.icon, color: signal.color, size: 22),
              const SizedBox(width: 10),
              Text(
                correct ? 'Correct' : 'Not quite',
                style: TextStyle(
                  color: signal.color,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            explanation,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _CriticalBadge extends StatelessWidget {
  const _CriticalBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.hazardRed.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.hazardRed.withValues(alpha: 0.6)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.priority_high, size: 15, color: AppTheme.hazardRed),
          SizedBox(width: 4),
          Text(
            'Must get right',
            style: TextStyle(
              color: AppTheme.hazardRed,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result, required this.onDone});

  final AssessmentResult result;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signal = result.passed ? SafetySignal.safe : SafetySignal.danger;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(signal.icon, size: 60, color: signal.color),
          const SizedBox(height: 16),
          Text(
            result.passed ? 'Assessment passed' : 'Assessment not passed',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${result.correctCount} of ${result.answers.length} correct  ·  '
            '${result.rawScore.round()}%',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          if (result.failedMandatory.isNotEmpty) ...[
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.hazardRed.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.hazardRed.withValues(alpha: 0.6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Life-critical questions answered wrongly',
                    style: TextStyle(
                      color: AppTheme.hazardRed,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'These must be right to be certified, whatever the total '
                    'score. Go through them again with your supervisor before '
                    'your next attempt.',
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  for (final question in result.failedMandatory)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.arrow_right, size: 20),
                          Expanded(
                            child: Text(
                              question.explanation,
                              style: theme.textTheme.bodySmall?.copyWith(
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: onDone, child: const Text('Done')),
          ),
        ],
      ),
    );
  }
}
