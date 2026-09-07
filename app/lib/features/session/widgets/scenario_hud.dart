import 'package:flutter/material.dart';

import '../../../ar/pose/device_pose.dart';
import '../../../core/theme/app_theme.dart';
import '../../../modules/engine/scenario.dart';

/// The instruction band and status furniture drawn over a live AR scene.
///
/// Kept to the screen edges on purpose: the middle of the view is where the
/// worker is looking for hazards, and a HUD that covers it defeats the exercise.
class ScenarioHud extends StatelessWidget {
  const ScenarioHud({
    super.key,
    required this.prompt,
    required this.poseSource,
    required this.hasPose,
    required this.onExit,
  });

  final ScenarioPrompt prompt;
  final PoseSource poseSource;
  final bool hasPose;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _TopBar(
            remaining: prompt.remaining,
            poseSource: poseSource,
            hasPose: hasPose,
            onExit: onExit,
          ),
          const Spacer(),
          _InstructionBand(prompt: prompt),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.remaining,
    required this.poseSource,
    required this.hasPose,
    required this.onExit,
  });

  final Duration? remaining;
  final PoseSource poseSource;
  final bool hasPose;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          _GlassButton(
            icon: Icons.close,
            semanticLabel: 'Leave drill',
            onTap: onExit,
          ),
          const SizedBox(width: 10),
          if (!hasPose) const _TrackingWarning(),
          const Spacer(),
          if (remaining != null) _CountdownPill(remaining: remaining!),
        ],
      ),
    );
  }
}

/// Shown until a real sensor sample arrives.
///
/// Being explicit about this matters: an AR view that silently renders at the
/// identity pose looks like a bug to the worker and like working software to an
/// evaluator. Neither is acceptable.
class _TrackingWarning extends StatelessWidget {
  const _TrackingWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.cautionAmber.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.screen_rotation_alt, size: 18, color: Colors.black87),
          SizedBox(width: 8),
          Text(
            'Waiting for motion sensor',
            style: TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _CountdownPill extends StatelessWidget {
  const _CountdownPill({required this.remaining});

  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final seconds = remaining.inSeconds;
    final urgent = seconds <= 10;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: (urgent ? AppTheme.hazardRed : Colors.black).withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: urgent ? AppTheme.hazardRed : Colors.white24,
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            urgent ? Icons.timer_outlined : Icons.schedule,
            size: 18,
            color: Colors.white,
          ),
          const SizedBox(width: 8),
          Text(
            '${seconds}s',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 16,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// The current instruction, plus the audio button.
///
/// The listen control is full-height and sits at the trailing edge where a thumb
/// naturally rests. For a worker who reads slowly, this is the primary way the
/// instruction gets delivered, not a secondary affordance.
class _InstructionBand extends StatelessWidget {
  const _InstructionBand({required this.prompt});

  final ScenarioPrompt prompt;

  @override
  Widget build(BuildContext context) {
    final signal = prompt.signal;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: signal.color.withValues(alpha: 0.75), width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(signal.icon, color: signal.color, size: 26),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      prompt.text,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _GlassButton(
                    icon: Icons.volume_up_outlined,
                    semanticLabel: 'Listen to this instruction',
                    // Narration audio is bundled in Phase 4. Disabled rather
                    // than hidden so the affordance is discoverable now.
                    onTap: null,
                  ),
                ],
              ),
            ),
            if (prompt.hint != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: BoxDecoration(
                  color: AppTheme.cautionAmber.withValues(alpha: 0.18),
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(14),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.lightbulb_outline,
                      size: 20,
                      color: AppTheme.cautionAmber,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        prompt.hint!,
                        style: const TextStyle(
                          color: AppTheme.cautionAmber,
                          fontSize: 15,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Colors.white24),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            // Gloved hands: above the Material 48dp minimum.
            width: AppTheme.minTouchTarget,
            height: AppTheme.minTouchTarget,
            child: Icon(
              icon,
              color: onTap == null ? Colors.white38 : Colors.white,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}

/// Result of a completed act.
///
/// Leads with what the worker got right or wrong in plain language, and only
/// then shows a number. A score with no explanation is the classroom failure
/// mode this whole platform exists to replace.
class ScenarioResultSheet extends StatelessWidget {
  const ScenarioResultSheet({
    super.key,
    required this.result,
    required this.onDone,
  });

  final ScenarioResult result;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final passed = result.passed;
    final signal = passed ? SafetySignal.safe : SafetySignal.danger;

    final wrongActions = result.actions
        .where((a) => a.outcome != ActionOutcome.correct)
        .toList();

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.86),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(signal.icon, size: 60, color: signal.color),
                const SizedBox(height: 16),
                Text(
                  passed ? 'Drill complete' : 'Drill not passed',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),

                if (result.fatalReason != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTheme.hazardRed.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.hazardRed.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Text(
                      result.fatalReason!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                _ScoreRow(
                  label: 'Performance in the drill',
                  value: result.behaviouralScore,
                ),
                const SizedBox(height: 8),
                _MetaRow(
                  icon: Icons.schedule,
                  label: 'Time taken',
                  value: '${result.duration.inSeconds}s',
                ),
                _MetaRow(
                  icon: Icons.touch_app_outlined,
                  label: 'Wrong choices',
                  value: '${wrongActions.length}',
                ),

                if (wrongActions.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    'What to remember',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final action in wrongActions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.error_outline,
                            size: 18,
                            color: AppTheme.cautionAmber,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _lessonFor(action.targetId),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],

                const SizedBox(height: 26),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onDone,
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Turns a recorded wrong choice back into the lesson it was testing.
  static String _lessonFor(String targetId) {
    return switch (targetId) {
      'exit.locked' =>
        'The nearest door is not always the way out. Look for the green fire exit sign.',
      'exit.lift' =>
        'Never use a lift during a fire. Take the stairs or a marked fire exit.',
      'fire' || 'smoke' => 'Move away from smoke and flame, never towards them.',
      _ => 'Review this step before your next attempt.',
    };
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final colour = value >= 80
        ? AppTheme.safeGreen
        : value >= 50
            ? AppTheme.cautionAmber
            : AppTheme.hazardRed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 15)),
            Text(
              value.round().toString(),
              style: TextStyle(
                color: colour,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value / 100,
            minHeight: 8,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation(colour),
          ),
        ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 17, color: Colors.white54),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14)),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Manual field-of-view trim.
///
/// Only shown when Camera2 gave us no lens metadata. Rather than silently using
/// a guessed FOV and letting overlays drift, the worker gets a control and a
/// plain explanation of what it is for.
class CalibrationSlider extends StatelessWidget {
  const CalibrationSlider({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.straighten, size: 18, color: Colors.white70),
          const SizedBox(width: 10),
          const Text(
            'Fit',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: 0.6,
              max: 1.6,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
