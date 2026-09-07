import 'catalogue.dart';
import 'engine/scenario.dart';
import 'm1_fire/fire_act1_exit.dart';
import 'm1_fire/fire_act2_extinguisher.dart';
import 'm1_fire/fire_act3_evacuation.dart';
import 'm2_gas/gas_act1_hazard_zone.dart';
import 'm2_gas/gas_act2_ppe.dart';
import 'm2_gas/gas_act3_buddy.dart';
import 'm3_machinery/loto_act.dart';
import 'm4_strata/strata_act.dart';
import 'm5_electrical/electrical_act.dart';

/// Maps a safety domain to the acts that make up its drill.
///
/// The session screen walks this list in order. Fire and Gas run three acts
/// each; the introductory modules run one. Keeping the mapping here means
/// adding an act is a one-line change and touches no UI.
abstract final class ActRegistry {
  static List<ArScenario Function()> actsFor(SafetyDomain domain) {
    return switch (domain) {
      // Find the way out, then deal with a fire you can actually fight, then
      // get everyone out in the right order. The sequence mirrors the decisions
      // a worker faces in that order in a real incident.
      SafetyDomain.fire => [
          FireAct1ExitScenario.new,
          FireAct2ExtinguisherScenario.new,
          FireAct3EvacuationScenario.new,
        ],

      // Recognise the hazard, equip correctly, then follow the procedure that
      // stops a rescue becoming a second fatality.
      SafetyDomain.gas => [
          GasAct1HazardZoneScenario.new,
          GasAct2PpeScenario.new,
          GasAct3BuddyScenario.new,
        ],

      SafetyDomain.machinery => [LotoScenario.new],
      SafetyDomain.strata => [StrataScenario.new],
      SafetyDomain.electrical => [ElectricalScenario.new],
    };
  }

  static int actCountFor(SafetyDomain domain) => actsFor(domain).length;
}

/// Combines the acts of one module into a single result.
///
/// The module's behavioural score is the mean across its acts, and every act's
/// telemetry is carried through. Averaging rather than taking the best is
/// deliberate: a worker who evacuates well but cannot use an extinguisher is
/// not competent in the domain, and a certificate should not round that away.
ScenarioResult combineActs({
  required SafetyDomain domain,
  required List<ScenarioResult> acts,
}) {
  if (acts.isEmpty) {
    throw ArgumentError('Cannot combine an empty list of acts');
  }

  final passed = acts.every((a) => a.passed);
  final meanScore =
      acts.fold<double>(0, (sum, a) => sum + a.behaviouralScore) / acts.length;

  return ScenarioResult(
    scenarioId: 'module.${domain.name}',
    domain: domain,
    passed: passed,
    behaviouralScore: meanScore,
    actions: [for (final act in acts) ...act.actions],
    duration: acts.fold(Duration.zero, (sum, a) => sum + a.duration),
    // Surface the first act that ended badly, since that is the one to retrain.
    fatalReason: acts
        .where((a) => a.fatalReason != null)
        .map((a) => a.fatalReason!)
        .firstOrNull,
  );
}
