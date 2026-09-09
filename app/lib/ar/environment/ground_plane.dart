import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:vector_math/vector_math_64.dart';

import '../scene/ar_camera.dart';

/// How the camera's height above the floor came to be known.
enum GroundHeightSource {
  /// A standing adult holding a phone at chest height. A guess, and labelled
  /// as one in the UI.
  assumed,

  /// Derived from the worker aiming at a floor point during calibration.
  measured,

  /// Taken from a detected marker of known physical size and mounting height.
  marker,
}

/// The floor, as a plane in world space.
///
/// The orientation of this plane is not estimated — it is *known*. The device
/// pose is gravity-referenced, so world +Z is genuinely up and the floor is
/// genuinely horizontal. That is the whole reason markerless ground placement
/// is tractable on a phone with no depth sensor and no ARCore: of the four
/// numbers that define a plane, gravity hands us three for free, and only the
/// camera's height above it has to be found.
///
/// The camera sits at the world origin (this engine is 3-DoF — it rotates but
/// never translates), so the floor is the plane `z == -cameraHeightMetres`.
class GroundPlane {
  const GroundPlane({
    required this.cameraHeightMetres,
    this.source = GroundHeightSource.assumed,
  });

  /// Height of the phone above the floor, in metres.
  final double cameraHeightMetres;

  final GroundHeightSource source;

  /// A worker of average height holding a phone up to look through it.
  ///
  /// Slightly below eye level on purpose: people hold a phone at chest-to-chin
  /// height when using it as a viewfinder, not pressed against their eye.
  static const GroundPlane assumed = GroundPlane(cameraHeightMetres: 1.45);

  /// Heights outside this range are rejected as bad measurements. A phone is
  /// not held at ankle height, and not two and a half metres up.
  static const double minHeightMetres = 0.6;
  static const double maxHeightMetres = 2.2;

  bool get isMeasured => source != GroundHeightSource.assumed;

  GroundPlane copyWith({double? cameraHeightMetres, GroundHeightSource? source}) =>
      GroundPlane(
        cameraHeightMetres: cameraHeightMetres ?? this.cameraHeightMetres,
        source: source ?? this.source,
      );

  /// Clamps a candidate height and reports whether it was plausible.
  static bool isPlausibleHeight(double metres) =>
      metres.isFinite && metres >= minHeightMetres && metres <= maxHeightMetres;

  /// Where a ray leaving the camera meets the floor, in world space.
  ///
  /// Returns null when the ray points at or above the horizon, which is the
  /// common case for the upper half of the frame — those pixels are wall,
  /// ceiling or sky and no amount of arithmetic will make them floor.
  Vector3? intersect(Vector3 worldRay) {
    // Ray must be heading downward to ever reach the floor.
    if (worldRay.z >= -1e-6) return null;

    final t = -cameraHeightMetres / worldRay.z;
    if (!t.isFinite || t <= 0) return null;

    final hit = worldRay * t;
    // Absurdly grazing rays produce kilometre-distant hits that are numerically
    // valid and physically meaningless.
    if (hit.length > 60) return null;
    return hit;
  }

  /// Horizontal distance from the worker to where a screen pixel meets the floor.
  ///
  /// This is the measurement that turns a detected floor/wall edge into a real
  /// number of metres of usable space.
  double? distanceAt(ArCamera camera, Offset screenPoint) {
    final hit = intersect(camera.rayThrough(screenPoint));
    if (hit == null) return null;
    return math.sqrt(hit.x * hit.x + hit.y * hit.y);
  }

  /// A world-space floor point at [distanceMetres] along a world [bearingRadians].
  ///
  /// Bearing is measured in the world frame from +X, the same convention as
  /// [DevicePose.yaw], so it composes directly with the calibration heading.
  Vector3 pointAt({
    required double bearingRadians,
    required double distanceMetres,
  }) {
    return Vector3(
      distanceMetres * math.cos(bearingRadians),
      distanceMetres * math.sin(bearingRadians),
      -cameraHeightMetres,
    );
  }

  /// Estimates camera height from a floor point the worker identified.
  ///
  /// Used by the calibration step: the worker aims the phone at a spot on the
  /// floor a known pace or two ahead and taps. The ray through the crosshair has
  /// a known depression angle, so `height = distance × tan(depression)`.
  ///
  /// Returns null when the geometry cannot support a measurement — aiming at or
  /// above the horizon, where tan explodes and a tiny hand tremor would swing
  /// the answer by metres.
  static double? heightFromAimedFloorPoint({
    required ArCamera camera,
    required Offset screenPoint,
    required double assumedDistanceMetres,
  }) {
    final ray = camera.rayThrough(screenPoint);
    final horizontal = math.sqrt(ray.x * ray.x + ray.y * ray.y);
    if (horizontal < 1e-6) return null;

    // Positive when the ray points below level.
    final depression = math.atan2(-ray.z, horizontal);

    // Below about 8° the estimate is dominated by hand shake: at 5° a 1°
    // tremor moves the answer by roughly 20%.
    if (depression < 8 * math.pi / 180) return null;

    final height = assumedDistanceMetres * math.tan(depression);
    return isPlausibleHeight(height) ? height : null;
  }
}
