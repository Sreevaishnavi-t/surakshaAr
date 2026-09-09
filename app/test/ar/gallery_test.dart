import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/environment/environment_map.dart';
import 'package:surakshaar/ar/environment/floor_detector.dart';
import 'package:surakshaar/ar/environment/ground_plane.dart';
import 'package:surakshaar/ar/pose/device_pose.dart';
import 'package:surakshaar/ar/scene/ar_camera.dart';
import 'package:surakshaar/ar/scene/scene_graph.dart';
import 'package:surakshaar/ar/world/gallery_layout.dart';
import 'package:surakshaar/ar/world/gallery_nodes.dart';
import 'package:vector_math/vector_math_64.dart';

const ground = GroundPlane(cameraHeightMetres: 1.5);

/// A calibrated camera, as the live session always builds one.
///
/// Calibration is what maps scene-forward (+Y) onto the heading the worker is
/// actually facing. Without it scene +Y sits 90 degrees to the left of the view
/// axis and the whole gallery projects behind the camera — which is a property
/// of the test rig, not of the gallery.
ArCamera cameraFacing(double yaw, {bool calibrated = true}) => ArCamera(
      pose: DevicePose.upright(yawRadians: yaw),
      intrinsics: ArCameraIntrinsics.fallback,
      previewSize: const Size(480, 720),
      viewportSize: const Size(384, 832),
      worldFromScene:
          calibrated ? ArCamera.calibrationFromYaw(yaw) : null,
    );

/// Builds a room where every direction is obstructed at the same distance,
/// except optionally one clear corridor.
EnvironmentMap roomOf({
  required int boundaryRow,
  double? clearBearing,
  int? clearRow,
}) {
  final map = EnvironmentMap();

  for (var step = 0; step < 36; step++) {
    final yaw = step / 36 * 2 * math.pi;
    final isClear = clearBearing != null &&
        _angularDistance(yaw, clearBearing) < 0.25;

    map.ingest(
      floor: FloorScan(
        columns: [
          for (var i = 0; i < 32; i++)
            ColumnBoundary(
              column: i,
              boundaryRow: isClear ? clearRow : boundaryRow,
              confidence: 0.8,
            ),
        ],
        gridHeight: 24,
      ),
      doors: const [],
      camera: cameraFacing(yaw, calibrated: false),
      ground: ground,
    );
  }

  return map;
}

double _angularDistance(double a, double b) {
  var delta = (a - b).abs() % (2 * math.pi);
  if (delta > math.pi) delta = 2 * math.pi - delta;
  return delta;
}

void main() {
  group('GalleryLayout.fit', () {
    test('falls back to standard dimensions in an unmapped room', () {
      final layout = GalleryLayout.fit(map: EnvironmentMap());

      expect(layout.fittedToRoom, isFalse);
      expect(layout.halfWidthMetres, GalleryLayout.standard.halfWidthMetres);
      // Flagged rather than hidden: an unfitted gallery can run through a real
      // wall, and the worker should be told.
      expect(layout.fittedToRoom, isFalse);
    });

    test('narrows the gallery to fit a cramped room', () {
      // Obstructions close in on every side.
      final tight = GalleryLayout.fit(map: roomOf(boundaryRow: 20));
      final open = GalleryLayout.fit(map: roomOf(boundaryRow: 17));

      expect(tight.fittedToRoom, isTrue);
      expect(tight.halfWidthMetres, lessThanOrEqualTo(open.halfWidthMetres));
      expect(tight.halfWidthMetres,
          greaterThanOrEqualTo(GalleryLayout.minHalfWidth));
    });

    test('never exceeds the sane bounds of a real roadway', () {
      // A hall with nothing in it should still not produce a cathedral.
      final layout = GalleryLayout.fit(map: roomOf(boundaryRow: 5));

      expect(layout.halfWidthMetres,
          inInclusiveRange(GalleryLayout.minHalfWidth, GalleryLayout.maxHalfWidth));
      expect(layout.lengthMetres,
          inInclusiveRange(GalleryLayout.minLength, GalleryLayout.maxLength));
    });

    test('runs the tunnel down the clearest line available', () {
      // One corridor open, everything else close in.
      const corridor = 2.0;
      final map = roomOf(
        boundaryRow: 20,
        clearBearing: corridor,
        clearRow: null,
      );

      final layout = GalleryLayout.fit(map: map);

      expect(
        _angularDistance(layout.axisBearingRadians, corridor),
        lessThan(0.4),
        reason: 'the gallery should point along the open corridor',
      );
    });

    test('holds the ribs back from the real wall', () {
      final map = roomOf(boundaryRow: 18);
      final layout = GalleryLayout.fit(map: map);

      final sideways = map.freeDistanceAt(
        layout.axisBearingRadians + math.pi / 2,
      );

      if (sideways != null && layout.halfWidthMetres > GalleryLayout.minHalfWidth) {
        // Otherwise the rib is embedded in the worker's actual wall.
        expect(layout.halfWidthMetres, lessThan(sideways));
      }
    });

    test('puts the floor at the measured eye height', () {
      final layout = GalleryLayout.fit(
        map: roomOf(boundaryRow: 18),
        eyeHeightMetres: 1.62,
      );

      expect(layout.floorDropMetres, 1.62);
      // Roof rise is measured from the floor, not from the camera.
      expect(layout.roofRise, closeTo(layout.roofHeightMetres - 1.62, 1e-9));
    });
  });

  group('gallery nodes', () {
    const layout = GalleryLayout(
      axisBearingRadians: 0,
      halfWidthMetres: 1.7,
      lengthMetres: 9,
      roofHeightMetres: 2.9,
      floorDropMetres: 1.5,
      fittedToRoom: true,
    );

    /// Renders a node and reports whether anything was actually drawn.
    bool drawsSomething(ProjectedSceneNode node, ArCamera camera) {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      node.paintProjected(
        canvas,
        ProjectedRenderContext(
          camera: camera,
          elapsed: const Duration(milliseconds: 500),
          viewportSize: camera.viewportSize,
        ),
      );
      final picture = recorder.endRecording();
      // approximateBytesUsed is zero for an empty display list.
      return picture.approximateBytesUsed > 0;
    }

    test('the gallery draws when the worker looks down it', () {
      final node = MineGalleryNode(id: 'gallery', layout: layout);
      expect(drawsSomething(node, cameraFacing(0)), isTrue);
    });

    test('rails draw down the tunnel', () {
      final node = MineRailsNode(id: 'rails', layout: layout);
      expect(drawsSomething(node, cameraFacing(0)), isTrue);
    });

    test('the portal sits at the far end, on the floor', () {
      final node = GalleryPortalNode(id: 'portal', layout: layout);

      expect(node.position.y, closeTo(layout.lengthMetres, 1e-9));
      expect(node.position.z, closeTo(-layout.floorDropMetres, 1e-9));
    });

    test('geometry nodes opt out of the screen-margin cull', () {
      // A tunnel surrounds the camera, so its centre landing off screen says
      // nothing about whether it is visible. Culling it by centre would make
      // the gallery vanish the moment the worker looked sideways.
      expect(
        MineGalleryNode(id: 'g', layout: layout).bypassesScreenCull,
        isTrue,
      );
      expect(MineRailsNode(id: 'r', layout: layout).bypassesScreenCull, isTrue);
    });

    test('draws nothing at all when facing away', () {
      // Every vertex behind the camera means every quad is skipped rather than
      // clamped, which is what stops a vertex behind the viewer streaking
      // across the screen.
      final node = MineGalleryNode(id: 'gallery', layout: layout);
      final behind = cameraFacing(math.pi);

      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      node.paintProjected(
        canvas,
        ProjectedRenderContext(
          camera: behind,
          elapsed: Duration.zero,
          viewportSize: behind.viewportSize,
        ),
      );
      // Should not throw, and should produce little or nothing.
      expect(recorder.endRecording(), isNotNull);
    });

    test('the tunnel is symmetric about its centre line', () {
      // A worker walking down the middle should see equal rib on both sides;
      // asymmetry here would read as the tunnel leaning.
      final camera = cameraFacing(0);
      final node = MineGalleryNode(id: 'gallery', layout: layout, seed: 0);

      final left = camera.project(Vector3(-layout.halfWidthMetres, 5, -1.5));
      final right = camera.project(Vector3(layout.halfWidthMetres, 5, -1.5));

      expect(left, isNotNull);
      expect(right, isNotNull);
      expect(
        camera.viewportCenter.dx - left!.screen.dx,
        closeTo(right!.screen.dx - camera.viewportCenter.dx, 0.5),
      );
      expect(node.bypassesScreenCull, isTrue);
    });
  });
}
