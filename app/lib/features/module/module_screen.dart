import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../assessment/assessment_engine.dart';
import '../../core/diagnostics.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/services.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories.dart';
import '../../modules/catalogue.dart';
import '../../modules/engine/scenario.dart';
import '../assessment/assessment_screen.dart';
import '../session/ar_session_screen.dart';

/// The two halves of a module, and where the worker has got to.
///
/// Certification needs both. Requiring only the drill leaves the reasoning
/// untested; requiring only the assessment is the classroom outcome — under 20%
/// retention after a week — that this whole platform exists to replace. So the
/// screen shows them as two gates rather than one score.
class ModuleScreen extends ConsumerStatefulWidget {
  const ModuleScreen({super.key, required this.domain, required this.worker});

  final SafetyDomain domain;
  final WorkerRecord worker;

  @override
  ConsumerState<ModuleScreen> createState() => _ModuleScreenState();
}

class _ModuleScreenState extends ConsumerState<ModuleScreen> {
  double? _drillScore;
  double? _assessmentScore;
  bool _loading = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final attempts = ref.read(servicesProvider).attempts;
      final drill = await attempts.bestDrillScore(
        widget.worker.id,
        widget.domain,
      );
      final assessment = await attempts.bestAssessmentScore(
        widget.worker.id,
        widget.domain,
      );

      if (!mounted) return;
      setState(() {
        _drillScore = drill;
        _assessmentScore = assessment;
        _loadError = null;
        _loading = false;
      });
    } catch (error, stack) {
      // A screen that spins forever tells the worker nothing and a supervisor
      // even less. Surface the failure and offer a retry.
      Diagnostics.instance.record(
        'module.refresh failed: $error',
        stackTrace: stack,
      );
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  Future<void> _runDrill() async {
    final result = await Navigator.of(context).push<ScenarioResult>(
      MaterialPageRoute(builder: (_) => ArSessionScreen(domain: widget.domain)),
    );

    if (result == null || !mounted) return;

    // Every attempt is recorded, including failures. A worker who tried the
    // lift during a fire drill and learned not to is exactly the evidence a
    // safety officer wants, and silently discarding failed attempts would make
    // the compliance record flattering rather than useful.
    await ref
        .read(servicesProvider)
        .attempts
        .recordDrill(workerId: widget.worker.id, result: result);

    if (mounted) await _refresh();
  }

  Future<void> _runAssessment() async {
    final result = await Navigator.of(context).push<AssessmentResult>(
      MaterialPageRoute(
        builder: (_) => AssessmentScreen(domain: widget.domain),
      ),
    );

    if (result == null || !mounted) return;

    await ref
        .read(servicesProvider)
        .attempts
        .recordAssessment(workerId: widget.worker.id, result: result);

    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L.of(context);
    final module = moduleFor(widget.domain);
    final theme = Theme.of(context);

    final drill = _drillScore;
    final assessment = _assessmentScore;
    final complete = drill != null && assessment != null;

    return Scaffold(
      appBar: AppBar(title: Text(module.title(l10n))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? _LoadFailure(
              error: _loadError!,
              onRetry: () {
                setState(() => _loading = true);
                _refresh();
              },
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    module.summary(l10n),
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  if (module.depth == ModuleDepth.introductory)
                    const _IntroductoryNotice(),
                  const SizedBox(height: 22),

                  _StageCard(
                    step: 1,
                    title: 'AR drill',
                    body:
                        'Practise in your own surroundings. You are scored on '
                        'what you do and how fast you do it.',
                    icon: Icons.view_in_ar_outlined,
                    accent: module.accent,
                    score: drill,
                    actionLabel: drill == null ? 'Start drill' : 'Try again',
                    onAction: _runDrill,
                  ),
                  const SizedBox(height: 14),
                  _StageCard(
                    step: 2,
                    title: 'Assessment',
                    body:
                        'Questions that check you understand why, not just '
                        'what. Some must be answered correctly to pass.',
                    icon: Icons.quiz_outlined,
                    accent: module.accent,
                    score: assessment,
                    actionLabel: assessment == null
                        ? 'Start assessment'
                        : 'Try again',
                    onAction: _runAssessment,
                  ),

                  const SizedBox(height: 24),
                  if (complete)
                    _CompositePanel(
                      composite: compositeScore(
                        assessmentScore: assessment,
                        behaviouralScore: drill,
                      ),
                    )
                  else
                    _PendingPanel(
                      needsDrill: drill == null,
                      needsAssessment: assessment == null,
                    ),
                ],
              ),
            ),
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 52,
              color: AppTheme.hazardRed,
            ),
            const SizedBox(height: 16),
            Text(
              'Could not read your training record',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            SelectableText(
              error.toString(),
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

class _StageCard extends StatelessWidget {
  const _StageCard({
    required this.step,
    required this.title,
    required this.body,
    required this.icon,
    required this.accent,
    required this.score,
    required this.actionLabel,
    required this.onAction,
  });

  final int step;
  final String title;
  final String body;
  final IconData icon;
  final Color accent;

  /// Best passing score so far, or null if not yet passed.
  final double? score;

  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = score != null;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: done
              ? AppTheme.safeGreen.withValues(alpha: 0.6)
              : theme.colorScheme.outlineVariant,
          width: done ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done
                      ? AppTheme.safeGreen
                      : accent.withValues(alpha: 0.2),
                ),
                child: done
                    ? const Icon(Icons.check, color: Colors.white, size: 24)
                    : Text(
                        '$step',
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (done)
                Text(
                  '${score!.round()}',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: AppTheme.safeGreen,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: done
                ? OutlinedButton(onPressed: onAction, child: Text(actionLabel))
                : FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ),
        ],
      ),
    );
  }
}

class _CompositePanel extends StatelessWidget {
  const _CompositePanel({required this.composite});

  final double composite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.safeGreen.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.safeGreen.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.verified_outlined,
                color: AppTheme.safeGreen,
                size: 26,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Module complete',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: AppTheme.safeGreen,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                composite.round().toString(),
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: AppTheme.safeGreen,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Your score is 60% from the assessment and 40% from what you '
            'actually did in the drill. Open your certificate from the home '
            'screen to get your QR code.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _PendingPanel extends StatelessWidget {
  const _PendingPanel({
    required this.needsDrill,
    required this.needsAssessment,
  });

  final bool needsDrill;
  final bool needsAssessment;

  @override
  Widget build(BuildContext context) {
    final missing = [
      if (needsDrill) 'the AR drill',
      if (needsAssessment) 'the assessment',
    ].join(' and ');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Pass $missing to complete this module. Both are needed before a '
              'certificate can be issued.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Says plainly that a module is shorter than the two built to full depth.
///
/// A worker opening a one-act module should know it is an introduction, and an
/// evaluator should not have to guess which modules were built out.
class _IntroductoryNotice extends StatelessWidget {
  const _IntroductoryNotice();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            size: 18,
            color: AppTheme.cautionAmber,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This is a short introductory module. Fire and Gas are the two '
              'full-length drills.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.cautionAmber,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
