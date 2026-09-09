import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart';

import '../scene/scene_graph.dart';
import 'gallery_layout.dart';

/// Deterministic value noise, so a gallery looks rough but replays identically.
double _noise(double x, double seed) =>
    math.sin(x * 2.7 + seed) * 0.5 + math.sin(x * 6.3 + seed * 1.9) * 0.3;

/// The gallery itself: floor, ribs, roof and the darkness beyond.
///
/// Drawn as a single node rather than a dozen, because a tunnel is one
/// continuous surface and splitting it would put seams where the painter's
/// algorithm sorted two pieces inconsistently. Everything here is a quad strip
/// marching away from the worker, with each ring projected separately — which
/// is what produces genuine perspective rather than a scaled picture.
///
/// The strongest single cue is not the geometry but the **fog**. A real gallery
/// is lit only by cap lamps, so it fades to black within a few metres. Fading
/// the tunnel out with distance both looks right and quietly hides the far end,
/// where projection error and the limits of the room measurement would
/// otherwise show.
class MineGalleryNode extends ProjectedSceneNode {
  MineGalleryNode({
    required super.id,
    required this.layout,
    this.ringCount = 14,
    this.seed = 3,
    super.visible,
  }) : super(position: Vector3.zero(), hitRadiusMetres: 0.1, sortBias: -1.0);

  final GalleryLayout layout;

  /// Cross-sections drawn along the tunnel. Fourteen is enough that the ribs
  /// read as continuous while staying cheap on a budget phone.
  final int ringCount;

  final double seed;

  /// Distance at which the gallery has faded to nothing.
  double get _fogEnd => layout.lengthMetres;

  double _fog(double distance) {
    final t = (distance / _fogEnd).clamp(0.0, 1.0);
    // Squared falloff: cap-lamp light drops off fast, and a linear fade looks
    // like haze rather than darkness.
    return (1 - t * t).clamp(0.0, 1.0);
  }

  /// A point on the tunnel surface.
  ///
  /// [along] is metres down the axis, [lateral] is metres from the centre line
  /// (positive to the right), [height] is metres above the floor.
  Vector3 _point(double along, double lateral, double height) {
    // The scene frame has +Y forward, so the tunnel axis is +Y and the lateral
    // axis is +X. The layout's world bearing is applied by the scene rotation.
    return Vector3(lateral, along, height - layout.floorDropMetres);
  }

  /// Half-width at a given distance, wobbled so the ribs are not machined.
  double _halfWidthAt(double along) {
    final wobble = _noise(along * 0.45, seed) * 0.12;
    return math.max(0.6, layout.halfWidthMetres + wobble);
  }

  double _roofAt(double along) {
    final sag = _noise(along * 0.38, seed + 4) * 0.14;
    return math.max(1.9, layout.roofHeightMetres + sag);
  }

  @override
  void paintProjected(Canvas canvas, ProjectedRenderContext ctx) {
    final step = layout.lengthMetres / ringCount;

    // Far to near, so nearer rings paint over further ones — the painter's
    // algorithm standing in for a depth buffer we do not have.
    for (var i = ringCount - 1; i >= 0; i--) {
      final near = i * step;
      final far = (i + 1) * step;
      _paintSegment(canvas, ctx, near, far);
    }

    _paintRoofSupports(canvas, ctx, step);
  }

  /// One slice of tunnel: floor, two ribs and the roof between two rings.
  void _paintSegment(
    Canvas canvas,
    ProjectedRenderContext ctx,
    double near,
    double far,
  ) {
    final nw = _halfWidthAt(near);
    final fw = _halfWidthAt(far);
    final nr = _roofAt(near);
    final fr = _roofAt(far);

    final alpha = _fog((near + far) / 2);
    if (alpha <= 0.01) return;

    // Floor.
    _quad(
      canvas,
      ctx,
      [
        _point(near, -nw, 0),
        _point(near, nw, 0),
        _point(far, fw, 0),
        _point(far, -fw, 0),
      ],
      // Coal-measure floor: dark, slightly warm from dust.
      Color.lerp(const Color(0xFF2A2622), const Color(0xFF14120F), 1 - alpha)!
          .withValues(alpha: alpha),
    );

    // Left and right ribs. Slightly different shades so the tunnel has a
    // lit side, which reads as depth far more cheaply than shading gradients.
    _quad(
      canvas,
      ctx,
      [
        _point(near, -nw, 0),
        _point(near, -nw, nr),
        _point(far, -fw, fr),
        _point(far, -fw, 0),
      ],
      const Color(0xFF3A332C).withValues(alpha: alpha * 0.95),
    );
    _quad(
      canvas,
      ctx,
      [
        _point(near, nw, 0),
        _point(near, nw, nr),
        _point(far, fw, fr),
        _point(far, fw, 0),
      ],
      const Color(0xFF2E2822).withValues(alpha: alpha * 0.95),
    );

    // Roof.
    _quad(
      canvas,
      ctx,
      [
        _point(near, -nw, nr),
        _point(near, nw, nr),
        _point(far, fw, fr),
        _point(far, -fw, fr),
      ],
      const Color(0xFF201C18).withValues(alpha: alpha),
    );
  }

  /// Steel arches at intervals, as any supported gallery has.
  ///
  /// Worth the extra draws: roof support is the single most recognisable
  /// feature of an underground roadway, and Module 4 is about roof fall. A
  /// worker who has seen these in the drill has something to point at when a
  /// real one is deformed.
  void _paintRoofSupports(
    Canvas canvas,
    ProjectedRenderContext ctx,
    double step,
  ) {
    for (var i = 1; i < ringCount; i += 2) {
      final along = i * step;
      final alpha = _fog(along);
      if (alpha <= 0.02) continue;

      final w = _halfWidthAt(along);
      final r = _roofAt(along);

      final arch = ctx.projectAll([
        _point(along, -w, 0),
        _point(along, -w, r * 0.82),
        _point(along, -w * 0.72, r),
        _point(along, w * 0.72, r),
        _point(along, w, r * 0.82),
        _point(along, w, 0),
      ]);
      if (arch == null) continue;

      final path = Path()..moveTo(arch.first.dx, arch.first.dy);
      for (final point in arch.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }

      // Stroke width falls off with distance, which is what sells the arches as
      // receding rather than as flat lines drawn over the tunnel.
      final depth = ctx.depthOf(_point(along, 0, r)) ?? along;
      final width = (ctx.camera.focalPixels * 0.09 / math.max(depth, 0.5))
          .clamp(1.0, 14.0);

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFF6B6259).withValues(alpha: alpha * 0.9),
      );
    }
  }

  void _quad(
    Canvas canvas,
    ProjectedRenderContext ctx,
    List<Vector3> corners,
    Color color,
  ) {
    final projected = ctx.projectAll(corners);
    // Null means a corner is behind the camera. Skipping the whole quad is
    // correct: drawing it would need real 3D clipping, and clamping the vertex
    // instead produces a streak across the screen.
    if (projected == null) return;

    final path = Path()..moveTo(projected.first.dx, projected.first.dy);
    for (final point in projected.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();

    canvas.drawPath(path, Paint()..color = color);
  }
}

/// Rails and sleepers running down the gallery.
///
/// Small detail, disproportionate effect: a receding pair of rails is one of
/// the strongest perspective cues available, and it gives the eye something to
/// track that makes the tracking itself feel solid.
class MineRailsNode extends ProjectedSceneNode {
  MineRailsNode({
    required super.id,
    required this.layout,
    this.gaugeMetres = 0.76,
    super.visible,
  }) : super(position: Vector3.zero(), hitRadiusMetres: 0.1, sortBias: -0.9);

  /// Two feet six, the common Indian mine tub gauge.
  final double gaugeMetres;

  final GalleryLayout layout;

  Vector3 _point(double along, double lateral) =>
      Vector3(lateral, along, -layout.floorDropMetres + 0.02);

  @override
  void paintProjected(Canvas canvas, ProjectedRenderContext ctx) {
    const segments = 26;
    final step = layout.lengthMetres / segments;
    final half = gaugeMetres / 2;

    // Sleepers first, so the rails sit on top of them.
    for (var i = 0; i < segments; i++) {
      final along = i * step;
      final alpha = (1 - along / layout.lengthMetres).clamp(0.0, 1.0);
      if (alpha <= 0.03) continue;

      final ends = ctx.projectAll([
        _point(along, -half * 1.35),
        _point(along, half * 1.35),
      ]);
      if (ends == null) continue;

      final depth = ctx.depthOf(_point(along, 0)) ?? along;
      canvas.drawLine(
        ends.first,
        ends.last,
        Paint()
          ..strokeWidth =
              (ctx.camera.focalPixels * 0.05 / math.max(depth, 0.5)).clamp(1.0, 10.0)
          ..color = const Color(0xFF4A3F35).withValues(alpha: alpha * 0.75),
      );
    }

    for (final side in [-half, half]) {
      final points = <Offset>[];
      for (var i = 0; i <= segments; i++) {
        final projected = ctx.project(_point(i * step, side));
        if (projected == null) break;
        points.add(projected);
      }
      if (points.length < 2) continue;

      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          // Worn steel catches what little light there is.
          ..color = const Color(0xFF8A8378).withValues(alpha: 0.55),
      );
    }
  }
}

/// The lit mouth at the far end of the gallery.
///
/// Doubles as the evacuation target when the room scan found no real doorway.
/// A tunnel that simply fades to black gives a worker nothing to move toward,
/// and "find the way out" needs somewhere for the way out to be.
class GalleryPortalNode extends ProjectedSceneNode {
  GalleryPortalNode({
    required super.id,
    required this.layout,
    this.lit = true,
    super.visible,
    super.interactive = true,
  }) : super(
          position: Vector3(0, layout.portalDistanceMetres, -layout.floorDropMetres),
          hitRadiusMetres: 1.2,
          sortBias: -0.8,
        );

  final GalleryLayout layout;

  /// Whether the far side is daylight or another dark roadway.
  final bool lit;

  @override
  void paintProjected(Canvas canvas, ProjectedRenderContext ctx) {
    final distance = layout.portalDistanceMetres;
    final w = layout.halfWidthMetres * 0.78;
    final h = layout.roofHeightMetres * 0.86;
    final base = -layout.floorDropMetres;

    final corners = ctx.projectAll([
      Vector3(-w, distance, base),
      Vector3(-w, distance, base + h),
      Vector3(w, distance, base + h),
      Vector3(w, distance, base),
    ]);
    if (corners == null) return;

    final path = Path()..moveTo(corners.first.dx, corners.first.dy);
    for (final point in corners.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();

    final bounds = path.getBounds();
    if (bounds.isEmpty) return;

    canvas.drawPath(
      path,
      Paint()
        ..shader = RadialGradient(
          colors: lit
              ? const [Color(0xFFFFF3D6), Color(0xFFBFA97A), Color(0x00000000)]
              : const [Color(0xFF2C3742), Color(0xFF141A20), Color(0x00000000)],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(bounds),
    );

    // A soft halo, so the mouth glows into the roadway rather than sitting on
    // it as a flat shape.
    if (lit) {
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFFFFE9B0).withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }
  }
}
