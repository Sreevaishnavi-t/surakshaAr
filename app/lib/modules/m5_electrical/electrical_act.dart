import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, Icons;

import '../catalogue.dart';
import '../engine/ordering_scenario.dart';

/// **Electrical Hazards & First Aid — safe isolation sequence.**
///
/// Built around prove-test-prove, the discipline that separates a circuit
/// someone believes is dead from one that has been shown to be. The final proof
/// step is the one that gets dropped, and dropping it is precisely the failure
/// that kills: a tester that failed silently between the first two steps makes a
/// live conductor look dead.
class ElectricalScenario extends OrderingScenario {
  ElectricalScenario({math.Random? random})
      : super(
          id: 'm5.act1.electrical',
          domain: SafetyDomain.electrical,
          accent: const Color(0xFF7E57C2),
          random: random,
          brief: 'A distribution board needs work. Make it safe — tap the steps '
              'in the correct order.',
          prompt_: 'What is the next step?',
          successMessage:
              'Correct. Isolated, locked, and proved dead with a tester you '
              'proved was working — before and after.',
          timeoutMessage:
              'Time ran out. A circuit nobody has proved dead is a live circuit.',
          steps: const [
            OrderedStep(
              id: 'elec.identify',
              icon: Icons.search,
              label: 'Identify the correct circuit',
              rationale:
                  'Confirm exactly which circuit you are working on. Isolating '
                  'the wrong one leaves you working live and leaves someone '
                  'else in the dark.',
            ),
            OrderedStep(
              id: 'elec.isolate',
              icon: Icons.power_off,
              label: 'Isolate at the supply',
              rationale:
                  'Open the isolator and secure it. A switched-off breaker is '
                  'not an isolation until it is locked.',
            ),
            OrderedStep(
              id: 'elec.lock',
              icon: Icons.lock_outline,
              label: 'Lock off and tag',
              rationale:
                  'Your own lock and your own key, so nobody can re-energise '
                  'the circuit while you are working on it.',
              fatalIfSkipped: true,
            ),
            OrderedStep(
              id: 'elec.prove-tester',
              icon: Icons.check_circle_outline,
              label: 'Prove the tester on a known live source',
              rationale:
                  'Check the tester works before you trust it. An untested '
                  'tester reads dead on everything, including live conductors.',
            ),
            OrderedStep(
              id: 'elec.test',
              icon: Icons.electrical_services,
              label: 'Test the isolated circuit',
              rationale:
                  'Test every conductor, including neutral and earth, not just '
                  'the one you intend to touch.',
            ),
            OrderedStep(
              id: 'elec.reprove',
              icon: Icons.replay,
              label: 'Prove the tester again',
              rationale:
                  'The step people skip. If the tester failed between the first '
                  'proof and the test, a live circuit just read as dead — and '
                  'you would have no way of knowing.',
              fatalIfSkipped: true,
            ),
          ],
        );
}
