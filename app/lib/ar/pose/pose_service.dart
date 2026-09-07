import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../scene/ar_camera.dart';
import 'device_pose.dart';
import 'madgwick.dart';

/// What the device can actually do, queried once at startup.
///
/// Reported to the user on the AR readiness screen. A worker on a phone with no
/// gyroscope should be told that plainly, not left wondering why the overlay
/// will not hold still.
@immutable
class PoseCapabilities {
  const PoseCapabilities({
    required this.hasGameRotationVector,
    required this.hasRotationVector,
    required this.hasGyroscope,
    required this.hasAccelerometer,
    required this.hasMagnetometer,
  });

  final bool hasGameRotationVector;
  final bool hasRotationVector;
  final bool hasGyroscope;
  final bool hasAccelerometer;
  final bool hasMagnetometer;

  static const PoseCapabilities unknown = PoseCapabilities(
    hasGameRotationVector: false,
    hasRotationVector: false,
    hasGyroscope: false,
    hasAccelerometer: false,
    hasMagnetometer: false,
  );

  /// True when the device can hold a scene still as the worker turns.
  bool get supportsWorldLocking => hasGameRotationVector || hasRotationVector;

  /// True when orientation would depend on the magnetometer, which is not
  /// trustworthy underground or beside heavy machinery.
  bool get isMagnetometerDependent => !hasGameRotationVector && hasRotationVector;

  PoseSource get bestSource {
    if (hasGameRotationVector) return PoseSource.gameRotationVector;
    if (hasRotationVector) return PoseSource.rotationVector;
    return PoseSource.none;
  }

  static PoseCapabilities fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return unknown;
    bool read(String key) => raw[key] == true;
    return PoseCapabilities(
      hasGameRotationVector: read('hasGameRotationVector'),
      hasRotationVector: read('hasRotationVector'),
      hasGyroscope: read('hasGyroscope'),
      hasAccelerometer: read('hasAccelerometer'),
      hasMagnetometer: read('hasMagnetometer'),
    );
  }
}

/// Streams device orientation and exposes camera intrinsics.
///
/// Wraps the `PoseChannel` Kotlin plugin. All of it works with the radio off —
/// there is no network path anywhere in this class.
class PoseService {
  PoseService({
    EventChannel? poseChannel,
    MethodChannel? metaChannel,
    EventChannel? imuChannel,
  })  : _poseChannel = poseChannel ?? const EventChannel('org.suraksha.surakshaar/pose'),
        _metaChannel = metaChannel ?? const MethodChannel('org.suraksha.surakshaar/pose_meta'),
        _imuChannel = imuChannel ?? const EventChannel('org.suraksha.surakshaar/imu');

  final EventChannel _poseChannel;
  final MethodChannel _metaChannel;
  final EventChannel _imuChannel;

  Stream<DevicePose>? _poses;
  Stream<DevicePose>? _fallbackPoses;

  /// Broadcast so the renderer, the scenario step machine and any debug overlay
  /// can all observe without each opening its own sensor registration.
  Stream<DevicePose> get poses {
    return _poses ??= _poseChannel
        .receiveBroadcastStream()
        .map(_decode)
        .where((pose) => pose != null)
        .cast<DevicePose>()
        .handleError(_onStreamError)
        .asBroadcastStream();
  }

  DevicePose? _decode(Object? event) {
    if (event is! List || event.length < 7) return null;
    double at(int i) => (event[i] as num).toDouble();

    return DevicePose.fromSensorQuaternion(
      w: at(0),
      x: at(1),
      y: at(2),
      z: at(3),
      source: _sourceFromCode(at(4).toInt()),
      displayRotationDegrees: at(5).toInt(),
      // Sensor timestamps are monotonic nanoseconds since boot.
      timestamp: Duration(microseconds: (at(6) / 1000).round()),
    );
  }

  static PoseSource _sourceFromCode(int code) {
    switch (code) {
      case 1:
        return PoseSource.gameRotationVector;
      case 2:
        return PoseSource.rotationVector;
      default:
        return PoseSource.none;
    }
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    // A sensor stream failure must never take down a training session: the
    // scenario stays playable with a frozen viewport, so we log and continue.
    debugPrint('PoseService: sensor stream error: $error');
  }

  /// Orientation from raw IMU samples, fused in Dart with [MadgwickAhrs].
  ///
  /// Used only when the platform exposes no fused rotation sensor. Android does
  /// this better in the platform when it can, so this is a genuine fallback
  /// rather than a preference — but on a handset without it, the difference is
  /// between AR that tracks and AR that does not.
  Stream<DevicePose> get fallbackPoses {
    return _fallbackPoses ??= () {
      final filter = MadgwickAhrs();
      double? previousTimestampSeconds;

      return _imuChannel
          .receiveBroadcastStream()
          .map<DevicePose?>((event) {
            if (event is! List || event.length < 7) return null;
            double at(int i) => (event[i] as num).toDouble();

            final timestampSeconds = at(6) / 1e9;
            final dt = previousTimestampSeconds == null
                ? 1 / 100
                : timestampSeconds - previousTimestampSeconds!;
            previousTimestampSeconds = timestampSeconds;

            filter.update(
              ax: at(0),
              ay: at(1),
              az: at(2),
              gx: at(3),
              gy: at(4),
              gz: at(5),
              dt: dt,
            );

            return DevicePose(
              worldFromDevice: filter.orientation,
              source: PoseSource.madgwickFallback,
              // The activity is portrait-locked, so the display never leaves
              // its natural rotation.
              displayRotationDegrees: 0,
              timestamp: Duration(microseconds: (timestampSeconds * 1e6).round()),
            );
          })
          .where((pose) => pose != null)
          .cast<DevicePose>()
          .handleError(_onStreamError)
          .asBroadcastStream();
    }();
  }

  /// The best orientation stream this device can provide.
  ///
  /// Picks the platform's fused sensor when present and the Dart filter when
  /// not, so callers never have to branch on hardware.
  Stream<DevicePose> streamFor(PoseCapabilities capabilities) =>
      capabilities.supportsWorldLocking ? poses : fallbackPoses;

  Future<PoseCapabilities> capabilities() async {
    try {
      final raw = await _metaChannel.invokeMapMethod<Object?, Object?>('capabilities');
      return PoseCapabilities.fromMap(raw);
    } on PlatformException catch (e) {
      debugPrint('PoseService: capabilities unavailable: ${e.message}');
      return PoseCapabilities.unknown;
    } on MissingPluginException {
      // Hit in unit tests and on the desktop harness.
      return PoseCapabilities.unknown;
    }
  }

  /// Real camera geometry, or [ArCameraIntrinsics.fallback] when Camera2 gives
  /// us nothing. Callers can tell the two apart via `isMeasured` and offer the
  /// manual calibration slider only when it is actually needed.
  Future<ArCameraIntrinsics> cameraIntrinsics() async {
    try {
      final raw = await _metaChannel.invokeMapMethod<Object?, Object?>('cameraIntrinsics');
      return ArCameraIntrinsics.fromPlatform(raw) ?? ArCameraIntrinsics.fallback;
    } on PlatformException catch (e) {
      debugPrint('PoseService: intrinsics unavailable: ${e.message}');
      return ArCameraIntrinsics.fallback;
    } on MissingPluginException {
      return ArCameraIntrinsics.fallback;
    }
  }
}
