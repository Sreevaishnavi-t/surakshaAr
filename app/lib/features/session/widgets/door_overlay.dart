import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../../../ar/environment/environment_map.dart';
import '../../../ar/nodes/holo_style.dart';
import '../../../ar/scene/ar_camera.dart';

/// Draws what the door detector currently believes, over the live camera feed.
///
/// This is a diagnostic instrument, not part of the drill. A worker never needs
/// to see it; it exists because the detector's thresholds — how strong an edge
/// counts as a jamb, how wide an opening may be before it stops being a door —
/// were chosen from geometry alone and have never been checked against a real
/// room. Tuning a detector you cannot watch is guesswork, and guesswork here
/// costs a worker the one thing the fire drill is about: being pointed at a
/// real way out.
///
/// It deliberately shows **provisional** candidates, the ones seen only once,
/// alongside confirmed ones. A door that is being found and then discarded
/// looks identical to a door that is never found at all if only the survivors
/// are drawn, and those two faults have opposite fixes.
class DoorOverlay extends StatelessWidget {
  const DoorOverlay({
    super.key,
    required this.camera,
    required this.environment,
  });

  final ArCamera camera;
  final EnvironmentMap environment;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: DoorOverlayPainter(
          camera: camera,
          // The quads must be drawn in raw viewport coordinates, so the
          // painter cannot sit inside a SafeArea. The inset is handed to it
          // instead, for the header alone.
          topInset: MediaQuery.paddingOf(context).top,
          doors: environment.provisionalDoors,
          coverage: environment.coverage,
          cameraHeightMetres: environment.ground.cameraHeightMetres,
          heightIsMeasured: environment.ground.isMeasured,
        ),
      ),
    );
  }
}

class DoorOverlayPainter extends CustomPainter {
  const DoorOverlayPainter({
    required this.camera,
    required this.topInset,
    required this.doors,
    required this.coverage,
    required this.cameraHeightMetres,
    required this.heightIsMeasured,
  });

  final ArCamera camera;
  final double topInset;
  final List<MappedDoor> doors;
  final double coverage;
  final double cameraHeightMetres;
  final bool heightIsMeasured;

  /// Sightings at or above which the map stops calling a door provisional.
  static const int _confirmedSightings = 2;

  @override
  void paint(Canvas canvas, Size size) {
    _paintHeader(canvas);

    for (final door in doors) {
      _paintDoor(canvas, door);
    }
  }

  /// The numbers you need in order to read the rest of the overlay.
  ///
  /// Camera height leads, because every metre drawn below is that height times
  /// a ray direction — if it is wrong, every label is wrong by the same ratio
  /// and no amount of threshold tuning will help.
  void _paintHeader(Canvas canvas) {
    final source = heightIsMeasured ? 'stated' : 'assumed';
    final text = 'detector  ·  camera ${cameraHeightMetres.toStringAsFixed(2)} m '
        '($source)  ·  looked at ${(coverage * 100).round()}%  ·  '
        '${doors.length} candidate${doors.length == 1 ? '' : 's'}';

    final painter = _label(text, Holo.neutral, 12);
    // Top left: the scan gate's own content is bottom-aligned and the mode
    // chips are top right, so this is the one corner that stays clear.
    final origin = Offset(12, topInset + 12);

    _plate(canvas, origin, painter, Holo.shadow.withValues(alpha: 0.75));
    painter.paint(canvas, origin);
  }

  /// The four screen corners of a door's frame, in order base-left, top-left,
  /// top-right, base-right — or null if any corner is behind the camera.
  ///
  /// A [MappedDoor] stores a threshold point, a width and a height, but no
  /// facing, so the frame is reconstructed standing square-on to the worker.
  /// That is right to within the bearing's own resolution, and squaring it up
  /// is all this overlay claims to show.
  ///
  /// All four corners or none: a quad with one corner projected from behind the
  /// camera folds inside out, and drawing a confidently wrong shape is worse
  /// than drawing nothing in an instrument meant to be trusted.
  static List<Offset>? quadFor(ArCamera camera, MappedDoor door) {
    final bearing = door.bearingRadians;
    final across = Vector3(-math.sin(bearing), math.cos(bearing), 0)
      ..scale(door.widthMetres / 2);

    final baseLeft = door.basePoint + across;
    final baseRight = door.basePoint - across;
    final rise = Vector3(0, 0, door.heightMetres);

    final projected = [
      camera.projectWorld(baseLeft),
      camera.projectWorld(baseLeft + rise),
      camera.projectWorld(baseRight + rise),
      camera.projectWorld(baseRight),
    ];
    if (projected.any((point) => point == null)) return null;

    return [for (final point in projected) point!.screen];
  }

  void _paintDoor(Canvas canvas, MappedDoor door) {
    final quad = quadFor(camera, door);
    if (quad == null) return;

    final confirmed = door.sightings >= _confirmedSightings;
    final colour = confirmed ? Holo.exitGreen : Holo.cautionAmber;

    final path = Path()..moveTo(quad.first.dx, quad.first.dy);
    for (final corner in quad.skip(1)) {
      path.lineTo(corner.dx, corner.dy);
    }
    path.close();

    canvas.drawPath(path, Paint()..color = colour.withValues(alpha: 0.12));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = confirmed ? 2.5 : 1.5
        ..color = colour,
    );

    // The threshold itself, which is the point scenario content anchors to.
    final base = camera.projectWorld(door.basePoint);
    if (base != null) {
      canvas.drawCircle(base.screen, 4, Paint()..color = colour);
    }

    _paintDoorLabel(canvas, door, quad, colour);
  }

  void _paintDoorLabel(
    Canvas canvas,
    MappedDoor door,
    List<Offset> quad,
    Color colour,
  ) {
    final topLeft = quad[1];
    final topRight = quad[2];

    final text = '${door.widthMetres.toStringAsFixed(2)} × '
        '${door.heightMetres.toStringAsFixed(2)} m\n'
        '${door.distanceMetres.toStringAsFixed(1)} m away  ·  '
        'seen ${door.sightings}×  ·  ${(door.confidence * 100).round()}%'
        '${door.isOpening ? '  ·  open' : ''}';

    final painter = _label(text, colour, 11);
    final centre = Offset(
      (topLeft.dx + topRight.dx) / 2,
      math.min(topLeft.dy, topRight.dy),
    );
    final origin = centre - Offset(painter.width / 2, painter.height + 6);

    _plate(canvas, origin, painter, Holo.shadow.withValues(alpha: 0.7));
    painter.paint(canvas, origin);
  }

  TextPainter _label(String text, Color colour, double size) => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: colour,
            fontSize: size,
            height: 1.3,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();

  /// A backing plate, so a label stays readable over a bright camera image.
  void _plate(Canvas canvas, Offset origin, TextPainter painter, Color colour) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          origin.dx - 6,
          origin.dy - 4,
          painter.width + 12,
          painter.height + 8,
        ),
        const Radius.circular(5),
      ),
      Paint()..color = colour,
    );
  }

  @override
  bool shouldRepaint(DoorOverlayPainter old) =>
      old.camera != camera ||
      old.topInset != topInset ||
      old.doors != doors ||
      old.coverage != coverage ||
      old.cameraHeightMetres != cameraHeightMetres;
}
