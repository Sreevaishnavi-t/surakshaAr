import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, IconData, Icons;

import '../../ar/fx/gas_fx.dart';
import '../../ar/nodes/basic_nodes.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/scene_graph.dart';
import '../../core/theme/app_theme.dart';
import '../catalogue.dart';
import '../engine/scenario.dart';

/// One item on the kit board.
class _Item {
  const _Item({
    required this.id,
    required this.icon,
    required this.label,
    required this.colour,
    required this.required_,
    required this.verdict,
    this.fatal = false,
  });

  final String id;
  final IconData icon;
  final String label;
  final Color colour;

  /// Whether this item must be taken.
  // ignore: non_constant_identifier_names — `required` is a Dart keyword.
  final bool required_;

  /// Explanation shown when the worker selects or omits it.
  final String verdict;

  /// True for choices that would kill the wearer. Ends the act immediately.
  final bool fatal;
}

abstract final class _Copy {
  static const brief =
      'You are entering a tank. The last reading was 17% oxygen. Choose your '
      'equipment from the board, then confirm.';
  static const prompt = 'Select everything you need, then tap Confirm.';
  static const success =
      'Correct kit. Supplied air, a detector on you, and a harness the '
      'attendant can pull you out by.';
  static const timeout = 'Time ran out before the kit was chosen.';

  static const fatalFilter =
      'You chose a filter respirator for a space with 17% oxygen.\n\n'
      'A filter only cleans the air that is already there. It cannot make '
      'oxygen. You would have lost consciousness within a few breaths and had '
      'no warning beforehand.\n\n'
      'Below 19.5% oxygen you need supplied air: SCBA or an airline set. '
      'Nothing else will do.';
}

/// **Gas Leak & Confined Space, Act 2 — PPE selection.**
///
/// A kit board with the right equipment, the merely useless, and one item that
/// kills.
///
/// The filter respirator is the whole act. It is the single most persistent
/// fatal misconception in confined-space work: it looks like breathing
/// protection, it is breathing protection in other contexts, and in an
/// oxygen-deficient space it does nothing at all while feeling like it works.
/// Choosing it here ends the drill immediately with the consequence spelled
/// out, because a worker who merely loses points will not remember, and this is
/// exactly the lesson that has to survive a week.
class GasAct2PpeScenario extends ArScenario {
  GasAct2PpeScenario({math.Random? random})
      : _random = random ?? math.Random() {
    _build();
  }

  final math.Random _random;

  static const Duration _timeLimit = Duration(seconds: 90);

  static const List<_Item> _catalogue = [
    _Item(
      id: 'ppe.scba',
      icon: Icons.scuba_diving,
      label: 'SCBA set',
      colour: AppTheme.safeGreen,
      required_: true,
      verdict: 'Correct. Supplied air is the only option below 19.5% oxygen.',
    ),
    _Item(
      id: 'ppe.detector',
      icon: Icons.sensors,
      label: 'Personal gas detector',
      colour: AppTheme.safeGreen,
      required_: true,
      verdict:
          'Correct. The atmosphere changes while you work, so monitoring has to '
          'be continuous, not a single test at entry.',
    ),
    _Item(
      id: 'ppe.harness',
      icon: Icons.airline_seat_legroom_extra,
      label: 'Full-body harness and line',
      colour: AppTheme.safeGreen,
      required_: true,
      verdict:
          'Correct. This is how the attendant recovers you without entering '
          'themselves.',
    ),
    _Item(
      id: 'ppe.filter',
      icon: Icons.masks,
      label: 'Filter respirator',
      colour: AppTheme.hazardRed,
      required_: false,
      fatal: true,
      verdict: _Copy.fatalFilter,
    ),
    _Item(
      id: 'ppe.dustmask',
      icon: Icons.sanitizer,
      label: 'Dust mask',
      colour: AppTheme.cautionAmber,
      required_: false,
      verdict:
          'A dust mask stops particles. It does nothing about gas or a lack of '
          'oxygen.',
    ),
    _Item(
      id: 'ppe.torch',
      icon: Icons.flashlight_on,
      label: 'Non-sparking torch',
      colour: AppTheme.safeGreen,
      required_: false,
      verdict:
          'Sensible. In a flammable atmosphere it must be intrinsically safe — '
          'an ordinary torch is an ignition source.',
    ),
    _Item(
      id: 'ppe.phone',
      icon: Icons.smartphone,
      label: 'Ordinary mobile phone',
      colour: AppTheme.hazardRed,
      required_: false,
      verdict:
          'Not in a flammable atmosphere. An ordinary phone is not intrinsically '
          'safe and can ignite the mixture.',
    ),
    _Item(
      id: 'ppe.gloves',
      icon: Icons.back_hand,
      label: 'Chemical gloves',
      colour: AppTheme.cautionAmber,
      required_: false,
      verdict: 'Useful for residues, but not what keeps you breathing.',
    ),
  ];

  @override
  String get id => 'm2.act2.ppe';

  @override
  SafetyDomain get domain => SafetyDomain.gas;

  final List<SceneNode> _nodes = [];
  final List<ActionRecord> _actions = [];
  final List<BillboardNode> _itemNodes = [];
  final Map<String, _Item> _itemsById = {};
  final Set<String> _selected = {};

  Duration _elapsed = Duration.zero;
  int _wrongSelections = 0;
  bool _finished = false;
  ScenarioResult? _result;
  String? _feedback;
  Duration _feedbackUntil = Duration.zero;

  @override
  List<SceneNode> get nodes => _nodes;

  Set<String> get selected => _selected;

  /// The atmosphere the worker is kitting up for. Shown on the HUD throughout,
  /// because the entire decision hinges on that 17%.
  static const GasReading entryReading = GasReading(
    methanePercent: 1.2,
    oxygenPercent: 17.0,
    carbonMonoxidePpm: 22,
  );

  bool get hasAllRequired => _catalogue
      .where((item) => item.required_)
      .every((item) => _selected.contains(item.id));

  void _build() {
    final floor = floorZ;
    final shuffled = List<_Item>.from(_catalogue)..shuffle(_random);

    // Laid out as two rows in an arc, so the worker turns to see the whole
    // board rather than reading a list.
    for (var i = 0; i < shuffled.length; i++) {
      final item = shuffled[i];
      _itemsById[item.id] = item;

      final column = i % 4;
      final row = i ~/ 4;
      final bearing = -45.0 + column * 30.0;

      final node = BillboardNode(
        id: item.id,
        position: scenePlacement(
          bearingDegrees: bearing,
          distanceMetres: 2.8,
          heightMetres: floor + 1.45 - row * 0.75,
        ),
        icon: item.icon,
        // Neutral until chosen: colouring the answers in advance would give
        // the game away entirely.
        color: const Color(0xFF78909C),
        label: item.label,
        sizeMetres: 0.52,
      );

      _itemNodes.add(node);
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

    return ScenarioPrompt(
      text: _elapsed < const Duration(seconds: 6) ? _Copy.brief : _Copy.prompt,
      signal: SafetySignal.danger,
      hint: _elapsed > const Duration(seconds: 30) && !hasAllRequired
          ? 'Three things are essential: something to breathe, something to '
              'watch the air, and something to be pulled out by.'
          : null,
      narrationKey: 'm2.act2.select',
      remaining: clamped,
    );
  }

  @override
  void update(Duration elapsed, ArCamera camera) {
    if (_finished) return;
    _elapsed = elapsed;

    if (_elapsed >= _timeLimit) {
      _finish(passed: false, reason: _Copy.timeout, fatal: false);
      return;
    }

    notifyListeners();
  }

  @override
  void handleTap(SceneNode node) {
    if (_finished) return;
    final item = _itemsById[node.id];
    if (item == null) return;

    if (item.fatal) {
      // No second chance and no points. The consequence is the lesson.
      _record(item.id, ActionOutcome.fatal);
      _finish(passed: false, reason: item.verdict, fatal: true);
      notifyListeners();
      return;
    }

    final index = _itemNodes.indexWhere((n) => n.id == item.id);

    if (_selected.remove(item.id)) {
      if (index >= 0) _itemNodes[index].color = const Color(0xFF78909C);
    } else {
      _selected.add(item.id);
      if (index >= 0) _itemNodes[index].color = AppTheme.infoBlue;
      _showFeedback(item.verdict);
      if (!item.required_ && item.colour == AppTheme.hazardRed) {
        _wrongSelections++;
      }
    }

    notifyListeners();
  }

  /// Confirms the selection. Wired to the HUD's confirm control rather than a
  /// scene node, since it is a decision about the whole board.
  void confirmSelection() {
    if (_finished) return;

    final missing = _catalogue
        .where((item) => item.required_ && !_selected.contains(item.id))
        .toList();

    if (missing.isNotEmpty) {
      _wrongSelections++;
      _record('confirm.incomplete', ActionOutcome.incorrect);
      _showFeedback(
        'You are missing ${missing.length} essential '
        '${missing.length == 1 ? 'item' : 'items'}. '
        '${missing.first.verdict}',
      );
      notifyListeners();
      return;
    }

    _record('confirm.complete', ActionOutcome.correct);
    _showFeedback(_Copy.success);
    _finish(passed: true, reason: null, fatal: false);
    notifyListeners();
  }

  void _record(String targetId, ActionOutcome outcome) {
    _actions.add(ActionRecord(
      stepId: id,
      targetId: targetId,
      outcome: outcome,
      timeToAct: _elapsed,
      hintsUsed: 0,
    ));
  }

  void _showFeedback(String message) {
    _feedback = message;
    _feedbackUntil = _elapsed + const Duration(seconds: 5);
  }

  void _finish({
    required bool passed,
    required String? reason,
    required bool fatal,
  }) {
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
    score -= _wrongSelections * 15.0;

    // Taking the non-sparking torch is not required but shows the worker is
    // thinking about ignition sources as well as breathing.
    if (_selected.contains('ppe.torch')) score += 5;
    if (_selected.contains('ppe.phone')) score -= 20;

    final seconds = _elapsed.inMilliseconds / 1000.0;
    if (seconds < 45) score += (1 - seconds / 45) * 6;

    return score.clamp(0.0, 100.0);
  }

  @override
  bool get isFinished => _finished;

  @override
  ScenarioResult? get result => _result;

  @override
  void abandon() {
    if (_finished) return;
    _finish(
      passed: false,
      reason: 'Drill exited before completion.',
      fatal: false,
    );
  }
}
