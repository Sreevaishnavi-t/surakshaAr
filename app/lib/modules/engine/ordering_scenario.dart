import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, IconData;

import '../../ar/nodes/basic_nodes.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/scene_graph.dart';
import '../../core/theme/app_theme.dart';
import '../catalogue.dart';
import 'scenario.dart';

/// One step in an ordered procedure.
class OrderedStep {
  const OrderedStep({
    required this.id,
    required this.icon,
    required this.label,
    required this.rationale,
    this.fatalIfSkipped = false,
  });

  final String id;
  final IconData icon;
  final String label;

  /// Why this step sits where it does. Shown when the worker gets it wrong,
  /// because an ordering only sticks if the reasoning behind it does.
  final String rationale;

  /// Steps whose omission would be fatal rather than merely wrong. Scored much
  /// more heavily.
  final bool fatalIfSkipped;
}

/// A reusable AR act for procedures whose whole difficulty is sequence.
///
/// Lockout-tagout, roof support, electrical isolation: in each case a worker can
/// usually list the steps, and the competence being tested is doing them in the
/// right order under pressure. Rather than writing three near-identical
/// scenarios, the shared mechanic lives here and each module supplies content.
///
/// Steps are scattered across an arc so the worker has to turn to find them,
/// and shuffled each attempt so position never encodes the answer.
class OrderingScenario extends ArScenario {
  OrderingScenario({
    required this.id,
    required this.domain,
    required this.brief,
    required this.prompt_,
    required this.successMessage,
    required this.timeoutMessage,
    required List<OrderedStep> steps,
    this.accent = AppTheme.infoBlue,
    this.timeLimit = const Duration(seconds: 90),
    math.Random? random,
  })  : _steps = steps,
        _random = random ?? math.Random() {
    _build();
  }

  @override
  final String id;

  @override
  final SafetyDomain domain;

  final String brief;
  final String prompt_;
  final String successMessage;
  final String timeoutMessage;
  final Color accent;
  final Duration timeLimit;

  final List<OrderedStep> _steps;
  final math.Random _random;

  final List<SceneNode> _nodes = [];
  final List<ActionRecord> _actions = [];
  final List<BillboardNode> _stepNodes = [];
  final Map<String, int> _orderById = {};

  int _nextExpectedIndex = 0;
  int _mistakes = 0;
  int _fatalOmissions = 0;
  Duration _elapsed = Duration.zero;
  Duration _lastCorrectAt = Duration.zero;
  bool _finished = false;
  ScenarioResult? _result;
  String? _feedback;
  Duration _feedbackUntil = Duration.zero;

  @override
  List<SceneNode> get nodes => _nodes;

  int get completedSteps => _nextExpectedIndex;

  int get totalSteps => _steps.length;

  void _build() {
    const floor = -kEyeHeightMetres;
    for (var i = 0; i < _steps.length; i++) {
      _orderById[_steps[i].id] = i;
    }

    final shuffled = List<OrderedStep>.from(_steps)..shuffle(_random);
    for (var i = 0; i < shuffled.length; i++) {
      final step = shuffled[i];
      final node = BillboardNode(
        id: step.id,
        position: scenePlacement(
          bearingDegrees: -58.0 + i * (116.0 / math.max(1, shuffled.length - 1)),
          distanceMetres: 2.9 + (i.isEven ? 0.0 : 0.45),
          heightMetres: floor + 1.35,
        ),
        icon: step.icon,
        color: accent,
        label: step.label,
        sizeMetres: 0.58,
      );

      _stepNodes.add(node);
      _nodes.add(node);
    }
  }

  @override
  ScenarioPrompt get prompt {
    final remaining = timeLimit - _elapsed;
    final clamped = remaining.isNegative ? Duration.zero : remaining;

    if (_feedback != null && _elapsed < _feedbackUntil) {
      return ScenarioPrompt(
        text: _feedback!,
        signal: SafetySignal.caution,
        remaining: clamped,
      );
    }

    if (_nextExpectedIndex >= _steps.length) {
      return ScenarioPrompt(
        text: successMessage,
        signal: SafetySignal.safe,
        remaining: clamped,
      );
    }

    return ScenarioPrompt(
      text: _elapsed < const Duration(seconds: 5) ? brief : prompt_,
      signal: SafetySignal.caution,
      hint: _hint,
      narrationKey: '$id.prompt',
      remaining: clamped,
    );
  }

  String? get _hint {
    if (_elapsed - _lastCorrectAt < const Duration(seconds: 18)) return null;
    final next = _steps[_nextExpectedIndex];
    return 'Next: ${next.label}. ${next.rationale}';
  }

  @override
  void update(Duration elapsed, ArCamera camera) {
    if (_finished) return;
    _elapsed = elapsed;

    if (_elapsed >= timeLimit) {
      _finish(passed: false, reason: timeoutMessage);
      return;
    }

    notifyListeners();
  }

  @override
  void handleTap(SceneNode node) {
    if (_finished) return;
    final index = _orderById[node.id];
    if (index == null) return;

    // Already taken — ignore rather than punish a stray second tap.
    if (index < _nextExpectedIndex) return;

    if (index == _nextExpectedIndex) {
      _actions.add(ActionRecord(
        stepId: id,
        targetId: node.id,
        outcome: ActionOutcome.correct,
        timeToAct: _elapsed - _lastCorrectAt,
        hintsUsed: _hint == null ? 0 : 1,
      ));

      _nextExpectedIndex++;
      _lastCorrectAt = _elapsed;

      final nodeIndex = _stepNodes.indexWhere((n) => n.id == node.id);
      if (nodeIndex >= 0) {
        _stepNodes[nodeIndex]
          ..interactive = false
          ..color = AppTheme.safeGreen;
      }

      if (_nextExpectedIndex >= _steps.length) {
        _finish(passed: true, reason: null);
      }
    } else {
      final expected = _steps[_nextExpectedIndex];
      _mistakes++;
      // Skipping a step whose omission is fatal is weighted far above simply
      // doing two steps out of order.
      if (expected.fatalIfSkipped) _fatalOmissions++;

      _actions.add(ActionRecord(
        stepId: id,
        targetId: node.id,
        outcome: expected.fatalIfSkipped
            ? ActionOutcome.fatal
            : ActionOutcome.incorrect,
        timeToAct: _elapsed - _lastCorrectAt,
        hintsUsed: _hint == null ? 0 : 1,
      ));

      _feedback = 'Not yet. ${expected.rationale}';
      _feedbackUntil = _elapsed + const Duration(seconds: 5);
    }

    notifyListeners();
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
      // Partial credit for progress: five of six steps ordered correctly is
      // genuinely different from guessing at the first.
      return (completedSteps / totalSteps * 45).clamp(0.0, 45.0);
    }

    var score = 100.0;
    score -= _mistakes * 11.0;
    score -= _fatalOmissions * 15.0;

    final seconds = _elapsed.inMilliseconds / 1000.0;
    final par = totalSteps * 8.0;
    if (seconds < par) score += (1 - seconds / par) * 8;

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
