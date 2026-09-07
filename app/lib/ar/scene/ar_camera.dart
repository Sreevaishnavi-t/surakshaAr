import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:vector_math/vector_math_64.dart';

import '../math/quaternion_ops.dart';
import '../pose/device_pose.dart';

/// Physical geometry of the rear camera, read from Camera2 metadata.
///
/// Matching the virtual camera's field of view to the real lens is what stops
/// overlays sliding against the world as the worker turns. It is the difference
/// between content that reads as *attached* to the machine in front of them and
/// content that reads as a heads-up display floating over a video feed. Budget
/// phones ship wide sensors where the common 60° guess is off by 15° or more.
class ArCameraIntrinsics {
  const ArCameraIntrinsics({
    required this.focalLengthMm,
    required this.sensorWidthMm,
    required this.sensorHeightMm,
    this.isMeasured = true,
  });

  final double focalLengthMm;
  final double sensorWidthMm;
  final double sensorHeightMm;

  /// False when Camera2 gave us nothing and these are assumed values. The UI
  /// exposes a calibration slider in that case rather than pretending to know.
  final bool isMeasured;

  /// Fallback geometry: a ~66° horizontal field of view, typical of a mid-range
  /// Android main camera. Used only when [ArCameraIntrinsics.fromPlatform]
  /// returns null.
  static const ArCameraIntrinsics fallback = ArCameraIntrinsics(
    focalLengthMm: 4.25,
    sensorWidthMm: 5.6,
    sensorHeightMm: 4.2,
    isMeasured: false,
  );

  double get horizontalFovRad => 2 * math.atan((sensorWidthMm / 2) / focalLengthMm);

  double get verticalFovRad => 2 * math.atan((sensorHeightMm / 2) / focalLengthMm);

  double get sensorAspect => sensorWidthMm / sensorHeightMm;

  static ArCameraIntrinsics? fromPlatform(Map<Object?, Object?>? raw) {
    if (raw == null) return null;
    final focal = (raw['focalLengthMm'] as num?)?.toDouble();
    final width = (raw['sensorWidthMm'] as num?)?.toDouble();
    final height = (raw['sensorHeightMm'] as num?)?.toDouble();
    if (focal == null || width == null || height == null) return null;
    if (focal <= 0 || width <= 0 || height <= 0) return null;
    return ArCameraIntrinsics(
      focalLengthMm: focal,
      sensorWidthMm: width,
      sensorHeightMm: height,
    );
  }

  /// Focal length expressed in the logical pixels of the on-screen viewport.
  ///
  /// Two fits compose here and both matter:
  ///
  /// 1. **Sensor → preview.** The preview stream is a crop of the sensor. If the
  ///    preview is wider than the sensor it is a vertical crop and uses the full
  ///    sensor width; otherwise it is a horizontal crop and uses the full height.
  /// 2. **Preview → widget.** The preview is drawn `BoxFit.cover`, so it is
  ///    scaled up until it covers the viewport and the overflow is clipped.
  ///
  /// Skipping either step leaves the overlay mis-scaled, which looks like drift.
  double focalPixels({
    required Size previewSize,
    required Size viewportSize,
    double calibrationScale = 1.0,
  }) {
    if (previewSize.width <= 0 || previewSize.height <= 0) {
      return viewportSize.width * calibrationScale;
    }

    final previewAspect = previewSize.width / previewSize.height;
    final double pixelsPerMm;
    if (previewAspect >= sensorAspect) {
      // Preview is wider than the sensor: full sensor width, cropped vertically.
      pixelsPerMm = previewSize.width / sensorWidthMm;
    } else {
      // Preview is taller: full sensor height, cropped horizontally.
      pixelsPerMm = previewSize.height / sensorHeightMm;
    }

    final focalInPreviewPixels = focalLengthMm * pixelsPerMm;

    final coverScale = math.max(
      viewportSize.width / previewSize.width,
      viewportSize.height / previewSize.height,
    );

    return focalInPreviewPixels * coverScale * calibrationScale;
  }
}

/// A scene point that survived projection and lies in front of the camera.
class ProjectedPoint {
  const ProjectedPoint({
    required this.screen,
    required this.depth,
    required this.scale,
  });

  /// Position in logical pixels within the viewport.
  final Offset screen;

  /// Distance along the view axis in metres. Always positive.
  final double depth;

  /// Pixels-per-metre at this depth. Multiply a real-world size by this to get
  /// its on-screen size, which is what gives billboards correct perspective.
  final double scale;
}

/// Projects scene-space points onto the viewport for the current device pose.
///
/// This engine is deliberately 3-DoF: the camera rotates but never translates.
/// Content is direction-anchored, and re-anchored in position only when a
/// printed marker is detected. That constraint is stated plainly rather than
/// dressed up as SLAM — see the README.
class ArCamera {
  ArCamera({
    required this.pose,
    required this.intrinsics,
    required this.previewSize,
    required this.viewportSize,
    this.worldFromScene,
    this.sceneOrigin,
    this.calibrationScale = 1.0,
    this.nearPlane = 0.15,
  });

  final DevicePose pose;
  final ArCameraIntrinsics intrinsics;
  final Size previewSize;
  final Size viewportSize;

  /// Rotation from scene space into world space. Set at calibration time so the
  /// scenario's "forward" lines up with wherever the worker was facing, and
  /// replaced outright when a marker pins the scene to a real surface.
  final Quaternion? worldFromScene;

  /// Translation of the scene origin in world space, in metres.
  final Vector3? sceneOrigin;

  /// User-adjustable FOV trim, exposed when intrinsics are unmeasured.
  final double calibrationScale;

  /// Points closer than this are culled. Keeps the 1/depth term from exploding.
  final double nearPlane;

  late final double _focalPixels = intrinsics.focalPixels(
    previewSize: previewSize,
    viewportSize: viewportSize,
    calibrationScale: calibrationScale,
  );

  late final Quaternion _deviceFromWorld = pose.deviceFromWorld;

  late final double _displayRotationRad = pose.displayRotationDegrees * math.pi / 180.0;

  double get focalPixels => _focalPixels;

  Offset get viewportCenter => Offset(viewportSize.width / 2, viewportSize.height / 2);

  /// Transforms a scene-space point into world space.
  Vector3 worldPointOf(Vector3 scenePoint) {
    final scene = worldFromScene;
    final rotated =
        scene == null ? scenePoint.clone() : rotateVector(scene, scenePoint);
    final origin = sceneOrigin;
    if (origin != null) rotated.add(origin);
    return rotated;
  }

  /// Projects a scene-space point, or returns null if it is behind the camera.
  ProjectedPoint? project(Vector3 scenePoint) {
    final world = worldPointOf(scenePoint);
    final device = rotateVector(_deviceFromWorld, world);

    // The rear camera looks down device −Z, so view depth is the negated Z.
    final depth = -device.z;
    if (depth <= nearPlane) return null;

    var right = device.x;
    var up = device.y;

    // Undo the display rotation so screen-up matches the viewport, not the
    // device's natural orientation. A no-op at 0°, which is the common case
    // since the activity is portrait-locked, but tablets ship natural landscape.
    if (pose.displayRotationDegrees != 0) {
      final c = math.cos(_displayRotationRad);
      final s = math.sin(_displayRotationRad);
      final rotatedRight = right * c + up * s;
      final rotatedUp = -right * s + up * c;
      right = rotatedRight;
      up = rotatedUp;
    }

    final scale = _focalPixels / depth;
    return ProjectedPoint(
      screen: Offset(
        viewportCenter.dx + right * scale,
        // Screen Y grows downward while world/device Y grows upward.
        viewportCenter.dy - up * scale,
      ),
      depth: depth,
      scale: scale,
    );
  }

  /// Angle in radians between the camera's view axis and a scene point.
  ///
  /// Scenarios use this for aim validation — for instance, requiring the worker
  /// to point at the base of a fire rather than at the flames — and for deciding
  /// when something has been looked at long enough to count as "found".
  double angleTo(Vector3 scenePoint) {
    final world = worldPointOf(scenePoint);
    if (world.length2 == 0) return 0;
    final target = world.normalized();
    final forward = pose.viewDirection;
    final dot = forward.dot(target).clamp(-1.0, 1.0);
    return math.acos(dot);
  }

  /// Whether a scene point falls inside the viewport, with an optional margin in
  /// logical pixels for treating near-edge content as visible.
  bool isOnScreen(Vector3 scenePoint, {double margin = 0}) {
    final projected = project(scenePoint);
    if (projected == null) return false;
    final p = projected.screen;
    return p.dx >= -margin &&
        p.dy >= -margin &&
        p.dx <= viewportSize.width + margin &&
        p.dy <= viewportSize.height + margin;
  }

  ArCamera copyWith({
    DevicePose? pose,
    ArCameraIntrinsics? intrinsics,
    Size? previewSize,
    Size? viewportSize,
    Quaternion? worldFromScene,
    Vector3? sceneOrigin,
    double? calibrationScale,
  }) {
    return ArCamera(
      pose: pose ?? this.pose,
      intrinsics: intrinsics ?? this.intrinsics,
      previewSize: previewSize ?? this.previewSize,
      viewportSize: viewportSize ?? this.viewportSize,
      worldFromScene: worldFromScene ?? this.worldFromScene,
      sceneOrigin: sceneOrigin ?? this.sceneOrigin,
      calibrationScale: calibrationScale ?? this.calibrationScale,
      nearPlane: nearPlane,
    );
  }

  /// Builds the scene rotation that puts scene +Y (the authoring "forward"
  /// direction) under the worker's current heading.
  ///
  /// Called when a scenario starts so content appears in front of whoever is
  /// holding the phone, regardless of which way they happen to be facing.
  ///
  /// The −π/2 is not arbitrary. The scene frame is +X right, +Y forward, +Z up,
  /// while world yaw is measured from world +X. Rotating by `yaw − π/2` about
  /// world +Z is the unique rotation that lands scene +Y on the worker's heading
  /// *and* scene +X on their right; `yaw + π/2` would point content forwards but
  /// mirror left and right, which is the kind of bug that still looks like
  /// working AR right up until someone is told to turn left.
  static Quaternion calibrationFromYaw(double yawRadians) {
    return Quaternion.axisAngle(Vector3(0, 0, 1), yawRadians - math.pi / 2);
  }
}
