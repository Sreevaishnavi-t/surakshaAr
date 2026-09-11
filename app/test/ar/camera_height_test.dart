import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/environment/camera_height.dart';
import 'package:surakshaar/ar/environment/ground_plane.dart';

/// The camera height is the one number that scales the whole scene: every
/// distance the engine reports is a ray intersected with a plane this far below
/// the camera. These tests pin the properties that matter for that job rather
/// than the exact constants, which are estimates and may be refined.
void main() {
  group('CameraHeight.cameraHeightFor', () {
    test('a taller worker always yields a higher camera', () {
      for (final hold in PhoneHold.values) {
        var previous = double.negativeInfinity;

        // One sample per centimetre, matching the slider's own divisions.
        for (var cm = 130; cm <= 210; cm++) {
          final height = CameraHeight.cameraHeightFor(
            bodyHeightMetres: cm / 100,
            hold: hold,
          );
          expect(
            height,
            greaterThan(previous),
            reason: 'height went backwards at $cm cm holding $hold',
          );
          previous = height;
        }
      }
    });

    test('holding the phone up puts it above holding it at chest', () {
      for (var cm = 130; cm <= 210; cm += 5) {
        final body = cm / 100;
        final up = CameraHeight.cameraHeightFor(
          bodyHeightMetres: body,
          hold: PhoneHold.atEyeLevel,
        );
        final chest = CameraHeight.cameraHeightFor(
          bodyHeightMetres: body,
          hold: PhoneHold.atChestLevel,
        );
        expect(up, greaterThan(chest), reason: 'at $cm cm');
      }
    });

    test('an average worker at chest hold lands in the low 1.3s', () {
      final height = CameraHeight.cameraHeightFor(
        bodyHeightMetres: CameraHeight.defaultBodyHeightMetres,
        hold: PhoneHold.atChestLevel,
      );

      // Sanity band, not a spot value: the old hardcoded 1.45 m was an
      // unmeasured guess that sat too high, and this test exists to notice if a
      // future edit quietly walks it back up there.
      expect(height, inInclusiveRange(1.25, 1.36));
    });

    test('the camera never ends up below the phone-holder', () {
      for (var cm = 130; cm <= 210; cm += 5) {
        final body = cm / 100;
        for (final hold in PhoneHold.values) {
          final height = CameraHeight.cameraHeightFor(
            bodyHeightMetres: body,
            hold: hold,
          );
          expect(height, lessThan(body), reason: 'above the crown at $cm cm');
          expect(height, greaterThan(body * 0.5), reason: 'absurdly low at $cm cm');
        }
      }
    });
  });

  group('CameraHeight.forWorker', () {
    test('reports the height as stated, not assumed', () {
      final ground = CameraHeight.forWorker(
        bodyHeightMetres: 1.72,
        hold: PhoneHold.atEyeLevel,
      );

      expect(ground.source, GroundHeightSource.stated);
      expect(ground.isMeasured, isTrue);
    });

    test('the clamp is a guard, not a shaper, across the slider range', () {
      // Every answer the UI can produce should already be plausible. If the
      // clamp ever starts biting inside this range, the model has drifted and
      // the slider would silently stop responding at one end.
      for (var cm = 130; cm <= 210; cm++) {
        for (final hold in PhoneHold.values) {
          final body = cm / 100;
          final raw = CameraHeight.cameraHeightFor(
            bodyHeightMetres: body,
            hold: hold,
          );
          final ground = CameraHeight.forWorker(
            bodyHeightMetres: body,
            hold: hold,
          );
          expect(
            ground.cameraHeightMetres,
            closeTo(raw, 1e-9),
            reason: 'clamped at $cm cm holding $hold',
          );
          expect(GroundPlane.isPlausibleHeight(raw), isTrue);
        }
      }
    });

    test('a nonsense stature is still clamped to something usable', () {
      final tiny = CameraHeight.forWorker(
        bodyHeightMetres: 0.2,
        hold: PhoneHold.atChestLevel,
      );
      final huge = CameraHeight.forWorker(
        bodyHeightMetres: 4.0,
        hold: PhoneHold.atEyeLevel,
      );

      expect(tiny.cameraHeightMetres, GroundPlane.minHeightMetres);
      expect(huge.cameraHeightMetres, GroundPlane.maxHeightMetres);
    });
  });
}
