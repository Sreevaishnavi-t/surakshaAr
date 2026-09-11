import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/environment/door_detector.dart';
import 'package:surakshaar/ar/environment/environment_map.dart';
import 'package:surakshaar/ar/pose/device_pose.dart';
import 'package:surakshaar/ar/scene/ar_camera.dart';
import 'package:surakshaar/features/session/widgets/door_overlay.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

/// A phone held upright, facing world +X.
ArCamera upright() => ArCamera(
      pose: DevicePose.upright(),
      intrinsics: ArCameraIntrinsics.fallback,
      previewSize: const Size(480, 720),
      viewportSize: const Size(384, 832),
    );

/// A door standing on the floor, [distance] metres away on the given bearing.
MappedDoor doorAt({
  required double distance,
  double bearingRadians = 0,
  double widthMetres = 0.9,
  double heightMetres = 2.05,
  int sightings = 1,
}) {
  final base = Vector3(
    distance * math.cos(bearingRadians),
    distance * math.sin(bearingRadians),
    -1.30,
  );

  final door = MappedDoor(
    seed: DoorCandidate(
      basePoint: base,
      widthMetres: widthMetres,
      heightMetres: heightMetres,
      distanceMetres: distance,
      bearingRadians: bearingRadians,
      score: 0.8,
      isOpening: true,
    ),
  );

  for (var i = 1; i < sightings; i++) {
    door.merge(
      DoorCandidate(
        basePoint: base,
        widthMetres: widthMetres,
        heightMetres: heightMetres,
        distanceMetres: distance,
        bearingRadians: bearingRadians,
        score: 0.8,
        isOpening: true,
      ),
    );
  }

  return door;
}

void main() {
  group('DoorOverlayPainter.quadFor', () {
    test('puts a doorway straight ahead squarely in the middle', () {
      final camera = upright();
      final quad = DoorOverlayPainter.quadFor(camera, doorAt(distance: 4));

      expect(quad, isNotNull);
      final [baseLeft, topLeft, topRight, baseRight] = quad!;

      // Corner order is the contract the painter's label code relies on.
      expect(topLeft.dy, lessThan(baseLeft.dy), reason: 'top above base');
      expect(topRight.dy, lessThan(baseRight.dy), reason: 'top above base');

      final centre = camera.viewportCenter.dx;
      expect((baseLeft.dx + baseRight.dx) / 2, closeTo(centre, 1));
      expect((topLeft.dx + topRight.dx) / 2, closeTo(centre, 1));

      // The frame is vertical in the world, so its sides are vertical on screen
      // for a camera that is not rolled.
      expect(topLeft.dx, closeTo(baseLeft.dx, 0.5));
      expect(topRight.dx, closeTo(baseRight.dx, 0.5));
    });

    test('a nearer doorway draws larger', () {
      final camera = upright();

      double widthOnScreen(double distance) {
        final quad = DoorOverlayPainter.quadFor(camera, doorAt(distance: distance))!;
        return (quad[0].dx - quad[3].dx).abs();
      }

      final near = widthOnScreen(2);
      final far = widthOnScreen(6);

      expect(near, greaterThan(far));
      // Perspective is 1/depth, so tripling the distance thirds the size.
      expect(far, closeTo(near / 3, 1.0));
    });

    test('refuses to draw a doorway behind the worker', () {
      // Nothing crashes and nothing is drawn: a quad with a corner projected
      // from behind the camera folds inside out, and a confidently wrong shape
      // in a diagnostic is worse than an absent one.
      final quad = DoorOverlayPainter.quadFor(
        upright(),
        doorAt(distance: 4, bearingRadians: 3.14159),
      );

      expect(quad, isNull);
    });

    test('a doorway to one side is drawn to that side', () {
      final camera = upright();
      // +Y is the worker's left, and screen X grows to the right, so a door on
      // the left must land left of centre. Getting this backwards is the exact
      // failure that sends a worker the wrong way in a fire drill.
      final left = DoorOverlayPainter.quadFor(
        camera,
        doorAt(distance: 5, bearingRadians: 0.18),
      )!;

      final midX = (left[0].dx + left[3].dx) / 2;
      expect(midX, lessThan(camera.viewportCenter.dx));
    });
  });
}
