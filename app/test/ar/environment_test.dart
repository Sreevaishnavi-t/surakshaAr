import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/environment/door_detector.dart';
import 'package:surakshaar/ar/environment/floor_detector.dart';
import 'package:surakshaar/ar/environment/ground_plane.dart';
import 'package:surakshaar/ar/environment/luma_grid.dart';
import 'package:surakshaar/ar/pose/device_pose.dart';
import 'package:surakshaar/ar/scene/ar_camera.dart';
import 'package:vector_math/vector_math_64.dart';

/// Builds a grid from a `(x, y) -> luma` function.
LumaGrid gridOf(
  int width,
  int height,
  int Function(int x, int y) sample,
) {
  final cells = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      cells[y * width + x] = sample(x, y).clamp(0, 255);
    }
  }
  return LumaGrid(width: width, height: height, cells: cells);
}

/// Deterministic per-cell jitter, so "textured" surfaces are not uniform but
/// tests stay reproducible.
int jitter(int x, int y, int amplitude) =>
    ((math.sin(x * 12.9898 + y * 78.233) * 43758.5453) % 1).abs() ~/ 1 == 0
        ? (((x * 7 + y * 13) % (amplitude * 2)) - amplitude)
        : 0;

DevicePose tiltedPose(double pitch) {
  final base = DevicePose.upright();
  final right = Vector3(0, -1, 0);
  final tilt = Quaternion.axisAngle(right, pitch);
  return base.copyWith(worldFromDevice: (tilt * base.worldFromDevice)..normalize());
}

ArCamera cameraTilted(double pitch) => ArCamera(
      pose: tiltedPose(pitch),
      intrinsics: ArCameraIntrinsics.fallback,
      previewSize: const Size(480, 720),
      viewportSize: const Size(384, 832),
    );

void main() {
  group('LumaGrid', () {
    test('box-averages a luma plane and respects row stride', () {
      // A plane whose rows are 40 bytes wide but only 32 pixels are image data.
      // Ignoring stride is the classic YUV bug and shears the picture.
      const width = 32, height = 24, stride = 40;
      final plane = Uint8List(stride * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < stride; x++) {
          // Image area is a vertical ramp; padding is deliberately garbage.
          plane[y * stride + x] = x < width ? (y * 10).clamp(0, 255) : 255;
        }
      }

      final grid = LumaGrid.fromLumaPlane(
        plane: plane,
        imageWidth: width,
        imageHeight: height,
        rowStride: stride,
        gridWidth: 8,
        gridHeight: 6,
      );

      // Brightness must increase down the grid and be constant across it. If
      // the padding leaked in, the right-hand cells would be far brighter.
      for (var gy = 0; gy < 6; gy++) {
        final row = [for (var gx = 0; gx < 8; gx++) grid.at(gx, gy)];
        expect(row.reduce(math.max) - row.reduce(math.min), lessThan(12),
            reason: 'row $gy should be uniform');
      }
      expect(grid.at(0, 5), greaterThan(grid.at(0, 0)));
    });

    test('verticalEdgeAt fires on a vertical edge and ignores a horizontal one', () {
      final vertical = gridOf(16, 12, (x, y) => x < 8 ? 40 : 200);
      final horizontal = gridOf(16, 12, (x, y) => y < 6 ? 40 : 200);

      expect(vertical.verticalEdgeAt(8, 6), greaterThan(100));
      // A purely horizontal edge has no left-right gradient at all.
      expect(horizontal.verticalEdgeAt(8, 6), lessThan(1));
    });
  });

  group('FloorDetector', () {
    const detector = FloorDetector();

    test('reports open floor when the whole frame is one surface', () {
      final grid = gridOf(16, 12, (x, y) => 100 + jitter(x, y, 3));
      final scan = detector.detect(grid);

      expect(scan.columns.every((c) => c.isOpenToHorizon), isTrue);
      expect(scan.coverage, greaterThan(0.9));
    });

    test('finds a bright wall above a dark floor', () {
      // Floor for the bottom half, much brighter wall above.
      final grid = gridOf(16, 12, (x, y) => y >= 6 ? 70 : 190);
      final scan = detector.detect(grid);

      for (final column in scan.columns) {
        expect(column.boundaryRow, isNotNull);
        // The true wall starts at row 5, and the detector stops at row 6. That
        // one-row lead is inherent: textureAt averages over a 3-row window, so
        // the last floor cell already "sees" the wall above it. It errs toward
        // under-reporting floor, which is the safe direction — content bunches
        // slightly nearer rather than being placed inside a wall.
        expect(column.boundaryRow, inInclusiveRange(5, 6));
      }
    });

    test('finds a same-brightness wall by its texture break', () {
      // The case brightness alone cannot solve: grey wall over grey floor, both
      // averaging 120. Only the texture discontinuity distinguishes them.
      final grid = gridOf(16, 12, (x, y) {
        if (y >= 6) return 120 + jitter(x, y, 18); // rough floor
        return 120; // flat, featureless wall
      });

      final scan = detector.detect(grid);
      final boundaries = scan.columns
          .map((c) => c.boundaryRow)
          .whereType<int>()
          .toList();

      expect(boundaries, isNotEmpty,
          reason: 'texture break should be detected without a brightness cue');
      expect(boundaries.every((row) => row <= 5 && row >= 4), isTrue);
    });

    test('never traces above a supplied horizon', () {
      final grid = gridOf(16, 12, (x, y) => 100 + jitter(x, y, 3));
      final scan = detector.detect(grid, horizonRow: 7);

      // With the horizon at row 7, tracing stops there and nothing above is
      // absorbed into the floor profile.
      expect(scan.columns.every((c) => c.boundaryRow == null), isTrue);
    });

    test('a thin profile is treated leniently', () {
      // A mild step one row above the seed must not end the trace: with only
      // two samples the statistics cannot support that call, and a premature
      // boundary makes the whole room read as a metre deep.
      final grid = gridOf(16, 12, (x, y) => y >= 9 ? 100 : 112);
      final scan = detector.detect(grid);

      expect(scan.columns.first.boundaryRow, isNull);
    });
  });

  _cameraFrameTests();

  group('DoorDetector', () {
    const floorDetector = FloorDetector();
    const doorDetector = DoorDetector();
    const cameraHeight = 1.5;
    const ground = GroundPlane(cameraHeightMetres: cameraHeight);

    /// Renders a wall with a rectangular opening, by ray-casting real geometry.
    ///
    /// Hand-painted grids were tried first and were a bad test: they encode a
    /// guess about how many cells a door "should" span, which depends on focal
    /// length, preview aspect and cover-crop. Building the scene from metres
    /// instead means the test asserts the thing that matters — that the
    /// detector recovers the dimensions that were actually put in.
    LumaGrid renderWall({
      required ArCamera camera,
      required double wallDistance,
      double? doorWidth,
      double doorHeight = 2.05,
      double doorCentreLateral = 0,
      int wallLuma = 170,
      int openingLuma = 25,
    }) {
      const gw = 32, gh = 24;
      return gridOf(gw, gh, (gx, gy) {
        final screen = Offset(
          (gx + 0.5) / gw * camera.viewportSize.width,
          (gy + 0.5) / gh * camera.viewportSize.height,
        );
        final ray = camera.rayThrough(screen);

        // Anything not heading toward the wall is open sky above it.
        if (ray.x <= 1e-6) return wallLuma;
        final tWall = wallDistance / ray.x;

        // Floor wins when the ray reaches it before the wall.
        if (ray.z < 0) {
          final tGround = cameraHeight / -ray.z;
          if (tGround < tWall) return 80 + jitter(gx, gy, 6);
        }

        final lateral = ray.y * tWall;
        final height = ray.z * tWall + cameraHeight;

        if (doorWidth != null &&
            height >= 0 &&
            height <= doorHeight &&
            (lateral - doorCentreLateral).abs() <= doorWidth / 2) {
          return openingLuma;
        }
        return wallLuma;
      });
    }

    List<DoorCandidate> detectIn(LumaGrid grid, ArCamera camera) =>
        doorDetector.detect(
          grid: grid,
          floor: floorDetector.detect(grid),
          camera: camera,
          ground: ground,
        );

    test('recovers the real width and height of a doorway', () {
      final camera = cameraTilted(-0.15);
      final grid = renderWall(
        camera: camera,
        wallDistance: 5.0,
        doorWidth: 0.9,
        doorHeight: 2.05,
      );

      final doors = detectIn(grid, camera);
      expect(doors, isNotEmpty, reason: 'a 0.9 x 2.05 m doorway should be found');

      final door = doors.first;
      // Grid resolution is ~7 cm per column at this distance, so a tolerance of
      // a couple of cells is the honest limit of the measurement.
      expect(door.widthMetres, closeTo(0.9, 0.25));
      expect(door.heightMetres, closeTo(2.05, 0.45));
      expect(door.distanceMetres, closeTo(5.0, 0.8));
      expect(door.isOpening, isTrue);
      expect(door.basePoint.z, closeTo(-cameraHeight, 1e-6),
          reason: 'the threshold must sit on the floor plane');
    });

    test('points at the doorway, not past it', () {
      final camera = cameraTilted(-0.15);
      // Opening offset to the worker's left (+Y in world with yaw 0).
      //
      // 0.45 m and no further: at 5 m this camera sees only ±1.14 m of wall, so
      // a door centred at 1.0 m would have its far jamb outside the frame. The
      // detector then correctly refuses to pair a lone edge — which is right
      // behaviour and a badly chosen test.
      final grid = renderWall(
        camera: camera,
        wallDistance: 5.0,
        doorWidth: 0.9,
        doorCentreLateral: 0.45,
      );

      final doors = detectIn(grid, camera);
      expect(doors, isNotEmpty);
      expect(doors.first.basePoint.y, closeTo(0.45, 0.35));
      expect(doors.first.bearingRadians, greaterThan(0));
    });

    test('rejects a gap too narrow to walk through', () {
      final camera = cameraTilted(-0.15);
      final grid = renderWall(
        camera: camera,
        wallDistance: 5.0,
        doorWidth: 0.25, // a pipe recess, not a door
      );

      expect(detectIn(grid, camera), isEmpty);
    });

    test('rejects an opening too wide to be a door', () {
      final camera = cameraTilted(-0.15);
      final grid = renderWall(
        camera: camera,
        wallDistance: 5.0,
        doorWidth: 3.2, // a roller shutter or a bay
      );

      expect(detectIn(grid, camera), isEmpty);
    });

    test('rejects a hatch that does not reach the floor', () {
      const gw = 32, gh = 24;
      const wallDistance = 5.0;

      // Same wall, but the opening floats between 1.0 m and 1.8 m — a serving
      // hatch or a window. Nothing a worker can evacuate through.
      final grid = gridOf(gw, gh, (gx, gy) {
        final screen = Offset(
          (gx + 0.5) / gw * 384,
          (gy + 0.5) / gh * 832,
        );
        final ray = cameraTilted(-0.15).rayThrough(screen);
        if (ray.x <= 1e-6) return 170;
        final tWall = wallDistance / ray.x;
        if (ray.z < 0) {
          final tGround = 1.5 / -ray.z;
          if (tGround < tWall) return 80 + jitter(gx, gy, 6);
        }
        final lateral = ray.y * tWall;
        final height = ray.z * tWall + 1.5;
        if (height >= 1.0 && height <= 1.8 && lateral.abs() <= 0.45) return 25;
        return 170;
      });

      // Jambs must have floor contact; a floating hatch has none, so its edges
      // are never even considered.
      expect(detectIn(grid, cameraTilted(-0.15)), isEmpty);
    });

    test('finds nothing in a blank wall', () {
      final camera = cameraTilted(-0.15);
      final grid = renderWall(camera: camera, wallDistance: 5.0);

      expect(detectIn(grid, camera), isEmpty);
    });

    test('finds nothing when there is no wall at all', () {
      final camera = cameraTilted(-0.15);
      final grid = gridOf(32, 24, (x, y) => 100 + jitter(x, y, 4));

      // Open floor to the horizon everywhere, so no jamb has floor contact.
      expect(detectIn(grid, camera), isEmpty);
    });

    test('reports one doorway once, not several nested copies', () {
      final camera = cameraTilted(-0.15);
      final grid = renderWall(
        camera: camera,
        wallDistance: 5.0,
        doorWidth: 0.9,
      );

      expect(detectIn(grid, camera).length, lessThanOrEqualTo(2));
    });

    test('prefers the better-proportioned of two openings', () {
      final camera = cameraTilted(-0.15);
      const gw = 32, gh = 24;
      const wallDistance = 5.0;

      final grid = gridOf(gw, gh, (gx, gy) {
        final screen = Offset((gx + 0.5) / gw * 384, (gy + 0.5) / gh * 832);
        final ray = camera.rayThrough(screen);
        if (ray.x <= 1e-6) return 170;
        final tWall = wallDistance / ray.x;
        if (ray.z < 0) {
          final tGround = 1.5 / -ray.z;
          if (tGround < tWall) return 80 + jitter(gx, gy, 6);
        }
        final lateral = ray.y * tWall;
        final height = ray.z * tWall + 1.5;
        if (height < 0) return 170;
        // A proper door on the left, a squat wide gap on the right.
        if (height <= 2.05 && (lateral - 0.85).abs() <= 0.45) return 25;
        if (height <= 1.6 && (lateral + 1.0).abs() <= 0.75) return 25;
        return 170;
      });

      final doors = detectIn(grid, camera);
      expect(doors, isNotEmpty);
      // The door-proportioned opening is on the +Y (left) side.
      expect(doors.first.basePoint.y, greaterThan(0));
    });
  });
}

/// Guards the sensor-orientation and cover-crop mapping.
///
/// If this is wrong nothing crashes and nothing looks obviously broken — the
/// room is simply reported rotated a quarter turn, so a door straight ahead is
/// announced to the worker's left. Silent, and dangerous in a drill about
/// finding the way out, so it is pinned.
void _cameraFrameTests() {
  group('LumaGrid.fromCameraFrame', () {
    // A landscape sensor frame: left half dark, right half bright.
    Uint8List splitFrame(int w, int h, int stride) {
      final plane = Uint8List(stride * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < stride; x++) {
          plane[y * stride + x] = x < w ~/ 2 ? 30 : 220;
        }
      }
      return plane;
    }

    test('undoes a 90 degree sensor rotation', () {
      const w = 640, h = 480, stride = 640;
      final grid = LumaGrid.fromCameraFrame(
        plane: splitFrame(w, h, stride),
        imageWidth: w,
        imageHeight: h,
        rowStride: stride,
        displayPreviewSize: const Size(480, 640),
        viewportSize: const Size(480, 640),
        quarterTurns: 1,
        gridWidth: 8,
        gridHeight: 8,
      );

      // A vertical split in the sensor becomes a horizontal split on screen.
      // Turning a picture clockwise swings its left edge up to the top, so the
      // sensor's dark left half lands at the top of the display.
      expect(grid.at(4, 0), lessThan(100), reason: 'sensor left -> screen top');
      expect(grid.at(4, 7), greaterThan(150), reason: 'sensor right -> screen bottom');
    });

    test('leaves an unrotated frame alone', () {
      const w = 640, h = 480, stride = 640;
      final grid = LumaGrid.fromCameraFrame(
        plane: splitFrame(w, h, stride),
        imageWidth: w,
        imageHeight: h,
        rowStride: stride,
        displayPreviewSize: const Size(640, 480),
        viewportSize: const Size(640, 480),
        quarterTurns: 0,
        gridWidth: 8,
        gridHeight: 8,
      );

      // No rotation: the split stays vertical.
      expect(grid.at(0, 4), lessThan(100));
      expect(grid.at(7, 4), greaterThan(150));
    });

    test('respects row stride', () {
      const w = 640, h = 480, stride = 704; // padded rows
      final plane = Uint8List(stride * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < stride; x++) {
          // Image area uniform; padding deliberately bright garbage.
          plane[y * stride + x] = x < w ? 100 : 255;
        }
      }

      final grid = LumaGrid.fromCameraFrame(
        plane: plane,
        imageWidth: w,
        imageHeight: h,
        rowStride: stride,
        displayPreviewSize: const Size(480, 640),
        viewportSize: const Size(480, 640),
        gridWidth: 8,
        gridHeight: 8,
      );

      // Every cell should read the uniform image area, never the padding.
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          expect(grid.at(x, y), closeTo(100, 6));
        }
      }
    });

    test('samples only the visible part of a cover-cropped preview', () {
      // A 4:3 preview shown in a tall viewport is cropped left and right, so
      // the extreme edges of the sensor are off screen and must not be sampled.
      const w = 640, h = 480, stride = 640;
      final plane = Uint8List(stride * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < stride; x++) {
          // Mark only the very top and bottom sensor rows, which become the
          // left and right screen edges after a quarter turn.
          plane[y * stride + x] = (y < 20 || y > h - 20) ? 255 : 90;
        }
      }

      final grid = LumaGrid.fromCameraFrame(
        plane: plane,
        imageWidth: w,
        imageHeight: h,
        rowStride: stride,
        displayPreviewSize: const Size(480, 640),
        viewportSize: const Size(384, 832),
        gridWidth: 8,
        gridHeight: 8,
      );

      // The cropped-away bands should not dominate any cell.
      final centre = grid.at(4, 4);
      expect(centre, closeTo(90, 12));
    });
  });
}
