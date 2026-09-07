import '../modules/catalogue.dart';
import 'question.dart';

/// The assessment question bank.
///
/// Authored in English, the source language; Phase 4 lifts these into ARB for
/// Hindi and Santali translation.
///
/// Content is grounded in Indian statutory practice and in the hazards that
/// actually appear in Jharkhand's coal, steel and mica sectors: extinguisher
/// classes follow IS 15683, gas thresholds follow DGMS and standard confined
/// space practice, and the mandatory items are the specific misconceptions that
/// recur in fatal accident reports.
abstract final class QuestionBank {
  static List<Question> forDomain(SafetyDomain domain) => switch (domain) {
        SafetyDomain.fire => fire,
        SafetyDomain.gas => gas,
        SafetyDomain.machinery => machinery,
        SafetyDomain.strata => strata,
        SafetyDomain.electrical => electrical,
      };

  // ------------------------------------------------------------------- fire

  static const List<Question> fire = [
    Question(
      id: 'fire.extinguisher.electrical',
      domain: SafetyDomain.fire,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'extinguisher-selection',
      mandatory: true,
      prompt: 'A motor control panel catches fire. Which extinguisher do you use?',
      choices: [
        'Carbon dioxide (CO2)',
        'Water jet',
        'Foam',
        'The nearest one, whatever it is',
      ],
      answer: [0],
      explanation:
          'Use CO2 (or dry powder) on live electrical equipment. Water and foam '
          'conduct electricity and will carry the current back to you. Isolate '
          'the supply first wherever you safely can.',
    ),
    Question(
      id: 'fire.lift',
      domain: SafetyDomain.fire,
      kind: QuestionKind.single,
      difficulty: 1,
      concept: 'evacuation-route',
      mandatory: true,
      prompt: 'There is a fire on your floor. The lift is closer than the stairs. '
          'What do you do?',
      choices: [
        'Take the stairs or the marked fire exit',
        'Take the lift because it is faster',
        'Take the lift only if it is already on your floor',
        'Wait by the lift for a supervisor',
      ],
      answer: [0],
      explanation:
          'Never use a lift in a fire. Power can fail and trap you between '
          'floors, and the shaft draws smoke upward. Always use the stairs or a '
          'marked fire exit.',
    ),
    Question(
      id: 'fire.pass.aim',
      domain: SafetyDomain.fire,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'extinguisher-technique',
      prompt: 'When using an extinguisher, where do you aim the nozzle?',
      choices: [
        'At the base of the fire',
        'At the tallest flames',
        'At the smoke above the fire',
        'Sweep across the ceiling first',
      ],
      answer: [0],
      explanation:
          'Aim at the base. That is where the fuel is. Spraying the flames wastes '
          'the extinguisher without removing what is burning, and you have '
          'roughly ten to fifteen seconds of discharge.',
    ),
    Question(
      id: 'fire.pass.order',
      domain: SafetyDomain.fire,
      kind: QuestionKind.ordering,
      difficulty: 2,
      concept: 'extinguisher-technique-order',
      prompt: 'Put the four steps of using an extinguisher in the correct order.',
      choices: [
        'Pull the safety pin',
        'Aim at the base of the fire',
        'Squeeze the handle',
        'Sweep from side to side',
      ],
      answer: [0, 1, 2, 3],
      explanation:
          'Pull, Aim, Squeeze, Sweep. Aiming before you squeeze matters — '
          'squeezing first empties the extinguisher into the air.',
    ),
    Question(
      id: 'fire.smoke.stay-low',
      domain: SafetyDomain.fire,
      kind: QuestionKind.single,
      difficulty: 1,
      concept: 'smoke-behaviour',
      prompt: 'A room is filling with smoke. Where is the cleaner air?',
      choices: [
        'Near the floor',
        'Near the ceiling',
        'It is the same throughout',
        'Beside the windows at head height',
      ],
      answer: [0],
      explanation:
          'Hot smoke rises and layers down from the ceiling, so the cleanest air '
          'is near the floor. Keep low and move quickly to the exit.',
    ),
    Question(
      id: 'fire.first-action',
      domain: SafetyDomain.fire,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'first-action',
      prompt: 'You are first to notice a fire starting in a storage bay. '
          'What is your first action?',
      choices: [
        'Raise the alarm',
        'Try to put it out yourself',
        'Find your supervisor and tell them',
        'Photograph it for the incident report',
      ],
      answer: [0],
      explanation:
          'Raise the alarm first. It takes seconds and it protects everyone else '
          'in the building. Only then consider tackling a small fire, and only '
          'if you have a clear escape route behind you.',
    ),
    Question(
      id: 'fire.reentry',
      domain: SafetyDomain.fire,
      kind: QuestionKind.single,
      difficulty: 1,
      concept: 'assembly-discipline',
      mandatory: true,
      prompt: 'You reach the assembly point and realise a workmate may still be '
          'inside. What do you do?',
      choices: [
        'Tell the fire warden immediately and stay out',
        'Go back in to look for them',
        'Go back in, but only as far as the doorway',
        'Wait to see if they arrive before saying anything',
      ],
      answer: [0],
      explanation:
          'Report it to the fire warden and stay out. Untrained re-entry is how '
          'one casualty becomes two. The warden has the information and the '
          'trained rescue team has the equipment.',
    ),
    Question(
      id: 'fire.classes',
      domain: SafetyDomain.fire,
      kind: QuestionKind.single,
      difficulty: 3,
      concept: 'fire-classes',
      prompt: 'Burning magnesium swarf in a machining bay is which class of fire?',
      choices: [
        'Class D',
        'Class A',
        'Class B',
        'Class C',
      ],
      answer: [0],
      explanation:
          'Burning metals are Class D and need a special dry powder agent. Water '
          'reacts violently with burning magnesium and will make it far worse.',
    ),
    Question(
      id: 'fire.triangle',
      domain: SafetyDomain.fire,
      kind: QuestionKind.multiple,
      difficulty: 2,
      concept: 'fire-triangle',
      prompt: 'A fire needs three things to keep burning. Select all three.',
      choices: ['Fuel', 'Oxygen', 'Heat', 'Smoke', 'Pressure'],
      answer: [0, 1, 2],
      explanation:
          'Fuel, oxygen and heat. Removing any one puts the fire out, which is '
          'why closing a door behind you as you leave slows a fire down: it cuts '
          'the oxygen supply.',
    ),
    Question(
      id: 'fire.door-closing',
      domain: SafetyDomain.fire,
      kind: QuestionKind.single,
      difficulty: 3,
      concept: 'compartmentation',
      prompt: 'As you evacuate through a doorway, what should you do with the door?',
      choices: [
        'Close it behind you, without locking it',
        'Leave it wide open so others can follow',
        'Lock it to stop the fire spreading',
        'Wedge it half open',
      ],
      answer: [0],
      explanation:
          'Close it but never lock it. A closed door starves the fire of oxygen '
          'and holds back smoke for several minutes. Locking it would trap '
          'anyone still behind you.',
    ),
  ];

  // -------------------------------------------------------------------- gas

  static const List<Question> gas = [
    Question(
      id: 'gas.respirator.confined',
      domain: SafetyDomain.gas,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'respiratory-protection',
      mandatory: true,
      prompt: 'You must enter a tank where the oxygen level reads 17%. Which '
          'breathing equipment do you use?',
      choices: [
        'Self-contained breathing apparatus (SCBA) or an airline set',
        'A dust mask',
        'A cartridge or filter respirator',
        'None — 17% is close enough to normal',
      ],
      answer: [0],
      explanation:
          'A filter respirator only cleans the air that is already there. It '
          'cannot make oxygen, so in an oxygen-deficient space it will not keep '
          'you alive. Below 19.5% oxygen you need supplied air: SCBA or an '
          'airline set. This misunderstanding kills people every year.',
    ),
    Question(
      id: 'gas.rescue.solo',
      domain: SafetyDomain.gas,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'rescue-discipline',
      mandatory: true,
      prompt: 'Your buddy collapses inside a confined space. What do you do?',
      choices: [
        'Stay outside, raise the alarm and call the trained rescue team',
        'Go in immediately and pull them out',
        'Go in holding your breath',
        'Go in after checking the gas meter once more',
      ],
      answer: [0],
      explanation:
          'Do not enter. A large share of people who die in confined spaces are '
          'would-be rescuers who went in without breathing apparatus. Whatever '
          'brought your buddy down is still in there and will take you too. '
          'Raise the alarm and let the trained team enter with equipment.',
    ),
    Question(
      id: 'gas.methane.range',
      domain: SafetyDomain.gas,
      kind: QuestionKind.single,
      difficulty: 3,
      concept: 'explosive-range',
      prompt: 'Between which concentrations in air is methane (firedamp) '
          'explosive?',
      choices: [
        'About 5% to 15%',
        'About 0.5% to 2%',
        'About 20% to 40%',
        'Any concentration above 1%',
      ],
      answer: [0],
      explanation:
          'Roughly 5% to 15%. Below 5% it is too lean to ignite and above 15% too '
          'rich — but a rich pocket becomes explosive the moment it mixes with '
          'fresh air, so a high reading is not a safe reading.',
    ),
    Question(
      id: 'gas.oxygen.threshold',
      domain: SafetyDomain.gas,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'oxygen-threshold',
      prompt: 'Normal air is about 21% oxygen. Below what level is an atmosphere '
          'treated as oxygen-deficient?',
      choices: ['19.5%', '15%', '10%', '20.9%'],
      answer: [0],
      explanation:
          '19.5% is the standard threshold. It sounds like a small drop from 21%, '
          'which is exactly why people underestimate it — judgement and '
          'coordination are already affected before you feel anything is wrong.',
    ),
    Question(
      id: 'gas.methane.location',
      domain: SafetyDomain.gas,
      kind: QuestionKind.single,
      difficulty: 3,
      concept: 'gas-density',
      prompt: 'Methane is lighter than air. Where should you expect it to collect '
          'in an underground roadway?',
      choices: [
        'Against the roof and in cavities above',
        'Along the floor',
        'Evenly through the whole roadway',
        'Only near the ventilation fan',
      ],
      answer: [0],
      explanation:
          'Methane rises and collects at the roof and in roof cavities, which is '
          'why testing is done at height. Hydrogen sulphide and carbon dioxide '
          'are heavier and pool low down — so where you hold the detector '
          'depends on which gas you are looking for.',
    ),
    Question(
      id: 'gas.approach.wind',
      domain: SafetyDomain.gas,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'approach-direction',
      prompt: 'A gas release is reported in the yard. How do you approach?',
      choices: [
        'From upwind',
        'From downwind',
        'From directly above',
        'The direction does not matter if you are quick',
      ],
      answer: [0],
      explanation:
          'Approach from upwind so the wind carries the gas away from you rather '
          'than over you. Check the windsock before you move.',
    ),
    Question(
      id: 'gas.permit',
      domain: SafetyDomain.gas,
      kind: QuestionKind.multiple,
      difficulty: 3,
      concept: 'entry-permit',
      prompt: 'Before anyone enters a confined space, which of these must be in '
          'place? Select all that apply.',
      choices: [
        'A valid written entry permit',
        'Atmospheric testing of the space',
        'An attendant stationed outside',
        'A rescue plan and equipment ready',
        'A photograph of the entry point',
      ],
      answer: [0, 1, 2, 3],
      explanation:
          'Permit, testing, an attendant outside and a rescue plan are all '
          'required before entry. The attendant never enters — their job is to '
          'stay out, keep watch and raise the alarm.',
    ),
    Question(
      id: 'gas.testing.continuous',
      domain: SafetyDomain.gas,
      kind: QuestionKind.single,
      difficulty: 3,
      concept: 'monitoring',
      prompt: 'The space tested clear before entry. What monitoring is needed '
          'during the work?',
      choices: [
        'Continuous monitoring throughout the work',
        'None — it was tested before entry',
        'One more test at the halfway point',
        'Testing only if someone feels unwell',
      ],
      answer: [0],
      explanation:
          'Monitor continuously. An atmosphere changes: sludge gets disturbed, '
          'welding consumes oxygen, and gas seeps in from connected pipework. A '
          'clear test at entry says nothing about twenty minutes later.',
    ),
    Question(
      id: 'gas.isolation',
      domain: SafetyDomain.gas,
      kind: QuestionKind.single,
      difficulty: 3,
      concept: 'isolation',
      prompt: 'A vessel is connected to a live process line. What must be done '
          'before entry?',
      choices: [
        'Physically isolate the line by blanking or disconnecting it',
        'Close the valve and tape it shut',
        'Ask the control room not to use that line',
        'Post a warning notice at the valve',
      ],
      answer: [0],
      explanation:
          'Positive isolation — a blank, a spade or a physical disconnection. A '
          'closed valve can be opened by mistake, and valves leak. Nothing but a '
          'physical break is good enough when someone is inside.',
    ),
    Question(
      id: 'gas.detector.alarm',
      domain: SafetyDomain.gas,
      kind: QuestionKind.single,
      difficulty: 1,
      concept: 'alarm-response',
      prompt: 'Your personal gas detector alarms while you are working inside a '
          'vessel. What do you do?',
      choices: [
        'Leave immediately by the way you came in',
        'Silence the alarm and finish the task',
        'Wait to see whether the reading settles',
        'Move to the far end of the vessel',
      ],
      answer: [0],
      explanation:
          'Leave at once. The alarm is set below the level that harms you so that '
          'you still have time to get out. Silencing it or waiting spends the '
          'margin the alarm exists to give you.',
    ),
  ];

  // ------------------------------------------------- introductory domains

  static const List<Question> machinery = [
    Question(
      id: 'loto.order',
      domain: SafetyDomain.machinery,
      kind: QuestionKind.ordering,
      difficulty: 2,
      concept: 'loto-sequence',
      prompt: 'Put the lockout-tagout steps in the correct order.',
      choices: [
        'Notify affected workers and shut the machine down',
        'Isolate every energy source',
        'Apply your own lock and tag',
        'Release stored energy',
        'Try to start the machine to prove it is dead',
      ],
      answer: [0, 1, 2, 3, 4],
      explanation:
          'Notify, isolate, lock and tag, release stored energy, then verify by '
          'attempting a start. The verification step is the one people skip, and '
          'it is the only one that proves the rest worked.',
    ),
    Question(
      id: 'loto.own-lock',
      domain: SafetyDomain.machinery,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'lock-ownership',
      mandatory: true,
      prompt: 'Three people are working on the same conveyor. How many locks go '
          'on the isolation point?',
      choices: [
        'One from each worker, on a multi-lock hasp',
        'One, applied by the supervisor',
        'One, applied by whoever arrived first',
        'None, as long as a tag is fitted',
      ],
      answer: [0],
      explanation:
          'Every worker fits their own lock and keeps their own key. The machine '
          'cannot restart until the last person has removed their lock — so '
          'nobody can be re-energised onto by a colleague finishing early.',
    ),
    Question(
      id: 'loto.stored-energy',
      domain: SafetyDomain.machinery,
      kind: QuestionKind.multiple,
      difficulty: 3,
      concept: 'stored-energy',
      prompt: 'After electrical isolation, which stored energy can still injure '
          'you? Select all that apply.',
      choices: [
        'A raised or suspended load',
        'A compressed spring',
        'Trapped hydraulic or air pressure',
        'A flywheel still spinning',
        'The switch being locked off',
      ],
      answer: [0, 1, 2, 3],
      explanation:
          'Gravity, springs, trapped pressure and rotating mass all hold energy '
          'after the power is off. Each has to be blocked, bled or allowed to '
          'stop before the work starts.',
    ),
    Question(
      id: 'loto.guard',
      domain: SafetyDomain.machinery,
      kind: QuestionKind.single,
      difficulty: 1,
      concept: 'guarding',
      prompt: 'A guard on a running machine is loose and rattling. What do you do?',
      choices: [
        'Stop the machine and report it before any further work',
        'Tighten it while the machine runs',
        'Remove it, since a loose guard is more dangerous than none',
        'Carry on and report it at the end of the shift',
      ],
      answer: [0],
      explanation:
          'Stop and report. Adjusting a guard on running machinery puts your '
          'hands exactly where the guard exists to keep them out of.',
    ),
  ];

  static const List<Question> strata = [
    Question(
      id: 'strata.warning-signs',
      domain: SafetyDomain.strata,
      kind: QuestionKind.multiple,
      difficulty: 2,
      concept: 'roof-warning-signs',
      prompt: 'Which of these warn that the roof may be about to fail? Select all '
          'that apply.',
      choices: [
        'Fresh cracks or spalling in the roof',
        'A drummy, hollow sound when tapped',
        'Supports taking visible load or buckling',
        'Water suddenly seeping through',
        'A drop in air temperature',
      ],
      answer: [0, 1, 2, 3],
      explanation:
          'Cracking, a drummy sound, loaded supports and new water ingress are '
          'all warnings. Sounding the roof — tapping and listening — is a skill '
          'worth practising, because a drummy note means the rock above is '
          'already separated.',
    ),
    Question(
      id: 'strata.support-distance',
      domain: SafetyDomain.strata,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'unsupported-roof',
      mandatory: true,
      prompt: 'Work has exposed a stretch of unsupported roof. What do you do?',
      choices: [
        'Stay out from under it and get support set before working there',
        'Work quickly underneath and finish before anything moves',
        'Work under it only if it looks solid',
        'Stand under it but keep watching the roof',
      ],
      answer: [0],
      explanation:
          'Never work or travel under unsupported roof. Falls of ground give '
          'almost no warning and a small piece of roof rock weighs more than '
          'enough to kill. Support first, then work.',
    ),
    Question(
      id: 'strata.anchor',
      domain: SafetyDomain.strata,
      kind: QuestionKind.single,
      difficulty: 3,
      concept: 'fall-arrest-anchor',
      prompt: 'You need an anchor point for a fall-arrest harness. Which is '
          'acceptable?',
      choices: [
        'A rated anchor point at or above shoulder height',
        'A handrail at waist height',
        'A pipe running along the floor',
        'The nearest cable tray',
      ],
      answer: [0],
      explanation:
          'Use a rated anchor at or above shoulder height. Anchoring low lets you '
          'fall further before the system takes hold, and handrails, pipes and '
          'cable trays are not designed for arrest loads.',
    ),
  ];

  static const List<Question> electrical = [
    Question(
      id: 'elec.rescue',
      domain: SafetyDomain.electrical,
      kind: QuestionKind.single,
      difficulty: 2,
      concept: 'electrical-rescue',
      mandatory: true,
      prompt: 'A workmate is being shocked and is still in contact with a live '
          'conductor. What do you do first?',
      choices: [
        'Isolate the supply before touching them',
        'Pull them away by the arm',
        'Pull them away by their clothing',
        'Pour water to break the contact',
      ],
      answer: [0],
      explanation:
          'Isolate the supply first. Touching someone who is still in contact '
          'puts the same current through you. If isolation is genuinely '
          'impossible, use a dry insulating object — never bare hands, never '
          'water.',
    ),
    Question(
      id: 'elec.verify-dead',
      domain: SafetyDomain.electrical,
      kind: QuestionKind.ordering,
      difficulty: 3,
      concept: 'prove-dead',
      prompt: 'Put the steps for proving a circuit dead in the correct order.',
      choices: [
        'Prove the tester works on a known live source',
        'Test the circuit you are about to work on',
        'Prove the tester still works on the known live source',
      ],
      answer: [0, 1, 2],
      explanation:
          'Prove, test, prove again. Without the final check, a tester that '
          'failed between the first two steps would make a live circuit look '
          'dead — which is precisely the situation that kills.',
    ),
    Question(
      id: 'elec.arc-flash',
      domain: SafetyDomain.electrical,
      kind: QuestionKind.single,
      difficulty: 3,
      concept: 'arc-flash',
      prompt: 'What is the main protection against an arc flash when switching '
          'high-power equipment?',
      choices: [
        'Rated arc-flash PPE and keeping clear of the arc zone',
        'Ordinary cotton overalls',
        'Standing close so you can switch quickly',
        'Rubber gloves alone',
      ],
      answer: [0],
      explanation:
          'Rated arc-flash PPE plus distance. An arc flash reaches temperatures '
          'several times hotter than the surface of the sun and the pressure '
          'wave alone can throw a person across a room; ordinary clothing can '
          'ignite.',
    ),
  ];
}
