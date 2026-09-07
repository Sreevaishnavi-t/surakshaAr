import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

/// Runs ML Kit barcode detection over the live camera stream.
///
/// Serves two purposes that look unrelated but need identical plumbing:
/// verifying a certificate QR, and detecting the printed markers that pin AR
/// content to a real wall or machine.
///
/// The model is bundled in the APK, so detection works with the radio off.
/// That is not incidental — the entire premise is a platform that functions in
/// a gallery with no signal, and an unbundled model that downloads on first use
/// would fail exactly where it is needed.
class BarcodeScannerService {
  BarcodeScannerService({List<BarcodeFormat>? formats})
      : _scanner = BarcodeScanner(
          formats: formats ?? const [BarcodeFormat.qrCode],
        );

  final BarcodeScanner _scanner;

  /// Guards against queueing frames faster than they can be processed. Without
  /// it a mid-range phone builds an unbounded backlog and the preview stalls
  /// within seconds.
  bool _busy = false;

  bool _closed = false;

  /// Processes one camera frame, returning any barcodes found.
  ///
  /// Returns an empty list when a previous frame is still in flight, which is
  /// the correct behaviour: dropping frames costs nothing here because the next
  /// one is 16 ms away.
  Future<List<Barcode>> process({
    required CameraImage image,
    required CameraDescription camera,
    required int deviceOrientationDegrees,
  }) async {
    if (_busy || _closed) return const [];
    _busy = true;

    try {
      final input = _toInputImage(
        image: image,
        camera: camera,
        deviceOrientationDegrees: deviceOrientationDegrees,
      );
      if (input == null) return const [];

      return await _scanner.processImage(input);
    } catch (e) {
      // A malformed frame must never take down a training session or a
      // verification attempt; skip it and try the next one.
      debugPrint('BarcodeScannerService: frame skipped: $e');
      return const [];
    } finally {
      _busy = false;
    }
  }

  /// Converts a camera frame into the form ML Kit expects.
  ///
  /// The camera is configured for NV21 on Android specifically so this stays a
  /// single contiguous plane. Requesting YUV420 instead would mean manually
  /// interleaving three planes here with per-device row and pixel strides —
  /// a well-known source of subtly corrupted frames that detect nothing while
  /// looking perfectly fine in the preview.
  InputImage? _toInputImage({
    required CameraImage image,
    required CameraDescription camera,
    required int deviceOrientationDegrees,
  }) {
    if (image.planes.isEmpty) return null;

    final rotation = _resolveRotation(
      sensorOrientation: camera.sensorOrientation,
      deviceOrientationDegrees: deviceOrientationDegrees,
      lensDirection: camera.lensDirection,
    );
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw as int? ?? 0);
    if (format == null) return null;

    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  /// Works out how far the frame must be rotated for ML Kit to read it upright.
  ///
  /// Getting this wrong does not produce an error — it produces a scanner that
  /// simply never finds anything, which is far harder to diagnose. A QR code is
  /// rotation-tolerant in principle, but only within the detector's own search
  /// range once the frame itself is sideways.
  static InputImageRotation? _resolveRotation({
    required int sensorOrientation,
    required int deviceOrientationDegrees,
    required CameraLensDirection lensDirection,
  }) {
    final int rotationCompensation;
    if (lensDirection == CameraLensDirection.front) {
      // Front cameras are mirrored, so the compensation adds rather than
      // subtracts.
      rotationCompensation = (sensorOrientation + deviceOrientationDegrees) % 360;
    } else {
      rotationCompensation =
          (sensorOrientation - deviceOrientationDegrees + 360) % 360;
    }

    return InputImageRotationValue.fromRawValue(rotationCompensation);
  }

  Future<void> close() async {
    _closed = true;
    await _scanner.close();
  }
}

/// A detected QR marker, with the corner geometry the AR anchor needs.
class DetectedMarker {
  const DetectedMarker({
    required this.value,
    required this.corners,
    required this.imageSize,
  });

  /// Decoded payload, e.g. `SJHM:EXIT-1`.
  final String value;

  /// Four corners in image coordinates, in the order ML Kit reported them.
  final List<Offset> corners;

  final Size imageSize;

  /// Apparent side length in pixels, averaged over the four edges.
  ///
  /// Combined with the marker's known printed size and the camera's focal
  /// length, this gives distance — which is what turns a 2D detection into a
  /// 3D anchor.
  double get apparentSidePixels {
    if (corners.length != 4) return 0;
    var total = 0.0;
    for (var i = 0; i < 4; i++) {
      total += (corners[(i + 1) % 4] - corners[i]).distance;
    }
    return total / 4;
  }

  Offset get centre {
    if (corners.isEmpty) return Offset.zero;
    var x = 0.0;
    var y = 0.0;
    for (final corner in corners) {
      x += corner.dx;
      y += corner.dy;
    }
    return Offset(x / corners.length, y / corners.length);
  }
}

/// Prefix distinguishing an AR anchor marker from a certificate QR.
///
/// Both are scanned by the same detector, so the payload has to say which it
/// is. Without this, pointing the AR view at a worker's certificate would try
/// to anchor the scene to it.
const String kMarkerPrefix = 'SJHM:';
