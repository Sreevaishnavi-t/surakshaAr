import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/pose/device_pose.dart';
import 'package:surakshaar/ar/scene/ar_camera.dart';
import 'package:surakshaar/ar/scene/scene_graph.dart';
import 'package:vector_math/vector_math_64.dart';

/// Builds the pose of a phone held upright like a window, facing [yaw].
///
/// This is the pose that actually matters. The identity quaternion corresponds
/// to a phone lying flat on a table with the camera pointing at the floor, so a
/// test written against identity would prove nothing about how the app is used.
///
/// Device axes expressed in world coordinates:
///   X (screen right)      -> ( sin y, -cos y, 0)
///   Y (screen up)         -> ( 0,      0,     1)
///   Z (out of the screen) -> (-cos y, -sin y, 0)
DevicePose uprightPose(double yaw, {PoseSource source = PoseSource.gameRotationVector}) {
  final sy = math.sin(yaw);
  final cy = math.cos(yaw);

  // Matrix3 is column-major in vector_math: each column is a device axis in world space.
  final rotation = Matrix3(
    sy, -cy, 0, // device X
    0, 0, 1, // device Y
    -cy, -sy, 0, // device Z
  );

  return DevicePose(
    worldFromDevice: Quaternion.fromRotation(rotation),
    source: source,
    displayRotationDegrees: 0,
    timestamp: Duration.zero,
  );
}

ArCamera cameraFacing(
  double yaw, {
  Size viewport = const Size(1080, 1920),
  Size preview = const Size(720, 1280),
}) {
  final pose = uprightPose(yaw);
  return ArCamera(
    pose: pose,
    intrinsics: ArCameraIntrinsics.fallback,
    previewSize: preview,
    viewportSize: viewport,
    worldFromScene: ArCamera.calibrationFromYaw(pose.yaw),
  );
}

void main() {
  group('DevicePose', () {
    test('reads the sensor quaternion as w-first', () {
      // Android writes [w, x, y, z]; vector_math takes (x, y, z, w). Mixing them
      // up yields a scene that rotates plausibly but wrongly, so it is pinned.
      final pose = DevicePose.fromSensorQuaternion(
        w: 0.5,
        x: 0.5,
        y: 0.5,
        z: 0.5,
        source: PoseSource.gameRotationVector,
        displayRotationDegrees: 0,
        timestamp: Duration.zero,
      );

      expect(pose.worldFromDevice.w, closeTo(0.5, 1e-9));
      expect(pose.worldFromDevice.x, closeTo(0.5, 1e-9));
    });

    test('normalises a quaternion that arrives slightly off unit length', () {
      final pose = DevicePose.fromSensorQuaternion(
        w: 2, x: 0, y: 0, z: 0,
        source: PoseSource.gameRotationVector,
        displayRotationDegrees: 0,
        timestamp: Duration.zero,
      );

      expect(pose.worldFromDevice.length, closeTo(1.0, 1e-9));
    });

    test('an upright phone reports the yaw it is facing and zero pitch', () {
      for (final yaw in [0.0, math.pi / 2, math.pi, -math.pi / 3]) {
        final pose = uprightPose(yaw);
        // atan2 wraps, so compare direction vectors rather than raw angles.
        expect(math.cos(pose.yaw), closeTo(math.cos(yaw), 1e-6));
        expect(math.sin(pose.yaw), closeTo(math.sin(yaw), 1e-6));
        expect(pose.pitch, closeTo(0, 1e-6));
      }
    });

    test('view direction is horizontal when the phone is held upright', () {
      final direction = uprightPose(0).viewDirection;
      expect(direction.x, closeTo(1, 1e-6));
      expect(direction.y, closeTo(0, 1e-6));
      expect(direction.z, closeTo(0, 1e-6));
    });
  });

  group('ArCamera projection', () {
    test('content authored straight ahead lands at the centre of the viewport', () {
      // The whole calibration chain in one assertion: scene forward (-Y) must
      // map onto whatever heading the worker happened to be facing.
      for (final yaw in [0.0, 1.1, -2.4, math.pi]) {
        final camera = cameraFacing(yaw);
        final projected = camera.project(
          scenePlacement(bearingDegrees: 0, distanceMetres: 6),
        );

        expect(projected, isNotNull, reason: 'yaw $yaw should be visible');
        expect(projected!.screen.dx, closeTo(camera.viewportCenter.dx, 0.5));
        expect(projected.screen.dy, closeTo(camera.viewportCenter.dy, 0.5));
        expect(projected.depth, closeTo(6, 1e-6));
      }
    });

    test('culls anything behind the camera', () {
      final camera = cameraFacing(0);
      final behind = camera.project(
        scenePlacement(bearingDegrees: 180, distanceMetres: 6),
      );
      expect(behind, isNull);
    });

    test('on-screen size halves when distance doubles', () {
      final camera = cameraFacing(0);
      final near = camera.project(scenePlacement(bearingDegrees: 0, distanceMetres: 4))!;
      final far = camera.project(scenePlacement(bearingDegrees: 0, distanceMetres: 8))!;

      expect(far.scale, closeTo(near.scale / 2, 1e-6));
    });

    test('a target to the right projects right of centre, and vice versa', () {
      final camera = cameraFacing(0);
      final right = camera.project(
        scenePlacement(bearingDegrees: 20, distanceMetres: 6),
      )!;
      final left = camera.project(
        scenePlacement(bearingDegrees: -20, distanceMetres: 6),
      )!;

      expect(right.screen.dx, greaterThan(camera.viewportCenter.dx));
      expect(left.screen.dx, lessThan(camera.viewportCenter.dx));
      // Symmetric about the centre.
      expect(
        right.screen.dx - camera.viewportCenter.dx,
        closeTo(camera.viewportCenter.dx - left.screen.dx, 0.5),
      );
    });

    test('something above eye level projects above the centre line', () {
      final camera = cameraFacing(0);
      final high = camera.project(
        scenePlacement(bearingDegrees: 0, distanceMetres: 6, heightMetres: 1.5),
      )!;

      // Screen Y grows downward, so "higher" means a smaller dy.
      expect(high.screen.dy, lessThan(camera.viewportCenter.dy));
    });

    test('angleTo is zero dead ahead and grows with bearing', () {
      final camera = cameraFacing(0.7);

      expect(
        camera.angleTo(scenePlacement(bearingDegrees: 0, distanceMetres: 5)),
        closeTo(0, 1e-6),
      );
      expect(
        camera.angleTo(scenePlacement(bearingDegrees: 30, distanceMetres: 5)),
        closeTo(30 * math.pi / 180, 1e-6),
      );
      expect(
        camera.angleTo(scenePlacement(bearingDegrees: 180, distanceMetres: 5)),
        closeTo(math.pi, 1e-6),
      );
    });

    test('turning the worker sweeps anchored content the opposite way', () {
      // The core promise of the engine: content is fixed to the world, so
      // rotating the phone moves it across the screen rather than dragging it
      // along. Note that world yaw increases counter-clockwise seen from above,
      // which is the worker turning to their *left* — so a larger yaw must push
      // content to the right.
      final target = scenePlacement(bearingDegrees: 0, distanceMetres: 6);
      final worldFromScene = ArCamera.calibrationFromYaw(0);

      ArCamera cameraAt(double yaw) => ArCamera(
            pose: uprightPose(yaw),
            intrinsics: ArCameraIntrinsics.fallback,
            previewSize: const Size(720, 1280),
            viewportSize: const Size(1080, 1920),
            worldFromScene: worldFromScene,
          );

      final centred = cameraAt(0).project(target)!;
      final turnedLeft = cameraAt(0.2).project(target)!;
      final turnedRight = cameraAt(-0.2).project(target)!;

      expect(turnedLeft.screen.dx, greaterThan(centred.screen.dx));
      expect(turnedRight.screen.dx, lessThan(centred.screen.dx));

      // Symmetric: equal and opposite turns displace content equally.
      expect(
        turnedLeft.screen.dx - centred.screen.dx,
        closeTo(centred.screen.dx - turnedRight.screen.dx, 0.5),
      );

      // Rotation must not translate the scene: the content stays exactly 6 m
      // away in world space however the worker turns.
      final camera = cameraAt(0.2);
      expect(camera.worldPointOf(target).length, closeTo(6, 1e-9));

      // `depth` is z-depth along the view axis, not radial distance, so it
      // shrinks by cos(angle) as the target moves off-axis. That is the correct
      // pinhole behaviour and is what makes the 1/depth scaling look right.
      expect(turnedLeft.depth, closeTo(6 * math.cos(0.2), 1e-6));
    });

    test('a full turn brings anchored content back to where it started', () {
      final target = scenePlacement(bearingDegrees: 0, distanceMetres: 6);
      final worldFromScene = ArCamera.calibrationFromYaw(0);

      ArCamera cameraAt(double yaw) => ArCamera(
            pose: uprightPose(yaw),
            intrinsics: ArCameraIntrinsics.fallback,
            previewSize: const Size(720, 1280),
            viewportSize: const Size(1080, 1920),
            worldFromScene: worldFromScene,
          );

      final start = cameraAt(0).project(target)!;
      final wrapped = cameraAt(2 * math.pi).project(target)!;

      expect(wrapped.screen.dx, closeTo(start.screen.dx, 0.01));
      expect(wrapped.screen.dy, closeTo(start.screen.dy, 0.01));
    });
  });

  group('ArCameraIntrinsics', () {
    test('fallback geometry is a plausible phone field of view', () {
      final fov = ArCameraIntrinsics.fallback.horizontalFovRad * 180 / math.pi;
      expect(fov, greaterThan(50));
      expect(fov, lessThan(80));
      expect(ArCameraIntrinsics.fallback.isMeasured, isFalse);
    });

    test('parses Camera2 metadata and rejects incomplete payloads', () {
      final parsed = ArCameraIntrinsics.fromPlatform({
        'focalLengthMm': 4.7,
        'sensorWidthMm': 6.4,
        'sensorHeightMm': 4.8,
      });

      expect(parsed, isNotNull);
      expect(parsed!.isMeasured, isTrue);
      expect(parsed.focalLengthMm, 4.7);

      expect(ArCameraIntrinsics.fromPlatform(null), isNull);
      expect(ArCameraIntrinsics.fromPlatform({'focalLengthMm': 4.7}), isNull);
      // Zero or negative geometry is nonsense and must not reach the projection.
      expect(
        ArCameraIntrinsics.fromPlatform({
          'focalLengthMm': 0,
          'sensorWidthMm': 6.4,
          'sensorHeightMm': 4.8,
        }),
        isNull,
      );
    });

    test('accounts for the cover-fit crop between preview and viewport', () {
      const intrinsics = ArCameraIntrinsics.fallback;

      // A viewport taller than the preview must scale the preview up to cover,
      // which lengthens the effective focal length in viewport pixels.
      final tight = intrinsics.focalPixels(
        previewSize: const Size(720, 1280),
        viewportSize: const Size(720, 1280),
      );
      final covered = intrinsics.focalPixels(
        previewSize: const Size(720, 1280),
        viewportSize: const Size(1080, 1920),
      );

      expect(covered, greaterThan(tight));
      expect(covered / tight, closeTo(1.5, 1e-6));
    });

    test('calibration scale trims the field of view proportionally', () {
      const intrinsics = ArCameraIntrinsics.fallback;
      final base = intrinsics.focalPixels(
        previewSize: const Size(720, 1280),
        viewportSize: const Size(1080, 1920),
      );
      final trimmed = intrinsics.focalPixels(
        previewSize: const Size(720, 1280),
        viewportSize: const Size(1080, 1920),
        calibrationScale: 1.25,
      );

      expect(trimmed, closeTo(base * 1.25, 1e-9));
    });
  });

  group('scenePlacement', () {
    test('bearing 0 is straight ahead along scene +Y', () {
      final ahead = scenePlacement(bearingDegrees: 0, distanceMetres: 5);
      expect(ahead.x, closeTo(0, 1e-9));
      expect(ahead.y, closeTo(5, 1e-9));
      expect(ahead.z, closeTo(0, 1e-9));
    });

    test('positive bearing goes to the right, negative to the left', () {
      expect(scenePlacement(bearingDegrees: 90, distanceMetres: 3).x, closeTo(3, 1e-9));
      expect(scenePlacement(bearingDegrees: -90, distanceMetres: 3).x, closeTo(-3, 1e-9));
    });

    test('preserves distance regardless of bearing', () {
      for (final bearing in [0.0, 37.0, 145.0, -88.0]) {
        final placed = scenePlacement(bearingDegrees: bearing, distanceMetres: 7);
        expect(placed.length, closeTo(7, 1e-9));
      }
    });
  });
}
