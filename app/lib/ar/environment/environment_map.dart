import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';

import '../scene/ar_camera.dart';
import 'door_detector.dart';
import 'floor_detector.dart';
import 'ground_plane.dart';

/// A door the map has become confident about, having seen it more than once.
class MappedDoor {
  MappedDoor({required DoorCandidate seed})
      : basePoint = seed.basePoint.clone(),
        widthMetres = seed.widthMetres,
        heightMetres = seed.heightMetres,
        _scoreSum = seed.score,
        _openingVotes = seed.isOpening ? 1 : 0,
        sightings = 1;

  /// Running mean of the threshold position, in world space.
  Vector3 basePoint;

  double widthMetres;
  double heightMetres;

  /// How many frames this door has been seen in. The single best guard against
  /// a false positive: a shadow or a reflection rarely survives the worker
  /// moving the phone, whereas a real door frame does.
  int sightings;

  double _scoreSum;
  int _openingVotes;

  double get meanScore => _scoreSum / sightings;

  bool get isOpening => _openingVotes * 2 > sightings;

  double get distanceMetres =>
      math.sqrt(basePoint.x * basePoint.x + basePoint.y * basePoint.y);

  double get bearingRadians => math.atan2(basePoint.y, basePoint.x);

  /// Confidence that this is a real doorway worth sending a worker toward.
  ///
  /// Repeated sightings dominate deliberately: per-frame detector score says
  /// how door-shaped a thing looked in one image, while sightings say whether
  /// it was actually there.
  double get confidence {
    final persistence = (sightings / 4).clamp(0.0, 1.0);
    return (0.65 * persistence + 0.35 * meanScore).clamp(0.0, 1.0);
  }

  void merge(DoorCandidate observation) {
    sightings++;
    _scoreSum += observation.score;
    if (observation.isOpening) _openingVotes++;

    // Incremental mean, so a long-observed door is not yanked around by one
    // noisy frame.
    final weight = 1 / sightings;
    basePoint = basePoint * (1 - weight) + observation.basePoint * weight;
    widthMetres = widthMetres * (1 - weight) + observation.widthMetres * weight;
    heightMetres = heightMetres * (1 - weight) + observation.heightMetres * weight;
  }
}

/// What the app has worked out about the space the worker is standing in.
///
/// Built up while the worker pans the phone around at the start of a drill.
/// The engine is 3-DoF — it rotates but never translates — so the worker is a
/// fixed origin and everything observed can be accumulated in one world frame
/// without any tracking or loop closure. That constraint, which is a limitation
/// elsewhere, is what makes this map cheap and stable.
class EnvironmentMap extends ChangeNotifier {
  EnvironmentMap({this.sectorCount = 72});

  /// Sectors around the full circle. 72 gives 5° resolution, which is finer
  /// than the placement decisions that consume it need.
  final int sectorCount;

  late final List<double> _freeDistance = List<double>.filled(sectorCount, 0);
  late final List<int> _sectorSamples = List<int>.filled(sectorCount, 0);

  final List<MappedDoor> _doors = [];

  GroundPlane _ground = GroundPlane.assumed;

  GroundPlane get ground => _ground;

  set ground(GroundPlane value) {
    _ground = value;
    notifyListeners();
  }

  /// Doors seen at least twice, most confident first.
  List<MappedDoor> get doors {
    final confident = _doors.where((d) => d.sightings >= 2).toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return confident;
  }

  /// Every candidate including single sightings. For the live scan overlay,
  /// where showing a tentative detection is useful feedback.
  List<MappedDoor> get provisionalDoors => List.unmodifiable(_doors);

  /// Fraction of the full circle that has been looked at.
  double get coverage {
    final seen = _sectorSamples.where((s) => s > 0).length;
    return seen / sectorCount;
  }

  /// Whether enough of the space is known to place a scenario in it.
  ///
  /// A third of the circle is roughly what a worker sweeps comfortably without
  /// turning their feet, and is enough to place content in front of them.
  bool get isUsable => coverage >= 0.33;

  int _sectorFor(double bearingRadians) {
    final normalised = (bearingRadians % (2 * math.pi) + 2 * math.pi) % (2 * math.pi);
    return (normalised / (2 * math.pi) * sectorCount).floor() % sectorCount;
  }

  /// How much open floor there is in a direction, in metres.
  ///
  /// Returns null for directions never observed, which the caller must treat as
  /// "unknown" rather than "clear" — placing a hazard in an unobserved sector is
  /// exactly the mid-air spawn this map exists to prevent.
  double? freeDistanceAt(double bearingRadians) {
    final sector = _sectorFor(bearingRadians);
    if (_sectorSamples[sector] == 0) return null;
    return _freeDistance[sector];
  }

  /// Folds one analysed frame into the map.
  void ingest({
    required FloorScan floor,
    required List<DoorCandidate> doors,
    required ArCamera camera,
    required GroundPlane ground,
  }) {
    // Adopt the plane the caller measured against, so later placement uses the
    // same floor the observations were taken on. Without this the map silently
    // resolved content against the assumed 1.45 m default while its distances
    // had been computed from a measured height.
    _ground = ground;

    _ingestFloor(floor, camera, ground);
    for (final door in doors) {
      _ingestDoor(door);
    }
    notifyListeners();
  }

  void _ingestFloor(FloorScan floor, ArCamera camera, GroundPlane ground) {
    final viewport = camera.viewportSize;

    for (final column in floor.columns) {
      if (column.confidence < 0.4) continue;

      final x = (column.column + 0.5) / floor.columns.length * viewport.width;

      // An open column is floor as far as the eye goes; cap it at a distance
      // beyond which the drill does not care and the measurement is unreliable.
      final row = column.boundaryRow;
      final screenY = row == null
          ? viewport.height * 0.5
          : (row + 0.5) / floor.gridHeight * viewport.height;

      final ray = camera.rayThrough(Offset(x, screenY));
      final hit = ground.intersect(ray);

      final double distance;
      if (row == null) {
        distance = 12.0; // open floor; further than any scenario needs
      } else if (hit == null) {
        continue; // boundary above the horizon: tells us nothing about floor
      } else {
        distance = math.sqrt(hit.x * hit.x + hit.y * hit.y);
      }

      final bearing = math.atan2(ray.y, ray.x);
      final sector = _sectorFor(bearing);

      // Keep the *smallest* distance ever seen in a sector, not a mean.
      // Free space is a safety claim, and the conservative reading is the only
      // honest one: if an obstruction was seen once, the space is not clear.
      if (_sectorSamples[sector] == 0 || distance < _freeDistance[sector]) {
        _freeDistance[sector] = distance;
      }
      _sectorSamples[sector]++;
    }
  }

  void _ingestDoor(DoorCandidate observation) {
    for (final existing in _doors) {
      final separation = (existing.basePoint - observation.basePoint).length;
      // Within half a door width is the same door seen again.
      if (separation < math.max(existing.widthMetres, 0.8)) {
        existing.merge(observation);
        return;
      }
    }
    _doors.add(MappedDoor(seed: observation));
  }

  /// Forgets everything. Used when a drill restarts in a different spot.
  void reset() {
    for (var i = 0; i < sectorCount; i++) {
      _freeDistance[i] = 0;
      _sectorSamples[i] = 0;
    }
    _doors.clear();
    notifyListeners();
  }
}
