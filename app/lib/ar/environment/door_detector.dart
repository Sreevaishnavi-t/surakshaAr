import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:vector_math/vector_math_64.dart';

import '../scene/ar_camera.dart';
import 'floor_detector.dart';
import 'ground_plane.dart';
import 'luma_grid.dart';

/// A real doorway found in the camera image, measured in metres.
class DoorCandidate {
  const DoorCandidate({
    required this.basePoint,
    required this.widthMetres,
    required this.heightMetres,
    required this.distanceMetres,
    required this.bearingRadians,
    required this.score,
    required this.isOpening,
  });

  /// Centre of the door's threshold, in world space, on the ground plane.
  /// This is the point scenario content anchors to.
  final Vector3 basePoint;

  final double widthMetres;
  final double heightMetres;

  /// Horizontal distance from the worker to the threshold.
  final double distanceMetres;

  /// World-frame heading to the door, radians from +X.
  final double bearingRadians;

  /// 0–1. Combines edge strength, dimensional plausibility and floor contact.
  final double score;

  /// True when the interior reads darker than the surrounding wall, which
  /// suggests an open doorway rather than a closed door or a painted panel.
  final bool isOpening;

  double get aspectRatio => widthMetres <= 0 ? 0 : heightMetres / widthMetres;
}

/// Finds door-shaped structures in the camera image.
///
/// The method is classical and entirely offline: locate sustained vertical
/// edges, pair them, and then let **geometry do the semantic work**. Because
/// the ground plane gives the real distance to the base of a candidate, its
/// width and height can be computed in metres and anything that is not
/// door-sized simply discarded. A pipe is too narrow, a shadow has no floor
/// contact, a floor seam is horizontal, a roller shutter is too wide. No
/// trained model is involved, which matters here: a model would mean tens of
/// megabytes in the APK, a slow inference pass on a budget phone, and training
/// data from industrial interiors that nobody has.
///
/// The limitation to state plainly: this finds *door-shaped openings*, not
/// doors specifically. A tall narrow gap between two stacked pallets will
/// match. That is acceptable, because the drill only needs a plausible real
/// exit-shaped target in the worker's actual surroundings — and it is far
/// better than a green arrow floating in mid-air.
class DoorDetector {
  const DoorDetector({
    this.minWidthMetres = 0.6,
    this.maxWidthMetres = 1.6,
    this.minHeightMetres = 1.5,
    this.maxHeightMetres = 2.6,
    this.minEdgeStrength = 14.0,
  });

  /// A single industrial door leaf is about 0.9 m; double doors reach 1.6 m.
  final double minWidthMetres;
  final double maxWidthMetres;

  /// Statutory minimum door height is about 2 m. The band is widened a little
  /// for measurement error and for the camera-height estimate being imperfect.
  final double minHeightMetres;
  final double maxHeightMetres;

  /// Below this a "jamb" is indistinguishable from sensor noise.
  final double minEdgeStrength;

  /// Returns candidates, strongest first.
  List<DoorCandidate> detect({
    required LumaGrid grid,
    required FloorScan floor,
    required ArCamera camera,
    required GroundPlane ground,
  }) {
    final jambs = _findJambs(grid, floor);
    if (jambs.length < 2) return const [];

    final candidates = <DoorCandidate>[];

    for (var i = 0; i < jambs.length; i++) {
      for (var j = i + 1; j < jambs.length; j++) {
        final candidate = _evaluatePair(
          grid: grid,
          floor: floor,
          camera: camera,
          ground: ground,
          left: jambs[i],
          right: jambs[j],
        );
        if (candidate != null) candidates.add(candidate);
      }
    }

    candidates.sort((a, b) => b.score.compareTo(a.score));
    return _suppressOverlapping(candidates);
  }

  /// Columns carrying a sustained vertical edge that rises from the floor.
  ///
  /// "Rises from the floor" is the load-bearing requirement. A door is a hole
  /// in a wall that a person walks through, so its jambs necessarily meet the
  /// ground. Requiring floor contact discards the overhead pipework, cable
  /// trays and window frames that otherwise dominate an industrial scene.
  List<_Jamb> _findJambs(LumaGrid grid, FloorScan floor) {
    final strengths = List<double>.filled(grid.width, 0);
    final tops = List<int>.filled(grid.width, 0);

    for (var x = 1; x < grid.width - 1; x++) {
      final boundary = x < floor.columns.length
          ? floor.columns[x].boundaryRow
          : null;
      // No detected boundary means open floor to the horizon: nothing standing
      // in this column, so no jamb either.
      if (boundary == null) continue;

      var total = 0.0;
      var count = 0;
      var top = boundary;

      // Walk upward from the floor contact while the edge holds up.
      for (var y = boundary; y >= 0; y--) {
        final edge = grid.verticalEdgeAt(x, y);
        if (edge < minEdgeStrength) {
          // Allow one weak cell — a door frame can be partly occluded or in
          // shadow — but two in a row ends the jamb.
          if (y < boundary - 1 && grid.verticalEdgeAt(x, y + 1) < minEdgeStrength) {
            break;
          }
        }
        total += edge;
        count++;
        top = y;
      }

      if (count < 2) continue;
      strengths[x] = total / count;
      tops[x] = top;
    }

    // Keep local maxima only, so one thick frame yields a single jamb rather
    // than a smear of adjacent columns all reporting the same edge.
    final jambs = <_Jamb>[];
    for (var x = 1; x < grid.width - 1; x++) {
      final s = strengths[x];
      if (s < minEdgeStrength) continue;
      if (s < strengths[x - 1] || s < strengths[x + 1]) continue;

      final boundary = floor.columns[x].boundaryRow;
      if (boundary == null) continue;

      jambs.add(_Jamb(column: x, baseRow: boundary, topRow: tops[x], strength: s));
    }

    return jambs;
  }

  DoorCandidate? _evaluatePair({
    required LumaGrid grid,
    required FloorScan floor,
    required ArCamera camera,
    required GroundPlane ground,
    required _Jamb left,
    required _Jamb right,
  }) {
    // Both feet must sit at a similar depth. A pair straddling a corner has one
    // foot metres behind the other and is not a door.
    if ((left.baseRow - right.baseRow).abs() > 2) return null;

    final viewport = camera.viewportSize;
    final leftBase = _toScreen(grid, viewport, left.column, left.baseRow);
    final rightBase = _toScreen(grid, viewport, right.column, right.baseRow);

    final leftGround = ground.intersect(camera.rayThrough(leftBase));
    final rightGround = ground.intersect(camera.rayThrough(rightBase));
    if (leftGround == null || rightGround == null) return null;

    // Real width, measured between the two threshold points on the floor.
    final widthMetres = (leftGround - rightGround).length;
    if (widthMetres < minWidthMetres || widthMetres > maxWidthMetres) return null;

    final basePoint = (leftGround + rightGround)..scale(0.5);
    final distanceMetres = math.sqrt(
      basePoint.x * basePoint.x + basePoint.y * basePoint.y,
    );

    // Height of the shorter jamb, so a candidate is not flattered by one edge
    // running away up a wall.
    final topRow = math.max(left.topRow, right.topRow);
    final heightMetres = _heightAt(
      camera: camera,
      ground: ground,
      basePoint: basePoint,
      topScreen: _toScreen(
        grid,
        viewport,
        (left.column + right.column) ~/ 2,
        topRow,
      ),
    );
    if (heightMetres == null) return null;
    if (heightMetres < minHeightMetres || heightMetres > maxHeightMetres) {
      return null;
    }

    final isOpening = _interiorIsDarker(grid, left, right);

    return DoorCandidate(
      basePoint: basePoint,
      widthMetres: widthMetres,
      heightMetres: heightMetres,
      distanceMetres: distanceMetres,
      bearingRadians: math.atan2(basePoint.y, basePoint.x),
      score: _score(
        left: left,
        right: right,
        widthMetres: widthMetres,
        heightMetres: heightMetres,
        isOpening: isOpening,
      ),
      isOpening: isOpening,
    );
  }

  /// Real-world height of a vertical structure standing at [basePoint].
  ///
  /// The door is vertical, so its top lies directly above the threshold. Scale
  /// the ray through the top pixel until its horizontal reach matches the
  /// base's, and the vertical component of that scaled ray is the height.
  double? _heightAt({
    required ArCamera camera,
    required GroundPlane ground,
    required Vector3 basePoint,
    required Offset topScreen,
  }) {
    final ray = camera.rayThrough(topScreen);
    final rayHorizontal = math.sqrt(ray.x * ray.x + ray.y * ray.y);
    if (rayHorizontal < 1e-6) return null;

    final baseHorizontal = math.sqrt(
      basePoint.x * basePoint.x + basePoint.y * basePoint.y,
    );
    final t = baseHorizontal / rayHorizontal;
    final topZ = ray.z * t;

    final height = topZ - basePoint.z;
    return height.isFinite && height > 0 ? height : null;
  }

  /// Whether the region between the jambs is darker than the jambs themselves.
  ///
  /// An open doorway leads somewhere unlit, so it reads as a dark rectangle.
  /// This does not gate detection — a closed fire door is still the exit worth
  /// pointing at — but it raises the score, because an opening is the better
  /// target when several candidates compete.
  bool _interiorIsDarker(LumaGrid grid, _Jamb left, _Jamb right) {
    if (right.column - left.column < 2) return false;

    final midRow = ((left.baseRow + left.topRow) / 2).round().clamp(0, grid.height - 1);

    var interior = 0.0;
    var count = 0;
    for (var x = left.column + 1; x < right.column; x++) {
      interior += grid.at(x, midRow);
      count++;
    }
    if (count == 0) return false;

    final surround = (grid.at(left.column, midRow) + grid.at(right.column, midRow)) / 2;
    return (interior / count) < surround - 18;
  }

  double _score({
    required _Jamb left,
    required _Jamb right,
    required double widthMetres,
    required double heightMetres,
    required bool isOpening,
  }) {
    // Edge strength, normalised against a strong-but-attainable 60.
    final edge = ((left.strength + right.strength) / 2 / 60).clamp(0.0, 1.0);

    // A standard single door is about 0.9 x 2.05 m. Closeness to that is the
    // strongest evidence available that this really is a door.
    final widthFit = 1 - ((widthMetres - 0.95).abs() / 0.7).clamp(0.0, 1.0);
    final heightFit = 1 - ((heightMetres - 2.05).abs() / 0.8).clamp(0.0, 1.0);

    // Both jambs should be similarly strong; a real frame is symmetric.
    final balance = 1 -
        ((left.strength - right.strength).abs() /
                math.max(left.strength, right.strength))
            .clamp(0.0, 1.0);

    final base = 0.34 * edge + 0.26 * widthFit + 0.26 * heightFit + 0.14 * balance;
    return (isOpening ? base * 1.15 : base).clamp(0.0, 1.0);
  }

  /// Drops candidates that overlap a stronger one, so a doorway does not yield
  /// three nested near-duplicates.
  List<DoorCandidate> _suppressOverlapping(List<DoorCandidate> sorted) {
    final kept = <DoorCandidate>[];
    for (final candidate in sorted) {
      final clashes = kept.any((k) {
        final separation = (k.basePoint - candidate.basePoint).length;
        return separation < math.max(k.widthMetres, candidate.widthMetres);
      });
      if (!clashes) kept.add(candidate);
    }
    return kept;
  }

  /// Grid cell centre to viewport pixel.
  Offset _toScreen(LumaGrid grid, Size viewport, int x, int y) => Offset(
        (x + 0.5) / grid.width * viewport.width,
        (y + 0.5) / grid.height * viewport.height,
      );
}

class _Jamb {
  const _Jamb({
    required this.column,
    required this.baseRow,
    required this.topRow,
    required this.strength,
  });

  final int column;

  /// Grid row where the jamb meets the floor.
  final int baseRow;

  /// Highest row the edge was traced to.
  final int topRow;

  final double strength;
}
