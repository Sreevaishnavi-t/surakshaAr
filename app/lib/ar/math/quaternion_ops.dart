import 'package:vector_math/vector_math_64.dart';

/// Rotates [v] by [q] using the standard Hamilton convention.
///
/// **Do not replace this with `Quaternion.rotated`.** `vector_math` rotates
/// vectors by the *conjugate* of the quaternion, which contradicts its own
/// `asRotationMatrix`. The two disagree:
///
/// ```dart
/// final q = Quaternion.axisAngle(Vector3(0, 0, 1), 0.5);
/// q.rotated(Vector3(1, 0, 0));   // (0.878, -0.479, 0) — clockwise
/// rotateVector(q, Vector3(1, 0, 0)); // (0.878, 0.479, 0) — right-handed
/// ```
///
/// Android's sensor stack hands us standard-convention quaternions, and every
/// derivation in this engine is written against textbook right-handed rotation.
/// Adopting the library's inverted convention would flip the sign of the view
/// direction, the calibration offset and the world-to-device transform at once —
/// producing a scene that tracks smoothly and points the wrong way, which is far
/// harder to spot than an outright crash. `quaternion_convention_test.dart`
/// pins this down.
///
/// Uses the standard three-cross-product form:
///   `v' = v + 2w(u × v) + 2(u × (u × v))`, where `u` is the vector part.
/// Cheaper than building a rotation matrix for a single vector.
Vector3 rotateVector(Quaternion q, Vector3 v) {
  final ux = q.x, uy = q.y, uz = q.z, w = q.w;

  // t = 2 * (u × v)
  final tx = 2 * (uy * v.z - uz * v.y);
  final ty = 2 * (uz * v.x - ux * v.z);
  final tz = 2 * (ux * v.y - uy * v.x);

  // v' = v + w*t + (u × t)
  return Vector3(
    v.x + w * tx + (uy * tz - uz * ty),
    v.y + w * ty + (uz * tx - ux * tz),
    v.z + w * tz + (ux * ty - uy * tx),
  );
}

/// Rotates [v] by the inverse of [q].
///
/// For a unit quaternion the inverse is the conjugate, so this is the cheap way
/// to go from world space into device space.
Vector3 rotateVectorInverse(Quaternion q, Vector3 v) =>
    rotateVector(Quaternion(-q.x, -q.y, -q.z, q.w), v);
