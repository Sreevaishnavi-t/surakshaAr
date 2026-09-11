import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/environment/environment_map.dart';
import 'package:surakshaar/ar/environment/ground_plane.dart';
import 'package:surakshaar/ar/pose/device_pose.dart';
import 'package:surakshaar/ar/scene/ar_camera.dart';
import 'package:surakshaar/modules/engine/scenario.dart';
import 'package:surakshaar/modules/m1_fire/fire_act1_exit.dart';
import 'package:surakshaar/modules/m1_fire/fire_act2_extinguisher.dart';
import 'package:surakshaar/modules/m1_fire/fire_act3_evacuation.dart';
import 'package:surakshaar/modules/m2_gas/gas_act1_hazard_zone.dart';
import 'package:surakshaar/modules/m2_gas/gas_act2_ppe.dart';
import 'package:surakshaar/modules/m2_gas/gas_act3_buddy.dart';

ArCamera _camera() => ArCamera(
      pose: DevicePose.upright(),
      intrinsics: ArCameraIntrinsics.fallback,
      previewSize: const Size(480, 720),
      viewportSize: const Size(384, 832),
      worldFromScene: ArCamera.calibrationFromYaw(0),
    );

/// A map whose only interesting property is the floor it reports.
EnvironmentMap _mapAtHeight(double metres) => EnvironmentMap()
  ..ground = GroundPlane(
    cameraHeightMetres: metres,
    source: GroundHeightSource.measured,
  );

List<ArScenario Function()> get _allActs => [
      () => FireAct1ExitScenario(random: math.Random(1)),
      () => FireAct2ExtinguisherScenario(random: math.Random(1)),
      () => FireAct3EvacuationScenario(random: math.Random(1)),
      () => GasAct1HazardZoneScenario(random: math.Random(1)),
      () => GasAct2PpeScenario(random: math.Random(1)),
      () => GasAct3BuddyScenario(random: math.Random(1)),
    ];

void main() {
  group('floor snapping', () {
    test('every act moves its content onto the measured floor', () {
      // The regression this pins: applyEnvironment used to be an empty default
      // that only one act of eight overrode, so seven acts left their content
      // at an assumed height nobody had checked.
      for (final make in _allActs) {
        final scenario = make();
        final before = {
          for (final node in scenario.nodes) node.id: node.position.z,
        };

        scenario.applyEnvironment(_mapAtHeight(1.20), _camera());

        final moved = scenario.nodes.any(
          (n) => (n.position.z - before[n.id]!).abs() > 1e-9,
        );
        expect(
          moved,
          isTrue,
          reason: '${scenario.id} ignored the measured floor entirely',
        );
      }
    });

    test('the shift is uniform, so heights above the floor survive', () {
      // The extinguisher is bracketed 0.45 m up a wall and the smoke column
      // starts 0.7 m above the fire. An absolute assignment would flatten both
      // onto the ground; a single delta cannot.
      final scenario = FireAct2ExtinguisherScenario(random: math.Random(7));
      final before = {
        for (final node in scenario.nodes) node.id: node.position.z,
      };

      scenario.applyEnvironment(_mapAtHeight(1.20), _camera());

      final deltas = <double>[
        for (final node in scenario.nodes)
          node.position.z - before[node.id]!,
      ];
      expect(deltas, isNotEmpty);
      for (final delta in deltas) {
        expect(delta, closeTo(deltas.first, 1e-9));
      }
    });

    test('content lands at the measured floor, not the assumed one', () {
      final scenario = FireAct3EvacuationScenario(random: math.Random(3));

      // Authored against the assumed height.
      final lowest = scenario.nodes
          .map((n) => n.position.z)
          .reduce(math.min);
      expect(lowest, closeTo(-GroundPlane.assumed.cameraHeightMetres, 1e-9));

      scenario.applyEnvironment(_mapAtHeight(1.20), _camera());

      final movedLowest = scenario.nodes
          .map((n) => n.position.z)
          .reduce(math.min);
      expect(movedLowest, closeTo(-1.20, 1e-9));
    });

    test('applying twice does not shift twice', () {
      // The session offers the environment once per act, but a rebuild or a
      // re-scan must not compound the correction.
      final scenario = GasAct1HazardZoneScenario(random: math.Random(5));
      final map = _mapAtHeight(1.30);
      final camera = _camera();

      scenario.applyEnvironment(map, camera);
      final once = {
        for (final node in scenario.nodes) node.id: node.position.z,
      };

      scenario.applyEnvironment(map, camera);

      for (final node in scenario.nodes) {
        expect(node.position.z, closeTo(once[node.id]!, 1e-9));
      }
    });

    test('a thin scan still corrects the floor for the exit act', () {
      // FireAct1 returns early when the map is unusable. That early return used
      // to skip the floor correction as well as the door anchoring, which is
      // the opposite of the desired trade: door anchoring is a bonus, standing
      // on the right floor is not.
      final scenario = FireAct1ExitScenario(random: math.Random(2));
      final unusable = _mapAtHeight(1.15);
      expect(unusable.isUsable, isFalse, reason: 'test needs a thin scan');

      scenario.applyEnvironment(unusable, _camera());

      final lowest = scenario.nodes
          .map((n) => n.position.z)
          .reduce(math.min);
      expect(lowest, closeTo(-1.15, 1e-9));
    });
  });
}
