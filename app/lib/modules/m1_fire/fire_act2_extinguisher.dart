import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/material.dart' show Color, IconData, Icons;
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../../ar/fx/fire_fx.dart';
import '../../ar/nodes/basic_nodes.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/scene_graph.dart';
import '../../core/theme/app_theme.dart';
import '../catalogue.dart';
import '../engine/scenario.dart';

/// The four steps of extinguisher use, plus the selection that precedes them.
enum _Phase { select, pull, aim, squeeze, done }

abstract final class _Copy {
  static const brief =
      'A motor control panel is on fire. Choose the right extinguisher.';
  static const chooseAgent = 'Which extinguisher for an electrical fire?';

  static const wrongWater =
      'Water conducts electricity. On a live panel it would carry the current '
      'straight back to you.';
  static const wrongFoam =
      'Foam is water-based and conducts. Not for live electrical equipment.';
  static const wrongMetal =
      'That is a Class D unit for burning metals. It will not deal with an '
      'electrical fire.';
  static const rightAgent =
      'Correct. CO2 does not conduct and leaves no residue on the equipment.';

  static const pull = 'Pull the safety pin. Swipe across to pull it out.';
  static const aim =
      'Aim at the BASE of the fire, not the flames. Point the phone low.';
  static const aimingHigh =
      'You are aiming at the flames. Drop your aim to the base, where the fuel is.';
  static const squeeze = 'Press and hold to squeeze the handle.';
  static const sweep = 'Keep holding and sweep side to side across the base.';
  static const releasedEarly =
      'You let go. Keep the handle squeezed until the fire is out.';
  static const lostAim =
      'Your aim drifted off the base. Bring it back down before you lose the '
      'rest of the extinguisher.';

  static const outOfAgent =
      'The extinguisher is empty. A portable unit gives you only ten to fifteen '
      'seconds — that is why aim matters more than speed.';
  static const success = 'Fire out. Good technique.';
  static const timeout =
      'The fire took hold. At this size it is beyond a portable extinguisher — '
      'evacuate and call the fire team.';
}

/// **Fire & Explosion, Act 2 — extinguisher selection and PASS technique.**
///
/// The part of fire training that is almost never practised, because setting
/// real fires to practise on is expensive and dangerous. So most workers have
/// only ever been *told* about PASS.
///
/// Each step is a genuine physical action measured by the phone's own sensors
/// rather than a button that says "aim":
///
/// * **Pull** — a swipe, because pulling a pin is a movement.
/// * **Aim** — the device must actually point at the base of the fire. Aiming
///   at the flames, which is the near-universal instinct, fails and says why.
/// * **Squeeze** — press and hold. Discharge only runs while held.
/// * **Sweep** — measured as real yaw rotation of the handset, requiring a
///   genuine side-to-side arc with a direction reversal.
///
/// A portable extinguisher carries roughly ten to fifteen seconds of agent, and
/// that budget is modelled: agent drains only while the handle is squeezed, and
/// drains without effect while the aim is off the base. Running out because you
/// sprayed the flames is the lesson.
class FireAct2ExtinguisherScenario extends ArScenario {
  FireAct2ExtinguisherScenario({math.Random? random})
      : _random = random ?? math.Random() {
    _build();
  }

  final math.Random _random;

  static const Duration _timeLimit = Duration(seconds: 90);

  /// Discharge budget of a typical portable CO2 unit.
  static const double _agentSeconds = 13.0;

  /// How close to the base the aim must be, in radians. About 8 degrees.
  static const double _aimTolerance = 0.14;

  /// Yaw arc that counts as a sweep, in radians. About 17 degrees each way.
  static const double _sweepArc = 0.30;

  @override
  String get id => 'm1.act2.extinguisher';

  @override
  SafetyDomain get domain => SafetyDomain.fire;

  final List<SceneNode> _nodes = [];
  final List<ActionRecord> _actions = [];

  late final FireNode _fire;
  late final SmokeColumnNode _smoke;
  late final Vector3 _basePosition;
  late final Vector3 _flamePosition;
  final List<BillboardNode> _extinguishers = [];

  _Phase _phase = _Phase.select;
  Duration _elapsed = Duration.zero;
  Duration? _lastFrame;
  Duration _phaseStartedAt = Duration.zero;

  double _agentRemaining = _agentSeconds;
  double _fireHealth = 1.0;
  bool _pressing = false;
  double _dragAccumulated = 0;

  // Sweep tracking: the arc covered while squeezing, and whether the worker
  // actually reversed direction rather than turning steadily one way.
  double? _sweepMinYaw;
  double? _sweepMaxYaw;
  double? _lastYaw;
  int _sweepReversals = 0;
  int _lastSweepDirection = 0;

  bool _aimOnBase = false;
  Duration _aimHeld = Duration.zero;

  int _wrongChoices = 0;
  int _aimDrifts = 0;
  int _earlyReleases = 0;
  bool _finished = false;
  ScenarioResult? _result;
  String? _feedback;
  Duration _feedbackUntil = Duration.zero;

  @override
  List<SceneNode> get nodes => _nodes;

  void _build() {
    final mirror = _random.nextBool() ? 1.0 : -1.0;
    final bearing = (12 + (_random.nextDouble() - 0.5) * 20) * mirror;
    const floor = -kEyeHeightMetres;

    _basePosition = scenePlacement(
      bearingDegrees: bearing,
      distanceMetres: 3.4,
      heightMetres: floor,
    );
    // Roughly where the visible flames sit — a metre above the base. Aiming
    // here is the natural instinct and the thing the act exists to correct.
    _flamePosition = _basePosition.clone()..z += 1.0;

    _fire = FireNode(
      id: 'fire',
      position: _basePosition.clone(),
      heightMetres: 1.25,
      widthMetres: 0.9,
    );

    _smoke = SmokeColumnNode(
      id: 'smoke',
      position: _basePosition.clone()..z += 0.8,
      density: 0.7,
    );

    // A wall panel behind the fire, so it reads as an electrical fire rather
    // than a fire in mid-air. The class of fire is the whole first decision.
    final panel = BillboardNode(
      id: 'panel',
      position: _basePosition.clone()..z += 0.85,
      icon: Icons.electrical_services,
      color: const Color(0xFF90A4AE),
      sizeMetres: 0.85,
      interactive: false,
      sortBias: -0.1,
    );

    _nodes.addAll([_smoke, panel, _fire]);
    _buildExtinguishers(mirror);
  }

  /// Lays the extinguisher choices out in a shallow arc in front of the worker.
  ///
  /// Order is shuffled each attempt so the correct answer is never in a
  /// memorable position.
  void _buildExtinguishers(double mirror) {
    final options = <({String id, IconData icon, Color colour, String label})>[
      (id: 'ext.co2', icon: Icons.ac_unit, colour: const Color(0xFF212121), label: 'CO2'),
      (id: 'ext.water', icon: Icons.water_drop, colour: const Color(0xFFD32F2F), label: 'Water'),
      (id: 'ext.foam', icon: Icons.bubble_chart, colour: const Color(0xFFF9A825), label: 'Foam'),
      (id: 'ext.metal', icon: Icons.grain, colour: const Color(0xFF1565C0), label: 'Class D'),
    ]..shuffle(_random);

    const floor = -kEyeHeightMetres + 0.45;
    for (var i = 0; i < options.length; i++) {
      final option = options[i];
      final bearing = (-42.0 + i * 28.0) * mirror;
      final node = BillboardNode(
        id: option.id,
        position: scenePlacement(
          bearingDegrees: bearing,
          distanceMetres: 2.3,
          heightMetres: floor,
        ),
        icon: option.icon,
        color: option.colour,
        label: option.label,
        sizeMetres: 0.5,
      );
      _extinguishers.add(node);
      _nodes.add(node);
    }
  }

  // ------------------------------------------------------------------ prompt

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

    return switch (_phase) {
      _Phase.select => ScenarioPrompt(
          text: _elapsed < const Duration(seconds: 4)
              ? _Copy.brief
              : _Copy.chooseAgent,
          signal: SafetySignal.danger,
          narrationKey: 'm1.act2.choose',
          remaining: clamped,
        ),
      _Phase.pull => ScenarioPrompt(
          text: _Copy.pull,
          signal: SafetySignal.caution,
          narrationKey: 'm1.act2.pull',
          remaining: clamped,
        ),
      _Phase.aim => ScenarioPrompt(
          text: _Copy.aim,
          signal: SafetySignal.caution,
          hint: _aimOnBase ? null : _Copy.aimingHigh,
          narrationKey: 'm1.act2.aim',
          remaining: clamped,
        ),
      _Phase.squeeze => ScenarioPrompt(
          text: _pressing ? _Copy.sweep : _Copy.squeeze,
          signal: SafetySignal.caution,
          hint: _pressing && !_aimOnBase ? _Copy.lostAim : null,
          narrationKey: 'm1.act2.squeeze',
          remaining: clamped,
        ),
      _Phase.done => ScenarioPrompt(
          text: _Copy.success,
          signal: SafetySignal.safe,
          remaining: clamped,
        ),
    };
  }

  @override
  double get hazeDensity => (0.18 + 0.30 * (1 - _fireHealth)).clamp(0.0, 0.5);

  /// Remaining agent as a fraction, for the HUD gauge.
  double get agentFraction => (_agentRemaining / _agentSeconds).clamp(0.0, 1.0);

  double get fireHealth => _fireHealth;

  // ------------------------------------------------------------------ update

  @override
  void update(Duration elapsed, ArCamera camera) {
    if (_finished) return;

    final delta = _lastFrame == null ? Duration.zero : elapsed - _lastFrame!;
    _lastFrame = elapsed;
    _elapsed = elapsed;
    final dt = delta.inMicroseconds / 1e6;

    _aimOnBase = camera.angleTo(_basePosition) < _aimTolerance;

    // Aiming at the flames rather than the base is the mistake this act exists
    // to correct, so it is detected explicitly rather than inferred from "not
    // on base" — that lets the feedback name what the worker is doing wrong.
    final aimingAtFlames =
        !_aimOnBase && camera.angleTo(_flamePosition) < _aimTolerance * 1.6;

    switch (_phase) {
      case _Phase.aim:
        if (_aimOnBase) {
          _aimHeld += delta;
          if (_aimHeld >= const Duration(milliseconds: 500)) {
            _enterPhase(_Phase.squeeze);
          }
        } else {
          _aimHeld = Duration.zero;
          if (aimingAtFlames && _elapsed > _phaseStartedAt + const Duration(seconds: 3)) {
            _showFeedback(_Copy.aimingHigh);
          }
        }

      case _Phase.squeeze:
        _updateDischarge(camera, dt);

      case _Phase.select:
      case _Phase.pull:
      case _Phase.done:
        break;
    }

    // The fire grows whenever it is not being suppressed.
    if (_phase != _Phase.done) {
      final growth = _phase == _Phase.squeeze && _pressing ? 0.0 : dt * 0.035;
      _fireHealth = (_fireHealth + growth).clamp(0.0, 1.6);
    }

    _fire.intensity = _fireHealth;
    _smoke.density = (_fireHealth * 0.75).clamp(0.0, 1.2);

    if (_elapsed >= _timeLimit) {
      _finish(passed: false, reason: _Copy.timeout);
      return;
    }

    notifyListeners();
  }

  /// Drains agent and knocks the fire down, but only when aimed correctly.
  void _updateDischarge(ArCamera camera, double dt) {
    if (!_pressing) return;

    // Agent drains whether or not the aim is good. That asymmetry is the point:
    // a worker who sprays the flames empties the extinguisher and achieves
    // nothing, which is exactly what happens in reality.
    _agentRemaining -= dt;

    if (_agentRemaining <= 0) {
      _agentRemaining = 0;
      _finish(passed: false, reason: _Copy.outOfAgent);
      return;
    }

    _trackSweep(camera);

    if (!_aimOnBase) {
      if (_aimDrifts == 0 || _elapsed > _feedbackUntil) {
        _aimDrifts++;
        _showFeedback(_Copy.lostAim);
      }
      return;
    }

    // Suppression needs aim *and* sweep. Holding a jet on one spot leaves the
    // rest of the burning surface alight.
    final sweeping = _sweepSpan >= _sweepArc && _sweepReversals >= 1;
    final rate = sweeping ? 0.34 : 0.12;
    _fireHealth -= dt * rate;

    if (_fireHealth <= 0) {
      _fireHealth = 0;
      _enterPhase(_Phase.done);
      _record('fire.extinguished', ActionOutcome.correct);
      _finish(passed: true, reason: null);
    }
  }

  double get _sweepSpan {
    final min = _sweepMinYaw;
    final max = _sweepMaxYaw;
    if (min == null || max == null) return 0;
    return max - min;
  }

  /// Measures real handset rotation, and requires a direction reversal.
  ///
  /// Without the reversal check a worker could satisfy "sweep" by slowly
  /// turning one way, which is not the technique being taught.
  void _trackSweep(ArCamera camera) {
    final yaw = camera.pose.yaw;
    final previous = _lastYaw;
    _lastYaw = yaw;

    _sweepMinYaw = _sweepMinYaw == null ? yaw : math.min(_sweepMinYaw!, yaw);
    _sweepMaxYaw = _sweepMaxYaw == null ? yaw : math.max(_sweepMaxYaw!, yaw);

    if (previous == null) return;
    var difference = yaw - previous;
    // Unwrap across the +/-pi discontinuity so a worker facing that way is not
    // credited with a huge phantom sweep.
    if (difference > math.pi) difference -= 2 * math.pi;
    if (difference < -math.pi) difference += 2 * math.pi;
    if (difference.abs() < 0.004) return;

    final direction = difference > 0 ? 1 : -1;
    if (_lastSweepDirection != 0 && direction != _lastSweepDirection) {
      _sweepReversals++;
    }
    _lastSweepDirection = direction;
  }

  // ------------------------------------------------------------------ input

  @override
  void handleTap(SceneNode node) {
    if (_finished || _phase != _Phase.select) return;

    switch (node.id) {
      case 'ext.co2':
        _record(node.id, ActionOutcome.correct);
        _showFeedback(_Copy.rightAgent);
        for (final extinguisher in _extinguishers) {
          extinguisher.visible = extinguisher.id == 'ext.co2';
        }
        _enterPhase(_Phase.pull);

      case 'ext.water':
        _wrongChoice(node.id, _Copy.wrongWater);
      case 'ext.foam':
        _wrongChoice(node.id, _Copy.wrongFoam);
      case 'ext.metal':
        _wrongChoice(node.id, _Copy.wrongMetal);
    }

    notifyListeners();
  }

  void _wrongChoice(String id, String message) {
    _wrongChoices++;
    _record(id, ActionOutcome.incorrect);
    _showFeedback(message);
  }

  @override
  void handleDrag(Offset delta) {
    if (_finished || _phase != _Phase.pull) return;

    _dragAccumulated += delta.distance;
    if (_dragAccumulated > 110) {
      _record('pin.pulled', ActionOutcome.correct);
      _enterPhase(_Phase.aim);
      notifyListeners();
    }
  }

  @override
  void handlePressStart() {
    if (_finished || _phase != _Phase.squeeze) return;
    _pressing = true;
    _sweepMinYaw = null;
    _sweepMaxYaw = null;
    _lastYaw = null;
    _lastSweepDirection = 0;
    notifyListeners();
  }

  @override
  void handlePressEnd() {
    if (_finished) return;
    if (_pressing && _phase == _Phase.squeeze && _fireHealth > 0) {
      _earlyReleases++;
      _showFeedback(_Copy.releasedEarly);
    }
    _pressing = false;
    notifyListeners();
  }

  // ----------------------------------------------------------------- helpers

  void _enterPhase(_Phase phase) {
    _phase = phase;
    _phaseStartedAt = _elapsed;
    _aimHeld = Duration.zero;
  }

  void _record(String targetId, ActionOutcome outcome) {
    _actions.add(ActionRecord(
      stepId: id,
      targetId: targetId,
      outcome: outcome,
      timeToAct: _elapsed - _phaseStartedAt,
      hintsUsed: 0,
    ));
  }

  void _showFeedback(String message) {
    _feedback = message;
    _feedbackUntil = _elapsed + const Duration(seconds: 4);
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
    if (!passed) return 0;

    var score = 100.0;
    // Choosing water or foam for a live electrical panel is the serious error
    // here, so it is weighted well above a technique slip.
    score -= _wrongChoices * 22.0;
    score -= _aimDrifts * 8.0;
    score -= _earlyReleases * 6.0;

    // Efficiency with the agent is the real measure of good technique.
    score += agentFraction * 12;

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
