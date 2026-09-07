import 'dart:math' as math;

import 'package:flutter/material.dart';

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
    final alpha = ctx.atmosphericOpacity;
    final t = ctx.seconds;
    final scale = intensity.clamp(0.0, 2.0);

    // Warm ground glow first, so tongues composite over it.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: widthMetres * 1.9 * scale,
        height: widthMetres * 0.5 * scale,
      ),
      Paint()
        ..color = const Color(0xFFFF6D00).withValues(alpha: alpha * 0.30)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, ctx.blurUnits(18)),
    );

    // Three tongues, outermost and coolest first.
    _paintTongue(canvas, ctx, t, alpha * 0.55, scale, 1.0, const Color(0xFFD84315), 0.0);
    _paintTongue(canvas, ctx, t, alpha * 0.75, scale, 0.72, const Color(0xFFFF9100), 1.9);
    _paintTongue(canvas, ctx, t, alpha * 0.95, scale, 0.42, const Color(0xFFFFD54F), 3.4);
  }

  void _paintTongue(
    Canvas canvas,
    NodeRenderContext ctx,
    double t,
    double alpha,
    double scale,
    double sizeFactor,
    Color color,
    double phase,
  ) {
    final h = heightMetres * scale * sizeFactor;
    final w = widthMetres * scale * sizeFactor;
    final path = Path()..moveTo(-w / 2, 0);

    const steps = 11;
    for (var i = 0; i <= steps; i++) {
      final f = i / steps;
      // Flame narrows toward the tip and wavers more the higher it goes.
      final taper = math.sin((1 - f) * math.pi / 2);
      final waver = _noise(f * 2.2 + t * 3.1, seed + phase) * 0.16 * f;
      path.lineTo((-w / 2 + w * f) + waver * w, -h * f * (0.35 + 0.65 * taper));
    }
    for (var i = steps; i >= 0; i--) {
      final f = i / steps;
      final taper = math.sin((1 - f) * math.pi / 2);
      final waver = _noise(f * 2.2 + t * 3.1 + 10, seed + phase) * 0.16 * f;
      path.lineTo(
        (-w / 2 + w * f) + waver * w,
        -h * f * (0.35 + 0.65 * taper) + 0.06 * (1 - f),
      );
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, ctx.blurUnits(6)),
    );
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

      canvas.drawCircle(
        Offset(x, y),
        radius,
        Paint()
          ..color = Color.lerp(
                const Color(0xFF37474F),
                const Color(0xFF90A4AE),
                life * 0.6,
              )!
              .withValues(alpha: alpha * fade * 0.42)
          // Screen-space, and capped. Expressed in metres this reached a
          // ~450px sigma across 46 particles and took the GPU down with it.
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, ctx.blurUnits(20)),
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
