import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ar_camera.dart';
import 'scene_graph.dart';

/// A node that survived culling, paired with its projection for this frame.
class _DrawItem {
  const _DrawItem(this.node, this.projected, this.angle);

  final SceneNode node;
  final ProjectedPoint projected;
  final double angle;
}

/// Draws a scene graph over the camera feed.
///
/// Uses the painter's algorithm — sort far-to-near and draw in order. That is
/// the right call here rather than a depth buffer: scene counts are in the tens,
/// almost everything is a translucent billboard (which a depth buffer handles
/// badly anyway), and it costs one sort per frame on a list that small.
class ArScenePainter extends CustomPainter {
  ArScenePainter({
    required this.camera,
    required this.nodes,
    required this.elapsed,
    this.fadeStartMetres = 8,
    this.fadeEndMetres = 25,
    this.cullMarginPixels = 160,
  }) : super(repaint: null);

  final ArCamera camera;
  final List<SceneNode> nodes;
  final Duration elapsed;

  /// Distance at which atmospheric fade begins and where it bottoms out.
  final double fadeStartMetres;
  final double fadeEndMetres;

  /// Nodes projecting this far outside the viewport are skipped. The margin
  /// keeps partially-visible content (a wide gas cloud, say) from popping.
  final double cullMarginPixels;

  @override
  void paint(Canvas canvas, Size size) {
    final visible = <_DrawItem>[];

    for (final node in nodes) {
      if (!node.visible) continue;
      final projected = camera.project(node.position);
      if (projected == null) continue; // Behind the camera.

      final radiusPixels = node.hitRadiusMetres * projected.scale;
      final margin = cullMarginPixels + radiusPixels;
      final p = projected.screen;
      if (p.dx < -margin ||
          p.dy < -margin ||
          p.dx > size.width + margin ||
          p.dy > size.height + margin) {
        continue;
      }

      visible.add(_DrawItem(node, projected, camera.angleTo(node.position)));
    }

    // Far to near, with sortBias letting coincident nodes declare an order.
    visible.sort((a, b) {
      final da = a.projected.depth - a.node.sortBias;
      final db = b.projected.depth - b.node.sortBias;
      return db.compareTo(da);
    });

    for (final item in visible) {
      final ctx = NodeRenderContext(
        depth: item.projected.depth,
        pixelsPerMetre: item.projected.scale,
        elapsed: elapsed,
        atmosphericOpacity: _atmosphericOpacity(item.projected.depth),
        viewportSize: size,
        screenPosition: item.projected.screen,
        angleFromCentre: item.angle,
      );

      canvas.save();
      canvas.translate(item.projected.screen.dx, item.projected.screen.dy);
      // One canvas unit becomes one metre, so nodes draw in real dimensions.
      canvas.scale(item.projected.scale);
      item.node.paint(canvas, ctx);
      canvas.restore();
    }
  }

  double _atmosphericOpacity(double depth) {
    if (depth <= fadeStartMetres) return 1.0;
    if (depth >= fadeEndMetres) return 0.35;
    final t = (depth - fadeStartMetres) / (fadeEndMetres - fadeStartMetres);
    return 1.0 - 0.65 * t;
  }

  @override
  bool shouldRepaint(covariant ArScenePainter oldDelegate) {
    // Pose changes every frame while a scenario is live, so this is effectively
    // always true. Compared anyway so a paused, still scene stops repainting.
    return oldDelegate.elapsed != elapsed ||
        !identical(oldDelegate.nodes, nodes) ||
        oldDelegate.camera.pose.timestamp != camera.pose.timestamp ||
        oldDelegate.camera.viewportSize != camera.viewportSize;
  }
}

/// Result of a tap against the scene.
class SceneHit {
  const SceneHit({
    required this.node,
    required this.distancePixels,
    required this.depth,
  });

  final SceneNode node;

  /// How far the tap landed from the node's projected centre.
  final double distancePixels;

  final double depth;
}

/// Screen-space hit test against the projected scene.
///
/// Returns the nearest interactive node whose on-screen radius contains the tap.
/// Ties break toward the closer node, which matches the intuition that you touch
/// what is in front. A small minimum radius keeps distant targets tappable with
/// a gloved thumb — the alternative is a worker jabbing at a 4-pixel exit sign.
SceneHit? hitTestScene({
  required ArCamera camera,
  required List<SceneNode> nodes,
  required Offset tap,
  double minimumRadiusPixels = 44,
}) {
  SceneHit? best;

  for (final node in nodes) {
    if (!node.visible || !node.interactive) continue;
    final projected = camera.project(node.position);
    if (projected == null) continue;

    final radius = math.max(
      minimumRadiusPixels,
      node.hitRadiusMetres * projected.scale,
    );
    final distance = (projected.screen - tap).distance;
    if (distance > radius) continue;

    if (best == null || projected.depth < best.depth) {
      best = SceneHit(
        node: node,
        distancePixels: distance,
        depth: projected.depth,
      );
    }
  }

  return best;
}

/// Renders a scene graph and routes taps to it.
///
/// Deliberately not a [StatefulWidget] with its own ticker: the owning scenario
/// drives `elapsed` so that scoring, animation and the step machine all advance
/// off one clock. That keeps a replay or a test deterministic.
class ArSceneView extends StatelessWidget {
  const ArSceneView({
    super.key,
    required this.camera,
    required this.nodes,
    required this.elapsed,
    this.onNodeTap,
    this.onEmptyTap,
    this.onDrag,
    this.onPressStart,
    this.onPressEnd,
  });

  final ArCamera camera;
  final List<SceneNode> nodes;
  final Duration elapsed;
  final void Function(SceneNode node)? onNodeTap;
  final void Function(Offset position)? onEmptyTap;

  /// Screen drag, for gestures like pulling an extinguisher pin.
  final void Function(Offset delta)? onDrag;

  /// Press and hold, for squeezing an extinguisher handle.
  final VoidCallback? onPressStart;
  final VoidCallback? onPressEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final hit = hitTestScene(
          camera: camera,
          nodes: nodes,
          tap: details.localPosition,
        );
        if (hit != null) {
          onNodeTap?.call(hit.node);
        } else {
          onEmptyTap?.call(details.localPosition);
        }
      },
      onPanUpdate: onDrag == null ? null : (d) => onDrag!(d.delta),
      // Long-press rather than tap-down for the squeeze, so a tap meant for a
      // scene node is never misread as starting a discharge.
      onLongPressStart: onPressStart == null ? null : (_) => onPressStart!(),
      onLongPressEnd: onPressEnd == null ? null : (_) => onPressEnd!(),
      onLongPressCancel: onPressEnd,
      child: CustomPaint(
        size: Size.infinite,
        painter: ArScenePainter(
          camera: camera,
          nodes: nodes,
          elapsed: elapsed,
        ),
      ),
    );
  }
}
