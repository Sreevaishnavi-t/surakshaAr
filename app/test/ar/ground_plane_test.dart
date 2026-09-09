import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/environment/ground_plane.dart';
import 'package:surakshaar/ar/pose/device_pose.dart';
import 'package:surakshaar/ar/scene/ar_camera.dart';
import 'package:vector_math/vector_math_64.dart';

/// A phone held upright facing [yaw], optionally tilted [pitch] radians
/// (negative looks down at the floor).
DevicePose pose({double yaw = 0, double pitch = 0}) {
  final base = DevicePose.upright(yawRadians: yaw);
  if (pitch == 0) return base;

  // Rotate about the device's own right axis to tilt the camera up or down.
  final right = Vector3(math.sin(yaw), -math.cos(yaw), 0);
  final tilt = Quaternion.axisAngle(right, pitch);
  return base.copyWith(worldFromDevice: (tilt * base.worldFromDevice)..normalize());
}

ArCamera cameraWith(DevicePose p) => ArCamera(
      pose: p,
      intrinsics: ArCameraIntrinsics.fallback,
      previewSize: const Size(480, 720),
      viewportSize: const Size(384, 832),
    );

void main() {
  group('rayThrough', () {
    test('the viewport centre maps to the direction the camera faces', () {
      for (final yaw in [0.0, 1.2, -2.0]) {
        final camera = cameraWith(pose(yaw: yaw));
        final ray = camera.rayThrough(camera.viewportCenter);
        final forward = camera.pose.viewDirection;

        expect(ray.dot(forward), closeTo(1, 1e-9), reason: 'yaw $yaw');
      }
    });

    test('round-trips against projectWorld', () {
      // The strongest available check: unproject a pixel, walk out along the
      // ray, project the result and land back on the same pixel.
      final camera = cameraWith(pose(yaw: 0.6, pitch: -0.3));

      for (final point in const [
        Offset(120, 300),
        Offset(300, 700),
        Offset(192, 416),
      ]) {
        final ray = camera.rayThrough(point);
        final projected = camera.projectWorld(ray * 8.0);

        expect(projected, isNotNull);
        expect(projected!.screen.dx, closeTo(point.dx, 0.01));
        expect(projected.screen.dy, closeTo(point.dy, 0.01));
      }
    });

    test('always returns a unit vector', () {
      final camera = cameraWith(pose(yaw: 0.4, pitch: -0.5));
      for (final point in const [Offset(0, 0), Offset(384, 832), Offset(50, 700)]) {
        expect(camera.rayThrough(point).length, closeTo(1, 1e-9));
      }
    });
  });

  group('horizonY', () {
    test('sits at the vertical centre when the phone is held level', () {
      final camera = cameraWith(pose(yaw: 0.9));
      expect(camera.horizonY(), closeTo(camera.viewportCenter.dy, 0.01));
    });

    test('rises up the screen as the phone tilts down', () {
      // Tilting down brings more floor into frame, so the horizon moves toward
      // the top of the viewport — a smaller dy.
      final level = cameraWith(pose()).horizonY()!;
      final tilted = cameraWith(pose(pitch: -0.4)).horizonY()!;

      expect(tilted, lessThan(level));
    });
  });

  group('GroundPlane.intersect', () {
    test('a ray aimed at the horizon never reaches the floor', () {
      const ground = GroundPlane.assumed;
      // Perfectly level, and just above level.
      expect(ground.intersect(Vector3(1, 0, 0)), isNull);
      expect(ground.intersect(Vector3(1, 0, 0.2)), isNull);
    });

    test('straight down lands directly under the worker', () {
      const ground = GroundPlane(cameraHeightMetres: 1.5);
      final hit = ground.intersect(Vector3(0, 0, -1))!;

      expect(hit.x, closeTo(0, 1e-9));
      expect(hit.y, closeTo(0, 1e-9));
      expect(hit.z, closeTo(-1.5, 1e-9));
    });

    test('a 45 degree ray lands one camera-height ahead', () {
      const ground = GroundPlane(cameraHeightMetres: 1.5);
      final hit = ground.intersect(Vector3(1, 0, -1).normalized())!;

      expect(hit.x, closeTo(1.5, 1e-9));
      expect(hit.z, closeTo(-1.5, 1e-9));
    });

    test('rejects grazing rays that land absurdly far away', () {
      const ground = GroundPlane.assumed;
      // Half a degree below level reaches past 150 m — geometrically valid,
      // physically meaningless, and dominated by sensor noise.
      final grazing = Vector3(1, 0, -math.tan(0.5 * math.pi / 180)).normalized();
      expect(ground.intersect(grazing), isNull);
    });
  });

  group('distanceAt', () {
    test('the bottom of the frame is nearer than the middle', () {
      final camera = cameraWith(pose(pitch: -0.35));
      const ground = GroundPlane.assumed;

      final low = ground.distanceAt(camera, const Offset(192, 800))!;
      final high = ground.distanceAt(camera, const Offset(192, 500))!;

      expect(low, lessThan(high));
    });

    test('agrees with an independent trigonometric calculation', () {
      // Camera pitched 30 degrees down; the ray through the exact centre of the
      // viewport is therefore 30 degrees below level, so the floor distance is
      // height / tan(30).
      const pitch = -30 * math.pi / 180;
      final camera = cameraWith(pose(pitch: pitch));
      const ground = GroundPlane(cameraHeightMetres: 1.5);

      final measured = ground.distanceAt(camera, camera.viewportCenter)!;
      final expected = 1.5 / math.tan(30 * math.pi / 180);

      expect(measured, closeTo(expected, 1e-6));
    });

    test('anything above the horizon has no floor distance', () {
      final camera = cameraWith(pose(pitch: -0.35));
      const ground = GroundPlane.assumed;

      final horizon = camera.horizonY()!;
      expect(ground.distanceAt(camera, Offset(192, horizon - 40)), isNull);
    });
  });

  group('pointAt', () {
    test('places content on the floor at the requested distance', () {
      const ground = GroundPlane(cameraHeightMetres: 1.5);
      final point = ground.pointAt(bearingRadians: 0.7, distanceMetres: 4);

      expect(point.z, closeTo(-1.5, 1e-9));
      expect(math.sqrt(point.x * point.x + point.y * point.y), closeTo(4, 1e-9));
    });

    test('a floor point projects below the horizon, as it must', () {
      final camera = cameraWith(pose(yaw: 0.0));
      const ground = GroundPlane(cameraHeightMetres: 1.5);

      final projected = camera.projectWorld(
        ground.pointAt(bearingRadians: 0, distanceMetres: 5),
      )!;

      // Screen Y grows downward, so "below the horizon" means a larger dy.
      expect(projected.screen.dy, greaterThan(camera.horizonY()!));
    });
  });

  group('heightFromAimedFloorPoint', () {
    test('recovers the height used to build the geometry', () {
      // Aim 30 degrees down at a point 2.6 m away. A camera at h sees that
      // point when h = 2.6 * tan(30) = 1.50 m.
      const pitch = -30 * math.pi / 180;
      final camera = cameraWith(pose(pitch: pitch));

      final height = GroundPlane.heightFromAimedFloorPoint(
        camera: camera,
        screenPoint: camera.viewportCenter,
        assumedDistanceMetres: 2.6,
      );

      expect(height, isNotNull);
      expect(height!, closeTo(2.6 * math.tan(30 * math.pi / 180), 1e-6));
    });

    test('refuses a near-level aim where hand shake would dominate', () {
      final camera = cameraWith(pose(pitch: -0.05));
      expect(
        GroundPlane.heightFromAimedFloorPoint(
          camera: camera,
          screenPoint: camera.viewportCenter,
          assumedDistanceMetres: 2.5,
        ),
        isNull,
      );
    });

    test('refuses implausible heights', () {
      // Aiming almost straight down at a point 2.5 m away implies the phone is
      // several metres in the air.
      final camera = cameraWith(pose(pitch: -1.4));
      expect(
        GroundPlane.heightFromAimedFloorPoint(
          camera: camera,
          screenPoint: camera.viewportCenter,
          assumedDistanceMetres: 2.5,
        ),
        isNull,
      );
    });
  });
}
