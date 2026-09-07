import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart' show Colors, IconData, Icons;
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../scene/scene_graph.dart';

/// Shared drawing conventions for every node in the library.
///
/// The canvas is in metres with Y increasing downward, and the node's origin is
/// wherever [SceneNode.position] put it. Content that stands on the floor is
/// therefore drawn with *negative* Y going up from its own base. Getting that
/// sign backwards is the single easiest mistake to make here, so nodes below are
/// consistent about anchoring at their base.
const double _kOutlineMetres = 0.03;

/// A pulsing ring drawn flat on the ground beneath something.
///
/// Serves two purposes at once: it grounds a billboard that would otherwise look
/// like it is floating, and it is a far more legible "go here" affordance than an
/// arrow for someone who has never used AR before.
class GroundRingNode extends SceneNode {
  GroundRingNode({
    required super.id,
    required super.position,
    required this.color,
    this.radiusMetres = 0.6,
    this.pulse = true,
    super.visible,
  }) : super(hitRadiusMetres: radiusMetres, sortBias: -0.05);

  final Color color;
  final double radiusMetres;
  final bool pulse;

  @override
  void paint(Canvas canvas, NodeRenderContext ctx) {
    final phase = pulse ? (math.sin(ctx.seconds * 2.4) * 0.5 + 0.5) : 1.0;
    final alpha = ctx.atmosphericOpacity * (0.35 + 0.35 * phase);

    // Foreshortened into an ellipse. The 0.32 vertical squash approximates a
    // circle on the floor viewed from roughly standing eye height; a true
    // ground-plane projection is not worth the cost at this scale.
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: radiusMetres * 2,
      height: radiusMetres * 2 * 0.32,
    );

    canvas.drawOval(
      rect,
      Paint()
        ..color = color.withValues(alpha: alpha * 0.25)
        ..style = PaintingStyle.fill,
    );
    canvas.drawOval(
      rect,
      Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = _kOutlineMetres,
    );
  }
}

/// A doorway: frame, leaf, and an optional sign panel above it.
///
/// Used for fire exits, the decoy locked door, and the lift that must never be
/// taken during a fire. All three look like plausible doors on purpose — a decoy
/// that announces itself teaches nothing.
class DoorwayNode extends SceneNode {
  DoorwayNode({
    required super.id,
    required super.position,
    required this.frameColor,
    this.widthMetres = 0.95,
    this.heightMetres = 2.05,
    this.signColor,
    this.signIcon,
    this.signLabel,
    this.highlight = false,
    super.visible,
    super.interactive = true,
  }) : super(hitRadiusMetres: 0.85);

  final Color frameColor;
  final double widthMetres;
  final double heightMetres;

  /// Panel above the door. Null draws a bare doorway.
  final Color? signColor;
  final IconData? signIcon;
  final String? signLabel;

  /// Draws an attention ring. Set while the step machine is hinting.
  bool highlight;

  @override
  void paint(Canvas canvas, NodeRenderContext ctx) {
    final alpha = ctx.atmosphericOpacity;
    final halfWidth = widthMetres / 2;

    // Anchored at the base: the doorway rises to negative Y.
    final doorRect = Rect.fromLTRB(-halfWidth, -heightMetres, halfWidth, 0);

    // Dark opening, so the doorway reads as a hole rather than a panel.
    canvas.drawRRect(
      RRect.fromRectAndRadius(doorRect, const Radius.circular(0.04)),
      Paint()..color = const Color(0xFF0B0E13).withValues(alpha: alpha * 0.72),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(doorRect, const Radius.circular(0.04)),
      Paint()
        ..color = frameColor.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = _kOutlineMetres * 2,
    );

    if (highlight) {
      final phase = math.sin(ctx.seconds * 3.2) * 0.5 + 0.5;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          doorRect.inflate(0.09),
          const Radius.circular(0.08),
        ),
        Paint()
          ..color = frameColor.withValues(alpha: alpha * (0.3 + 0.5 * phase))
          ..style = PaintingStyle.stroke
          ..strokeWidth = _kOutlineMetres * 2.4,
      );
    }

    final sign = signColor;
    if (sign != null) {
      _paintSignPanel(canvas, ctx, doorRect, sign);
    }
  }

  void _paintSignPanel(
    Canvas canvas,
    NodeRenderContext ctx,
    Rect doorRect,
    Color sign,
  ) {
    final alpha = ctx.atmosphericOpacity;
    const panelHeight = 0.34;
    const gap = 0.12;
    final panel = Rect.fromLTRB(
      doorRect.left + 0.05,
      doorRect.top - gap - panelHeight,
      doorRect.right - 0.05,
      doorRect.top - gap,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(panel, const Radius.circular(0.05)),
      Paint()..color = sign.withValues(alpha: alpha * 0.92),
    );

    final icon = signIcon;
    if (icon != null) {
      paintIconGlyph(
        canvas: canvas,
        icon: icon,
        center: panel.center,
        sizeMetres: panelHeight * 0.72,
        color: Colors.white.withValues(alpha: alpha),
      );
    }
  }
}

/// A flat billboard carrying an icon and a short caption.
///
/// The workhorse for equipment: extinguishers, gas detectors, PPE items, valves.
class BillboardNode extends SceneNode {
  BillboardNode({
    required super.id,
    required super.position,
    required this.icon,
    required this.color,
    this.label,
    this.sizeMetres = 0.55,
    this.showGroundRing = false,
    this.highlight = false,
    super.visible,
    super.interactive = true,
    super.sortBias,
  }) : super(hitRadiusMetres: sizeMetres * 0.85);

  final IconData icon;

  /// Mutable: scenarios recolour a billboard to show selection, completion or a
  /// wrong choice, which is the clearest feedback available without text.
  Color color;

  final String? label;
  final double sizeMetres;
  final bool showGroundRing;
  bool highlight;

  @override
  void paint(Canvas canvas, NodeRenderContext ctx) {
    final alpha = ctx.atmosphericOpacity;
    final half = sizeMetres / 2;
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: sizeMetres,
      height: sizeMetres,
    );

    // Looking straight at something brightens it. A gentle but effective cue
    // that gaze is the primary pointing device in a markerless AR view.
    final gazeBoost = (1.0 - (ctx.angleFromCentre / 0.35)).clamp(0.0, 1.0);

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(half * 0.28)),
      Paint()..color = const Color(0xFF0B0E13).withValues(alpha: alpha * 0.65),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(half * 0.28)),
      Paint()
        ..color = color.withValues(alpha: alpha * (0.65 + 0.35 * gazeBoost))
        ..style = PaintingStyle.stroke
        ..strokeWidth = _kOutlineMetres * 1.6,
    );

    if (highlight) {
      final phase = math.sin(ctx.seconds * 3.2) * 0.5 + 0.5;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(0.07), Radius.circular(half * 0.4)),
        Paint()
          ..color = color.withValues(alpha: alpha * (0.25 + 0.5 * phase))
          ..style = PaintingStyle.stroke
          ..strokeWidth = _kOutlineMetres * 2,
      );
    }

    paintIconGlyph(
      canvas: canvas,
      icon: icon,
      center: Offset.zero,
      sizeMetres: sizeMetres * 0.6,
      color: color.withValues(alpha: alpha),
    );
  }
}

/// Cache of laid-out icon glyphs.
///
/// Building a Paragraph means running the text engine: shaping, layout, the
/// lot. Doing that once per icon per node per frame was costing far more than
/// the drawing itself — eight nodes at 60 fps is ~500 layouts a second on a
/// phone that has a camera preview and a particle system to feed as well.
///
/// Keyed on the glyph and its colour. Alpha comes from atmospheric fade, which
/// is a constant 1.0 for anything inside 8 m, so in practice the cache is hit
/// on nearly every draw. Colour is quantised so a slow fade cannot fill the map
/// with near-identical entries, and the cache is capped regardless.
final Map<int, Paragraph> _glyphCache = <int, Paragraph>{};

const int _glyphCacheLimit = 64;
const double _glyphLayoutPixels = 64.0;

Paragraph _glyphParagraph(IconData icon, Color color) {
  // 5 bits of alpha is far finer than the eye resolves and keeps the key space
  // small.
  final quantisedAlpha = (color.a * 31).round();
  final key = Object.hash(
    icon.codePoint,
    icon.fontFamily,
    (color.r * 255).round(),
    (color.g * 255).round(),
    (color.b * 255).round(),
    quantisedAlpha,
  );

  final cached = _glyphCache[key];
  if (cached != null) return cached;

  if (_glyphCache.length >= _glyphCacheLimit) {
    // These are cheap to rebuild, so evicting wholesale is simpler and no worse
    // than tracking recency.
    _glyphCache.clear();
  }

  final builder = ParagraphBuilder(ParagraphStyle(
    fontFamily: icon.fontFamily,
    fontSize: _glyphLayoutPixels,
    height: 1.0,
  ))
    ..pushStyle(TextStyle(
      color: color.withValues(alpha: quantisedAlpha / 31),
      fontSize: _glyphLayoutPixels,
      fontFamily: icon.fontFamily,
    ))
    ..addText(String.fromCharCode(icon.codePoint));

  final paragraph = builder.build()
    ..layout(const ParagraphConstraints(width: _glyphLayoutPixels * 1.5));

  _glyphCache[key] = paragraph;
  return paragraph;
}

/// Draws a Material icon glyph into world-space canvas units.
///
/// Icons are font glyphs, so they are resolution-independent and scale cleanly
/// under the renderer's metre transform. This is a large part of why the engine
/// needs no bitmap or 3D assets at all: the entire visual vocabulary is icon
/// glyphs plus vector paths, which keeps the APK small and dodges every asset
/// licensing question.
void paintIconGlyph({
  required Canvas canvas,
  required IconData icon,
  required Offset center,
  required double sizeMetres,
  required Color color,
}) {
  // Glyphs are laid out at a fixed pixel size and then scaled into metres.
  // Rasterising directly at metre scale would ask the text engine for a ~0.5px
  // font and produce mush.
  final paragraph = _glyphParagraph(icon, color);
  final scale = sizeMetres / _glyphLayoutPixels;

  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.scale(scale);
  canvas.drawParagraph(
    paragraph,
    Offset(-paragraph.longestLine / 2, -_glyphLayoutPixels / 2),
  );
  canvas.restore();
}

/// Convenience constructors for the recurring signage in these scenarios.
abstract final class SafetyNodes {
  /// A compliant fire exit: green, running-man icon, ground ring to draw the eye.
  static DoorwayNode fireExit({
    required String id,
    required Vector3 position,
    bool highlight = false,
  }) {
    return DoorwayNode(
      id: id,
      position: position,
      frameColor: const Color(0xFF2E7D32),
      signColor: const Color(0xFF2E7D32),
      signIcon: Icons.directions_run,
      signLabel: 'EXIT',
      highlight: highlight,
    );
  }

  /// A door that looks usable but is chained shut. Present because "the nearest
  /// door" and "the usable door" are not the same thing, and that gap is exactly
  /// what kills people during an evacuation.
  static DoorwayNode lockedDoor({
    required String id,
    required Vector3 position,
  }) {
    return DoorwayNode(
      id: id,
      position: position,
      frameColor: const Color(0xFF757575),
      signColor: const Color(0xFF616161),
      signIcon: Icons.lock_outline,
      signLabel: 'LOCKED',
    );
  }

  /// A lift. Never to be used in a fire, and a decoy that catches a lot of
  /// first-time trainees.
  static DoorwayNode lift({
    required String id,
    required Vector3 position,
  }) {
    return DoorwayNode(
      id: id,
      position: position,
      frameColor: const Color(0xFF546E7A),
      signColor: const Color(0xFF455A64),
      signIcon: Icons.elevator_outlined,
      signLabel: 'LIFT',
    );
  }
}
