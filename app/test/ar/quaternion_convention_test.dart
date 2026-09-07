import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/math/quaternion_ops.dart';
import 'package:vector_math/vector_math_64.dart';

/// Guards the single most dangerous assumption in the AR engine.
///
/// `vector_math` rotates vectors by the conjugate of the quaternion, so
/// `Quaternion.rotated` disagrees with the same quaternion's
/// `asRotationMatrix`. Android's sensors speak the standard convention, and so
/// does every derivation in this codebase.
///
/// If someone "simplifies" [rotateVector] back to `q.rotated(v)`, the scene will
/// still track smoothly — it will simply point the wrong way, mirrored about the
/// worker. That is a bug that survives a casual demo and fails in a real gallery,
/// which is exactly the kind that deserves a test naming it out loud.
void main() {
  group('quaternion convention', () {
    test('rotateVector is right-handed about +Z', () {
      final q = Quaternion.axisAngle(Vector3(0, 0, 1), math.pi / 2);
      final rotated = rotateVector(q, Vector3(1, 0, 0));

      // Right-handed: +X turns towards +Y.
      expect(rotated.x, closeTo(0, 1e-9));
      expect(rotated.y, closeTo(1, 1e-9));
      expect(rotated.z, closeTo(0, 1e-9));
    });

    test('vector_math disagrees, which is why the helper exists', () {
      final q = Quaternion.axisAngle(Vector3(0, 0, 1), math.pi / 2);

      final ours = rotateVector(q, Vector3(1, 0, 0));
      final theirs = q.rotated(Vector3(1, 0, 0));

      expect(ours.y, closeTo(1, 1e-9));
      // The library turns the opposite way. Documented, not worked around silently.
      expect(theirs.y, closeTo(-1, 1e-9));
    });

    test('rotateVector agrees with the quaternion own rotation matrix', () {
      final q = Quaternion.axisAngle(Vector3(0.3, -0.5, 0.81), 1.17)..normalize();
      final matrix = q.asRotationMatrix();

      for (final v in [
        Vector3(1, 0, 0),
        Vector3(0, 1, 0),
        Vector3(0, 0, 1),
        Vector3(2.3, -1.1, 0.7),
      ]) {
        final viaHelper = rotateVector(q, v);
        final viaMatrix = matrix.transformed(v.clone());

        expect(viaHelper.x, closeTo(viaMatrix.x, 1e-9));
        expect(viaHelper.y, closeTo(viaMatrix.y, 1e-9));
        expect(viaHelper.z, closeTo(viaMatrix.z, 1e-9));
      }
    });

    test('rotateVectorInverse undoes rotateVector', () {
      final q = Quaternion.axisAngle(Vector3(-0.2, 0.9, 0.39), -2.05)..normalize();
      final original = Vector3(1.7, -0.4, 2.2);

      final roundTrip = rotateVectorInverse(q, rotateVector(q, original));

      expect(roundTrip.x, closeTo(original.x, 1e-9));
      expect(roundTrip.y, closeTo(original.y, 1e-9));
      expect(roundTrip.z, closeTo(original.z, 1e-9));
    });

    test('rotation preserves length', () {
      final q = Quaternion.axisAngle(Vector3(1, 2, 3).normalized(), 0.83);
      final v = Vector3(3, -4, 12); // length 13
      expect(rotateVector(q, v).length, closeTo(13, 1e-9));
    });
  });
}
