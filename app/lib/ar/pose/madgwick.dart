import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Madgwick AHRS filter, gyroscope + accelerometer only.
///
/// The fallback for devices that expose no fused rotation sensor. Android's
/// `GAME_ROTATION_VECTOR` does this in the platform and does it better, so this
/// runs only when that sensor is absent — which is rare, but "rare" across a
/// contract workforce's assorted handsets still means real people holding a
/// phone where the AR does not track.
///
/// Deliberately the IMU-only variant: no magnetometer, for the same reason the
/// Kotlin side prefers game rotation vector. Underground and beside steel plant
/// motors, magnetic heading is worse than no heading. The cost is that absolute
/// yaw is unobservable and will drift slowly; the scene is origined by
/// calibration or a marker, so that costs us nothing we were relying on.
///
/// Produces `worldFromDevice` in the same convention as the rest of the engine:
/// rotating a device-frame vector by the result gives a world-frame vector,
/// with world +Z up.
class MadgwickAhrs {
  MadgwickAhrs({this.beta = 0.08});

  /// Filter gain. Trades responsiveness against noise: higher follows the
  /// accelerometer faster and jitters more. 0.08 is a little tighter than the
  /// common 0.1 because a shaky overlay reads as broken tracking to a worker.
  final double beta;

  // Quaternion state, w-first internally to match the published derivation.
  double _q0 = 1.0;
  double _q1 = 0.0;
  double _q2 = 0.0;
  double _q3 = 0.0;

  bool _seeded = false;

  /// Current orientation as `worldFromDevice`.
  Quaternion get orientation => Quaternion(_q1, _q2, _q3, _q0);

  /// True once at least one usable sample has been folded in.
  bool get hasConverged => _seeded;

  void reset() {
    _q0 = 1.0;
    _q1 = 0.0;
    _q2 = 0.0;
    _q3 = 0.0;
    _seeded = false;
  }

  /// Folds in one sample.
  ///
  /// [gx], [gy], [gz] are angular rates in rad/s; [ax], [ay], [az] are
  /// accelerometer readings in any consistent unit (only their direction is
  /// used). [dt] is the interval since the previous sample, in seconds.
  void update({
    required double gx,
    required double gy,
    required double gz,
    required double ax,
    required double ay,
    required double az,
    required double dt,
  }) {
    // Guard against the first sample, a stalled stream, or a clock glitch. A
    // large dt would integrate the gyro into a wild orientation in one step.
    if (dt <= 0 || dt > 0.5) return;

    final accelNorm = math.sqrt(ax * ax + ay * ay + az * az);

    // Seed straight from gravity rather than integrating up from identity.
    // Without this the scene visibly swings into place over the first second
    // of every drill, which looks like a fault.
    if (!_seeded && accelNorm > 0) {
      _seedFromGravity(ax / accelNorm, ay / accelNorm, az / accelNorm);
      _seeded = true;
      return;
    }

    // Rate of change of the quaternion from the gyroscope alone.
    var qDot0 = 0.5 * (-_q1 * gx - _q2 * gy - _q3 * gz);
    var qDot1 = 0.5 * (_q0 * gx + _q2 * gz - _q3 * gy);
    var qDot2 = 0.5 * (_q0 * gy - _q1 * gz + _q3 * gx);
    var qDot3 = 0.5 * (_q0 * gz + _q1 * gy - _q2 * gx);

    // Correct gyro drift against gravity, but only when the accelerometer is
    // actually measuring gravity. During a sharp movement it is measuring the
    // movement, and trusting it then drags the orientation off.
    if (accelNorm > 0) {
      final nx = ax / accelNorm;
      final ny = ay / accelNorm;
      final nz = az / accelNorm;

      // Objective: the rotated reference gravity should match the measurement.
      final f0 = 2 * (_q1 * _q3 - _q0 * _q2) - nx;
      final f1 = 2 * (_q0 * _q1 + _q2 * _q3) - ny;
      final f2 = 2 * (0.5 - _q1 * _q1 - _q2 * _q2) - nz;

      // Gradient, via the Jacobian transpose.
      var s0 = -2 * _q2 * f0 + 2 * _q1 * f1;
      var s1 = 2 * _q3 * f0 + 2 * _q0 * f1 - 4 * _q1 * f2;
      var s2 = -2 * _q0 * f0 + 2 * _q3 * f1 - 4 * _q2 * f2;
      var s3 = 2 * _q1 * f0 + 2 * _q2 * f1;

      final sNorm = math.sqrt(s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3);
      if (sNorm > 0) {
        s0 /= sNorm;
        s1 /= sNorm;
        s2 /= sNorm;
        s3 /= sNorm;

        qDot0 -= beta * s0;
        qDot1 -= beta * s1;
        qDot2 -= beta * s2;
        qDot3 -= beta * s3;
      }
    }

    _q0 += qDot0 * dt;
    _q1 += qDot1 * dt;
    _q2 += qDot2 * dt;
    _q3 += qDot3 * dt;

    _normalise();
  }

  /// Builds an initial orientation from a single gravity measurement.
  ///
  /// Yaw is unobservable from gravity alone, so it is left at zero — which is
  /// fine, because the scene's heading comes from calibration rather than from
  /// the filter.
  void _seedFromGravity(double nx, double ny, double nz) {
    // Rotation taking device-frame gravity onto world +Z, by the shortest arc.
    final dot = nz; // dot product of (nx,ny,nz) with (0,0,1)

    if (dot > 0.999999) {
      _q0 = 1;
      _q1 = 0;
      _q2 = 0;
      _q3 = 0;
      return;
    }
    if (dot < -0.999999) {
      // Exactly upside down: any perpendicular axis will do.
      _q0 = 0;
      _q1 = 1;
      _q2 = 0;
      _q3 = 0;
      return;
    }

    // Axis = measured x reference, angle from the dot product.
    final cx = ny * 1.0 - nz * 0.0;
    final cy = nz * 0.0 - nx * 1.0;
    final cz = nx * 0.0 - ny * 0.0;

    _q0 = 1 + dot;
    _q1 = cx;
    _q2 = cy;
    _q3 = cz;
    _normalise();
  }

  void _normalise() {
    final norm =
        math.sqrt(_q0 * _q0 + _q1 * _q1 + _q2 * _q2 + _q3 * _q3);
    if (norm == 0) {
      reset();
      return;
    }
    _q0 /= norm;
    _q1 /= norm;
    _q2 /= norm;
    _q3 /= norm;
  }
}
