import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'environment_map.dart';
import 'ground_plane.dart';

/// What a piece of scenario content actually needs from the room.
///
/// The scenario says what a thing *is*, not where to put it. That is the whole
/// change: "the fire exit" used to mean "a marker 7 m away, 118° to the left",
/// which is a position invented before the app had ever seen the room. It now
/// means "the way out of here", and the engine goes and finds one.
enum PlacementKind {
  /// A way out. Wants a real doorway, and says so plainly when it cannot find
  /// one rather than inventing a green arrow in mid-air.
  exit,

  /// Something dangerous to be kept away from and looked at. Wants open floor
  /// at a distance, and specifically *not* a doorway — putting the fire in the
  /// exit would teach the opposite of the lesson.
  hazard,

  /// A fixed installation: an extinguisher, a valve, an isolator. Wants floor
  /// near an obstruction, because that is where such things are mounted.
  equipment,

  /// Anything else. Floor, roughly where the author asked, within free space.
  freeStanding,
}

/// How a resolved position came to be chosen.
enum PlacementAnchor {
  /// Pinned to a doorway detected in the worker's actual surroundings.
  detectedDoor,

  /// Placed on measured open floor.
  measuredFloor,

  /// Placed against a measured obstruction.
  measuredObstruction,

  /// The room was never successfully scanned. The authored position is used
  /// unchanged, and the UI says so — the drill still runs, it just is not
  /// anchored to anything real.
  authoredFallback,
}

/// A request to place one piece of content.
class PlacementRequest {
  const PlacementRequest({
    required this.id,
    required this.kind,
    required this.preferredBearingRadians,
    required this.preferredDistanceMetres,
    this.heightAboveFloorMetres = 0,
    this.minDistanceMetres = 1.5,
  });

  final String id;
  final PlacementKind kind;

  /// Where the scenario author would like it, as a world-frame bearing. Treated
  /// as a preference and nothing stronger: a real door two metres from the hint
  /// beats empty air exactly on it.
  final double preferredBearingRadians;

  final double preferredDistanceMetres;

  final double heightAboveFloorMetres;

  /// Never place closer than this. Content inside arm's reach cannot be looked
  /// at, and at very short range small pose errors swing it wildly.
  final double minDistanceMetres;
}

/// Where a piece of content ended up, and on what evidence.
class ResolvedPlacement {
  const ResolvedPlacement({
    required this.id,
    required this.worldPosition,
    required this.anchor,
    required this.confidence,
    this.door,
  });

  final String id;

  /// Position in world space, on or above the ground plane.
  final Vector3 worldPosition;

  final PlacementAnchor anchor;

  /// 0–1. Drives whether the UI presents this as anchored to the room or as a
  /// best guess.
  final double confidence;

  /// The doorway this was pinned to, when [anchor] is [PlacementAnchor.detectedDoor].
  final MappedDoor? door;

  bool get isAnchoredToRealFeature => anchor != PlacementAnchor.authoredFallback;
}

/// Turns authored placement requests into positions in the worker's real room.
class PlacementResolver {
  const PlacementResolver({
    this.clearanceMetres = 0.8,
    this.minDoorConfidence = 0.45,
  });

  /// Kept back from any measured obstruction, so content is not half-buried in
  /// a wall that was measured slightly long.
  final double clearanceMetres;

  /// Below this a doorway is not trustworthy enough to send a worker at.
  final double minDoorConfidence;

  /// Resolves a batch together, so two requests cannot claim the same doorway.
  ///
  /// Order matters and is the caller's to choose: exits are resolved first in
  /// practice, because a drill with the fire in the right place and the exit in
  /// the wrong one is worse than the reverse.
  List<ResolvedPlacement> resolveAll({
    required List<PlacementRequest> requests,
    required EnvironmentMap map,
  }) {
    final claimed = <MappedDoor>{};
    return [
      for (final request in requests)
        _resolve(request: request, map: map, claimed: claimed),
    ];
  }

  ResolvedPlacement _resolve({
    required PlacementRequest request,
    required EnvironmentMap map,
    required Set<MappedDoor> claimed,
  }) {
    if (!map.isUsable) return _authored(request, map.ground);

    switch (request.kind) {
      case PlacementKind.exit:
        return _resolveExit(request, map, claimed);
      case PlacementKind.hazard:
        return _resolveHazard(request, map);
      case PlacementKind.equipment:
        return _resolveEquipment(request, map);
      case PlacementKind.freeStanding:
        return _resolveFreeStanding(request, map);
    }
  }

  /// Pins an exit to the best available doorway.
  ///
  /// "Best" weighs confidence against agreement with the authored bearing, but
  /// confidence dominates: a real door behind the worker teaches evacuation
  /// better than a guessed one straight ahead, and turning to look for the way
  /// out is the behaviour being drilled.
  ResolvedPlacement _resolveExit(
    PlacementRequest request,
    EnvironmentMap map,
    Set<MappedDoor> claimed,
  ) {
    final available = map.doors
        .where((d) => !claimed.contains(d) && d.confidence >= minDoorConfidence)
        .toList();

    if (available.isNotEmpty) {
      MappedDoor? best;
      var bestScore = double.negativeInfinity;

      for (final door in available) {
        final offset = _angularDistance(
          door.bearingRadians,
          request.preferredBearingRadians,
        );
        // Full marks for agreeing with the hint, falling to zero at 180°.
        final agreement = 1 - (offset / math.pi);
        final score = 0.7 * door.confidence + 0.3 * agreement;
        if (score > bestScore) {
          bestScore = score;
          best = door;
        }
      }

      if (best != null) {
        claimed.add(best);
        final position = best.basePoint.clone()
          ..z += request.heightAboveFloorMetres;
        return ResolvedPlacement(
          id: request.id,
          worldPosition: position,
          anchor: PlacementAnchor.detectedDoor,
          confidence: best.confidence,
          door: best,
        );
      }
    }

    // No doorway found. Fall back to the direction with the most open floor —
    // a gap in a wall that the detector could not resolve into jambs is still
    // the most exit-like thing available, and is far better than mid-air.
    final open = _mostOpenBearing(map);
    if (open != null) {
      final distance = _clampToFreeSpace(
        map: map,
        bearingRadians: open,
        desired: request.preferredDistanceMetres,
        minimum: request.minDistanceMetres,
      );
      return ResolvedPlacement(
        id: request.id,
        worldPosition: map.ground.pointAt(
          bearingRadians: open,
          distanceMetres: distance,
        )..z += request.heightAboveFloorMetres,
        anchor: PlacementAnchor.measuredFloor,
        // Deliberately capped low. This is "the most open direction", not a
        // door, and the UI should not claim otherwise.
        confidence: 0.4,
      );
    }

    return _authored(request, map.ground);
  }

  /// Puts a hazard on open floor, away from the exits.
  ResolvedPlacement _resolveHazard(PlacementRequest request, EnvironmentMap map) {
    final bearing = _bestBearing(
      map: map,
      preferred: request.preferredBearingRadians,
      // A hazard sitting in the doorway would teach a worker to run into the
      // fire, so doorways are actively avoided here.
      avoid: map.doors.map((d) => d.bearingRadians).toList(),
      avoidRadians: 0.35,
      minimumFree: request.minDistanceMetres + clearanceMetres,
    );
    if (bearing == null) return _authored(request, map.ground);

    final distance = _clampToFreeSpace(
      map: map,
      bearingRadians: bearing,
      desired: request.preferredDistanceMetres,
      minimum: request.minDistanceMetres,
    );

    return ResolvedPlacement(
      id: request.id,
      worldPosition: map.ground.pointAt(
        bearingRadians: bearing,
        distanceMetres: distance,
      )..z += request.heightAboveFloorMetres,
      anchor: PlacementAnchor.measuredFloor,
      confidence: 0.75,
    );
  }

  /// Puts equipment against something, because that is where it is mounted.
  ResolvedPlacement _resolveEquipment(PlacementRequest request, EnvironmentMap map) {
    final bearing = _bestBearing(
      map: map,
      preferred: request.preferredBearingRadians,
      avoid: const [],
      avoidRadians: 0,
      minimumFree: request.minDistanceMetres,
    );
    if (bearing == null) return _authored(request, map.ground);

    final free = map.freeDistanceAt(bearing) ?? request.preferredDistanceMetres;
    // Just short of the obstruction: an extinguisher hangs on the wall, it does
    // not stand in the middle of the floor.
    final distance = math.max(
      request.minDistanceMetres,
      free - clearanceMetres * 0.5,
    );

    return ResolvedPlacement(
      id: request.id,
      worldPosition: map.ground.pointAt(
        bearingRadians: bearing,
        distanceMetres: distance,
      )..z += request.heightAboveFloorMetres,
      anchor: PlacementAnchor.measuredObstruction,
      confidence: 0.7,
    );
  }

  ResolvedPlacement _resolveFreeStanding(
    PlacementRequest request,
    EnvironmentMap map,
  ) {
    final bearing = _bestBearing(
      map: map,
      preferred: request.preferredBearingRadians,
      avoid: const [],
      avoidRadians: 0,
      minimumFree: request.minDistanceMetres,
    );
    if (bearing == null) return _authored(request, map.ground);

    return ResolvedPlacement(
      id: request.id,
      worldPosition: map.ground.pointAt(
        bearingRadians: bearing,
        distanceMetres: _clampToFreeSpace(
          map: map,
          bearingRadians: bearing,
          desired: request.preferredDistanceMetres,
          minimum: request.minDistanceMetres,
        ),
      )..z += request.heightAboveFloorMetres,
      anchor: PlacementAnchor.measuredFloor,
      confidence: 0.65,
    );
  }

  /// The authored position, unchanged. Used when the room is unknown.
  ResolvedPlacement _authored(PlacementRequest request, GroundPlane ground) {
    return ResolvedPlacement(
      id: request.id,
      worldPosition: ground.pointAt(
        bearingRadians: request.preferredBearingRadians,
        distanceMetres: request.preferredDistanceMetres,
      )..z += request.heightAboveFloorMetres,
      anchor: PlacementAnchor.authoredFallback,
      confidence: 0.2,
    );
  }

  /// Nearest observed bearing to the preference that has room and is not near
  /// anything in [avoid].
  double? _bestBearing({
    required EnvironmentMap map,
    required double preferred,
    required List<double> avoid,
    required double avoidRadians,
    required double minimumFree,
  }) {
    double? best;
    var bestOffset = double.infinity;

    for (var sector = 0; sector < map.sectorCount; sector++) {
      final bearing = (sector + 0.5) / map.sectorCount * 2 * math.pi;
      final free = map.freeDistanceAt(bearing);
      if (free == null || free < minimumFree) continue;

      if (avoid.any((a) => _angularDistance(a, bearing) < avoidRadians)) {
        continue;
      }

      final offset = _angularDistance(bearing, preferred);
      if (offset < bestOffset) {
        bestOffset = offset;
        best = bearing;
      }
    }

    return best;
  }

  double? _mostOpenBearing(EnvironmentMap map) {
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

  double _clampToFreeSpace({
    required EnvironmentMap map,
    required double bearingRadians,
    required double desired,
    required double minimum,
  }) {
    final free = map.freeDistanceAt(bearingRadians);
    if (free == null) return desired;
    final limit = math.max(minimum, free - clearanceMetres);
    return math.min(desired, limit);
  }

  /// Smallest angle between two bearings, 0 to π.
  static double _angularDistance(double a, double b) {
    var delta = (a - b).abs() % (2 * math.pi);
    if (delta > math.pi) delta = 2 * math.pi - delta;
    return delta;
  }
}
