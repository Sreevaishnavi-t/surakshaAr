import 'dart:math' as math;

import '../../ar/environment/environment_map.dart';
import '../../ar/environment/placement_resolver.dart';
import '../../ar/fx/fire_fx.dart';
import '../../ar/nodes/basic_nodes.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/scene_graph.dart';
import '../../core/theme/app_theme.dart';
import '../catalogue.dart';
import '../engine/scenario.dart';

/// Scenario copy, in English (the source language).
///
/// Held as constants here for Phase 1; Phase 4 lifts them into `app_en.arb` and
/// they become the template the Hindi and Santali translations derive from.
abstract final class _Copy {
  static const brief =
      'A fire has started in the workshop. Look around and find the safe way out.';
  static const findExit = 'Find the fire exit. Look all around you.';
  static const hintLook =
      'Turn around slowly. The fire exit has a green running-man sign.';
  static const hintRealDoor =
      'Turn around slowly. Look for a real doorway around you — the green '
      'running-man sign is on it.';
  static const hintHighlight = 'The green exit is marked for you now. Tap it.';

  static const lockedDoor =
      'That door is chained shut. The nearest door is not always the way out — '
      'check for the green exit sign.';
  static const liftDoor =
      'Never use a lift during a fire. Power can fail and trap you inside, and '
      'the shaft draws smoke upward.';
  static const towardFire =
      'That path leads towards the fire. Move away from the smoke, not into it.';
  static const timeout =
      'Time ran out. In a real fire the smoke would have made the exit '
      'impossible to find.';
}

/// **Fire & Explosion, Act 1 — exit identification.**
///
/// The worker stands in a workshop that is filling with smoke and must find the
/// marked fire exit by physically turning around with the phone.
///
/// The scenario is built around three specific misconceptions that kill people:
///
/// * **The nearest door is the way out.** It is chained shut here, as fire exits
///   routinely are in small industrial units.
/// * **A lift is a fast way down.** It is the classic fatal choice in a fire.
/// * **You can take your time.** Smoke thickens on a clock, and the exit becomes
///   genuinely harder to see as the seconds pass.
class FireAct1ExitScenario extends ArScenario {
  FireAct1ExitScenario({math.Random? random})
      : _random = random ?? math.Random() {
    _build();
  }

  final math.Random _random;

  static const Duration _timeLimit = Duration(seconds: 60);
  static const Duration _firstHintAfter = Duration(seconds: 18);
  static const Duration _secondHintAfter = Duration(seconds: 34);

  /// The exit only counts as found once it has been held in view briefly. Stops
  /// a worker sweeping the phone in a circle and tapping blindly.
  static const Duration _gazeDwellRequired = Duration(milliseconds: 600);

  @override
  String get id => 'm1.act1.exit';

  @override
  SafetyDomain get domain => SafetyDomain.fire;

  final List<SceneNode> _nodes = [];
  final List<ActionRecord> _actions = [];

  late final DoorwayNode _fireExit;
  late final DoorwayNode _lockedDoor;
  late final DoorwayNode _lift;
  late final FireNode _fire;
  late final SmokeColumnNode _smoke;
  late final GroundRingNode _exitRing;

  Duration _elapsed = Duration.zero;
  Duration _gazeOnExit = Duration.zero;
  Duration? _lastFrame;

  int _wrongTaps = 0;
  int _hintsUsed = 0;
  bool _finished = false;
  ScenarioResult? _result;
  String? _feedback;
  Duration _feedbackUntil = Duration.zero;

  /// Bearing of the fire, in degrees from the worker's starting heading.
  late final double _fireBearing;
  late final double _exitBearing;
  late final double _lockedBearing;
  late final double _liftBearing;

  /// True once the exit has been pinned to a doorway detected in the room.
  ///
  /// Drives the prompt: telling a worker to "find the green sign" is honest
  /// when the sign is on a real door and misleading when it is floating in the
  /// middle of the room because no door was found.
  bool _exitAnchoredToRealDoor = false;

  @override
  List<SceneNode> get nodes => _nodes;

  /// Re-places the act onto the room the worker is actually standing in.
  ///
  /// The bearings chosen in [_build] were always a fallback. Once the scan has
  /// found real doorways and real open floor, the exit belongs on an actual
  /// door and the fire on actual clear ground — because the skill being drilled
  /// is finding the way out of *this* room, and a green sign hanging in mid-air
  /// teaches a worker to look for something that will not be there.
  ///
  /// The decoys matter as much as the exit. A locked door and a lift are only
  /// meaningful as traps if they sit somewhere a worker would plausibly try, so
  /// they are placed on other detected doorways where any exist.
  @override
  void applyEnvironment(EnvironmentMap map, ArCamera camera) {
    // Floor first, and unconditionally. Anchoring to a doorway is a bonus that
    // needs a decent scan; standing on the right floor is not, and returning
    // early on a thin scan used to skip both.
    super.applyEnvironment(map, camera);

    if (!map.isUsable) return;

    const resolver = PlacementResolver();

    // Exits first, deliberately. A drill with the fire in the right place and
    // the exit in the wrong one is worse than the reverse.
    final resolved = resolver.resolveAll(
      map: map,
      requests: [
        PlacementRequest(
          id: 'exit.correct',
          kind: PlacementKind.exit,
          preferredBearingRadians: _worldBearing(camera, _exitBearing),
          preferredDistanceMetres: 7,
        ),
        PlacementRequest(
          id: 'exit.locked',
          kind: PlacementKind.exit,
          preferredBearingRadians: _worldBearing(camera, _lockedBearing),
          preferredDistanceMetres: 4.4,
        ),
        PlacementRequest(
          id: 'exit.lift',
          kind: PlacementKind.exit,
          preferredBearingRadians: _worldBearing(camera, _liftBearing),
          preferredDistanceMetres: 6.1,
        ),
        PlacementRequest(
          id: 'fire',
          kind: PlacementKind.hazard,
          preferredBearingRadians: _worldBearing(camera, _fireBearing),
          preferredDistanceMetres: 5.2,
          minDistanceMetres: 2.5,
        ),
      ],
    );

    for (final placement in resolved) {
      // Back into scene space, so the existing node pipeline is untouched.
      final scene = camera.scenePointOf(placement.worldPosition);
      switch (placement.id) {
        case 'exit.correct':
          _fireExit.position.setFrom(scene);
          _exitRing.position.setFrom(scene);
          _exitAnchoredToRealDoor =
              placement.anchor == PlacementAnchor.detectedDoor;
        case 'exit.locked':
          _lockedDoor.position.setFrom(scene);
        case 'exit.lift':
          _lift.position.setFrom(scene);
        case 'fire':
          _fire.position.setFrom(scene);
          // Smoke rises from the fire, so it follows rather than being placed.
          _smoke.position
            ..setFrom(scene)
            ..z += 0.7;
      }
    }

    notifyListeners();
  }

  /// Converts an authored scene-space bearing into a world-frame one.
  ///
  /// Scenario bearings are relative to wherever the worker was facing at the
  /// start; the environment map is in world space. Without this the hint would
  /// be interpreted against the wrong zero and the resolver would prefer
  /// features in an arbitrary direction.
  double _worldBearing(ArCamera camera, double sceneBearingDegrees) {
    final scenePoint = scenePlacement(
      bearingDegrees: sceneBearingDegrees,
      distanceMetres: 1,
    );
    final world = camera.worldPointOf(scenePoint);
    return math.atan2(world.y, world.x);
  }

  void _build() {
    // Layout is randomised per attempt within sensible bounds. Two workers
    // sharing a phone should not be able to coach each other with "it's the one
    // on the left", and a repeat attempt should not be muscle memory.
    final mirror = _random.nextBool() ? 1.0 : -1.0;
    final jitter = (_random.nextDouble() - 0.5) * 24;

    _fireBearing = (28 + jitter) * mirror;
    _exitBearing = (-118 + jitter * 0.6) * mirror;
    _lockedBearing = (-38 + jitter * 0.4) * mirror;
    _liftBearing = (96 + jitter * 0.5) * mirror;

    final floor = floorZ;

    _fire = FireNode(
      id: 'fire',
      position: scenePlacement(
        bearingDegrees: _fireBearing,
        distanceMetres: 5.2,
        heightMetres: floor,
      ),
      heightMetres: 1.35,
      widthMetres: 1.0,
      intensity: 1.0,
    );

    _smoke = SmokeColumnNode(
      id: 'smoke',
      position: _fire.position.clone()..z += 0.7,
      density: 0.9,
    );

    _fireExit = SafetyNodes.fireExit(
      id: 'exit.correct',
      position: scenePlacement(
        bearingDegrees: _exitBearing,
        distanceMetres: 7.0,
        heightMetres: floor,
      ),
    );

    _exitRing = GroundRingNode(
      id: 'exit.ring',
      position: _fireExit.position.clone(),
      color: AppTheme.safeGreen,
      radiusMetres: 0.75,
      visible: false,
    );

    _lockedDoor = SafetyNodes.lockedDoor(
      id: 'exit.locked',
      position: scenePlacement(
        bearingDegrees: _lockedBearing,
        distanceMetres: 4.4,
        heightMetres: floor,
      ),
    );

    _lift = SafetyNodes.lift(
      id: 'exit.lift',
      position: scenePlacement(
        bearingDegrees: _liftBearing,
        distanceMetres: 6.1,
        heightMetres: floor,
      ),
    );

    _nodes.addAll([_smoke, _fire, _exitRing, _fireExit, _lockedDoor, _lift]);
  }

  // ------------------------------------------------------------------ prompt

  @override
  ScenarioPrompt get prompt {
    final remaining = _timeLimit - _elapsed;

    if (_feedback != null && _elapsed < _feedbackUntil) {
      return ScenarioPrompt(
        text: _feedback!,
        signal: SafetySignal.caution,
        remaining: remaining.isNegative ? Duration.zero : remaining,
      );
    }

    String? hint;
    if (_elapsed >= _secondHintAfter) {
      hint = _Copy.hintHighlight;
    } else if (_elapsed >= _firstHintAfter) {
      // Only promise a real door when there is one. Telling a worker to look
      // for a doorway that the app has hung in mid-air trains them to look for
      // something that will not be there in the real workshop.
      hint = _exitAnchoredToRealDoor ? _Copy.hintRealDoor : _Copy.hintLook;
    }

    return ScenarioPrompt(
      text: _elapsed < const Duration(seconds: 4) ? _Copy.brief : _Copy.findExit,
      signal: SafetySignal.danger,
      hint: hint,
      narrationKey: 'm1.act1.find_exit',
      remaining: remaining.isNegative ? Duration.zero : remaining,
    );
  }

  /// Smoke thickens on a clock. This is the pressure that makes the act a drill
  /// rather than a quiz: hesitating has a visible, worsening cost.
  @override
  double get hazeDensity {
    final t = _elapsed.inMilliseconds / _timeLimit.inMilliseconds;
    return (t * 0.82).clamp(0.0, 0.82);
  }

  // ------------------------------------------------------------------ update

  @override
  void update(Duration elapsed, ArCamera camera) {
    if (_finished) return;

    final delta = _lastFrame == null ? Duration.zero : elapsed - _lastFrame!;
    _lastFrame = elapsed;
    _elapsed = elapsed;

    // The fire grows as the worker dithers, and so does the smoke it feeds.
    final growth = 1.0 + (_elapsed.inMilliseconds / _timeLimit.inMilliseconds) * 0.7;
    _fire.intensity = growth;
    _smoke.density = (0.9 * growth).clamp(0.0, 1.6);

    // Escalating hint: after long enough, physically mark the exit rather than
    // leaving a stuck worker to fail. Being unable to finish teaches nothing.
    if (_elapsed >= _secondHintAfter && !_exitRing.visible) {
      _exitRing.visible = true;
      _fireExit.highlight = true;
      _hintsUsed = 2;
    } else if (_elapsed >= _firstHintAfter && _hintsUsed == 0) {
      _hintsUsed = 1;
    }

    _trackGaze(camera, delta);

    if (_elapsed >= _timeLimit) {
      _finish(passed: false, reason: _Copy.timeout);
      return;
    }

    notifyListeners();
  }

  /// Counts how long the exit has been held near the centre of view.
  ///
  /// Gaze dwell is what makes this a *looking* task. Without it the worker could
  /// spin the phone and tap wherever a green shape flickered past, which trains
  /// the wrong reflex entirely.
  void _trackGaze(ArCamera camera, Duration delta) {
    const gazeCone = 0.30; // radians, roughly 17 degrees off-axis
    if (camera.angleTo(_fireExit.position) < gazeCone) {
      _gazeOnExit += delta;
    } else {
      _gazeOnExit = Duration.zero;
    }
  }

  bool get _exitIsHeldInView => _gazeOnExit >= _gazeDwellRequired;

  // -------------------------------------------------------------------- taps

  @override
  void handleTap(SceneNode node) {
    if (_finished) return;

    switch (node.id) {
      case 'exit.correct':
        if (!_exitIsHeldInView) {
          // Seen but not actually looked at. Nudge rather than penalise: this is
          // a UI subtlety, not a safety error.
          _showFeedback('Hold the exit in view for a moment, then tap it.');
          return;
        }
        _record('exit.correct', ActionOutcome.correct);
        _finish(passed: true, reason: null);

      case 'exit.locked':
        _wrongTaps++;
        _record('exit.locked', ActionOutcome.incorrect);
        _showFeedback(_Copy.lockedDoor);

      case 'exit.lift':
        _wrongTaps++;
        // Weighted heavier than the locked door: choosing a lift is an active
        // decision that gets people killed, not a misread sign.
        _wrongTaps++;
        _record('exit.lift', ActionOutcome.incorrect);
        _showFeedback(_Copy.liftDoor);

      case 'fire':
      case 'smoke':
        _wrongTaps++;
        _record(node.id, ActionOutcome.incorrect);
        _showFeedback(_Copy.towardFire);
    }

    notifyListeners();
  }

  void _record(String targetId, ActionOutcome outcome) {
    _actions.add(ActionRecord(
      stepId: id,
      targetId: targetId,
      outcome: outcome,
      timeToAct: _elapsed,
      hintsUsed: _hintsUsed,
    ));
  }

  void _showFeedback(String message) {
    _feedback = message;
    _feedbackUntil = _elapsed + const Duration(seconds: 4);
  }

  // ------------------------------------------------------------------ finish

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

  /// Behavioural score, 0..100.
  ///
  /// Deliberately not just pass/fail. A worker who found the exit in eight
  /// seconds with no wrong turns has demonstrated something different from one
  /// who needed both hints and tried the lift first, and the certificate should
  /// be able to say so.
  double _score({required bool passed}) {
    if (!passed) return 0;

    var score = 100.0;
    score -= _wrongTaps * 18.0;
    score -= _hintsUsed * 9.0;

    // Speed bonus, tapering to nothing at 25 seconds. Modest on purpose:
    // rewarding haste too heavily would teach the wrong lesson.
    final seconds = _elapsed.inMilliseconds / 1000.0;
    if (seconds < 25) {
      score += (1 - seconds / 25) * 10;
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
