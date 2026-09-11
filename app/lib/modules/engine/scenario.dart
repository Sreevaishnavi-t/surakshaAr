import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../../ar/environment/environment_map.dart';
import '../../ar/environment/ground_plane.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/scene_graph.dart';
import '../../core/theme/app_theme.dart';
import '../catalogue.dart';

/// One instruction shown to the worker.
///
/// Always carries a [narrationKey] alongside the text. Audio is not an
/// accessibility afterthought in this app: a large share of the target users
/// read slowly or not at all, and a text-only prompt fails them completely.
class ScenarioPrompt {
  const ScenarioPrompt({
    required this.text,
    required this.signal,
    this.hint,
    this.narrationKey,
    this.remaining,
  });

  final String text;
  final SafetySignal signal;

  /// Escalated help, revealed after the worker has been stuck for a while.
  final String? hint;

  /// Identifier for the bundled narration clip.
  final String? narrationKey;

  /// Time left, when the step is under a countdown.
  final Duration? remaining;
}

/// What a single scored action produced.
enum ActionOutcome {
  correct,

  /// Wrong but recoverable. Costs points and usually worsens the hazard.
  incorrect,

  /// Wrong in a way that would kill the worker or a colleague. Ends the act and
  /// shows the consequence explicitly, because a near-miss the trainee walks
  /// away from teaches far less than seeing the outcome.
  fatal,
}

/// One recorded interaction. This is the raw material for behavioural scoring —
/// the part that lets a certificate attest to what a worker *did* rather than
/// that they sat through a session.
class ActionRecord {
  const ActionRecord({
    required this.stepId,
    required this.targetId,
    required this.outcome,
    required this.timeToAct,
    required this.hintsUsed,
  });

  final String stepId;
  final String targetId;
  final ActionOutcome outcome;

  /// How long the worker took from the prompt appearing to acting. Reaction time
  /// under pressure is a genuine competence signal, not padding.
  final Duration timeToAct;

  final int hintsUsed;

  Map<String, Object?> toJson() => {
        'stepId': stepId,
        'targetId': targetId,
        'outcome': outcome.name,
        'timeToActMs': timeToAct.inMilliseconds,
        'hintsUsed': hintsUsed,
      };
}

/// Outcome of a completed act.
class ScenarioResult {
  const ScenarioResult({
    required this.scenarioId,
    required this.domain,
    required this.passed,
    required this.behaviouralScore,
    required this.actions,
    required this.duration,
    this.fatalReason,
  });

  final String scenarioId;
  final SafetyDomain domain;
  final bool passed;

  /// 0..100. Feeds the 40% behavioural share of the certificate composite.
  final double behaviouralScore;

  final List<ActionRecord> actions;
  final Duration duration;

  /// Set when the act ended in a fatal action. Shown verbatim to the worker.
  final String? fatalReason;

  Map<String, Object?> toJson() => {
        'scenarioId': scenarioId,
        'domain': domain.code,
        'passed': passed,
        'behaviouralScore': behaviouralScore,
        'durationMs': duration.inMilliseconds,
        'fatalReason': fatalReason,
        'actions': actions.map((a) => a.toJson()).toList(),
      };
}

/// A playable AR act.
///
/// Implementations own their own scene graph and step logic. The session screen
/// only pumps [update] once per frame, forwards taps, and renders whatever
/// [nodes] currently contains — it knows nothing about fire or gas specifically.
abstract class ArScenario extends ChangeNotifier {
  String get id;

  SafetyDomain get domain;

  /// Live scene contents. Implementations may mutate this list between frames.
  List<SceneNode> get nodes;

  /// Scene-space Z of the floor: negative, because the camera is the origin and
  /// the floor is below it.
  ///
  /// Starts at the assumed standing eye height and is corrected by
  /// [snapToFloor] once the room has been measured. Scenarios must read this
  /// rather than hardcode a height, so that one number governs the floor for
  /// content, for the simulated gallery and for the door detector alike.
  double _floorZ = -GroundPlane.assumed.cameraHeightMetres;

  /// Where the floor currently is. Implementations place content against this.
  @protected
  double get floorZ => _floorZ;

  /// Current instruction.
  ScenarioPrompt get prompt;

  /// Screen-space smoke or dust overlay, 0..1.
  double get hazeDensity => 0;

  /// Called once per rendered frame with the scene clock and current camera.
  ///
  /// The camera is passed rather than stored so scenarios can score gaze and aim
  /// — looking at the base of a fire, holding a gaze on an exit long enough to
  /// count as having found it.
  void update(Duration elapsed, ArCamera camera);

  /// A scene node was tapped.
  void handleTap(SceneNode node);

  /// A tap that hit nothing. Some steps score this (jabbing at random costs
  /// points), most ignore it.
  void handleEmptyTap() {}

  /// A drag across the screen. Used for the "pull the pin" gesture, which is a
  /// physical action in reality and should be a physical action here rather
  /// than a button labelled "pull".
  void handleDrag(Offset delta) {}

  /// The worker pressed and held. Used for squeezing an extinguisher handle:
  /// discharge continues only while held, which is what makes running out of
  /// agent a real consequence of poor aim.
  void handlePressStart() {}

  void handlePressEnd() {}

  bool get isFinished;

  /// Non-null once [isFinished] is true.
  ScenarioResult? get result;

  /// Offers the scenario what has been learned about the worker's real
  /// surroundings, once, before the drill starts.
  ///
  /// This is where content stops being decorative and starts being about the
  /// room the worker is standing in. An implementation should move its nodes
  /// onto real detected features — the exit onto an actual doorway, the fire
  /// onto actual open floor — rather than the authored bearings it was built
  /// with, which were only ever a fallback for a room nobody had looked at.
  ///
  /// The default is to put everything on the floor that was actually measured.
  ///
  /// That default is not a no-op, and deliberately so. Scenarios author their
  /// content against an *assumed* floor, because they are built before the room
  /// has been looked at. Leaving them there meant content sat at a height
  /// nobody had checked — visibly floating, or sunk into the ground — in every
  /// act that did not override this method, which until now was seven of the
  /// eight.
  ///
  /// Overriding implementations should call `super.applyEnvironment` first and
  /// then move individual nodes onto detected features, so they inherit the
  /// floor correction rather than reimplementing it.
  void applyEnvironment(EnvironmentMap map, ArCamera camera) {
    snapToFloor(map.ground);
  }

  /// Shifts every node so the authored floor lands on the measured one.
  ///
  /// A single uniform delta rather than an absolute assignment, which is the
  /// whole trick: it preserves each node's height *above* the floor. An
  /// extinguisher bracketed 0.45 m up a wall and a smoke column starting 0.7 m
  /// above a fire stay where the author put them relative to the ground, with
  /// no per-node metadata to record and keep in sync.
  @protected
  void snapToFloor(GroundPlane ground) {
    final measured = -ground.cameraHeightMetres;
    final delta = measured - _floorZ;
    if (delta.abs() < 1e-6) return;

    for (final node in nodes) {
      node.position.z += delta;
    }
    _floorZ = measured;
  }

  /// Called when the worker abandons the act. Implementations should record it
  /// rather than silently discarding progress.
  void abandon() {}
}
