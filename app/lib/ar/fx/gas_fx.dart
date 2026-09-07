import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../scene/scene_graph.dart';

/// A drifting cloud of gas.
///
/// Invisible in reality, which is exactly the danger — so it is rendered as a
/// faint shimmer rather than an obvious coloured blob. A worker who can see the
/// hazard clearly has not learned anything about a hazard they cannot see. The
/// real detection channel in this drill is the meter reading, and the visual is
/// only a hint.
class GasCloudNode extends SceneNode {
  GasCloudNode({
    required super.id,
    required super.position,
    required this.radiusMetres,
    this.concentration = 1.0,
    this.tint = const Color(0xFF80CBC4),
    this.puffCount = 20,
    this.seed = 3,
    super.visible,
    super.interactive = false,
  }) : super(hitRadiusMetres: radiusMetres, sortBias: -0.03);

  /// Radius at which the concentration has fallen to roughly nothing.
  final double radiusMetres;

  /// 0..1 at the centre.
  double concentration;

  final Color tint;
  final int puffCount;
  final double seed;

  @override
  void paint(Canvas canvas, NodeRenderContext ctx) {
    if (concentration <= 0.01) return;
    final t = ctx.seconds;
    final alpha = ctx.atmosphericOpacity * concentration;

    for (var i = 0; i < puffCount; i++) {
      final phase = seed + i * 2.399;
      final drift = math.sin(t * 0.35 + phase) * radiusMetres * 0.28;
      final rise = math.cos(t * 0.27 + phase * 1.3) * radiusMetres * 0.2;
      final distance = radiusMetres * (0.25 + 0.7 * ((i % 5) / 5));

      final x = math.cos(phase) * distance + drift;
      final y = math.sin(phase) * distance * 0.55 + rise;

      canvas.drawCircle(
        Offset(x, y),
        radiusMetres * 0.42,
        Paint()
          ..color = tint.withValues(alpha: alpha * 0.085)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            radiusMetres * 0.35,
          ),
      );
    }
  }
}

/// A windsock, showing which way the air is moving.
///
/// Approach direction is the first decision at any gas release, and the windsock
/// is how it is made on a real site. Putting one in the scene means the worker
/// has to look for it rather than being told the answer.
class WindsockNode extends SceneNode {
  WindsockNode({
    required super.id,
    required super.position,
    required this.windBearingRadians,
    super.visible,
    super.interactive = false,
  }) : super(hitRadiusMetres: 0.5);

  /// Direction the wind is blowing *towards*, in scene space.
  final double windBearingRadians;

  @override
  void paint(Canvas canvas, NodeRenderContext ctx) {
    final alpha = ctx.atmosphericOpacity;
    final flutter = math.sin(ctx.seconds * 2.6) * 0.06;

    // Mast.
    canvas.drawLine(
      Offset.zero,
      const Offset(0, -1.8),
      Paint()
        ..color = Colors.white.withValues(alpha: alpha * 0.8)
        ..strokeWidth = 0.05,
    );

    // Sock, drawn as a tapering cone lying along the wind direction. Only the
    // horizontal component is used: the node is billboarded, so this reads as
    // "blowing left" or "blowing right" from wherever the worker stands.
    final direction = math.sin(windBearingRadians);
    final path = Path()
      ..moveTo(0, -1.75)
      ..lineTo(direction * 0.95, -1.62 + flutter)
      ..lineTo(direction * 0.95, -1.30 + flutter)
      ..lineTo(0, -1.05)
      ..close();

    canvas.drawPath(
      path,
      Paint()..color = const Color(0xFFFF7043).withValues(alpha: alpha * 0.9),
    );

    // Stripe, so the direction reads even at a distance.
    canvas.drawPath(
      Path()
        ..moveTo(direction * 0.42, -1.56 + flutter * 0.6)
        ..lineTo(direction * 0.62, -1.53 + flutter * 0.8)
        ..lineTo(direction * 0.62, -1.34 + flutter * 0.8)
        ..lineTo(direction * 0.42, -1.30 + flutter * 0.6)
        ..close(),
      Paint()..color = Colors.white.withValues(alpha: alpha * 0.85),
    );
  }
}

/// Readings from a four-gas detector, as a real one would report them.
///
/// Values and alarm points follow standard confined-space practice: 19.5%
/// oxygen is the deficiency threshold, methane's explosive range is 5-15% in
/// air, and carbon monoxide is reported in parts per million against a 50 ppm
/// occupational limit.
class GasReading {
  const GasReading({
    required this.methanePercent,
    required this.oxygenPercent,
    required this.carbonMonoxidePpm,
  });

  final double methanePercent;
  final double oxygenPercent;
  final double carbonMonoxidePpm;

  static const double lowerExplosiveLimit = 5.0;
  static const double upperExplosiveLimit = 15.0;
  static const double oxygenDeficient = 19.5;
  static const double oxygenEnriched = 23.5;
  static const double coOccupationalLimit = 50;

  /// Within the range where methane will ignite.
  bool get isExplosive =>
      methanePercent >= lowerExplosiveLimit &&
      methanePercent <= upperExplosiveLimit;

  /// Above the explosive range. Emphatically *not* safe: this pocket becomes
  /// explosive the moment it mixes with fresh air, which is what happens as
  /// soon as anyone opens a door or starts a fan.
  bool get isOverRich => methanePercent > upperExplosiveLimit;

  bool get isOxygenDeficient => oxygenPercent < oxygenDeficient;

  bool get isCarbonMonoxideHigh => carbonMonoxidePpm > coOccupationalLimit;

  bool get isAnyAlarm =>
      isExplosive || isOverRich || isOxygenDeficient || isCarbonMonoxideHigh;

  /// Safe only when every channel is in range.
  bool get isClear => !isAnyAlarm && methanePercent < lowerExplosiveLimit;
}
