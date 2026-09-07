import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/math/quaternion_ops.dart';
import 'package:surakshaar/ar/pose/madgwick.dart';
import 'package:vector_math/vector_math_64.dart';

/// Feeds [seconds] worth of samples at [rate] Hz.
void feed(
  MadgwickAhrs filter, {
  required double seconds,
  double rate = 100,
  Vector3 gyro = const _Zero(),
  required Vector3 accel,
}) {
  final dt = 1 / rate;
  final steps = (seconds * rate).round();
  for (var i = 0; i < steps; i++) {
    filter.update(
      gx: gyro.x,
      gy: gyro.y,
      gz: gyro.z,
      ax: accel.x,
      ay: accel.y,
      az: accel.z,
      dt: dt,
    );
  }
}

/// `Vector3` has no const constructor, so this stands in for a zero default.
class _Zero implements Vector3 {
  const _Zero();

  @override
  double get x => 0;
  @override
  double get y => 0;
  @override
  double get z => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('test stub');
}

void main() {
  group('MadgwickAhrs', () {
    test('a phone lying flat converges to level', () {
      final filter = MadgwickAhrs();
      // Android reports +9.81 on Z when the device lies screen-up.
      feed(filter, seconds: 2, accel: Vector3(0, 0, 9.81));

      // Device +Z should map onto world +Z.
      final up = rotateVector(filter.orientation, Vector3(0, 0, 1));
      expect(up.z, closeTo(1, 1e-3));
    });

    test('seeds from the first sample instead of swinging into place', () {
      // Integrating up from identity would take a visible second to settle,
      // which reads as broken tracking at the start of every drill.
      final filter = MadgwickAhrs();
      expect(filter.hasConverged, isFalse);

      // A phone held upright: gravity along −Y in the device frame.
      filter.update(
        gx: 0, gy: 0, gz: 0,
        ax: 0, ay: -9.81, az: 0,
        dt: 0.01,
      );

      expect(filter.hasConverged, isTrue);
      final up = rotateVector(filter.orientation, Vector3(0, -1, 0));
      expect(up.z, closeTo(1, 1e-3));
    });

    test('an upright phone puts the camera axis on the horizon', () {
      final filter = MadgwickAhrs();
      // Held upright like a window: gravity pulls along device −Y.
      feed(filter, seconds: 2, accel: Vector3(0, -9.81, 0));

      // The rear camera looks along device −Z, which should now be horizontal.
      final view = rotateVector(filter.orientation, Vector3(0, 0, -1));
      expect(view.z, closeTo(0, 1e-2));
    });

    test('integrates a steady yaw rotation', () {
      final filter = MadgwickAhrs();
      feed(filter, seconds: 1, accel: Vector3(0, 0, 9.81));

      final before = filter.orientation;

      // Half a radian per second about device Z, for one second. With the phone
      // flat, device Z is world up, so this is a pure heading change.
      feed(
        filter,
        seconds: 1,
        accel: Vector3(0, 0, 9.81),
        gyro: Vector3(0, 0, 0.5),
      );

      final rotated = rotateVector(filter.orientation, Vector3(1, 0, 0));
      final original = rotateVector(before, Vector3(1, 0, 0));
      final swept = math.atan2(rotated.y, rotated.x) -
          math.atan2(original.y, original.x);

      // Gravity cannot correct yaw, so this is pure gyro integration and should
      // land close to the commanded 0.5 rad.
      expect(swept, closeTo(0.5, 0.05));
    });

    test('stays level while yawing, so the horizon does not tilt', () {
      final filter = MadgwickAhrs();
      feed(
        filter,
        seconds: 3,
        accel: Vector3(0, 0, 9.81),
        gyro: Vector3(0, 0, 0.4),
      );

      final up = rotateVector(filter.orientation, Vector3(0, 0, 1));
      expect(up.z, closeTo(1, 1e-2));
    });

    test('ignores implausible time steps', () {
      final filter = MadgwickAhrs();
      feed(filter, seconds: 1, accel: Vector3(0, 0, 9.81));
      final before = filter.orientation;

      // A stalled stream resuming would otherwise integrate the gyro across the
      // whole gap in one step and fling the scene somewhere absurd.
      filter.update(
        gx: 5, gy: 5, gz: 5,
        ax: 0, ay: 0, az: 9.81,
        dt: 12,
      );
      filter.update(
        gx: 5, gy: 5, gz: 5,
        ax: 0, ay: 0, az: 9.81,
        dt: -1,
      );

      expect(filter.orientation.x, closeTo(before.x, 1e-12));
      expect(filter.orientation.w, closeTo(before.w, 1e-12));
    });

    test('always produces a unit quaternion', () {
      final filter = MadgwickAhrs();
      final random = math.Random(7);

      for (var i = 0; i < 500; i++) {
        filter.update(
          gx: (random.nextDouble() - 0.5) * 4,
          gy: (random.nextDouble() - 0.5) * 4,
          gz: (random.nextDouble() - 0.5) * 4,
          ax: (random.nextDouble() - 0.5) * 20,
          ay: (random.nextDouble() - 0.5) * 20,
          az: (random.nextDouble() - 0.5) * 20,
          dt: 0.01,
        );
        expect(filter.orientation.length, closeTo(1, 1e-9), reason: 'step $i');
      }
    });

    test('survives an all-zero accelerometer without producing NaN', () {
      // Free fall, or a wedged sensor. Neither should poison the orientation.
      final filter = MadgwickAhrs();
      feed(filter, seconds: 1, accel: Vector3(0, 0, 9.81));

      for (var i = 0; i < 100; i++) {
        filter.update(
          gx: 0.1, gy: 0, gz: 0,
          ax: 0, ay: 0, az: 0,
          dt: 0.01,
        );
      }

      final q = filter.orientation;
      expect(q.x.isNaN, isFalse);
      expect(q.w.isNaN, isFalse);
      expect(q.length, closeTo(1, 1e-9));
    });
  });
}
