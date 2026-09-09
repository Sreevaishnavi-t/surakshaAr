import 'dart:math' as math;

import '../environment/environment_map.dart';

/// Dimensions of a simulated underground gallery, fitted to the real room.
///
/// This is the answer to a problem the environment scanner alone cannot solve:
/// safety training happens in a classroom or a site office, not at a coal face.
/// Detecting the real room is still essential — it is what stops the worker
/// walking into a desk — but the room itself has nothing to teach. So the drill
/// builds a gallery *into* the space that was measured: the tunnel runs down the
/// longest clear line the worker actually has, its walls sit at the distance
/// their real walls sit, and its roof is at a real mine's height.
///
/// The result is a place, not a picture. That matters for more than atmosphere:
/// a worker surrounded by enclosing geometry stops noticing small tracking
/// errors, because there is no longer a stretch of real room beside the overlay
/// to compare it against.
class GalleryLayout {
  const GalleryLayout({
    required this.axisBearingRadians,
    required this.halfWidthMetres,
    required this.lengthMetres,
    required this.roofHeightMetres,
    required this.floorDropMetres,
    required this.fittedToRoom,
  });

  /// World-frame heading the tunnel runs along, chosen as the longest clear
  /// line the worker actually has.
  final double axisBearingRadians;

  /// Distance from the tunnel centre line to each rib.
  final double halfWidthMetres;

  /// How far ahead the gallery is drawn before it fades into darkness.
  final double lengthMetres;

  /// Height of the roof above the floor. Indian coal galleries are commonly
  /// worked at around 3 m; low enough that a worker notices it overhead.
  final double roofHeightMetres;

  /// Depth of the floor below the camera, i.e. the worker's own eye height.
  final double floorDropMetres;

  /// False when the room was never scanned and standard dimensions were used.
  /// Surfaced to the worker rather than hidden, since an unfitted gallery can
  /// pass through a real wall.
  final bool fittedToRoom;

  /// A typical bord-and-pillar working, used when nothing is known about the
  /// room. Deliberately narrow: a gallery that is too small for the real space
  /// merely looks tight, whereas one that is too large runs through the walls.
  static const GalleryLayout standard = GalleryLayout(
    axisBearingRadians: 0,
    halfWidthMetres: 1.6,
    lengthMetres: 9,
    roofHeightMetres: 2.9,
    floorDropMetres: 1.45,
    fittedToRoom: false,
  );

  /// Real galleries are wide enough for a tub and a person to pass, and are not
  /// unbounded; these bounds keep a mis-measured room from producing a corridor
  /// or a cathedral.
  static const double minHalfWidth = 1.1;
  static const double maxHalfWidth = 3.0;
  static const double minLength = 4.0;
  static const double maxLength = 14.0;

  /// Fits a gallery into what was actually measured.
  static GalleryLayout fit({
    required EnvironmentMap map,
    double eyeHeightMetres = 1.45,
  }) {
    if (!map.isUsable) {
      return standard.copyWith(floorDropMetres: eyeHeightMetres);
    }

    // Run the tunnel down the clearest line available: that is the direction
    // the worker has most room to look along, and the one least likely to put
    // virtual geometry through a real obstruction.
    final axis = _clearestBearing(map) ?? 0;
    final ahead = map.freeDistanceAt(axis) ?? standard.lengthMetres;

    // Width comes from the sides, not the axis — how far the real walls are to
    // left and right is what the ribs should sit at.
    final left = map.freeDistanceAt(axis + math.pi / 2);
    final right = map.freeDistanceAt(axis - math.pi / 2);
    final sides = [left, right].whereType<double>().toList();
    final measuredHalfWidth = sides.isEmpty
        ? standard.halfWidthMetres
        : sides.reduce(math.min);

    return GalleryLayout(
      axisBearingRadians: axis,
      // Held back from the real wall so the rib is visibly inside the room
      // rather than embedded in it.
      halfWidthMetres:
          (measuredHalfWidth - 0.35).clamp(minHalfWidth, maxHalfWidth),
      lengthMetres: (ahead - 0.5).clamp(minLength, maxLength),
      roofHeightMetres: standard.roofHeightMetres,
      floorDropMetres: eyeHeightMetres,
      fittedToRoom: true,
    );
  }

  /// The direction with the most measured open floor.
  static double? _clearestBearing(EnvironmentMap map) {
    double? best;
    var bestFree = 0.0;

    for (var sector = 0; sector < map.sectorCount; sector++) {
      final bearing = (sector + 0.5) / map.sectorCount * 2 * math.pi;
      final free = map.freeDistanceAt(bearing);
      if (free != null && free > bestFree) {
        bestFree = free;
        best = bearing;
      }
    }

    return best;
  }

  GalleryLayout copyWith({
    double? axisBearingRadians,
    double? halfWidthMetres,
    double? lengthMetres,
    double? roofHeightMetres,
    double? floorDropMetres,
    bool? fittedToRoom,
  }) {
    return GalleryLayout(
      axisBearingRadians: axisBearingRadians ?? this.axisBearingRadians,
      halfWidthMetres: halfWidthMetres ?? this.halfWidthMetres,
      lengthMetres: lengthMetres ?? this.lengthMetres,
      roofHeightMetres: roofHeightMetres ?? this.roofHeightMetres,
      floorDropMetres: floorDropMetres ?? this.floorDropMetres,
      fittedToRoom: fittedToRoom ?? this.fittedToRoom,
    );
  }

  /// Height of the roof relative to the camera. Negative floor, positive roof.
  double get roofRise => roofHeightMetres - floorDropMetres;

  /// Where the gallery mouth sits — the far end, which the evacuation route
  /// leads to and which acts as the exit when no real doorway was found.
  double get portalDistanceMetres => lengthMetres;
}
