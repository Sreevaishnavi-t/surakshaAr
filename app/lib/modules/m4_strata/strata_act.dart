import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, Icons;

import '../catalogue.dart';
import '../engine/ordering_scenario.dart';

/// **Roof Fall & Working at Height — support and inspection sequence.**
///
/// Falls of ground remain one of the largest causes of death in Indian
/// underground coal mining, and they give almost no warning. The sequence here
/// is built around the two habits that prevent them: sounding the roof before
/// trusting it, and never travelling under unsupported ground — the step
/// workers skip when they are only passing through for a moment.
class StrataScenario extends OrderingScenario {
  StrataScenario({math.Random? random})
      : super(
          id: 'm4.act1.strata',
          domain: SafetyDomain.strata,
          accent: const Color(0xFF8D6E63),
          random: random,
          brief: 'You have arrived at a newly advanced face. Make the roof safe '
              'before working — tap the steps in the correct order.',
          prompt_: 'What is the next step?',
          successMessage:
              'Correct. Inspected, sounded, barred down, supported, and only '
              'then worked under.',
          timeoutMessage:
              'Time ran out. Ground does not wait to be assessed.',
          steps: const [
            OrderedStep(
              id: 'strata.inspect',
              icon: Icons.visibility_outlined,
              label: 'Inspect the roof and sides',
              rationale:
                  'Look for fresh cracks, spalling, loaded supports and new '
                  'water seepage before anything else.',
            ),
            OrderedStep(
              id: 'strata.sound',
              icon: Icons.graphic_eq,
              label: 'Sound the roof',
              rationale:
                  'Tap and listen from a safe position. A drummy, hollow note '
                  'means the rock above has already separated.',
              fatalIfSkipped: true,
            ),
            OrderedStep(
              id: 'strata.bar',
              icon: Icons.construction,
              label: 'Bar down loose ground',
              rationale:
                  'Bring down anything loose from under supported ground, '
                  'standing clear of where it will fall.',
            ),
            OrderedStep(
              id: 'strata.support',
              icon: Icons.vertical_align_top,
              label: 'Set support to the face',
              rationale:
                  'Set props or bolts up to the working face. This is what '
                  'turns unsupported ground into ground you can stand under.',
              fatalIfSkipped: true,
            ),
            OrderedStep(
              id: 'strata.work',
              icon: Icons.engineering,
              label: 'Begin work under supported roof',
              rationale:
                  'Only now. Never work or travel under unsupported roof, not '
                  'even briefly — a fall gives no warning.',
            ),
          ],
        );
}
