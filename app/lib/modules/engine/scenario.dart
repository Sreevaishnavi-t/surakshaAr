import 'package:flutter/foundation.dart';

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

  bool get isFinished;

  /// Non-null once [isFinished] is true.
  ScenarioResult? get result;

  /// Called when the worker abandons the act. Implementations should record it
  /// rather than silently discarding progress.
  void abandon() {}
}
