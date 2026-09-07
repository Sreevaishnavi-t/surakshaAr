import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../scene/ar_camera.dart';
import 'device_pose.dart';

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
  })  : _poseChannel = poseChannel ?? const EventChannel('org.suraksha.surakshaar/pose'),
        _metaChannel = metaChannel ?? const MethodChannel('org.suraksha.surakshaar/pose_meta');

  final EventChannel _poseChannel;
  final MethodChannel _metaChannel;

  Stream<DevicePose>? _poses;

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
