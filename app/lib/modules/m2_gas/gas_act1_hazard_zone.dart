import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, Icons;
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../../ar/fx/gas_fx.dart';
import '../../ar/nodes/basic_nodes.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/scene_graph.dart';
import '../../core/theme/app_theme.dart';
import '../catalogue.dart';
import '../engine/scenario.dart';

enum _Phase { survey, identifySource, chooseApproach, done }

abstract final class _Copy {
  static const brief =
      'Gas has been reported near the pump house. Sweep the area with your '
      'detector before you go anywhere near it.';
  static const survey =
      'Turn slowly and point the phone around you. The reading changes with '
      'where you point.';
  static const surveyProgress =
      'Keep sweeping. You have not covered the whole area yet.';
  static const identifySource =
      'You have mapped the area. Point at where the gas is strongest and tap to '
      'mark the source.';
  static const wrongSource =
      'That is not the strongest reading. Watch the meter as you turn — the '
      'source is where methane peaks.';
  static const chooseApproach =
      'Now find your approach. Check the windsock, then tap the direction you '
      'would approach from.';
  static const approachDownwind =
      'That is downwind. The gas would blow straight over you. Look at the '
      'windsock again.';
  static const approachThroughCloud =
      'That route takes you through the cloud itself, and through the explosive '
      'range on the way.';
  static const success =
      'Correct. Approach from upwind, staying out of the explosive range.';
  static const timeout =
      'Too long. A release does not wait, and the cloud has spread past the '
      'point where an approach is safe.';
}

/// **Gas Leak & Confined Space, Act 1 — hazard zone recognition.**
///
/// The phone becomes a four-gas detector that the worker physically points
/// around them. Readings vary with where the device is aimed, so the only way
/// to map the hazard is to turn and sweep — which is exactly the procedure with
/// a real detector, and a genuinely good fit for rotation-tracked AR.
///
/// The scenario teaches three things that recur in gas fatalities:
///
/// * **The gas is invisible.** It is drawn as barely more than a shimmer. The
///   meter, not the eye, is what finds it.
/// * **A high reading is not a safe reading.** Above 15% methane the mixture is
///   too rich to burn, and workers have taken that as an all-clear. It becomes
///   explosive the moment it mixes with fresh air.
/// * **Approach is upwind, always.** The windsock is in the scene rather than
///   the instructions, so the worker has to look for it.
///
/// Note the honest constraint: this engine tracks rotation, not position, so
/// the worker aims rather than walks. The act is written around that rather
/// than pretending to positional tracking it does not have.
class GasAct1HazardZoneScenario extends ArScenario {
  GasAct1HazardZoneScenario({math.Random? random})
      : _random = random ?? math.Random() {
    _build();
  }

  final math.Random _random;

  static const Duration _timeLimit = Duration(seconds: 120);

  /// How much of the horizon must be swept before the survey counts as done.
  /// Twelve of sixteen sectors — enough to require a real turn, forgiving of
  /// the sector directly behind the worker.
  static const int _sectorCount = 16;
  static const int _sectorsRequired = 12;

  @override
  String get id => 'm2.act1.hazard_zone';

  @override
  SafetyDomain get domain => SafetyDomain.gas;

  final List<SceneNode> _nodes = [];
  final List<ActionRecord> _actions = [];
  final Set<int> _sweptSectors = {};

  late final GasCloudNode _cloud;
  late final WindsockNode _windsock;
  late final BillboardNode _sourceMarker;
  late final Vector3 _sourcePosition;

  /// Bearing the wind blows *towards*, in radians, scene space.
  late final double _windBearing;

  final List<BillboardNode> _approachOptions = [];

  _Phase _phase = _Phase.survey;
  Duration _elapsed = Duration.zero;
  Duration _phaseStartedAt = Duration.zero;

  GasReading _reading = const GasReading(
    methanePercent: 0,
    oxygenPercent: 20.9,
    carbonMonoxidePpm: 0,
  );

  double _peakMethaneSeen = 0;
  int _mistakes = 0;
  bool _finished = false;
  ScenarioResult? _result;
  String? _feedback;
  Duration _feedbackUntil = Duration.zero;

  @override
  List<SceneNode> get nodes => _nodes;

  /// Live detector readings, for the HUD.
  GasReading get reading => _reading;

  double get surveyProgress =>
      (_sweptSectors.length / _sectorsRequired).clamp(0.0, 1.0);

  _Phase get phase => _phase;

  void _build() {
    final floor = floorZ;
    final mirror = _random.nextBool() ? 1.0 : -1.0;
    final sourceBearing = (55 + (_random.nextDouble() - 0.5) * 50) * mirror;

    _sourcePosition = scenePlacement(
      bearingDegrees: sourceBearing,
      distanceMetres: 8.0,
      heightMetres: floor + 0.4,
    );

    // Wind blows across the source rather than along the worker's line of
    // sight, so upwind and "away from the gas" are genuinely different answers.
    _windBearing = (sourceBearing + 90) * math.pi / 180.0;

    _cloud = GasCloudNode(
      id: 'cloud',
      position: _sourcePosition.clone(),
      radiusMetres: 3.6,
      concentration: 0.9,
    );

    _windsock = WindsockNode(
      id: 'windsock',
      position: scenePlacement(
        bearingDegrees: -20 * mirror,
        distanceMetres: 9.0,
        heightMetres: floor,
      ),
      windBearingRadians: _windBearing,
    );

    // A valve at the source, revealed only once the worker identifies it.
    _sourceMarker = BillboardNode(
      id: 'source',
      position: _sourcePosition.clone(),
      icon: Icons.dangerous,
      color: AppTheme.hazardRed,
      sizeMetres: 0.7,
      visible: false,
      interactive: false,
    );

    _nodes.addAll([_cloud, _windsock, _sourceMarker]);
    _buildApproachOptions(sourceBearing, mirror);
  }

  /// Four candidate approach directions, only one of them upwind and clear.
  void _buildApproachOptions(double sourceBearing, double mirror) {
    final floor = floorZ;

    // Upwind means facing into the wind: the wind blows towards _windBearing,
    // so the safe approach is from the opposite side.
    final upwindBearing = (_windBearing * 180 / math.pi) + 180;

    final options = <({String id, double bearing, String verdict})>[
      (id: 'approach.upwind', bearing: upwindBearing, verdict: 'correct'),
      (
        id: 'approach.downwind',
        bearing: _windBearing * 180 / math.pi,
        verdict: 'downwind'
      ),
      (id: 'approach.through', bearing: sourceBearing, verdict: 'through'),
      (
        id: 'approach.crosswind',
        bearing: sourceBearing + 140 * mirror,
        verdict: 'downwind'
      ),
    ];

    for (final option in options) {
      final node = BillboardNode(
        id: option.id,
        position: scenePlacement(
          bearingDegrees: option.bearing,
          distanceMetres: 4.5,
          heightMetres: floor + 0.9,
        ),
        icon: Icons.directions_walk,
        color: const Color(0xFF42A5F5),
        sizeMetres: 0.55,
        visible: false,
      );
      _approachOptions.add(node);
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
      _Phase.survey => ScenarioPrompt(
          text: _elapsed < const Duration(seconds: 5)
              ? _Copy.brief
              : _Copy.survey,
          signal: SafetySignal.caution,
          hint: surveyProgress > 0.35 && surveyProgress < 1
              ? _Copy.surveyProgress
              : null,
          narrationKey: 'm2.act1.survey',
          remaining: clamped,
        ),
      _Phase.identifySource => ScenarioPrompt(
          text: _Copy.identifySource,
          signal: SafetySignal.danger,
          narrationKey: 'm2.act1.source',
          remaining: clamped,
        ),
      _Phase.chooseApproach => ScenarioPrompt(
          text: _Copy.chooseApproach,
          signal: SafetySignal.danger,
          hint: _elapsed - _phaseStartedAt > const Duration(seconds: 18)
              ? 'The windsock shows which way the air is moving. Approach into '
                  'the wind, so it blows the gas away from you.'
              : null,
          narrationKey: 'm2.act1.approach',
          remaining: clamped,
        ),
      _Phase.done => ScenarioPrompt(
          text: _Copy.success,
          signal: SafetySignal.safe,
          remaining: clamped,
        ),
    };
  }

  // ------------------------------------------------------------------ update

  @override
  void update(Duration elapsed, ArCamera camera) {
    if (_finished) return;
    _elapsed = elapsed;

    _reading = _readingFor(camera);
    _peakMethaneSeen = math.max(_peakMethaneSeen, _reading.methanePercent);

    if (_phase == _Phase.survey) {
      _recordSector(camera.pose.yaw);
      if (_sweptSectors.length >= _sectorsRequired) {
        _enterPhase(_Phase.identifySource);
      }
    }

    // The cloud keeps growing, so hesitation costs ground.
    final growth = _elapsed.inMilliseconds / _timeLimit.inMilliseconds;
    _cloud.concentration = (0.9 + growth * 0.4).clamp(0.0, 1.4);

    if (_elapsed >= _timeLimit) {
      _finish(passed: false, reason: _Copy.timeout);
      return;
    }

    notifyListeners();
  }

  /// Detector reading in whatever direction the phone is currently pointed.
  ///
  /// Concentration falls off with angular distance from the source. This is a
  /// deliberate simplification of a real dispersion model — the pedagogical
  /// point is "the reading depends on where you point, so sweep before you
  /// move", and that survives the simplification intact.
  GasReading _readingFor(ArCamera camera) {
    final angle = camera.angleTo(_sourcePosition);
    // Falls to roughly nothing about 50 degrees off the source.
    final proximity = (1.0 - angle / 0.9).clamp(0.0, 1.0);
    final strength = proximity * proximity;

    // Peaks over-rich at the source, passing through the explosive band on the
    // way in — so a careless sweep reads "safe, safe, EXPLOSIVE, high" and the
    // worker has to notice what they passed through.
    final methane = strength * 22.0;

    // Methane displaces air, so oxygen falls where methane is high.
    final oxygen = 20.9 - strength * 5.2;

    // Incomplete combustion nearby puts some CO in the mix.
    final co = strength * 78;

    return GasReading(
      methanePercent: methane,
      oxygenPercent: oxygen,
      carbonMonoxidePpm: co,
    );
  }

  /// Marks the compass sector the worker is currently facing as surveyed.
  void _recordSector(double yaw) {
    final normalised = (yaw + math.pi) / (2 * math.pi);
    final sector = (normalised * _sectorCount).floor() % _sectorCount;
    _sweptSectors.add(sector);
  }

  // ------------------------------------------------------------------- input

  @override
  void handleTap(SceneNode node) {
    if (_finished) return;

    switch (_phase) {
      case _Phase.identifySource:
        break;
      case _Phase.chooseApproach:
        _handleApproachTap(node);
      case _Phase.survey:
      case _Phase.done:
        break;
    }

    notifyListeners();
  }

  /// During source identification the worker taps anywhere while aiming, so the
  /// judgement is made on where the phone is pointing rather than on hitting a
  /// small target — the source is invisible until found.
  @override
  void handleEmptyTap() {
    if (_finished || _phase != _Phase.identifySource) return;

    // Correct if the current reading is near the peak the worker has seen.
    if (_reading.methanePercent >= _peakMethaneSeen * 0.75 &&
        _reading.methanePercent > GasReading.lowerExplosiveLimit) {
      _record('source.found', ActionOutcome.correct);
      _sourceMarker.visible = true;
      _enterPhase(_Phase.chooseApproach);
      for (final option in _approachOptions) {
        option.visible = true;
      }
    } else {
      _mistakes++;
      _record('source.missed', ActionOutcome.incorrect);
      _showFeedback(_Copy.wrongSource);
    }

    notifyListeners();
  }

  void _handleApproachTap(SceneNode node) {
    switch (node.id) {
      case 'approach.upwind':
        _record(node.id, ActionOutcome.correct);
        _enterPhase(_Phase.done);
        _finish(passed: true, reason: null);
      case 'approach.through':
        _mistakes += 2;
        _record(node.id, ActionOutcome.incorrect);
        _showFeedback(_Copy.approachThroughCloud);
      case 'approach.downwind':
      case 'approach.crosswind':
        _mistakes++;
        _record(node.id, ActionOutcome.incorrect);
        _showFeedback(_Copy.approachDownwind);
    }
  }

  // ----------------------------------------------------------------- helpers

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
      behaviouralScore: _score(passed: passed),
      actions: List.unmodifiable(_actions),
      duration: _elapsed,
      fatalReason: reason,
    );

    notifyListeners();
  }

  double _score({required bool passed}) {
    if (!passed) return (surveyProgress * 30).clamp(0.0, 30.0);

    var score = 100.0;
    score -= _mistakes * 14.0;

    final seconds = _elapsed.inMilliseconds / 1000.0;
    if (seconds < 60) score += (1 - seconds / 60) * 8;

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
