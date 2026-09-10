import 'dart:math' as math;
import 'package:flutter/painting.dart';

import '../scene/scene_graph.dart';

/// The drawing vocabulary shared by every AR object.
///
/// Overlay graphics have a harder job than ordinary UI: they compete with a
/// live camera feed that is arbitrarily bright, cluttered and low contrast.
/// Anything soft or translucent disappears into it. So the rules here are
/// deliberately blunt — saturated fill, a bright hard outline, and a mark on
/// the floor underneath — and they are the same rules real safety signage
/// follows, for the same reason.
abstract final class Holo {
  /// Safety-signage colours, brightened for a screen held in daylight.
  ///
  /// ISO 7010 green is a deep #009639, which is legible on a printed sign lit
  /// by the sun but muddy when drawn over a camera image. These keep the
  /// signage *meaning* — green is the way out, red is the hazard, blue is a
  /// mandatory action — while raising the luminance enough to survive
  /// compositing.
  static const Color exitGreen = Color(0xFF00E27A);
  static const Color dangerRed = Color(0xFFFF4438);
  static const Color cautionAmber = Color(0xFFFFC400);
  static const Color mandatoryBlue = Color(0xFF3BA0FF);
  static const Color neutral = Color(0xFFEDF2F7);
  static const Color shadow = Color(0xFF05070A);

  /// Converts a width in **screen pixels** into canvas units.
  ///
  /// Nodes draw in metres under a canvas scaled by pixels-per-metre, so a
  /// stroke written as a plain number is multiplied by that scale: a "2 unit"
  /// outline is 2 metres wide, which at close range fills the screen. Every
  /// stroke and radius meant to be constant on screen has to come through here.
  static double px(NodeRenderContext ctx, double pixels) {
    if (ctx.pixelsPerMetre <= 0) return 0;
    return pixels / ctx.pixelsPerMetre;
  }

  /// A hard, bright outline. The single most effective thing for legibility
  /// over a camera feed, because it guarantees a contrast edge whatever is
  /// behind it.
  static Paint stroke(
    NodeRenderContext ctx, {
    Color color = neutral,
    double pixels = 2.5,
    double opacity = 1,
  }) =>
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = px(ctx, pixels)
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: opacity * ctx.atmosphericOpacity);

  /// A vertical gradient fill: lighter at the top, as though lit from above.
  ///
  /// Cheap, and it does most of the work of making a flat shape read as an
  /// object rather than a sticker.
  static Paint fill(
    NodeRenderContext ctx,
    Rect bounds, {
    required Color color,
    double opacity = 1,
    double lift = 0.35,
  }) {
    final alpha = opacity * ctx.atmosphericOpacity;
    return Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(color, const Color(0xFFFFFFFF), lift)!.withValues(alpha: alpha),
          color.withValues(alpha: alpha),
          Color.lerp(color, shadow, 0.28)!.withValues(alpha: alpha),
        ],
        stops: const [0, 0.55, 1],
      ).createShader(bounds);
  }

  /// A soft halo behind a shape, so it separates from a busy background.
  ///
  /// Blur radius is in screen pixels and capped, because a sigma expressed in
  /// canvas units becomes hundreds of pixels at close range and will exhaust
  /// the GPU.
  static Paint glow(
    NodeRenderContext ctx, {
    required Color color,
    double pixels = 14,
    double opacity = 0.5,
  }) =>
      Paint()
        ..color = color.withValues(alpha: opacity * ctx.atmosphericOpacity)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          px(ctx, math.min(pixels, 26)),
        );

  /// An ellipse on the floor directly beneath an object.
  ///
  /// Does more than decorate. The commonest failure of phone AR is content that
  /// reads as floating, and the reason is that the eye judges height from
  /// ground contact — with nothing on the floor there is no evidence of where
  /// an object *is*, so the brain places it nowhere. A contact mark supplies
  /// that evidence, and it also makes a genuine placement error visible
  /// instead of merely looking odd.
  static void contactShadow(
    Canvas canvas,
    NodeRenderContext ctx, {
    required double heightAboveFloor,
    required double radiusMetres,
    Color color = shadow,
  }) {
    final rect = Rect.fromCenter(
      center: Offset(0, heightAboveFloor),
      width: radiusMetres * 2,
      // Foreshortened: a circle on the floor is an ellipse from eye height.
      height: radiusMetres * 0.62,
    );

    canvas.drawOval(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.55 * ctx.atmosphericOpacity),
            color.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
  }

  /// A ring on the floor plus a light column rising from it.
  ///
  /// The strongest available cue that an object belongs to the ground. Used on
  /// anything a worker must walk to, because "where is it standing" is exactly
  /// the question they need answered.
  static void groundAnchor(
    Canvas canvas,
    NodeRenderContext ctx, {
    required double heightAboveFloor,
    required double radiusMetres,
    required Color color,
    double beamHeight = 0,
    double pulse = 0,
  }) {
    final alpha = ctx.atmosphericOpacity;

    // Column of light, brightest at the floor.
    if (beamHeight > 0) {
      final beam = Rect.fromLTRB(
        -radiusMetres * 0.72,
        heightAboveFloor - beamHeight,
        radiusMetres * 0.72,
        heightAboveFloor,
      );
      canvas.drawRect(
        beam,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              color.withValues(alpha: 0.30 * alpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(beam),
      );
    }

    // Two rings: a solid inner one and a pulsing outer one that expands and
    // fades, which reads as "come here" without any text.
    final ringRect = Rect.fromCenter(
      center: Offset(0, heightAboveFloor),
      width: radiusMetres * 2,
      height: radiusMetres * 0.62,
    );
    canvas.drawOval(
      ringRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = px(ctx, 2.5)
        ..color = color.withValues(alpha: 0.85 * alpha),
    );

    if (pulse > 0) {
      final t = pulse % 1.0;
      final grow = 1 + t * 0.8;
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(0, heightAboveFloor),
          width: radiusMetres * 2 * grow,
          height: radiusMetres * 0.62 * grow,
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = px(ctx, 2)
          ..color = color.withValues(alpha: (1 - t) * 0.6 * alpha),
      );
    }
  }

  /// Draws a path filled, outlined and haloed in one call — the standard
  /// treatment, so every object in the scene reads as one family.
  static void shape(
    Canvas canvas,
    NodeRenderContext ctx,
    Path path, {
    required Color color,
    Color outline = neutral,
    double opacity = 1,
    double outlinePixels = 2.5,
    bool halo = true,
  }) {
    final bounds = path.getBounds();
    if (bounds.isEmpty) return;

    if (halo) {
      canvas.drawPath(
        path,
        glow(ctx, color: color, pixels: 12, opacity: 0.35 * opacity),
      );
    }
    canvas.drawPath(path, fill(ctx, bounds, color: color, opacity: opacity));
    canvas.drawPath(
      path,
      stroke(ctx, color: outline, pixels: outlinePixels, opacity: opacity),
    );
  }
}
