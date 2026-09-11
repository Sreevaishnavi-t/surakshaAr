import 'ground_plane.dart';

/// How the worker says they are holding the phone during the drill.
///
/// Worth asking rather than assuming. The same person produces a camera height
/// that differs by 30 cm or more between holding the phone up like a window and
/// holding it comfortably at chest level, and 30 cm of error in this one number
/// propagates straight into every distance the engine computes — where the fire
/// stands, how wide a detected door measures, how far away the tunnel wall is.
enum PhoneHold {
  /// Held up, screen roughly at eye level, used like a window.
  atEyeLevel,

  /// Held comfortably in front of the chest, tilted up slightly.
  atChestLevel,
}

/// Turns what the worker told us into the camera's height above the floor.
///
/// This is the single number that scales the entire scene. The ground plane's
/// orientation is known for free from gravity, so this height is the *only*
/// unknown standing between the app and real-world measurements — which is why
/// it is worth a question at the start of the drill rather than a constant.
abstract final class CameraHeight {
  /// Average standing height, used when the worker skips the question.
  static const double defaultBodyHeightMetres = 1.68;

  /// Plausible range for the stature question, so a mistyped entry cannot put
  /// the floor somewhere absurd.
  static const double minBodyHeightMetres = 1.30;
  static const double maxBodyHeightMetres = 2.10;

  /// Camera height for a worker of [bodyHeightMetres] using the given [hold].
  ///
  /// Returns a [GroundPlane] tagged [GroundHeightSource.stated], and never one
  /// outside [GroundPlane.minHeightMetres]..[GroundPlane.maxHeightMetres].
  static GroundPlane forWorker({
    required double bodyHeightMetres,
    required PhoneHold hold,
  }) {
    final metres = cameraHeightFor(
      bodyHeightMetres: bodyHeightMetres,
      hold: hold,
    );

    return GroundPlane(
      cameraHeightMetres: metres.clamp(
        GroundPlane.minHeightMetres,
        GroundPlane.maxHeightMetres,
      ),
      source: GroundHeightSource.stated,
    );
  }

  /// Standing eye height as a fraction of stature.
  ///
  /// Anthropometric surveys put the pupils a little over 6% of stature below
  /// the crown of the head. It is a skeletal proportion rather than a habit, so
  /// it holds across the whole range this question offers.
  static const double _eyeHeightRatio = 0.936;

  /// How far below the eyes the phone ends up, per hold, in metres.
  ///
  /// Fixed rather than proportional, deliberately. Eye height scales with the
  /// body because it is a skeletal landmark; where somebody parks their hands
  /// does not. A tall worker and a short worker bend their elbows the same way,
  /// so scaling these by stature would invent a difference that is not there.
  static const double _eyeLevelDropMetres = 0.05;
  static const double _chestLevelDropMetres = 0.27;

  /// Height of the phone above the floor, in metres, for a worker of
  /// [bodyHeightMetres] holding it as described by [hold].
  ///
  /// Unclamped — [forWorker] is the entry point that keeps the result sane.
  static double cameraHeightFor({
    required double bodyHeightMetres,
    required PhoneHold hold,
  }) {
    final eyeHeight = bodyHeightMetres * _eyeHeightRatio;

    final drop = switch (hold) {
      PhoneHold.atEyeLevel => _eyeLevelDropMetres,
      PhoneHold.atChestLevel => _chestLevelDropMetres,
    };

    return eyeHeight - drop;
  }
}
