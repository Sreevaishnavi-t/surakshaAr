import 'dart:math' as math;
import 'dart:ui';

import 'package:vector_math/vector_math_64.dart';

import 'ar_camera.dart';

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

  /// Whether this node opts out of the renderer's screen-margin cull.
  ///
  /// False for billboards, whose extent is bounded by [hitRadiusMetres].
  bool get bypassesScreenCull => false;

  /// Per-frame state update. Default is a no-op; particle systems override it.
  void update(Duration elapsed) {}
}

/// A node whose shape is defined in world space and projected per vertex.
///
/// The ordinary [SceneNode] is a billboard: one point is projected and the node
/// draws flat around it at a scale set by depth. That is right for a fire, a
/// sign or an extinguisher, all of which face the viewer. It cannot draw a
/// wall, because a wall *recedes* — its near edge is large and its far edge
/// small, and no single scale factor expresses that.
///
/// Nodes of this kind therefore paint in screen space with the camera in hand,
/// projecting each corner separately. That is what gives a tunnel real
/// perspective, and it is what makes a simulated gallery read as a place the
/// worker is standing inside rather than a picture hung in front of them.
abstract class ProjectedSceneNode extends SceneNode {
  ProjectedSceneNode({
    required super.id,
    required super.position,
    super.hitRadiusMetres,
    super.visible,
    super.interactive,
    super.sortBias,
  });

  /// Extent is large and often surrounds the camera, so the renderer's
  /// screen-margin cull would wrongly discard geometry whose centre happens to
  /// be off screen — the near wall of a tunnel being the obvious case.
  @override
  bool get bypassesScreenCull => true;

  /// Never called; [paintProjected] is used instead.
  @override
  void paint(Canvas canvas, NodeRenderContext ctx) {}

  /// Draws in **screen space**. Use [ArCamera.projectWorld] or the helpers in
  /// [ProjectedRenderContext] to turn world points into pixels.
  void paintProjected(Canvas canvas, ProjectedRenderContext ctx);
}

/// What a [ProjectedSceneNode] gets to draw with.
class ProjectedRenderContext {
  const ProjectedRenderContext({
    required this.camera,
    required this.elapsed,
    required this.viewportSize,
  });

  final ArCamera camera;
  final Duration elapsed;
  final Size viewportSize;

  double get seconds => elapsed.inMicroseconds / 1e6;

  /// Projects a scene-space point to a pixel, or null if it is behind the
  /// camera. Returning null rather than clamping is deliberate: a polygon with
  /// one vertex behind the viewer cannot be drawn correctly without clipping in
  /// 3D, and a clamped vertex produces a wild streak across the screen.
  Offset? project(Vector3 scenePoint) => camera.project(scenePoint)?.screen;

  /// Projects a whole ring of points, giving up if any vertex is behind the
  /// camera.
  List<Offset>? projectAll(List<Vector3> scenePoints) {
    final out = <Offset>[];
    for (final point in scenePoints) {
      final projected = camera.project(point);
      if (projected == null) return null;
      out.add(projected.screen);
    }
    return out;
  }

  /// Depth in metres, for fog and draw ordering.
  double? depthOf(Vector3 scenePoint) => camera.project(scenePoint)?.depth;
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
