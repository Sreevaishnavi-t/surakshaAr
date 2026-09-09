import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/environment/door_detector.dart';
import 'package:surakshaar/ar/environment/environment_map.dart';
import 'package:surakshaar/ar/environment/floor_detector.dart';
import 'package:surakshaar/ar/environment/ground_plane.dart';
import 'package:surakshaar/ar/environment/placement_resolver.dart';
import 'package:surakshaar/ar/pose/device_pose.dart';
import 'package:surakshaar/ar/scene/ar_camera.dart';
import 'package:vector_math/vector_math_64.dart';

const ground = GroundPlane(cameraHeightMetres: 1.5);

ArCamera cameraFacing(double yaw) => ArCamera(
      pose: DevicePose.upright(yawRadians: yaw),
      intrinsics: ArCameraIntrinsics.fallback,
      previewSize: const Size(480, 720),
      viewportSize: const Size(384, 832),
    );

DoorCandidate doorAt({
  required double bearing,
  required double distance,
  double width = 0.9,
  double height = 2.05,
  double score = 0.8,
  bool isOpening = true,
}) {
  return DoorCandidate(
    basePoint: ground.pointAt(
      bearingRadians: bearing,
      distanceMetres: distance,
    ),
    widthMetres: width,
    heightMetres: height,
    distanceMetres: distance,
    bearingRadians: bearing,
    score: score,
    isOpening: isOpening,
  );
}

/// Fills every sector with a uniform free distance, so tests can focus on the
/// decision being made rather than on map coverage.
void fillOpenSpace(EnvironmentMap map, {double metres = 8}) {
  final columns = <ColumnBoundary>[];
  for (var i = 0; i < 32; i++) {
    columns.add(ColumnBoundary(column: i, boundaryRow: null, confidence: 0.8));
  }
  final scan = FloorScan(columns: columns, gridHeight: 24);

  // Sweep the full circle so every sector is observed.
  for (var step = 0; step < 24; step++) {
    map.ingest(
      floor: scan,
      doors: const [],
      camera: cameraFacing(step / 24 * 2 * math.pi),
      ground: ground,
    );
  }
}

void main() {
  group('EnvironmentMap', () {
    test('starts unusable and becomes usable once enough has been seen', () {
      final map = EnvironmentMap();
      expect(map.isUsable, isFalse);
      expect(map.coverage, 0);

      fillOpenSpace(map);
      expect(map.isUsable, isTrue);
      expect(map.coverage, greaterThan(0.9));
    });

    test('an unobserved direction reports null, not zero', () {
      // The distinction matters: null means "unknown", and placing a hazard in
      // an unknown sector is exactly the mid-air spawn this map prevents.
      final map = EnvironmentMap();
      expect(map.freeDistanceAt(0), isNull);
    });

    test('keeps the nearest obstruction ever seen in a sector', () {
      final map = EnvironmentMap();
      final camera = cameraFacing(0);

      FloorScan scanWithBoundary(int? row) => FloorScan(
            columns: [
              for (var i = 0; i < 32; i++)
                ColumnBoundary(column: i, boundaryRow: row, confidence: 0.8),
            ],
            gridHeight: 24,
          );

      // Seen open once, then obstructed. Free space is a safety claim, so the
      // conservative reading must win regardless of order.
      map.ingest(
        floor: scanWithBoundary(null),
        doors: const [],
        camera: camera,
        ground: ground,
      );
      final open = map.freeDistanceAt(camera.pose.yaw)!;

      map.ingest(
        // Row 19 is a genuinely near obstruction. Row 14 sits so close to the
        // horizon that it computes further away than the open-floor cap, which
        // made the test assert nothing.
        floor: scanWithBoundary(19),
        doors: const [],
        camera: camera,
        ground: ground,
      );
      final obstructed = map.freeDistanceAt(camera.pose.yaw)!;

      expect(obstructed, lessThan(open));
    });

    test('merges repeated sightings of one door instead of duplicating it', () {
      final map = EnvironmentMap();
      final camera = cameraFacing(0);
      final scan = FloorScan(columns: const [], gridHeight: 24);

      for (var i = 0; i < 4; i++) {
        map.ingest(
          floor: scan,
          // Jittered slightly, as successive frames of the same door would be.
          doors: [doorAt(bearing: 0.02 * i, distance: 5 + 0.05 * i)],
          camera: camera,
          ground: ground,
        );
      }

      expect(map.provisionalDoors.length, 1);
      expect(map.provisionalDoors.first.sightings, 4);
    });

    test('a door seen once is provisional, not confirmed', () {
      final map = EnvironmentMap();
      map.ingest(
        floor: FloorScan(columns: const [], gridHeight: 24),
        doors: [doorAt(bearing: 0, distance: 5)],
        camera: cameraFacing(0),
        ground: ground,
      );

      expect(map.provisionalDoors, hasLength(1));
      expect(map.doors, isEmpty, reason: 'one sighting is not evidence');
    });

    test('confidence grows with sightings', () {
      final map = EnvironmentMap();
      final scan = FloorScan(columns: const [], gridHeight: 24);

      map.ingest(
        floor: scan,
        doors: [doorAt(bearing: 0, distance: 5)],
        camera: cameraFacing(0),
        ground: ground,
      );
      final afterOne = map.provisionalDoors.first.confidence;

      for (var i = 0; i < 5; i++) {
        map.ingest(
          floor: scan,
          doors: [doorAt(bearing: 0, distance: 5)],
          camera: cameraFacing(0),
          ground: ground,
        );
      }

      expect(map.provisionalDoors.first.confidence, greaterThan(afterOne));
    });
  });

  group('PlacementResolver', () {
    const resolver = PlacementResolver();

    PlacementRequest exitRequest({double bearing = 0}) => PlacementRequest(
          id: 'exit',
          kind: PlacementKind.exit,
          preferredBearingRadians: bearing,
          preferredDistanceMetres: 7,
        );

    EnvironmentMap mapWithDoors(List<DoorCandidate> doors, {int sightings = 4}) {
      final map = EnvironmentMap();
      fillOpenSpace(map);
      for (var i = 0; i < sightings; i++) {
        map.ingest(
          floor: FloorScan(columns: const [], gridHeight: 24),
          doors: doors,
          camera: cameraFacing(0),
          ground: ground,
        );
      }
      return map;
    }

    test('an exit is pinned to a detected doorway', () {
      final map = mapWithDoors([doorAt(bearing: 1.2, distance: 6)]);

      final resolved = resolver.resolveAll(
        requests: [exitRequest(bearing: 0)],
        map: map,
      ).single;

      expect(resolved.anchor, PlacementAnchor.detectedDoor);
      expect(resolved.door, isNotNull);
      // The authored hint said straight ahead; the real door is at 1.2 rad, and
      // the real door wins. Turning to look for the way out is the drill.
      expect(
        math.atan2(resolved.worldPosition.y, resolved.worldPosition.x),
        closeTo(1.2, 0.05),
      );
      expect(resolved.isAnchoredToRealFeature, isTrue);
    });

    test('two exits never claim the same doorway', () {
      final map = mapWithDoors([
        doorAt(bearing: 0.5, distance: 6),
        doorAt(bearing: 2.5, distance: 5),
      ]);

      final resolved = resolver.resolveAll(
        requests: [
          exitRequest(bearing: 0.4),
          const PlacementRequest(
            id: 'exit2',
            kind: PlacementKind.exit,
            preferredBearingRadians: 0.45,
            preferredDistanceMetres: 7,
          ),
        ],
        map: map,
      );

      expect(resolved[0].door, isNotNull);
      expect(resolved[1].door, isNotNull);
      expect(identical(resolved[0].door, resolved[1].door), isFalse);
    });

    test('prefers a confident door over one that merely matches the hint', () {
      final map = EnvironmentMap();
      fillOpenSpace(map);

      // A weak door exactly where the author wanted it.
      map.ingest(
        floor: FloorScan(columns: const [], gridHeight: 24),
        doors: [doorAt(bearing: 0, distance: 6, score: 0.5)],
        camera: cameraFacing(0),
        ground: ground,
      );
      map.ingest(
        floor: FloorScan(columns: const [], gridHeight: 24),
        doors: [doorAt(bearing: 0, distance: 6, score: 0.5)],
        camera: cameraFacing(0),
        ground: ground,
      );

      // A thoroughly confirmed door off to the side.
      for (var i = 0; i < 8; i++) {
        map.ingest(
          floor: FloorScan(columns: const [], gridHeight: 24),
          doors: [doorAt(bearing: 2.0, distance: 6, score: 0.9)],
          camera: cameraFacing(0),
          ground: ground,
        );
      }

      final resolved = resolver.resolveAll(
        requests: [exitRequest(bearing: 0)],
        map: map,
      ).single;

      expect(resolved.door!.bearingRadians, closeTo(2.0, 0.05));
    });

    test('falls back to the most open direction when no door is found', () {
      final map = EnvironmentMap();
      fillOpenSpace(map);

      final resolved = resolver.resolveAll(
        requests: [exitRequest()],
        map: map,
      ).single;

      expect(resolved.anchor, PlacementAnchor.measuredFloor);
      expect(resolved.door, isNull);
      // Capped low on purpose: this is "the most open direction", not a door,
      // and the UI must not claim otherwise.
      expect(resolved.confidence, lessThanOrEqualTo(0.4));
    });

    test('uses the authored position when the room was never scanned', () {
      final map = EnvironmentMap(); // nothing ingested
      final resolved = resolver.resolveAll(
        requests: [exitRequest(bearing: 1.0)],
        map: map,
      ).single;

      expect(resolved.anchor, PlacementAnchor.authoredFallback);
      expect(resolved.isAnchoredToRealFeature, isFalse);
      expect(
        math.atan2(resolved.worldPosition.y, resolved.worldPosition.x),
        closeTo(1.0, 1e-6),
      );
    });

    test('a hazard is never placed in a doorway', () {
      final map = mapWithDoors([doorAt(bearing: 0.6, distance: 6)]);

      final resolved = resolver.resolveAll(
        requests: [
          const PlacementRequest(
            id: 'fire',
            kind: PlacementKind.hazard,
            // Deliberately aimed straight at the door.
            preferredBearingRadians: 0.6,
            preferredDistanceMetres: 5,
          ),
        ],
        map: map,
      ).single;

      final bearing = math.atan2(
        resolved.worldPosition.y,
        resolved.worldPosition.x,
      );
      // Putting the fire in the exit would teach the opposite of the lesson.
      expect((bearing - 0.6).abs(), greaterThan(0.3));
    });

    test('content is pulled in to fit the measured space', () {
      final map = EnvironmentMap();
      // A cramped room: obstructions about 3 m out in every direction.
      final columns = [
        for (var i = 0; i < 32; i++)
          ColumnBoundary(column: i, boundaryRow: 16, confidence: 0.8),
      ];
      for (var step = 0; step < 24; step++) {
        map.ingest(
          floor: FloorScan(columns: columns, gridHeight: 24),
          doors: const [],
          camera: cameraFacing(step / 24 * 2 * math.pi),
          ground: ground,
        );
      }

      final resolved = resolver.resolveAll(
        requests: [
          const PlacementRequest(
            id: 'fire',
            kind: PlacementKind.hazard,
            preferredBearingRadians: 0,
            // Asks for 9 m in a room that does not have 9 m.
            preferredDistanceMetres: 9,
          ),
        ],
        map: map,
      ).single;

      final distance = math.sqrt(
        resolved.worldPosition.x * resolved.worldPosition.x +
            resolved.worldPosition.y * resolved.worldPosition.y,
      );
      expect(distance, lessThan(9));
      expect(distance, greaterThanOrEqualTo(1.5));
    });

    test('everything lands on the floor plane', () {
      final map = mapWithDoors([doorAt(bearing: 1.0, distance: 6)]);

      final resolved = resolver.resolveAll(
        requests: [
          exitRequest(),
          const PlacementRequest(
            id: 'fire',
            kind: PlacementKind.hazard,
            preferredBearingRadians: 2.5,
            preferredDistanceMetres: 5,
          ),
          const PlacementRequest(
            id: 'extinguisher',
            kind: PlacementKind.equipment,
            preferredBearingRadians: 4.0,
            preferredDistanceMetres: 4,
            heightAboveFloorMetres: 1.1,
          ),
        ],
        map: map,
      );

      expect(resolved[0].worldPosition.z, closeTo(-1.5, 1e-6));
      expect(resolved[1].worldPosition.z, closeTo(-1.5, 1e-6));
      // The extinguisher is mounted at 1.1 m, so it sits above the floor.
      expect(resolved[2].worldPosition.z, closeTo(-0.4, 1e-6));
    });
  });
}
