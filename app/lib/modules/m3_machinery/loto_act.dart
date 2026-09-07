import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;

import '../../core/theme/app_theme.dart';
import '../catalogue.dart';
import '../engine/ordering_scenario.dart';

/// **Machinery & Lockout-Tagout — isolation sequence.**
///
/// Five steps that almost every worker can list and far fewer can order. The
/// two that matter most are the ones people skip: releasing stored energy,
/// because isolating the electrical supply does nothing about a raised load or
/// a charged accumulator, and the try-out step, which is the only part of the
/// whole procedure that actually *proves* the machine is dead rather than
/// assuming it.
class LotoScenario extends OrderingScenario {
  LotoScenario({math.Random? random})
      : super(
          id: 'm3.act1.loto',
          domain: SafetyDomain.machinery,
          accent: AppTheme.infoBlue,
          random: random,
          brief: 'A conveyor drive needs maintenance. Isolate it safely — tap '
              'the steps in the correct order.',
          prompt_: 'What is the next step?',
          successMessage:
              'Correct. Notified, isolated, locked, de-energised and proved '
              'dead — in that order.',
          timeoutMessage:
              'Time ran out. An isolation done in a hurry is an isolation '
              'someone gets hurt by.',
          steps: const [
            OrderedStep(
              id: 'loto.notify',
              icon: Icons.campaign_outlined,
              label: 'Notify and shut down',
              rationale:
                  'Tell everyone affected and bring the machine to a normal '
                  'stop first. Someone downstream may be relying on it running.',
            ),
            OrderedStep(
              id: 'loto.isolate',
              icon: Icons.power_off,
              label: 'Isolate every energy source',
              rationale:
                  'Every source, not just the main electrical one — hydraulic, '
                  'pneumatic, gravity and stored charge all count.',
            ),
            OrderedStep(
              id: 'loto.lock',
              icon: Icons.lock_outline,
              label: 'Apply your own lock and tag',
              rationale:
                  'Your own lock, your own key. On a multi-lock hasp the machine '
                  'cannot restart until the last worker removes theirs.',
            ),
            OrderedStep(
              id: 'loto.dissipate',
              icon: Icons.compress,
              label: 'Release stored energy',
              rationale:
                  'Bleed pressure, block raised loads, let flywheels stop and '
                  'discharge capacitors. Isolation does not remove energy that '
                  'is already stored in the machine.',
              fatalIfSkipped: true,
            ),
            OrderedStep(
              id: 'loto.verify',
              icon: Icons.play_disabled,
              label: 'Try to start it — prove it is dead',
              rationale:
                  'Attempt a start from the normal controls. This is the only '
                  'step that proves the other four worked, and it is the one '
                  'most often skipped.',
              fatalIfSkipped: true,
            ),
          ],
        );
}
