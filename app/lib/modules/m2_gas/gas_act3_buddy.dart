import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, IconData, Icons;

import '../../ar/nodes/basic_nodes.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/scene_graph.dart';
import '../../core/theme/app_theme.dart';
import '../catalogue.dart';
import '../engine/scenario.dart';

enum _Phase { permit, working, emergency, done }

class _PermitCheck {
  const _PermitCheck({
    required this.id,
    required this.icon,
    required this.label,
    required this.rationale,
  });

  final String id;
  final IconData icon;
  final String label;
  final String rationale;
}

abstract final class _Copy {
  static const brief =
      'You are the entrant. Before you go in, complete the permit checks — tap '
      'each one you have confirmed.';
  static const permitPrompt = 'Which checks have you completed?';
  static const permitIncomplete =
      'Not all checks are done. Entering on an incomplete permit is how most '
      'confined-space incidents begin.';

  static const working =
      'Permit complete. You are inside and working. Stay alert.';

  static const emergency =
      'YOUR BUDDY HAS COLLAPSED INSIDE THE TANK.\n\nWhat do you do?';

  static const fatalEntry =
      'You went in after them.\n\n'
      'Whatever brought your buddy down was still in there, and it took you '
      'too. Both of you are now casualties, and the rescue team has two people '
      'to recover instead of one.\n\n'
      'A large share of everyone who dies in a confined space is a would-be '
      'rescuer. This is the single most important rule in this module: never '
      'enter to rescue. Raise the alarm and let the trained team enter with '
      'breathing apparatus.';

  static const fatalBreathHold =
      'You went in holding your breath.\n\n'
      'In an oxygen-deficient atmosphere you lose consciousness in seconds, and '
      'you get no warning first — there is no choking, no smell, no chance to '
      'turn back. You collapsed beside your buddy.';

  static const wrongRetrieve =
      'Pulling on the line is right, but not first and not alone. Raise the '
      'alarm so the trained team is already on its way while you work.';

  static const success =
      'Correct. Alarm raised, rescue team called, and you recovered your buddy '
      'from outside using the retrieval line — without becoming a second '
      'casualty.';

  static const timeout =
      'Too slow. In an oxygen-deficient atmosphere, minutes matter.';
}

/// **Gas Leak & Confined Space, Act 3 — permit discipline and the buddy system.**
///
/// The act builds a routine — permit checks, a period of ordinary work — and
/// then breaks it: the buddy collapses inside the tank.
///
/// The instinct to go in after a colleague is overwhelming, human, and the
/// reason a large share of confined-space fatalities are would-be rescuers who
/// went in without breathing apparatus. Telling someone that fact in a
/// classroom does not survive the moment. Making them make the choice, and then
/// showing them the outcome in the second person, is the only version of this
/// lesson with a chance of holding.
///
/// So both "go in and pull them out" and "go in holding your breath" end the
/// act immediately with an explicit consequence. The correct answer — stay out,
/// raise the alarm, use the retrieval line from outside — is deliberately the
/// least satisfying-looking option on the board.
class GasAct3BuddyScenario extends ArScenario {
  GasAct3BuddyScenario({math.Random? random})
      : _random = random ?? math.Random() {
    _build();
  }

  final math.Random _random;

  static const Duration _timeLimit = Duration(seconds: 150);

  /// How long the "ordinary work" lull runs before the emergency. Long enough
  /// for the worker to settle, short enough not to bore them.
  static const Duration _lullDuration = Duration(seconds: 12);

  /// The emergency is deliberately tighter than the rest of the act.
  static const Duration _emergencyLimit = Duration(seconds: 25);

  static const List<_PermitCheck> _checks = [
    _PermitCheck(
      id: 'permit.isolation',
      icon: Icons.block,
      label: 'Line blanked and isolated',
      rationale:
          'A physical blank or disconnection. A closed valve can be opened by '
          'mistake, and valves leak.',
    ),
    _PermitCheck(
      id: 'permit.test',
      icon: Icons.sensors,
      label: 'Atmosphere tested',
      rationale: 'Oxygen, flammables and toxics tested before anyone enters.',
    ),
    _PermitCheck(
      id: 'permit.attendant',
      icon: Icons.visibility,
      label: 'Attendant posted outside',
      rationale:
          'The attendant stays out. Their job is to watch, keep count and raise '
          'the alarm — never to enter.',
    ),
    _PermitCheck(
      id: 'permit.rescue',
      icon: Icons.medical_services_outlined,
      label: 'Rescue plan and equipment ready',
      rationale:
          'Retrieval line, tripod and breathing apparatus staged before entry, '
          'not fetched afterwards.',
    ),
    _PermitCheck(
      id: 'permit.comms',
      icon: Icons.record_voice_over,
      label: 'Communication checked',
      rationale:
          'An agreed signal between entrant and attendant, tested before you go '
          'in.',
    ),
  ];

  @override
  String get id => 'm2.act3.buddy';

  @override
  SafetyDomain get domain => SafetyDomain.gas;

  final List<SceneNode> _nodes = [];
  final List<ActionRecord> _actions = [];
  final List<BillboardNode> _checkNodes = [];
  final List<BillboardNode> _responseNodes = [];
  final Map<String, _PermitCheck> _checksById = {};
  final Set<String> _confirmed = {};

  _Phase _phase = _Phase.permit;
  Duration _elapsed = Duration.zero;
  Duration _phaseStartedAt = Duration.zero;
  int _mistakes = 0;
  bool _finished = false;
  ScenarioResult? _result;
  String? _feedback;
  Duration _feedbackUntil = Duration.zero;

  @override
  List<SceneNode> get nodes => _nodes;

  _Phase get phase => _phase;

  Set<String> get confirmed => _confirmed;

  bool get allChecksConfirmed => _confirmed.length == _checks.length;

  /// Countdown during the emergency, for the HUD.
  Duration? get emergencyRemaining {
    if (_phase != _Phase.emergency) return null;
    final left = _emergencyLimit - (_elapsed - _phaseStartedAt);
    return left.isNegative ? Duration.zero : left;
  }

  void _build() {
    const floor = -kEyeHeightMetres;

    // The tank opening the worker is standing at.
    _nodes.add(BillboardNode(
      id: 'tank',
      position: scenePlacement(
        bearingDegrees: 0,
        distanceMetres: 3.2,
        heightMetres: floor + 0.3,
      ),
      icon: Icons.circle_outlined,
      color: const Color(0xFF546E7A),
      label: 'Tank entry',
      sizeMetres: 1.1,
      interactive: false,
      sortBias: -0.1,
    ));

    final shuffled = List<_PermitCheck>.from(_checks)..shuffle(_random);
    for (var i = 0; i < shuffled.length; i++) {
      final check = shuffled[i];
      _checksById[check.id] = check;

      final node = BillboardNode(
        id: check.id,
        position: scenePlacement(
          bearingDegrees: -50.0 + i * 25.0,
          distanceMetres: 2.7,
          heightMetres: floor + 1.5,
        ),
        icon: check.icon,
        color: const Color(0xFF78909C),
        label: check.label,
        sizeMetres: 0.5,
      );

      _checkNodes.add(node);
      _nodes.add(node);
    }

    _buildResponses(floor);
  }

  /// The four responses to the collapse.
  ///
  /// Positions are shuffled so the correct one is never in a fixed place — and
  /// so a worker who has done the drill before cannot pass on muscle memory.
  void _buildResponses(double floor) {
    final options = <({String id, IconData icon, String label})>[
      (
        id: 'rescue.alarm',
        icon: Icons.campaign,
        label: 'Raise the alarm, call rescue'
      ),
      (id: 'rescue.enter', icon: Icons.login, label: 'Go in and pull them out'),
      (
        id: 'rescue.breath',
        icon: Icons.air,
        label: 'Go in holding your breath'
      ),
      (
        id: 'rescue.line',
        icon: Icons.linear_scale,
        label: 'Pull the retrieval line'
      ),
    ]..shuffle(_random);

    for (var i = 0; i < options.length; i++) {
      final option = options[i];
      final node = BillboardNode(
        id: option.id,
        position: scenePlacement(
          bearingDegrees: -36.0 + i * 24.0,
          distanceMetres: 2.6,
          heightMetres: floor + 1.2,
        ),
        icon: option.icon,
        color: AppTheme.hazardRed,
        label: option.label,
        sizeMetres: 0.56,
        visible: false,
      );

      _responseNodes.add(node);
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

    return switch (_phase) {
      _Phase.permit => ScenarioPrompt(
          text: _elapsed < const Duration(seconds: 6)
              ? _Copy.brief
              : _Copy.permitPrompt,
          signal: SafetySignal.caution,
          narrationKey: 'm2.act3.permit',
          remaining: clamped,
        ),
      _Phase.working => ScenarioPrompt(
          text: _Copy.working,
          signal: SafetySignal.safe,
          remaining: clamped,
        ),
      _Phase.emergency => ScenarioPrompt(
          text: _Copy.emergency,
          signal: SafetySignal.danger,
          narrationKey: 'm2.act3.emergency',
          remaining: emergencyRemaining,
        ),
      _Phase.done => ScenarioPrompt(
          text: _Copy.success,
          signal: SafetySignal.safe,
          remaining: clamped,
        ),
    };
  }

  @override
  void update(Duration elapsed, ArCamera camera) {
    if (_finished) return;
    _elapsed = elapsed;

    if (_phase == _Phase.working &&
        _elapsed - _phaseStartedAt >= _lullDuration) {
      _enterPhase(_Phase.emergency);
      for (final node in _responseNodes) {
        node.visible = true;
      }
      for (final node in _checkNodes) {
        node.visible = false;
      }
    }

    if (_phase == _Phase.emergency &&
        _elapsed - _phaseStartedAt >= _emergencyLimit) {
      _finish(
        passed: false,
        reason: 'You froze. Your buddy was not recovered in time.\n\n'
            'Hesitating is understandable, and it is also fatal. The response '
            'has to be automatic: raise the alarm, then work from outside.',
      );
      return;
    }

    if (_elapsed >= _timeLimit) {
      _finish(passed: false, reason: _Copy.timeout);
      return;
    }

    notifyListeners();
  }

  @override
  void handleTap(SceneNode node) {
    if (_finished) return;

    switch (_phase) {
      case _Phase.permit:
        _handlePermitTap(node);
      case _Phase.emergency:
        _handleEmergencyTap(node);
      case _Phase.working:
      case _Phase.done:
        break;
    }

    notifyListeners();
  }

  void _handlePermitTap(SceneNode node) {
    final check = _checksById[node.id];
    if (check == null) return;

    final index = _checkNodes.indexWhere((n) => n.id == check.id);
    if (_confirmed.remove(check.id)) {
      if (index >= 0) _checkNodes[index].color = const Color(0xFF78909C);
    } else {
      _confirmed.add(check.id);
      if (index >= 0) _checkNodes[index].color = AppTheme.safeGreen;
      _showFeedback(check.rationale);
    }
  }

  /// Confirms the permit and enters the space. Driven from the HUD.
  void confirmPermit() {
    if (_finished || _phase != _Phase.permit) return;

    if (!allChecksConfirmed) {
      _mistakes++;
      _record('permit.incomplete', ActionOutcome.incorrect);
      _showFeedback(_Copy.permitIncomplete);
      notifyListeners();
      return;
    }

    _record('permit.complete', ActionOutcome.correct);
    _enterPhase(_Phase.working);
    notifyListeners();
  }

  void _handleEmergencyTap(SceneNode node) {
    switch (node.id) {
      case 'rescue.alarm':
        _record(node.id, ActionOutcome.correct);
        _enterPhase(_Phase.done);
        _finish(passed: true, reason: null);

      case 'rescue.enter':
        _record(node.id, ActionOutcome.fatal);
        _finish(passed: false, reason: _Copy.fatalEntry);

      case 'rescue.breath':
        _record(node.id, ActionOutcome.fatal);
        _finish(passed: false, reason: _Copy.fatalBreathHold);

      case 'rescue.line':
        // Not wrong, just out of order — so it costs points and redirects
        // rather than ending the act.
        _mistakes++;
        _record(node.id, ActionOutcome.incorrect);
        _showFeedback(_Copy.wrongRetrieve);
    }
  }

  void _enterPhase(_Phase phase) {
    _phase = phase;
    _phaseStartedAt = _elapsed;
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
    _feedbackUntil = _elapsed + const Duration(seconds: 5);
  }

  void _finish({required bool passed, required String? reason}) {
    if (_finished) return;
    _finished = true;

    _result = ScenarioResult(
      scenarioId: id,
      domain: domain,
      passed: passed,
      behaviouralScore: passed ? _score() : 0,
      actions: List.unmodifiable(_actions),
      duration: _elapsed,
      fatalReason: reason,
    );

    notifyListeners();
  }

  double _score() {
    var score = 100.0;
    score -= _mistakes * 12.0;

    // Reaction time in the emergency is the thing being measured. A worker who
    // answered in three seconds has internalised the rule; one who took twenty
    // was reasoning it out, which is not the same competence.
    final reaction = _actions
        .where((a) => a.targetId.startsWith('rescue.'))
        .map((a) => a.timeToAct)
        .firstOrNull;
    if (reaction != null && reaction < const Duration(seconds: 8)) {
      score += 8;
    }

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
