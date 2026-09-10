import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../nodes/holo_style.dart';
import '../scene/scene_graph.dart';

/// Cheap deterministic value noise.
///
/// Deterministic matters: animation is a pure function of elapsed time, so a
/// scenario replays identically and a golden test can assert on a frame. A real
/// Perlin implementation would be nicer to look at and is not worth the cost on
/// the hardware this has to run on.
double _noise(double x, double seed) {
  return math.sin(x * 1.7 + seed) * 0.5 +
      math.sin(x * 3.9 + seed * 2.3) * 0.3 +
      math.sin(x * 8.1 + seed * 4.7) * 0.2;
}

/// A burning fire, drawn as stacked flame tongues over a hot base.
///
/// The base is drawn distinctly from the tongues for a reason that is
/// pedagogical rather than decorative: extinguisher technique requires aiming at
/// the *base* of a fire, and the scenario scores that. The worker has to be able
/// to see the base as a separate thing before being asked to aim at it.
class FireNode extends SceneNode {
  FireNode({
    required super.id,
    required super.position,
    this.heightMetres = 1.1,
    this.widthMetres = 0.8,
    this.intensity = 1.0,
    this.seed = 0,
    super.visible,
    super.interactive = false,
  }) : super(hitRadiusMetres: 0.6, sortBias: 0.02);

  final double heightMetres;
  final double widthMetres;

  /// 0..1+. Rises when the worker delays or acts wrongly, shrinks as the fire is
  /// suppressed. The visual consequence of hesitating is the whole point.
  double intensity;

  final double seed;

  /// Base of the fire in scene space — the point extinguisher aim is scored
  /// against. Sits at the node origin, which is the floor contact.
  double get baseHeightOffset => 0;

  @override
  void paint(Canvas canvas, NodeRenderContext ctx) {
    if (intensity <= 0) return;
    final t = ctx.seconds;
    final scale = intensity.clamp(0.0, 2.0);

    // Ground first, and it matters more than the flame. A fire with no mark
    // beneath it reads as a sprite hanging in the air — which was exactly the
    // complaint — because the eye judges an object's height from where it meets
    // the floor and a bare flame gives it nothing to judge from.
    Holo.contactShadow(
      canvas,
      ctx,
      heightAboveFloor: 0,
      radiusMetres: widthMetres * 1.5 * scale,
    );

    // Hot pool of light on the floor, sitting inside the shadow.
    final pool = Rect.fromCenter(
      center: Offset.zero,
      width: widthMetres * 2.4 * scale,
      height: widthMetres * 0.78 * scale,
    );
    canvas.drawOval(
      pool,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFFFB74D)
                .withValues(alpha: 0.55 * ctx.atmosphericOpacity),
            const Color(0xFFFF6D00)
                .withValues(alpha: 0.22 * ctx.atmosphericOpacity),
            const Color(0x00FF6D00),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(pool),
    );

    // Three tongues, coolest and largest at the back. Drawn as solid shapes
    // with only a small screen-space blur, rather than the heavy metre-scale
    // blur used before, which turned the whole fire into an orange smudge.
    _paintTongue(canvas, ctx, t, scale, 1.00, const Color(0xFFE64A19), 0.0, 0.55);
    _paintTongue(canvas, ctx, t, scale, 0.70, const Color(0xFFFF9100), 1.9, 0.80);
    _paintTongue(canvas, ctx, t, scale, 0.40, const Color(0xFFFFE082), 3.4, 0.95);

    _paintEmbers(canvas, ctx, t, scale);
  }

  /// One flame tongue: a closed, wavering silhouette.
  void _paintTongue(
    Canvas canvas,
    NodeRenderContext ctx,
    double t,
    double scale,
    double sizeFactor,
    Color color,
    double phase,
    double opacity,
  ) {
    final h = heightMetres * scale * sizeFactor;
    final w = widthMetres * scale * sizeFactor;

    // Built as one closed outline up the left side and down the right, so the
    // silhouette is continuous instead of two independent edges that can cross.
    final path = Path()..moveTo(-w / 2, 0);

    const steps = 14;
    for (var i = 0; i <= steps; i++) {
      final f = i / steps;
      final taper = math.sin((1 - f) * math.pi / 2);
      final waver = _noise(f * 2.4 + t * 3.4, seed + phase) * 0.20 * f;
      path.lineTo(
        -w / 2 * (1 - f * 0.86) + waver * w,
        -h * f * (0.30 + 0.70 * taper),
      );
    }
    for (var i = steps; i >= 0; i--) {
      final f = i / steps;
      final taper = math.sin((1 - f) * math.pi / 2);
      final waver = _noise(f * 2.4 + t * 3.4 + 11, seed + phase) * 0.20 * f;
      path.lineTo(
        w / 2 * (1 - f * 0.86) + waver * w,
        -h * f * (0.30 + 0.70 * taper),
      );
    }
    path.close();

    final alpha = opacity * ctx.atmosphericOpacity;
    final bounds = path.getBounds();
    if (bounds.isEmpty) return;

    // Halo in screen pixels, so it stays a glow rather than becoming a
    // full-screen blur when the worker steps close.
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: alpha * 0.4)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, Holo.px(ctx, 10)),
    );

    // Vertical gradient: white-hot at the base, deepening toward the tip, which
    // is the way a real flame actually reads.
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Color.lerp(color, const Color(0xFFFFF3C4), 0.55)!
                .withValues(alpha: alpha),
            color.withValues(alpha: alpha),
            color.withValues(alpha: alpha * 0.55),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(bounds),
    );
  }

  /// Sparks lifting off the fire.
  ///
  /// Small, bright and crisp: a handful of hard dots do more to sell a fire as
  /// live than any amount of extra flame blur, and they cost almost nothing.
  void _paintEmbers(
    Canvas canvas,
    NodeRenderContext ctx,
    double t,
    double scale,
  ) {
    const count = 12;
    final alpha = ctx.atmosphericOpacity;

    for (var i = 0; i < count; i++) {
      final phase = seed + i * 1.618;
      // Each ember has its own lifetime, so they do not pulse in unison.
      final life = ((t * 0.55 + phase) % 1.0);
      final rise = life * heightMetres * 2.1 * scale;
      final drift = _noise(life * 2.2 + phase, seed) * widthMetres * 0.7;
      final fade = (1 - life) * (life < 0.12 ? life / 0.12 : 1);

      if (fade <= 0.02) continue;

      canvas.drawCircle(
        Offset(drift, -rise),
        Holo.px(ctx, 1.6 + 1.4 * (1 - life)),
        Paint()
          ..color = Color.lerp(
            const Color(0xFFFFE082),
            const Color(0xFFFF5722),
            life,
          )!
              .withValues(alpha: fade * 0.9 * alpha),
      );
    }
  }
}

/// One smoke puff. Plain fields rather than a class hierarchy because there are
/// a couple of hundred of these and they are updated every frame.
class _Puff {
  _Puff({
    required this.offset,
    required this.birth,
    required this.lifetime,
    required this.radius,
    required this.drift,
  });

  Offset offset;
  double birth;
  double lifetime;
  double radius;
  double drift;
}

/// A rising, spreading smoke column.
///
/// Smoke is the actual killer in most fire fatalities, so it is modelled as a
/// hazard the worker must route around rather than as set dressing. It also
/// progressively obscures the scene, which is what forces the "stay low, move
/// fast" behaviour the drill is teaching.
class SmokeColumnNode extends SceneNode {
  SmokeColumnNode({
    required super.id,
    required super.position,
    this.puffCount = 46,
    this.riseMetresPerSecond = 0.85,
    this.spreadMetres = 1.4,
    this.density = 1.0,
    this.seed = 7,
    super.visible,
    super.interactive = false,
  }) : super(hitRadiusMetres: 1.0, sortBias: -0.02) {
    _seed();
  }

  final int puffCount;
  final double riseMetresPerSecond;
  final double spreadMetres;

  /// 0..1. Tracks fire intensity.
  double density;

  final double seed;

  final List<_Puff> _puffs = [];
  final math.Random _random = math.Random(11);

  void _seed() {
    for (var i = 0; i < puffCount; i++) {
      _puffs.add(_Puff(
        offset: Offset.zero,
        // Staggered births so the column is already established on frame one,
        // rather than erupting from nothing when the step starts.
        birth: -_random.nextDouble() * 4.0,
        lifetime: 3.0 + _random.nextDouble() * 2.5,
        radius: 0.18 + _random.nextDouble() * 0.22,
        drift: (_random.nextDouble() - 0.5) * 0.5,
      ));
    }
  }

  @override
  void paint(Canvas canvas, NodeRenderContext ctx) {
    if (density <= 0) return;
    final t = ctx.seconds;
    final alpha = ctx.atmosphericOpacity * density;

    for (var i = 0; i < _puffs.length; i++) {
      final puff = _puffs[i];
      var age = t - puff.birth;
      if (age > puff.lifetime) {
        // Recycle in place rather than allocating.
        puff.birth = t;
        age = 0;
      }
      if (age < 0) continue;

      final life = (age / puff.lifetime).clamp(0.0, 1.0);
      final rise = age * riseMetresPerSecond;
      final wander = _noise(age * 0.9 + i, seed) * spreadMetres * 0.35 * life;
      final x = puff.drift * rise + wander;
      final y = -rise;

      // Fade in fast, out slow; grow throughout.
      final fade = life < 0.15 ? life / 0.15 : (1 - life) / 0.85;
      final radius = puff.radius * (1 + life * 2.4);

      // Radial falloff instead of a blurred disc. A gradient gives a soft edge
      // for free, at a fraction of the cost of a MaskFilter, and it reads as
      // volume rather than as an out-of-focus circle — the previous version's
      // main flaw.
      final rect = Rect.fromCircle(center: Offset(x, y), radius: radius);
      final tint = Color.lerp(
        const Color(0xFF2B3138),
        const Color(0xFF9BA7B4),
        life * 0.75,
      )!;

      canvas.drawOval(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              tint.withValues(alpha: alpha * fade * 0.55),
              tint.withValues(alpha: alpha * fade * 0.30),
              tint.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.55, 1.0],
          ).createShader(rect),
      );
    }
  }
}

/// Full-viewport smoke haze drawn over the whole AR view.
///
/// Distinct from [SmokeColumnNode]: that is smoke *in the world* at a location,
/// this is the loss of visibility from being *inside* the smoke. Rendered as a
/// screen-space overlay because it is not at any particular depth, and it darkens
/// from the top down, mirroring how a real compartment fills.
class SmokeHazePainter extends CustomPainter {
  const SmokeHazePainter({
    required this.density,
    required this.seconds,
  });

  /// 0 clear, 1 barely able to see.
  final double density;
  final double seconds;

  @override
  void paint(Canvas canvas, Size size) {
    if (density <= 0.01) return;
    final d = density.clamp(0.0, 1.0);

    // Smoke layers down from the ceiling, which is why staying low works.
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        const Color(0xFF263238).withValues(alpha: 0.86 * d),
        const Color(0xFF37474F).withValues(alpha: 0.62 * d),
        const Color(0xFF546E7A).withValues(alpha: 0.22 * d),
      ],
      stops: const [0.0, 0.45, 1.0],
    );

    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));

    // A few slow drifting blobs so the haze breathes instead of sitting flat.
    final blobPaint = Paint()
      ..color = const Color(0xFF90A4AE).withValues(alpha: 0.05 * d)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 48);
    for (var i = 0; i < 4; i++) {
      final phase = seconds * 0.12 + i * 1.7;
      canvas.drawCircle(
        Offset(
          size.width * (0.5 + 0.42 * math.sin(phase)),
          size.height * (0.32 + 0.26 * math.cos(phase * 0.8)),
        ),
        size.width * 0.36,
        blobPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SmokeHazePainter oldDelegate) =>
      oldDelegate.density != density || oldDelegate.seconds != seconds;
}
