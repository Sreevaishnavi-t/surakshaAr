
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../scene/ar_camera.dart';
import 'door_detector.dart';
import 'environment_map.dart';
import 'floor_detector.dart';
import 'ground_plane.dart';
import 'luma_grid.dart';

/// Runs environment sensing over the live camera stream.
///
/// Analysis is deliberately throttled well below the frame rate. Nothing about
/// a room changes in 100 ms, and the worker is holding the phone in one hand
/// while being talked through a drill — spending every frame on image analysis
/// would cost the overlay its frame budget for no extra knowledge. Ten frames a
/// second is far more than enough to map a room somebody is panning across.
class SceneScanner {
  SceneScanner({
    required this.map,
    this.floorDetector = const FloorDetector(),
    this.doorDetector = const DoorDetector(),
    this.minInterval = const Duration(milliseconds: 100),
  });

  final EnvironmentMap map;
  final FloorDetector floorDetector;
  final DoorDetector doorDetector;

  /// Shortest gap between two analysed frames.
  final Duration minInterval;

  /// Supplies the camera for the moment a frame arrives.
  ///
  /// A frame is only interpretable alongside the pose it was taken at, and the
  /// pose changes continuously while the worker sweeps. Pulling the camera at
  /// analysis time rather than holding a stale one is what keeps a detected
  /// door in the direction it was actually seen.
  ArCamera? Function()? cameraProvider;

  GroundPlane ground = GroundPlane.assumed;

  /// Rotation from sensor orientation to the displayed portrait orientation.
  /// Derived from the camera description's `sensorOrientation`.
  int quarterTurns = 1;

  bool _busy = false;
  Duration _lastAnalysis = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();

  int _framesSeen = 0;
  int _framesAnalysed = 0;

  int get framesSeen => _framesSeen;
  int get framesAnalysed => _framesAnalysed;

  /// Feeds one camera frame in. Cheap to call at full frame rate.
  void onFrame(CameraImage image) {
    _framesSeen++;

    if (_busy) return;
    final now = _clock.elapsed;
    if (now - _lastAnalysis < minInterval) return;

    final camera = cameraProvider?.call();
    if (camera == null) return;

    _busy = true;
    _lastAnalysis = now;
    try {
      _analyse(image, camera);
      _framesAnalysed++;
    } catch (e) {
      // Frame analysis is an enhancement, never a dependency. A malformed frame
      // must degrade the room map, not end the drill.
      debugPrint('SceneScanner: frame dropped: $e');
    } finally {
      _busy = false;
    }
  }

  void _analyse(CameraImage image, ArCamera camera) {
    final plane = image.planes.first;
    final grid = LumaGrid.fromCameraFrame(
      plane: plane.bytes,
      imageWidth: image.width,
      imageHeight: image.height,
      rowStride: plane.bytesPerRow,
      // The frame arrives in sensor orientation; the grid must come out aligned
      // with the viewport or every detection lands a quarter turn away.
      displayPreviewSize: camera.previewSize,
      viewportSize: camera.viewportSize,
      quarterTurns: quarterTurns,
    );

    // Convert the horizon into grid rows so the floor trace never climbs into
    // sky or ceiling, which would poison the floor profile for that column.
    final horizonPixels = camera.horizonY();
    final horizonRow = horizonPixels == null
        ? null
        : (horizonPixels / camera.viewportSize.height * grid.height)
            .floor()
            .clamp(0, grid.height - 1);

    final floor = floorDetector.detect(grid, horizonRow: horizonRow);
    final doors = doorDetector.detect(
      grid: grid,
      floor: floor,
      camera: camera,
      ground: ground,
    );

    map.ingest(floor: floor, doors: doors, camera: camera, ground: ground);
  }
}
