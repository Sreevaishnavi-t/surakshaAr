import 'dart:math' as math;
import 'dart:ui';

import 'package:vector_math/vector_math_64.dart';

/// Everything a node needs in order to draw itself for one frame.
///
/// The canvas handed to a node is already translated to the node's projected
/// screen position and scaled so that **one canvas unit is one metre**. Nodes
/// therefore describe themselves in real-world dimensions — a 1.8 m doorway is
/// literally `1.8` tall — and perspective falls out of the transform. This keeps
/// content authoring physical instead of a pile of magic pixel constants.
class NodeRenderContext {
  const NodeRenderContext({
    required this.depth,
    required this.pixelsPerMetre,
    required this.elapsed,
    required this.atmosphericOpacity,
    required this.viewportSize,
    required this.screenPosition,
    required this.angleFromCentre,
  });

  /// Distance from the camera in metres.
  final double depth;

  /// On-screen pixels per world metre at this depth.
  final double pixelsPerMetre;

  /// Time since the scene started. Drives all animation, so playback is a pure
  /// function of elapsed time and stays deterministic for tests.
  final Duration elapsed;

  /// Distance fade, 0..1. Content far away washes out slightly, which is a
  /// surprisingly strong depth cue when there is no stereo disparity.
  final double atmosphericOpacity;

  final Size viewportSize;

  /// Where this node landed, in viewport pixels. Available for nodes that need
  /// to draw an unscaled element such as a label or a leader line.
  final Offset screenPosition;

  /// Angle in radians between the camera's view axis and this node. Nodes use it
  /// to emphasise themselves when looked at directly.
  final double angleFromCentre;

  double get seconds => elapsed.inMicroseconds / 1e6;

  /// Converts a blur radius expressed in **screen pixels** into canvas units.
  ///
  /// Essential, not cosmetic. Blur sigma is applied in the canvas coordinate
  /// system, and this renderer scales that system by [pixelsPerMetre] — often
  /// several hundred. A sigma written as a plain metre value therefore becomes a
  /// several-hundred-pixel blur at close range, and a scene with a few dozen
  /// blurred particles will exhaust or hang the GPU rather than merely running
  /// slowly.
  ///
  /// [maxScreenPixels] caps the result so a node that drifts very close to the
  /// camera cannot spike the cost. Visually this is also the more correct
  /// behaviour: a soft edge should stay soft by roughly the same amount on
  /// screen rather than growing without bound as the worker approaches.
  double blurUnits(double screenPixels, {double maxScreenPixels = 32}) {
    if (pixelsPerMetre <= 0) return 0;
    final clamped = screenPixels < maxScreenPixels ? screenPixels : maxScreenPixels;
    return clamped / pixelsPerMetre;
  }
}

/// A drawable anchored in scene space.
abstract class SceneNode {
  SceneNode({
    required this.id,
    required this.position,
    this.hitRadiusMetres = 0.4,
    this.visible = true,
    this.interactive = false,
    this.sortBias = 0,
  });

  final String id;

  /// Position in scene space, metres. +Z is up; the camera sits at the origin.
  Vector3 position;

  /// Radius used for tap testing, in metres at the node's own depth.
  double hitRadiusMetres;

  bool visible;

  /// Whether taps should be routed to this node.
  bool interactive;

  /// Nudges draw order without moving the node. Positive values draw later
  /// (nearer the viewer). Used for things like a flame that must sit in front of
  /// its own smoke even though their centres are nearly coincident.
  double sortBias;

  /// Draws the node. The canvas is pre-transformed: origin at the node, one unit
  /// per metre, Y increasing downward as usual for canvas space.
  void paint(Canvas canvas, NodeRenderContext ctx);

  /// Per-frame state update. Default is a no-op; particle systems override it.
  void update(Duration elapsed) {}
}

/// Places a node by bearing and distance rather than raw coordinates.
///
/// Scenario content is far easier to author as "the fire exit is 6 m away, 40°
/// to my left, at floor level" than as a Cartesian triple.
///
/// **Scene frame: +X right, +Y forward, +Z up.** Right-handed, and chosen so
/// that the three axes read the way a person standing in the space would
/// describe them. `ArCamera.calibrationFromYaw` maps scene +Y onto whichever
/// heading the worker was facing when the drill began.
///
/// Positive [bearingDegrees] turns to the worker's right. [heightMetres] is
/// measured from eye level, so floor-level content sits at about −1.6.
Vector3 scenePlacement({
  required double bearingDegrees,
  required double distanceMetres,
  double heightMetres = 0,
}) {
  final bearing = bearingDegrees * math.pi / 180.0;
  return Vector3(
    distanceMetres * math.sin(bearing),
    distanceMetres * math.cos(bearing),
    heightMetres,
  );
}

/// Typical eye height of a standing worker, in metres. Scene content uses this
/// to sit things on the floor: the camera is the eye, so the floor is −1.6.
const double kEyeHeightMetres = 1.6;
