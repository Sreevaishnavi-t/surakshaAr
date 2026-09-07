import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../math/quaternion_ops.dart';

/// Which sensor produced a pose sample. Surfaced in the UI so a worker (or an
/// evaluator) can see *why* tracking is behaving the way it is.
enum PoseSource {
  /// Gyroscope + accelerometer, no magnetometer. Preferred underground.
  gameRotationVector,

  /// Includes magnetometer. Fine above ground, unreliable near ferrous mass.
  rotationVector,

  /// Dart-side Madgwick AHRS filter, used when neither fused sensor exists.
  madgwickFallback,

  /// No usable motion sensors at all. AR degrades to a static viewport.
  none,
}

extension PoseSourceInfo on PoseSource {
  bool get isMagnetometerDependent => this == PoseSource.rotationVector;

  /// Whether the scene can be trusted to stay put while the worker turns.
  bool get supportsWorldLocking => this != PoseSource.none;
}

/// A single orientation sample.
///
/// Coordinate frames used throughout the AR engine:
///
/// **World frame** — right-handed, +Z up, X/Y horizontal. With
/// [PoseSource.gameRotationVector] the horizontal yaw origin is arbitrary
/// (whatever the device faced when the sensor started), which is exactly what we
/// want: we impose our own origin through calibration or a detected marker
/// rather than depending on magnetic north.
///
/// **Device frame** — Android's convention: +X right along the screen, +Y up
/// along the screen, +Z out of the screen toward the viewer. The rear camera
/// therefore looks down **−Z**.
class DevicePose {
  const DevicePose({
    required this.worldFromDevice,
    required this.source,
    required this.displayRotationDegrees,
    required this.timestamp,
  });

  /// Rotation taking a vector from the device frame into the world frame.
  final Quaternion worldFromDevice;

  final PoseSource source;

  /// Display rotation relative to the device's natural orientation (0/90/180/270).
  final int displayRotationDegrees;

  final Duration timestamp;

  static DevicePose get identity => DevicePose(
        worldFromDevice: Quaternion.identity(),
        source: PoseSource.none,
        displayRotationDegrees: 0,
        timestamp: Duration.zero,
      );

  /// Rotation taking a vector from the world frame into the device frame.
  ///
  /// A rotation quaternion is unit-length, so the inverse is just the conjugate —
  /// cheaper and numerically better behaved than a general inversion.
  Quaternion get deviceFromWorld => worldFromDevice.conjugated();

  /// Unit vector, in world space, along the direction the rear camera points.
  ///
  /// Uses [rotateVector] rather than `Quaternion.rotated` — see the note there;
  /// the library's convention is inverted and would point this backwards.
  Vector3 get viewDirection => rotateVector(worldFromDevice, Vector3(0, 0, -1));

  /// Heading in radians about the world +Z axis, measured from world +X.
  ///
  /// Used to capture the calibration offset when the worker starts a scenario.
  double get yaw {
    final forward = viewDirection;
    if (forward.x == 0 && forward.y == 0) return 0;
    return math.atan2(forward.y, forward.x);
  }

  /// How far the device is tilted from horizontal, in radians. Positive is up.
  ///
  /// Scenarios use this to detect deliberate aiming gestures — pointing an
  /// extinguisher at the base of a fire rather than at the flames.
  double get pitch {
    final forward = viewDirection;
    final horizontal = math.sqrt(forward.x * forward.x + forward.y * forward.y);
    if (forward.z == 0 && horizontal == 0) return 0;
    return math.atan2(forward.z, horizontal);
  }

  DevicePose copyWith({
    Quaternion? worldFromDevice,
    PoseSource? source,
    int? displayRotationDegrees,
    Duration? timestamp,
  }) {
    return DevicePose(
      worldFromDevice: worldFromDevice ?? this.worldFromDevice,
      source: source ?? this.source,
      displayRotationDegrees: displayRotationDegrees ?? this.displayRotationDegrees,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  /// Builds a pose from the `[w, x, y, z]` ordering the Android sensor stack uses.
  ///
  /// Note the reordering: `SensorManager.getQuaternionFromVector` writes
  /// w-first, while `vector_math`'s constructor takes x, y, z, w. Getting this
  /// backwards produces a scene that rotates plausibly but wrongly, so it is
  /// funnelled through this one factory and covered by a test.
  factory DevicePose.fromSensorQuaternion({
    required double w,
    required double x,
    required double y,
    required double z,
    required PoseSource source,
    required int displayRotationDegrees,
    required Duration timestamp,
  }) {
    final q = Quaternion(x, y, z, w);
    final lengthSquared = q.length2;
    if (lengthSquared > 0 && (lengthSquared - 1.0).abs() > 1e-6) {
      q.normalize();
    }
    return DevicePose(
      worldFromDevice: q,
      source: source,
      displayRotationDegrees: displayRotationDegrees,
      timestamp: timestamp,
    );
  }
}
