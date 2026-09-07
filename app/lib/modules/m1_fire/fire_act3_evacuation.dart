import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, IconData, Icons;

import '../../ar/fx/fire_fx.dart';
import '../../ar/nodes/basic_nodes.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/scene_graph.dart';
import '../../core/theme/app_theme.dart';
import '../catalogue.dart';
import '../engine/scenario.dart';

/// One action in the evacuation sequence.
class _Step {
  const _Step({
    required this.id,
    required this.order,
    required this.icon,
    required this.label,
    required this.rationale,
  });

  final String id;

  /// Correct position, 1-based.
  final int order;

  final IconData icon;
  final String label;

  /// Why this step belongs where it does. Shown when the worker gets it wrong,
  /// because the ordering only sticks if the reasoning does.
  final String rationale;
}

abstract final class _Copy {
  static const brief =
      'The fire is spreading and cannot be fought. Evacuate in the correct '
      'order — tap the actions one after another.';
  static const prompt = 'What do you do next?';
  static const success = 'Correct order. That sequence gets everyone out.';
  static const timeout =
      'Too slow. An evacuation that is still being thought through is an '
      'evacuation that has already failed.';
}

/// **Fire & Explosion, Act 3 — evacuation sequencing.**
///
/// Six actions, all of them individually sensible, that only work in one order.
/// This is the act that tests judgement rather than knowledge: nearly every
/// worker can list the steps, and far fewer can order them under a countdown
/// with smoke thickening.
///
/// The two orderings that matter most: raising the alarm comes before anything
/// personal, because it protects everyone else in the building and costs
/// seconds; and reporting at the assembly point comes last, because an
/// evacuation where nobody knows who is still inside is why fire teams enter
/// buildings they did not need to.
class FireAct3EvacuationScenario extends ArScenario {
  FireAct3EvacuationScenario({math.Random? random})
      : _random = random ?? math.Random() {
    _build();
  }

  final math.Random _random;

  static const Duration _timeLimit = Duration(seconds: 75);

  static const List<_Step> _correctSequence = [
    _Step(
      id: 'step.alarm',
      order: 1,
      icon: Icons.notifications_active_outlined,
      label: 'Raise the alarm',
      rationale:
          'The alarm comes first. It costs two seconds and it protects everyone '
          'else in the building, not just you.',
    ),
    _Step(
      id: 'step.buddy',
      order: 2,
      icon: Icons.group_outlined,
      label: 'Alert and help your buddy',
      rationale:
          'Alert the people near you before you leave. Someone working inside a '
          'noisy plant may not have heard the alarm at all.',
    ),
    _Step(
      id: 'step.shutdown',
      order: 3,
      icon: Icons.power_settings_new,
      label: 'Shut down your machine',
      rationale:
          'Make your own work area safe on the way out — but only if it takes '
          'seconds. Never delay leaving for equipment.',
    ),
    _Step(
      id: 'step.door',
      order: 4,
      icon: Icons.door_front_door_outlined,
      label: 'Close the door behind you',
      rationale:
          'A closed door starves the fire of oxygen and holds back smoke for '
          'minutes. Close it, never lock it.',
    ),
    _Step(
      id: 'step.assembly',
      order: 5,
      icon: Icons.flag_outlined,
      label: 'Go to the assembly point',
      rationale:
          'Go to the marked assembly point by the shortest safe route, and do '
          'not stop to collect belongings.',
    ),
    _Step(
      id: 'step.report',
      order: 6,
      icon: Icons.how_to_reg_outlined,
      label: 'Report to the fire warden',
      rationale:
          'Report in so the roll can be counted. An evacuation where nobody '
          'knows who is still inside is why fire teams enter buildings they did '
          'not need to.',
    ),
  ];

  @override
  String get id => 'm1.act3.evacuation';

  @override
  SafetyDomain get domain => SafetyDomain.fire;

  final List<SceneNode> _nodes = [];
  final List<ActionRecord> _actions = [];
  final List<BillboardNode> _stepNodes = [];
  final Map<String, _Step> _stepsById = {};

  late final FireNode _fire;
  late final SmokeColumnNode _smoke;

  int _nextExpectedOrder = 1;
  int _mistakes = 0;
  Duration _elapsed = Duration.zero;
  Duration _lastCorrectAt = Duration.zero;
  bool _finished = false;
  ScenarioResult? _result;
  String? _feedback;
  Duration _feedbackUntil = Duration.zero;

  @override
  List<SceneNode> get nodes => _nodes;

  void _build() {
    const floor = -kEyeHeightMetres;
    final mirror = _random.nextBool() ? 1.0 : -1.0;

    _fire = FireNode(
      id: 'fire',
      position: scenePlacement(
        bearingDegrees: 150 * mirror,
        distanceMetres: 6.5,
        heightMetres: floor,
      ),
      heightMetres: 1.7,
      widthMetres: 1.3,
      intensity: 1.3,
    );

    _smoke = SmokeColumnNode(
      id: 'smoke',
      position: _fire.position.clone()..z += 1.0,
      density: 1.2,
    );

    _nodes.addAll([_smoke, _fire]);

    // Shuffle placement so position never encodes the answer. Steps are spread
    // in an arc that requires turning the head, keeping this an AR task rather
    // than a list on a screen.
    final shuffled = List<_Step>.from(_correctSequence)..shuffle(_random);
    for (var i = 0; i < shuffled.length; i++) {
      final step = shuffled[i];
      _stepsById[step.id] = step;

      final bearing = (-62.0 + i * 25.0) * mirror;
      final node = BillboardNode(
        id: step.id,
        position: scenePlacement(
          bearingDegrees: bearing,
          distanceMetres: 3.0 + (i.isEven ? 0.0 : 0.5),
          heightMetres: floor + 1.15,
        ),
        icon: step.icon,
        color: const Color(0xFF42A5F5),
        label: step.label,
        sizeMetres: 0.62,
      );

      _stepNodes.add(node);
      _nodes.add(node);
    }
  }

  @override
  ScenarioPrompt get prompt {
    final remaining = _timeLimit - _elapsed;
    final clamped = remaining.isNegative ? Duration.zero : remaining;

    if (_feedback != null && _elapsed < _feedbackUntil) {
      return ScenarioPrompt(
        text: _feedback!,
        signal: SafetySignal.caution,
        remaining: clamped,
      );
    }

    if (_nextExpectedOrder > _correctSequence.length) {
      return ScenarioPrompt(
        text: _Copy.success,
        signal: SafetySignal.safe,
        remaining: clamped,
      );
    }

    return ScenarioPrompt(
      text: _elapsed < const Duration(seconds: 5) ? _Copy.brief : _Copy.prompt,
      signal: SafetySignal.danger,
      hint: _hint,
      narrationKey: 'm1.act3.sequence',
      remaining: clamped,
    );
  }

  /// Names the step only after a long pause, and even then explains rather than
  /// simply pointing. Being unable to finish teaches nothing.
  String? get _hint {
    if (_elapsed - _lastCorrectAt < const Duration(seconds: 16)) return null;
    final next = _correctSequence.firstWhere((s) => s.order == _nextExpectedOrder);
    return 'Next: ${next.label}. ${next.rationale}';
  }

  @override
  double get hazeDensity {
    // Smoke thickens as the evacuation drags, so dithering has a visible cost.
    final t = _elapsed.inMilliseconds / _timeLimit.inMilliseconds;
    return (0.15 + t * 0.6).clamp(0.0, 0.75);
  }

  int get completedSteps => _nextExpectedOrder - 1;

  int get totalSteps => _correctSequence.length;

  @override
  void update(Duration elapsed, ArCamera camera) {
    if (_finished) return;
    _elapsed = elapsed;

    final growth = 1.3 + (_elapsed.inMilliseconds / _timeLimit.inMilliseconds) * 0.6;
    _fire.intensity = growth;
    _smoke.density = growth * 0.9;

    if (_elapsed >= _timeLimit) {
      _finish(passed: false, reason: _Copy.timeout);
      return;
    }

    notifyListeners();
  }

  @override
  void handleTap(SceneNode node) {
    if (_finished) return;
    final step = _stepsById[node.id];
    if (step == null) return;

    // Already done — ignore rather than penalise a stray double tap.
    if (step.order < _nextExpectedOrder) return;

    if (step.order == _nextExpectedOrder) {
      _record(step.id, ActionOutcome.correct);
      _nextExpectedOrder++;
      _lastCorrectAt = _elapsed;

      final index = _stepNodes.indexWhere((n) => n.id == step.id);
      if (index >= 0) {
        _stepNodes[index]
          ..interactive = false
          ..color = AppTheme.safeGreen;
      }

      if (_nextExpectedOrder > _correctSequence.length) {
        _finish(passed: true, reason: null);
        return;
      }
    } else {
      _mistakes++;
      _record(step.id, ActionOutcome.incorrect);

      final expected =
          _correctSequence.firstWhere((s) => s.order == _nextExpectedOrder);
      _showFeedback(
        'Not yet. ${expected.rationale}',
      );
    }

    notifyListeners();
  }

  void _record(String targetId, ActionOutcome outcome) {
    _actions.add(ActionRecord(
      stepId: id,
      targetId: targetId,
      outcome: outcome,
      timeToAct: _elapsed - _lastCorrectAt,
      hintsUsed: _hint == null ? 0 : 1,
    ));
  }

  void _showFeedback(String message) {
    _feedback = message;
    _feedbackUntil = _elapsed + const Duration(seconds: 5);
  }

  void _finish({required bool passed, required String? reason}) {
    if (_finished) return;
    _finished = true;

    _result = ScenarioResult(
      scenarioId: id,
      domain: domain,
      passed: passed,
      behaviouralScore: _score(passed: passed),
      actions: List.unmodifiable(_actions),
      duration: _elapsed,
      fatalReason: reason,
    );

    notifyListeners();
  }

  double _score({required bool passed}) {
    if (!passed) {
      // Partial credit for how far the sequence got. Someone who ordered five
      // of six correctly knows more than someone who guessed at the first step,
      // and the certificate should be able to tell them apart.
      return (completedSteps / totalSteps * 45).clamp(0.0, 45.0);
    }

    var score = 100.0;
    score -= _mistakes * 12.0;

    final seconds = _elapsed.inMilliseconds / 1000.0;
    if (seconds < 40) score += (1 - seconds / 40) * 8;

    return score.clamp(0.0, 100.0);
  }

  @override
  bool get isFinished => _finished;

  @override
  ScenarioResult? get result => _result;

  @override
  void abandon() {
    if (_finished) return;
    _finish(passed: false, reason: 'Drill exited before completion.');
  }
}
